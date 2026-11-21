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
# shellcheck disable=SC1091
. "$TOOLS/lib_kernel.sh"

TESTNAME="Random_CRNG_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
# shellcheck disable=SC2034
CHECK_DEPS_RECOVER=0

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

# usage
# Print the supported options without changing hardware.
usage() {
    printf '%s\n' "Usage: $0 [--help]"
}

# parse_args <arguments...>
# Reject unsupported arguments before test setup.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *)
                test_result_finish FAIL "Unsupported option: $1"
                ;;
        esac
    done
}
parse_args "$@"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

deps_list="cat grep sed awk tr dd mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
if ! k_kernel_evidence_init "random:|crng"; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ -r /proc/sys/kernel/random/entropy_avail ]; then
    k_record_readable "entropy_avail" "/proc/sys/kernel/random/entropy_avail" 1
fi
if [ -r /proc/sys/kernel/random/poolsize ]; then
    k_record_readable "poolsize" "/proc/sys/kernel/random/poolsize" 1
fi
if [ -r /proc/sys/kernel/random/uuid ]; then
    uuid="$(k_sysfs_read /proc/sys/kernel/random/uuid)"
    case "$uuid" in
        *-*-*-*-*)
            test_result_record "PASS" "kernel uuid looks well-formed: $uuid"
            ;;
        *)
            test_result_record "FAIL" "kernel uuid unexpected: '$uuid'"
            ;;
    esac
fi

if [ -r /dev/urandom ]; then
    if dd if=/dev/urandom of=/dev/null bs=64 count=1 2>/dev/null; then
        test_result_record "PASS" "/dev/urandom produced 64 bytes"
    else
        test_result_record "FAIL" "/dev/urandom read failed"
    fi
else
    test_result_record "FAIL" "/dev/urandom is not readable"
fi

if k_dmesg_snapshot_match "crng init done|random: crng init"; then
    test_result_record "PASS" "kernel log reports CRNG initialization"
else
    test_result_record "SKIP" "no CRNG init message found (may have been rotated)"
fi

test_result_finish
