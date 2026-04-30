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
    exit 0
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

TESTNAME="ufs_read_writes"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 0
res_file="./$TESTNAME.res"

log_info "--------------------------------------------------"
log_info "------------- Starting $TESTNAME Test ------------"

check_dependencies dd awk readlink sed

# Run common UFS prechecks
if ! ufs_precheck_common; then
    log_skip "Required UFS configurations are not available"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "UFS prechecks successful"

block_dev="$UFS_BLOCK_DEV"
if [ -z "$block_dev" ]; then
    log_skip "No UFS block device found."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Detected UFS block: $block_dev"

if command -v findmnt >/dev/null 2>&1; then
    rootfs_dev=$(findmnt -n -o SOURCE /)
else
    log_warn "findmnt not available, using fallback rootfs detection"
    rootfs_dev=$(awk '$2 == "/" { print $1 }' /proc/mounts)
fi

resolved_block=$(readlink -f "$block_dev" 2>/dev/null)
resolved_rootfs=$(readlink -f "$rootfs_dev" 2>/dev/null)

if [ -n "$resolved_block" ] && [ -n "$resolved_rootfs" ] && [ "$resolved_block" = "$resolved_rootfs" ]; then
    log_warn "Detected block ($resolved_block) is the root filesystem. Skipping read test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Running basic read test on $block_dev (non-rootfs)..."
if echo | dd of=/dev/null iflag=direct 2>/dev/null; then
    DD_CMD="dd if=$block_dev of=/dev/null bs=1M count=32 iflag=direct"
else
    log_warn "'iflag=direct' not supported by dd. Falling back to standard dd."
    DD_CMD="dd if=$block_dev of=/dev/null bs=1M count=32"
fi

if $DD_CMD >/dev/null 2>&1; then
    log_pass "UFS read test succeeded"
else
    log_fail "UFS read test failed"
    log_info "Try manually: $DD_CMD"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

log_info "Running I/O stress test (64MB read+write on tmpfile)..."
tmpfile="$test_path/${TESTNAME}.tmp"

if echo | dd of=/dev/null conv=fsync 2>/dev/null; then
    DD_WRITE="dd if=/dev/zero of=$tmpfile bs=1M count=64 conv=fsync"
else
    log_warn "'conv=fsync' not supported by dd. Using basic write."
    DD_WRITE="dd if=/dev/zero of=$tmpfile bs=1M count=64"
fi

if $DD_WRITE >/dev/null 2>&1 &&
   dd if="$tmpfile" of=/dev/null bs=1M count=64 >/dev/null 2>&1; then
    log_pass "UFS I/O stress test passed"
    if command -v stat >/dev/null 2>&1; then
        stat --format="[INFO] Size: %s bytes File: %n" "$tmpfile"
    elif command -v wc >/dev/null 2>&1; then
        size=$(wc -c < "$tmpfile")
        echo "[INFO] Size: $size bytes File: $tmpfile"
    else
        # shellcheck disable=SC2012
        ls -l "$tmpfile" | awk '{print "[INFO] Size: " $5 " bytes File: " $9}'
    fi
    rm -f "$tmpfile"
else
    log_fail "UFS I/O stress test failed"
    df -h . | sed 's/^/[INFO] /'
    if [ -f "$tmpfile" ]; then
        if command -v stat >/dev/null 2>&1; then
            stat --format="[INFO] Size: %s bytes File: %n" "$tmpfile"
        elif command -v wc >/dev/null 2>&1; then
            size=$(wc -c < "$tmpfile")
            echo "[INFO] Size: $size bytes File: $tmpfile"
        else
            # shellcheck disable=SC2012
            ls -l "$tmpfile" | awk '{print "[INFO] Size: " $5 " bytes File: " $9}'
        fi
        rm -f "$tmpfile"
    fi
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

scan_dmesg_errors "$test_path" "ufs"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0
