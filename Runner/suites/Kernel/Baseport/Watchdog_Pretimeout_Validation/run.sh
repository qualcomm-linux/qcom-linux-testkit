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

TESTNAME="Watchdog_Pretimeout_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
# shellcheck disable=SC2034
CHECK_DEPS_RECOVER=0

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

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

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

deps_list="cat grep sed awk tr mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "watchdog"
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

wd_dir="$(watchdog_sysfs_dirs | awk 'NR==1 { print; exit }')"
if [ -z "$wd_dir" ]; then
    test_result_record "SKIP" "No watchdog sysfs device found"
    test_result_finish "SKIP"
fi

found=0
for node in pretimeout pretimeout_governor pretimeout_available_governors; do
    if [ -e "$wd_dir/$node" ]; then
        found=1
        kernel_record_attribute "watchdog $node" "$wd_dir/$node"
    else
        test_result_record "SKIP" "$wd_dir/$node not exported"
    fi
done

if [ "$found" -eq 0 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: driver does not export pretimeout ABI"
fi

pretimeout="$(kernel_attribute_value "$wd_dir/pretimeout")" || pretimeout=""
timeout="$(kernel_attribute_value "$wd_dir/timeout")" || timeout=""
if ! is_unsigned_number "$pretimeout" || ! is_unsigned_number "$timeout"; then
    test_result_record "FAIL" "pretimeout='$pretimeout' or timeout='$timeout' is not an unsigned integer"
elif [ "$pretimeout" -eq 0 ]; then
    test_result_record "PASS" "pretimeout is disabled (0), timeout=$timeout"
elif [ "$pretimeout" -lt "$timeout" ]; then
    test_result_record "PASS" "pretimeout ($pretimeout) is below timeout ($timeout)"
else
    test_result_record "FAIL" "pretimeout ($pretimeout) must be strictly below timeout ($timeout)"
fi

test_result_finish
