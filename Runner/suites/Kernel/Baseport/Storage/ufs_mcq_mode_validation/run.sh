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

TESTNAME="ufs_mcq_mode_validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies cat readlink; then
    test_result_finish SKIP "Image lacks utilities required to inspect UFS MCQ mode"
fi

# Applicability: a bound UFS host must exist. Runtime driver binding decides
# this, not the filesystem type that happens to hold the root partition.
log_info "Looking for a block device beneath a bound UFS host"
block_dev=$(detect_ufs_partition_block)
if [ -z "$block_dev" ]; then
    test_result_finish SKIP "No block device with a bound UFS host found in sysfs"
fi

if ! ufs_host=$(storage_ufs_host_node "/sys/class/block/${block_dev##*/}"); then
    test_result_finish FAIL "Cannot resolve the UFS host controller for $block_dev"
fi
log_info "UFS block device: $block_dev, host controller: $ufs_host"

# Multi-Circular Queue is defined from UFS 4.0 onwards.
if ! ufs_spec=$(storage_ufs_spec_version "$ufs_host"); then
    test_result_finish FAIL "Cannot read a valid UFS specification_version under $ufs_host"
fi
log_info "UFS specification version: $ufs_spec"

ufs_spec_major=${ufs_spec%%.*}
if [ "$ufs_spec_major" -lt 4 ]; then
    test_result_finish SKIP "UFS MCQ requires UFS 4.0 or later, device reports $ufs_spec"
fi

# The parameter belongs to the UFS core module. Find it at runtime
mcq_node=""
for mcq_candidate in /sys/module/*/parameters/use_mcq_mode; do
    [ -r "$mcq_candidate" ] || continue
    mcq_module=${mcq_candidate#/sys/module/}
    mcq_module=${mcq_module%%/*}
    case "$mcq_module" in
        ufs*)
            mcq_node="$mcq_candidate"
            log_info "Found use_mcq_mode in UFS module '$mcq_module': $mcq_node"
            break
            ;;
    esac
done

if [ -z "$mcq_node" ]; then
    test_result_finish FAIL "UFS $ufs_spec host has no readable use_mcq_mode module parameter"
fi

if ! mcq_value=$(cat "$mcq_node"); then
    test_result_finish FAIL "Cannot read $mcq_node"
fi
log_info "$mcq_node = '$mcq_value'"

case "$mcq_value" in
    Y|y|1)
        test_result_record PASS "UFS MCQ mode is enabled on UFS $ufs_spec"
        ;;
    N|n|0)
        test_result_record FAIL "UFS MCQ mode is disabled on UFS $ufs_spec"
        ;;
    *)
        test_result_record FAIL "Unexpected use_mcq_mode value '$mcq_value'"
        ;;
esac

test_result_finish

