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

TESTNAME="UserDataEncryption"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
check_dependencies fscryptctl 

KEY_FILE="/data/std_key"
MOUNT_DIR="/mnt/testing"

# Step 1: Generate a 64-byte key
log_info "Generating 64-byte encryption key"
if ! head -c 64 /dev/urandom > "$KEY_FILE"; then
    log_fail "$TESTNAME : Failed to generate encryption key"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# Step 2: Create mount folder
log_info "Creating mount folder at $MOUNT_DIR"
if [ -d "$MOUNT_DIR" ]; then
    log_info "$MOUNT_DIR already exists. Deleting it first."
    if ! rm -rf "$MOUNT_DIR"; then
        log_fail "$TESTNAME : Failed to delete existing mount directory"
        echo "$TESTNAME FAIL" > "$res_file"
        rm -f "$KEY_FILE"
        exit 1
    fi
fi

if ! mkdir -p "$MOUNT_DIR"; then
    log_fail "$TESTNAME : Failed to create mount directory"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$KEY_FILE"
    exit 1
fi

# Step 3: Add the key to the filesystem
log_info "Adding encryption key to the filesystem"
key_id=$(/data/fscryptctl add_key /mnt < "$KEY_FILE" 2>/dev/null)
if [ -z "$key_id" ]; then
    log_fail "$TESTNAME : Failed to add encryption key"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$KEY_FILE"
    exit 1
fi

log_info "Key ID: $key_id"

# Step 4: Check key status
log_info "Checking key status"
status=$(/data/fscryptctl key_status "$key_id" / 2>/dev/null)
if [ -z "$status" ]; then
    log_fail "$TESTNAME : Failed to get key status"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$KEY_FILE"
    exit 1
fi
log_info "Key Status: $status"

# Step 5: Set encryption policy
log_info "Setting encryption policy on $MOUNT_DIR"
if ! /data/fscryptctl set_policy "$key_id" "$MOUNT_DIR"; then
    log_fail "$TESTNAME : Failed to set encryption policy"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$KEY_FILE"
    exit 1
fi

# Step 6: Verify policy
log_info "Verifying encryption policy"
policy_output=$(/data/fscryptctl get_policy "$MOUNT_DIR" 2>/dev/null)
if echo "$policy_output" | grep -q "$key_id"; then
    log_info "Policy verification successful"
else
    log_fail "$TESTNAME : Policy verification failed"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$KEY_FILE"
    exit 1
fi

# Step 7: Create and read a test file
log_info "Creating test file in encrypted directory"
echo "file" > "$MOUNT_DIR/file.txt"

log_info "Reading test file"
file_content=$(cat "$MOUNT_DIR/file.txt")
if [ "$file_content" = "file" ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$KEY_FILE"
    exit 1
fi

# Cleanup
rm -f "$KEY_FILE"
rm -f "$MOUNT_DIR/file.txt"
rmdir "$MOUNT_DIR"

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
