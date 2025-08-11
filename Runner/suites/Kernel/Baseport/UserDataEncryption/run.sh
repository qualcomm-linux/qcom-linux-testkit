#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Ensure script runs as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 0
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
    exit 0
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

if [ -z "$test_path" ]; then
    log_fail "Path not found for $TESTNAME test. Falling back to SCRIPT_DIR: $SCRIPT_DIR"
    test_path="$SCRIPT_DIR"

    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    log_fail "$TESTNAME : Test case directory not found"
    exit 0
fi

cd "$test_path" || {
    log_fail "Failed to change directory to $test_path"
    log_fail "Path not found for $TESTNAME test. Falling back to SCRIPT_DIR: $SCRIPT_DIR"
    test_path="$SCRIPT_DIR"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    exit 0
}

res_file="./$TESTNAME.res"

# Globals that cleanup will use
MOUNT_DIR=""
FS_PATH=""
key_id=""
KEY_FILE=""

cleanup() {
    if [ -n "$MOUNT_DIR" ] && [ "$MOUNT_DIR" != "/" ]; then
        log_info "Cleaning up mount directory: $MOUNT_DIR"

        if rm -f "$MOUNT_DIR/file.txt" 2>/dev/null; then
            log_info "Deleted test file: $MOUNT_DIR/file.txt"
        else
            log_warn "Failed to delete test file: $MOUNT_DIR/file.txt"
        fi

        if rmdir "$MOUNT_DIR" 2>/dev/null; then
            log_info "Removed mount directory: $MOUNT_DIR"
        else
            log_warn "Failed to remove mount directory: $MOUNT_DIR"
        fi
    fi

    if [ -n "$key_id" ]; then
        "$FSCRYPTCTL" remove_key "$key_id" "$FS_PATH" >/dev/null 2>&1 || true
    fi
    [ -n "$KEY_FILE" ] && rm -f "$KEY_FILE" 2>/dev/null || true
}

# Run cleanup on normal exit, Ctrl-C, or SIGTERM
trap cleanup EXIT INT TERM

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
check_dependencies "$FSCRYPTCTL"

if ! command -v "$FSCRYPTCTL" >/dev/null 2>&1; then
    log_warn "$FSCRYPTCTL binary was not found. Skipping $TESTNAME."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Create a secure temporary file for the key
if KEY_FILE="$(mktemp)"; then
    log_info "Temporary key file created: $KEY_FILE"
    chmod 600 "$KEY_FILE"
else
    log_fail "$TESTNAME : Failed to create temporary key file"
    echo "[ERROR] Failed to create temporary key file" >&2
    exit 0
fi

# Step 1: Generate a 64-byte key
log_info "Generating 64-byte encryption key"
if ! head -c 64 /dev/urandom > "$KEY_FILE"; then
    log_fail "$TESTNAME : Failed to generate encryption key"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# Step 2: Create mount folder (this will create an unique folder under mnt)
log_info "Creating unique mount folder under /mnt"
MOUNT_DIR=$(mktemp -d /mnt/testing.XXXXXX)
if [ ! -d "$MOUNT_DIR" ]; then
    log_fail "$TESTNAME : Failed to create mount directory"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Created unique mount directory: $MOUNT_DIR"


FS_PATH=$(df --output=target "$MOUNT_DIR" | tail -n 1)
if [ -z "$FS_PATH" ]; then
    log_fail "$TESTNAME : Failed to determine filesystem mount point for $MOUNT_DIR"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Derived filesystem mount point: $FS_PATH"

# Step 3: Add the key to the filesystem
log_info "Adding encryption key to the filesystem"
key_id=$("$FSCRYPTCTL" add_key "$FS_PATH" < "$KEY_FILE" 2>/dev/null)
scan_dmesg_errors "$SCRIPT_DIR" "fscrypt" ""

if [ -z "$key_id" ]; then
    log_fail "$TESTNAME : Failed to add encryption key"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

log_info "Key ID: $key_id"

# Step 4: Check key status
log_info "Checking key status" 
status=$("$FSCRYPTCTL" key_status "$key_id" "$FS_PATH" 2>/dev/null)
if [ -z "$status" ]; then
    log_fail "$TESTNAME : Failed to get key status"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Key Status: $status"

if ! echo "$status" | grep -q "^Present"; then
    log_fail "$TESTNAME : Key is not usable (status: $status)"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi


# Step 5: Set encryption policy
log_info "Setting encryption policy on $MOUNT_DIR"

if ! "$FSCRYPTCTL" set_policy "$key_id" "$MOUNT_DIR"; then
    log_fail "$TESTNAME : Failed to set encryption policy"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
scan_dmesg_errors "$SCRIPT_DIR" "fscrypt" ""


# Step 6: Verify policy
log_info "Verifying encryption policy"
policy_output=$("$FSCRYPTCTL" get_policy "$MOUNT_DIR" 2>/dev/null)
scan_dmesg_errors "$SCRIPT_DIR" "fscrypt" ""


policy_key=$(echo "$policy_output" | awk -F': ' '/Master key identifier/ {print $2}' | tr -d '[:space:]')

if [ "$policy_key" = "$key_id" ]; then
    log_info "Policy verification successful: Master key identifier matches key_id"
else
    log_fail "$TESTNAME : Policy verification failed (expected $key_id, got $policy_key)"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
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
    exit 0
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
