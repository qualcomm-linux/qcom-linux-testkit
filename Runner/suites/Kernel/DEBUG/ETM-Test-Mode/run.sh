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
rm -f "$res_file"
touch "$res_file"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

CS_BASE="/sys/bus/coresight/devices"
ETR_PATH="$CS_BASE/tmc_etr0"
[ ! -d "$ETR_PATH" ] && ETR_PATH="$CS_BASE/tmc_etr" 


reset_source_sink() {
    if [ -f "$CS_BASE/stm0/enable_source" ]; then
        echo 0 > "$CS_BASE/stm0/enable_source"
    fi
    
    # shellcheck disable=SC2086
    for etm in $ETM_LIST; do
        if [ -f "$etm/enable_source" ]; then
            echo 0 > "$etm/enable_source"
        fi
    done

    if [ -f "$ETR_PATH/enable_sink" ]; then
        echo 0 > "$ETR_PATH/enable_sink"
    fi
    if [ -f "$CS_BASE/tmc_etf0/enable_sink" ]; then
        echo 0 > "$CS_BASE/tmc_etf0/enable_sink"
    fi
}


# shellcheck disable=SC2010
ETM_LIST=$(ls -d "$CS_BASE"/etm* "$CS_BASE"/coresight-etm* 2>/dev/null)

if [ -z "$ETM_LIST" ]; then
    log_fail "No Coresight ETM devices found"
    echo "$TESTNAME: FAIL" >> "$res_file"
    exit 1
fi

log_info "Found ETM devices: $(echo "$ETM_LIST" | tr '\n' ' ')"

reset_source_sink

if [ -d "$ETR_PATH" ]; then
    log_info "Enabling Sink: $ETR_PATH"
    echo 1 > "$ETR_PATH/enable_sink"
else
    log_fail "TMC-ETR sink not found"
    echo "$TESTNAME: FAIL" >> "$res_file"
    exit 1
fi

fail_count=0

# shellcheck disable=SC2086
for etm in $ETM_LIST; do
    log_info "Configuring $etm"
    
    if [ -f "$etm/mode" ]; then
        echo 0XFFFFFFF > "$etm/mode"
        if [ $? -ne 0 ]; then
             log_warn "Failed to set mode on $etm"
             fail_count=$((fail_count + 1))
        fi
    else
        log_warn "$etm does not have 'mode' attribute"
    fi

    if [ -f "$etm/enable_source" ]; then
        echo 1 > "$etm/enable_source"
        if [ $? -ne 0 ]; then
             log_fail "Failed to enable $etm"
             fail_count=$((fail_count + 1))
        fi
    fi
done

if [ $fail_count -eq 0 ]; then
    log_pass "ETM Mode Configuration Successful"
    echo "$TESTNAME: PASS" >> "$res_file"
else
    log_fail "ETM Mode Configuration Failed ($fail_count errors)"
    echo "$TESTNAME: FAIL" >> "$res_file"
fi

# shellcheck disable=SC2086
for etm in $ETM_LIST; do
    if [ -f "$etm/mode" ]; then
        echo 0x0 > "$etm/mode"
    fi
done

reset_source_sink

# log_info "-------------------$TESTNAME Testcase Finished----------------------------"