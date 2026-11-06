#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

export CS_BASE="/sys/bus/coresight/devices"

find_path() {
    for _dir_name in "$@"; do
        if [ -d "$CS_BASE/$_dir_name" ]; then
            echo "$CS_BASE/$_dir_name"
            return 0
        fi
    done
    echo ""
}

reset_devices() {
    for node in "$CS_BASE"/*; do
        [ -d "$node" ] || continue
        [ -f "$node/enable_source" ] && echo 0 > "$node/enable_source" 2>/dev/null
        [ -f "$node/enable_sink" ] && echo 0 > "$node/enable_sink" 2>/dev/null
    done
}

# Change a sink state and verify the kernel accepted the requested state.
# A successful write alone is not sufficient because sysfs writes may be rejected.
set_sink_state() {
    _cs_sink_path=$1
    _cs_sink_name=$2
    _cs_requested_state=$3
    _cs_state_file="$_cs_sink_path/enable_sink"
    if [ ! -f "$_cs_state_file" ]; then
        log_fail "$_cs_sink_name sink has no enable_sink control: $_cs_sink_path"
        return 1
    fi
    if ! echo "$_cs_requested_state" > "$_cs_state_file" 2>/dev/null; then
        log_fail "Failed to set $_cs_sink_name sink enable_sink to $_cs_requested_state"
        return 1
    fi
    _cs_actual_state=$(cat "$_cs_state_file" 2>/dev/null)
    if [ "$_cs_actual_state" != "$_cs_requested_state" ]; then
        log_fail "$_cs_sink_name sink enable_sink is $_cs_actual_state; expected $_cs_requested_state"
        return 1
    fi
    return 0
}

# Prepare a sink independently and verify it is clear before enabling it.
prepare_sink() {
    _cs_prepare_path=$1
    _cs_prepare_name=$2
    reset_devices
    if ! set_sink_state "$_cs_prepare_path" "$_cs_prepare_name" 0; then
        log_fail "$_cs_prepare_name sink could not be cleared before phase start"
        return 1
    fi
    if ! set_sink_state "$_cs_prepare_path" "$_cs_prepare_name" 1; then
        log_fail "Cannot enable $_cs_prepare_name sink for phase"
        return 1
    fi
    return 0
}

# Clear the sink and verify readback. Since reset_devices has no reliable
# aggregate status, retry the explicit clear once if readback is not zero.
cleanup_sink() {
    _cs_cleanup_path=$1
    _cs_cleanup_name=$2
    _cs_cleanup_ok=0
    if set_sink_state "$_cs_cleanup_path" "$_cs_cleanup_name" 0; then
        _cs_cleanup_ok=1
    fi
    reset_devices
    if [ -f "$_cs_cleanup_path/enable_sink" ] && \
        [ "$(cat "$_cs_cleanup_path/enable_sink" 2>/dev/null)" = "0" ]; then
        _cs_cleanup_ok=1
    else
        _cs_cleanup_ok=0
        log_fail "$_cs_cleanup_name sink was not cleared after reset"
        # The readback remains authoritative; reset_devices' return status is not used.
        if set_sink_state "$_cs_cleanup_path" "$_cs_cleanup_name" 0; then
            _cs_cleanup_ok=1
        fi
    fi
    if [ "$_cs_cleanup_ok" -ne 1 ]; then
        log_fail "$_cs_cleanup_name sink cleanup failed; sink may remain selected"
        return 1
    fi
    return 0
}

enable_npu_clocks() {
    if [ -f "/sys/kernel/debug/npu/ctrl" ]; then
        echo on > "/sys/kernel/debug/npu/ctrl" 2>/dev/null
    elif [ -f "/d/npu/ctrl" ]; then
        echo on > "/d/npu/ctrl" 2>/dev/null
    fi
}

disable_npu_clocks() {
    if [ -f "/sys/kernel/debug/npu/ctrl" ]; then
        echo off > "/sys/kernel/debug/npu/ctrl" 2>/dev/null
    elif [ -f "/d/npu/ctrl" ]; then
        echo off > "/d/npu/ctrl" 2>/dev/null
    fi
}