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

TESTNAME="Watchdog_Sysfs_Validation"
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

if [ ! -d /sys/class/watchdog ]; then
    test_result_record "SKIP" "watchdog class is not present under /sys/class/watchdog"
    test_result_finish "SKIP"
fi

wd_count=0
for wd_dir in $(watchdog_sysfs_dirs); do
    wd_count=$((wd_count + 1))
    log_info "Inspecting $wd_dir"
    kernel_record_attribute "watchdog identity" "$wd_dir/identity"
    kernel_record_attribute "watchdog state" "$wd_dir/state"
    kernel_record_attribute "watchdog timeout" "$wd_dir/timeout"
    if [ -e "$wd_dir/status" ]; then
        kernel_record_attribute "watchdog status" "$wd_dir/status"
    else
        test_result_record "SKIP" "watchdog status not exported: $wd_dir/status"
    fi
    if [ -e "$wd_dir/bootstatus" ]; then
        kernel_record_attribute "watchdog bootstatus" "$wd_dir/bootstatus"
    else
        test_result_record "SKIP" "watchdog bootstatus not exported: $wd_dir/bootstatus"
    fi
    if [ -e "$wd_dir/nowayout" ]; then
        kernel_record_attribute "watchdog nowayout" "$wd_dir/nowayout" 1
    else
        test_result_record "SKIP" "watchdog nowayout not exported: $wd_dir/nowayout"
    fi
    if kernel_config_is_enabled CONFIG_WATCHDOG; then
        test_result_record "PASS" "CONFIG_WATCHDOG is enabled"
    else
        test_result_record "SKIP" "CONFIG_WATCHDOG not visible in kernel config"
    fi
done

if [ "$wd_count" -eq 0 ]; then
    if [ -e /dev/watchdog ]; then
        test_result_record "FAIL" "/dev/watchdog exists but /sys/class/watchdog has no watchdogN nodes"
        test_result_finish "FAIL"
    fi
    test_result_record "SKIP" "No watchdogN sysfs nodes found"
    test_result_finish "SKIP"
fi

test_result_finish
