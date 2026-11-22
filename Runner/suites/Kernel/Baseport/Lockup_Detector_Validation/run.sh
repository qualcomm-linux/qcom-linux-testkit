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

TESTNAME="Lockup_Detector_Validation"
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
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "lockup|hung_task|watchdog"
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

wd="/proc/sys/kernel/watchdog"
if [ ! -e "$wd" ]; then
    test_result_record "SKIP" "/proc/sys/kernel/watchdog is not present"
    test_result_finish "SKIP"
fi

kernel_record_attribute "lockup detector enable" "$wd" 1
if [ -e /proc/sys/kernel/watchdog_thresh ]; then
    kernel_record_attribute "watchdog_thresh" "/proc/sys/kernel/watchdog_thresh" 1
fi
if [ -e /proc/sys/kernel/nmi_watchdog ]; then
    kernel_record_attribute "nmi_watchdog" "/proc/sys/kernel/nmi_watchdog" 1
fi
if [ -e /proc/sys/kernel/soft_watchdog ]; then
    kernel_record_attribute "soft_watchdog" "/proc/sys/kernel/soft_watchdog" 1
fi
if [ -e /proc/sys/kernel/watchdog_cpumask ]; then
    kernel_record_attribute "watchdog_cpumask" "/proc/sys/kernel/watchdog_cpumask"
fi
if [ -e /proc/sys/kernel/softlockup_panic ]; then
    kernel_record_attribute "softlockup_panic" "/proc/sys/kernel/softlockup_panic" 1
fi
if [ -e /proc/sys/kernel/hardlockup_panic ]; then
    kernel_record_attribute "hardlockup_panic" "/proc/sys/kernel/hardlockup_panic" 1
fi

if kernel_config_is_enabled CONFIG_LOCKUP_DETECTOR || kernel_config_is_enabled CONFIG_SOFTLOCKUP_DETECTOR || kernel_config_is_enabled CONFIG_HARDLOCKUP_DETECTOR; then
    test_result_record "PASS" "a lockup-detector Kconfig is enabled"
else
    test_result_record "SKIP" "lockup-detector Kconfig not visible"
fi

kernel_log_has_pattern "BUG: soft lockup|Watchdog detected hard LOCKUP|hung_task"
k_log_rc=$?
if [ "$k_log_rc" -eq 0 ]; then
    test_result_record "FAIL" "kernel log contains a lockup/hung-task splat"
elif [ "$k_log_rc" -eq 2 ]; then
    test_result_record "SKIP" "kernel log unavailable; check unverified"
else
    test_result_record "PASS" "no lockup/hung-task splat in kernel log"
fi

test_result_finish
