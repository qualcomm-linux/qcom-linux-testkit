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

TESTNAME="STM-Source-Enable-Disable"
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
STM_PATH="$CS_BASE/stm0"
[ ! -d "$STM_PATH" ] && STM_PATH="$CS_BASE/coresight-stm"
ETF_PATH="$CS_BASE/tmc_etf0"
DEBUGFS="/sys/kernel/debug/tracing"
FAIL_COUNT=0

reset_source_sink() {
    for dev in $(ls "$CS_BASE"); do
        path="$CS_BASE/$dev"
        if [ -f "$path/enable_source" ]; then
            val=$(cat "$path/enable_source")
            if [ "$val" -eq 1 ]; then
                echo 0 > "$path/enable_source"
                [ -f "$path/reset" ] && echo 1 > "$path/reset"
            fi
        fi
        if [ -f "$path/enable_sink" ]; then
            val=$(cat "$path/enable_sink")
            [ "$val" -eq 1 ] && echo 0 > "$path/enable_sink"
        fi
    done
}


if [ ! -d "$STM_PATH" ]; then
    log_fail "STM device not found"
    echo "$TESTNAME: FAIL" >> "$res_file"
    exit 1
fi

log_info "Setting up STP policy..."
mkdir -p /sys/kernel/config/stp-policy/stm0:p_ost.policy/default

log_info "Initial cleanup..."
reset_source_sink

if [ -f "$STM_PATH/hwevent_enable" ]; then
    echo 0 > "$STM_PATH/hwevent_enable"
fi
if [ -f "$STM_PATH/port_enable" ]; then
    echo 0xffffffff > "$STM_PATH/port_enable"
fi
echo 0 > "$DEBUGFS/events/enable"

log_info "Starting 50 iteration loop..."

for i in $(seq 1 50); do
    reset_source_sink
    
    if [ -f "$ETF_PATH/enable_sink" ]; then
        echo 1 > "$ETF_PATH/enable_sink"
    fi

    echo 1 > "$STM_PATH/enable_source"
    val=$(cat "$STM_PATH/enable_source")
    
    if [ "$val" -ne 1 ]; then
        log_fail "Iteration $i: Failed to enable STM source"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    echo 0 > "$STM_PATH/enable_source"
    val=$(cat "$STM_PATH/enable_source")
    
    if [ "$val" -ne 0 ]; then
        log_fail "Iteration $i: Failed to disable STM source"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

reset_source_sink

if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "STM source enable/disable loop passed (50 iterations)"
    echo "$TESTNAME: PASS" >> "$res_file"
else
    log_fail "STM source enable/disable loop failed ($FAIL_COUNT failures)"
    echo "$TESTNAME: FAIL" >> "$res_file"
fi

# log_info "-------------------$TESTNAME Testcase Finished----------------------------"