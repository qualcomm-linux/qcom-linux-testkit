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

TESTNAME="Reset-All-Sinks-Base"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
log_info "---------------------------$TESTNAME Starting---------------------------"

cs_base="/sys/bus/coresight/devices"
debugfs="/sys/kernel/debug"
[ ! -d "$debugfs/tracing" ] && debugfs="/debug"

if [ ! -d "$cs_base" ]; then
    log_warn "Coresight directory not found. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

trap cleanup EXIT HUP INT TERM

reset_coresight

runs=${1:-1000}

sinks=""
sink_count=0
for node in "$cs_base"/*; do
    [ ! -d "$node" ] && continue
    [ "$(basename "$node")" = "tmc_etf1" ] && continue

    if [ -f "$node/enable_sink" ]; then
        sinks="$sinks $node"
        sink_count=$((sink_count + 1))
    fi
done
sinks="${sinks# }"

if [ "$sink_count" -lt 2 ]; then
    log_warn "Need at least 2 Coresight sinks for multiple sink reset test. Found $sink_count. Skipping."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

stm=""
for node in "$cs_base"/stm*; do
    if [ -d "$node" ] && [ -f "$node/enable_source" ]; then
        stm="$node"
        break
    fi
done

etm=""
for node in "$cs_base"/etm*; do
    if [ -d "$node" ] && [ -f "$node/enable_source" ]; then
        etm="$node"
        break
    fi
done

if [ -z "$stm" ] && [ -z "$etm" ]; then
    log_warn "No STM or ETM sources found. Cannot generate trace data. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Discovered Sinks ($sink_count): $(for s in $sinks; do basename "$s"; done | tr '\n' ' ')"
[ -n "$stm" ] && log_info "Discovered STM: $(basename "$stm")"
[ -n "$etm" ] && log_info "Discovered ETM: $(basename "$etm")"

# shellcheck disable=SC2086
set -- $sinks

fail=0
case "$1" in
    ''|*[!0-9]*) ;;
    *) runs=$1 ;;
esac
log_info "starting reset sinks stress test for $runs iterations..."

i=0
while [ "$i" -lt "$runs" ] && [ "$fail" -eq 0 ]; do
    log_info "stress test running loop: $i"
    
    while [ "$#" -gt 1 ] && [ "$fail" -eq 0 ]; do
        sink1="$1"
        shift

        for sink2 in "$@"; do
            if [ "$fail" -ne 0 ]; then
                break
            fi

            if [ -f "$sink1/enable_sink" ]; then
                echo 1 > "$sink1/enable_sink" 2>/dev/null
            fi

            if [ -f "$sink2/enable_sink" ]; then
                echo 1 > "$sink2/enable_sink" 2>/dev/null
            fi

            reset_coresight
            
# shellcheck disable=SC2086
            if ! check_sink_status $sinks; then
                log_fail "FAIL: reset multiple sinks at loop $i (failed on sinks: $(basename "$sink1"), $(basename "$sink2"))"
                fail=1
                break
            fi
        done
    done

    i=$((i + 1))
done

if [ "$fail" -eq 0 ]; then
    log_info "Starting post-stress trace capture verification..."
    
    verify_sink=""
    verify_dev=""
    for s in $sinks; do
        s_name=$(basename "$s")
        if [ -c "/dev/$s_name" ]; then
            verify_sink="$s"
            verify_dev="/dev/$s_name"
            break
        fi
    done

    if [ -z "$verify_sink" ]; then
        log_warn "No valid /dev node found for any sink. Cannot verify read, but reset test passed."
    else      
        reset_coresight

        [ -f "$verify_sink/enable_sink" ] && echo 1 > "$verify_sink/enable_sink" 2>/dev/null
        [ -f "$debugfs/tracing/events/enable" ] && echo 0 > "$debugfs/tracing/events/enable" 2>/dev/null

        if [ -n "$stm" ]; then
            echo 1 > "$stm/enable_source" 2>/dev/null
            log_info "enabled STM source"
        fi

        if [ -n "$etm" ]; then
            echo 1 > "$etm/enable_source" 2>/dev/null
            log_info "enabled ETM source"
        fi

        sleep 1

        rm -f "/tmp/verify_sink.bin"
        if [ -c "$verify_dev" ]; then
            cat "$verify_dev" > "/tmp/verify_sink.bin" 2>/dev/null
        fi

        if [ -f "/tmp/verify_sink.bin" ]; then
            size=$(wc -c < "/tmp/verify_sink.bin" 2>/dev/null || echo 0)
            size=$(echo "$size" | tr -d ' ')
            if [ "$size" -lt 64 ]; then
                fail=1
            fi
        else
            log_fail "verification read FAIL: /tmp/verify_sink.bin missing"
            fail=1
        fi
    fi
fi

if [ "$fail" -eq 0 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"