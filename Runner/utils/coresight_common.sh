#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# --- Logging helpers ---
CS_BASE="/sys/bus/coresight/devices"
CS_RESET_NODE="/sys/bus/coresight/reset_source_sink"

# Helper for all reset
cs_global_reset() {
    if [ -f "$CS_RESET_NODE" ]; then
        echo 1 > "$CS_RESET_NODE" 2>/dev/null
    else
        for _sink in tmc_etr0 tmc_etf0 coresight-tmc-etr coresight-tmc-etf; do
            if [ -f "$CS_BASE/$_sink/enable_sink" ]; then
                echo 0 > "$CS_BASE/$_sink/enable_sink" 2>/dev/null
            fi
        done
    fi
}

# Helper to find sinks
cs_find_sinks() {
    # shellcheck disable=SC2010
    ls "$CS_BASE" 2>/dev/null | grep -E "tmc.et[fr]|tmc-et[fr]"
}

# Helper to enable sinks
cs_enable_sink() {
    _sname="$1"
    _spath="$CS_BASE/$_sname"
    if [ ! -f "$_spath/enable_sink" ]; then
        return 1
    fi
    echo 1 > "$_spath/enable_sink"
}

# Helper to disable sink
cs_disable_sink() {
    _sname="$1"
    _spath="$CS_BASE/$_sname"
    if [ -f "$_spath/enable_sink" ]; then
        echo 0 > "$_spath/enable_sink" 2>/dev/null
    fi
}

# Helper to find sources
cs_find_sources() {
    _pattern="${1:-}"
    # shellcheck disable=SC2010
    ls "$CS_BASE" 2>/dev/null | grep "$_pattern"
}

# Helper to check bases
cs_check_base() {
    if [ ! -d "$CS_BASE" ]; then
        log_fail "Coresight sysfs not found: $CS_BASE"
        return 1
    fi
    return 0
}

# coresight_find_sink <device> <dev-root> <visited-paths>
# Traverse only output connections, resolving sysfs links. Print first readable
# sink path, return 1 if no connected character-device sink is usable.
coresight_find_sink() (
    cs_node=$(CDPATH='' cd "$1" && pwd -P) || exit 1
    cs_devs=$2
    cs_visited=${3:-}
    case "|$cs_visited|" in
        *"|$cs_node|"*)
            exit 1
            ;;
    esac
    if [ -r "$cs_node/enable_sink" ] && [ -c "$cs_devs/${cs_node##*/}" ]; then
        printf '%s\n' "$cs_node"
        exit 0
    fi
    for cs_link in "$cs_node"/connections/out:* "$cs_node"/out:*; do
        [ -d "$cs_link" ] || continue
        if coresight_find_sink "$cs_link" "$cs_devs" "$cs_visited|$cs_node"; then
            exit 0
        fi
    done
    exit 1
)

# coresight_find_pair <sysfs-root> <dev-root>
# Print source|sink|cpu for a schedulable CPU source and connected readable sink.
# Return 4 when no usable route exists. No mutation and diagnostics on stderr.
coresight_find_pair() (
    cs_root=$1
    cs_devs=$2
    CS_BASE="$cs_root"
    for cs_source_name in $(cs_find_sources ''); do
        cs_candidate_source="$cs_root/$cs_source_name"
        [ -r "$cs_candidate_source/enable_source" ] || continue
        [ -r "$cs_candidate_source/cpu" ] || continue
        cs_cpu=$(cat "$cs_candidate_source/cpu") || exit 1
        is_unsigned_number "$cs_cpu" || exit 1
        taskset -c "$cs_cpu" sh -c 'true' >/dev/null 2>&1 || continue
        cs_candidate_sink=$(coresight_find_sink "$cs_candidate_source" "$cs_devs" "") || continue
        printf '%s|%s|%s\n' "$cs_candidate_source" "$cs_candidate_sink" "$cs_cpu"
        exit 0
    done
    echo "No schedulable CPU trace source connected to a character-device sink" >&2
    exit 4
)

