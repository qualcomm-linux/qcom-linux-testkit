#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# Test for RMNET driver: skip if CONFIG_RMNET not enabled, then
# builtin vs module, verify /dev/rmnet, functional sysfs & dmesg checks.

# Robustly find and source init_env
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

TESTNAME="RMNET"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
RES_FILE="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="


# Kernel config gate
if ! check_kernel_config "CONFIG_RMNET"; then
    log_skip "$TESTNAME SKIP - CONFIG_RMNET not enabled"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# Load module if needed
MODNAME="rmnet"
PRE_LOADED=0
FAILURE=0
if is_module_loaded "$MODNAME"; then
    PRE_LOADED=1
    log_info "Module $MODNAME already loaded"
else
    MODPATH=$(find_kernel_module "$MODNAME")
    [ -n "$MODPATH" ] || (log_fail "$MODNAME.ko not found in filesystem"; FAILURE=1)
    load_kernel_module "$MODPATH" || (log_fail "Failed to load $MODNAME"; FAILURE=1)
    log_pass "$MODNAME module loaded"
fi

# /dev/rmnet* nodes (authoritative), but do NOT FAIL if absent (common until modem data call)
log_info "Verifying /dev/rmnet* node(s)"
first_node=""
for n in /dev/rmnet*; do
    case "$n" in
        /dev/rmnet*) [ -e "$n" ] && { first_node="$n"; break; } ;;
    esac
done

if [ -n "$first_node" ]; then
    if wait_for_path "$first_node" 3; then
        log_pass "rmnet node $first_node is present"
    else
        log_fail "rmnet node $first_node did not appear within timeout"
        FAILURE=1
    fi
else
    log_warn "No /dev/rmnet* nodes found"
fi

# dmesg scan for rmnet errors (no positive 'OK' pattern required here)
scan_dmesg_errors "rmnet" "." "panic|oops|fault|stall|abort" ""
if [ -s "./rmnet_dmesg_errors.log" ]; then
    log_fail "rmnet-related errors found in dmesg"
    FAILURE=1
else
    log_info "No rmnet-related errors in dmesg"
fi

# Optional informational check: ip link (do not fail if absent)
if command -v ip >/dev/null 2>&1; then
    if ip -o link show | grep -qi rmnet; then
        log_info "ip(8): rmnet interface(s) present"
    else
        log_info "ip(8): no rmnet interface yet (probably no data call)"
    fi
fi

# Cleanup if we loaded it
if [ "$PRE_LOADED" -eq 0 ]; then
    log_info "Unloading $MODNAME (loaded by this test)"
    unload_kernel_module "$MODNAME" false || log_warn "Unload $MODNAME failed"
else
    log_info "$MODNAME was pre-loaded; leaving it loaded"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
if [ "$FAILURE" = 0 ]; then
    log_pass "$TESTNAME PASS"
    log_info "Writing to file $RES_FILE"
    echo "$TESTNAME PASS" >"$RES_FILE"
else
    log_fail "$TESTNAME FAIL"
    log_info "Writing to file $RES_FILE"
    echo "$TESTNAME FAIL" >"$RES_FILE"
fi
exit 0

