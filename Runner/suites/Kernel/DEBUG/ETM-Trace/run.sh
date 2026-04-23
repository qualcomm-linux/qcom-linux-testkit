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
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

for _tool in timeout stat; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        log_warn "Required tool '$_tool' not found - skipping test"
        echo "$TESTNAME: SKIP" > "$res_file"
        exit 0
    fi
done

CS_BASE="/sys/bus/coresight/devices"
TMP_DIR="/tmp/coresight-test"
FAIL_COUNT=0

RUNS=2
if [ -n "$1" ]; then
    case "$1" in
        ''|*[!0-9]*)
            log_warn "Invalid RUNS argument '$1' - must be a positive integer, using default: 2"
            ;;
        *)
            if [ "$1" -gt 0 ]; then
                RUNS=$1
            else
                log_warn "RUNS argument must be > 0, using default: 2"
            fi
            ;;
    esac
fi
log_info "Running $RUNS iteration(s) per sink"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

ETM_LIST=""
for _etm in "$CS_BASE"/etm* "$CS_BASE"/coresight-etm* "$CS_BASE"/coresight-ete*; do
    [ -d "$_etm" ] || continue
    ETM_LIST="$ETM_LIST $_etm"
done

SINK_LIST=""
for _sink in "$CS_BASE"/tmc_et*; do
    [ -d "$_sink" ] || continue
    case "$_sink" in
        *tmc_etf1*) continue ;;
    esac
    SINK_LIST="$SINK_LIST $_sink"
done

if [ -z "$SINK_LIST" ] || [ -z "$ETM_LIST" ]; then
    log_fail "Missing Sinks or ETM devices. Cannot proceed."
    echo "$TESTNAME FAIL - Missing target Coresight nodes" > "$res_file"
    exit 1
fi

reset_devices() {
    for stm in "$CS_BASE"/stm* "$CS_BASE"/coresight-stm*; do
        [ -d "$stm" ] || continue
        [ -f "$stm/enable_source" ] && echo 0 > "$stm/enable_source" 2>/dev/null
    done

    for etm in $ETM_LIST; do
        [ -f "$etm/enable_source" ] && echo 0 > "$etm/enable_source" 2>/dev/null
    done

    for sink in $SINK_LIST; do
        [ -f "$sink/enable_sink" ] && echo 0 > "$sink/enable_sink" 2>/dev/null
    done
}

run_trace_test() {
    sourcename=$1
    sinkname=$2
    source_base=$(basename "$sourcename")
    
    bin_dir="$TMP_DIR/$sinkname"
    mkdir -p "$bin_dir"
    outfile="$bin_dir/$source_base.bin"

    log_info "Source: $source_base | Sink: $sinkname"
    
    echo 1 > "$sourcename/enable_source" 2>/dev/null
    res=$(cat "$sourcename/enable_source" 2>/dev/null)
    if [ "$res" = "1" ]; then
        log_info "Source enabled successfully"
    else
        log_fail "Source failed to enable (Value: $res)"
        echo "$TESTNAME FAIL - [Enable Error] $source_base -> $sinkname" >> "$res_file"
        return 1
    fi
    
    sleep 3
    timeout 5 cat "/dev/$sinkname" > "$outfile" 2>/dev/null

     if [ -f "$outfile" ]; then
        bin_size=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
        log_info "Captured bin size: $bin_size bytes"
        
        if [ "$bin_size" -ge 64 ]; then
            log_pass "Trace data captured for $sourcename -> $sinkname"
        else
            log_fail "Trace data too small ($bin_size < 64 bytes)"
            echo "$TESTNAME FAIL - [Size < 64 bytes] $source_base -> $sinkname (Size: $bin_size)" >> "$res_file"
            return 1
        fi
    else
        log_fail "Failed to create output file from /dev/$sinkname"
        echo "$TESTNAME FAIL - [No Output File] $source_base -> $sinkname" >> "$res_file"
        return 1
    fi
    
    echo 0 > "$sourcename/enable_source" 2>/dev/null
    res=$(cat "$sourcename/enable_source" 2>/dev/null)
    if [ "$res" = "0" ]; then
        log_info "Source disabled successfully"
    else
        log_fail "Source failed to disable (Value: $res)"
        echo "$TESTNAME FAIL - [Disable Error] $source_base -> $sinkname" >> "$res_file"
        return 1
    fi
    
    return 0
}

reset_devices

for sink_path in $SINK_LIST; do
    sinkname=$(basename "$sink_path")
    
    i=1
    while [ "$i" -le "$RUNS" ]; do
        log_info "--- Iteration $i for Sink: $sinkname ---"
        iteration_fail=0
        
        echo 1 > "$sink_path/enable_sink" 2>/dev/null
        
        for etm_path in $ETM_LIST; do
            if ! run_trace_test "$etm_path" "$sinkname"; then
                iteration_fail=1
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        done
        
        echo 0 > "$sink_path/enable_sink" 2>/dev/null
        
        if [ "$iteration_fail" -ne 0 ]; then
            log_fail "Iteration $i for Sink $sinkname encountered errors"
        fi
        
        i=$((i + 1))
    done
done

reset_devices
rm -rf "$TMP_DIR"

if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "ETM Trace Enable/Disable Test Completed Successfully"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "ETM Trace Enable/Disable Test Failed ($FAIL_COUNT errors total)"
    echo "$TESTNAME FAIL - Total Errors: $FAIL_COUNT" >> "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"
