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

TESTNAME="CPUFreq_Policy_Stress"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

TEST_RUN_TIMEOUT="60"
TEST_RUN_EXERCISE="0"
TEST_RUN_SAMPLES="5"
TEST_RUN_TOLERANCE="5"
TEST_RUN_LOAD_SECONDS="0"

# usage
# Show the suite options and safe defaults.
usage() {
    cat <<EOF
Usage: $0 [options]
Repeated policy frequency feedback, peer-policy coordination and pinned workload timing.
  --timeout <value> (default: 60)
  --exercise <value> (default: 0)
  --samples <value> (default: 5)
  --tolerance-percent <value> (default: 5)
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
            --samples)
                TEST_RUN_SAMPLES="$2"
                ;;
            --tolerance-percent)
                TEST_RUN_TOLERANCE="$2"
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
        is_bounded_positive_integer "$TEST_RUN_SAMPLES" 10
    }; then
        test_result_record FAIL "Invalid value for --samples: $TEST_RUN_SAMPLES"
        test_result_finish
    fi
    if ! {
        is_bounded_positive_integer "$TEST_RUN_TOLERANCE" 50
    }; then
        test_result_record FAIL "Invalid value for --tolerance-percent: $TEST_RUN_TOLERANCE"
        test_result_finish
    fi
    if ! {
        [ "$TEST_RUN_LOAD_SECONDS" = 0 ] || is_bounded_positive_integer "$TEST_RUN_LOAD_SECONDS" 300
    }; then
        test_result_record FAIL "Invalid value for --load-seconds: $TEST_RUN_LOAD_SECONDS"
        test_result_finish
    fi
}

parse_args "$@"
test_run_start

# ---------- Runtime validation ----------
count=0
if [ "$TEST_RUN_EXERCISE" != 1 ]; then
    test_result_record SKIP "Frequency changes require --exercise, policy limits will be restored"
    test_run_finish
fi
test_require_commands taskset awk sort || test_run_finish
allowed=$(cpu_allowed_cpus)
if [ -z "$allowed" ]; then
    test_result_record SKIP "No runtime-online CPU is permitted by the process affinity/cpuset"
    test_run_finish
fi
mkdir -p "$TEST_RUN_DIR/policies" || test_run_finish FAIL "CPUFreq_Policy_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    if [ ! -w "$policy/scaling_setspeed" ] ||
       ! grep -qw userspace "$policy/scaling_available_governors"; then
        test_result_record SKIP "${policy##*/} has no writable userspace-governor control"
        continue
    fi
    saved="$TEST_RUN_DIR/policies/${policy##*/}"
    mkdir -p "$saved" || test_run_finish FAIL "CPUFreq_Policy_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
    printf '%s\n' "$policy" >"$saved/path"
    cat "$policy/scaling_min_freq" >"$saved/min" || test_run_finish FAIL "CPUFreq_Policy_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
    cat "$policy/scaling_max_freq" >"$saved/max" || test_run_finish FAIL "CPUFreq_Policy_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
    cat "$policy/scaling_governor" >"$saved/governor" || test_run_finish FAIL "CPUFreq_Policy_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
    cat "$policy/scaling_setspeed" >"$saved/speed" 2>/dev/null || true
    count=$((count + 1))
done
# shellcheck disable=SC2034 # Consumed by test_run_cleanup in functestlib.sh.
TEST_RUN_CLEANUP=cpu_restore_policies
if [ "$count" = 0 ]; then
    test_result_record SKIP "No runtime cpufreq policy exposes writable userspace controls and a frequency table"
    test_run_finish
