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
     __INIT_ENV_LOADED=1

fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/coresight_helper.sh" 

TESTNAME="TPDM-Enable-Disable"
res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
cs_base="/sys/bus/coresight/devices"
fail=0

# Change a sink state and verify the kernel accepted the requested state.
# A successful write alone is not sufficient because sysfs writes may be rejected.
set_sink_state()
{
    sink_path=$1
    sink_name=$2
    requested_state=$3
    state_file="$sink_path/enable_sink"

    if [ ! -f "$state_file" ]; then
        log_fail "$sink_name sink has no enable_sink control: $sink_path"
        return 1
    fi

    if ! echo "$requested_state" > "$state_file" 2>/dev/null; then
        log_fail "Failed to set $sink_name sink enable_sink to $requested_state"
        return 1
    fi

    actual_state=$(cat "$state_file" 2>/dev/null)
    if [ "$actual_state" != "$requested_state" ]; then
        log_fail "$sink_name sink enable_sink is $actual_state; expected $requested_state"
        return 1
    fi
    return 0
}

# reset_devices does not provide a reliable aggregate status. Verify the sink
# state after reset instead, and retry the clear once before declaring failure.
cleanup_sink()
{
    sink_path=$1
    sink_name=$2
    cleanup_ok=0

    if set_sink_state "$sink_path" "$sink_name" 0; then
        cleanup_ok=1
    fi

    reset_devices

    if [ -f "$sink_path/enable_sink" ] && [ "$(cat "$sink_path/enable_sink" 2>/dev/null)" = "0" ]; then
        cleanup_ok=1
    else
        cleanup_ok=0
        log_fail "$sink_name sink was not cleared after reset"
        # Give the sink one final explicit cleanup attempt. The readback is
        # still authoritative; reset_devices' return status is not used.
        if set_sink_state "$sink_path" "$sink_name" 0; then
            cleanup_ok=1
        fi
    fi

    if [ "$cleanup_ok" -ne 1 ]; then
        log_fail "$sink_name sink cleanup failed; sink may remain selected"
        return 1
    fi
    return 0
}

# Prepare one sink phase independently and verify the sink is clear before enabling it.
prepare_sink()
{
    sink_path=$1
    sink_name=$2
    reset_devices
    if ! set_sink_state "$sink_path" "$sink_name" 0; then
        log_fail "$sink_name sink could not be cleared before phase start"
        return 1
    fi
    if ! set_sink_state "$sink_path" "$sink_name" 1; then
        log_fail "Cannot enable $sink_name sink for phase"
        return 1
    fi
    return 0
}
run_sink_phase()
{
    sink_path=$1
    sink_name=$2
    log_info "Running with $sink_name sink"
    if ! prepare_sink "$sink_path" "$sink_name"; then
        fail=1
        cleanup_sink "$sink_path" "$sink_name" || fail=1
        return
    fi

    i=0
    while [ "$i" -le 50 ]; do
        iter_fail=0
        for node_path in "$cs_base"/tpdm* "$cs_base"/coresight-tpdm*; do
            [ ! -d "$node_path" ] && continue
            node_name=$(basename "$node_path")
            if echo "$node_name" | grep -q "tpdm-turing-llm"; then
                continue
            fi
            if [ ! -f "$node_path/enable_source" ]; then
                continue
            fi

            if ! echo 1 > "$node_path/enable_source" 2>/dev/null ||                [ "$(cat "$node_path/enable_source" 2>/dev/null)" != "1" ]; then
                iter_fail=1
                log_fail "Iter $i: Failed to enable $node_name with $sink_name sink"
            fi

            if ! echo 0 > "$node_path/enable_source" 2>/dev/null ||                [ "$(cat "$node_path/enable_source" 2>/dev/null)" = "1" ]; then
                iter_fail=1
                log_fail "Iter $i: Failed to disable $node_name with $sink_name sink"
            fi
        done

        if [ "$iter_fail" -eq 0 ]; then
            log_info "Iteration: $i - PASS"
        else
            log_fail "Iteration: $i - FAIL"
            fail=1
        fi
        i=$((i + 1))
    done

    # Cleanup is part of the result. In particular, do not report PASS when
    # ETR (or ETF) remains enabled for subsequent source operations.
    if ! cleanup_sink "$sink_path" "$sink_name"; then
        fail=1
    fi
}

# Discover ETF and ETR independently. ETR is optional: its absence skips only
# the ETR subcase and must not remove ETF coverage (and vice versa).
etf_path=$(find_path "tmc_etf0" "tmc_etf" "tmc_etf1" "coresight-tmc_etf" "coresight-tmc_etf0")
etr_path=$(find_path "tmc_etr0" "tmc_etr" "tmc_etr1" "coresight-tmc_etr" "coresight-tmc_etr0")

etf_available=0
etr_available=0
[ -n "$etf_path" ] && [ -f "$etf_path/enable_sink" ] && etf_available=1
[ -n "$etr_path" ] && [ -f "$etr_path/enable_sink" ] && etr_available=1

if [ "$etf_available" -eq 0 ]; then
    log_info "SKIP: TMC-ETF sink is unavailable"
fi
if [ "$etr_available" -eq 0 ]; then
    log_info "SKIP: TMC-ETR sink is unavailable"
fi
if [ "$etf_available" -eq 0 ] && [ "$etr_available" -eq 0 ]; then
    log_fail "No usable TMC-ETF or TMC-ETR sink found. Cannot proceed."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

tpdm_count=0
for node_path in "$cs_base"/tpdm* "$cs_base"/coresight-tpdm*; do
    [ -d "$node_path" ] && tpdm_count=$((tpdm_count + 1))
done
if [ "$tpdm_count" -eq 0 ]; then
    log_fail "No TPDM devices found on the system."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

[ "$etf_available" -eq 1 ] && run_sink_phase "$etf_path" "ETF"
[ "$etr_available" -eq 1 ] && run_sink_phase "$etr_path" "ETR"

if [ "$fail" -eq 0 ]; then
    log_pass "-------------enable/disable TPDMs Test PASS-------------"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "-------------enable/disable TPDMs Test FAIL-------------"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------" 