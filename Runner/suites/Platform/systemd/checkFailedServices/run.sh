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

TESTNAME="checkFailedServices"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

# Function to check specific services for failures
check_failed_services() {
    log_info "----------------------------------------------------"
    log_info "-------- Starting $TESTNAME Functional Test --------"
    
    # List of services to check
    services_to_check="android-tools-adbd.service NetworkManager.service pd-mapper.service"
    
    # Initialize variables
    test_passed=true
    
    # Check each service individually
    for service in $services_to_check; do
        # Check if service exists
        if ! systemctl list-unit-files "$service" --no-legend --no-pager | grep -q "$service"; then
            failed_or_missing_services="${failed_or_missing_services}${service} (missing)\n"
            test_passed=false
            continue
        fi
        
        # Check if service is failed
        status=$(systemctl is-failed "$service" 2>/dev/null)
        if [ "$status" = "failed" ]; then
            failed_or_missing_services="${failed_or_missing_services}${service} (failed)\n"
            test_passed=false
        fi
    done
    
    if $test_passed; then
        log_pass "All monitored services are present and not in failed state"
        echo "$TESTNAME PASS" > "$res_file"
    else
        log_fail "------ List of failed or missing monitored services --------"
        log_fail "$failed_or_missing_services"
        log_fail "--------------------------------------"
        echo "$TESTNAME FAIL" > "$res_file"
    fi
    log_info "----------------------------------------------------"
    log_info "-------- Stopping $TESTNAME Functional Test --------"
}

# Call the functions
check_failed_services
