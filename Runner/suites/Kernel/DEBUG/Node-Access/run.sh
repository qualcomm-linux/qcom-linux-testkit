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

TESTNAME="Node-Access"
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
FAIL_COUNT=0
ITERATIONS=3

reset_source_sink() {
    log_info "Dynamically finding and resetting all Coresight sources and sinks..."
    for _dev in "$CS_BASE"/*; do
        [ -e "$_dev" ] || continue
        
        # Disable if it's a source
        if [ -f "$_dev/enable_source" ]; then
            echo 0 > "$_dev/enable_source" 2>/dev/null || true
        fi
        
        # Disable if it's a sink
        if [ -f "$_dev/enable_sink" ]; then
            echo 0 > "$_dev/enable_sink" 2>/dev/null || true
        fi
    done
}

if [ ! -d "$CS_BASE" ]; then
    log_fail "Coresight directory $CS_BASE not found"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

set -- "$CS_BASE"/*
if [ ! -e "$1" ]; then
    log_fail "No Coresight devices found inside $CS_BASE"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

reset_source_sink

i=0
while [ "$i" -lt "$ITERATIONS" ]; do
    log_info "--- Iteration $((i+1)) / $ITERATIONS ---"

    for node_path in "$CS_BASE"/*; do
        [ -d "$node_path" ] || continue

        case "$(basename "$node_path")" in
            *tpdm*)
                continue
                ;;
        esac

        for node in "$node_path"/*; do
            if [ -f "$node" ] && [ -r "$node" ]; then
                cat "$node" > /dev/null 2>&1 || true
            fi
        done

        if [ -d "$node_path/mgmt" ]; then
            for snode in "$node_path"/mgmt/*; do
                if [ -f "$snode" ] && [ -r "$snode" ]; then
                    if ! cat "$snode" > /dev/null 2>&1; then
                        log_fail "Failed to read mgmt node: $snode"
                        FAIL_COUNT=$((FAIL_COUNT + 1))
                    fi
                fi
            done
        fi
    done
    i=$((i+1))
done

if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "All sysfs nodes Read Test PASS"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "Sysfs nodes Read Test FAIL ($FAIL_COUNT errors)"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"