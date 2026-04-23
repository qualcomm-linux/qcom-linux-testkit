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

TESTNAME="ETM_CPU_Toggle_Composite_Base"
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
CPU_BASE="/sys/devices/system/cpu"
TMP_DIR="/tmp/etm-stress"
CORES=$(grep -c "processor" /proc/cpuinfo)
RUNS=${1:-100} 
FAIL_COUNT=0
pass_count=0

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

find_path() {
    for _dir_name in "$@"; do
        if [ -d "$CS_BASE/$_dir_name" ]; then
            echo "$CS_BASE/$_dir_name"
            return 0
        fi
    done
    echo ""
}

ETF_SINK=$(find_path "tmc_etf0" "tmc_etf" "tmc_etf1" "coresight-tmc_etf" "coresight-tmc_etf0")
if [ -z "$ETF_SINK" ]; then
    log_fail "TMC-ETF sink not found. Cannot proceed."
    echo "$TESTNAME FAIL - Missing ETF sink" > "$res_file"
    exit 1
fi

ETF_DEV_NAME=$(basename "$ETF_SINK")
ETF_DEV_NODE="/dev/$ETF_DEV_NAME"

ETM_LIST=""
for _etm in "$CS_BASE"/etm* "$CS_BASE"/coresight-etm* "$CS_BASE"/coresight-ete*; do
    [ -d "$_etm" ] || continue
    ETM_LIST="$ETM_LIST $_etm"
done

if [ -z "$ETM_LIST" ]; then
    log_fail "No Coresight ETM devices found"
    echo "$TESTNAME FAIL - No ETMs found" > "$res_file"
    exit 1
fi

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

etm_all_cores() {
    state=$1
    # shellcheck disable=SC2086
    for etm_node in $ETM_LIST; do
        if [ -f "$etm_node/enable_source" ]; then
            echo "$state" > "$etm_node/enable_source" 2>/dev/null
        fi
    done
}

toggle_cpu() {
    cpu_id=$1
    if [ "$cpu_id" -eq 0 ]; then return; fi
    
    online_path="$CPU_BASE/cpu$cpu_id/online"
    if [ -f "$online_path" ]; then
        echo 0 > "$online_path" 2>/dev/null
        sleep 0.1
        echo 1 > "$online_path" 2>/dev/null
    fi
}

cpu_stress_loop() {
    while true; do
        rand_val=$(od -An -N2 -tu2 /dev/urandom | tr -dc '0-9')
        rand_val=${rand_val:-1}
        target=$(( (rand_val % (CORES - 1)) + 1 ))
        toggle_cpu "$target"
        sleep 0.2
    done
}

trap cleanup EXIT

log_info "Targeting $CORES cores for $RUNS iterations"

reset_devices

cpu_stress_loop &
HOTPLUG_PID=$!
log_info "Started CPU hotplug stress (PID: $HOTPLUG_PID)"

for i in $(seq 1 "$RUNS"); do
    log_info "Iteration $i/$RUNS..."

    echo 1 > "$ETF_SINK/enable_sink" 2>/dev/null

    etm_all_cores 1
    sleep 1

    etm_all_cores 0
    echo 0 > "$ETF_SINK/enable_sink" 2>/dev/null
    sleep 0.2

    outfile="$TMP_DIR/trace_iter_$i.bin"
    errfile="$TMP_DIR/err_$i.txt"
    
    timeout 2 cat "$ETF_DEV_NODE" > "$outfile" 2> "$errfile"

    if grep -qE "Operation not permitted|Invalid argument|No such file" "$errfile"; then
        log_fail "Kernel error detected during capture in iteration $i"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        break
    fi

    if [ -f "$outfile" ]; then
        size=$(stat -c%s "$outfile")
        if [ "$size" -lt 64 ]; then
            log_fail "Trace data too small ($size bytes) in iteration $i"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            break
        fi
    else
        log_fail "Failed to capture trace file in iteration $i"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        break
    fi

    pass_count=$((pass_count + 1))
done

if [ "$FAIL_COUNT" -eq 0 ] && [ "$pass_count" -eq "$RUNS" ]; then
    log_pass "Successfully completed $RUNS iterations of ETM + Hotplug Stress"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "Stress test failed: $pass_count/$RUNS iterations passed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"