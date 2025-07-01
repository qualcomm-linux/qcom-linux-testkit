#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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
 
# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="CPU_affinity"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "----------------------------------------------------"
log_info "-------- Starting $TESTNAME Functional Test --------"

check_dependencies taskset top chrt zcat grep

REQUIRED_CONFIGS="CONFIG_CGROUP_SCHED CONFIG_SMP"
for config in $REQUIRED_CONFIGS; do
    if check_kernel_config "$config"; then
        log_pass "$config is enabled"
        echo "$TESTNAME PASS" > "$res_file"
    else
        log_fail "$config is missing"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi
done

log_info "Creating a CPU-bound background task..."
cpu_task() {
    while true; do :; done
}
cpu_task &
TASK_PID=$!
sleep 2

log_info "Checking CPU affinity of task $TASK_PID..."
CPU_AFFINITY=$(taskset -p $TASK_PID | awk -F: '{print $2}' | xargs)
log_info "CPU affinity: $CPU_AFFINITY"

log_info "Setting affinity to CPU 0"
taskset -pc 0 $TASK_PID > /dev/null
sleep 1

NEW_AFFINITY=$(taskset -p $TASK_PID | awk -F: '{print $2}' | xargs)
if [ "$NEW_AFFINITY" = "1" ]; then
    log_pass "Successfully set CPU affinity"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "Failed to set CPU affinity"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "Checking scheduling policy of task..."
SCHED_POLICY=$(chrt -p $TASK_PID | grep "scheduling policy" | awk -F: '{print $2}' | xargs)
log_info "Scheduling Policy: $SCHED_POLICY"

if echo "$SCHED_POLICY" | grep -q "SCHED_OTHER"; then
    log_pass "Default scheduling policy detected. Test passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "Unexpected scheduling policy. Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

kill $TASK_PID
echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
log_info "-------- Completed $TESTNAME Functional Test --------"
