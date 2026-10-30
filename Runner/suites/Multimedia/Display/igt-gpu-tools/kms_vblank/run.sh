#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# Source display helpers: Weston/Wayland lifecycle, DRM utilities, weston_restore_runtime
. "$TOOLS/lib_display.sh"

# EXIT trap: safety-net cleanup when the script exits normally (PIDs already cleared).
# Signal traps: kill the IGT child, restore Weston, then record an interrupted FAIL.
weston_stopped_by_test=0
trap 'if [ "$weston_stopped_by_test" -eq 1 ]; then if managed_timeout_cancel_bounded 5; then log_info "Restarting Weston after test completion"; weston_restore_runtime || true; else log_warn "IGT child may still hold DRM ownership; skipping Weston restore to avoid conflict"; fi; weston_stopped_by_test=0; else managed_timeout_cancel_bounded 5 || true; fi' EXIT
trap 'if [ "$weston_stopped_by_test" -eq 1 ]; then if managed_timeout_cancel_bounded 5; then log_info "Restarting Weston after signal interruption"; weston_restore_runtime || true; else log_warn "IGT child may still hold DRM ownership; skipping Weston restore to avoid conflict"; fi; weston_stopped_by_test=0; else managed_timeout_cancel_bounded 5 || true; fi; test_result_finish "FAIL" "test interrupted by signal"' INT TERM HUP

TESTNAME="kms_vblank"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
test_result_init "$TESTNAME" "$RES_FILE"
# Default IGT test binary location
DEFAULT_IGT_PATH="/usr/libexec/igt-gpu-tools"
KMS_VBLANK_CMD="$DEFAULT_IGT_PATH/$TESTNAME"
# Default pattern to exclude problematic subtests
DEFAULT_PATTERN="*,!*suspend*,!*rpm*"
RUN_SUBTEST="$DEFAULT_PATTERN"
# Configurable timeout in seconds for the IGT invocation
IGT_TIMEOUT="${IGT_TIMEOUT:-300}"

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null)"
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    test_path="$SCRIPT_DIR"
fi

if [ ! -w "$test_path" ]; then
    log_error "Cannot write to test directory: $test_path"
    test_result_finish "FAIL" "Cannot write to test directory: $test_path"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --kms-vblank-path)
            shift
            if [ -n "${1:-}" ]; then
                KMS_VBLANK_CMD="$1"
            else
                log_error "Missing value for --kms-vblank-path parameter"
                test_result_finish "FAIL" "Missing value for --kms-vblank-path parameter"
            fi
            ;;
        --run-subtest)
            shift
            if [ -n "${1:-}" ]; then
                RUN_SUBTEST="$1"
            else
                log_error "Missing value for --run-subtest parameter"
                test_result_finish "FAIL" "Missing value for --run-subtest parameter"
            fi
            ;;
        --help|-h)
            log_info "Usage: $0 [--kms-vblank-path BINARY_PATH] [--run-subtest PATTERN]"
            log_info "Default binary path: $DEFAULT_IGT_PATH/$TESTNAME"
            log_info "Default subtest filter: $DEFAULT_PATTERN"
            exit 0
            ;;
        -*)
            log_warn "Unknown argument: $1"
            ;;
        *)
            KMS_VBLANK_CMD="$1"
            ;;
    esac
    shift
done

if ! cd "$test_path"; then
    log_error "cd failed: $test_path"
    test_result_finish "FAIL" "cd failed: $test_path"
fi

log_info "-------------------Starting $TESTNAME Testcase-----------------------------"

# Check if the binary exists and is executable
if [ ! -x "$KMS_VBLANK_CMD" ]; then
    log_skip "$TESTNAME: kms_vblank binary not found or not executable at: $KMS_VBLANK_CMD"
    log_skip "Please ensure IGT GPU tools are installed or specify the binary path with --kms-vblank-path"
    test_result_finish "SKIP" "kms_vblank binary not found or not executable"
fi

log_info "Using kms_vblank binary at: $KMS_VBLANK_CMD"

