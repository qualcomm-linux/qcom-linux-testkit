#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc.
# SPDX-License-Identifier: BSD-3-Clause

cs_base="${cs_base:-/sys/bus/coresight/devices}"

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