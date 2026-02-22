#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Script to test the QDSS CTI driver.
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

TESTNAME="CTI-Enable-Disable"
if command -v find_test_case_by_name >/dev/null 2>&1; then
    test_path=$(find_test_case_by_name "$TESTNAME")
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

res_file="./$TESTNAME.res"
rm -f "$res_file"
touch "$res_file"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

CS_BASE="/sys/bus/coresight/devices"
FAIL_COUNT=0


reset_devices() {
    log_info "Resetting Coresight devices..."
    if [ -f "$CS_BASE/tmc_etf0/enable_sink" ]; then
        echo 0 > "$CS_BASE/tmc_etf0/enable_sink" 2>/dev/null
    fi
    if [ -f "$CS_BASE/tmc_etr0/enable_sink" ]; then
        echo 0 > "$CS_BASE/tmc_etr0/enable_sink" 2>/dev/null
    fi
    if [ -f "$CS_BASE/stm0/enable_source" ]; then
        echo 0 > "$CS_BASE/stm0/enable_source" 2>/dev/null
    fi
}


if [ ! -d "$CS_BASE" ]; then
    log_fail "Coresight directory not found: $CS_BASE"
    echo "Coresight directory not found" >> "$res_file"
    exit 1
fi

reset_devices

if [ -f "$CS_BASE/tmc_etf0/enable_sink" ]; then
    echo 1 > "$CS_BASE/tmc_etf0/enable_sink"
else
    log_warn "tmc_etf0 not found, proceeding without it..."
fi

# shellcheck disable=SC2010
CTI_LIST=$(ls "$CS_BASE" | grep 'cti')

if [ -z "$CTI_LIST" ]; then
    log_fail "No CTI devices found."
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    for cti in $CTI_LIST; do
        dev_path="$CS_BASE/$cti"
        
        if [ ! -f "$dev_path/enable" ]; then
            log_warn "Skipping $cti: 'enable' node not found"
            continue
        fi

        log_info "Testing Device: $cti"

        if ! echo 1 > "$dev_path/enable"; then
            log_fail "$cti: Failed to write 1 to enable"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi

        res=$(cat "$dev_path/enable")
        if [ "$res" -eq 1 ]; then
            log_pass "$cti Enabled Successfully"
        else
            log_fail "$cti Failed to Enable (Value: $res)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi

        if ! echo 0 > "$dev_path/enable"; then
            log_fail "$cti: Failed to write 0 to enable"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi

        res=$(cat "$dev_path/enable")
        if [ "$res" -eq 0 ]; then
            log_pass "$cti Disabled Successfully"
        else
            log_fail "$cti Failed to Disable (Value: $res)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done
fi

reset_devices

if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "CTI Enable/Disable Test Completed Successfully"
    echo "$TESTNAME: PASS" >> "$res_file"
else
    log_fail "CTI Enable/Disable Test Failed ($FAIL_COUNT errors)"
    echo "$TESTNAME: FAIL" >> "$res_file"
fi

# log_info "-------------------$TESTNAME Testcase Finished----------------------------"