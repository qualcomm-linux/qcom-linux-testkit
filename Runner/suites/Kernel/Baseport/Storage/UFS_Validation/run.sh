#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# ---------- Repo env + helpers ----------
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

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="UFS_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! check_dependencies dd readlink awk mktemp wc; then
    test_result_finish SKIP "Image lacks utilities required for safe UFS I/O"
fi
RESULT_DIR=$(mktemp -d "$PWD/ufs-validation.XXXXXX") || test_result_finish FAIL "Cannot create UFS evidence directory in CWD"
trap 'managed_timeout_cancel_bounded 2; rm -f "$RESULT_DIR/ufs_test.img"' 0
trap 'test_result_finish FAIL "UFS validation interrupted"' HUP INT TERM
block_dev=$(detect_ufs_partition_block)
if [ -z "$block_dev" ]; then
    scan_dmesg_errors "$RESULT_DIR" 'ufs|ufshcd' 'deferred probe|EPROBE_DEFER' || true
    if [ -s "$RESULT_DIR/dmesg_errors.log" ]; then
        test_result_finish FAIL "No UFS block device registered and UFS kernel errors were captured in $RESULT_DIR"
    fi
    test_result_finish SKIP "No block device with a bound UFS host found in sysfs"
fi
ufs_sectors=$(cat "/sys/class/block/${block_dev##*/}/size")
case "$ufs_sectors" in
    ''|*[!0-9]*|0)
        test_result_finish FAIL "UFS block $block_dev has no valid nonzero sector count"
        ;;
esac
ufs_read_count=65536
if [ "$ufs_sectors" -lt "$ufs_read_count" ]; then
    ufs_read_count="$ufs_sectors"
fi
LC_ALL=C
export LC_ALL
log_info "Runtime UFS block: $block_dev, evidence: $RESULT_DIR"
# Raw device access is read-only, including when UFS contains the root filesystem.
if run_with_managed_timeout 60 "$RESULT_DIR" ufs-read \
    dd if="$block_dev" of=/dev/null bs=512 count="$ufs_read_count" >"$RESULT_DIR/read.log" 2>&1 &&
   [ "$(awk '$2 == "records" && $3 == "in" {print $1; exit}' "$RESULT_DIR/read.log")" = "$ufs_read_count+0" ]; then
    test_result_record PASS "Read-only UFS block I/O completed on $block_dev"
else
    test_result_record FAIL "UFS block read failed or timed out on $block_dev"
fi
cat "$RESULT_DIR/read.log"
if storage_path_is_ufs "$RESULT_DIR"; then
    # No raw writes. A unique file is used only on a verified UFS filesystem.
    if run_with_managed_timeout 60 "$RESULT_DIR" ufs-write \
        dd if=/dev/zero of="$RESULT_DIR/ufs_test.img" bs=1048576 count=64 conv=fsync \
        >"$RESULT_DIR/write.log" 2>&1 &&
       [ "$(wc -c <"$RESULT_DIR/ufs_test.img")" -eq 67108864 ] &&
       run_with_managed_timeout 60 "$RESULT_DIR" ufs-file-read \
        dd if="$RESULT_DIR/ufs_test.img" of=/dev/null bs=1048576 count=64 \
        >"$RESULT_DIR/file-read.log" 2>&1 &&
       [ "$(awk '$2 == "records" && $3 == "in" {print $1; exit}' "$RESULT_DIR/file-read.log")" = '64+0' ]; then
        test_result_record PASS "64 MiB file write and read completed on verified UFS backing"
    else
        test_result_record FAIL "UFS file I/O failed or timed out, see $RESULT_DIR/write.log"
    fi
    cat "$RESULT_DIR/write.log"
    if [ -f "$RESULT_DIR/file-read.log" ]; then
        cat "$RESULT_DIR/file-read.log"
    fi
else
    test_result_record SKIP "File write check requires CWD on a directly verified UFS filesystem, current backing is not proven UFS"
fi
scan_dmesg_errors "$RESULT_DIR" 'ufs|ufshcd' 'deferred probe|EPROBE_DEFER' || true
if [ -s "$RESULT_DIR/dmesg_errors.log" ]; then
    test_result_record FAIL "UFS kernel errors captured in $RESULT_DIR/dmesg_errors.log"
fi
test_result_finish
