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

TESTNAME="RCU_Validation"
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
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "rcu_|RCU"
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

rcu_tiny="$(kernel_config_state CONFIG_TINY_RCU)" || rcu_tiny=""
for rcu_name in rcu_expedited rcu_normal; do
    rcu_path=""
    if [ -e "/sys/module/rcupdate/parameters/$rcu_name" ]; then
        rcu_path="/sys/module/rcupdate/parameters/$rcu_name"
    elif [ -e "/sys/kernel/$rcu_name" ]; then
        rcu_path="/sys/kernel/$rcu_name"
    fi
    if [ -z "$rcu_path" ]; then
        if [ "$rcu_tiny" = "y" ] || [ "$rcu_tiny" = "m" ]; then
            test_result_record "SKIP" "$rcu_name is not exported with CONFIG_TINY_RCU"
        else
            test_result_record "SKIP" "$rcu_name is not exported"
        fi
        continue
    fi
    rcu_val="$(kernel_attribute_value "$rcu_path")" || rcu_val=""
    case "$rcu_val" in
        0|1)
            test_result_record "PASS" "$rcu_name=$rcu_val ($rcu_path)"
            ;;
        *)
            test_result_record "FAIL" "$rcu_name is not 0 or 1 at $rcu_path ('${rcu_val:-unreadable}')"
            ;;
    esac
done

if [ -e /proc/sys/kernel/panic_on_rcu_stall ]; then
    kernel_record_attribute "panic_on_rcu_stall" "/proc/sys/kernel/panic_on_rcu_stall" 1
fi
if [ -e /proc/sys/kernel/max_rcu_stall_to_panic ]; then
    kernel_record_attribute "max_rcu_stall_to_panic" "/proc/sys/kernel/max_rcu_stall_to_panic" 1
fi

if [ -d /sys/kernel/debug/rcu ]; then
    test_result_record "PASS" "debugfs rcu directory is present"
else
    test_result_record "SKIP" "debugfs rcu is not present"
fi

kernel_log_has_pattern "self-detected stall|detected stalls|expedited stall|rcu_preempt detected stalls|rcu_sched detected stalls|RCU Stall"
k_log_rc=$?
if [ "$k_log_rc" -eq 0 ]; then
    test_result_record "FAIL" "kernel log contains an RCU stall"
elif [ "$k_log_rc" -eq 2 ]; then
    test_result_record "SKIP" "kernel log unavailable; check unverified"
else
    test_result_record "PASS" "no RCU stall messages in kernel log"
fi

if kernel_config_is_enabled CONFIG_TREE_RCU || kernel_config_is_enabled CONFIG_PREEMPT_RCU || kernel_config_is_enabled CONFIG_TINY_RCU; then
    test_result_record "PASS" "an RCU implementation Kconfig is enabled"
else
    test_result_record "SKIP" "RCU Kconfig not visible"
fi

test_result_finish
