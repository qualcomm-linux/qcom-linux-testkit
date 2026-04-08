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

TESTNAME="Single-Sink-Reset-Connected-Base"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
log_info "------------------------$TESTNAME Starting------------------------"

cs_base="/sys/bus/coresight/devices"

if [ ! -d "$cs_base" ]; then
    log_warn "Coresight directory $cs_base not found. Skipping test."
    echo "0" > "$res_file"
    exit 0
fi

stm=""
for node in "$cs_base"/stm*; do
    if [ -d "$node" ] && [ -f "$node/enable_source" ]; then
        stm="$node"
        brea
    fi
done

sinks=""
for node in "$cs_base"/*; do
    [ -d "$node" ] || continue
    [ "$(basename "$node")" = "tmc_etf1" ] && continue
    
    if [ -f "$node/enable_sink" ]; then
        sinks="$sinks $node"
    fi
done

sinks="${sinks# }"

if [ -z "$stm" ]; then
    log_warn "No stm source found on this device. Skipping test."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

if [ -z "$sinks" ]; then
    log_warn "No Coresight sinks found on this device. Skipping test."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

trap cleanup EXIT HUP INT TERM

reset_coresight

if [ -f "$stm/hwevent_enable" ]; then
    echo 0 > "$stm/hwevent_enable" 2>/dev/null || true
fi

debugfs="/sys/kernel/debug"
[ ! -d "$debugfs/tracing" ] && debugfs="/debug"
if [ -f "$debugfs/tracing/events/enable" ]; then
    echo 0 > "$debugfs/tracing/events/enable" 2>/dev/null || true
fi

testRes=""
runs=${1:-250}
log_info "Running sink reset stress test for $runs iterations..."

i=0
while [ "$i" -lt "$runs" ]; do
    log_info "Sink reset running loop: $i / $runs"
    
    for sink in $sinks; do
        reset_coresight
        
        echo 1 > "$sink/enable_sink" 2>/dev/null || true
        echo 1 > "$stm/enable_source" 2>/dev/null || true
        
        sleep 1
        reset_coresight
        
        if ! check_sink_status; then
            log_fail "FAIL: reset_source_sink failed to disable sink during active source at loop $i"
            testRes="FAIL"
        else
            log_info "PASS: reset_source_sink successful for $sink"
        fi
    done
    i=$((i+1))
done

reset_coresight

verify_sink=""
verify_dev=""
for s in $sinks; do
    dev_path="/dev/$(basename "$s")"
    if [ -c "$dev_path" ]; then
        verify_sink="$s"
        verify_dev="$dev_path"
        break
    fi
done

if [ -z "$verify_sink" ]; then
    log_warn "Could not find a valid /dev/ character node for any sink. Skipping read verification."
else   
    echo 1 > "$verify_sink/enable_sink" 2>/dev/null || true
    echo 1 > "$stm/enable_source" 2>/dev/null || true
    
    sleep 5
    
    echo 0 > "$stm/enable_source" 2>/dev/null || true
    echo 0 > "$verify_sink/enable_sink" 2>/dev/null || true
    
    rm -f /tmp/etf.bin
    cat "$verify_dev" > /tmp/etf.bin 2>/dev/null
    
    if [ ! -f "/tmp/etf.bin" ]; then
        log_fail "Trace read FAIL: File /tmp/etf.bin not created"
        testRes="FAIL"
    else
        size=$(wc -c < /tmp/etf.bin)
        if [ "$size" -lt 64 ]; then
            testRes="FAIL"
        fi
    fi
fi

if [ -z "$testRes" ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Finished----------------------------"