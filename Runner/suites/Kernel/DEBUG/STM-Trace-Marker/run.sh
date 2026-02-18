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

runs=500
if [ -n "$1" ]; then
    case "$1" in
        ''|*[!0-9]*)
            log_warn "Invalid no. of runs '$1' - using default: 500"
            ;;
        *)
            runs=$1
            ;;
    esac
fi

if [ -z "$cs_base" ]; then
    cs_base="/sys/bus/coresight/devices"
fi

stm_path="$cs_base/stm0"
etf_path="$cs_base/tmc_etf0"
debugfs="/sys/kernel/debug"
configfs="/sys/kernel/config"
trace_marker="$debugfs/tracing/trace_marker"
stm_source_link="/sys/class/stm_source/ftrace/stm_source_link"
tmp_out="/tmp/etf0.bin"

find_first_existing_path() {
    for _dir_name in "$@"; do
        if [ -d "$cs_base/$_dir_name" ]; then
            echo "$cs_base/$_dir_name"
            return 0
        fi
    done
    echo ""
}

stm_path=$(find_first_existing_path "stm0" "coresight-stm")
etf_path=$(find_first_existing_path "tmc_etf0" "tmc_etf" "tmc_etf1")

cleanup_trace_marker() {
    log_info "Cleaning up Ftrace and STM settings..."
    
    [ -f "$debugfs/tracing/tracing_on" ] && echo 0 > "$debugfs/tracing/tracing_on" 2>/dev/null
    
    [ -f "$debugfs/tracing/events/sched/sched_switch/enable" ] && \
        echo 0 > "$debugfs/tracing/events/sched/sched_switch/enable" 2>/dev/null

    if [ -n "$stm_path" ] && [ -f "$stm_path/enable_source" ]; then
        echo 0 > "$stm_path/enable_source" 2>/dev/null
    fi
    
    if [ -n "$etf_path" ] && [ -f "$etf_path/enable_sink" ]; then
        echo 0 > "$etf_path/enable_sink" 2>/dev/null
    fi
}

if [ -z "$stm_path" ] || [ -z "$etf_path" ]; then
    log_fail "Device STM or ETF not found in $cs_base"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

stm_name=$(basename "$stm_path")
etf_name=$(basename "$etf_path")

cleanup_trace_marker

if command -v cs_global_reset >/dev/null 2>&1; then
    cs_global_reset
fi

mkdir -p "$configfs/stp-policy/$stm_name:p_basic.policy/default" 2>/dev/null

log_info "Configuring Coresight Path..."
echo 0 > "$stm_path/hwevent_enable" 2>/dev/null

echo 1 > "$etf_path/enable_sink"
if [ "$(cat "$etf_path/enable_sink" 2>/dev/null)" != "1" ]; then
    log_fail "Failed to enable ETF sink ($etf_name)"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

if [ -f "$stm_source_link" ]; then
    echo "$stm_name" > "$stm_source_link" 2>/dev/null
else
    log_fail "STM Source Link not found at $stm_source_link"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

echo 0xffffffff > "$stm_path/port_enable" 2>/dev/null
echo 1 > "$stm_path/enable_source"
if [ "$(cat "$stm_path/enable_source" 2>/dev/null)" != "1" ]; then
    log_fail "Failed to enable STM source ($stm_name)"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

if [ ! -f "$trace_marker" ]; then
    log_fail "Trace marker file missing: $trace_marker"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

log_info "Enabling Ftrace events..."
echo 1 > "$debugfs/tracing/events/sched/sched_switch/enable" 2>/dev/null
echo 1 > "$debugfs/tracing/tracing_on" 2>/dev/null

log_info "Generating $runs trace marker events..."
for i in $(seq 1 "$runs"); do
    echo "STM_TEST_MARKER_$i" > "$trace_marker" 2>/dev/null
done

sleep 10

echo 0 > "$debugfs/tracing/tracing_on" 2>/dev/null
echo 0 > "$debugfs/tracing/events/sched/sched_switch/enable" 2>/dev/null

log_info "Dumping ETF buffer to $tmp_out..."
true > "$tmp_out"

if [ -c "/dev/$etf_name" ]; then
    timeout 5s cat "/dev/$etf_name" > "$tmp_out" 2>/dev/null
else
    log_fail "/dev/$etf_name char device missing"
    echo "$TESTNAME FAIL" > "$res_file"
    cleanup_trace_marker
    exit 1
fi

if [ -s "$tmp_out" ]; then
    bin_size=$(stat -c%s "$tmp_out")
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

log_info "-------------------$TESTNAME Testcase Finished----------------------------" 