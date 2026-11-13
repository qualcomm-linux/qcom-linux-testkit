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
# shellcheck disable=SC1091
. "$TOOLS/lib_pkg_provider.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_performance.sh"

TESTNAME="CPU_Hotplug_Stress"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

TEST_RUN_TIMEOUT="60"
TEST_RUN_EXERCISE="0"
TEST_RUN_ROUNDS="3"
TEST_RUN_BATCH="0"
TEST_RUN_CONCURRENT="0"
TEST_RUN_LOAD_SECONDS="0"

# usage
# Show the suite options and safe defaults.
usage() {
    cat <<EOF
Usage: $0 [options]
Repeated secondary-CPU hotplug, optional batch and concurrent phases, with online-mask restoration.
  --timeout <value> (default: 60)
  --exercise <value> (default: 0)
  --rounds <value> (default: 3)
  --batch <value> (default: 0)
  --concurrent <value> (default: 0)
  --load-seconds <value> (default: 0)
  --help
EOF
}

# parse_args <arguments>...
# Reject malformed overrides before runtime discovery or state changes.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_record FAIL "Missing value for $1"
            test_result_finish
        fi
        case "$2" in
            --*)
                test_result_record FAIL "Missing value for $1 before option=$2"
                test_result_finish
                ;;
        esac
        case "$1" in
            --timeout)
                TEST_RUN_TIMEOUT="$2"
                ;;
            --exercise)
                TEST_RUN_EXERCISE="$2"
                ;;
            --rounds)
                TEST_RUN_ROUNDS="$2"
                ;;
            --batch)
                TEST_RUN_BATCH="$2"
                ;;
            --concurrent)
                TEST_RUN_CONCURRENT="$2"
                ;;
            --load-seconds)
                TEST_RUN_LOAD_SECONDS="$2"
                ;;
            *)
                test_result_record FAIL "Unknown option: $1"
                test_result_finish
                ;;
        esac
        shift 2
    done
    if ! {
        is_bounded_positive_integer "$TEST_RUN_TIMEOUT" 600
    }; then
        test_result_record FAIL "Invalid value for --timeout: $TEST_RUN_TIMEOUT"
        test_result_finish
    fi
    if ! {
        [ "$TEST_RUN_EXERCISE" = 0 ] || [ "$TEST_RUN_EXERCISE" = 1 ]
    }; then
        test_result_record FAIL "Invalid value for --exercise: $TEST_RUN_EXERCISE"
        test_result_finish
    fi
    if ! {
        is_bounded_positive_integer "$TEST_RUN_ROUNDS" 10
    }; then
        test_result_record FAIL "Invalid value for --rounds: $TEST_RUN_ROUNDS"
        test_result_finish
    fi
    if ! {
        [ "$TEST_RUN_BATCH" = 0 ] || [ "$TEST_RUN_BATCH" = 1 ]
    }; then
        test_result_record FAIL "Invalid value for --batch: $TEST_RUN_BATCH"
        test_result_finish
    fi
    if ! {
        [ "$TEST_RUN_CONCURRENT" = 0 ] || [ "$TEST_RUN_CONCURRENT" = 1 ]
    }; then
        test_result_record FAIL "Invalid value for --concurrent: $TEST_RUN_CONCURRENT"
        test_result_finish
    fi
    if ! {
        [ "$TEST_RUN_LOAD_SECONDS" = 0 ] || is_bounded_positive_integer "$TEST_RUN_LOAD_SECONDS" 3600
    }; then
        test_result_record FAIL "Invalid value for --load-seconds: $TEST_RUN_LOAD_SECONDS"
        test_result_finish
    fi
}

parse_args "$@"
test_run_start

# ---------- Runtime validation ----------
targets=""
pids=""
failed=0
if [ "$TEST_RUN_EXERCISE" != 1 ]; then
    test_result_record SKIP "CPU state changes require --exercise"
    test_run_finish
fi
test_require_commands taskset || test_run_finish
# shellcheck disable=SC2034 # Read by the shared cpu_hotplug_restore helper.
TEST_RUN_INITIAL_CPUS=$(get_online_cpus)
allowed=$(cpu_allowed_cpus)
anchor=$(printf '%s\n' "$allowed" | head -n 1)
if [ -z "$anchor" ]; then
    test_result_record SKIP "No permitted online CPU can be retained during hotplug"
    test_run_finish
fi
cpu_hotplug_reset_registry
TEST_RUN_LOAD_PIDS=""
# shellcheck disable=SC2034 # Consumed by test_run_cleanup in functestlib.sh.
TEST_RUN_CLEANUP=cpu_hotplug_restore
for cpu in $allowed; do
    [ "$cpu" != "$anchor" ] || continue
    if [ -w "$(cpu_hotplug_control_file "$cpu")" ]; then
        targets="$targets $cpu"
    fi
