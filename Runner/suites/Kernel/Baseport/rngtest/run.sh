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

TESTNAME="rngtest"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! check_dependencies rngtest head wc awk mktemp; then
    test_result_finish SKIP "Image lacks bounded RNG statistics tools"
fi
RESULT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || test_result_finish FAIL "Cannot create entropy evidence directory"
trap 'managed_timeout_cancel_bounded 2' 0
trap 'test_result_finish FAIL "RNG validation interrupted"' HUP INT TERM
RNG_SOURCE=/dev/urandom
if [ -e /dev/hwrng ]; then
    RNG_SOURCE=/dev/hwrng
fi
log_info "RNG source=$RNG_SOURCE, no fallback after a selected hardware source fails"
if ! rng_validate_entropy "$RNG_SOURCE" 1000 3 "$RESULT_DIR" 10 30; then
    test_result_finish FAIL "Entropy read or statistics failed, see $RESULT_DIR"
fi
test_result_finish PASS "1000 blocks validated from $RNG_SOURCE with at least 997 successes"
