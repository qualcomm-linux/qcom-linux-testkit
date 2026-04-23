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

TESTNAME="TPDM-Enable-Disable"
res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
cs_base="/sys/bus/coresight/devices"

etf_path=$(find_path "tmc_etf0" "tmc_etf" "tmc_etf1" "coresight-tmc_etf" "coresight-tmc_etf0")
if [ -z "$etf_path" ]; then
    log_fail "TMC-ETF sink not found. Cannot proceed."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

tpdm_count=0
for node_path in "$cs_base"/tpdm* "$cs_base"/coresight-tpdm*; do
    [ -d "$node_path" ] && tpdm_count=$((tpdm_count + 1))
done

if [ "$tpdm_count" -eq 0 ]; then
    log_fail "No TPDM devices found on the system."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

fail=0
i=0

reset_devices

[ -f "$etf_path/enable_sink" ] && echo 1 > "$etf_path/enable_sink" 2>/dev/null

while [ "$i" -le 50 ]; do
    iter_fail=0
    
    for node_path in "$cs_base"/tpdm* "$cs_base"/coresight-tpdm*; do
        [ ! -d "$node_path" ] && continue
        
        node_name=$(basename "$node_path")
        
        if echo "$node_name" | grep -q "tpdm-turing-llm"; then
            continue
        fi
        
        if [ ! -f "$node_path/enable_source" ]; then
            continue
        fi
        
        echo 1 > "$node_path/enable_source" 2>/dev/null
        if [ "$(cat "$node_path/enable_source" 2>/dev/null)" != "1" ]; then
            iter_fail=1
            log_fail "Iter $i: Failed to enable $node_name"
            echo "$TESTNAME FAIL" > "$res_file"
        fi
        
        echo 0 > "$node_path/enable_source" 2>/dev/null
        if [ "$(cat "$node_path/enable_source" 2>/dev/null)" = "1" ]; then
            iter_fail=1
            log_fail "Iter $i: Failed to disable $node_name"
            echo "$TESTNAME FAIL" > "$res_file"
        fi
    done
    
    if [ "$iter_fail" -eq 0 ]; then
        log_info "Iteration: $i - PASS"
    else
        log_fail "Iteration: $i - FAIL"
        fail=1
    fi
    
    i=$((i+1))
done

[ -f "$etf_path/enable_sink" ] && echo 0 > "$etf_path/enable_sink" 2>/dev/null
reset_devices

if [ "$fail" -eq 0 ]; then
    log_pass "-------------enable/disable TPDMs Test PASS-------------"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "-------------enable/disable TPDMs Test FAIL-------------"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------" 