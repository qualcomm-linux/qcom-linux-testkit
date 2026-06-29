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

TESTNAME="PELT_load_tracking"
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
log_info "Functional validation: PELT tracks CPU utilization under real scheduler load"

if ! check_dependencies grep awk cat; then
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

pass="true"

# ---------------------------------------------------------------------------
# Prerequisite: /proc/schedstat must be present
# ---------------------------------------------------------------------------
if [ ! -f /proc/schedstat ]; then
    log_fail "/proc/schedstat not found  -  cannot perform PELT load tracking test"
    log_warn "Enable CONFIG_SCHEDSTATS in the kernel"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# Helper: sum rq_cpu_time (field 8) across all CPU lines  -  total ns on-CPU
get_total_rq_cpu_time() {
    awk '/^cpu[0-9]/ {sum += $8} END {print sum+0}' /proc/schedstat
}

# Helper: sum run_delay (field 9)  -  total ns waiting in runqueue
get_total_run_delay() {
    awk '/^cpu[0-9]/ {sum += $9} END {print sum+0}' /proc/schedstat
}

# Helper: sum pcount (field 10)  -  total scheduling events
get_total_pcount() {
    awk '/^cpu[0-9]/ {sum += $10} END {print sum+0}' /proc/schedstat
}

# ---------------------------------------------------------------------------
# Baseline snapshot
# ---------------------------------------------------------------------------
log_info "=== Baseline PELT Snapshot ==="

baseline_runtime=$(get_total_rq_cpu_time)
baseline_delay=$(get_total_run_delay)
baseline_pcount=$(get_total_pcount)
baseline_load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)

log_info "  rq_cpu_time : ${baseline_runtime} ns"
log_info "  run_delay   : ${baseline_delay} ns"
log_info "  pcount      : ${baseline_pcount}"
log_info "  loadavg(1m) : ${baseline_load}"

# ---------------------------------------------------------------------------
# Spawn CPU-bound load (POSIX busy loop  -  no bashisms)
# PELT half-life ~32 ms; 3 seconds is more than enough to accumulate load
# ---------------------------------------------------------------------------
log_info "=== Spawning CPU-bound task (3 seconds) ==="

( i=0; while true; do i=$((i + 1)); done ) &
LOAD_PID=$!
log_info "Load task PID: $LOAD_PID"

sleep 3

# ---------------------------------------------------------------------------
# Post-load snapshot (before killing the task)
# ---------------------------------------------------------------------------
log_info "=== Post-load PELT Snapshot ==="

postload_runtime=$(get_total_rq_cpu_time)
postload_delay=$(get_total_run_delay)
postload_pcount=$(get_total_pcount)
postload_load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)

log_info "  rq_cpu_time : ${postload_runtime} ns"
log_info "  run_delay   : ${postload_delay} ns"
log_info "  pcount      : ${postload_pcount}"
log_info "  loadavg(1m) : ${postload_load}"

# Kill load task now  -  before evaluating results
kill "$LOAD_PID" 2>/dev/null || true
LOAD_PID=""

# ---------------------------------------------------------------------------
# Evaluate: rq_cpu_time must have increased
# ---------------------------------------------------------------------------
log_info "=== PELT Load Tracking Evaluation ==="

if [ "$postload_runtime" -gt "$baseline_runtime" ] 2>/dev/null; then
    delta_runtime=$((postload_runtime - baseline_runtime))
    log_pass "rq_cpu_time increased by ${delta_runtime} ns  -  PELT is tracking CPU utilization"
else
    log_fail "rq_cpu_time did not increase (baseline=${baseline_runtime} post=${postload_runtime})"
    log_fail "PELT is not accounting CPU run time correctly"
    pass="false"
fi

# pcount (scheduling events) must have increased
if [ "$postload_pcount" -gt "$baseline_pcount" ] 2>/dev/null; then
    delta_pcount=$((postload_pcount - baseline_pcount))
    log_pass "pcount increased by ${delta_pcount}  -  scheduler dispatched new tasks"
else
    log_warn "pcount did not increase (baseline=${baseline_pcount} post=${postload_pcount})"
fi

# Per-CPU breakdown after load
log_info "--- Per-CPU rq_cpu_time after load ---"
while IFS= read -r line; do
    case "$line" in
        cpu[0-9]*)
            cpu_id=$(printf '%s\n' "$line" | awk '{print $1}')
            cpu_rt=$(printf '%s\n' "$line" | awk '{print $8}')
            log_info "  $cpu_id: rq_cpu_time=${cpu_rt} ns"
            ;;
    esac
done < /proc/schedstat

# ---------------------------------------------------------------------------
# Load average check (PELT-derived  -  may lag due to 1-min window)
# ---------------------------------------------------------------------------
log_info "=== Load Average Check ==="
log_info "  Baseline loadavg(1m): $baseline_load"
log_info "  Post-load loadavg(1m): $postload_load"
log_info "  Note: 1-min load average has a long decay window; immediate change not guaranteed"

if [ "$pass" = "true" ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
