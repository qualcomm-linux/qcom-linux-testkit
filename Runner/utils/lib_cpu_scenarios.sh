#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# sh -c payloads intentionally expand positional arguments in the child shell.
# shellcheck disable=SC2016

# cpu_scenario_allowed_cpus
# Intersect runtime-online CPUs with the current process's permitted CPU set.
cpu_scenario_allowed_cpus() (
    allowed=$(awk '/^Cpus_allowed_list:/ { print $2 }' /proc/self/status)
    [ -n "$allowed" ] || exit 1
    online=$(get_online_cpus)
    allowed=$(expand_cpu_list "$allowed")
    printf '%s\n' "$online" | awk -v allowed="$allowed" '
        BEGIN { n = split(allowed, list, /[[:space:]]+/); for (i = 1; i <= n; i++) permitted[list[i]] = 1 }
        $1 in permitted { print $1 }
    '
)

# cpu_scenario_restore_policies
# Restore saved limits, governor and a readable userspace speed in safe order.
cpu_scenario_restore_policies() {
    local policy saved low high governor ceiling speed failed=0
    for saved in "$SCENARIO_DIR"/policies/*; do
        [ -f "$saved/changed" ] || continue
        policy=$(cat "$saved/path")
        low=$(cat "$saved/min")
        high=$(cat "$saved/max")
        governor=$(cat "$saved/governor")
        ceiling=$(cat "$policy/cpuinfo_max_freq")
        if ! scenario_command "restore-${policy##*/}" sh -c '
            printf "%s\n" "$2" >"$1/scaling_max_freq" &&
            printf "%s\n" "$3" >"$1/scaling_min_freq" &&
            printf "%s\n" "$4" >"$1/scaling_max_freq" &&
            printf "%s\n" "$5" >"$1/scaling_governor"
        ' sh "$policy" "$ceiling" "$low" "$high" "$governor"; then
            failed=1
            continue
        fi
        speed=$(cat "$saved/speed")
        if [ "$governor" = userspace ] && scenario_positive_integer "$speed" 100000000; then
            scenario_command "restore-speed-${policy##*/}" sh -c \
                'printf "%s\n" "$2" >"$1/scaling_setspeed"' sh "$policy" "$speed" || failed=1
        fi
        if [ "$(cat "$policy/scaling_min_freq")" != "$low" ] ||
           [ "$(cat "$policy/scaling_max_freq")" != "$high" ] ||
           [ "$(cat "$policy/scaling_governor")" != "$governor" ]; then
            failed=1
        fi
    done
    [ "$failed" -eq 0 ]
}

# cpu_scenario_set_frequency <policy> <frequency>
# Widen bounds safely before selecting an image-supported frequency.
cpu_scenario_set_frequency() {
    # Register before the first write so partial changes are restored too.
    : >"$SCENARIO_DIR/policies/${1##*/}/changed" || return 1
    scenario_command "set-${1##*/}-$2" sh -c '
        printf "%s\n" "$3" >"$1/scaling_max_freq" &&
        printf "%s\n" "$4" >"$1/scaling_min_freq" &&
        printf "userspace\n" >"$1/scaling_governor" &&
        printf "%s\n" "$2" >"$1/scaling_setspeed"
    ' sh "$1" "$2" "$(cat "$1/cpuinfo_max_freq")" "$(cat "$1/cpuinfo_min_freq")"
}

