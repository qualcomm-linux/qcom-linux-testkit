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

# Define log_info if not already defined
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

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
LOG_FILE="$HEALTH_DIR/reboot_test.log"
RETRY_FILE="$HEALTH_DIR/reboot_retry_count"
MARKER_FILE="/var/reboot_marker"
MAX_RETRIES=3

# Make sure health directory exists
mkdir -p "$HEALTH_DIR"

# Initialize retry count if not exist
if [ ! -f "$RETRY_FILE" ]; then
    echo "0" > "$RETRY_FILE"
fi

log_info "[START] Reboot Health Test Started"

# Reboot logic
if [ ! -f "$MARKER_FILE" ]; then
    log_info "Reboot marker not found. Rebooting now..."
    log_info "Rebooting"
    touch "$MARKER_FILE"
    reboot
    exit 0
else
    # Post-reboot actions
    rm -f "$MARKER_FILE"
    log_info "[PASS] System booted successfully and root shell obtained."
    log_info "[OVERALL PASS] Reboot + Health Check successful!"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
