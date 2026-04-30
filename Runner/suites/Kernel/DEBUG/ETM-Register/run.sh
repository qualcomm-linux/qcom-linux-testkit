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

TESTNAME="ETM-Register"
if command -v find_test_case_by_name >/dev/null 2>&1; then
    test_path=$(find_test_case_by_name "$TESTNAME")
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

CS_BASE="/sys/bus/coresight/devices"

find_path() {
    for _dir_name in "$@"; do
        if [ -d "$CS_BASE/$_dir_name" ]; then
            echo "$CS_BASE/$_dir_name"
            return 0
        fi
    done
    echo ""
}

ETF_PATH=$(find_path "tmc_etf0" "tmc_etf" "tmc_etf1" "coresight-tmc_etf" "coresight-tmc_etf0")
if [ -z "$ETF_PATH" ]; then
    log_fail "TMC-ETF sink not found. Cannot proceed."
    echo "$TESTNAME FAIL - Missing ETF sink" > "$res_file"
    exit 1
fi

ETM_LIST=""
ETM_NUM=0
for _etm in "$CS_BASE"/etm* "$CS_BASE"/coresight-etm* "$CS_BASE"/coresight-ete*; do
    [ -d "$_etm" ] || continue
    ETM_LIST="$ETM_LIST $_etm"
    ETM_NUM=$((ETM_NUM + 1))
done

fail_count=0

if [ -z "$ETM_LIST" ] || [ "$ETM_NUM" -eq 0 ]; then
    log_fail "No Coresight ETM devices found"
    echo "$TESTNAME FAIL - No ETMs found" > "$res_file"
    exit 1
fi

log_info "Found $ETM_NUM ETM devices"

reset_devices() {
    for dev in "$CS_BASE"/*; do
        [ -d "$dev" ] || continue
        if [ -f "$dev/enable_source" ]; then
            echo 0 > "$dev/enable_source" 2>/dev/null
        fi
        if [ -f "$dev/enable_sink" ]; then
            echo 0 > "$dev/enable_sink" 2>/dev/null
        fi
    done
}

reset_devices

echo 1 > "$ETF_PATH/enable_sink" 2>/dev/null

for etm in $ETM_LIST; do
    log_info "Testing ETM node: $etm"
    
    if [ -f "$etm/enable_source" ]; then
        echo 1 > "$etm/enable_source" 2>/dev/null
    fi
    
    if [ -d "$etm/mgmt" ]; then
        for reg in "$etm"/mgmt/*; do
            [ -e "$reg" ] || continue
            if ! cat "$reg" >/dev/null 2>&1; then
                log_warn "FAIL: Could not read $reg"
                echo "FAIL: Could not read $reg" >> "$res_file"
                fail_count=$((fail_count + 1))
            fi
        done
    fi

    for node in "$etm"/*; do
        if [ -f "$node" ] && [ -r "$node" ]; then
            base_node=${node##*/}
            case "$base_node" in
                addr_single|addr_start|addr_stop) continue ;;
            esac
            cat "$node" >/dev/null 2>&1
        fi
    done
    
    if [ -f "$etm/enable_source" ]; then
        echo 0 > "$etm/enable_source" 2>/dev/null
    fi
done

reset_devices

if [ "$fail_count" -eq 0 ]; then
    log_pass "ETM Register Read Test Successful"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "ETM Register Read Test Failed ($fail_count read errors)"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"