# coresight_write <attribute> <value>
# Write/read back an enable flag. No stdout, return nonzero on failure.
coresight_write() (
    cs_attribute="$1"
    cs_setting="$2"
    case "$cs_attribute" in
        */enable_sink)
            cs_component=${cs_attribute%/*}
            CS_BASE=${cs_component%/*}
            if [ "$cs_setting" = 1 ]; then
                cs_enable_sink "${cs_component##*/}" || exit 1
            else
                cs_disable_sink "${cs_component##*/}" || exit 1
            fi
            ;;
        *)
            printf '%s\n' "$cs_setting" >"$cs_attribute" || exit 1
            ;;
    esac
    [ "$(cat "$cs_attribute")" = "$cs_setting" ]
)

# coresight_restore
# Restore only source/sink controls owned by this capture. Return 1 on failure.
coresight_restore() {
    cs_restore_rc=0
    if [ "$cs_source_changed" = 1 ]; then
        coresight_write "$cs_source/enable_source" 0 || cs_restore_rc=1
    fi
    if [ "$cs_sink_changed" = 1 ]; then
        coresight_write "$cs_sink/enable_sink" 0 || cs_restore_rc=1
    fi
    return "$cs_restore_rc"
}

# coresight_capture <sysfs-root> <dev-root> <outdir>
# Capture a bounded CPU workload and fresh trace, restoring owned controls.
# Logs stdout. Return 0/1/4 = PASS/FAIL/SKIP. Active tracing is left untouched.
coresight_capture() (
    cs_root=$1
    cs_devs=$2
    cs_out=$3
    for cs_flag in "$cs_root"/*/enable_source "$cs_root"/*/enable_sink; do
        [ -e "$cs_flag" ] || continue
        cs_value=$(cat "$cs_flag") || exit 1
        case "$cs_value" in
            0) ;;
            1)
                echo "Trace component already active: $cs_flag, leave existing tracing untouched"
                exit 4
                ;;
            *)
                echo "Unexpected trace enable value '$cs_value' at $cs_flag"
                exit 1
                ;;
        esac
    done
    cs_pair=$(coresight_find_pair "$cs_root" "$cs_devs") || exit $?
    cs_source=${cs_pair%%|*}
    cs_tail=${cs_pair#*|}
    cs_sink=${cs_tail%%|*}
    cs_cpu=${cs_tail##*|}
    cs_source_changed=0
    cs_sink_changed=0
    trap 'cs_rc=$?
        trap - 0
        managed_timeout_cancel_bounded 2 || cs_rc=1
        if ! coresight_restore; then
            echo "CoreSight restoration failed, source=$cs_source sink=$cs_sink" >&2
            cs_rc=1
        fi
        exit "$cs_rc"' 0
    trap 'exit 1' HUP INT TERM
    echo "source=$cs_source sink=$cs_sink cpu=$cs_cpu"
    printf '%s\n' "$cs_pair" >"$cs_out/route.txt" || exit 1
    cs_sink_changed=1
    coresight_write "$cs_sink/enable_sink" 1 || exit 1
    cs_source_changed=1
    coresight_write "$cs_source/enable_source" 1 || exit 1
    # A finite instruction workload avoids leaving CPU burners after signals.
    # shellcheck disable=SC2016
    run_with_managed_timeout 10 "$cs_out" coresight-workload taskset -c "$cs_cpu" sh -c '
        n=0
        while [ "$n" -lt 10000 ]; do
            n=$((n + 1))
        done
    ' || exit 1
    coresight_write "$cs_source/enable_source" 0 || exit 1
    # Reading the stopped source flushes the TMC buffer through its driver.
    run_with_managed_timeout 10 "$cs_out" coresight-read cat "$cs_devs/${cs_sink##*/}" >"$cs_out/trace.bin"
    cs_rc=$?
    [ "$cs_rc" -eq 0 ] || exit 1
    [ -s "$cs_out/trace.bin" ] || exit 1
    echo "Captured $(wc -c <"$cs_out/trace.bin") bytes, raw trace retained at $cs_out/trace.bin"
)