done
if [ -z "$targets" ]; then
    test_result_record SKIP "No secondary online CPU has a writable hotplug control"
    test_run_finish
fi
if [ "$TEST_RUN_LOAD_SECONDS" -gt 0 ]; then
    test_require_commands stress-ng || test_run_finish
    stress-ng --cpu 0 --timeout "${TEST_RUN_LOAD_SECONDS}s" --metrics-brief \
        >"$TEST_RUN_DIR/hotplug-load.log" 2>&1 &
    TEST_RUN_LOAD_PIDS=$!
    sleep 1
    if ! kill -0 "$TEST_RUN_LOAD_PIDS" 2>/dev/null; then
        test_result_record FAIL "Load worker exited before hotplug validation"
        test_run_finish FAIL "CPU_Hotplug_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
    fi
fi
test_capture_kernel_log kernel-before || true
round=1
while [ "$round" -le "$TEST_RUN_ROUNDS" ]; do
    for cpu in $targets; do
        if cpu_hotplug_transition "$cpu" 0 "round$round-cpu$cpu-offline" &&
           cpu_hotplug_transition "$cpu" 1 "round$round-cpu$cpu-online"; then
            # shellcheck disable=SC2034 # Required by test_run_finish.
            TEST_RUN_VALIDATED=1
            test_result_record PASS "CPU$cpu offline/online round=$round"
        else
            test_result_record FAIL "CPU$cpu hotplug failed in round=$round"
            test_run_finish FAIL "CPU_Hotplug_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
        fi
    done
    round=$((round + 1))
done
if [ "$TEST_RUN_BATCH" = 1 ]; then
    for cpu in $targets; do
        if ! cpu_hotplug_transition "$cpu" 0 "batch-cpu$cpu-offline"; then
            test_result_record FAIL "Batch offline failed on CPU$cpu"
            test_run_finish FAIL "CPU_Hotplug_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
        fi
    done
    if ! cpu_hotplug_in_online_mask "$anchor"; then
        test_result_record FAIL "Batch hotplug lost retained CPU$anchor"
    else
        test_result_record PASS "All controllable secondary CPUs offlined together"
    fi
    for cpu in $targets; do
        cpu_hotplug_transition "$cpu" 1 "batch-cpu$cpu-online" || failed=1
    done
    if [ "$failed" -ne 0 ]; then
        test_result_record FAIL "Batch hotplug failed to restore secondary CPUs"
        test_run_finish FAIL "CPU_Hotplug_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
    fi
fi
if [ "$TEST_RUN_CONCURRENT" = 1 ]; then
    for cpu in $targets; do
        cpu_hotplug_record_offlined_cpu "$cpu"
        (
            trap - EXIT INT TERM
            trap '
                managed_timeout_cancel_bounded 2
                exit 1
            ' INT TERM
            round=1
            while [ "$round" -le "$TEST_RUN_ROUNDS" ]; do
                cpu_hotplug_transition "$cpu" 0 "race$round-cpu$cpu-offline" &&
                cpu_hotplug_transition "$cpu" 1 "race$round-cpu$cpu-online" || exit 1
                round=$((round + 1))
            done
        ) >"$TEST_RUN_DIR/race-cpu$cpu.log" 2>&1 &
        pid=$!
        pids="$pids $pid"
        TEST_RUN_RACE_PIDS="$pids"
    done
    for pid in $pids; do
        wait "$pid" || failed=1
    done
    # shellcheck disable=SC2034 # Read by shared test_run_cleanup on signals and exit.
    TEST_RUN_RACE_PIDS=""
    if [ "$failed" -eq 0 ]; then
        test_result_record PASS "Concurrent hotplug completed on discovered secondary CPUs"
    else
        test_result_record FAIL "Concurrent hotplug failed, artifacts=$TEST_RUN_DIR/race-cpu*.log"
    fi
fi
if [ "$TEST_RUN_LOAD_SECONDS" -gt 0 ] && ! kill -0 "$TEST_RUN_LOAD_PIDS" 2>/dev/null; then
    test_result_record FAIL "Load ended before all hotplug phases completed, increase --load-seconds"
fi
test_capture_kernel_log kernel-after || true
test_check_kernel_delta kernel-before kernel-after \
    'BUG:|WARNING:|Oops:|panic|Call trace:|psci.*(fail|error)|CPU[0-9]+.*failed' || true
test_run_finish
