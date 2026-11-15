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

TESTNAME="CPU_Offline_Safety_Validation"
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

if [ ! -r /sys/devices/system/cpu/cpu0/online ]; then
    test_result_record "SKIP" "cpu0/online is not present (hotplug sysfs incomplete)"
    test_result_finish "SKIP"
fi

cpu0_online="$(k_sysfs_read /sys/devices/system/cpu/cpu0/online)"
if [ "$cpu0_online" = "1" ]; then
    test_result_record "PASS" "CPU0 is online"
else
    test_result_record "SKIP" "CPU0 online='$cpu0_online' (boot CPU may not be cpu0)"
fi

# Confirm writing 0 to cpu0/online is rejected OR not writable. Do not persist a change.
if [ -w /sys/devices/system/cpu/cpu0/online ]; then
    if printf '0\n' > /sys/devices/system/cpu/cpu0/online 2>/dev/null; then
        # Restore immediately if the kernel allowed it (unexpected).
        printf '1\n' > /sys/devices/system/cpu/cpu0/online 2>/dev/null || true
        now="$(k_sysfs_read /sys/devices/system/cpu/cpu0/online)"
        if [ "$now" != "1" ]; then
            test_result_record "FAIL" "CPU0 was offlined; attempted restore, now=$now"
        else
            test_result_record "FAIL" "kernel accepted offline of CPU0 (then restored)"
        fi
    else
        test_result_record "PASS" "kernel rejected offline of CPU0"
    fi
else
    test_result_record "PASS" "cpu0/online is not writable from this context"
fi

if k_config_enabled CONFIG_HOTPLUG_CPU; then
    test_result_record "PASS" "CONFIG_HOTPLUG_CPU is enabled"
else
    test_result_record "SKIP" "CONFIG_HOTPLUG_CPU not visible"
fi

test_result_finish
