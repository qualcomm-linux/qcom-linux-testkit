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

TESTNAME="PELT_decay"
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
log_info "Validates PELT exponential decay: util_avg must decrease after load stops"
log_info ""
log_info "PELT decay theory:"
log_info "  Half-life  = ~32 ms (one PELT period = 1024 us)"
log_info "  After 200ms idle: util_avg decays to ~1.3% of peak"
log_info "  After 1000ms idle: util_avg decays to ~0% of peak (essentially zero)"

if ! check_dependencies grep awk cat date; then
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

pass="true"
method1_ran="false"
method2_ran="false"

# ============================================================================
# METHOD 1: /proc/$$/sched  se.avg.util_avg  (requires CONFIG_SCHED_DEBUG)
#
# The shell process itself does a CPU-bound busy loop, then sleeps.
# /proc/$$/sched exposes the current task's PELT util_avg.
# Reading it triggers a kernel-side PELT update at that instant.
#
# Expected:
#   peak_util  (immediately after busy loop) >> baseline_util
#   decayed_util (after 1s sleep)            << peak_util
# ============================================================================
log_info "========================================================================"
log_info "=== Method 1: /proc/$$/sched se.avg.util_avg decay ==="
log_info "========================================================================"

# Helper: read se.avg.util_avg from /proc/$$/sched (integer part)
get_self_util_avg() {
    grep "^se\.avg\.util_avg" /proc/$$/sched 2>/dev/null \
        | awk '{printf "%d\n", $NF + 0}'
}

if [ ! -f "/proc/$$/sched" ]; then
    log_warn "Method 1 SKIP: /proc/$$/sched not present"
    log_warn "  Enable CONFIG_SCHED_DEBUG in the kernel for per-task PELT visibility"
else
    method1_ran="true"

    # --- Baseline ---
    baseline_util=$(get_self_util_avg)
    log_info "Baseline util_avg: $baseline_util / 1024"

    # --- CPU-bound busy loop (3 seconds) ---
    # The shell itself does arithmetic work so its own util_avg accumulates.
    # We check the time every 50000 iterations to avoid excessive date forks
    # while still generating real CPU load in this process.
    log_info "Running CPU-bound busy loop for ~3 seconds (saturating PELT)..."
    _now=$(date +%s)
    _busy_end=$(( _now + 3 ))
    _busy_i=0
    while true; do
        _busy_i=$(( _busy_i + 1 ))
        if [ $(( _busy_i % 50000 )) -eq 0 ]; then
            [ "$(date +%s)" -ge "$_busy_end" ] && break
        fi
    done
    log_info "Busy loop complete (iterations: $_busy_i)"

    # --- Read util_avg immediately after busy loop ---
    # Some decay may have occurred during the grep/awk fork, but util_avg
    # should still be significantly elevated.
    peak_util=$(get_self_util_avg)
    log_info "Peak util_avg (post-busy-loop): $peak_util / 1024"

    # --- Sleep for PELT decay ---
    # 1 second = ~31 PELT half-lives  -  theoretical decay to <0.001% of peak
    # We use a conservative pass threshold of 50% decay (extremely lenient)
    log_info "Sleeping 1 second for PELT decay (~31 half-lives)..."
    sleep 1

    # --- Read util_avg after decay ---
    decayed_util=$(get_self_util_avg)
    log_info "Decayed util_avg (post-1s-sleep): $decayed_util / 1024"

    # --- Evaluate ---
    log_info "--- Method 1 Evaluation ---"

    # Check 1: peak_util must be meaningfully elevated after busy loop
    # Threshold: > 100/1024 (~10% utilization). Conservative because
    # fork/exec overhead during grep may have caused some decay already.
    if [ "$peak_util" -gt 100 ] 2>/dev/null; then
        log_pass "  Peak util_avg ($peak_util) > 100  -  PELT accumulated load correctly"
    else
        log_warn "  Peak util_avg ($peak_util) is low  -  busy loop may not have run long enough"
        log_warn "  This may indicate slow shell arithmetic on this platform"
        log_info "  Continuing with decay check regardless..."
    fi

    # Check 2: decayed_util must be less than half of peak_util
    # After 1s sleep, theoretical decay is >99.9%, so 50% threshold is very lenient
    if [ "$peak_util" -gt 0 ] 2>/dev/null; then
        # Compute threshold = peak_util / 2  (integer division via awk)
        decay_threshold=$(awk "BEGIN {printf \"%d\", $peak_util / 2}")
        log_info "  Decay threshold (50% of peak): $decay_threshold"

        if [ "$decayed_util" -lt "$decay_threshold" ] 2>/dev/null; then
            actual_pct=$(awk "BEGIN {printf \"%d\", (1 - $decayed_util / ($peak_util + 0.001)) * 100}")
            log_pass "  util_avg decayed from $peak_util  -  $decayed_util (~${actual_pct}% decay)"
            log_pass "  PELT exponential decay is functioning correctly"
        else
            log_fail "  util_avg did NOT decay sufficiently after 1s sleep"
            log_fail "  peak=$peak_util  decayed=$decayed_util  threshold=<$decay_threshold"
            log_fail "  Expected >50% decay after 1s; PELT decay may be broken"
            pass="false"
        fi
    else
        log_warn "  peak_util is 0  -  cannot evaluate decay ratio"
        log_warn "  Busy loop may not have generated measurable PELT load"
    fi

    log_info "  Summary: baseline=$baseline_util  peak=$peak_util  decayed=$decayed_util"
