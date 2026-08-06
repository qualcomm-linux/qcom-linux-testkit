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

TESTNAME="Reset-Random-Sinks-Base"
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

reset_source_sink

sink_list=""
sink_cnt=0

for sink in "$cs_base"/*; do
    [ ! -d "$sink" ] && continue
    [ "$(basename "$sink")" = "tmc_etf1" ] && continue
    
    if [ -f "$sink/enable_sink" ]; then
        sink_list="$sink_list $sink"
        sink_cnt=$((sink_cnt + 1))
    fi
done

sink_list=${sink_list# }

if [ "$sink_cnt" -lt 2 ]; then
    log_warn "Found less than 2 valid sinks ($sink_cnt). Cannot run multiple sink reset test. Skipping."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

runs=${1:-1000}
case "$1" in
    ''|*[!0-9]*) ;;
    *) runs=$1 ;;
esac
log_info "Start run reset sinks for $runs iterations with $sink_cnt available sinks"
i=0
while [ "$i" -lt "$runs" ] && [ "$fail" -eq 0 ]; do
    
    log_info "start run reset sinks in loop: $i"
    
    for sink1 in $sink_list; do
        [ "$fail" -eq 1 ] && break
        
        found_sink1=0
        for sink2 in $sink_list; do
            [ "$fail" -eq 1 ] && break
            
            if [ "$sink1" = "$sink2" ]; then
                found_sink1=1
                continue
            fi
            [ "$found_sink1" -eq 0 ] && continue
            
            echo 1 > "$sink1/enable_sink" 2>/dev/null
            echo 1 > "$sink2/enable_sink" 2>/dev/null
            
            reset_source_sink
            
            if ! check_sink_status; then
                log_fail "FAIL: reset multiple sinks (failed on loop $i for $(basename "$sink1") & $(basename "$sink2"))"
                fail=1
                break
            fi
        done
    done
    i=$((i+1))
done

log_info "Starting post-stress validation..."

sink_path=""
sink_base=""
for sink in $sink_list; do
    base_sink=$(basename "$sink")
    if [ -c "/dev/$base_sink" ]; then
        sink_path="$sink"
        sink_base="$base_sink"
        break
    fi
done

src_path=""
for src in "$cs_base"/*; do
    [ ! -d "$src" ] && continue
    if [ -f "$src/enable_source" ]; then
        src_path="$src"
        break
    fi
done

if [ -z "$sink_path" ]; then
    log_warn "No valid sink with a /dev/ node found for post-stress verification. Skipping verification."
elif [ -z "$src_path" ]; then
    log_warn "No valid source found for post-stress verification. Skipping verification."
elif [ "$fail" -eq 0 ]; then
    log_info "Using sink: $sink_base and source: $(basename "$src_path") for verification."
    
    echo 1 > "$sink_path/enable_sink" 2>/dev/null
    echo 1 > "$src_path/enable_source" 2>/dev/null
    
    sleep 1
    
    echo 0 > "$src_path/enable_source" 2>/dev/null
    
    trace_file="/tmp/${sink_base}_stress.bin"
    rm -f "$trace_file"
    
    cat "/dev/$sink_base" > "$trace_file" 2>/dev/null
    
    if [ -f "$trace_file" ]; then
        size=$(wc -c < "$trace_file" 2>/dev/null || echo 0)
        size=$(echo "$size" | tr -d ' ')
        
        if [ "$size" -lt 64 ]; then
            log_fail "etr/etf read FAIL after sink reset stress test (size $size < 64)"
            fail=1
        else
            log_info "Post-stress read successful (size $size bytes)."
        fi
    else
        log_fail "etr/etf read FAIL: $trace_file missing"
        fail=1
    fi
    
    echo 0 > "$sink_path/enable_sink" 2>/dev/null
fi

if [ "$fail" -eq 0 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"