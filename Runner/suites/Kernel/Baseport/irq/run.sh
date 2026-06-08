#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="irq"

test_path="$(find_test_case_by_name "$TESTNAME")"
if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    log_warn "Path not found for $TESTNAME test. Falling back to SCRIPT_DIR: $SCRIPT_DIR"
    test_path="$SCRIPT_DIR"
    cd "$test_path" || exit 1
fi

res_file="./$TESTNAME.res"

IRQ_TIMER_PATTERN="${IRQ_TIMER_PATTERN:-arch_timer}"
IRQ_WORKLOAD_SECONDS="${IRQ_WORKLOAD_SECONDS:-5}"
IRQ_RETRIES="${IRQ_RETRIES:-2}"
IRQ_SKIP_ISOLATED="${IRQ_SKIP_ISOLATED:-1}"

rm -f "$res_file"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Config, IRQ_TIMER_PATTERN=$IRQ_TIMER_PATTERN IRQ_WORKLOAD_SECONDS=$IRQ_WORKLOAD_SECONDS IRQ_RETRIES=$IRQ_RETRIES IRQ_SKIP_ISOLATED=$IRQ_SKIP_ISOLATED"

case "$IRQ_WORKLOAD_SECONDS" in
    ''|*[!0-9]*)
        log_warn "Invalid IRQ_WORKLOAD_SECONDS='$IRQ_WORKLOAD_SECONDS', using 5"
        IRQ_WORKLOAD_SECONDS=5
        ;;
esac

case "$IRQ_RETRIES" in
    ''|*[!0-9]*)
        log_warn "Invalid IRQ_RETRIES='$IRQ_RETRIES', using 2"
        IRQ_RETRIES=2
        ;;
esac

case "$IRQ_SKIP_ISOLATED" in
    0|1)
        ;;
    *)
        log_warn "Invalid IRQ_SKIP_ISOLATED='$IRQ_SKIP_ISOLATED', using 1"
        IRQ_SKIP_ISOLATED=1
        ;;
esac

deps_list="awk sed grep tr sleep taskset"

log_info "Checking dependencies: $deps_list"
if ! check_dependencies "$deps_list"; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies: $deps_list"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

validate_per_cpu_interrupt_active "$IRQ_TIMER_PATTERN" "$IRQ_WORKLOAD_SECONDS" "$IRQ_RETRIES" "$IRQ_SKIP_ISOLATED"
irq_validate_rc=$?

if [ "$irq_validate_rc" -eq 0 ]; then
    if [ "${IRQ_ACTIVE_SKIPPED:-0}" -gt 0 ]; then
        log_warn "$TESTNAME: all testable CPUs passed, skipped=${IRQ_ACTIVE_SKIPPED}"
    fi

    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
fi

if [ "$irq_validate_rc" -eq 2 ]; then
    log_skip "$TESTNAME SKIP, ${IRQ_ACTIVE_SKIP_REASON:-active per-CPU interrupt validation unsupported}"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_fail "$TESTNAME : Test Failed"
echo "$TESTNAME FAIL" > "$res_file"
exit 0
