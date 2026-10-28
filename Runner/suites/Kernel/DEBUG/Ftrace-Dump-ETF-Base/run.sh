#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
    echo "[ERROR] Could not find init_env" >&2
    exit 1
fi

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/coresight_helper.sh"

TESTNAME="Ftrace-Dump-ETF-Base"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
log_info "---------------------------$TESTNAME Starting---------------------------"

cs_base="/sys/bus/coresight/devices"
debugfs="/sys/kernel/debug"
[ ! -d "$debugfs/tracing" ] && debugfs="/debug"

fail=0

if [ ! -d "$cs_base" ]; then
    log_warn "Coresight directory $cs_base not found. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

trap cleanup EXIT HUP INT TERM

cleanup

stm_path=""
for stm_node in "$cs_base"/*stm*; do
    if [ -d "$stm_node" ] && [ -f "$stm_node/enable_source" ]; then
        stm_path="$stm_node"
        break
    fi
done

if [ -z "$stm_path" ]; then
    log_warn "No valid STM source found in $cs_base. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

sink_path=""
for sink_node in "$cs_base"/*; do
    [ ! -d "$sink_node" ] && continue
    [ "$(basename "$sink_node")" = "tmc_etf1" ] && continue
    
    if [ -f "$sink_node/enable_sink" ]; then
        sink_path="$sink_node"
        break
    fi
done

if [ -z "$sink_path" ]; then
    log_warn "No valid Sink found in $cs_base. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

sink_name="$(basename "$sink_path")"
stm_name="$(basename "$stm_path")"

if [ ! -c "/dev/$sink_name" ]; then
    log_warn "Character device /dev/$sink_name not found for data read. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

ftrace_link="/sys/class/stm_source/ftrace/stm_source_link"
if [ ! -f "$ftrace_link" ]; then
    log_warn "Ftrace STM source link capability missing at $ftrace_link. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Using Source: $stm_name, Sink: $sink_name"

[ -f "$stm_path/hwevent_enable" ] && echo 0 > "$stm_path/hwevent_enable" 2>/dev/null
[ -f "$stm_path/port_enable" ] && echo 0xffffffff > "$stm_path/port_enable" 2>/dev/null

echo 1 > "$sink_path/enable_sink" 2>/dev/null

ret=$(tr -d ' ' < "$sink_path/enable_sink" 2>/dev/null)

if [ "$ret" = "1" ]; then
    log_info "PASS: sink switch to $sink_name successful"
else
    log_fail "FAIL: sink switch to $sink_name failed"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    log_info "Linking Ftrace to $stm_name..."
    echo "$stm_name" > "$ftrace_link" 2>/dev/null

    [ -f "$debugfs/tracing/tracing_on" ] && echo 1 > "$debugfs/tracing/tracing_on"
    [ -f "$debugfs/tracing/events/sched/sched_switch/enable" ] && echo 1 > "$debugfs/tracing/events/sched/sched_switch/enable"
    
    echo 1 > "$stm_path/enable_source" 2>/dev/null

    sleep 20

    cleanup

    trace_file="/tmp/${sink_name}_ftrace.bin"
    rm -f "$trace_file"
    
    cat "/dev/$sink_name" > "$trace_file" 2>/dev/null
    
    bin_size=$(wc -c < "$trace_file" 2>/dev/null | tr -d ' ')
    [ -z "$bin_size" ] && bin_size=0
    
    log_info "Collected bin size: $bin_size bytes"

    if [ -f "$trace_file" ] && [ "$bin_size" -ge 65536 ]; then
        log_pass "PASS: $sink_name sink data through Ftrace verified"
    else
        log_fail "FAIL: $sink_name sink data through Ftrace insufficient or missing"
        fail=1
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "$TESTNAME PASS" > "$res_file"
else
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "---------------------------$TESTNAME Finished---------------------------"
