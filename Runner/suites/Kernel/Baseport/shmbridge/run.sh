#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
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

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="shmbridge"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "==== Test Initialization ===="

log_info "Checking if required tools are available"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies grep cat sed mkdir mktemp date wc tr id cp head; then
    test_result_finish SKIP "$TESTNAME SKIP - missing required image utilities"
fi

log_info "Checking kernel config for QCOM_SCM support..."
if ! check_kernel_config "CONFIG_QCOM_SCM"; then
    test_result_finish SKIP "$TESTNAME : CONFIG_QCOM_SCM not enabled"
fi

smb_out_dir=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create SCM diagnostics under CWD=$PWD"
scan_dmesg_errors \
    "$smb_out_dir" \
    "qcom_scm|shmbridge|shm_bridge|qcom_tzmem" \
    "Kernel command line|Command line|qcom_scm.download_mode|CONFIG_QCOM_SCM" || true

log_info "Checking qcom_scm presence using sysfs/current-boot kernel log"

qcom_scm_present=0

if [ -d /sys/module/qcom_scm ]; then
    qcom_scm_present=1
    log_pass "qcom_scm driver is present in sysfs."
    log_info "qcom_scm sysfs node: /sys/module/qcom_scm"

    if command -v print_path_meta >/dev/null 2>&1; then
        print_path_meta /sys/module/qcom_scm 2>/dev/null |
            while IFS= read -r line || [ -n "$line" ]; do
                [ -n "$line" ] || continue
                log_info "[qcom_scm-sysfs] $line"
            done
    fi

    if [ -r /sys/module/qcom_scm/initstate ]; then
        qcom_scm_initstate="$(cat /sys/module/qcom_scm/initstate 2>/dev/null || true)"
        [ -n "$qcom_scm_initstate" ] || qcom_scm_initstate="unknown"
        log_info "qcom_scm initstate: $qcom_scm_initstate"
    else
        log_info "qcom_scm initstate: <not exposed>"
    fi

    if [ -r /sys/module/qcom_scm/refcnt ]; then
        qcom_scm_refcnt="$(cat /sys/module/qcom_scm/refcnt 2>/dev/null || true)"
        [ -n "$qcom_scm_refcnt" ] || qcom_scm_refcnt="unknown"
        log_info "qcom_scm refcnt: $qcom_scm_refcnt"
    else
        log_info "qcom_scm refcnt: <not exposed>"
    fi

    if [ -d /sys/module/qcom_scm/parameters ]; then
        log_info "qcom_scm parameters:"
        qcom_scm_param_found=0

        for param in /sys/module/qcom_scm/parameters/*; do
            [ -e "$param" ] || continue
            qcom_scm_param_found=1
            param_name="${param##*/}"

            if [ -r "$param" ]; then
                param_value="$(cat "$param" 2>/dev/null || true)"
                [ -n "$param_value" ] || param_value="<empty>"
                log_info "[qcom_scm-param] $param_name=$param_value"
            else
                log_info "[qcom_scm-param] $param_name=<not readable>"
            fi
        done

        if [ "$qcom_scm_param_found" -eq 0 ]; then
            log_info "[qcom_scm-param] <none>"
        fi
    else
        log_info "qcom_scm parameters: <not exposed>"
    fi

    if [ -d /sys/module/qcom_scm/drivers ]; then
        log_info "qcom_scm driver links:"
        qcom_scm_driver_found=0

        for driver_link in /sys/module/qcom_scm/drivers/*; do
            [ -e "$driver_link" ] || continue
            qcom_scm_driver_found=1
            log_info "[qcom_scm-driver] ${driver_link##*/}"
        done

        if [ "$qcom_scm_driver_found" -eq 0 ]; then
            log_info "[qcom_scm-driver] <none>"
        fi
    else
        log_info "qcom_scm driver links: <not exposed>"
    fi
elif [ "${DMESG_ACCESS_STATUS:-unavailable}" = "available" ] &&
     grep -i '\bqcom_scm\b' "$smb_out_dir/dmesg_snapshot.log" |
         grep -viE 'Kernel command line|Command line|qcom_scm\.download_mode' >/dev/null; then
    qcom_scm_present=1
    log_pass "qcom_scm present in current-boot kernel log."
    log_info "qcom_scm sysfs node: <not present>, using current-boot kernel log evidence"

    grep -i '\bqcom_scm\b' "$smb_out_dir/dmesg_snapshot.log" |
        grep -viE 'Kernel command line|Command line|qcom_scm\.download_mode' |
        sed -n '1,10p' |
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            log_info "[qcom_scm-kernel-evidence] $line"
        done
fi

if [ "$qcom_scm_present" -ne 1 ]; then
    if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
        test_result_finish FAIL "SCM validation requires readable kernel logs, runtime evidence is unavailable, inspect $smb_out_dir/dmesg_access.log"
    fi
    test_result_finish FAIL "qcom_scm not found in sysfs or captured current-boot kernel log"
fi

if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_finish FAIL "SCM is present, required kernel-log access is unavailable, inspect $smb_out_dir/dmesg_access.log"
fi

if [ -s "$smb_out_dir/dmesg_errors.log" ]; then
    log_file_with_label qcom-scm-dmesg "$smb_out_dir/dmesg_errors.log" 60
    test_result_finish FAIL "SCM/shmbridge errors detected, inspect $smb_out_dir/dmesg_errors.log"
fi
test_result_finish PASS "qcom_scm present and no SCM/shmbridge errors in the captured kernel log"
