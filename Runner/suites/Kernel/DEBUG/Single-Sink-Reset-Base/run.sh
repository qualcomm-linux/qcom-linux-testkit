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

TESTNAME="Single-Sink-Reset-Base"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
log_info "------------------------$TESTNAME Starting------------------------"

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

reset_coresight
[ -f "$debugfs/tracing/events/enable" ] && echo 0 > "$debugfs/tracing/events/enable" 2>/dev/null


sink_list=""
for sink_node in "$cs_base"/*; do
    [ ! -d "$sink_node" ] && continue
    [ "$(basename "$sink_node")" = "tmc_etf1" ] && continue
    
    if [ -f "$sink_node/enable_sink" ]; then
        sink_list="$sink_list $sink_node"
    fi
done
sink_list=${sink_list# }

if [ -z "$sink_list" ]; then
    log_warn "No Coresight sinks found. Cannot run test. Skipping."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

source=""
for node in "$cs_base"/stm*; do
    if [ -d "$node" ] && [ -f "$node/enable_source" ]; then
        source="$node"
        break
    fi
done

verify_source=""
for node in "$cs_base"/etm*; do
    if [ -d "$node" ] && [ -f "$node/enable_source" ]; then
        verify_source="$node"
        break
    fi
done

[ -z "$source" ] && source="$verify_source"
[ -z "$verify_source" ] && verify_source="$source"

if [ -z "$source" ]; then
    log_warn "No Coresight sources (STM/ETM) found. Cannot run active-source stress test. Skipping."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

runs=${1:-250}
case "$1" in
    ''|*[!0-9]*) ;;
    *) runs=$1 ;;
esac

log_info "Starting sink reset test for $runs iterations..."

i=0
while [ "$i" -lt "$runs" ] && [ "$fail" -eq 0 ]; do
    [ $((i % 25)) -eq 0 ] && log_info "Stress test running loop: $i"
    
    for sink in $sink_list; do
        reset_coresight
        
        [ -f "$sink/enable_sink" ] && echo 1 > "$sink/enable_sink" 2>/dev/null
        [ -f "$source/enable_source" ] && echo 1 > "$source/enable_source" 2>/dev/null
        
        sleep 1
        
        reset_coresight
        
        if ! check_sink_status; then
            log_fail "FAIL: reset_coresight failed to disable sink during active source at loop $i"
            fail=1
            break
        fi
    done
    i=$((i + 1))
done

verify_sink=""
for sink in $sink_list; do
    sink_name=$(basename "$sink")
    if [ -c "/dev/$sink_name" ]; then
        verify_sink="$sink"
        break
    fi
done

if [ -z "$verify_sink" ]; then
    log_info "No valid character device found in /dev/ for verification. Skipping read check."
else
    sink_name=$(basename "$verify_sink")
    log_info "Starting reset_sink functionality check by reading from $sink_name using source $(basename "$verify_source")."
    
    reset_coresight
    [ -f "$verify_sink/enable_sink" ] && echo 1 > "$verify_sink/enable_sink" 2>/dev/null
    [ -f "$verify_source/enable_source" ] && echo 1 > "$verify_source/enable_source" 2>/dev/null
    
    sleep 5
    
    [ -f "$verify_source/enable_source" ] && echo 0 > "$verify_source/enable_source" 2>/dev/null
    
    rm -f "/tmp/${sink_name}.bin"
    cat "/dev/$sink_name" > "/tmp/${sink_name}.bin" 2>/dev/null
    
    if [ ! -f "/tmp/${sink_name}.bin" ]; then
        log_fail "Sink read FAIL after stress test (file missing)"
        fail=1
    else
        size=$(wc -c < "/tmp/${sink_name}.bin" 2>/dev/null || echo 0)
        size=$(echo "$size" | tr -d ' ')
        
        if [ "$size" -lt 64 ]; then
            log_fail "Sink read FAIL after stress test (size $size < 64 bytes)"
            fail=1
        fi
    fi
fi

reset_coresight

if [ "$fail" -eq 0 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "------------------------$TESTNAME Finished------------------------"