# cpu_scenario_frequency_samples <policy> <cpu> <frequency> <label>
# Read several samples on a busy policy CPU and retain the feedback provider.
cpu_scenario_frequency_samples() {
    local policy="$1" cpu="$2" requested="$3" label="$4" source failed=0
    source="$policy/cpuinfo_cur_freq"
    if ! scenario_positive_integer "$(cat "$source" 2>/dev/null)" 100000000; then
        source="$policy/scaling_cur_freq"
    fi
    if ! scenario_command "$label" taskset -c "$cpu" sh -c '
        sample=0
        while [ "$sample" -lt "$2" ]; do
            busy=0
            while [ "$busy" -lt 10000 ]; do
                busy=$((busy + 1))
            done
            cat "$1" || exit 1
            sleep 0.2
            sample=$((sample + 1))
        done
    ' sh "$source" "$SCENARIO_SAMPLES"; then
        test_result_record FAIL "$label could not read policy feedback"
        return 1
    fi
    if ! awk -v target="$requested" -v tolerance="$SCENARIO_TOLERANCE" \
        -v expected="$SCENARIO_SAMPLES" '
        {
            count++
            if ($0 !~ /^[0-9]+$/ || $1 <= 0 || $1 > 100000000) bad = 1
            difference = $1 - target
            if (difference < 0) difference = -difference
            if (difference * 100 > target * tolerance) bad = 1
        }
        END { exit bad || count != expected }
    ' "$SCENARIO_DIR/$label.log"; then
        failed=1
    fi
    if [ "$failed" -eq 0 ]; then
        # shellcheck disable=SC2034 # Required by scenario_finish.
        SCENARIO_VALIDATED=1
        test_result_record PASS "$label repeated feedback within ${SCENARIO_TOLERANCE}% of $requested kHz, provider=${source##*/}"
    else
        test_result_record FAIL "$label frequency feedback differs from request=$requested kHz, provider=${source##*/}"
    fi
    return "$failed"
}

# cpu_scenario_timed_loop <cpu> <iterations> <label>
# Measure a fixed pinned workload using monotonic procfs time, no Python needed.
cpu_scenario_timed_loop() {
    scenario_command "$3" taskset -c "$1" sh -c '
        start=$(awk "{print int(\$1 * 100)}" /proc/uptime)
        iteration=0
        while [ "$iteration" -lt "$1" ]; do
            iteration=$((iteration + 1))
        done
        end=$(awk "{print int(\$1 * 100)}" /proc/uptime)
        printf "%s\n" "$((end - start))"
    ' sh "$2"
}

