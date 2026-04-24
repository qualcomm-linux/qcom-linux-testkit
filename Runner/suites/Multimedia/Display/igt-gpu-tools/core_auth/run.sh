#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Source init_env & tools ----
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then INIT_ENV="$SEARCH/init_env"; break; fi
  SEARCH="$(dirname "$SEARCH")"
done
if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source if not already loaded (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_display.sh"

TESTNAME="core_auth"
result_file="./${TESTNAME}.res"
CORE_AUTH_CMD=""

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null)"
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    test_path="$SCRIPT_DIR"
fi

if [ ! -w "$test_path" ]; then
    log_error "Cannot write to test directory: $test_path"
    echo "$TESTNAME FAIL" >"$result_file"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --core-auth-path)
            shift
            if [ -n "${1:-}" ]; then
                CORE_AUTH_CMD="$1"
            else
                log_error "Missing value for --core-auth-path parameter"
                echo "$TESTNAME FAIL" >"$result_file"
                exit 1
            fi
            ;;
        --help|-h)
            log_info "Usage: $0 [--core-auth-path BINARY_PATH] | [BINARY_PATH]"
            exit 0
            ;;
        -*)
            log_warn "Unknown argument: $1"
            ;;
        *)
            if [ -z "$CORE_AUTH_CMD" ]; then
                CORE_AUTH_CMD="$1"
            else
                log_warn "Multiple paths specified, ignoring: $1"
            fi
            ;;
    esac
    shift
done

if ! cd "$test_path"; then
    log_error "cd failed: $test_path"
    echo "$TESTNAME FAIL" >"$result_file"
    exit 1
fi

log_info "-------------------Starting $TESTNAME Testcase-----------------------------"

if [ -z "$CORE_AUTH_CMD" ]; then
    log_error "core_auth binary not specified"
    echo "$TESTNAME FAIL" > "$result_file"
    exit 1
fi

if [ ! -x "$CORE_AUTH_CMD" ]; then
    log_error "FAIL: core_auth binary not found or not executable at: $CORE_AUTH_CMD"
    echo "$TESTNAME FAIL" > "$result_file"
    exit 1
fi

log_info "Using core_auth binary at: $CORE_AUTH_CMD"

weston_stopped_by_test=0
if command -v weston_is_running >/dev/null 2>&1; then
    if weston_is_running; then
        log_info "Weston is running, stopping it before $TESTNAME"
        if ! weston_stop; then
            log_error "Failed to stop Weston"
            echo "$TESTNAME FAIL" > "$result_file"
            exit 1
        fi
        weston_stopped_by_test=1
    else
        log_info "Weston is not running, no need to stop it"
    fi
else
    log_info "weston_is_running helper not found, attempting to continue"
fi

log_file="$test_path/core_auth_log.txt"
"$CORE_AUTH_CMD" > "$log_file" 2>&1
RC="$?"

log_info "Logs written to: $log_file"

success_count=$(grep -c "SUCCESS" "$log_file" 2>/dev/null || echo "0")
fail_count=$(grep -c "FAIL" "$log_file" 2>/dev/null || echo "0")
skip_count=$(grep -c "SKIP" "$log_file" 2>/dev/null || echo "0")

# Ensure we have valid numbers
success_count=${success_count:-0}
fail_count=${fail_count:-0}
skip_count=${skip_count:-0}

case "$success_count" in ''|*[!0-9]*) success_count=0 ;; esac
case "$fail_count" in ''|*[!0-9]*) fail_count=0 ;; esac
case "$skip_count" in ''|*[!0-9]*) skip_count=0 ;; esac

total_subtests=$((success_count + fail_count + skip_count))

log_info "Subtest Results: SUCCESS=$success_count, FAIL=$fail_count, SKIP=$skip_count, TOTAL=$total_subtests"
log_info "results will be written to \"$result_file\""

final_result="PASS"
final_exit=0
final_message=""

if [ "$RC" -eq 77 ]; then
    final_result="SKIP"
    final_exit=0
    final_message="$TESTNAME : Test Skipped (exit code: 77)"
elif [ "$RC" -ne 0 ]; then
    final_result="FAIL"
    final_exit=1
    final_message="$TESTNAME : Test Failed (exit code: $RC)"
elif [ "$fail_count" -gt 0 ]; then
    final_result="FAIL"
    final_exit=1
    final_message="$TESTNAME : Test Failed - $fail_count subtest(s) failed out of $total_subtests"
elif [ "$skip_count" -gt 0 ] && [ "$success_count" -eq 0 ]; then
    final_result="SKIP"
    final_exit=0
    final_message="$TESTNAME : Test Skipped - All $skip_count subtest(s) were skipped"
else
    if [ "$success_count" -gt 0 ]; then
        if [ "$skip_count" -gt 0 ]; then
            final_message="$TESTNAME : Test Passed - $success_count subtest(s) succeeded, $skip_count skipped"
        else
            final_message="$TESTNAME : Test Passed - All $success_count subtest(s) succeeded"
        fi
    else
        final_message="$TESTNAME : Test Passed (return code $RC)"
    fi
fi

if [ "$weston_stopped_by_test" -eq 1 ]; then
    log_info "Restoring Weston after $TESTNAME"
    if ! weston_restore_runtime 15; then
        log_error "Failed to restore Weston after $TESTNAME"
        final_result="FAIL"
        final_exit=1
        final_message="$TESTNAME : Test Failed - Weston restore failed after test execution"
    fi
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"

case "$final_result" in
    PASS)
        log_pass "$final_message"
        ;;
    SKIP)
        log_skip "$final_message"
        ;;
    *)
        log_fail "$final_message"
        ;;
esac

echo "$TESTNAME $final_result" > "$result_file"
exit "$final_exit"
