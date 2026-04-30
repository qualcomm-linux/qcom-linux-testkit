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

TESTNAME="ETM-Test-Mode"
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

reset_source_sink() {
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

ETR_PATH=$(find_path "tmc_etr0" "tmc_etr" "tmc_etr1" "coresight-tmc_etr")
if [ -z "$ETR_PATH" ]; then
    log_fail "TMC-ETR sink not found"
    echo "$TESTNAME FAIL: No ETR sink found" >> "$res_file"
    exit 1
fi

ETM_LIST=""
for _etm in "$CS_BASE"/etm* "$CS_BASE"/coresight-etm*; do
    [ -d "$_etm" ] || continue
    ETM_LIST="$ETM_LIST $_etm"
done
ETM_LIST="${ETM_LIST# }"

if [ -z "$ETM_LIST" ]; then
    log_fail "No Coresight ETM devices found"
    echo "$TESTNAME FAIL: No ETM devices found" >> "$res_file"
    exit 1
fi

reset_source_sink

log_info "Enabling Sink: $ETR_PATH"
echo 1 > "$ETR_PATH/enable_sink" 2>/dev/null

fail_count=0
no_mode_count=0
etm_total=0

for etm in $ETM_LIST; do
    etm_total=$((etm_total + 1))
    etm_name=$(basename "$etm")
    
    log_info "Configuring $etm_name"

    if [ ! -f "$etm/mode" ]; then
        log_fail "$etm_name does not have 'mode' attribute - required for this test"
        echo "FAIL: $etm_name missing 'mode' attribute" >> "$res_file"
        fail_count=$((fail_count + 1))
        no_mode_count=$((no_mode_count + 1))
        continue
    fi

    echo 0xFFFFFFF > "$etm/mode" 2>/dev/null
    actual_mode=$(cat "$etm/mode" 2>/dev/null)
    
    if [ -z "$actual_mode" ]; then
        log_fail "Failed to read back mode from $etm_name after write"
        echo "FAIL: $etm_name failed to read back mode" >> "$res_file"
        fail_count=$((fail_count + 1))
        continue
    fi
    
    expect_dec=$((0xFFFFFFF))
    actual_dec=$((${actual_mode:-0}))
    
    if [ "$actual_dec" != "$expect_dec" ]; then
        log_fail "$etm_name mode readback mismatch: wrote 0xFFFFFFF, read back $actual_mode"
        echo "FAIL: $etm_name mode mismatch (Wrote 0xFFFFFFF, Read $actual_mode)" >> "$res_file"
        fail_count=$((fail_count + 1))
        continue
    fi
    
    log_info "$etm_name mode set and verified: $actual_mode"

    if [ -f "$etm/enable_source" ]; then
        echo 1 > "$etm/enable_source" 2>/dev/null
        readback=$(cat "$etm/enable_source" 2>/dev/null)
        if [ "$readback" != "1" ]; then
            log_fail "Failed to enable $etm_name: enable_source readback=$readback (expected 1)"
            echo "FAIL: $etm_name failed to enable (enable_source readback=$readback)" >> "$res_file"
            fail_count=$((fail_count + 1))
        else
            log_info "$etm_name enabled and verified (enable_source=1)"
        fi
    else
        log_warn "$etm_name has no enable_source attribute, skipping enable step"
    fi
done

if [ "$no_mode_count" -eq "$etm_total" ]; then
    log_fail "No ETM devices had a 'mode' attribute - test cannot validate ETM mode"
    echo "$TESTNAME FAIL" >> "$res_file"
elif [ "$fail_count" -eq 0 ]; then
    log_pass "ETM Mode Configuration Successful"
    echo "$TESTNAME PASS" >> "$res_file"
else
    log_fail "ETM Mode Configuration Failed ($fail_count errors)"
    echo "$TESTNAME FAIL" >> "$res_file"
fi

for etm in $ETM_LIST; do
    if [ -f "$etm/mode" ]; then
        echo 0x0 > "$etm/mode" 2>/dev/null
    fi
done

reset_source_sink

log_info "-------------------$TESTNAME Testcase Finished----------------------------"