# cpu_scenario_cpufreq
# Exercise dynamically discovered policies with repeated feedback and load.
cpu_scenario_cpufreq() {
    local policy saved lo hi cpu peer first low_ticks high_ticks iterations ratio_error count=0 source allowed
    if [ "$SCENARIO_EXERCISE" != 1 ]; then
        test_result_record SKIP "Frequency changes require --exercise, policy limits will be restored"
        return
    fi
    scenario_require taskset awk sort || return 0
    allowed=$(cpu_scenario_allowed_cpus)
    if [ -z "$allowed" ]; then
        test_result_record SKIP "No runtime-online CPU is permitted by the process affinity/cpuset"
        return 0
    fi
    mkdir -p "$SCENARIO_DIR/policies" || return 1
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$policy" ] || continue
        if [ ! -w "$policy/scaling_setspeed" ] ||
           ! grep -qw userspace "$policy/scaling_available_governors"; then
            test_result_record SKIP "${policy##*/} has no writable userspace-governor control"
            continue
        fi
        saved="$SCENARIO_DIR/policies/${policy##*/}"
        mkdir -p "$saved" || return 1
        printf '%s\n' "$policy" >"$saved/path"
        cat "$policy/scaling_min_freq" >"$saved/min" || return 1
        cat "$policy/scaling_max_freq" >"$saved/max" || return 1
        cat "$policy/scaling_governor" >"$saved/governor" || return 1
        cat "$policy/scaling_setspeed" >"$saved/speed" 2>/dev/null || true
        count=$((count + 1))
    done
    # shellcheck disable=SC2034 # Consumed by lib_scenario.sh.
    SCENARIO_CLEANUP=cpu_scenario_restore_policies
    if [ "$count" = 0 ]; then
        test_result_record SKIP "No runtime cpufreq policy exposes writable userspace controls and a frequency table"
        return 0
    fi
    for saved in "$SCENARIO_DIR"/policies/*; do
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
        if ! scenario_positive_integer "$lo" 100000000 || ! scenario_positive_integer "$hi" 100000000; then
            test_result_record SKIP "${policy##*/} exposes no discrete frequency table"
            continue
        fi
        # Lower all other controllable policies, without a board/rail mapping.
        for peer in "$SCENARIO_DIR"/policies/*; do
            [ -d "$peer" ] || continue
            if [ "$peer" != "$saved" ]; then
                peer=$(cat "$peer/path")
                first=$(tr ' ' '\n' <"$peer/scaling_available_frequencies" | \
                    awk '/^[0-9]+$/ && $1 > 0' | sort -n | head -n 1)
                if scenario_positive_integer "$first" 100000000; then
                    if ! cpu_scenario_set_frequency "$peer" "$first"; then
                        test_result_record FAIL "Cannot coordinate peer policy=${peer##*/}"
                        return 1
                    fi
                fi
            fi
        done
        if ! cpu_scenario_set_frequency "$policy" "$lo"; then
            test_result_record FAIL "${policy##*/} rejected supported low frequency=$lo"
            return 1
        fi
        sleep 1
        cpu_scenario_frequency_samples "$policy" "$cpu" "$lo" "${policy##*/}-min" || true
        if ! cpu_scenario_set_frequency "$policy" "$hi"; then
            test_result_record FAIL "${policy##*/} rejected supported high frequency=$hi"
            return 1
        fi
        sleep 1
        cpu_scenario_frequency_samples "$policy" "$cpu" "$hi" "${policy##*/}-max" || true
        iterations=100000
        high_ticks=0
        while :; do
            cpu_scenario_timed_loop "$cpu" "$iterations" "${policy##*/}-runtime-high" || break
            high_ticks=$(cat "$SCENARIO_DIR/${policy##*/}-runtime-high.log")
            if ! scenario_positive_integer "$high_ticks" 10000000; then
                high_ticks=0
            fi
            if [ "$high_ticks" -ge 50 ] || [ "$iterations" -ge 3200000 ]; then
                break
            fi
            iterations=$((iterations * 2))
        done
        if [ "${high_ticks:-0}" -lt 50 ]; then
            test_result_record SKIP "${policy##*/} workload timing has insufficient resolution"
        elif cpu_scenario_set_frequency "$policy" "$lo" &&
             cpu_scenario_timed_loop "$cpu" "$iterations" "${policy##*/}-runtime-low"; then
            low_ticks=$(cat "$SCENARIO_DIR/${policy##*/}-runtime-low.log")
            if scenario_positive_integer "$low_ticks" 10000000; then
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
        if [ "$SCENARIO_LOAD_SECONDS" -gt 0 ]; then
            if command -v stress-ng >/dev/null 2>&1 &&
               grep -qw schedutil "$policy/scaling_available_governors"; then
                if ! scenario_command "${policy##*/}-load-governor" sh -c \
                    'printf "schedutil\n" >"$1/scaling_governor"' sh "$policy"; then
                    test_result_record FAIL "${policy##*/} cannot select advertised schedutil governor"
                else
                    taskset -c "$cpu" stress-ng --cpu 1 --timeout "${SCENARIO_LOAD_SECONDS}s" \
                        --metrics-brief >"$SCENARIO_DIR/${policy##*/}-load.log" 2>&1 &
                    SCENARIO_LOAD_PIDS=$!
                    sleep 1
                    source="$policy/cpuinfo_cur_freq"
                    if ! scenario_positive_integer "$(cat "$source" 2>/dev/null)" 100000000; then
                        source="$policy/scaling_cur_freq"
                    fi
                    if kill -0 "$SCENARIO_LOAD_PIDS" 2>/dev/null &&
                       scenario_command "${policy##*/}-load-feedback" taskset -c "$cpu" sh -c '
                            sample=0
                            while [ "$sample" -lt "$2" ]; do
                                cat "$1" || exit 1
                                sleep 0.2
                                sample=$((sample + 1))
                            done
                        ' sh "$source" "$SCENARIO_SAMPLES" &&
                       awk -v minimum="$lo" -v maximum="$hi" '
                            /^[0-9]+$/ && $1 > minimum && $1 <= maximum { scaled = 1 }
                            !/^[0-9]+$/ || $1 < minimum || $1 > maximum { bad = 1 }
                            END { exit bad || !scaled }
                        ' "$SCENARIO_DIR/${policy##*/}-load-feedback.log"; then
                        test_result_record PASS "${policy##*/} frequency rose above its minimum under load"
                    else
                        test_result_record FAIL "${policy##*/} load did not produce valid scaling feedback"
                    fi
                    # The workload is deliberately bounded, stop it before moving
                    # to another policy rather than waiting on an unbounded child.
                    if ! kill_process "$SCENARIO_LOAD_PIDS"; then
                        test_result_record FAIL "${policy##*/} load worker could not be stopped"
                        return 1
                    fi
                    SCENARIO_LOAD_PIDS=""
                fi
            else
                test_result_record SKIP "${policy##*/} load phase requires image-provided stress-ng and schedutil"
            fi
        fi
    done
}