# Validate IGT_TIMEOUT is a positive integer before stopping Weston
case "$IGT_TIMEOUT" in
    ''|*[!0-9]*|0)
        log_error "IGT_TIMEOUT must be a positive integer, got: '${IGT_TIMEOUT}'"
        test_result_finish "FAIL" "invalid IGT_TIMEOUT: ${IGT_TIMEOUT}"
        ;;
esac

if weston_is_running; then
    if ! weston_stop; then
        log_error "Failed to stop Weston"
        test_result_finish "FAIL" "Failed to stop Weston before test"
    fi
    weston_stopped_by_test=1
fi

log_file="$test_path/${TESTNAME}_log.txt"
log_info "Running with subtest pattern: $RUN_SUBTEST (timeout: ${IGT_TIMEOUT}s)"
run_with_managed_timeout "$IGT_TIMEOUT" "$test_path" "$TESTNAME" "$KMS_VBLANK_CMD" --run-subtest "$RUN_SUBTEST" > "$log_file" 2>&1
RC=$?

log_info "Logs written to: $log_file"

success_count=$(grep -c "SUCCESS" "$log_file" 2>/dev/null || echo "0")
fail_count=$(grep -c "FAIL" "$log_file" 2>/dev/null || echo "0")
skip_count=$(grep -c "SKIP" "$log_file" 2>/dev/null || echo "0")

success_count=${success_count:-0}
fail_count=${fail_count:-0}
skip_count=${skip_count:-0}

case "$success_count" in ''|*[!0-9]*) success_count=0 ;; esac
case "$fail_count" in ''|*[!0-9]*) fail_count=0 ;; esac
case "$skip_count" in ''|*[!0-9]*) skip_count=0 ;; esac

total_subtests=$((success_count + fail_count + skip_count))

# Restore Weston before writing the final result; report FAIL if recovery fails
if [ "$weston_stopped_by_test" -eq 1 ]; then
    log_info "Restarting Weston after test completion"
    if ! weston_restore_runtime; then
        log_fail "$TESTNAME: Weston failed to restart after test"
        test_result_finish "FAIL" "Weston failed to restart after test"
    fi
    weston_stopped_by_test=0
fi

log_info "Subtest Results: SUCCESS=$success_count, FAIL=$fail_count, SKIP=$skip_count, TOTAL=$total_subtests"
log_info "results will be written to \"$RES_FILE\""
log_info "-------------------Completed $TESTNAME Testcase----------------------------"

if [ "$RC" -eq 143 ] || [ "$RC" -eq 124 ]; then
    log_fail "$TESTNAME : Test Failed (timeout after ${IGT_TIMEOUT}s)"
    test_result_finish "FAIL" "timeout after ${IGT_TIMEOUT}s"
elif [ "$RC" -eq 77 ]; then
    log_skip "$TESTNAME : Test Skipped (IGT exit code 77)"
    test_result_finish "SKIP" "IGT exit code 77"
elif [ "$RC" -ne 0 ]; then
    log_fail "$TESTNAME : Test Failed (exit code: $RC)"
    test_result_finish "FAIL" "exit code: $RC"
elif [ "$fail_count" -gt 0 ]; then
    log_fail "$TESTNAME : Test Failed - $fail_count subtest(s) failed out of $total_subtests"
    test_result_finish "FAIL" "$fail_count subtest(s) failed out of $total_subtests"
elif [ "$skip_count" -gt 0 ] && [ "$success_count" -eq 0 ]; then
    log_skip "$TESTNAME : Test Skipped - All $skip_count subtest(s) were skipped"
    test_result_finish "SKIP" "all $skip_count subtest(s) were skipped"
else
    if [ "$success_count" -gt 0 ]; then
        if [ "$skip_count" -gt 0 ]; then
            log_pass "$TESTNAME : Test Passed - $success_count subtest(s) succeeded, $skip_count skipped"
            test_result_finish "PASS" "$success_count subtest(s) succeeded, $skip_count skipped"
        else
            log_pass "$TESTNAME : Test Passed - All $success_count subtest(s) succeeded"
            test_result_finish "PASS" "all $success_count subtest(s) succeeded"
        fi
    else
        log_pass "$TESTNAME : Test Passed (return code $RC)"
        test_result_finish "PASS" "return code $RC"
    fi
fi
