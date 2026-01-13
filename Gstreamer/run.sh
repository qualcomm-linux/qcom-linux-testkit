#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#==============================================================================
# GStreamer Master Test Runner - Runs all GStreamer test suites
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"

# Locate init_env dynamically
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH="$(dirname "$SEARCH")"
done

if [ -z "$INIT_ENV" ]; then
    echo "ERROR: Cannot find init_env"
    exit 1
fi

# Source init_env (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Source functestlib.sh
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

#==============================================================================
# Test Configuration
#==============================================================================

TESTNAME="Gstreamer"
test_path=$(find_test_case_by_name "$TESTNAME")
res_file="$test_path/$TESTNAME.res"
log_dir="$test_path/logs_$TESTNAME"

# Test suites to run
ALL_SUITES="Video Audio Display Camera"

#==============================================================================
# Helper Functions
#==============================================================================

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

GStreamer Master Test Runner - Runs all GStreamer test suites

OPTIONS:
    --all                   Run all test suites (default)
    --suite <name>          Run specific suite (Video, Audio, Display, Camera)
    --list                  List available test suites
    --help                  Show this help

EXAMPLES:
    $0                      # Run all suites
    $0 --all                # Run all suites
    $0 --suite Video        # Run only Video tests
    $0 --suite Camera       # Run only Camera tests

EOF
}

list_suites() {
    echo "Available GStreamer Test Suites:"
    for suite in $ALL_SUITES; do
        echo "  - $suite"
    done
}

run_test_suite() {
    local suite_name="$1"
    local suite_dir="$test_path/$suite_name"
    local suite_script="$suite_dir/run.sh"
    
    log_info "=== Running $suite_name Test Suite ==="
    
    if [ ! -d "$suite_dir" ]; then
        log_error "$suite_name: Suite directory not found: $suite_dir"
        return 1
    fi
    
    if [ ! -f "$suite_script" ]; then
        log_error "$suite_name: run.sh not found in $suite_dir"
        return 1
    fi
    
    if [ ! -x "$suite_script" ]; then
        log_warn "$suite_name: Making run.sh executable"
        chmod +x "$suite_script"
    fi
    
    # Run the suite
    cd "$suite_dir" || return 1
    if ./run.sh; then
        log_pass "$suite_name: Suite completed"
        cd "$test_path" || return 1
        return 0
    else
        log_error "$suite_name: Suite failed or had errors"
        cd "$test_path" || return 1
        return 1
    fi
}

#==============================================================================
# Main Execution
#==============================================================================

main() {
    local run_all=true
    local specific_suite=""
    local suites_to_run=""
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --all)
                run_all=true
                shift
                ;;
            --suite)
                specific_suite="$2"
                run_all=false
                shift 2
                ;;
            --list)
                list_suites
                exit 0
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Determine suites to run
    if [ "$run_all" = "true" ]; then
        suites_to_run="$ALL_SUITES"
    elif [ -n "$specific_suite" ]; then
        suites_to_run="$specific_suite"
    else
        suites_to_run="$ALL_SUITES"
    fi
    
    # Setup
    mkdir -p "$log_dir"
    log_info "Starting GStreamer Master Test Runner"
    log_info "Test path: $test_path"
    log_info "Log directory: $log_dir"
    
    # Run test suites
    local total_suites=0
    local passed_suites=0
    local failed_suites=0
    local suite_results=""
    
    for suite in $suites_to_run; do
        total_suites=$((total_suites + 1))
        
        if run_test_suite "$suite"; then
            passed_suites=$((passed_suites + 1))
            suite_results="$suite_results\n  ✓ $suite: PASSED"
        else
            failed_suites=$((failed_suites + 1))
            suite_results="$suite_results\n  ✗ $suite: FAILED"
        fi
    done
    
    # Generate summary
    {
        echo "=== GStreamer Master Test Summary ==="
        echo "Total Suites: $total_suites"
        echo "Passed: $passed_suites"
        echo "Failed: $failed_suites"
        echo ""
        echo "Suite Results:"
        echo "$suite_results" | sed 's/\\n/\n/g'
        echo ""
        echo "Individual suite results:"
        for suite in $suites_to_run; do
            suite_res_file="$test_path/$suite/Gstreamer_${suite}_Tests.res"
            if [ -f "$suite_res_file" ]; then
                echo "  $suite: $(cat "$suite_res_file")"
            else
                echo "  $suite: .res file not found"
            fi
        done
    } > "$log_dir/summary.txt"
    
    # Display summary
    log_info "========================================="
    log_info "GStreamer Test Suites Summary:"
    log_info "  Total: $total_suites"
    log_info "  Passed: $passed_suites"
    log_info "  Failed: $failed_suites"
    log_info "========================================="
    
    # Final result
    if [ $failed_suites -eq 0 ]; then
        echo "PASS $TESTNAME" > "$res_file"
        log_pass "$TESTNAME: All test suites passed ($passed_suites/$total_suites)"
        exit 0
    else
        echo "FAIL $TESTNAME" > "$res_file"
        log_fail "$TESTNAME: Some test suites failed ($failed_suites/$total_suites)"
        exit 0
    fi
}

# Execute main
main "$@"
