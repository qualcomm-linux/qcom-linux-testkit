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
# shellcheck disable=SC1091
. "$TOOLS/lib_kernel.sh"

TESTNAME="Watchdog_Keepalive_Validation"
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
if ! k_kernel_evidence_init "watchdog"; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if ! isroot; then
    test_result_record "SKIP" "root is required to open /dev/watchdog"
    test_result_finish "SKIP"
fi

wd_dir="$(k_first_watchdog_sysfs)"
if [ -z "$wd_dir" ]; then
    test_result_record "SKIP" "No watchdog sysfs device found"
    test_result_finish "SKIP"
fi

wd_dev="$(k_watchdog_dev_for_sysfs "$wd_dir")" || true
if [ -z "$wd_dev" ]; then
    test_result_record "SKIP" "No character device for $wd_dir"
    test_result_finish "SKIP"
fi

if [ ! -w "$wd_dev" ]; then
    test_result_record "SKIP" "$wd_dev is not writable"
    test_result_finish "SKIP"
fi

nowayout="$(k_sysfs_read "$wd_dir/nowayout" 2>/dev/null || true)"
if [ "$nowayout" = "1" ]; then
    test_result_record "SKIP" "nowayout=1; keepalive would arm a non-stoppable watchdog"
    test_result_finish "SKIP"
fi

log_info "Sending keepalive then magic-close 'V' to $wd_dev"
# Open, ping, magic-close, then close. Magic-close must happen before close
# or the hardware watchdog starts the reset countdown.
if sh -c "exec 3>$wd_dev && printf '1' >&3 && printf 'V' >&3 && exec 3>&-"; then
    test_result_record "PASS" "keepalive and magic-close succeeded on $wd_dev"
else
    test_result_record "FAIL" "keepalive/magic-close failed on $wd_dev"
    test_result_finish "FAIL"
fi

state="$(k_sysfs_read "$wd_dir/state" 2>/dev/null || true)"
if [ -n "$state" ]; then
    log_info "watchdog state after magic-close: $state"
    test_result_record "PASS" "watchdog state still readable after keepalive"
fi

test_result_finish
