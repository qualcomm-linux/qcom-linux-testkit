#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"

while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="qcom_hwrng"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! check_dependencies rngtest head wc awk mktemp; then
    test_result_finish SKIP "Image lacks rngtest or the utilities needed for bounded entropy validation"
fi
if [ "$(id -u)" != 0 ]; then
    test_result_finish SKIP "Selecting the hardware RNG requires root"
fi
RNG_CURRENT_PATH=/sys/class/misc/hw_random/rng_current
RNG_AVAILABLE_PATH=/sys/class/misc/hw_random/rng_available
if [ ! -r "$RNG_AVAILABLE_PATH" ]; then
    test_result_finish SKIP "No hardware RNG providers registered in sysfs"
fi
RNG_SELECTED=""
rng_available=$(cat "$RNG_AVAILABLE_PATH")
for rng_provider in $rng_available; do
    case "$rng_provider" in
        *qcom*)
            RNG_SELECTED="$rng_provider"
            break
            ;;
    esac
done
if [ -z "$RNG_SELECTED" ]; then
    test_result_finish SKIP "No Qualcomm RNG provider registered, available: $(cat "$RNG_AVAILABLE_PATH")"
fi
if [ ! -c /dev/hwrng ] || [ ! -r /dev/hwrng ]; then
    test_result_finish FAIL "Registered RNG $RNG_SELECTED has no readable /dev/hwrng character device"
fi
RESULT_DIR=$(mktemp -d "$PWD/qcom_hwrng.XXXXXX") || test_result_finish FAIL "Cannot create RNG evidence directory in CWD"
RNG_PREVIOUS=$(cat "$RNG_CURRENT_PATH") || test_result_finish FAIL "Cannot read current RNG selection"
RNG_CHANGED=0
trap rng_cleanup 0
trap 'test_result_finish FAIL "RNG validation interrupted"' HUP INT TERM
if [ "$RNG_PREVIOUS" != "$RNG_SELECTED" ]; then
    # shellcheck disable=SC2034 # Consumed by rng_cleanup.
    RNG_CHANGED=1
    if ! printf '%s\n' "$RNG_SELECTED" >"$RNG_CURRENT_PATH" ||
       [ "$(cat "$RNG_CURRENT_PATH")" != "$RNG_SELECTED" ]; then
        test_result_finish FAIL "Cannot select registered RNG provider $RNG_SELECTED"
    fi
fi
log_info "Selected RNG: $RNG_SELECTED, evidence: $RESULT_DIR"
if ! rng_validate_entropy /dev/hwrng 1000 9 "$RESULT_DIR" 60 30; then
    test_result_finish FAIL "Hardware entropy read or statistics failed, see $RESULT_DIR"
fi
if ! rng_restore_selection; then
    test_result_finish FAIL "RNG selection restoration failed"
fi
test_result_finish PASS "1000 entropy blocks validated, statistical failures below 10, evidence=$RESULT_DIR"
