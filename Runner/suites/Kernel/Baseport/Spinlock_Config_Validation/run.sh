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

TESTNAME="Spinlock_Config_Validation"
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
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

smp_state="$(kernel_config_state CONFIG_SMP)" || smp_state=""
case "$smp_state" in
    y|m)
        test_result_record "PASS" "CONFIG_SMP is enabled"
        ;;
    n)
        online_count="$(get_online_cpus | kernel_count_lines)"
        if [ "$online_count" -gt 1 ]; then
            test_result_record "FAIL" "multiple CPUs online but CONFIG_SMP is not enabled"
        else
            test_result_record "SKIP" "CONFIG_SMP is disabled on a uniprocessor image"
        fi
        ;;
    *)
        test_result_record "SKIP" "CONFIG_SMP state is unavailable"
        ;;
esac

for cfg in CONFIG_DEBUG_SPINLOCK CONFIG_DEBUG_LOCK_ALLOC CONFIG_PROVE_LOCKING CONFIG_LOCKDEP CONFIG_LOCK_STAT; do
    state="$(kernel_config_state "$cfg" || true)"
    case "$state" in
        y|m)
            test_result_record "PASS" "$cfg=$state (debug, optional)"
            ;;
        n)
            test_result_record "SKIP" "$cfg is disabled (expected on production images)"
            ;;
        *)
            test_result_record "SKIP" "$cfg not present in kernel config"
            ;;
    esac
done

if kernel_config_is_enabled CONFIG_GENERIC_LOCKBREAK || kernel_config_is_enabled CONFIG_INLINE_SPIN_LOCK; then
    test_result_record "PASS" "generic/inline spinlock implementation is configured"
else
    test_result_record "SKIP" "spinlock implementation configs not exported"
fi

file_lock_state="$(kernel_config_state CONFIG_FILE_LOCKING)" || file_lock_state=""
case "$file_lock_state" in
    n)
        test_result_record "SKIP" "CONFIG_FILE_LOCKING is disabled; /proc/locks is not a spinlock check"
        ;;
    y|m)
        if [ -r /proc/locks ]; then
            test_result_record "PASS" "/proc/locks is readable"
        else
            test_result_record "FAIL" "CONFIG_FILE_LOCKING is enabled but /proc/locks is not readable"
        fi
        ;;
    *)
        if [ -r /proc/locks ]; then
            test_result_record "PASS" "/proc/locks is readable"
        else
            test_result_record "SKIP" "CONFIG_FILE_LOCKING state is unavailable and /proc/locks is absent"
        fi
        ;;
esac

test_result_finish
