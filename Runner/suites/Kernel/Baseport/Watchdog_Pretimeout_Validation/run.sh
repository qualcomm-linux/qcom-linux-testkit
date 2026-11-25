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

wd_seen=0
wd_checked=0
for wd_dir in $(watchdog_sysfs_dirs); do
    wd_seen=1
    if [ ! -e "$wd_dir/pretimeout" ] && [ ! -e "$wd_dir/pretimeout_governor" ]; then
        test_result_record "SKIP" "$wd_dir does not export pretimeout"
        continue
    fi
    wd_checked=1
    log_info "Inspecting $wd_dir"
    if [ -e "$wd_dir/pretimeout" ]; then
        pretimeout="$(kernel_attribute_value "$wd_dir/pretimeout")" || pretimeout=""
        timeout="$(kernel_attribute_value "$wd_dir/timeout")" || timeout=""
        if ! is_unsigned_number "$pretimeout" || ! is_unsigned_number "$timeout"; then
            test_result_record "FAIL" "$wd_dir pretimeout='$pretimeout' or timeout='$timeout' is not an unsigned integer"
        elif [ "$pretimeout" -eq 0 ]; then
            test_result_record "PASS" "$wd_dir pretimeout is disabled (0), timeout=$timeout"
        elif [ "$pretimeout" -lt "$timeout" ]; then
            test_result_record "PASS" "$wd_dir pretimeout ($pretimeout) is below timeout ($timeout)"
        else
            test_result_record "FAIL" "$wd_dir pretimeout ($pretimeout) must be strictly below timeout ($timeout)"
        fi
    fi
    if [ -e "$wd_dir/pretimeout_governor" ]; then
        wd_gov="$(kernel_attribute_value "$wd_dir/pretimeout_governor")" || wd_gov=""
        if [ -z "$wd_gov" ]; then
            test_result_record "PASS" "$wd_dir has no pretimeout governor"
        elif [ ! -r "$wd_dir/pretimeout_available_governors" ]; then
            test_result_record "FAIL" "$wd_dir governor '$wd_gov' has no available-governor list"
        elif grep -Fxq "$wd_gov" "$wd_dir/pretimeout_available_governors"; then
            test_result_record "PASS" "$wd_dir governor '$wd_gov' is in the available list"
        else
            test_result_record "FAIL" "$wd_dir governor '$wd_gov' is not in the available list"
        fi
    fi
done

if [ "$wd_seen" -eq 0 ]; then
    test_result_record "SKIP" "No watchdog sysfs device found"
    test_result_finish "SKIP"
fi
if [ "$wd_checked" -eq 0 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: driver does not export pretimeout ABI"
fi

test_result_finish
