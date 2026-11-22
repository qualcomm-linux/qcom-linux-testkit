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

TESTNAME="File_Lock_Validation"
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

deps_list="cat grep sed awk flock sleep mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

lockfile="$KERNEL_EVIDENCE_DIR/file_lock_validation.lock"
ready="$KERNEL_EVIDENCE_DIR/file_lock_validation.ready"
release="$KERNEL_EVIDENCE_DIR/file_lock_validation.release"
holder=""
rm -f "$lockfile" "$ready" "$release"
touch "$lockfile"

cleanup_file_lock() {
    touch "$release"
    if [ -n "$holder" ]; then
        wait "$holder" 2>/dev/null || true
        holder=""
    fi
    rm -f "$lockfile" "$ready" "$release"
}
trap cleanup_file_lock EXIT INT TERM

# Hold the lock until this process publishes a release file.
(
    flock -x "$lockfile" || exit 1
    touch "$ready"
    while [ ! -f "$release" ]; do
        sleep 1
    done
) &
holder=$!

waited=0
while [ ! -f "$ready" ] && [ "$waited" -lt 5 ]; do
    if ! kill -0 "$holder" 2>/dev/null; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done

if [ ! -f "$ready" ]; then
    test_result_record "FAIL" "lock holder did not acquire the exclusive lock"
    test_result_finish "FAIL"
fi

if flock -n -x "$lockfile" true 2>/dev/null; then
    test_result_record "FAIL" "second exclusive flock succeeded while holder is alive"
    test_result_finish "FAIL"
fi
test_result_record "PASS" "exclusive flock contention is enforced"

touch "$release"
wait "$holder"
holder_rc=$?
holder=""
if [ "$holder_rc" -ne 0 ]; then
    test_result_record "FAIL" "lock holder exited $holder_rc"
    test_result_finish "FAIL"
fi

if flock -n -x "$lockfile" true 2>/dev/null; then
    test_result_record "PASS" "exclusive flock succeeds after holder release"
else
    test_result_record "FAIL" "flock still contended after holder release"
fi

if [ -r /proc/locks ]; then
    test_result_record "PASS" "/proc/locks remains readable after flock exercise"
fi

cleanup_file_lock
trap - EXIT INT TERM
test_result_finish