# cpu_scenario_hotplug_restore
# Stop owned load workers, restore the initial online mask and verify it.
cpu_scenario_hotplug_restore() {
    local cpu pid failed=0
    for pid in ${SCENARIO_RACE_PIDS:-}; do
        kill_process "$pid" || failed=1
    done
    SCENARIO_RACE_PIDS=""
    for cpu in $CPU_HOTPLUG_OFFLINED_CPUS; do
        if ! cpu_hotplug_in_online_mask "$cpu"; then
            if ! scenario_command "restore-cpu$cpu" sh -c \
                '
                    . "$1"
                    cpu_hotplug_write_state "$2" 1 restore "$3"
                ' \
                sh "$TOOLS/functestlib.sh" "$cpu" "$SCENARIO_DIR"; then
                failed=1
            fi
        fi
    done
    [ "$(get_online_cpus)" = "$SCENARIO_INITIAL_CPUS" ] || failed=1
    [ "$failed" -eq 0 ]
}

# cpu_scenario_hotplug_transition <cpu> <0|1> <label>
# Reuse bounded state writes and require sysfs plus scheduler-mask readback.
cpu_scenario_hotplug_transition() {
    local cpu="$1" state="$2" label="$3"
    if [ "$state" = 0 ]; then
        cpu_hotplug_record_offlined_cpu "$cpu"
    fi
    if ! scenario_command "$label" sh -c \
        '
            . "$1"
            cpu_hotplug_write_state "$2" "$3" "$4" "$5"
        ' \
        sh "$TOOLS/functestlib.sh" "$cpu" "$state" "$label" "$SCENARIO_DIR"; then
        return 1
    fi
    [ "$(cpu_hotplug_read_state "$cpu")" = "$state" ] || return 1
    if [ "$state" = 1 ]; then
        cpu_hotplug_in_online_mask "$cpu" && cpu_is_schedulable "$cpu"
    else
        ! cpu_hotplug_in_online_mask "$cpu"
    fi
}

