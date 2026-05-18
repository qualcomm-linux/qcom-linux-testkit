#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="PELT_config"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "================================================================================"
log_info "============ Starting $TESTNAME Testcase ======================================="
log_info "================================================================================"
log_info "Validates kernel configuration required for PELT (Per-Entity Load Tracking)"

if ! check_dependencies grep; then
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

pass="true"

log_info "=== Core PELT / CFS Kernel Configs ==="

if [ ! -f /proc/config.gz ]; then
    log_warn "/proc/config.gz not found  -  kernel config checks will be skipped"
    log_warn "Ensure CONFIG_IKCONFIG and CONFIG_IKCONFIG_PROC are enabled in the kernel"
else
    CORE_CONFIGS="CONFIG_FAIR_GROUP_SCHED CONFIG_SMP"

    if ! check_kernel_config "$CORE_CONFIGS"; then
        log_fail "Core Scheduler kernel config validation failed"
        pass=false
    else
        log_pass "Core Scheduler configs available"
    fi

    OPTIONAL_CONFIGS="CONFIG_SCHED_DEBUG CONFIG_CFS_BANDWIDTH CONFIG_NO_HZ_COMMON CONFIG_SCHED_AUTOGROUP CONFIG_CGROUP_SCHED CONFIG_CPU_FREQ_GOV_SCHEDUTIL"

    log_info "Checking optional Scheduler configurations..."
    for cfg in $OPTIONAL_CONFIGS; do
        if zgrep -qE "^${cfg}=(y|m)" /proc/config.gz 2>/dev/null; then
            log_pass "  Optional config $cfg is enabled"
        else
            log_info "  Optional config $cfg is not enabled (optional)"
        fi
    done
fi

if [ "$pass" = "true" ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
