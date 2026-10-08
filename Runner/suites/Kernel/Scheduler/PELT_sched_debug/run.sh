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

TESTNAME="PELT_sched_debug"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "================================================================================"
log_info "============ Starting $TESTNAME Testcase ======================================="
log_info "================================================================================"
log_info "Validates the scheduler debugfs interface used to inspect PELT state"

if ! check_dependencies grep awk cat id mount basename; then
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi


pass="true"

SCHED_DEBUG_DIR="/sys/kernel/debug/sched"

# ---------------------------------------------------------------------------
# Ensure debugfs is mounted; attempt to mount if root and not present
# ---------------------------------------------------------------------------
log_info "=== debugfs Mount Check ==="

if ! grep -qE "debugfs /sys/kernel/debug" /proc/mounts 2>/dev/null; then
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
        log_info "debugfs not mounted  -  attempting to mount..."
        if mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null; then
            log_info "debugfs mounted successfully"
        else
            log_warn "Could not mount debugfs  -  scheduler debug checks will be skipped"
            echo "$TESTNAME SKIP" > "$res_file"
            exit 0
        fi
    else
        log_warn "debugfs not mounted -  skipping"
        echo "$TESTNAME SKIP" > "$res_file"
        exit 0
    fi
else
    log_info "debugfs is mounted at /sys/kernel/debug"
fi

# ---------------------------------------------------------------------------
# /sys/kernel/debug/sched directory
# ---------------------------------------------------------------------------
log_info "=== Scheduler Debugfs Directory ==="

if [ ! -d "$SCHED_DEBUG_DIR" ]; then
    log_fail "$SCHED_DEBUG_DIR not found"
    log_warn "Enable CONFIG_SCHED_DEBUG in the kernel"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

log_pass "Scheduler debugfs present: $SCHED_DEBUG_DIR"

# List all entries for reference
log_info "Contents of $SCHED_DEBUG_DIR:"
for entry in "$SCHED_DEBUG_DIR"/*; do
    [ -e "$entry" ] || continue
    entry_name=$(basename "$entry")
    if [ -d "$entry" ]; then
        log_info "  [dir]  $entry_name"
    else
        log_info "  [file] $entry_name"
    fi
done

# ---------------------------------------------------------------------------
# /sys/kernel/debug/sched/features  -  scheduler feature flags
# ---------------------------------------------------------------------------
log_info "=== Scheduler Feature Flags ==="

if [ -f "$SCHED_DEBUG_DIR/features" ]; then
    sched_features=$(cat "$SCHED_DEBUG_DIR/features" 2>/dev/null)
    log_pass "sched/features readable"
    log_info "Active features: $sched_features"

    # PELT-relevant feature flags
    for feat in GENTLE_FAIR_SLEEPERS START_DEBIT NEXT_BUDDY LAST_BUDDY \
                CACHE_HOT_BUDDY WAKEUP_PREEMPTION UTIL_EST \
                NONTASK_CAPACITY TTWU_QUEUE; do
        if printf '%s\n' "$sched_features" | grep -q "$feat"; then
            log_pass "  $feat: active"
        else
            log_info "  $feat: not active"
        fi
    done
else
    log_warn "$SCHED_DEBUG_DIR/features not readable (may need CONFIG_SCHED_DEBUG)"
fi

# ---------------------------------------------------------------------------
# /sys/kernel/debug/sched/domains  -  scheduling domain topology
# ---------------------------------------------------------------------------
log_info "=== Scheduling Domains ==="

if [ -d "$SCHED_DEBUG_DIR/domains" ]; then
    log_pass "sched/domains present"
    total_domains=0

    for cpu_dir in "$SCHED_DEBUG_DIR/domains"/cpu*; do
        [ -d "$cpu_dir" ] || continue
        cpu_name=$(basename "$cpu_dir")

        for dom_dir in "$cpu_dir"/domain*; do
            [ -d "$dom_dir" ] || continue
            dom_name=$(basename "$dom_dir")
            total_domains=$((total_domains + 1))

            # Log key domain properties relevant to PELT load balancing
            for prop in name flags min_interval max_interval busy_factor \
                        imbalance_pct cache_nice_tries; do
                prop_file="$dom_dir/$prop"
                if [ -f "$prop_file" ]; then
                    val=$(cat "$prop_file" 2>/dev/null)
                    log_info "  $cpu_name/$dom_name/$prop = $val"
                fi
            done
        done
    done

    if [ "$total_domains" -gt 0 ]; then
        log_pass "Found $total_domains scheduling domain entries"
    else
        log_warn "No domain entries found under sched/domains"
    fi
else
    log_warn "sched/domains not present (may be kernel version dependent)"
fi

# ---------------------------------------------------------------------------
# /proc/self/sched  -  per-task PELT detail (requires CONFIG_SCHED_DEBUG)
# ---------------------------------------------------------------------------
log_info "=== Per-Task PELT Detail (/proc/self/sched) ==="

if [ -f /proc/self/sched ]; then
    log_pass "/proc/self/sched present"

    # Extract key PELT fields
    for field in "se.load.weight" "se.avg.load_avg" "se.avg.util_avg" \
                 "se.avg.runnable_avg" "nr_voluntary_switches" \
                 "nr_involuntary_switches" "policy" "prio"; do
        val=$(grep "^${field}" /proc/self/sched 2>/dev/null | awk '{print $NF}')
        if [ -n "$val" ]; then
            log_info "  $field = $val"
        fi
    done
else
    log_warn "/proc/self/sched not present (CONFIG_SCHED_DEBUG may be disabled)"
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
