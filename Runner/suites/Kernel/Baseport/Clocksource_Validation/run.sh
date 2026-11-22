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

TESTNAME="Clocksource_Validation"
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
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "clocksource|timekeeping"
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

cs_dir="/sys/devices/system/clocksource/clocksource0"
if [ ! -d "$cs_dir" ]; then
    test_result_record "SKIP" "clocksource0 sysfs is not present"
    test_result_finish "SKIP"
fi

kernel_record_attribute "current_clocksource" "$cs_dir/current_clocksource"
kernel_record_attribute "available_clocksource" "$cs_dir/available_clocksource"

current="$(kernel_attribute_value "$cs_dir/current_clocksource" || true)"
available="$(kernel_attribute_value "$cs_dir/available_clocksource" || true)"
if [ -n "$current" ] && [ -n "$available" ]; then
    case " $available " in
        *" $current "*)
            test_result_record "PASS" "current clocksource '$current' is in available list"
            ;;
        *)
            test_result_record "FAIL" "current clocksource '$current' not in available list '$available'"
            ;;
    esac
fi

kernel_log_has_pattern "clocksource.*unstable|Timekeeping.*unstable"
k_log_rc=$?
if [ "$k_log_rc" -eq 0 ]; then
    test_result_record "FAIL" "kernel log reports an unstable clocksource"
elif [ "$k_log_rc" -eq 2 ]; then
    test_result_record "SKIP" "kernel log unavailable; check unverified"
else
    test_result_record "PASS" "no clocksource-unstable messages in kernel log"
fi

if kernel_config_is_enabled CONFIG_GENERIC_CLOCKEVENTS; then
    test_result_record "PASS" "CONFIG_GENERIC_CLOCKEVENTS is enabled"
else
    test_result_record "SKIP" "CONFIG_GENERIC_CLOCKEVENTS not visible"
fi

test_result_finish
