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

TESTNAME="PELT_tunables"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "================================================================================"
log_info "============ Starting $TESTNAME Testcase ======================================="
log_info "================================================================================"
log_info "Validates CFS/PELT scheduler tunables in /proc/sys/kernel/"

if ! check_dependencies grep awk cat; then
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi


pass="true"

SYSCTL_DIR="/proc/sys/kernel"

# ---------------------------------------------------------------------------
# Core CFS timing tunables  -  must be present and non-zero
# ---------------------------------------------------------------------------
log_info "=== Core CFS Timing Tunables ==="

for tunable in sched_min_granularity_ns sched_latency_ns sched_wakeup_granularity_ns; do
    path="$SYSCTL_DIR/$tunable"
    if [ -f "$path" ]; then
        val=$(cat "$path" 2>/dev/null)
        if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
            log_pass "  $tunable = $val ns"
        else
            log_fail "  $tunable is zero or unreadable (val='$val')"
            pass="false"
        fi
    else
        log_warn "  $tunable not found at $path  (kernel/config dependent)"
    fi
done

# Validate ordering: latency >= min_granularity (CFS invariant)
lat_path="$SYSCTL_DIR/sched_latency_ns"
gran_path="$SYSCTL_DIR/sched_min_granularity_ns"
if [ -f "$lat_path" ] && [ -f "$gran_path" ]; then
    lat=$(cat "$lat_path" 2>/dev/null)
    gran=$(cat "$gran_path" 2>/dev/null)
    if [ -n "$lat" ] && [ -n "$gran" ] && [ "$lat" -ge "$gran" ] 2>/dev/null; then
        log_pass "  sched_latency_ns ($lat) >= sched_min_granularity_ns ($gran)  -  CFS invariant holds"
    else
        log_fail "  CFS invariant violated: sched_latency_ns ($lat) < sched_min_granularity_ns ($gran)"
        pass="false"
    fi
fi

# ---------------------------------------------------------------------------
# Migration cost tunable
# ---------------------------------------------------------------------------
log_info "=== Migration Cost Tunable ==="

mig_path="$SYSCTL_DIR/sched_migration_cost_ns"
if [ -f "$mig_path" ]; then
    val=$(cat "$mig_path" 2>/dev/null)
    log_pass "  sched_migration_cost_ns = $val ns"
else
    log_warn "  sched_migration_cost_ns not found (optional)"
fi

# ---------------------------------------------------------------------------
# PELT util clamp tunables (kernel >= 5.3, uclamp)
# ---------------------------------------------------------------------------
log_info "=== PELT Utilization Clamp Tunables (uclamp) ==="

uclamp_found="false"
for tunable in sched_util_clamp_min sched_util_clamp_max; do
    path="$SYSCTL_DIR/$tunable"
    if [ -f "$path" ]; then
        val=$(cat "$path" 2>/dev/null)
        log_pass "  $tunable = $val"
        uclamp_found="true"
    else
        log_info "  $tunable not present (requires CONFIG_UCLAMP_TASK, kernel >= 5.3)"
    fi
done

if [ "$uclamp_found" = "true" ]; then
    # Validate: clamp_min <= clamp_max
    min_path="$SYSCTL_DIR/sched_util_clamp_min"
    max_path="$SYSCTL_DIR/sched_util_clamp_max"
    if [ -f "$min_path" ] && [ -f "$max_path" ]; then
        umin=$(cat "$min_path" 2>/dev/null)
        umax=$(cat "$max_path" 2>/dev/null)
        if [ -n "$umin" ] && [ -n "$umax" ] && [ "$umin" -le "$umax" ] 2>/dev/null; then
            log_pass "  uclamp invariant: clamp_min ($umin) <= clamp_max ($umax)"
        else
            log_fail "  uclamp invariant violated: clamp_min ($umin) > clamp_max ($umax)"
            pass="false"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Additional scheduler tunables (informational)
# ---------------------------------------------------------------------------
log_info "=== Additional Scheduler Tunables (informational) ==="

for tunable in sched_nr_migrate sched_schedstats sched_child_runs_first \
               sched_autogroup_enabled; do
    path="$SYSCTL_DIR/$tunable"
    if [ -f "$path" ]; then
        val=$(cat "$path" 2>/dev/null)
        log_info "  $tunable = $val"
    else
        log_info "  $tunable: not present"
    fi
done

# ---------------------------------------------------------------------------
# /proc/sys/kernel/sched_domain  -  per-domain tunables (if present)
# ---------------------------------------------------------------------------
log_info "=== Per-CPU Sched Domain Tunables ==="

sched_domain_base="/proc/sys/kernel/sched_domain"
if [ -d "$sched_domain_base" ]; then
    log_info "sched_domain sysctl present: $sched_domain_base"
    for cpu_dir in "$sched_domain_base"/cpu*; do
        [ -d "$cpu_dir" ] || continue
        cpu_name=$(basename "$cpu_dir")
        for dom_dir in "$cpu_dir"/domain*; do
            [ -d "$dom_dir" ] || continue
            dom_name=$(basename "$dom_dir")
            for prop in busy_factor imbalance_pct cache_nice_tries \
                        min_interval max_interval; do
                prop_file="$dom_dir/$prop"
                if [ -f "$prop_file" ]; then
                    val=$(cat "$prop_file" 2>/dev/null)
                    log_info "  $cpu_name/$dom_name/$prop = $val"
                fi
            done
        done
    done
else
    log_info "sched_domain sysctl not present (kernel version dependent)"
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
