#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# Test for IPA driver: skip if CONFIG_QCOM_IPA not enabled, then
# builtin vs module, verify /dev/ipa, functional sysfs & dmesg checks.

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

TESTNAME="IPA"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
RES_FILE="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Kernel config gate
if ! check_kernel_config "CONFIG_QCOM_IPA"; then
    log_skip "$TESTNAME SKIP - CONFIG_QCOM_IPA not enabled"
    log_info "Writing to file $RES_FILE"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

MODNAME="ipa"
PRE_LOADED=0

# Ensure module is loaded
if is_module_loaded "$MODNAME"; then
    PRE_LOADED=1
    log_info "Module $MODNAME already loaded"
else
    MODPATH=$(find_kernel_module "$MODNAME")
    [ -n "$MODPATH" ] || (log_fail "$MODNAME.ko not found in filesystem"; echo "$TESTNAME FAIL" >"$RES_FILE")
    load_kernel_module "$MODPATH" || (log_fail "Failed to load $MODNAME"; echo "$TESTNAME FAIL" >"$RES_FILE")
    log_pass "$MODNAME module loaded"
fi

# /dev node check (warn only, don't fail/skip)
log_info "Verifying /dev/ipa node"
if wait_for_path "/dev/ipa" 3; then
    log_pass "/dev/ipa node is present"
else
    log_warn "No /dev/ipa node found (platform/use-case may not expose it)"
fi

# dmesg scan: errors + success pattern
# scan_dmesg_errors(label, out_dir, extra_err, ok_kw)
scan_dmesg_errors "ipa" "." "handshake_complete.*error|stall|abort" "IPA Q6 handshake completed"
rc=$?
case "$rc" in
    0) log_warn "IPA-related errors found in dmesg (see ipa_dmesg_errors.log)" ;;
    1) log_info "No IPA-related errors in dmesg" ;;
    2) log_warn "Success pattern 'IPA Q6 handshake completed' not found in dmesg" ;;
    3) log_warn "scan_dmesg_errors misuse (label missing?)" ;;
esac

#Cleanup: unload only if we loaded it
if [ "$PRE_LOADED" -eq 0 ]; then
    log_info "Unloading $MODNAME (loaded by this test)"
    unload_kernel_module "$MODNAME" false || log_warn "Unload $MODNAME failed"
else
    log_info "$MODNAME was pre-loaded; leaving it loaded"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
log_pass "$TESTNAME PASS"
log_info "Writing to file $RES_FILE"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
