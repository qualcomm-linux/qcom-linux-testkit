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

TESTNAME="pinctrl"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0

# usage
# Print the supported options without changing hardware.
usage() {
    printf '%s\n' "Usage: $0 [--help]"
}

# parse_args <arguments...>
# Reject unsupported arguments before test setup.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *)
                test_result_finish FAIL "Unsupported option: $1"
                ;;
        esac
    done
}
parse_args "$@"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat awk grep mkdir mktemp date; then
    test_result_finish SKIP "Image-provided pinctrl validation utilities are unavailable"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create evidence under CWD=$PWD"
log_info "Evidence: $OUT_DIR"

debug_root=""
for candidate in /sys/kernel/debug /debug; do
    if [ -r "$candidate/pinctrl/pinctrl-devices" ]; then
        debug_root="$candidate"
        break
    fi
done
[ -n "$debug_root" ] || test_result_finish SKIP "Image does not expose readable pinctrl debugfs inventory, no mount changed"
if ! cat "$debug_root/pinctrl/pinctrl-devices" >"$OUT_DIR/pinctrl-devices.log"; then
    test_result_finish FAIL "Cannot read exposed pinctrl controller inventory"
fi
log_file_with_label PINCTRL "$OUT_DIR/pinctrl-devices.log"
controller_count=$(awk 'NR > 1 && NF { count++ } END {print count+0}' "$OUT_DIR/pinctrl-devices.log")
if [ "$controller_count" -eq 0 ]; then
    test_result_finish SKIP "No pinctrl controller is registered in the exposed inventory"
fi
scan_dmesg_errors "$OUT_DIR" 'pinctrl|tlmm' '' || true
if [ -s "$OUT_DIR/dmesg_errors.log" ]; then
    log_file_with_label PINCTRL-ERROR "$OUT_DIR/dmesg_errors.log"
    test_result_record FAIL "Captured pinctrl driver errors"
fi
test_result_record PASS "$controller_count registered pinctrl controller(s), no pin configuration changed"
test_result_finish
