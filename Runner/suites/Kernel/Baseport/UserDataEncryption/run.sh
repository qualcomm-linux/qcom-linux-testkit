#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Ensure script runs as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
else
    echo "[INFO] Running as root. Continuing..."
fi

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

FSCRYPTCTL="${FSCRYPTCTL:-fscryptctl}"
TESTNAME="UserDataEncryption"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
FS_PATH="/mnt"

# Globals that cleanup will use
key_id=""
KEY_FILE=""

cleanup() {
    if [ -n "$key_id" ]; then
        "$FSCRYPTCTL" remove_key "$key_id" "$FS_PATH" >/dev/null 2>&1 || true
    fi
    [ -n "$KEY_FILE" ] && rm -f "$KEY_FILE" 2>/dev/null || true
    rm -f "$MOUNT_DIR/file.txt" 2>/dev/null || true
    rmdir "$MOUNT_DIR" 2>/dev/null || true
}

# Run cleanup on normal exit, Ctrl-C, or SIGTERM
trap cleanup EXIT INT TERM

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
check_dependencies "$FSCRYPTCTL"

# Create a secure temporary file for the key
if KEY_FILE="$(mktemp)"; then
    echo "[INFO] Temporary key file created: $KEY_FILE"
    chmod 600 "$KEY_FILE"
else
    echo "[ERROR] Failed to create temporary key file" >&2
    exit 1
fi

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
        exit 1
    fi
fi

if ! mkdir -p "$MOUNT_DIR"; then
    log_fail "$TESTNAME : Failed to create mount directory"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# Step 3: Add the key to the filesystem
log_info "Adding encryption key to the filesystem"
key_id=$("$FSCRYPTCTL" add_key "$FS_PATH" < "$KEY_FILE" 2>/dev/null)
if [ -z "$key_id" ]; then
    log_fail "$TESTNAME : Failed to add encryption key"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Key ID: $key_id"

# Step 4: Check key status
log_info "Checking key status"
status=$("$FSCRYPTCTL" key_status "$key_id" "$FS_PATH" 2>/dev/null)
if [ -z "$status" ]; then
    log_fail "$TESTNAME : Failed to get key status"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "Key Status: $status"

# Step 5: Set encryption policy
log_info "Setting encryption policy on $MOUNT_DIR"
if ! "$FSCRYPTCTL" set_policy "$key_id" "$MOUNT_DIR"; then
    log_fail "$TESTNAME : Failed to set encryption policy"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# Step 6: Verify policy
log_info "Verifying encryption policy"
policy_output=$("$FSCRYPTCTL" get_policy "$MOUNT_DIR" 2>/dev/null)
if echo "$policy_output" | grep -q "$key_id"; then
    log_info "Policy verification successful"
else
    log_fail "$TESTNAME : Policy verification failed"
    echo "$TESTNAME FAIL" > "$res_file"
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
    exit 1
fi

# Cleanup
rm -f "$MOUNT_DIR/file.txt"
rmdir "$MOUNT_DIR"

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
