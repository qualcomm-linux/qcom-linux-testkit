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

TESTNAME="PELT_schedstat"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "================================================================================"
log_info "============ Starting $TESTNAME Testcase ======================================="
log_info "================================================================================"
log_info "Validates /proc/schedstat  -  the PELT per-CPU runtime accounting interface"

if ! check_dependencies grep awk cat; then
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

pass="true"

# ---------------------------------------------------------------------------
# /proc/schedstat  -  existence and version
# ---------------------------------------------------------------------------
log_info "=== /proc/schedstat Interface ==="

if [ ! -f /proc/schedstat ]; then
    log_fail "/proc/schedstat not found"
    log_warn "Enable CONFIG_SCHEDSTATS in the kernel to expose PELT accounting"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

schedstat_ver=$(awk '/^version/ {print $2}' /proc/schedstat)
log_pass "/proc/schedstat present (version $schedstat_ver)"

# ---------------------------------------------------------------------------
# Per-CPU line format validation
# schedstat v15 cpu line:
#   cpu<N> yld_count yld_act_count sched_count sched_goidle
#          ttwu_count ttwu_local rq_cpu_time run_delay pcount
# Fields: 10 total (including the "cpuN" label)
# rq_cpu_time = field 8, run_delay = field 9, pcount = field 10
# ---------------------------------------------------------------------------
log_info "=== Per-CPU Line Validation ==="

cpu_count=0
bad_lines=0

while IFS= read -r line; do
    case "$line" in
        cpu[0-9]*)
            cpu_count=$((cpu_count + 1))
            field_count=$(printf '%s\n' "$line" | awk '{print NF}')
            if [ "$field_count" -lt 10 ]; then
                log_warn "  Unexpected field count ($field_count) on: $line"
                bad_lines=$((bad_lines + 1))
            else
                cpu_id=$(printf '%s\n' "$line" | awk '{print $1}')
                rq_cpu_time=$(printf '%s\n' "$line" | awk '{print $8}')
                run_delay=$(printf '%s\n' "$line" | awk '{print $9}')
                pcount=$(printf '%s\n' "$line" | awk '{print $10}')
                log_info "  $cpu_id: rq_cpu_time=${rq_cpu_time}ns  run_delay=${run_delay}ns  pcount=$pcount"
            fi
            ;;
    esac
done < /proc/schedstat

if [ "$cpu_count" -eq 0 ]; then
    log_fail "No cpu* lines found in /proc/schedstat"
    pass="false"
elif [ "$bad_lines" -gt 0 ]; then
    log_fail "$bad_lines cpu line(s) had unexpected format"
    pass="false"
else
    log_pass "All $cpu_count CPU lines have valid format"
fi

# ---------------------------------------------------------------------------
# Aggregate totals
# ---------------------------------------------------------------------------
log_info "=== Aggregate PELT Accounting ==="

total_runtime=$(awk '/^cpu[0-9]/ {sum += $8} END {print sum+0}' /proc/schedstat)
total_delay=$(awk '/^cpu[0-9]/ {sum += $9} END {print sum+0}' /proc/schedstat)
total_pcount=$(awk '/^cpu[0-9]/ {sum += $10} END {print sum+0}' /proc/schedstat)

log_info "  Total rq_cpu_time : ${total_runtime} ns"
log_info "  Total run_delay   : ${total_delay} ns"
log_info "  Total pcount      : ${total_pcount}"

if [ "$total_runtime" -gt 0 ] 2>/dev/null; then
    log_pass "rq_cpu_time is non-zero  -  PELT CPU accounting is active"
else
    log_fail "rq_cpu_time is zero  -  scheduler may not be accounting CPU time"
    pass="false"
fi

# ---------------------------------------------------------------------------
# Scheduling domain lines (present in schedstat alongside cpu lines)
# ---------------------------------------------------------------------------
log_info "=== Scheduling Domain Lines ==="

domain_count=$(grep -c "^domain" /proc/schedstat 2>/dev/null || echo 0)
if [ "$domain_count" -gt 0 ]; then
    log_pass "Found $domain_count scheduling domain line(s) in /proc/schedstat"
else
    log_warn "No domain lines found in /proc/schedstat (may be normal on some kernels)"
fi

# ---------------------------------------------------------------------------
# /proc/self/schedstat  -  per-task PELT stats
# ---------------------------------------------------------------------------
log_info "=== Per-Task schedstat (/proc/self/schedstat) ==="

if [ -f /proc/self/schedstat ]; then
    self_stat=$(cat /proc/self/schedstat)
    exec_ns=$(printf '%s\n' "$self_stat" | awk '{print $1}')
    wait_ns=$(printf '%s\n' "$self_stat" | awk '{print $2}')
    timeslices=$(printf '%s\n' "$self_stat" | awk '{print $3}')
    log_pass "/proc/self/schedstat: exec_ns=$exec_ns  wait_ns=$wait_ns  timeslices=$timeslices"
else
    log_warn "/proc/self/schedstat not found (CONFIG_SCHEDSTATS may be disabled)"
fi

# ---------------------------------------------------------------------------
# /proc/loadavg  -  PELT-derived system load
# ---------------------------------------------------------------------------
log_info "=== /proc/loadavg (PELT-derived load averages) ==="

if [ -f /proc/loadavg ]; then
    loadavg=$(cat /proc/loadavg)
    log_pass "/proc/loadavg: $loadavg"
else
    log_fail "/proc/loadavg not found"
    pass="false"
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
