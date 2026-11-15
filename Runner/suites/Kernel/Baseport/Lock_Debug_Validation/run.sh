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

TESTNAME="Lock_Debug_Validation"
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

deps_list="cat grep sed awk tr mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
if ! k_kernel_evidence_init "."; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ -r /proc/locks ]; then
    test_result_record "PASS" "/proc/locks is readable"
    lock_lines="$(k_count_lines < /proc/locks)"
    log_info "/proc/locks entries=$lock_lines"
else
    test_result_record "FAIL" "/proc/locks is not readable"
fi

if [ -r /proc/lock_stat ]; then
    if grep -q "lock_stat version" /proc/lock_stat; then
        test_result_record "PASS" "/proc/lock_stat header is present"
    else
        test_result_record "FAIL" "/proc/lock_stat is readable but has no version header"
    fi
else
    test_result_record "SKIP" "/proc/lock_stat not present (CONFIG_LOCK_STAT off)"
fi

if [ -r /proc/lockdep ]; then
    test_result_record "PASS" "/proc/lockdep is readable"
elif [ -r /proc/lockdep_chains ]; then
    test_result_record "PASS" "/proc/lockdep_chains is readable"
else
    test_result_record "SKIP" "lockdep proc files not present (CONFIG_LOCKDEP off)"
fi

if [ -r /proc/lockdep_stats ]; then
    k_record_readable "lockdep_stats" "/proc/lockdep_stats"
fi

test_result_finish
