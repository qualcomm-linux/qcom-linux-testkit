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

TESTNAME="Clockevents_Validation"
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
if ! k_kernel_evidence_init "."; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

ce_root="/sys/devices/system/clockevents"
if [ ! -d "$ce_root" ]; then
    test_result_record "SKIP" "clockevents sysfs is not present"
    test_result_finish "SKIP"
fi

found=0
for ce_dir in "$ce_root"/clockevent* "$ce_root"/broadcast; do
    [ -e "$ce_dir" ] || continue
    found=$((found + 1))
    log_info "Inspecting $ce_dir"
    if [ -r "$ce_dir/current_device" ]; then
        k_record_readable "clockevent current_device" "$ce_dir/current_device"
    fi
    if [ -r "$ce_dir/available_events" ]; then
        k_record_readable "clockevent available_events" "$ce_dir/available_events"
    fi
done

if [ -d /sys/kernel/debug/clock_event_devices ] || [ -d /sys/kernel/debug/timer_list ]; then
    test_result_record "PASS" "debugfs clock-event/timer info is present"
else
    test_result_record "SKIP" "debugfs clock-event devices not mounted/exported"
fi

if [ "$found" -eq 0 ]; then
    test_result_record "SKIP" "no clockevent device nodes under $ce_root"
    test_result_finish "SKIP"
fi

test_result_record "PASS" "clockevents sysfs enumerated $found node(s)"
test_result_finish