# cpu_scenario_hotplug
# Perform loaded rounds and batch/concurrent transitions while keeping one CPU.
cpu_scenario_hotplug() {
    local cpu anchor round targets="" pid pids="" failed=0 allowed
    if [ "$SCENARIO_EXERCISE" != 1 ]; then
        test_result_record SKIP "CPU state changes require --exercise"
        return
    fi
    scenario_require taskset || return 0
    SCENARIO_INITIAL_CPUS=$(get_online_cpus)
    allowed=$(cpu_scenario_allowed_cpus)
    anchor=$(printf '%s\n' "$allowed" | head -n 1)
    if [ -z "$anchor" ]; then
        test_result_record SKIP "No permitted online CPU can be retained during hotplug"
        return 0
    fi
    cpu_hotplug_reset_registry
    SCENARIO_LOAD_PIDS=""
    # shellcheck disable=SC2034 # Consumed by lib_scenario.sh.
    SCENARIO_CLEANUP=cpu_scenario_hotplug_restore
    for cpu in $allowed; do
        [ "$cpu" != "$anchor" ] || continue
        if [ -w "$(cpu_hotplug_control_file "$cpu")" ]; then
            targets="$targets $cpu"
        fi
    done
    if [ -z "$targets" ]; then
        test_result_record SKIP "No secondary online CPU has a writable hotplug control"
        return
    fi
    if [ "$SCENARIO_LOAD_SECONDS" -gt 0 ]; then
        if ! command -v stress-ng >/dev/null 2>&1; then
            test_result_record SKIP "Loaded hotplug requires image-provided stress-ng"
            return
        fi
        stress-ng --cpu 0 --timeout "${SCENARIO_LOAD_SECONDS}s" --metrics-brief \
            >"$SCENARIO_DIR/hotplug-load.log" 2>&1 &
        SCENARIO_LOAD_PIDS=$!
        sleep 1
        if ! kill -0 "$SCENARIO_LOAD_PIDS" 2>/dev/null; then
            test_result_record FAIL "Load worker exited before hotplug validation"
            return 1
        fi
    fi
    scenario_capture_kernel kernel-before || true
    round=1
    while [ "$round" -le "$SCENARIO_ROUNDS" ]; do
        for cpu in $targets; do
            if cpu_scenario_hotplug_transition "$cpu" 0 "round$round-cpu$cpu-offline" &&
               cpu_scenario_hotplug_transition "$cpu" 1 "round$round-cpu$cpu-online"; then
                # shellcheck disable=SC2034 # Required by scenario_finish.
                SCENARIO_VALIDATED=1
                test_result_record PASS "CPU$cpu offline/online round=$round"
            else
                test_result_record FAIL "CPU$cpu hotplug failed in round=$round"
                return 1
            fi
        done
        round=$((round + 1))
    done
    if [ "$SCENARIO_BATCH" = 1 ]; then
        for cpu in $targets; do
            if ! cpu_scenario_hotplug_transition "$cpu" 0 "batch-cpu$cpu-offline"; then
                test_result_record FAIL "Batch offline failed on CPU$cpu"
                return 1
            fi
        done
        if ! cpu_hotplug_in_online_mask "$anchor"; then
            test_result_record FAIL "Batch hotplug lost retained CPU$anchor"
        else
            test_result_record PASS "All controllable secondary CPUs offlined together"
        fi
        for cpu in $targets; do
            cpu_scenario_hotplug_transition "$cpu" 1 "batch-cpu$cpu-online" || failed=1
        done
        if [ "$failed" -ne 0 ]; then
            test_result_record FAIL "Batch hotplug failed to restore secondary CPUs"
            return 1
        fi
    fi
    if [ "$SCENARIO_CONCURRENT" = 1 ]; then
        for cpu in $targets; do
            cpu_hotplug_record_offlined_cpu "$cpu"
            (
                trap - EXIT INT TERM
                trap '
                    managed_timeout_cancel_bounded 2
                    exit 1
                ' INT TERM
                round=1
                while [ "$round" -le "$SCENARIO_ROUNDS" ]; do
                    cpu_scenario_hotplug_transition "$cpu" 0 "race$round-cpu$cpu-offline" &&
                    cpu_scenario_hotplug_transition "$cpu" 1 "race$round-cpu$cpu-online" || exit 1
                    round=$((round + 1))
                done
            ) >"$SCENARIO_DIR/race-cpu$cpu.log" 2>&1 &
            pid=$!
            pids="$pids $pid"
            SCENARIO_RACE_PIDS="$pids"
        done
        for pid in $pids; do
            wait "$pid" || failed=1
        done
        SCENARIO_RACE_PIDS=""
        if [ "$failed" -eq 0 ]; then
            test_result_record PASS "Concurrent hotplug completed on discovered secondary CPUs"
        else
            test_result_record FAIL "Concurrent hotplug failed, artifacts=$SCENARIO_DIR/race-cpu*.log"
        fi
    fi
    if [ "$SCENARIO_LOAD_SECONDS" -gt 0 ] && ! kill -0 "$SCENARIO_LOAD_PIDS" 2>/dev/null; then
        test_result_record FAIL "Load ended before all hotplug phases completed, increase --load-seconds"
    fi
    scenario_capture_kernel kernel-after || true
    scenario_kernel_delta kernel-before kernel-after \
        'BUG:|WARNING:|Oops:|panic|Call trace:|psci.*(fail|error)|CPU[0-9]+.*failed' || true
}