fi

# ============================================================================
# METHOD 2: schedutil frequency proxy (no CONFIG_SCHED_DEBUG required)
#
# schedutil translates PELT util_avg into CPU frequency requests.
# When util_avg decays after load stops, schedutil should lower the frequency.
#
# Expected:
#   freq_under_load  > freq_idle  (schedutil raised freq due to PELT util)
#   freq_post_decay  < freq_under_load  (schedutil lowered freq as PELT decayed)
# ============================================================================
log_info "========================================================================"
log_info "=== Method 2: schedutil frequency proxy for PELT decay ==="
log_info "========================================================================"

CPUFREQ_BASE="/sys/devices/system/cpu/cpufreq"

# Find first policy using schedutil
schedutil_policy=""
for policy_dir in "$CPUFREQ_BASE"/policy*; do
    [ -d "$policy_dir" ] || continue
    gov_file="$policy_dir/scaling_governor"
    if [ -f "$gov_file" ]; then
        gov=$(cat "$gov_file" 2>/dev/null)
        if [ "$gov" = "schedutil" ]; then
            schedutil_policy=$(basename "$policy_dir")
            break
        fi
    fi
done

if [ -z "$schedutil_policy" ]; then
    log_warn "Method 2 SKIP: No CPU policy using schedutil governor found"
    log_warn "  schedutil is required for PELT-driven frequency scaling"
    log_warn "  Available governors:"
    for policy_dir in "$CPUFREQ_BASE"/policy*; do
        [ -d "$policy_dir" ] || continue
        avail_file="$policy_dir/scaling_available_governors"
        [ -f "$avail_file" ] && log_info "    $(basename "$policy_dir"): $(cat "$avail_file" 2>/dev/null)"
    done
