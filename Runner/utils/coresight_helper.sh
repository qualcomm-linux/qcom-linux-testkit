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