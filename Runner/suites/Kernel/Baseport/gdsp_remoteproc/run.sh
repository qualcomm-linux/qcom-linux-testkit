#!/bin/sh
 
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
 
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
 
TESTNAME="gdsp_remoteproc"
res_file="./$TESTNAME.res"
LOG_FILE="./$TESTNAME.log"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
 
log_info "-----------------------------------------------------------------------------------------" 
log_info "------------------- Starting $TESTNAME Testcase ----------------------------" 
log_info "=== Test Initialization ===" 
 
overall_result="PASS"
 
handle_failure() {
     name="$1"
     msg="$2"
     res_file="$3"
     log="$4"
    log_fail "$msg" "$log"
    echo "$name FAIL" > "$res_file"
    overall_result="FAIL"
}
 
for gdsp_firmware in gpdsp0 gpdsp1; do
    log_info "Processing $gdsp_firmware" 
    indiv_res_file="./$gdsp_firmware.res"
 
    if ! validate_remoteproc_running "$gdsp_firmware" "$LOG_FILE" 15 2; then
        handle_failure "$gdsp_firmware" "$gdsp_firmware remoteproc validation failed" "$indiv_res_file" "$LOG_FILE"
        continue
    fi
 
    log_pass "$gdsp_firmware remoteproc validated as running" 
 
    rproc_path=$(get_remoteproc_path_by_firmware "$gdsp_firmware")
    if [ -z "$rproc_path" ]; then
        handle_failure "$gdsp_firmware" "Remoteproc path not found for $gdsp_firmware" "$indiv_res_file" "$LOG_FILE"
        continue
    fi
 
    log_info "Stopping $gdsp_firmware at $rproc_path" 
    if ! stop_remoteproc "$rproc_path"; then
        handle_failure "$gdsp_firmware" "$gdsp_firmware stop failed" "$indiv_res_file" "$LOG_FILE"
        continue
    fi
    log_pass "$gdsp_firmware stop successful" 
 
    log_info "Restarting $gdsp_firmware at $rproc_path" 
    if ! start_remoteproc "$rproc_path"; then
        handle_failure "$gdsp_firmware" "$gdsp_firmware start failed" "$indiv_res_file" "$LOG_FILE"
        continue
    fi
 
    log_pass "$gdsp_firmware PASS" 
    echo "$gdsp_firmware PASS" > "$indiv_res_file"
done
 
log_info "$TESTNAME $overall_result" 
echo "$TESTNAME $overall_result" > "$res_file"
log_info "------------------- Completed $TESTNAME Testcase ----------------------------" 
 
if [ "$overall_result" = "FAIL" ]; then
    exit 1
else
    exit 0
fi
 