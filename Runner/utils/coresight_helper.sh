#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

export CS_BASE="/sys/bus/coresight/devices"
cs_base="${cs_base:-/sys/bus/coresight/devices}"

find_path() {
    for _dir_name in "$@"; do
        if [ -d "$CS_BASE/$_dir_name" ]; then
            echo "$CS_BASE/$_dir_name"
            return 0
        fi
    done
    echo ""
}

reset_coresight() {
    [ ! -d "$cs_base" ] && return 0

    for node in "$cs_base"/*; do
        [ ! -d "$node" ] && continue

        if [ -f "$node/enable_source" ]; then
            echo 0 > "$node/enable_source" 2>/dev/null || true
        fi

        if [ -f "$node/enable_sink" ]; then
            echo 0 > "$node/enable_sink" 2>/dev/null || true
        fi
    done
}

# Alias to support scripts from PR 370 that use reset_devices
reset_devices() {
    reset_coresight
}

check_sink_status() {
    _fail=0

    for _sink in "$@"; do
        [ ! -f "$_sink/enable_sink" ] && continue

        status=$(tr -d ' \n' < "$_sink/enable_sink" 2>/dev/null)

        if [ "$status" = "1" ]; then
            echo "[ERROR] Sink still enabled after reset: $(basename "$_sink")" >&2
            _fail=1
        fi
    done

    return $_fail
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