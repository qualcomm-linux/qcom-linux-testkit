#!/bin/sh
 
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
 
# Locate and source init_env
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
 
# shellcheck disable=SC1090
. "$INIT_ENV"
 
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
 
TESTNAME="shmbridge"
test_path=$(find_test_case_by_name "$TESTNAME") || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}
 
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"
 
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
 
check_dependencies fscryptctl mkfs.ext4 mount dd grep cat
 
MOUNT_POINT="/mnt/overlay"
PARTITION="/dev/disk/by-partlabel/xbl_ramdump_a"
KEY_FILE="$MOUNT_POINT/stdkey"
TEST_DIR="$MOUNT_POINT/test"
TEST_FILE="$TEST_DIR/txt"
 
log_info "Creating mount point at $MOUNT_POINT"
mkdir -p "$MOUNT_POINT"
 
if [ ! -e "$PARTITION" ]; then
    log_fail "Partition $PARTITION not found"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
 
if ! mount | grep -q "$PARTITION"; then
    log_info "Formatting $PARTITION with ext4 (encrypt, stable_inodes)"
    mkfs.ext4 -F -O encrypt,stable_inodes "$PARTITION"
else
    log_warn "$PARTITION already mounted, skipping format"
fi
 
log_info "Mounting $PARTITION to $MOUNT_POINT with inlinecrypt"
if ! mount "$PARTITION" -o inlinecrypt "$MOUNT_POINT"; then
    log_fail "Failed to mount $PARTITION"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
 
log_info "Generating 64-byte encryption key"
dd if=/dev/urandom bs=1 count=64 of="$KEY_FILE" status=none
 
log_info "Adding encryption key with fscryptctl"
identifier=$(fscryptctl add_key "$MOUNT_POINT" < "$KEY_FILE") || {
    log_fail "Failed to add key to $MOUNT_POINT"
    echo "$TESTNAME FAIL" > "$res_file"
    umount "$MOUNT_POINT"
    exit 1
}
 
mkdir -p "$TEST_DIR"
log_info "Applying encryption policy to $TEST_DIR"
fscryptctl set_policy --iv-ino-lblk-64 "$identifier" "$TEST_DIR" || {
    log_fail "Failed to set policy on $TEST_DIR"
    echo "$TESTNAME FAIL" > "$res_file"
    umount "$MOUNT_POINT"
    exit 1
}
 
log_info "Verifying encryption policy"
fscryptctl get_policy "$TEST_DIR"
 
log_info "Writing and reading test file"
echo "hello" > "$TEST_FILE"
sync
echo 3 > /proc/sys/vm/drop_caches
 
if grep -q "hello" "$TEST_FILE"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed to verify data"
    echo "$TESTNAME FAIL" > "$res_file"
    umount "$MOUNT_POINT"
    exit 1
fi
 
umount "$MOUNT_POINT"
log_info "Unmounted $MOUNT_POINT and cleaned up."
 
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0

