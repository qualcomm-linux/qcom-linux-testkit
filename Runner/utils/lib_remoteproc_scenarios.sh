#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Child-shell expressions must retain their positional arguments unexpanded.
# shellcheck disable=SC2016

# remoteproc_scenario_inventory
# Reuse runtime enumeration, resolve stable device owners, and select by name/id.
remoteproc_scenario_inventory() {
    local path name firmware state owner token selected
    : >"$SCENARIO_DIR/remoteprocs.raw"
    list_remoteproc_instances "$SCENARIO_DIR/remoteprocs.raw" || true
    : >"$SCENARIO_DIR/remoteprocs.selected"
    while IFS='|' read -r path name firmware state; do
        [ -n "$path" ] || continue
        owner=$(readlink -f "$path/device" 2>/dev/null)
        selected=0
        if [ "$SCENARIO_PROCESSORS" = auto ]; then
            selected=1
        else
            for token in $(printf '%s\n' "$SCENARIO_PROCESSORS" | tr ',' ' '); do
                if [ "$token" = "$name" ] || [ "$token" = "${owner##*/}" ]; then
                    selected=1
                fi
            done
        fi
        if [ "$selected" = 1 ]; then
            printf '%s|%s|%s|%s|%s\n' "$path" "$name" "$firmware" "$state" "$owner" \
                >>"$SCENARIO_DIR/remoteprocs.selected"
        fi
    done <"$SCENARIO_DIR/remoteprocs.raw"
    if [ "$SCENARIO_PROCESSORS" != auto ]; then
        for token in $(printf '%s\n' "$SCENARIO_PROCESSORS" | tr ',' ' '); do
            if ! awk -F '|' -v token="$token" '
                $2 == token { found = 1 }
                { owner = $5; sub(/^.*\//, "", owner); if (owner == token) found = 1 }
                END { exit !found }
            ' "$SCENARIO_DIR/remoteprocs.selected"; then
                test_result_record FAIL "Requested processor=$token was not registered, artifact=$SCENARIO_DIR/remoteprocs.raw"
            fi
        done
    fi
    [ -s "$SCENARIO_DIR/remoteprocs.selected" ]
}

# remoteproc_scenario_readiness
# Check explicit running expectations and recovered crash evidence from one log.
remoteproc_scenario_readiness() {
    local path name firmware state owner identifier
    if ! remoteproc_scenario_inventory; then
        test_result_record SKIP "No selected runtime remoteproc, check enabled DT and firmware"
        return
    fi
    scenario_capture_kernel kernel-boot || true
    while IFS='|' read -r path name firmware state owner; do
        identifier="${path##*/} ($name, owner=${owner##*/})"
        case "$state" in
            running|attached)
                # shellcheck disable=SC2034 # Required by scenario_finish.
                SCENARIO_VALIDATED=1
                test_result_record PASS "$identifier state=$state"
                ;;
            offline)
                if [ "$SCENARIO_PROCESSORS" = auto ]; then
                    test_result_record SKIP "$identifier is offline with unconfirmed lifecycle policy, use --processors to require it running"
                else
                    test_result_record FAIL "$identifier was explicitly required but state=offline"
                fi
                ;;
            *)
                test_result_record FAIL "$identifier unexpected state=${state:-unreadable}"
                ;;
        esac
        if [ -s "$SCENARIO_DIR/kernel-boot/dmesg_snapshot.log" ]; then
            if grep -F "${path##*/}: crash detected" "$SCENARIO_DIR/kernel-boot/dmesg_snapshot.log" \
                >"$SCENARIO_DIR/${path##*/}-crashes.log"; then
                log_file_with_label REMOTEPROC-CRASH "$SCENARIO_DIR/${path##*/}-crashes.log" 20
                test_result_record FAIL "$identifier crashed since boot, including recovered crashes"
            else
                test_result_record PASS "$identifier has no retained crash report"
            fi
        else
            test_result_record SKIP "$identifier crash history is unavailable"
        fi
        log_info "[$identifier] firmware=$firmware runtime_owner=$owner"
    done <"$SCENARIO_DIR/remoteprocs.selected"
}

# remoteproc_scenario_channels <remoteproc-path>
# Snapshot stable RPMsg channel names and bound drivers, preserving multiplicity.
remoteproc_scenario_channels() (
    owner=$(readlink -f "$1/device") || exit 1
    for channel in /sys/bus/rpmsg/devices/*; do
        [ -e "$channel" ] || continue
        resolved=$(readlink -f "$channel") || continue
        case "$resolved" in
            "$owner"/*)
                ;;
            *)
                continue
                ;;
        esac
        name=$(cat "$channel/name" 2>/dev/null)
        if [ -z "$name" ]; then
            name=${channel##*/}
            name=$(printf '%s\n' "$name" | sed 's/^virtio[0-9][0-9]*\.//')
        fi
        driver=$(readlink -f "$channel/driver" 2>/dev/null)
        printf '%s|%s\n' "$name" "${driver##*/}"
    done | sort
)

