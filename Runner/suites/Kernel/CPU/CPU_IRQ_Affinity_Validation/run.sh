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

TESTNAME="CPU_IRQ_Affinity_Validation"
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

if [ ! -d /proc/irq ]; then
    test_result_record "FAIL" "/proc/irq is not present"
    test_result_finish "FAIL"
fi

checked=0
for irq_dir in /proc/irq/[0-9]*; do
    [ -d "$irq_dir" ] || continue
    irq_name="$(basename "$irq_dir")"
    if [ -e "$irq_dir/smp_affinity" ]; then
        checked=$((checked + 1))
        irq_mask="$(kernel_attribute_value "$irq_dir/smp_affinity")" || irq_mask=""
        if kernel_cpumask_valid "$irq_mask"; then
            test_result_record "PASS" "IRQ $irq_name smp_affinity=$irq_mask"
        else
            test_result_record "FAIL" "IRQ $irq_name smp_affinity is not a hexadecimal mask ('${irq_mask:-unreadable}')"
        fi
    fi
    if [ -e "$irq_dir/smp_affinity_list" ]; then
        irq_list="$(kernel_attribute_value "$irq_dir/smp_affinity_list")" || irq_list=""
        if kernel_cpu_list_valid "$irq_list"; then
            test_result_record "PASS" "IRQ $irq_name smp_affinity_list=$irq_list"
        else
            test_result_record "FAIL" "IRQ $irq_name smp_affinity_list is empty or malformed ('${irq_list:-unreadable}')"
        fi
    fi
    for irq_eff in effective_affinity effective_affinity_list; do
        [ -e "$irq_dir/$irq_eff" ] || continue
        irq_eff_val="$(kernel_attribute_value "$irq_dir/$irq_eff")" || irq_eff_val=""
        log_info "IRQ $irq_name $irq_eff='${irq_eff_val:-empty}' is not part of the configured-affinity verdict"
    done
    if [ "$checked" -ge 8 ]; then
        break
    fi
done

if [ "$checked" -eq 0 ]; then
    test_result_record "FAIL" "no IRQ smp_affinity files found"
    test_result_finish "FAIL"
fi

if [ -r /proc/irq/default_smp_affinity ]; then
    irq_default="$(kernel_attribute_value /proc/irq/default_smp_affinity)" || irq_default=""
    if kernel_cpumask_valid "$irq_default"; then
        test_result_record "PASS" "default_smp_affinity=$irq_default"
    else
        test_result_record "FAIL" "default_smp_affinity is not a hexadecimal mask ('${irq_default:-unreadable}')"
    fi
fi

test_result_finish
