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
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

CS_BASE="/sys/bus/coresight/devices"
FAIL_COUNT=0

find_first_existing_path() {
    for _dir_name in "$@"; do
        if [ -d "$CS_BASE/$_dir_name" ]; then
            echo "$CS_BASE/$_dir_name"
            return 0
        fi
    done
    echo ""
}

STM_PATH=$(find_first_existing_path "stm0" "coresight-stm")
ETF_PATH=$(find_first_existing_path "tmc_etf0" "tmc_etf" "tmc_etf1")
DEBUGFS="/sys/kernel/debug/tracing"

reset_source_sink() {
    for dev in "$CS_BASE"/*/; do
        [ -d "$dev" ] || continue
        if [ -f "$dev/enable_source" ]; then
            val=$(cat "$dev/enable_source" 2>/dev/null)
            if [ "$val" = "1" ]; then
                echo 0 > "$dev/enable_source" 2>/dev/null
                [ -f "$dev/reset" ] && echo 1 > "$dev/reset" 2>/dev/null
            fi
        fi
        if [ -f "$dev/enable_sink" ]; then
            val=$(cat "$dev/enable_sink" 2>/dev/null)
            [ "$val" = "1" ] && echo 0 > "$dev/enable_sink" 2>/dev/null
        fi
    done
}

if [ -z "$STM_PATH" ]; then
    log_fail "STM device not found in $CS_BASE"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

STM_NAME=$(basename "$STM_PATH")

log_info "Setting up STP policy..."
STP_POLICY_BASE="/sys/kernel/config/stp-policy"

if ! grep -q "configfs" /proc/mounts 2>/dev/null; then
    log_warn "configfs not mounted — skipping STP policy setup"
    echo "$TESTNAME Skip" > "$res_file"
    exit 0
fi

if [ ! -d "$STP_POLICY_BASE" ]; then
    log_warn "STP policy path not available: $STP_POLICY_BASE — skipping"
    echo "$TESTNAME Skip" > "$res_file"
    exit 0
fi

if mkdir "$STP_POLICY_BASE/$STM_NAME:p_ost.policy" 2>/dev/null && \
   mkdir "$STP_POLICY_BASE/$STM_NAME:p_ost.policy/default" 2>/dev/null; then
    log_info "Using STP policy: p_ost"
elif mkdir "$STP_POLICY_BASE/$STM_NAME:p_basic.policy" 2>/dev/null && \
     mkdir "$STP_POLICY_BASE/$STM_NAME:p_basic.policy/default" 2>/dev/null; then
    log_info "Using STP policy: p_basic"
elif [ -d "$STP_POLICY_BASE/$STM_NAME:p_basic.policy/default" ]; then
    log_info "Using existing STP policy: p_basic"
elif [ -d "$STP_POLICY_BASE/$STM_NAME:p_ost.policy/default" ]; then
    log_info "Using existing STP policy: p_ost"
else
    log_warn "No STP policy could be created — skipping"
    echo "$TESTNAME Skip" > "$res_file"
    exit 0
fi

log_info "Initial cleanup..."
reset_source_sink

if [ -f "$STM_PATH/hwevent_enable" ]; then
    echo 0 > "$STM_PATH/hwevent_enable"
fi
if [ -f "$STM_PATH/port_enable" ]; then
    echo 0xffffffff > "$STM_PATH/port_enable"
fi

if ! grep -q "debugfs" /proc/mounts 2>/dev/null; then
    log_warn "debugfs not mounted — skipping events/enable reset"
elif [ -f "$DEBUGFS/events/enable" ]; then
    echo 0 > "$DEBUGFS/events/enable"
else
    log_warn "$DEBUGFS/events/enable not found — skipping"
fi

log_info "Starting 50 iteration loop..."

if [ -n "$ETF_PATH" ] && [ -f "$ETF_PATH/enable_sink" ]; then
    echo 1 > "$ETF_PATH/enable_sink" 2>/dev/null
fi

_count=1
while [ "$_count" -le 50 ]; do
    
    echo 1 > "$STM_PATH/enable_source" 2>/dev/null
    val=$(cat "$STM_PATH/enable_source" 2>/dev/null)
    
    if [ "$val" != "1" ]; then
        log_fail "Iteration $_count: Failed to enable STM source"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    echo 0 > "$STM_PATH/enable_source" 2>/dev/null
    val=$(cat "$STM_PATH/enable_source" 2>/dev/null)
    
    if [ "$val" != "0" ]; then
        log_fail "Iteration $_count: Failed to disable STM source"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    _count=$((_count + 1))
done

reset_source_sink

if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "STM source enable/disable loop passed (50 iterations)"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "STM source enable/disable loop failed ($FAIL_COUNT failures)"
    echo "$TESTNAME FAIL" > "$res_file"
fi
