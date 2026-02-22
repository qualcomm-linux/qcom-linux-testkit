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

TESTNAME="STM-HWE-PORT-SWITCH"
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
ETR_PATH="$CS_BASE/tmc_etr0"
DEBUGFS="/sys/kernel/debug/tracing"

reset_source_sink() {
    if [ -f "$STM_PATH/enable_source" ]; then
        echo 0 > "$STM_PATH/enable_source"
    fi
    if [ -f "$ETF_PATH/enable_sink" ]; then
        echo 0 > "$ETF_PATH/enable_sink"
    fi
    if [ -f "$ETR_PATH/enable_sink" ]; then
        echo 0 > "$ETR_PATH/enable_sink"
    fi
    if [ -f "$DEBUGFS/tracing_on" ]; then
        echo 0 > "$DEBUGFS/tracing_on"
    fi
}

test_attribute() {
    attr_name=$1
    attr_path="$STM_PATH/$attr_name"
    
    log_info "Testing Attribute: $attr_name"

    if [ ! -f "$attr_path" ]; then
        log_warn "Attribute $attr_name not found at $STM_PATH"
        return 0
    fi

    for stm_state in 0 1; do
        echo "$stm_state" > "$STM_PATH/enable_source"
        
        for val in 0 1; do
            echo "$val" > "$attr_path"
            readback=$(cat "$attr_path")
            
            
            if [ "$attr_name" = "hwevent_enable" ]; then
                if [ "$readback" -eq "$val" ]; then
                    log_pass "STM_Src:$stm_state | $attr_name set to $val"
                else
                    log_fail "STM_Src:$stm_state | Failed to set $attr_name to $val (Read: $readback)"
                    echo "$TESTNAME: FAIL" >> "$res_file"
                    return 1
                fi
            elif [ "$attr_name" = "port_enable" ]; then
                 if [ "$val" -eq 1 ] && [ "$readback" != "0" ] && [ "$readback" != "0x0" ]; then
                     log_pass "STM_Src:$stm_state | $attr_name set to $val"
                 elif [ "$val" -eq 0 ] && [ "$readback" = "0" ]; then 
                     log_pass "STM_Src:$stm_state | $attr_name set to $val"
                 elif [ "$val" -eq 0 ] && [ "$readback" = "0x0" ]; then
                     log_pass "STM_Src:$stm_state | $attr_name set to $val"
                 else
                     log_fail "STM_Src:$stm_state | Failed to set $attr_name to $val (Read: $readback)"
                     echo "$TESTNAME: FAIL" >> "$res_file"
                     return 1
                 fi
            fi
        done
    done
    
    echo "$TESTNAME: PASS" >> "$res_file"
    return 0
}


if [ ! -d "$STM_PATH" ]; then
    log_fail "STM device not found"
    echo "$TESTNAME: FAIL" >> "$res_file"
    exit 1
fi

log_info "Creating Policy Directories..."
mkdir -p /sys/kernel/config/stp-policy/stm0:p_ost.policy/default

reset_source_sink

if [ -f "$ETF_PATH/enable_sink" ]; then
    echo 1 > "$ETF_PATH/enable_sink"
fi

test_attribute "hwevent_enable"
test_attribute "port_enable"

reset_source_sink

if [ -f "$STM_PATH/hwevent_enable" ]; then
    echo 0 > "$STM_PATH/hwevent_enable"
fi
if [ -f "$STM_PATH/port_enable" ]; then
    echo 0xffffffff > "$STM_PATH/port_enable"
fi

# log_info "-------------------$TESTNAME Testcase Finished----------------------------"