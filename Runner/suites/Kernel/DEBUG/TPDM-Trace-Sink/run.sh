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

TESTNAME="TPDM-Trace-Sink"
res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
cs_base="/sys/bus/coresight/devices"

# shellcheck disable=SC2329
cleanup() {
    reset_devices
    disable_npu_clocks
}
trap cleanup EXIT INT TERM

fail=0
sink_found=0
tpdm_found=0
i=0

log_info "Performing initial device reset..."
reset_devices
enable_npu_clocks

while [ "$i" -le 1 ]; do
    log_info "[Iteration $i] Starting sink evaluation..."
    
    for sink_path in "$cs_base"/tmc_et* "$cs_base"/coresight-tmc_et*; do
        [ ! -d "$sink_path" ] && continue
        
        sink_dev=$(basename "$sink_path")
        
        if [ "$sink_dev" = "tmc_etf1" ] || [ "$sink_dev" = "coresight-tmc_etf1" ]; then
            continue
        fi

        sink_found=$((sink_found + 1))
        log_info "Testing Sink: $sink_dev"
        
        if [ -f "$sink_path/enable_sink" ]; then
            echo 1 > "$sink_path/enable_sink" 2>/dev/null
        fi

        for node_path in "$cs_base"/tpdm* "$cs_base"/coresight-tpdm*; do
            [ ! -d "$node_path" ] && continue
            
            node_name=$(basename "$node_path")
            
            if echo "$node_name" | grep -q "tpdm-turing-llm"; then
                continue
            fi
            
            if [ ! -f "$node_path/enable_source" ]; then
                continue
            fi
            
            tpdm_found=$((tpdm_found + 1))
            
            echo 1 > "$node_path/enable_source" 2>/dev/null
            res=$(cat "$node_path/enable_source" 2>/dev/null)
            
            if [ "$res" != "1" ]; then
                log_fail "Failed to enable source: $node_name"
                fail=1
            else
                log_info "Enabled source: $node_name"
            fi
            
            sleep 1
            trace_file="/tmp/${sink_dev}_${node_name}.bin"
            
            if [ -c "/dev/$sink_dev" ]; then
                cat "/dev/$sink_dev" > "$trace_file" 2>/dev/null

                if [ -s "$trace_file" ]; then
                    log_info "Trace validation PASS"
                else
                    log_fail "Trace validation FAIL"
                    fail=1
                fi
            else
                log_fail "/dev/$sink_dev character device not found!"
                fail=1
            fi
            
            echo 0 > "$node_path/enable_source" 2>/dev/null
            res=$(cat "$node_path/enable_source" 2>/dev/null)
            
            if [ "$res" = "1" ]; then
                log_fail "Failed to disable source: $node_name"
                fail=1
            fi
        done
        
        if [ -f "$sink_path/enable_sink" ]; then
            echo 0 > "$sink_path/enable_sink" 2>/dev/null
        fi
    done
    i=$((i+1))
done

if [ "$sink_found" -eq 0 ]; then
    log_fail "No valid TMC sinks found!"
    fail=1
fi

if [ "$tpdm_found" -eq 0 ]; then
    log_fail "No valid TPDM sources found!"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    log_pass "$TESTNAME: PASS"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME: FAIL"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------" 