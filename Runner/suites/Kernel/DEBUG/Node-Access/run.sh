#!/bin/sh

# Copyright (c) 2024 Qualcomm Technologies, Inc.
# All Rights Reserved. Qualcomm Technologies Proprietary and Confidential.

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
rm -f "$res_file"
touch "$res_file"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

CS_BASE="/sys/bus/coresight/devices"
FAIL_COUNT=0
ITERATIONS=3


reset_source_sink() {
    if [ -f "$CS_BASE/stm0/enable_source" ]; then
        echo 0 > "$CS_BASE/stm0/enable_source" 2>/dev/null
    fi
    if [ -f "$CS_BASE/tmc_etf0/enable_sink" ]; then
        echo 0 > "$CS_BASE/tmc_etf0/enable_sink" 2>/dev/null
    fi
    if [ -f "$CS_BASE/tmc_etr0/enable_sink" ]; then
        echo 0 > "$CS_BASE/tmc_etr0/enable_sink" 2>/dev/null
    fi
}

read_sysfs_node() {
    node=$1
    if [ -f "$node" ] && [ -r "$node" ]; then
        if ! cat "$node" > /dev/null 2>&1; then
            log_warn "Failed to read: $node"
            return 1
        fi
    fi
    return 0
}


if [ ! -d "$CS_BASE" ]; then
    log_fail "Coresight directory $CS_BASE not found"
    echo "$TESTNAME: FAIL" >> "$res_file"
    exit 1
fi

i=0
while [ $i -lt $ITERATIONS ]; do
    log_info "--- Iteration $((i+1)) / $ITERATIONS ---"

    for node_path in "$CS_BASE"/*; do
        if [ ! -d "$node_path" ]; then
            continue
        fi

        if echo "$node_path" | grep -q "tpdm"; then
            continue
        fi

        reset_source_sink

        for node in "$node_path"/*; do
            if ! read_sysfs_node "$node"; then
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        done

        if [ -d "$node_path/mgmt" ]; then
            for snode in "$node_path"/mgmt/*; do
                if ! read_sysfs_node "$snode"; then
                    log_fail "Failed to read mgmt node: $snode"
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                fi
            done
        fi
    done
    i=$((i+1))
done


if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "All sysfs nodes (except tpdm) Read Test PASS"
    echo "$TESTNAME: PASS" >> "$res_file"
else
    log_fail "Sysfs nodes Read Test FAIL ($FAIL_COUNT errors)"
    echo "$TESTNAME: FAIL" >> "$res_file"
fi

# log_info "-------------------$TESTNAME Testcase Finished----------------------------"