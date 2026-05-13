#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPTdIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPTdIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPTdIR)" >&2
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
if command -v find_test_case_byname >/dev/null 2>&1; then
    test_path=$(find_test_case_byname "$TESTNAME")
    cd "$test_path" || exit 1
else
    cd "$SCRIPTdIR" || exit 1
fi

res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Checking if required tools are available"

checkdependencies timeout stat || {
    log_skip "Required tools missing. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
}

CPU_PATH="/sys/devices/system/cpu/cpu"
CORES=$(grep -c "processor" /proc/cpuinfo)
STM_PATH="$cs_base/stm0"
[ ! -d "$STM_PATH" ] && STM_PATH="$cs_base/coresight-stm"

toggle_etm_all() {
    state=$1
    count=0
    toggledcount=0
    
    while [ "$count" -lt "$CORES" ]; do
        skip=0
        
        if [ -f "${CPU_PATH}${count}/online" ]; then
            read -r is_online < "${CPU_PATH}${count}/online"
            if [ "$is_online" = "0" ]; then
                log_info "CPU $count is offline, skipping ETM toggle for this core."
                skip=1
            fi
        fi

        if [ "$skip" -eq 0 ]; then
            etm=""
            
            if [ -f "$cs_base/ete$count/enable_source" ]; then
                etm="$cs_base/ete$count/enable_source"
            elif [ -f "$cs_base/coresight-ete$count/enable_source" ]; then
                etm="$cs_base/coresight-ete$count/enable_source"
            elif [ -f "$cs_base/etm$count/enable_source" ]; then
                etm="$cs_base/etm$count/enable_source"
            elif [ -f "$cs_base/coresight-etm$count/enable_source" ]; then
                etm="$cs_base/coresight-etm$count/enable_source"
            fi

            if [ -n "$etm" ]; then
                if echo "$state" > "$etm" 2>/dev/null; then
                    toggledcount=$((toggledcount + 1))
                else
                    log_warn "Failed to write $state to $etm"
                fi
            else
                log_warn "No ETM/ETE source found for CPU $count in $cs_base"
            fi
        fi

        count=$((count + 1))
    done

    if [ "$toggledcount" -eq 0 ]; then
        log_warn "No ETM/ETE devices were successfully toggled. Please verify Coresight configurations and path names."
    fi
}

cs_check_base || { echo "$TESTNAME FAIL" > "$res_file"; exit 1; }

cs_global_reset
toggle_etm_all 0

# shellcheck disable=SC2010
SINKS=""
for d in "$cs_base"/tmc_et* "$cs_base"/coresight-tmc-et*; do
    [ -d "$d" ] || continue
    name="${d##*/}"
    [ "$name" = "tmc_etf1" ] && continue
    [ -f "$d/enable_sink" ] || continue
    SINKS="$SINKS $name"
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