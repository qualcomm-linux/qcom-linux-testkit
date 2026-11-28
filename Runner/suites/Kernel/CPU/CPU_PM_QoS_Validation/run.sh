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

TESTNAME="CPU_PM_QoS_Validation"
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

qos_seen=0
if [ -c /dev/cpu_dma_latency ]; then
    test_result_record "PASS" "/dev/cpu_dma_latency is a character device"
    qos_seen=1
elif [ -e /dev/cpu_dma_latency ]; then
    test_result_record "FAIL" "/dev/cpu_dma_latency is not a character device"
    qos_seen=1
else
    test_result_record "SKIP" "/dev/cpu_dma_latency is not present"
fi

for cpu_name in $(kernel_list_all_cpus); do
    for qos_attr in pm_qos_resume_latency_us pm_qos_latency_tolerance_us; do
        qos_node="/sys/devices/system/cpu/$cpu_name/power/$qos_attr"
        [ -e "$qos_node" ] || continue
        qos_seen=1
        qos_val="$(kernel_attribute_value "$qos_node")" || qos_val=""
        case "$qos_attr" in
            pm_qos_resume_latency_us)
                if [ "$qos_val" = "n/a" ] || is_unsigned_number "$qos_val"; then
                    test_result_record "PASS" "$cpu_name $qos_attr='$qos_val'"
                else
                    test_result_record "FAIL" "$cpu_name $qos_attr is not an unsigned latency or n/a ('${qos_val:-unreadable}')"
                fi
                ;;
            pm_qos_latency_tolerance_us)
                if [ "$qos_val" = "auto" ] || [ "$qos_val" = "any" ] || is_unsigned_number "$qos_val"; then
                    test_result_record "PASS" "$cpu_name $qos_attr='$qos_val'"
                else
                    test_result_record "FAIL" "$cpu_name $qos_attr is not unsigned, auto, or any ('${qos_val:-unreadable}')"
                fi
                ;;
        esac
    done
done

if [ "$qos_seen" -eq 0 ]; then
    test_result_record "SKIP" "no PM QoS interface is exposed"
fi

test_result_finish
