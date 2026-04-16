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

TESTNAME="TPDM-Integration-Test"
res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
cs_base="/sys/bus/coresight/devices"

etf_path=$(find_path "tmc_etf0" "tmc_etf" "tmc_etf1" "coresight-tmc_etf" "coresight-tmc_etf0")
if [ -z "$etf_path" ]; then
    log_fail "TMC-ETF sink not found. Cannot proceed with integration test."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# shellcheck disable=SC2329
cleanup() {
    reset_devices
    disable_npu_clocks
}

trap cleanup EXIT INT TERM

reset_devices
enable_npu_clocks

if [ -f "$etf_path/enable_sink" ]; then
    echo 1 > "$etf_path/enable_sink" 2>/dev/null
fi

retval=0
tpdm_found=0

for tpdm_path in "$cs_base"/tpdm* "$cs_base"/coresight-tpdm*; do
    [ ! -d "$tpdm_path" ] && continue
    tpdm_found=1
    
    tpdm_name=$(basename "$tpdm_path")
    
    if [ ! -f "$tpdm_path/integration_test" ]; then
        continue
    fi
    
    log_info "$tpdm_name Integration Test Start"
    
    if [ -f "$tpdm_path/enable_source" ]; then
        echo 1 > "$tpdm_path/enable_source" 2>/dev/null
    fi
    
    pre_rwp=""
    if [ -f "$etf_path/mgmt/rwp" ]; then
        # shellcheck disable=SC2162
        read -r pre_rwp < "$etf_path/mgmt/rwp"
    fi
    
    i=1
    while [ "$i" -le 10 ]; do
        echo 1 > "$tpdm_path/integration_test" 2>/dev/null
        echo 2 > "$tpdm_path/integration_test" 2>/dev/null
        i=$((i+1))
    done
    
    curr_rwp=""
    if [ -f "$etf_path/mgmt/rwp" ]; then
        # shellcheck disable=SC2162
        read -r curr_rwp < "$etf_path/mgmt/rwp"
    fi
    
    if [ -n "$curr_rwp" ] && [ "$curr_rwp" != "$pre_rwp" ]; then
        log_info "$tpdm_name Integration Test PASS"
    else
        log_fail "$tpdm_name Integration Test FAIL"
        retval=1
    fi
    
    if [ -f "$tpdm_path/enable_source" ]; then
        echo 0 > "$tpdm_path/enable_source" 2>/dev/null
    fi
done

if [ "$tpdm_found" -eq 0 ]; then
    log_fail "FAIL: No TPDM device found"
    echo "$TESTNAME FAIL" > "$res_file"
    retval=1
fi

if [ "$retval" -eq 0 ]; then
    log_pass "-----PASS: All TPDM devices integration test-----"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "----FAIL: Some TPDM devices integration test fail----"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------" 