#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Resolve the real path of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Set TOOLS path to utils under the script directory
TOOLS="$SCRIPT_DIR/utils"

# Safely source init_env from the same directory as this script
if [ -f "$SCRIPT_DIR/init_env" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/init_env"
else
    echo "[INFO] init_env not found at $SCRIPT_DIR/init_env — skipping."
fi

# Source functestlib.sh from utils/
if [ -f "$TOOLS/functestlib.sh" ]; then
    # shellcheck source=/dev/null
    . "$TOOLS/functestlib.sh"
    # Export key vars so they are visible to child scripts like ./run.sh
    export ROOT_DIR
    export TOOLS
    export __RUNNER_SUITES_DIR
    export __RUNNER_UTILS_BIN_DIR
else
    echo "[ERROR] functestlib.sh not found at $TOOLS/functestlib.sh"
    exit 1
fi

# Store results
RESULTS_PASS=""
RESULTS_FAIL=""

execute_test_case() {
    test_path=$1
    test_name=$(basename "$test_path")

    if [ -d "$test_path" ]; then
        run_script="$test_path/run.sh"
        if [ -f "$run_script" ]; then
            log "Executing test case: $test_name"
            if (cd "$test_path" && sh "./run.sh"); then
                log_pass "$test_name passed"
                if [ -z "$RESULTS_PASS" ]; then
                    RESULTS_PASS="$test_name"
                else
                    RESULTS_PASS=$(printf "%s\n%s" "$RESULTS_PASS" "$test_name")
                fi
            else
                log_fail "$test_name failed"
                if [ -z "$RESULTS_FAIL" ]; then
                    RESULTS_FAIL="$test_name"
                else
                    RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name")
                fi
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
    test_path=$(find_test_case_by_name "$test_name")
    if [ -z "$test_path" ]; then
        log_error "Test case with name $test_name not found."
        RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name (not found)")
    else
        execute_test_case "$test_path"
    fi
}

run_all_tests() {
    find "${__RUNNER_SUITES_DIR}" -maxdepth 3 -type d -name '[A-Za-z]*' | while IFS= read -r test_dir; do
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
    log_info "=================================="
}

if [ "$#" -eq 0 ]; then
    log "Usage: $0 [all | <testcase_name>]"
    exit 1
fi

if [ "$1" = "all" ]; then
    run_all_tests
else
    run_specific_test_by_name "$1"
fi

print_summary
