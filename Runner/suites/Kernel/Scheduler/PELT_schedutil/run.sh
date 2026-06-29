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

TESTNAME="PELT_schedutil"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

# Kill any background load task on exit
LOAD_PID=""
# shellcheck disable=SC2317
cleanup() {
    if [ -n "$LOAD_PID" ]; then
        kill "$LOAD_PID" 2>/dev/null || true
        LOAD_PID=""
    fi
}
trap cleanup EXIT INT TERM

log_info "================================================================================"
log_info "============ Starting $TESTNAME Testcase ======================================="
log_info "================================================================================"
log_info "Validates schedutil cpufreq governor integration with PELT utilization signals"

if ! check_dependencies grep awk cat; then
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi


pass="true"
schedutil_cpus=""

CPUFREQ_BASE="/sys/devices/system/cpu/cpufreq"
CPU_BASE="/sys/devices/system/cpu"

# ---------------------------------------------------------------------------
# Discover CPUs using schedutil governor
# ---------------------------------------------------------------------------
log_info "=== Schedutil Governor Detection ==="

for policy_dir in "$CPUFREQ_BASE"/policy*; do
    [ -d "$policy_dir" ] || continue
    policy_name=$(basename "$policy_dir")
    gov_file="$policy_dir/scaling_governor"

    if [ -f "$gov_file" ]; then
        gov=$(cat "$gov_file" 2>/dev/null)
        if [ "$gov" = "schedutil" ]; then
            log_pass "  $policy_name: governor = schedutil"
            schedutil_cpus="$schedutil_cpus $policy_name"
        else
            log_info "  $policy_name: governor = $gov (not schedutil)"
        fi
    fi
done

if [ -z "$schedutil_cpus" ]; then
    log_warn "No CPU policies using schedutil governor found"
    log_warn "schedutil is required for PELT-driven frequency scaling"
    log_warn "Check available governors:"
    for policy_dir in "$CPUFREQ_BASE"/policy*; do
        [ -d "$policy_dir" ] || continue
        avail_file="$policy_dir/scaling_available_governors"
        if [ -f "$avail_file" ]; then
            avail=$(cat "$avail_file" 2>/dev/null)
            log_info "  $(basename "$policy_dir"): available = $avail"
        fi
    done
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# ---------------------------------------------------------------------------
# For each schedutil policy: validate frequency range and rate_limit_us
# ---------------------------------------------------------------------------
log_info "=== Schedutil Policy Validation ==="

for policy_name in $schedutil_cpus; do
    policy_dir="$CPUFREQ_BASE/$policy_name"
    log_info "--- $policy_name ---"

    # Frequency range
    min_freq_file="$policy_dir/scaling_min_freq"
    max_freq_file="$policy_dir/scaling_max_freq"
    cur_freq_file="$policy_dir/scaling_cur_freq"

    if [ -f "$min_freq_file" ] && [ -f "$max_freq_file" ]; then
        min_freq=$(cat "$min_freq_file" 2>/dev/null)
        max_freq=$(cat "$max_freq_file" 2>/dev/null)
        log_pass "  freq range: ${min_freq} kHz  -  ${max_freq} kHz"

        if [ -n "$min_freq" ] && [ -n "$max_freq" ] && \
           [ "$max_freq" -ge "$min_freq" ] 2>/dev/null; then
            log_pass "  freq range valid (max >= min)"
        else
            log_fail "  freq range invalid: max ($max_freq) < min ($min_freq)"
            pass="false"
        fi
    fi

    if [ -f "$cur_freq_file" ]; then
        cur_freq=$(cat "$cur_freq_file" 2>/dev/null)
        log_info "  current freq: ${cur_freq} kHz"
    fi

    # rate_limit_us  -  schedutil-specific tunable
    rate_limit_file="$policy_dir/schedutil/rate_limit_us"
    if [ -f "$rate_limit_file" ]; then
        rate_limit=$(cat "$rate_limit_file" 2>/dev/null)
        log_pass "  rate_limit_us = $rate_limit us"
    else
        log_info "  rate_limit_us not present (kernel version dependent)"
    fi

    # Available frequencies
    avail_freq_file="$policy_dir/scaling_available_frequencies"
    if [ -f "$avail_freq_file" ]; then
        avail_freqs=$(cat "$avail_freq_file" 2>/dev/null)
        freq_count=$(printf '%s\n' "$avail_freqs" | wc -w)
        log_info "  available frequencies ($freq_count): $avail_freqs"
    fi

    # Related CPUs
    related_file="$policy_dir/related_cpus"
    if [ -f "$related_file" ]; then
        related=$(cat "$related_file" 2>/dev/null)
        log_info "  related CPUs: $related"
    fi
done

# ---------------------------------------------------------------------------
# Functional: verify frequency responds to CPU load under schedutil
# ---------------------------------------------------------------------------
log_info "=== Schedutil Frequency Response Under Load ==="

# Pick first schedutil policy for load test
first_policy=$(printf '%s\n' "$schedutil_cpus" | awk '{print $1}')
policy_dir="$CPUFREQ_BASE/$first_policy"
cur_freq_file="$policy_dir/scaling_cur_freq"

if [ -f "$cur_freq_file" ]; then
    idle_freq=$(cat "$cur_freq_file" 2>/dev/null)
    log_info "  Idle frequency ($first_policy): ${idle_freq} kHz"

    # Spawn CPU-bound load
    log_info "  Spawning CPU-bound task (3 seconds)..."
    ( i=0; while true; do i=$((i + 1)); done ) &
    LOAD_PID=$!

    sleep 2

    load_freq=$(cat "$cur_freq_file" 2>/dev/null)
    log_info "  Under-load frequency ($first_policy): ${load_freq} kHz"

    kill "$LOAD_PID" 2>/dev/null || true
    LOAD_PID=""

    if [ -n "$idle_freq" ] && [ -n "$load_freq" ] && \
       [ "$load_freq" -gt "$idle_freq" ] 2>/dev/null; then
        log_pass "  Frequency increased under load: ${idle_freq} -> ${load_freq} kHz"
        log_pass "  schedutil is responding to PELT utilization signal"
    elif [ -n "$load_freq" ] && [ -n "$idle_freq" ] && [ "$load_freq" -eq "$idle_freq" ] 2>/dev/null; then
        log_warn "  Frequency unchanged under load (${idle_freq} kHz)"
        log_warn "  May be at max freq already, or schedutil rate_limit_us is high"
        log_info "  This is a warning only  -  not a failure"
    else
        log_warn "  Could not compare frequencies (idle=${idle_freq} load=${load_freq})"
    fi
else
    log_warn "  scaling_cur_freq not available for $first_policy  -  skipping load test"
fi

# ---------------------------------------------------------------------------
# /sys/devices/system/cpu/cpu*/cpufreq/util  -  PELT util per-CPU (if present)
# ---------------------------------------------------------------------------
log_info "=== Per-CPU PELT Utilization (cpufreq util) ==="

util_found="false"
for cpu_dir in "$CPU_BASE"/cpu[0-9]*; do
    [ -d "$cpu_dir" ] || continue
    util_file="$cpu_dir/cpufreq/util"
    if [ -f "$util_file" ]; then
        util_val=$(cat "$util_file" 2>/dev/null)
        cpu_name=$(basename "$cpu_dir")
        log_info "  $cpu_name util = $util_val"
        util_found="true"
    fi
done

if [ "$util_found" = "false" ]; then
    log_info "  Per-CPU cpufreq/util not present (kernel version dependent)"
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
