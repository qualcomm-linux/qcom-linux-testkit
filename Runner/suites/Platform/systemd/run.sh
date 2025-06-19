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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="systemd"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

ANY_SUBTEST_FAILED="false"

update_test_pass(){
    subtestname=$1
    msg=$2
    echo "$subtestname PASS" >> "$res_file"
    log_pass "$msg"
}

update_test_fail(){
    subtestname=$1
    msg=$2
    echo "$subtestname FAIL" >> "$res_file"
    log_fail "$msg"
    ANY_SUBTEST_FAILED="true"
}

# Function to check if systemd is running with PID 1

check_systemd_pid() {
    SUBTESTNAME="CheckSystemdPID"
    log_info "----------------------------------------------------"
    log_info "-------- Starting $SUBTESTNAME Functional Test --------"
    if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then 
        update_test_pass "$SUBTESTNAME" "Systemd init started with PID 1"
    else
        update_test_fail "$SUBTESTNAME" "Systemd init did not start with PID 1"
    fi
    log_info "----------------------------------------------------"
    log_info "-------- Stopping $SUBTESTNAME Functional Test --------"
}

# Function to check if systemctl stop command works for systemd-user-sessions.service

check_systemctl_stop() {
    SUBTESTNAME="CheckSystemctlStop"
    log_info "----------------------------------------------------"
    log_info "-------- Starting $SUBTESTNAME Functional Test --------"
    systemctl stop systemd-user-sessions.service
    sleep 5
    if systemctl is-active --quiet systemd-user-sessions.service; then
        update_test_fail "$SUBTESTNAME" "Not able to stop the service systemd-user-sessions with systemctl"
    else
        update_test_pass "$SUBTESTNAME" "Able to stop the service systemd-user-sessions with systemctl"
    fi
    log_info "----------------------------------------------------"
    log_info "-------- Stopping $SUBTESTNAME Functional Test --------"
}

# Function to check if systemctl start command works for systemd-user-sessions.service
check_systemctl_start() {
    SUBTESTNAME="CheckSystemctlStart"
    log_info "----------------------------------------------------"
    log_info "-------- Starting $SUBTESTNAME Functional Test --------"
    systemctl start systemd-user-sessions.service
    if systemctl is-active --quiet systemd-user-sessions.service; then
        update_test_pass "$SUBTESTNAME" "Service started successfully with systemctl command"
    else
        update_test_fail "$SUBTESTNAME" "Failed to start service with systemctl command"
    fi
    log_info "----------------------------------------------------"
    log_info "-------- Stopping $SUBTESTNAME Functional Test --------"
}

# Function to check for any failed services and print them
check_failed_services() {
    SUBTESTNAME="CheckFailedServices"
    log_info "----------------------------------------------------"
    log_info "-------- Starting $SUBTESTNAME Functional Test --------"
    failed_services=$(systemctl --failed --no-legend --plain | awk '{print $1}')
    if [ -z "$failed_services" ]; then
        update_test_pass "$SUBTESTNAME" "No service is in failed state on device"
    else
        update_test_fail "$SUBTESTNAME" "------ List of failed services --------"
        log_fail $failed_services
        log_fail "--------------------------------------"
    fi
    log_info "----------------------------------------------------"
    log_info "-------- Stopping $SUBTESTNAME Functional Test --------"
}

# Call the functions
check_systemd_pid
check_systemctl_stop
check_systemctl_start
check_failed_services


if [ "$ANY_SUBTEST_FAILED" = "true" ]; then
    exit 1
else
    exit 0
fi

