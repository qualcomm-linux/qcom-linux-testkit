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

TESTNAME="TGU-Enable-Disable"
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
POTENTIAL_SINKS="coresight-tmc-etr coresight-tmc-etf tmc_etr0 tmc_etf0"


global_reset() {
    if [ -f "/sys/bus/coresight/reset_source_sink" ]; then
        echo 1 > "/sys/bus/coresight/reset_source_sink" 2>/dev/null
    else
        for s in $POTENTIAL_SINKS; do
            if [ -f "$CS_BASE/$s/enable_sink" ]; then
                echo 0 > "$CS_BASE/$s/enable_sink" 2>/dev/null
            fi
        done
    fi
}


if [ ! -d "$CS_BASE" ]; then
    log_fail "Coresight directory not found"
    echo "Coresight directory not found" >> "$res_file"
    exit 1
fi

# shellcheck disable=SC2010
TGU_LIST=$(ls "$CS_BASE" | grep "tgu")

if [ -z "$TGU_LIST" ]; then
    log_warn "No TGU (Trace Generation Unit) devices found. Skipping test."
    echo "TGU Discovery: Skip" >> "$res_file"
    exit 0
fi

log_info "Found TGUs: $TGU_LIST"

for sink_name in $POTENTIAL_SINKS; do
    sink_path="$CS_BASE/$sink_name"
    
    if [ ! -d "$sink_path" ]; then
        continue
    fi
    
    log_info "--- Testing with Sink: $sink_name ---"
    
    global_reset
    
    if [ -f "$sink_path/enable_sink" ]; then
        if ! echo 1 > "$sink_path/enable_sink"; then
            log_fail "Failed to enable sink: $sink_name"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi
    else
        log_warn "Sink $sink_name has no enable_sink node"
        continue
    fi
    
    for tgu in $TGU_LIST; do
        tgu_path="$CS_BASE/$tgu"
        
        if ! echo 1 > "$tgu_path/enable_tgu"; then
            log_fail "Failed to enable TGU: $tgu (Sink: $sink_name)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            log_info "Enabled $tgu OK"
        fi
        
        if ! echo 0 > "$tgu_path/enable_tgu"; then
            log_fail "Failed to disable TGU: $tgu (Sink: $sink_name)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            log_info "Disabled $tgu OK"
        fi
    done
    
    echo 0 > "$sink_path/enable_sink" 2>/dev/null
done


if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "TGU Enable/Disable Test PASS"
    echo "$TESTNAME: PASS" >> "$res_file"
else
    log_fail "TGU Enable/Disable Test FAIL ($FAIL_COUNT errors)"
    echo "$TESTNAME: FAIL" >> "$res_file"
fi

# log_info "-------------------$TESTNAME Testcase Finished----------------------------"

