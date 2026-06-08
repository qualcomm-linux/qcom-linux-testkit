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

TESTNAME="Sink-Status-STM-Toggle"
if command -v find_test_case_by_name >/dev/null 2>&1; then
    test_path=$(find_test_case_by_name "$TESTNAME")
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

cs_base="/sys/bus/coresight/devices"
fail=0


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
etm_path=$(find_first_existing_path "etm0" "etm" "coresight-etm0" "coresight-etm4x" "coresight-ete0")

reset_devices() {
    if [ -n "$stm_path" ] && [ -f "$stm_path/enable_source" ]; then
        echo 0 > "$stm_path/enable_source" 2>/dev/null
    fi
    if [ -n "$etm_path" ] && [ -f "$etm_path/enable_source" ]; then
        echo 0 > "$etm_path/enable_source" 2>/dev/null
    fi

    for s in "$cs_base"/tmc_et*; do
        [ -d "$s" ] || continue
        if [ -f "$s/curr_sink" ]; then
            echo 0 > "$s/curr_sink" 2>/dev/null
        fi
        if [ -f "$s/enable_sink" ]; then
            echo 0 > "$s/enable_sink" 2>/dev/null
        fi
    done
}

check_sink_status() {
    local_sink=$1
    expected=$2
    stage=$3

    if [ -f "$local_sink/curr_sink" ]; then
        val=$(cat "$local_sink/curr_sink")
    else
        val=$(cat "$local_sink/enable_sink")
    fi

    if [ "$val" != "$expected" ]; then
        log_fail "$stage: $local_sink status is $val (Expected: $expected)"
        return 1
    else
        log_pass "$stage: $local_sink status is $val"
        return 0
    fi
}

if [ -z "$stm_path" ]; then
    log_fail "STM device not found in $cs_base"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

sink_list=""
for _sink in "$cs_base"/tmc_et*; do
    [ -d "$_sink" ] || continue
    case "$_sink" in
        *tmc_etf1) continue ;;
    esac
    sink_list="${sink_list:+$sink_list }$_sink"
done

if [ -z "$sink_list" ]; then
    log_fail "No suitable sinks found"
    echo "$TESTNAME Fail" > "$res_file"
    exit 1
fi

if [ -f "$cs_base/tmc_etr0/out_mode" ]; then
    echo mem > "$cs_base/tmc_etr0/out_mode"
fi

log_info "=== Phase 1: STM Only Test ==="

for sink in $sink_list; do
    log_info "Testing Sink: $(basename "$sink")"

    reset_devices
    echo 1 > "$sink/enable_sink"
    echo 1 > "$stm_path/enable_source"
    sleep 1

    if ! check_sink_status "$sink" 1 "Phase1_STM_Enable"; then
        fail=$((fail + 1))
    fi

    echo 0 > "$stm_path/enable_source"
    sleep 1

    echo 0 > "$sink/enable_sink"
    if ! check_sink_status "$sink" 0 "Phase1_STM_Disable"; then
        fail=$((fail + 1))
    fi
done

log_info "=== Phase 2: STM + ETM Test ==="

has_etm=0
if [ -n "$etm_path" ] && [ -f "$etm_path/enable_source" ]; then
    has_etm=1
fi
if [ -d "$etm_path" ]; then
    if [ -f /proc/config.gz ]; then
        if zcat /proc/config.gz | grep -q "CONFIG_CORESIGHT_SOURCE_ETM4X=y"; then
            has_etm=1
        fi
    else
        has_etm=1
    fi
fi

if [ "$has_etm" -eq 1 ]; then
    for sink in $sink_list; do
        log_info "Testing Sink (Multi-Source): $(basename "$sink")"

        reset_devices
        echo 1 > "$sink/enable_sink"

        echo 1 > "$stm_path/enable_source"
        echo 1 > "$etm_path/enable_source"
        sleep 1

        if ! check_sink_status "$sink" 1 "Phase2_Both_Enable"; then
            fail=$((fail + 1))
        fi

        echo 0 > "$stm_path/enable_source"

        if ! check_sink_status "$sink" 1 "Phase2_STM_Disable_ETM_Active"; then
            fail=$((fail + 1))
        fi

        reset_devices
    done
else
    log_info "Skipping Phase 2 (ETM not found or not enabled)"
fi

reset_devices

if [ "$fail" -eq 0 ]; then
    log_pass "Sink status check passed across all phases"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "Sink status check failed ($fail errors)"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"