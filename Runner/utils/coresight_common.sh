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
    _pattern="$1"
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