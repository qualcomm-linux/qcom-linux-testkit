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

TESTNAME="MultiSource-STM-ETM"
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
log_info "=== Test Initialization ==="
log_info "Checking if required tools are available"

CS_BASE="/sys/bus/coresight/devices"
CPU_PATH="/sys/devices/system/cpu/cpu"
CORES=$(grep -c "processor" /proc/cpuinfo)
STM_PATH="$CS_BASE/stm0"
[ ! -d "$STM_PATH" ] && STM_PATH="$CS_BASE/coresight-stm"

reset_source_sink() {
    # shellcheck disable=SC2045
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

toggle_etm_all() {
    state=$1
    count=0
    while [ "$count" -lt "$CORES" ]; do
        [ -f "$CPU_PATH$count/online" ] && echo 1 > "$CPU_PATH$count/online"
        
        if [ -d "$CS_BASE/ete$count" ]; then
            etm_path="$CS_BASE/ete$count/enable_source"
        elif [ -d "$CS_BASE/coresight-ete$count" ]; then
            etm_path="$CS_BASE/coresight-ete$count/enable_source"
        elif [ -d "$CS_BASE/etm$count" ]; then
            etm_path="$CS_BASE/etm$count/enable_source"
        elif [ -d "$CS_BASE/coresight-etm$count" ]; then
            etm_path="$CS_BASE/coresight-etm$count/enable_source"
        else
            count=$((count + 1))
            continue
        fi

        [ -f "$etm_path" ] && echo "$state" > "$etm_path"
        count=$((count + 1))
    done
}

reset_source_sink
toggle_etm_all 0

# shellcheck disable=SC2010
SINKS=$(ls "$CS_BASE" | grep "tmc_et" | grep -v "tmc_etf1")

if [ -z "$SINKS" ]; then
    log_fail "No suitable TMC sinks found"
    echo "$TESTNAME: FAIL" >> "$res_file"
    exit 1
fi

for sinkname in $SINKS; do
    log_info "Testing Sink: $sinkname"
    
    reset_source_sink
    OUTPUT_BIN="/tmp/$sinkname.bin"
    rm -f "$OUTPUT_BIN"

    if [ -f "$CS_BASE/$sinkname/enable_sink" ]; then
        echo 1 > "$CS_BASE/$sinkname/enable_sink"
    else
        log_warn "Sink $sinkname enable file not found"
        echo "$TESTNAME: FAIL" >> "$res_file"
        continue
    fi

    toggle_etm_all 1
    
    if [ -f "$STM_PATH/enable_source" ]; then
        echo 1 > "$STM_PATH/enable_source"
    else
        log_warn "STM source not found"
    fi
    
    if [ -c "/dev/$sinkname" ]; then
        timeout 2s cat "/dev/$sinkname" > "$OUTPUT_BIN"
    fi

    if [ -f "$OUTPUT_BIN" ]; then
        bin_size=$(stat -c%s "$OUTPUT_BIN")
        if [ "$bin_size" -ge 64 ]; then
            log_pass "Captured $bin_size bytes from $sinkname"
            echo "$TESTNAME: PASS" >> "$res_file"
        else
            log_fail "Captured data too small ($bin_size bytes) from $sinkname"
            echo "$TESTNAME: FAIL" >> "$res_file"
        fi
    else
        log_fail "No output file generated for $sinkname"
        echo "$TESTNAME: FAIL" >> "$res_file"
    fi

    toggle_etm_all 0
done

reset_source_sink
# log_info "-------------------$TESTNAME Testcase Finished----------------------------"