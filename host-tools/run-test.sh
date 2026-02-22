#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Resolve the real path of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Disable wrapper-level capture; each test will capture in its own folder
export RUN_STDOUT_ENABLE=0
unset RUN_STDOUT_TAG RUN_STDOUT_FILE

# Safely source init_env from the same directory as this script
# init_env will set TOOLS, ROOT_DIR, __RUNNER_SUITES_DIR, etc.
if [ -f "$SCRIPT_DIR/init_env" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/init_env"
else
    echo "[ERROR] init_env not found at $SCRIPT_DIR/init_env"
    exit 1
fi

# Verify that init_env set up the environment correctly
if [ -z "$TOOLS" ] || [ ! -f "$TOOLS/functestlib.sh" ]; then
    echo "[ERROR] functestlib.sh not found at $TOOLS/functestlib.sh"
    echo "[ERROR] init_env may not have set up the environment correctly"
    exit 1
fi

# Export key vars so they are visible to child scripts like ./run.sh
export ROOT_DIR
export TOOLS
export __RUNNER_SUITES_DIR
export __RUNNER_UTILS_BIN_DIR

# Reboot device to ensure adb functionality after Renesas firmware flash
log_info "Rebooting device to ensure adb functionality..."
sync
sleep 2
reboot -f
sleep 30

# Restart adb server
log_info "Restarting adb server..."
adb kill-server
sleep 2
adb start-server
sleep 2

# Wait for adb to detect the device (non-blocking, 30s timeout)
log_info "Waiting for device to be detected by adb (timeout: 30s)..."

if timeout 30s adb wait-for-device >/dev/null 2>&1; then
    log_info "Device detected by adb"
else
    log_warn "$TESTNAME SKIP: Device not detected by adb within timeout"
    echo "SKIP" > "$res_file"
    exit 0
fi

# Set host-tools specific suites directory
HOST_TOOLS_DIR="$SCRIPT_DIR"
export HOST_TOOLS_DIR

# Store results
RESULTS_PASS=""
RESULTS_FAIL=""
RESULTS_SKIP=""

execute_test_case() {
    test_path=$1
    shift

    test_name=$(basename "$test_path")

    if [ -d "$test_path" ]; then
        run_script="$test_path/run.sh"
        if [ -f "$run_script" ]; then
            log "Executing test case: $test_name"
            (
              cd "$test_path" || exit 2
              # Enable per-test capture in the test folder with a clear tag
              RUN_STDOUT_ENABLE=1 RUN_STDOUT_TAG="$test_name" sh "./run.sh" "$@"
            )
            res_file="$test_path/$test_name.res"
            if [ -f "$res_file" ]; then
                if grep -q "SKIP" "$res_file"; then
                    log_skip "$test_name skipped"
                    if [ -z "$RESULTS_SKIP" ]; then
                        RESULTS_SKIP="$test_name"
                    else
                        RESULTS_SKIP=$(printf "%s\n%s" "$RESULTS_SKIP" "$test_name")
                    fi
                elif grep -q "PASS" "$res_file"; then
                    log_pass "$test_name passed"
                    if [ -z "$RESULTS_PASS" ]; then
                        RESULTS_PASS="$test_name"
                    else
                        RESULTS_PASS=$(printf "%s\n%s" "$RESULTS_PASS" "$test_name")
                    fi
                elif grep -q "FAIL" "$res_file"; then
                    log_fail "$test_name failed"
                    if [ -z "$RESULTS_FAIL" ]; then
                        RESULTS_FAIL="$test_name"
                    else
                        RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name")
                    fi
                else
                    log_fail "$test_name: unknown result in .res file"
                    RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name (unknown result)")
                fi
            else
                log_fail "$test_name: .res file not found"
                RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name (.res not found)")
            fi
        else
            log_error "No run.sh found in $test_path"
            RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name (missing run.sh)")
        fi
    else
        log_error "Test case directory not found: $test_path"
        RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name (directory not found)")
    fi
}

run_specific_test_by_name() {
    test_name=$1
    shift
    test_path=$(find_test_case_by_name "$test_name")
    if [ -z "$test_path" ]; then
        log_error "Test case with name $test_name not found."
        RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name (not found)")
    else
        execute_test_case "$test_path" "$@"
    fi
}

run_all_tests() {
    # Search for tests in host-tools directory (not Runner/suites)
    find "${HOST_TOOLS_DIR}" -maxdepth 2 -type d -name '[A-Za-z]*' | while IFS= read -r test_dir; do
        # Skip the host-tools directory itself
        if [ "$test_dir" = "$HOST_TOOLS_DIR" ]; then
            continue
        fi
        if [ -f "$test_dir/run.sh" ]; then
            execute_test_case "$test_dir"
        fi
    done
}

print_summary() {
    echo
    log_info "========== Test Summary =========="
    echo "PASSED:"
    [ -n "$RESULTS_PASS" ] && printf "%s\n" "$RESULTS_PASS" || echo " None"
    echo
    echo "FAILED:"
    [ -n "$RESULTS_FAIL" ] && printf "%s\n" "$RESULTS_FAIL" || echo " None"
    echo
    echo "SKIPPED:"
    [ -n "$RESULTS_SKIP" ] && printf "%s\n" "$RESULTS_SKIP" || echo " None"
    log_info "=================================="
}

print_usage() {
    cat >&2 <<EOF
Usage:
  "${0##*/}" all
  "${0##*/}" <testcase_name> [arg1 arg2 ...]

Notes:
  - Extra args are forwarded only when a single <testcase_name> is specified.
  - 'all' runs every test and does not accept additional args.
  - Each test captures stdout/stderr next to its .res file as:
      <testname>_stdout_<timestamp>.log
EOF
}

if [ "$#" -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    print_usage
    if [ "$#" -eq 0 ]; then
        log_error "No arguments provided"
        exit 1
    else
        exit 0
    fi
fi

if [ "$1" = "all" ]; then
    run_all_tests
else
    test_case_name="$1"
    shift
    run_specific_test_by_name "$test_case_name" "$@"
fi

print_summary
