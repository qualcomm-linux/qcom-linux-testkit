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

TESTNAME="CPU_Online_Mask_Validation"
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
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

for node in possible present online; do
    path="/sys/devices/system/cpu/$node"
    kernel_record_attribute "cpu $node mask" "$path"
done

if [ -r /sys/devices/system/cpu/offline ]; then
    kernel_record_attribute "cpu offline mask" "/sys/devices/system/cpu/offline"
fi
if [ -r /sys/devices/system/cpu/kernel_max ]; then
    kernel_record_attribute "kernel_max" "/sys/devices/system/cpu/kernel_max" 1
fi

possible="$(kernel_attribute_value /sys/devices/system/cpu/possible)" || possible=""
present="$(kernel_attribute_value /sys/devices/system/cpu/present)" || present=""
online="$(kernel_attribute_value /sys/devices/system/cpu/online)" || online=""

mask_ok=1
if ! kernel_cpu_list_valid "$possible"; then
    test_result_record "FAIL" "cpu possible mask is empty or malformed ('$possible')"
    mask_ok=0
fi
if ! kernel_cpu_list_valid "$present"; then
    test_result_record "FAIL" "cpu present mask is empty or malformed ('$present')"
    mask_ok=0
fi
if ! kernel_cpu_list_valid "$online"; then
    test_result_record "FAIL" "cpu online mask is empty or malformed ('$online')"
    mask_ok=0
fi

fail=0
if [ "$mask_ok" -eq 1 ]; then
    for cpu in $(expand_cpu_list "$online"); do
        if ! cpu_in_list "$cpu" "$present"; then
            test_result_record "FAIL" "CPU$cpu is online but not present"
            fail=1
        fi
        if ! cpu_in_list "$cpu" "$possible"; then
            test_result_record "FAIL" "CPU$cpu is online but not possible"
            fail=1
        fi
    done

    for cpu in $(expand_cpu_list "$present"); do
        if ! cpu_in_list "$cpu" "$possible"; then
            test_result_record "FAIL" "CPU$cpu is present but not possible"
            fail=1
        fi
    done

    if [ "$fail" -eq 0 ]; then
        test_result_record "PASS" "online ⊆ present ⊆ possible (online=$online present=$present possible=$possible)"
    fi
fi

if ! cpu_in_list "0" "$online"; then
    test_result_record "SKIP" "CPU0 is not online; boot CPU id may not be 0"
else
    test_result_record "PASS" "CPU0 is online"
fi

test_result_finish
