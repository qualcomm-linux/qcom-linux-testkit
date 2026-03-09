#!/bin/sh
# run.sh - Verification for qrtr-lookup service

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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

# Only source if not already loaded
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    export __INIT_ENV_LOADED=1
fi

# Always source functestlib.sh
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="qrtr_lookup_validation"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "--------------------------------------------------"
log_info "------------- Starting $TESTNAME Test ------------"

check_dependencies qrtr-lookup

# --- Argument Parsing ---
TARGET_NAME=""
INSTANCE_ID=""

while getopts "t:i:" opt; do
  case ${opt} in
    t) TARGET_NAME=$OPTARG ;;
    i) INSTANCE_ID=$OPTARG ;;
    \?) 
        log_fail "Invalid option: -$OPTARG"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0 
        ;;
  esac
done

# Resolve Target Name to ID if provided
if [ -n "$TARGET_NAME" ]; then
    MAPPED_ID=$(get_qrtr_id_from_name "$TARGET_NAME")
    if [ -n "$MAPPED_ID" ]; then
        INSTANCE_ID=$MAPPED_ID
        log_info "Mapped target '$TARGET_NAME' to Instance ID $INSTANCE_ID"
    else
        log_fail "Unknown target name '$TARGET_NAME'"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0
    fi
fi

# --- Main Logic ---

if [ -n "$INSTANCE_ID" ]; then
    # --- MODE 1: Specific Verification ---
    log_info "Verifying specific Instance ID: $INSTANCE_ID"
    
    if qrtr_id_exists "$INSTANCE_ID"; then
        scan_dmesg_errors "qrtr" "$PWD"
        log_pass "Found service for ID $INSTANCE_ID"
        echo "$TESTNAME PASS" > "$res_file"
    else
        log_fail "Instance ID $INSTANCE_ID not found in qrtr-lookup output."
        echo "$TESTNAME FAIL" > "$res_file"
    fi

else
    # --- MODE 2: Default (Auto-Detect Any) ---
    log_info "No specific target provided. Scanning for ANY Test services..."
    
    # Get all lines containing "Test service", extract ID (Col 3)
    FOUND_IDS=$(qrtr-lookup | grep "Test service" | awk '{print $3}')
    
    if [ -n "$FOUND_IDS" ]; then
        log_info "Found the following active Test Services:"
        
        for id in $FOUND_IDS; do
            name=$(get_qrtr_name_from_id "$id")
            log_info "  - ID $id : $name"
        done
        
        # Pass if at least one is found
        scan_dmesg_errors "qrtr" "$PWD"
        log_pass "Found active qrtr-lookup test services"
        echo "$TESTNAME PASS" > "$res_file"
    else
        log_fail "No 'Test service' lines found in qrtr-lookup output."
        echo "$TESTNAME FAIL" > "$res_file"
    fi
fi

exit 0