fi
for saved in "$TEST_RUN_DIR"/policies/*; do
    [ -d "$saved" ] || continue
    policy=$(cat "$saved/path")
    cpu=$(awk -v allowed="$allowed" '
        BEGIN { n = split(allowed, list, /[[:space:]]+/); for (i = 1; i <= n; i++) permitted[list[i]] = 1 }
        { for (i = 1; i <= NF; i++) if ($i in permitted) { print $i; exit } }
    ' "$policy/affected_cpus")
    case "$cpu" in
        ''|*[!0-9]*)
            test_result_record SKIP "${policy##*/} has no valid online affected CPU"
            continue
            ;;
    esac
    first=$(tr ' ' '\n' <"$policy/scaling_available_frequencies" | \
        awk '/^[0-9]+$/ && $1 > 0' | sort -n)
    lo=$(printf '%s\n' "$first" | head -n 1)
    hi=$(printf '%s\n' "$first" | tail -n 1)
    if ! is_bounded_positive_integer "$lo" 100000000 || ! is_bounded_positive_integer "$hi" 100000000; then
        test_result_record SKIP "${policy##*/} exposes no discrete frequency table"
        continue
    fi
    # Lower all other controllable policies, without a board/rail mapping.
    for peer in "$TEST_RUN_DIR"/policies/*; do
        [ -d "$peer" ] || continue
        if [ "$peer" != "$saved" ]; then
            peer=$(cat "$peer/path")
            first=$(tr ' ' '\n' <"$peer/scaling_available_frequencies" | \
                awk '/^[0-9]+$/ && $1 > 0' | sort -n | head -n 1)
            if is_bounded_positive_integer "$first" 100000000; then
                if ! cpu_set_frequency "$peer" "$first"; then
                    test_result_record FAIL "Cannot coordinate peer policy=${peer##*/}"
                    test_run_finish FAIL "CPUFreq_Policy_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
                fi
            fi
        fi
    done
    for range in min max; do
        if [ "$range" = min ]; then
            requested="$lo"
        else
            requested="$hi"
        fi
        if ! cpu_set_frequency "$policy" "$requested"; then
            test_result_record FAIL "${policy##*/} rejected supported frequency=$requested"
            test_run_finish
        fi
        sleep 1
        if cpu_frequency_samples "$policy" "$cpu" "$requested" "${policy##*/}-$range" \
            "$TEST_RUN_SAMPLES" "$TEST_RUN_TOLERANCE"; then
            # shellcheck disable=SC2034 # Read by the shared test_run_finish helper.
            TEST_RUN_VALIDATED=1
            test_result_record PASS "${policy##*/}-$range repeated feedback within ${TEST_RUN_TOLERANCE}% of $requested kHz"
        else
            test_result_record FAIL "${policy##*/}-$range frequency feedback failed for request=$requested kHz, inspect settling and sample logs under $TEST_RUN_DIR"
        fi
    done
    iterations=100000
    high_ticks=0
    while :; do
        cpu_timed_loop "$cpu" "$iterations" "${policy##*/}-runtime-high" || break
        high_ticks=$(cat "$TEST_RUN_DIR/${policy##*/}-runtime-high.log")
        if ! is_bounded_positive_integer "$high_ticks" 10000000; then
            high_ticks=0
        fi
        if [ "$high_ticks" -ge 50 ] || [ "$iterations" -ge 3200000 ]; then
            break
        fi
        iterations=$((iterations * 2))
    done
    if [ "${high_ticks:-0}" -lt 50 ]; then
        test_result_record SKIP "${policy##*/} workload timing has insufficient resolution"
    elif cpu_set_frequency "$policy" "$lo" &&
         cpu_timed_loop "$cpu" "$iterations" "${policy##*/}-runtime-low"; then
        low_ticks=$(cat "$TEST_RUN_DIR/${policy##*/}-runtime-low.log")
        if is_bounded_positive_integer "$low_ticks" 10000000; then
            ratio_error=$(awk -v low="$low_ticks" -v high="$high_ticks" -v lo="$lo" -v hi="$hi" \
                'BEGIN { difference = low / high - hi / lo; if (difference < 0) difference = -difference; print difference * 100 / (hi / lo) }')
            if awk -v error="$ratio_error" 'BEGIN {exit !(error <= 35)}'; then
                test_result_record PASS "${policy##*/} pinned runtime follows frequency ratio, deviation=$ratio_error%"
            else
                test_result_record FAIL "${policy##*/} pinned runtime ratio differs by $ratio_error%"
            fi
        else
            test_result_record FAIL "${policy##*/} low-frequency timing is invalid"
        fi
    else
        test_result_record FAIL "${policy##*/} low-frequency workload could not execute"
    fi
    if [ "$TEST_RUN_LOAD_SECONDS" -gt 0 ]; then
        if grep -qw schedutil "$policy/scaling_available_governors" &&
           test_require_commands stress-ng; then
            # shellcheck disable=SC2016 # Child positional arguments expand in the bounded shell.
            if ! test_run_command "${policy##*/}-load-governor" sh -c \
                'printf "schedutil\n" >"$1/scaling_governor"' sh "$policy"; then
                test_result_record FAIL "${policy##*/} cannot select advertised schedutil governor"
            else
                taskset -c "$cpu" stress-ng --cpu 1 --timeout "${TEST_RUN_LOAD_SECONDS}s" \
                    --metrics-brief >"$TEST_RUN_DIR/${policy##*/}-load.log" 2>&1 &
                TEST_RUN_LOAD_PIDS=$!
                sleep 1
                source="$policy/cpuinfo_cur_freq"
                if ! is_bounded_positive_integer "$(cat "$source" 2>/dev/null)" 100000000; then
                    source="$policy/scaling_cur_freq"
                fi
                # shellcheck disable=SC2016 # Child positional arguments expand in the bounded shell.
                if kill -0 "$TEST_RUN_LOAD_PIDS" 2>/dev/null &&
                   test_run_command --stdout-only "${policy##*/}-load-feedback" taskset -c "$cpu" sh -c '
                        sample=0
                        while [ "$sample" -lt "$2" ]; do
                            cat "$1" || exit 1
                            sleep 0.2
                            sample=$((sample + 1))
                        done
                    ' sh "$source" "$TEST_RUN_SAMPLES" &&
                   awk -v minimum="$lo" -v maximum="$hi" '
                        /^[0-9]+$/ && $1 > minimum && $1 <= maximum { scaled = 1 }
                        !/^[0-9]+$/ || $1 < minimum || $1 > maximum { bad = 1 }
                        END { exit bad || !scaled }
                    ' "$TEST_RUN_DIR/${policy##*/}-load-feedback.log"; then
                    test_result_record PASS "${policy##*/} frequency rose above its minimum under load"
                else
                    test_result_record FAIL "${policy##*/} load did not produce valid scaling feedback"
                fi
                # The workload is deliberately bounded, stop it before moving
                # to another policy rather than waiting on an unbounded child.
                if ! kill_process "$TEST_RUN_LOAD_PIDS"; then
                    test_result_record FAIL "${policy##*/} load worker could not be stopped"
                    test_run_finish FAIL "CPUFreq_Policy_Stress could not complete, inspect artifacts=$TEST_RUN_DIR"
                fi
                TEST_RUN_LOAD_PIDS=""
            fi
        else
            test_result_record SKIP "${policy##*/} load phase requires available stress-ng and schedutil"
        fi
    fi
done
test_run_finish
