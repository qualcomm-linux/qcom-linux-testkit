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

TESTNAME="TPDM-Interface-Access"
res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
cs_base="/sys/bus/coresight/devices"

etf_path=$(find_path "tmc_etf0" "tmc_etf" "tmc_etf1" "coresight-tmc_etf" "coresight-tmc_etf0")
if [ -z "$etf_path" ]; then
    log_warn "TMC-ETF sink not found. Some operations may fail."
fi

dataset_map(){
    case "$1" in
        2) mode_config="dsb" ;;
        4) mode_config="cmb" ;;
        8) mode_config="tc" ;;
        16) mode_config="bc" ;;
        24) mode_config="tc bc" ;;
        32) mode_config="gpr" ;;
        36) mode_config="cmb gpr" ;;
        50) mode_config="dsb bc gpr" ;;
        62) mode_config="dsb cmb tc bc gpr" ;;
        64) mode_config="mcmb" ;;
        *) mode_config="none" ;;
    esac
}

mode_atrr(){
    mode=$1
    fail_flag=0
    
    for attr_file in "$cs_base/$tpdm_device/$mode"*; do
        if [ -f "$attr_file" ] && [ -r "$attr_file" ]; then
            if ! cat "$attr_file" >/dev/null 2>&1; then
                log_fail "Failed to read attribute: $attr_file"
                fail_flag=1
            fi
        fi
    done
    return $fail_flag
}

fail_count=0
tpdm_found=0

for npu_dir in "$cs_base"/tpdm-npu* "$cs_base"/coresight-tpdm-npu*; do
    if [ -d "$npu_dir" ]; then
        if [ -f "/sys/kernel/debug/npu/ctrl" ]; then
            echo on > /sys/kernel/debug/npu/ctrl 2>/dev/null
        elif [ -f "/d/npu/ctrl" ]; then
            echo on > /d/npu/ctrl 2>/dev/null
        fi
        break
    fi
done

log_info "Performing initial device reset..."
reset_devices
[ -n "$etf_path" ] && [ -f "$etf_path/enable_sink" ] && echo 1 > "$etf_path/enable_sink"

log_info "--- Phase 1: Source dataset mode tests ---"

for tpdm_path in "$cs_base"/tpdm* "$cs_base"/coresight-tpdm*; do
    [ ! -d "$tpdm_path" ] && continue
    tpdm_device=$(basename "$tpdm_path")
    tpdm_found=$((tpdm_found + 1))
    
    if echo "$tpdm_device" | grep -q "tpdm-turing-llm"; then
        log_info "Skipping unsupported source: $tpdm_device"
        continue
    fi
    
    if [ ! -f "$tpdm_path/enable_source" ]; then
        continue
    fi
    
    log_info "Testing device: $tpdm_device"
    
    echo 1 > "$tpdm_path/enable_source" 2>/dev/null
    
    datasets=$(cat "$tpdm_path/enable_datasets" 2>/dev/null)
    set_mode=$(printf "%d" "0x$datasets" 2>/dev/null || echo 0)
    dataset_map "$set_mode"
    
    log_info "  Default datasets: $datasets (Mode: $set_mode) -> Configurations: $mode_config"
    
    for mode in $mode_config; do
        if [ "$mode" = "none" ]; then
            continue
        fi
        
        mode_atrr "$mode"
        if mode_atrr "$mode"; then
            log_pass "  PASS: $mode attributes"
        else
            log_fail "  FAIL: $mode attributes"
            fail_count=$((fail_count + 1))
        fi
    done
    
    echo 0 > "$tpdm_path/enable_source" 2>/dev/null
done

if [ "$tpdm_found" -eq 0 ]; then
    log_fail "Result: $TESTNAME FAIL (No TPDM devices found)"
    echo "$TESTNAME FAIL" > "$res_file"
    fail_count=$((fail_count + 1))
    exit 1
fi

if [ "$fail_count" -eq 0 ]; then
    log_pass "Phase 1 Completed: All TPDM mode attributes check passed"
else
    log_fail "Phase 1 Completed: TPDM mode attributes check failed with $fail_count errors"
fi

log_info "Performing mid-test device reset..."
reset_devices

log_info "--- Phase 2: Readable attributes check ---"

for tpdm_path in "$cs_base"/tpdm* "$cs_base"/coresight-tpdm*; do
    [ ! -d "$tpdm_path" ] && continue
    tpdm_device=$(basename "$tpdm_path")
    
    if echo "$tpdm_device" | grep -q "tpdm-turing-llm"; then
        continue
    fi
    
    if_count=0
    for attr_file in "$tpdm_path"/*; do
        if [ -f "$attr_file" ] && [ -r "$attr_file" ]; then
            if_count=$((if_count + 1))
        fi
    done
    
    log_info "Reading $if_count accessible nodes under $tpdm_device"
    
    for attr_file in "$tpdm_path"/*; do
        if [ -f "$attr_file" ] && [ -r "$attr_file" ]; then
            cat "$attr_file" >/dev/null 2>&1
        fi
    done
done

if [ -f "/sys/kernel/debug/npu/ctrl" ]; then
    echo off > /sys/kernel/debug/npu/ctrl 2>/dev/null
elif [ -f "/d/npu/ctrl" ]; then
    echo off > /d/npu/ctrl 2>/dev/null
fi

if [ "$fail_count" -eq 0 ]; then
    log_pass "Result: $TESTNAME PASS"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "Result: $TESTNAME FAIL ($fail_count errors detected)"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------" 