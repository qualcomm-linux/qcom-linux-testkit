#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

# Import test suite definitions
source "$(pwd)/init_env"
TESTNAME="shmbridge"

# Import test functions library
source "$TOOLS/functestlib.sh"
test_path=$(find_test_case_by_name "$TESTNAME")

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

MOUNT_POINT="/mnt/overlay"
PARTITION="/dev/disk/by-partlabel/xbl_ramdump_a"
KEY_FILE="$MOUNT_POINT/stdkey"
TEST_DIR="$MOUNT_POINT/test"
TEST_FILE="$TEST_DIR/txt"

log_info "Creating mount point at $MOUNT_POINT"
mkdir -p "$MOUNT_POINT"

log_info "Checking if partition exists"
if [ ! -e "$PARTITION" ]; then
    log_fail "Partition $PARTITION not found"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    exit 1
fi

log_info "Formatting partition with ext4 and encryption options"
if ! mount | grep -q "$PARTITION"; then
    mkfs.ext4 -F -O encrypt,stable_inodes "$PARTITION"
else
    log_warn "$PARTITION is already mounted; skipping format"
fi

log_info "Mounting partition to $MOUNT_POINT with inlinecrypt"
mount "$PARTITION" -o inlinecrypt "$MOUNT_POINT"

log_info "Generating 64-byte encryption key"
head -c 64 /dev/urandom > "$KEY_FILE"

log_info "Checking if dependency binary is available"
check_dependencies fscryptctl

log_info "Adding encryption key using fscryptctl"
identifier=$(fscryptctl add_key "$MOUNT_POINT" < "$KEY_FILE")

mkdir -p "$TEST_DIR"

log_info "Setting encryption policy on $TEST_DIR"
fscryptctl set_policy --iv-ino-lblk-64 "$identifier" "$TEST_DIR"

log_info "Verifying encryption policy"
fscryptctl get_policy "$TEST_DIR"

log_info "Writing test file"
echo "hello" > "$TEST_FILE"
sync
echo 3 > /proc/sys/vm/drop_caches

log_info "Reading test file"
if cat "$TEST_FILE" | grep -q "hello"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"

