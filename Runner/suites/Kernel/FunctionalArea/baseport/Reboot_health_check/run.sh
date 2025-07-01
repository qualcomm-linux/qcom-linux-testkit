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

TESTNAME="Reboot_health_check"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Directory for health check files
HEALTH_DIR="/var/reboot_health"
RETRY_FILE="$HEALTH_DIR/reboot_retry_count"
MAX_RETRIES=3

# Make sure health directory exists
mkdir -p "$HEALTH_DIR"

# Initialize retry count if not exist
if [ ! -f "$RETRY_FILE" ]; then
    echo "0" > "$RETRY_FILE"
fi

# Read current retry count
RETRY_COUNT=$(cat "$RETRY_FILE")

log_info "--------------------------------------------"
log_info "Boot Health Check Started - $(date)" 
log_info "Current Retry Count: $RETRY_COUNT"

# Health Check: You can expand this check
if [ "$(whoami)" = "root" ]; then
    log_pass "System booted successfully and root shell obtained."
    log_info "Test Completed Successfully after $RETRY_COUNT retries."
    
    # Optional: clean retry counter after success
    echo "0" > "$RETRY_FILE"
    
    exit 0
else
    log_fail "Root shell not available!"
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "$RETRY_COUNT" > "$RETRY_FILE"
    
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        log_error "[ERROR] Maximum retries ($MAX_RETRIES) reached. Stopping test."
        exit 1
    else
        log_info "Rebooting system for retry #$RETRY_COUNT..."
        sync
        sleep 2
        reboot -f
    fi
fi
