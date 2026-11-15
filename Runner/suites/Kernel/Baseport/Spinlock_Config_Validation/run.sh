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
if ! k_kernel_evidence_init "."; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if k_config_enabled CONFIG_SMP; then
    test_result_record "PASS" "CONFIG_SMP is enabled"
else
    online_count="$(get_online_cpus | k_count_lines)"
    if [ "$online_count" -gt 1 ]; then
        test_result_record "FAIL" "multiple CPUs online but CONFIG_SMP is not enabled"
    else
        test_result_record "SKIP" "CONFIG_SMP not visible; uniprocessor image"
    fi
fi

for cfg in CONFIG_DEBUG_SPINLOCK CONFIG_DEBUG_LOCK_ALLOC CONFIG_PROVE_LOCKING CONFIG_LOCKDEP CONFIG_LOCK_STAT; do
    state="$(k_config_state "$cfg" || true)"
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

if k_config_enabled CONFIG_GENERIC_LOCKBREAK || k_config_enabled CONFIG_INLINE_SPIN_LOCK; then
    test_result_record "PASS" "generic/inline spinlock implementation is configured"
else
    test_result_record "SKIP" "spinlock implementation configs not exported"
fi

if [ -r /proc/locks ]; then
    test_result_record "PASS" "/proc/locks is readable"
else
    test_result_record "FAIL" "/proc/locks is not readable"
fi

test_result_finish
