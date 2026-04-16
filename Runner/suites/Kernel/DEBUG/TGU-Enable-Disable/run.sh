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

TESTNAME="TGU-Enable-Disable"
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
fail_count=0

reset_coresight() {
    for _dev in "$cs_base"/*; do
        [ -d "$_dev" ] || continue
        
        if [ -f "$_dev/enable_sink" ]; then
            echo 0 > "$_dev/enable_sink" 2>/dev/null || true
        fi
        
        if [ -f "$_dev/enable_tgu" ]; then
            echo 0 > "$_dev/enable_tgu" 2>/dev/null || true
        fi
    done
}

cleanup() {
    log_info "Cleaning up..."
    reset_coresight
}

trap cleanup EXIT HUP INT TERM

if [ ! -d "$cs_base" ]; then
    log_fail "Coresight directory not found"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

set -- "$cs_base"/*
if [ ! -e "$1" ]; then
    log_fail "No Coresight devices found inside $cs_base"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

reset_coresight

tgu_list=""
for _d in "$cs_base"/tgu*; do
    [ -d "$_d" ] || continue
    tgu_list="$tgu_list $(basename "$_d")"
done
tgu_list="${tgu_list# }"

if [ -z "$tgu_list" ]; then
    log_warn "No TGU (Trace Generation Unit) devices found. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Found TGUs: $tgu_list"

sink_count=0
for _d in "$cs_base"/*; do
    [ -d "$_d" ] || continue
    
    if [ -f "$_d/enable_sink" ]; then
        if echo 1 > "$_d/enable_sink" 2>/dev/null; then
            sink_count=1
            log_info "Dynamically found and enabled sink: $(basename "$_d")"
            break
        fi
    fi
done

if [ "$sink_count" -eq 0 ]; then
    log_warn "No sink enabled — proceeding with TGU test anyway"
fi

for tgu in $tgu_list; do
    tgu_path="$cs_base/$tgu"

    if [ ! -f "$tgu_path/enable_tgu" ]; then
        log_warn "No enable_tgu node for $tgu — skipping"
        continue
    fi

    if ! echo 1 > "$tgu_path/enable_tgu" 2>/dev/null; then
        log_fail "Failed to enable TGU: $tgu"
        fail_count=$((fail_count + 1))
    else
        log_info "Enabled $tgu OK"
    fi

    if ! echo 0 > "$tgu_path/enable_tgu" 2>/dev/null; then
        log_fail "Failed to disable TGU: $tgu"
        fail_count=$((fail_count + 1))
    else
        log_info "Disabled $tgu OK"
    fi
done

if [ "$fail_count" -eq 0 ]; then
    log_pass "TGU Enable/Disable Test PASS"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "TGU Enable/Disable Test FAIL ($fail_count errors)"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"

