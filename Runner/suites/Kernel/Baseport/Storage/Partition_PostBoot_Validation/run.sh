#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Post-boot partition validation:
# - logs current mount inventory
# - logs block device inventory
# - validates expected mountpoints from the mount matrix
# - triggers autofs mounts where needed
# - performs RW probe only where required
# - does not gate on systemd or unrelated service health

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"
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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Partition_PostBoot_Validation"
MOUNT_MATRIX="${MOUNT_MATRIX:-/:ext4,erofs,squashfs:0:0;/efi:autofs,vfat:0:1;/var/lib/tee:ext4:1:0}"

test_path="$(find_test_case_by_name "$TESTNAME")"
if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies findmnt mount awk grep sed lsblk blkid; then
    log_skip "$TESTNAME SKIP: missing dependencies"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Mount matrix, $MOUNT_MATRIX"

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform
fi

log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='$(uname -r 2>/dev/null || echo unknown)' arch='$(uname -m 2>/dev/null || echo unknown)'"

partition_log_current_mounts
partition_log_block_devices

log_info "----- Partition mount validation -----"
if partition_validate_mount_matrix "$MOUNT_MATRIX"; then
    log_info "----- End partition mount validation -----"
    log_pass "$TESTNAME : PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
fi
log_info "----- End partition mount validation -----"

log_fail "$TESTNAME : FAIL"
echo "$TESTNAME FAIL" > "$RES_FILE"
exit 0