# remoteproc_scenario_restore
# Restore only processors whose state this scenario changed.
remoteproc_scenario_restore() {
    local path name firmware state owner failed=0 baseline current start
    while IFS='|' read -r path name firmware state owner; do
        [ -n "$path" ] || continue
        if [ "$(cat "$path/state" 2>/dev/null)" != "$state" ]; then
            if [ "$state" = running ]; then
                if ! scenario_command "restore-${path##*/}" sh -c \
                    '
                        . "$1"
                        start_remoteproc "$2" "$3"
                    ' sh "$TOOLS/functestlib.sh" "$path" "$SCENARIO_TIMEOUT"; then
                    failed=1
                fi
            else
                failed=1
            fi
        fi
        [ "$(cat "$path/state" 2>/dev/null)" = "$state" ] || failed=1
        baseline="$SCENARIO_DIR/${path##*/}-initial-channels"
        current="$SCENARIO_DIR/${path##*/}-restored-channels"
        start=$(get_monotonic_seconds)
        while :; do
            remoteproc_scenario_channels "$path" >"$current" || return 1
            cmp -s "$baseline" "$current" && break
            [ "$(($(get_monotonic_seconds) - start))" -lt "$SCENARIO_TIMEOUT" ] || break
            sleep 1
        done
        cmp -s "$baseline" "$current" || failed=1
    done <"$SCENARIO_DIR/remoteprocs.changed"
    [ "$failed" -eq 0 ]
}

# remoteproc_scenario_restart
# Repeat explicitly selected processors' stop/start and channel recovery checks.
remoteproc_scenario_restart() {
    local path name firmware state owner round label start before after
    if [ "$SCENARIO_EXERCISE" != 1 ] || [ "$SCENARIO_PROCESSORS" = auto ]; then
        test_result_record SKIP "DSP lifecycle changes require --exercise and explicit --processors runtime names or owner IDs"
        return
    fi
    scenario_require sort cmp || return 0
    remoteproc_scenario_inventory || return 0
    if [ "$TEST_RESULT_FAIL_COUNT" -ne 0 ]; then
        return 0
    fi
    : >"$SCENARIO_DIR/remoteprocs.changed"
    # shellcheck disable=SC2034 # Consumed by lib_scenario.sh.
    SCENARIO_CLEANUP=remoteproc_scenario_restore
    while IFS='|' read -r path name firmware state owner; do
        if [ "$state" != running ] || [ ! -w "$path/state" ]; then
            test_result_record SKIP "Processor=$name owner=${owner##*/} is not Linux-owned running hardware with writable lifecycle control"
            continue
        fi
        printf '%s|%s|%s|%s|%s\n' "$path" "$name" "$firmware" "$state" "$owner" \
            >>"$SCENARIO_DIR/remoteprocs.changed"
        remoteproc_scenario_channels "$path" >"$SCENARIO_DIR/${path##*/}-initial-channels" || return 1
        round=1
        while [ "$round" -le "$SCENARIO_ROUNDS" ]; do
            label="${path##*/}-round$round"
            before="$SCENARIO_DIR/$label.channels-before"
            after="$SCENARIO_DIR/$label.channels-after"
            remoteproc_scenario_channels "$path" >"$before" || return 1
            scenario_capture_kernel "$label-before" || true
            if ! scenario_command "$label-stop" sh -c \
                '
                    . "$1"
                    stop_remoteproc "$2" "$3"
                ' sh "$TOOLS/functestlib.sh" "$path" "$SCENARIO_TIMEOUT"; then
                test_result_record FAIL "Processor=$name stop/offline failed, round=$round"
                return 1
            fi
            remoteproc_scenario_channels "$path" >"$after" || return 1
            if [ -s "$after" ]; then
                test_result_record FAIL "Processor=$name RPMsg channels remained while offline, artifact=$after"
            else
                test_result_record PASS "Processor=$name offline and channels removed, round=$round"
            fi
            if ! scenario_command "$label-start" sh -c \
                '
                    . "$1"
                    start_remoteproc "$2" "$3"
                ' sh "$TOOLS/functestlib.sh" "$path" "$SCENARIO_TIMEOUT"; then
                test_result_record FAIL "Processor=$name start/running failed, round=$round"
                return 1
            fi
            start=$(get_monotonic_seconds)
            while :; do
                remoteproc_scenario_channels "$path" >"$after" || return 1
                cmp -s "$before" "$after" && break
                [ "$(($(get_monotonic_seconds) - start))" -lt "$SCENARIO_TIMEOUT" ] || break
                sleep 1
            done
            if cmp -s "$before" "$after"; then
                if [ -s "$before" ]; then
                    test_result_record PASS "Processor=$name channel names, counts and drivers restored, round=$round"
                else
                    test_result_record SKIP "Processor=$name exposed no baseline RPMsg channels, channel restoration not exercised"
                fi
                test_result_record PASS "Processor=$name running after restart, round=$round"
                # shellcheck disable=SC2034 # Required by scenario_finish.
                SCENARIO_VALIDATED=1
            else
                test_result_record FAIL "Processor=$name RPMsg channel/driver restoration differs, round=$round artifacts=$before,$after"
            fi
            scenario_capture_kernel "$label-after" || true
            scenario_kernel_delta "$label-before" "$label-after" \
                'crash detected|BUG:|WARNING:|Oops:|panic|Call trace:|failed to|timed out|probe.*fail' || true
            round=$((round + 1))
        done
    done <"$SCENARIO_DIR/remoteprocs.selected"
}
