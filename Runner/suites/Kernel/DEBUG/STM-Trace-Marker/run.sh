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
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/coresight_common.sh"

TESTNAME="STM-Trace-Marker"
if command -v find_test_case_by_name >/dev/null 2>&1; then
    test_path=$(find_test_case_by_name "$TESTNAME")
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Checking if required tools are available"

for tool in timeout stat seq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_skip "Required tool '$tool' not found. Skipping test."
        echo "$TESTNAME SKIP" > "$res_file" 
        exit 0
    fi
done

RUNS=500
if [ -n "$1" ]; then
    case "$1" in
        ''|*[!0-9]*)
            log_warn "Invalid RUNS argument '$1' - using default: 500"
            ;;
        *)
            RUNS=$1
            ;;
    esac
fi

if [ -z "$CS_BASE" ]; then
    CS_BASE="/sys/bus/coresight/devices"
fi

STM_PATH="$CS_BASE/stm0"
ETF_PATH="$CS_BASE/tmc_etf0"
DEBUG_FS="/sys/kernel/debug"
CONFIG_FS="/sys/kernel/config"
TRACE_MARKER="$DEBUG_FS/tracing/trace_marker"
STM_SOURCE_LINK="/sys/class/stm_source/ftrace/stm_source_link"
TMP_OUT="/tmp/etf0.bin"

find_first_existing_path() {
    for _dir_name in "$@"; do
        if [ -d "$CS_BASE/$_dir_name" ]; then
            echo "$CS_BASE/$_dir_name"
            return 0
        fi
    done
    echo ""
}

# Resolve paths
STM_PATH=$(find_first_existing_path "stm0" "coresight-stm")
ETF_PATH=$(find_first_existing_path "tmc_etf0" "tmc_etf" "tmc_etf1")

cleanup_trace_marker() {
    log_info "Cleaning up Ftrace and STM settings..."
    
    [ -f "$DEBUG_FS/tracing/tracing_on" ] && echo 0 > "$DEBUG_FS/tracing/tracing_on" 2>/dev/null
    
    [ -f "$DEBUG_FS/tracing/events/sched/sched_switch/enable" ] && \
        echo 0 > "$DEBUG_FS/tracing/events/sched/sched_switch/enable" 2>/dev/null

    if [ -n "$STM_PATH" ] && [ -f "$STM_PATH/enable_source" ]; then
        echo 0 > "$STM_PATH/enable_source" 2>/dev/null
    fi
    
    if [ -n "$ETF_PATH" ] && [ -f "$ETF_PATH/enable_sink" ]; then
        echo 0 > "$ETF_PATH/enable_sink" 2>/dev/null
    fi
}

if [ -z "$STM_PATH" ] || [ -z "$ETF_PATH" ]; then
    log_fail "Device STM or ETF not found in $CS_BASE"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

STM_NAME=$(basename "$STM_PATH")
ETF_NAME=$(basename "$ETF_PATH")

cleanup_trace_marker

if command -v cs_global_reset >/dev/null 2>&1; then
    cs_global_reset
fi

mkdir -p "$CONFIG_FS/stp-policy/$STM_NAME:p_basic.policy/default" 2>/dev/null

log_info "Configuring Coresight Path..."
echo 0 > "$STM_PATH/hwevent_enable" 2>/dev/null

echo 1 > "$ETF_PATH/enable_sink"
if [ "$(cat "$ETF_PATH/enable_sink" 2>/dev/null)" != "1" ]; then
    log_fail "Failed to enable ETF sink ($ETF_NAME)"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

if [ -f "$STM_SOURCE_LINK" ]; then
    echo "$STM_NAME" > "$STM_SOURCE_LINK" 2>/dev/null
else
    log_fail "STM Source Link not found at $STM_SOURCE_LINK"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

echo 0xffffffff > "$STM_PATH/port_enable" 2>/dev/null
echo 1 > "$STM_PATH/enable_source"
if [ "$(cat "$STM_PATH/enable_source" 2>/dev/null)" != "1" ]; then
    log_fail "Failed to enable STM source ($STM_NAME)"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

if [ ! -f "$TRACE_MARKER" ]; then
    log_fail "Trace marker file missing: $TRACE_MARKER"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

log_info "Enabling Ftrace events..."
echo 1 > "$DEBUG_FS/tracing/events/sched/sched_switch/enable" 2>/dev/null
echo 1 > "$DEBUG_FS/tracing/tracing_on" 2>/dev/null

log_info "Generating $RUNS trace marker events..."
for i in $(seq 1 "$RUNS"); do
    echo "STM_TEST_MARKER_$i" > "$TRACE_MARKER" 2>/dev/null
done

sleep 10

echo 0 > "$DEBUG_FS/tracing/tracing_on" 2>/dev/null
echo 0 > "$DEBUG_FS/tracing/events/sched/sched_switch/enable" 2>/dev/null

log_info "Dumping ETF buffer to $TMP_OUT..."
true > "$TMP_OUT"

if [ -c "/dev/$ETF_NAME" ]; then
    timeout 5s cat "/dev/$ETF_NAME" > "$TMP_OUT" 2>/dev/null
else
    log_fail "/dev/$ETF_NAME char device missing"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

if [ -s "$TMP_OUT" ]; then
    bin_size=$(stat -c%s "$TMP_OUT")
    log_info "Captured binary size: $bin_size bytes"
    
    if [ "$bin_size" -ge 65536 ]; then
        log_pass "Successfully captured STM trace data ($bin_size bytes)"
        echo "$TESTNAME PASS" > "$res_file"
    else
        log_fail "Captured data too small ($bin_size bytes). Expected >= 4096"
        echo "$TESTNAME FAIL" > "$res_file"
    fi
else
    log_fail "Output file not generated or is completely empty"
    echo "$TESTNAME FAIL" > "$res_file"
fi

cleanup_trace_marker

# log_info "-------------------$TESTNAME Testcase Finished----------------------------"