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
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="ETM-Trace"
if command -v find_test_case_by_name >/dev/null 2>&1; then
    test_path=$(find_test_case_by_name "$TESTNAME")
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

res_file="./$TESTNAME.res"
rm -f "$res_file"
touch "$res_file"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

CS_BASE="/sys/bus/coresight/devices"
TMP_DIR="/tmp/coresight-test"
FAIL_COUNT=0

RUNS=2
if [ -n "$1" ]; then
    RUNS=$1
fi

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"


reset_devices() {
    if [ -f "$CS_BASE/stm0/enable_source" ]; then
        echo 0 > "$CS_BASE/stm0/enable_source" 2>/dev/null
    fi
    
    # shellcheck disable=SC2010
    for etm in $(ls -d "$CS_BASE"/etm* "$CS_BASE"/coresight-etm* 2>/dev/null); do
        if [ -f "$etm/enable_source" ]; then
            echo 0 > "$etm/enable_source" 2>/dev/null
        fi
    done

    for sink in "$CS_BASE"/tmc_et*; do
        if [ -f "$sink/enable_sink" ]; then
            echo 0 > "$sink/enable_sink" 2>/dev/null
        fi
    done
}

run_trace_test() {
    sourcename=$1
    sinkname=$2
    
    bin_dir="$TMP_DIR/$sinkname"
    mkdir -p "$bin_dir"
    
    log_info ">>> Source: $(basename "$sourcename") | Sink: $sinkname"
    
    if ! echo 1 > "$sourcename/enable_source"; then
        log_fail "Failed to write 1 to $sourcename/enable_source"
        return 1
    fi
    
    res=$(cat "$sourcename/enable_source")
    if [ "$res" -eq 1 ]; then
        log_info "Source enabled successfully"
    else
        log_fail "Source failed to enable (Value: $res)"
        return 1
    fi
    
    sleep 3
    
    outfile="$bin_dir/$(basename "$sourcename").bin"
    timeout 5 cat "/dev/$sinkname" > "$outfile" 2>/dev/null
    
    if [ -f "$outfile" ]; then
        bin_size=$(stat -c%s "$outfile")
        log_info " captured bin size: $bin_size bytes"
        
        if [ "$bin_size" -ge 64 ]; then
            log_pass "Trace data captured for $sourcename -> $sinkname"
        else
            log_fail "Trace data too small ($bin_size < 64)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        log_fail "Failed to create output file from /dev/$sinkname"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    
    echo 0 > "$sourcename/enable_source"
    res=$(cat "$sourcename/enable_source")
    
    if [ "$res" -eq 0 ]; then
        log_info "Source disabled successfully"
    else
        log_fail "Source failed to disable (Value: $res)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}


# shellcheck disable=SC2010
SINK_LIST=$(ls -d "$CS_BASE"/tmc_et* 2>/dev/null | grep -v tmc_etf1)
# shellcheck disable=SC2010
ETM_LIST=$(ls -d "$CS_BASE"/etm* "$CS_BASE"/coresight-etm* 2>/dev/null)

if [ -z "$SINK_LIST" ] || [ -z "$ETM_LIST" ]; then
    log_fail "Missing Sinks or ETM devices"
    echo "$TESTNAME: FAIL" >> "$res_file"
    exit 1
fi

reset_devices

for sink_path in $SINK_LIST; do
    sinkname=$(basename "$sink_path")
    
    i=0
    while [ $i -lt "$RUNS" ]; do
        log_info "--- Iteration $((i+1)) for Sink: $sinkname ---"
        
        for etm_path in $ETM_LIST; do
            reset_devices
            
            echo 1 > "$sink_path/enable_sink"
            
            run_trace_test "$etm_path" "$sinkname"
        done
        
        i=$((i+1))
    done
done

reset_devices

if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "ETM Trace Enable/Disable Test Completed Successfully"
    echo "$TESTNAME: PASS" >> "$res_file"
else
    log_fail "ETM Trace Enable/Disable Test Failed ($FAIL_COUNT errors)"
    echo "$TESTNAME: FAIL" >> "$res_file"
fi

rm -rf "$TMP_DIR"
# log_info "-------------------$TESTNAME Testcase Finished----------------------------"