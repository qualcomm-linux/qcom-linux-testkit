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

TESTNAME="MultiSource-STM-ETM"
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

for tool in timeout stat; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_skip "Required tool '$tool' not found. Skipping test."
        echo "$TESTNAME SKIP" > "$res_file" 
        exit 0
    fi
done

CPU_PATH="/sys/devices/system/cpu/cpu"
CORES=$(grep -c "processor" /proc/cpuinfo)
STM_PATH="$CS_BASE/stm0"
[ ! -d "$STM_PATH" ] && STM_PATH="$CS_BASE/coresight-stm"

# --- Helpers ---

toggle_etm_all() {
    _state=$1
    _count=0
    _toggled_count=0
    
    while [ "$_count" -lt "$CORES" ]; do
        _skip=0
        
        if [ -f "${CPU_PATH}${_count}/online" ]; then
            read -r _is_online < "${CPU_PATH}${_count}/online"
            if [ "$_is_online" = "0" ]; then
                log_info "CPU $_count is offline, skipping ETM toggle for this core."
                _skip=1
            fi
        fi

        if [ "$_skip" -eq 0 ]; then
            _etm=""
            
            if [ -f "$CS_BASE/ete$_count/enable_source" ]; then
                _etm="$CS_BASE/ete$_count/enable_source"
            elif [ -f "$CS_BASE/coresight-ete$_count/enable_source" ]; then
                _etm="$CS_BASE/coresight-ete$_count/enable_source"
            elif [ -f "$CS_BASE/etm$_count/enable_source" ]; then
                _etm="$CS_BASE/etm$_count/enable_source"
            elif [ -f "$CS_BASE/coresight-etm$_count/enable_source" ]; then
                _etm="$CS_BASE/coresight-etm$_count/enable_source"
            fi

            if [ -n "$_etm" ]; then
                if echo "$_state" > "$_etm" 2>/dev/null; then
                    _toggled_count=$((_toggled_count + 1))
                else
                    log_warn "Failed to write $_state to $_etm"
                fi
            else
                log_warn "No ETM/ETE source found for CPU $_count in $CS_BASE"
            fi
        fi

        _count=$((_count + 1))
    done

    if [ "$_toggled_count" -eq 0 ]; then
        log_warn "No ETM/ETE devices were successfully toggled. Please verify Coresight configurations and path names."
    fi
}

# --- Preflight ---

cs_check_base || { echo "$TESTNAME FAIL" > "$res_file"; exit 1; }

cs_global_reset
toggle_etm_all 0

# shellcheck disable=SC2010
SINKS=""
for _d in "$CS_BASE"/tmc_et* "$CS_BASE"/coresight-tmc-et*; do
    [ -d "$_d" ] || continue
    _name="${_d##*/}"
    [ "$_name" = "tmc_etf1" ] && continue
    [ -f "$_d/enable_sink" ] || continue
    SINKS="$SINKS $_name"
done
SINKS="${SINKS# }"

if [ -z "$SINKS" ]; then
    log_fail "No suitable TMC sinks found"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

for sinkname in $SINKS; do
    log_info "Testing Sink: $sinkname"
    
    cs_global_reset
    OUTPUT_BIN="/tmp/$sinkname.bin"
    rm -f "$OUTPUT_BIN"

    if ! cs_enable_sink "$sinkname"; then
        log_warn "Sink $sinkname enable_sink node not found"
        echo "$TESTNAME FAIL" > "$res_file"
        continue
    fi

    toggle_etm_all 1

    if [ -f "$STM_PATH/enable_source" ]; then
        echo 1 > "$STM_PATH/enable_source"
    else
        log_warn "STM source not found"
    fi

    [ -c "/dev/$sinkname" ] && timeout 2s cat "/dev/$sinkname" > "$OUTPUT_BIN"

    if [ -f "$OUTPUT_BIN" ]; then
        bin_size=$(stat -c%s "$OUTPUT_BIN")
        if [ "$bin_size" -ge 64 ]; then
            log_pass "Captured $bin_size bytes from $sinkname"
            echo "$TESTNAME PASS" > "$res_file"
        else
            log_fail "Captured data too small ($bin_size bytes) from $sinkname"
            echo "$TESTNAME FAIL" > "$res_file"
        fi
    else
        log_fail "No output file generated for $sinkname"
        echo "$TESTNAME FAIL" > "$res_file"
    fi

    toggle_etm_all 0
done

cs_global_reset