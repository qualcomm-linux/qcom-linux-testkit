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
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="shmbridge"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "==== Test Initialization ===="

log_info "Checking if required tools are available..."
if ! check_dependencies grep find basename cat readlink head; then
    log_skip "$TESTNAME SKIP - missing required grep/find/basename/cat/readlink/head utility"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Checking kernel config for CONFIG_QCOM_SCM support..."
if ! check_kernel_config "CONFIG_QCOM_SCM"; then
    log_fail "$TESTNAME : CONFIG_QCOM_SCM not enabled, test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

fail_flag=0


log_info "--- qcom_scm sysfs module presence ---"
if [ -d /sys/module/qcom_scm ]; then
    log_pass "qcom_scm module directory exists under /sys/module."
else
    log_fail "qcom_scm module directory NOT found under /sys/module."
    fail_flag=1
fi

log_info "--- Device Tree firmware/scm node ---"
if check_dt_nodes "/sys/firmware/devicetree/base/firmware/scm"; then
    log_pass "Device Tree firmware/scm node is present."
else
    log_fail "Device Tree /sys/firmware/devicetree/base/firmware/scm node is missing."
    fail_flag=1
fi

log_info "--- qcom_scm platform driver registration ---"
if [ -d /sys/bus/platform/drivers/qcom_scm ]; then
    log_pass "qcom_scm platform driver is registered on the platform bus."
else
    log_fail "qcom_scm platform driver is NOT registered on the platform bus."
    log_info "[DIAG] Available SCM-like platform drivers (to check for name/path change across kernel versions):"
    for drv in /sys/bus/platform/drivers/*scm* /sys/bus/platform/drivers/*qcom_scm* /sys/bus/platform/drivers/*tee* /sys/bus/platform/drivers/*trustzone*; do
        [ -e "$drv" ] || continue
        log_info "[DIAG]   $(basename "$drv")"
    done
    log_info "[DIAG] All registered platform drivers:"
    for drv in /sys/bus/platform/drivers/*; do
        [ -d "$drv" ] || continue
        log_info "[DIAG]   $(basename "$drv")"
    done
    fail_flag=1
fi

log_info "--- qcom_scm driver-to-device binding ---"
if [ -d /sys/bus/platform/drivers/qcom_scm ]; then
    bound_devices=$(find /sys/bus/platform/drivers/qcom_scm -maxdepth 1 -type l 2>/dev/null)
    if [ -n "$bound_devices" ]; then
        for dev in $bound_devices; do
            dev_name=$(basename "$dev")
            log_pass "qcom_scm driver is bound to device: $dev_name"
        done
    else
        log_fail "qcom_scm driver is registered but NOT bound to any platform device."
        log_info "[DIAG] Contents of /sys/bus/platform/drivers/qcom_scm:"
        for entry in /sys/bus/platform/drivers/qcom_scm/*; do
            [ -e "$entry" ] || continue
            log_info "[DIAG] $(ls -ld "$entry" 2>/dev/null)"
        done
        log_info "[DIAG] All platform devices (to check for path mismatch):"
        for dev in /sys/bus/platform/devices/*scm*; do
            [ -e "$dev" ] || continue
            log_info "[DIAG]   $dev"
        done
        log_info "Deferred probe list (if available):"
        if [ -r /sys/kernel/debug/devices_deferred ]; then
            grep -i "scm" /sys/kernel/debug/devices_deferred 2>/dev/null | while IFS= read -r line; do
                log_info "$line"
            done
        else
            log_info "/sys/kernel/debug/devices_deferred not available."
        fi
        fail_flag=1
    fi
else
    log_info "Skipping driver binding check (platform driver not registered)."
fi

log_info "--- qcom_scm sysfs attribute readability ---"
scm_attrs_ok=0
for attr in /sys/module/qcom_scm/parameters/*; do
    [ -f "$attr" ] || continue
    attr_name=$(basename "$attr")
    if attr_val=$(cat "$attr" 2>/dev/null); then
        log_pass "qcom_scm sysfs attribute readable: $attr_name = $attr_val"
        scm_attrs_ok=1
    else
        log_fail "qcom_scm sysfs attribute NOT readable: $attr_name"
        fail_flag=1
    fi
done
if [ "$scm_attrs_ok" -eq 0 ]; then
    log_info "No qcom_scm module parameters found (may be expected for built-in config)."
fi

log_info "--- qcom_scm device uevent/modalias ---"
scm_uevent_found=0
for dev_link in /sys/bus/platform/drivers/qcom_scm/*; do
    [ -L "$dev_link" ] || continue
    dev_path=$(readlink -f "$dev_link" 2>/dev/null) || continue

    if [ -f "$dev_path/uevent" ]; then
        modalias=$(grep "^MODALIAS=" "$dev_path/uevent" 2>/dev/null | head -n 1)
        if [ -n "$modalias" ]; then
            log_pass "qcom_scm device uevent is valid: $modalias"
        else
            log_pass "qcom_scm device uevent file is present (no MODALIAS entry)."
        fi
        scm_uevent_found=1
        break
    fi
done
if [ "$scm_uevent_found" -eq 0 ]; then
    log_info "qcom_scm device uevent not found (may be expected if driver is not bound)."
fi


log_info "--- TEE/TrustZone device node presence ---"
tee_found=0
for tee_node in /dev/tee0 /dev/teepriv0; do
    if [ -c "$tee_node" ]; then
        log_pass "TEE device node is present: $tee_node"
        tee_found=1
    fi
done
if [ "$tee_found" -eq 0 ]; then
    log_warn "No TEE device node found (/dev/tee0, /dev/teepriv0)."
fi


log_info "-----------------------------------------------------------------------------------------"
if [ "$fail_flag" -eq 1 ]; then
    log_fail "$TESTNAME : FAIL - One or more qcom_scm validation checks failed."
    echo "$TESTNAME FAIL" > "$res_file"
else
    log_pass "$TESTNAME : PASS - qcom_scm driver validated successfully across all checks."
    echo "$TESTNAME PASS" > "$res_file"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