else
    method2_ran="true"
    policy_dir="$CPUFREQ_BASE/$schedutil_policy"
    cur_freq_file="$policy_dir/scaling_cur_freq"
    max_freq_file="$policy_dir/scaling_max_freq"

    log_info "Using schedutil policy: $schedutil_policy"

    if [ ! -f "$cur_freq_file" ]; then
        log_warn "Method 2 SKIP: scaling_cur_freq not available for $schedutil_policy"
        method2_ran="false"
    else
        max_freq=$(cat "$max_freq_file" 2>/dev/null)

        # --- Idle frequency (before load) ---
        # Brief settle time to ensure we're reading a stable idle frequency
        sleep 1
        idle_freq=$(cat "$cur_freq_file" 2>/dev/null)
        log_info "Idle frequency: ${idle_freq} kHz  (max: ${max_freq} kHz)"

        # Check if already at max  -  if so, decay test is not meaningful
        if [ -n "$idle_freq" ] && [ -n "$max_freq" ] && \
           [ "$idle_freq" -ge "$max_freq" ] 2>/dev/null; then
            log_warn "CPU already at max frequency at idle (${idle_freq} kHz)"
            log_warn "Method 2 SKIP: frequency cannot increase further; decay test not meaningful"
            log_warn "  This may be due to performance governor override or thermal state"
            method2_ran="false"
        else
            # --- Spawn CPU-bound load ---
            log_info "Spawning CPU-bound load task (3 seconds)..."
            ( i=0; while true; do i=$((i + 1)); done ) &
            LOAD_PID=$!

            sleep 3

            # --- Read frequency under load ---
            load_freq=$(cat "$cur_freq_file" 2>/dev/null)
            log_info "Frequency under load: ${load_freq} kHz"

            # --- Kill load and wait for PELT decay ---
            kill "$LOAD_PID" 2>/dev/null || true
            LOAD_PID=""
            log_info "Load task killed. Waiting 2 seconds for PELT decay..."
            sleep 2

            # --- Read post-decay frequency ---
            postdecay_freq=$(cat "$cur_freq_file" 2>/dev/null)
            log_info "Post-decay frequency: ${postdecay_freq} kHz"

            # --- Evaluate ---
            log_info "--- Method 2 Evaluation ---"
            log_info "  idle=${idle_freq}  load=${load_freq}  post_decay=${postdecay_freq} kHz"

            # Check 1: frequency must have risen under load
            if [ -n "$load_freq" ] && [ -n "$idle_freq" ] && \
               [ "$load_freq" -gt "$idle_freq" ] 2>/dev/null; then
                log_pass "  Frequency rose under load: ${idle_freq}  -  ${load_freq} kHz"
                log_pass "  schedutil responded to PELT util_avg accumulation"

                # Check 2: frequency must have dropped after load stopped
                if [ -n "$postdecay_freq" ] && \
                   [ "$postdecay_freq" -lt "$load_freq" ] 2>/dev/null; then
                    log_pass "  Frequency dropped after load: ${load_freq}  -  ${postdecay_freq} kHz"
                    log_pass "  schedutil responded to PELT util_avg decay"
                else
                    log_warn "  Frequency did not drop after load stopped"
                    log_warn "  load=${load_freq}  post_decay=${postdecay_freq} kHz"
                    log_warn "  Possible causes: rate_limit_us too high, thermal floor, or"
                    log_warn "  2s decay window insufficient for this platform's schedutil config"
                    log_info "  This is a WARNING only  -  Method 1 is the authoritative decay check"
                fi
            else
                log_warn "  Frequency did not rise under load (idle=${idle_freq} load=${load_freq} kHz)"
                log_warn "  CPU may already be at max freq, or schedutil rate_limit_us is high"
                log_info "  Method 2 inconclusive  -  not counted as failure"
            fi
        fi
    fi
fi

# ============================================================================
# Final verdict
# ============================================================================
log_info "========================================================================"
log_info "=== Final Verdict ==="
log_info "========================================================================"

if [ "$method1_ran" = "false" ] && [ "$method2_ran" = "false" ]; then
    log_warn "Neither Method 1 nor Method 2 could run on this platform"
    log_warn "  Method 1 requires: CONFIG_SCHED_DEBUG (/proc/$$/sched)"
    log_warn "  Method 2 requires: schedutil cpufreq governor"
    log_warn "Marking as SKIP"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
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
