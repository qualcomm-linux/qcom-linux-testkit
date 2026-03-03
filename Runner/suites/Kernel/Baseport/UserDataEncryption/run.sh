#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Robustly find and source init_env
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

if [ -z "${INIT_ENV:-}" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 0
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

FSCRYPTCTL="${FSCRYPTCTL:-fscryptctl}"
TESTNAME="UserDataEncryption"
test_path=$(find_test_case_by_name "$TESTNAME")

if [ -z "${test_path:-}" ]; then
    log_warn "Path not found for $TESTNAME test. Falling back to SCRIPT_DIR: $SCRIPT_DIR"
    test_path="$SCRIPT_DIR"
fi

res_file="$test_path/$TESTNAME.res"

# Ensure script runs as root
if [ "$(id -u)" -ne 0 ]; then
    log_skip "This script must be run as root."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
else
    log_info "Running as root. Continuing..."
fi

if ! cd "${test_path:-}"; then
    log_fail "Failed to change directory to $test_path"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# Globals that cleanup will use
MOUNT_DIR=""
FS_PATH=""
key_id=""
KEY_FILE=""

cleanup() {

    if [ -n "${MOUNT_DIR:-}" ] && [ "${MOUNT_DIR:-}" != "/" ] && [ -d "${MOUNT_DIR:-}" ]; then
        log_info "Cleaning up mount directory: $MOUNT_DIR"

        if ! rm -f "$MOUNT_DIR/file.txt" 2>/dev/null; then
            log_warn "Failed to remove test file: $MOUNT_DIR/file.txt"
        fi

        if ! rmdir "$MOUNT_DIR" 2>/dev/null; then
            log_warn "Failed to remove mount directory: $MOUNT_DIR"
        fi
    fi

    if [ -n "${key_id:-}" ] && [ -n "${FS_PATH:-}" ]; then
        if ! "$FSCRYPTCTL" remove_key "$key_id" "$FS_PATH" >/dev/null 2>&1; then
            log_warn "Failed to remove key $key_id from $FS_PATH"
        else
            log_info "removed key $key_id from $FS_PATH"
        fi
    fi 

    
    if [ -n "${KEY_FILE:-}" ]; then
        if ! rm -f "$KEY_FILE" 2>/dev/null; then
            log_warn "Failed to remove key file: $KEY_FILE"
        fi
    fi  

    scan_dmesg_errors "$test_path" "fscrypt" ""
}

# Run cleanup on normal exit, Ctrl-C, or SIGTERM
trap cleanup EXIT INT TERM

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="


## kernel config check

if ! check_kernel_config "CONFIG_FS_ENCRYPTION"; then
    log_skip "$TESTNAME : Kernel lacks CONFIG_FS_ENCRYPTION. Skipping."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Checking if dependency binary is available"


if ! check_dependencies "$FSCRYPTCTL"; then
    log_skip "$TESTNAME : Dependency check failed (missing or unusable: $FSCRYPTCTL). Skipping."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi


# Create a secure temporary file for the key
if KEY_FILE="$(mktemp)"; then
    log_info "Temporary key file created: $KEY_FILE"
    chmod 600 "$KEY_FILE"
else
    log_fail "$TESTNAME : Failed to create temporary key file"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# Step 1: Generate a 64-byte key
log_info "Generating 64-byte encryption key"
if ! head -c 64 /dev/urandom > "${KEY_FILE:-}"; then
    log_fail "$TESTNAME : Failed to generate encryption key"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

BASE_MNT="/mnt"

# Ensure /mnt exists
if [ -d "$BASE_MNT" ] && [ -w "$BASE_MNT" ]; then
    log_info "Using existing writable $BASE_MNT for mount directory base"
else
    BASE_MNT="/UDE"
    log_info "/mnt not usable; falling back to separate base directory: $BASE_MNT"

    if ! mkdir -p "$BASE_MNT"; then
        log_fail "Failed to create base directory $BASE_MNT; cannot proceed with UserDataEncryption test"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0
    fi

    if [ ! -w "$BASE_MNT" ]; then
        log_fail "Base directory $BASE_MNT is not writable; cannot proceed with UserDataEncryption test"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0
    fi
fi

# Step 2: Create mount folder (this will create an unique folder under mnt)
log_info "Creating unique mount folder under $BASE_MNT"

MOUNT_DIR=$(mktemp -d "${BASE_MNT:-}/testing.XXXXXX")
if [ ! -d "${MOUNT_DIR:-}" ]; then
    log_fail "$TESTNAME : Failed to create mount directory"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Created unique mount directory: $MOUNT_DIR"


FS_PATH=$(df --output=target -- "$MOUNT_DIR" 2>/dev/null | awk 'NR==2{print $1}')

if [ -z "${FS_PATH:-}" ]; then
    FS_PATH=$(df -P "$MOUNT_DIR" 2>/dev/null | awk 'NR==2{print $6}')
fi

if [ -z "${FS_PATH:-}" ]; then
    log_fail "$TESTNAME : Failed to determine filesystem mount point for $MOUNT_DIR"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Derived filesystem mount point: $FS_PATH"


#file-system check
if fs_type="$(df -Th "${FS_PATH:-}" 2>/dev/null | awk 'NR==2{print $2}')"; then
    if [ -n "${fs_type:-}" ]; then

        if [ "$fs_type" = "ext4" ] || [ "$fs_type" = "f2fs" ]; then
            log_info "Filesystem '$fs_type' is supported."
        else
            log_skip "$TESTNAME: Filesystem type '$fs_type' is not supported by fscrypt. Skipping."
            echo "$TESTNAME SKIP" > "$res_file"
            exit 0
        fi

    else
        log_warn "df -Th succeeded but could not parse filesystem type for $FS_PATH"
    fi
else
    log_warn "df -Th failed for $FS_PATH"
fi

# Step 3: Add the key to the filesystem
log_info "Adding encryption key to the filesystem"

add_key_output=$("$FSCRYPTCTL" add_key "$FS_PATH" < "$KEY_FILE" 2>&1)
rc=$?
key_id=$(printf '%s\n' "$add_key_output" | awk 'match($0,/^[0-9a-fA-F]{32}$/){print $0; exit}')

if [ "$rc" -ne 0 ] || [ -z "${key_id:-}" ]; then
    log_fail "$TESTNAME : Failed to add encryption key. fscryptctl output: $add_key_output"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

log_info "Key ID: $key_id"

# Step 4: Check key status
log_info "Checking key status" 
status=$("$FSCRYPTCTL" key_status "$key_id" "$FS_PATH" 2>&1)
rc=$?

if [ "$rc" -ne 0 ] || [ -z "${status:-}" ]; then
    log_fail "$TESTNAME : Failed to get key status. key status output : $status"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

if ! echo "${status:-}" | grep -q "^Present"; then
    log_fail "$TESTNAME : Key is not usable (status: $status)"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Key Status: $status"

# Step 5: Set encryption policy
log_info "Setting encryption policy on $MOUNT_DIR"

set_policy_output=$("$FSCRYPTCTL" set_policy "$key_id" "$MOUNT_DIR" 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then
    log_fail "$TESTNAME : Failed to set encryption policy, set policy output : $set_policy_output"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# Step 6: Verify policy
log_info "Verifying encryption policy"

policy_output=$("$FSCRYPTCTL" get_policy "$MOUNT_DIR" 2>&1)
rc=$?

if [ "$rc" -ne 0 ] || [ -z "${policy_output:-}" ]; then
    log_fail "fscryptctl get_policy failed for $MOUNT_DIR: $policy_output"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0  
fi

not_encrypted=$(echo "$policy_output" | awk '/file or directory not encrypted/ {print 1}')

if [ -n "$not_encrypted" ]; then
    log_fail "$MOUNT_DIR is not encrypted (fscryptctl reports 'file or directory not encrypted')"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

policy_key=$(echo "$policy_output" | awk -F': ' '/Master key identifier/ {print $2}' | tr -d '[:space:]')

if [ -z "${policy_key:-}" ]; then
    log_fail "$TESTNAME : fscryptctl get_policy did not return a Master key identifier line"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

if [ "${policy_key:-}" = "${key_id:-}" ]; then
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
if [ "${file_content:-}" = "file" ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
