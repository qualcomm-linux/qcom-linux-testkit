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

TESTNAME="ETM-Enable-Disable"
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
    echo "$TESTNAME FAIL: No ETF sink found" >> "$res_file"
    exit 1
fi

ETM_LIST=""
for _etm in "$CS_BASE"/etm* "$CS_BASE"/coresight-etm* "$CS_BASE"/coresight-ete*; do
    [ -d "$_etm" ] || continue
    ETM_LIST="$ETM_LIST $_etm"
done

if [ -z "$ETM_LIST" ]; then
    log_fail "No Coresight ETM devices found"
    echo "$TESTNAME: FAIL" >> "$res_file"
    exit 1
fi

fail_count=0

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

log_info "Enabling ETF Sink at $ETF_PATH"
echo 1 > "$ETF_PATH/enable_sink" 2>/dev/null

for etm in $ETM_LIST; do
    if [ -f "$etm/enable_source" ]; then
        res=$(cat "$etm/enable_source" 2>/dev/null)
        log_info "$etm initial status: ${res:-unknown}"
        
        echo 1 > "$etm/enable_source" 2>/dev/null
        res=$(cat "$etm/enable_source" 2>/dev/null)
        
        if [ "$res" = "1" ]; then
            log_info "enable $etm PASS"
        else
            log_fail "enable $etm FAIL"
            fail_count=$((fail_count + 1))
        fi
        
        echo 0 > "$etm/enable_source" 2>/dev/null
        res=$(cat "$etm/enable_source" 2>/dev/null)
        
        if [ "$res" = "0" ]; then
            log_info "disable $etm PASS"
        else
            log_fail "disable $etm FAIL"
            fail_count=$((fail_count + 1))
        fi
    fi
done

log_info "Testing etm_enable_all_cores..."
for etm in $ETM_LIST; do
    if [ -f "$etm/enable_source" ]; then
        echo 1 > "$etm/enable_source" 2>/dev/null
    fi
done

for etm in $ETM_LIST; do
    if [ -f "$etm/enable_source" ]; then
        res=$(cat "$etm/enable_source" 2>/dev/null)
        if [ "$res" != "1" ]; then
            log_fail "Failed to enable $etm during all_cores test"
            fail_count=$((fail_count + 1))
        fi
    fi
done

log_info "Testing etm_disable_all_cores..."
for etm in $ETM_LIST; do
    if [ -f "$etm/enable_source" ]; then
        echo 0 > "$etm/enable_source" 2>/dev/null
    fi
done

for etm in $ETM_LIST; do
    if [ -f "$etm/enable_source" ]; then
        res=$(cat "$etm/enable_source" 2>/dev/null)
        if [ "$res" != "0" ]; then
            log_fail "Failed to disable $etm during all_cores test"
            fail_count=$((fail_count + 1))
        fi
    fi
done

reset_devices

if [ "$fail_count" -eq 0 ]; then
    log_pass "ETM enable and disable test end: PASS"
    echo "$TESTNAME: PASS" >> "$res_file"
else
    log_fail "ETM enable and disable test end: FAIL ($fail_count errors)"
    echo "$TESTNAME: FAIL" >> "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"