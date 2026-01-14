#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#==============================================================================
# GStreamer Display Tests - Wayland Video Display Validation
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

# Source functestlib.sh and lib_display.sh
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_display.sh"

#==============================================================================
# Test Configuration
#==============================================================================

TESTNAME="Gstreamer_Display_Tests"
test_path=$(find_test_case_by_name "$TESTNAME")
res_file="$test_path/$TESTNAME.res"
log_dir="$test_path/logs_$TESTNAME"

# Default parameters
TIMEOUT="${TIMEOUT:-120}"
REPEAT="${REPEAT:-1}"
REPEAT_POLICY="${REPEAT_POLICY:-all}"
STRICT="${STRICT:-false}"
DMESG_SCAN="${DMESG_SCAN:-true}"

# Test list
ALL_TESTS="wayland-basic wayland-videotestsrc wayland-colorbar wayland-smpte"

#==============================================================================
# Helper Functions
#==============================================================================

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

GStreamer Display Tests - Wayland video display validation

OPTIONS:
    --all                   Run all display tests
    --test <name>           Run specific test (wayland-basic, wayland-videotestsrc, wayland-colorbar, wayland-smpte)
    --list                  List available tests
    --timeout <seconds>     Timeout per test (default: 120)
    --repeat <count>        Repeat count (default: 1)
    --repeat-policy <all|any>  Pass policy: all runs pass or any run passes (default: all)
    --strict                Fail on warnings (default: false)
    --no-dmesg              Skip dmesg error scanning (default: scan enabled)
    --help                  Show this help

EXAMPLES:
    $0 --all
    $0 --test wayland-basic
    $0 --all --timeout 180 --strict
    $0 --test wayland-colorbar --repeat 3 --repeat-policy any

EOF
}

list_tests() {
    echo "Available Display Tests:"
    for test in $ALL_TESTS; do
        echo "  - $test"
    done
}

check_wayland() {
    # Use lib_display.sh helpers for Wayland detection (same as weston-simple-egl)
    
    if command -v wayland_debug_snapshot >/dev/null 2>&1; then
        wayland_debug_snapshot "$TESTNAME: start"
    fi
    
    local sock=""
    
    # Try to find any existing Wayland socket (base or overlay)
    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
    fi
    
    # If we found a socket, adopt its environment
    if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        log_info "Found existing Wayland socket: $sock"
        if ! adopt_wayland_env_from_socket "$sock"; then
            log_warn "Failed to adopt env from $sock"
        fi
    fi
    
    # If no usable socket yet, try starting a private Weston (overlay-style helper)
    if [ -z "$sock" ] && command -v overlay_start_weston_drm >/dev/null 2>&1; then
        log_info "No usable Wayland socket; trying overlay_start_weston_drm helper..."
        if overlay_start_weston_drm; then
            # Re-scan for a socket after attempting to start Weston
            if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
                sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
            fi
            if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
                log_info "Overlay Weston created Wayland socket: $sock"
                if ! adopt_wayland_env_from_socket "$sock"; then
                    log_warn "Failed to adopt env from $sock"
                fi
            else
                log_warn "overlay_start_weston_drm reported success but no Wayland socket was found."
            fi
        else
            log_warn "overlay_start_weston_drm returned non-zero; private Weston may have failed to start."
        fi
    fi
    
    # Final decision: run or SKIP
    if [ -z "$sock" ]; then
        log_warn "No Wayland socket found after autodetection; skipping $TESTNAME."
        return 1
    fi
    
    # Verify Wayland connection
    if command -v wayland_connection_ok >/dev/null 2>&1; then
        if ! wayland_connection_ok; then
            log_error "Wayland connection test failed; cannot run $TESTNAME."
            return 1
        fi
        log_info "Wayland connection test: OK"
    else
        log_warn "wayland_connection_ok helper not found; continuing without explicit Wayland probe."
    fi
    
    # Log final environment
    log_info "Wayland display: ${WAYLAND_DISPLAY:-<not set>}"
    log_info "XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-<not set>}"
    if [ -n "$sock" ]; then
        log_info "Wayland socket: $sock"
    fi
    
    return 0
}

validate_wayland_surface() {
    local test_name="$1"
    local log_file="$2"
    
    # Check if waylandsink created a surface
    if grep -qi "created.*surface\|waylandsink.*ready" "$log_file"; then
        log_info "$test_name: Wayland surface created successfully"
        return 0
    fi
    
    # Check for Wayland-specific errors
    if grep -qi "wayland.*error\|failed to connect to wayland\|no wayland display" "$log_file"; then
        log_error "$test_name: Wayland connection/surface error detected"
        return 1
    fi
    
    return 0
}

check_dependencies() {
    local missing=""
    
    if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
        missing="$missing gstreamer1.0-tools"
    fi
    
    if ! gst-inspect-1.0 waylandsink >/dev/null 2>&1; then
        missing="$missing gstreamer1.0-plugins-bad (waylandsink)"
    fi
    
    if ! gst-inspect-1.0 videotestsrc >/dev/null 2>&1; then
        missing="$missing gstreamer1.0-plugins-base (videotestsrc)"
    fi
    
    if ! gst-inspect-1.0 videoconvert >/dev/null 2>&1; then
        missing="$missing gstreamer1.0-plugins-base (videoconvert)"
    fi
    
    if [ -n "$missing" ]; then
        log_error "Missing dependencies:$missing"
        return 1
    fi
    
    return 0
}

validate_pipeline_output() {
    local log_file="$1"
    local test_name="$2"
    local errors=0
    
    # Check for ERROR messages
    if grep -qi "ERROR" "$log_file"; then
        log_error "$test_name: Found ERROR in pipeline output"
        grep -i "ERROR" "$log_file" | head -5
        errors=$((errors + 1))
    fi
    
    # Check for WARNING messages in strict mode
    if [ "$STRICT" = "true" ]; then
        if grep -qi "WARNING" "$log_file"; then
            log_error "$test_name: Found WARNING in pipeline output (strict mode)"
            grep -i "WARNING" "$log_file" | head -5
            errors=$((errors + 1))
        fi
    fi
    
    # Check for common failure patterns
    if grep -qi "failed to negotiate\|could not link\|no such element\|failed to create element" "$log_file"; then
        log_error "$test_name: Pipeline negotiation or element creation failed"
        grep -Ei "failed to negotiate|could not link|no such element|failed to create element" "$log_file"
        errors=$((errors + 1))
    fi
    
    # Validate Wayland surface creation
    if ! validate_wayland_surface "$test_name" "$log_file"; then
        errors=$((errors + 1))
    fi
    
    return $errors
}

run_gst_pipeline() {
    local test_name="$1"
    local pipeline="$2"
    local log_file="$log_dir/${test_name}.log"
    local timeout_val="$TIMEOUT"
    local duration="${3:-5}"  # Default 5 seconds display duration
    
    log_info "Running $test_name (timeout: ${timeout_val}s, duration: ${duration}s)"
    log_info "Pipeline: $pipeline"
    
    # Run pipeline with timeout
    # For display tests, we run for a specific duration then gracefully stop
    if timeout "$timeout_val" sh -c "gst-launch-1.0 $pipeline > '$log_file' 2>&1"; then
        log_pass "$test_name: Pipeline completed successfully"
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log_error "$test_name: Timeout after ${timeout_val}s"
        else
            log_error "$test_name: Pipeline failed with exit code $exit_code"
        fi
        return 1
    fi
}

#==============================================================================
# Test Cases
#==============================================================================

test_wayland_basic() {
    local test_name="wayland-basic"
    local log_file="$log_dir/${test_name}.log"
    
    log_info "=== Test: $test_name ==="
    
    # Basic Wayland display test with simple test pattern
    # 720x480 @ 30fps for 5 seconds (150 frames)
    local pipeline="videotestsrc num-buffers=150 pattern=0 ! \
video/x-raw,width=720,height=480,framerate=30/1 ! \
waylandsink"
    
    if run_gst_pipeline "$test_name" "$pipeline" 5; then
        if validate_pipeline_output "$log_file" "$test_name"; then
            log_pass "$test_name: PASSED"
            return 0
        fi
    fi
    
    log_fail "$test_name: FAILED"
    return 1
}

test_wayland_videotestsrc() {
    local test_name="wayland-videotestsrc"
    local log_file="$log_dir/${test_name}.log"
    
    log_info "=== Test: $test_name ==="
    
    # Test with moving ball pattern at 1080p
    # 1920x1080 @ 30fps for 5 seconds (150 frames)
    local pipeline="videotestsrc num-buffers=150 pattern=ball ! \
video/x-raw,width=1920,height=1080,framerate=30/1 ! \
videoconvert ! \
waylandsink"
    
    if run_gst_pipeline "$test_name" "$pipeline" 5; then
        if validate_pipeline_output "$log_file" "$test_name"; then
            log_pass "$test_name: PASSED"
            return 0
        fi
    fi
    
    log_fail "$test_name: FAILED"
    return 1
}

test_wayland_colorbar() {
    local test_name="wayland-colorbar"
    local log_file="$log_dir/${test_name}.log"
    
    log_info "=== Test: $test_name ==="
    
    # Test with color bars pattern at 4K
    # 3840x2160 @ 30fps for 5 seconds (150 frames)
    local pipeline="videotestsrc num-buffers=150 pattern=bar ! \
video/x-raw,width=3840,height=2160,framerate=30/1 ! \
videoconvert ! \
waylandsink"
    
    if run_gst_pipeline "$test_name" "$pipeline" 5; then
        if validate_pipeline_output "$log_file" "$test_name"; then
            log_pass "$test_name: PASSED"
            return 0
        fi
    fi
    
    log_fail "$test_name: FAILED"
    return 1
}

test_wayland_smpte() {
    local test_name="wayland-smpte"
    local log_file="$log_dir/${test_name}.log"
    
    log_info "=== Test: $test_name ==="
    
    # Test with SMPTE color bars at 720p
    # 1280x720 @ 60fps for 5 seconds (300 frames)
    local pipeline="videotestsrc num-buffers=300 pattern=smpte ! \
video/x-raw,width=1280,height=720,framerate=60/1 ! \
videoconvert ! \
waylandsink"
    
    if run_gst_pipeline "$test_name" "$pipeline" 5; then
        if validate_pipeline_output "$log_file" "$test_name"; then
            log_pass "$test_name: PASSED"
            return 0
        fi
    fi
    
    log_fail "$test_name: FAILED"
    return 1
}

#==============================================================================
# Test Execution with Repeat Logic
#==============================================================================

run_test_with_repeat() {
    local test_name="$1"
    local pass_count=0
    local fail_count=0
    
    log_info "Running $test_name (repeat: $REPEAT, policy: $REPEAT_POLICY)"
    
    i=1
    while [ $i -le "$REPEAT" ]; do
        log_info "Attempt $i/$REPEAT for $test_name"
        
        case "$test_name" in
            wayland-basic)
                if test_wayland_basic; then
                    pass_count=$((pass_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            wayland-videotestsrc)
                if test_wayland_videotestsrc; then
                    pass_count=$((pass_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            wayland-colorbar)
                if test_wayland_colorbar; then
                    pass_count=$((pass_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            wayland-smpte)
                if test_wayland_smpte; then
                    pass_count=$((pass_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            *)
                log_error "Unknown test: $test_name"
                return 1
                ;;
        esac
        
        i=$((i + 1))
    done
    
    # Apply repeat policy
    if [ "$REPEAT_POLICY" = "any" ]; then
        if [ $pass_count -gt 0 ]; then
            log_pass "$test_name: PASSED (any policy: $pass_count/$REPEAT passed)"
            return 0
        else
            log_fail "$test_name: FAILED (any policy: 0/$REPEAT passed)"
            return 1
        fi
    else
        # Default: all policy
        if [ $fail_count -eq 0 ]; then
            log_pass "$test_name: PASSED (all policy: $pass_count/$REPEAT passed)"
            return 0
        else
            log_fail "$test_name: FAILED (all policy: $fail_count/$REPEAT failed)"
            return 1
        fi
    fi
}

#==============================================================================
# Main Execution
#==============================================================================

main() {
    local run_all=false
    local specific_test=""
    local tests_to_run=""
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --all)
                run_all=true
                shift
                ;;
            --test)
                specific_test="$2"
                shift 2
                ;;
            --list)
                list_tests
                exit 0
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --repeat)
                REPEAT="$2"
                shift 2
                ;;
            --repeat-policy)
                REPEAT_POLICY="$2"
                shift 2
                ;;
            --strict)
                STRICT=true
                shift
                ;;
            --no-dmesg)
                DMESG_SCAN=false
                shift
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
    
    # Determine tests to run (default to all if no arguments)
    if [ "$run_all" = "true" ]; then
        tests_to_run="$ALL_TESTS"
    elif [ -n "$specific_test" ]; then
        tests_to_run="$specific_test"
    else
        # Default: run all tests
        log_info "No test specified, running all tests by default"
        tests_to_run="$ALL_TESTS"
    fi
    
    # Setup
    mkdir -p "$log_dir"
    log_info "Starting $TESTNAME"
    log_info "Log directory: $log_dir"
    
    # Pre-checks
    if ! check_dependencies; then
        echo "SKIP $TESTNAME" > "$res_file"
        log_skip "$TESTNAME: Missing dependencies"
        exit 0
    fi
    
    if ! check_wayland; then
        echo "SKIP $TESTNAME" > "$res_file"
        log_skip "$TESTNAME: Wayland not available"
        exit 0
    fi
    
    # Capture initial dmesg
    if [ "$DMESG_SCAN" = "true" ]; then
        dmesg > "$log_dir/dmesg_snapshot.log"
    fi
    
    # Run tests
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    
    for test in $tests_to_run; do
        total_tests=$((total_tests + 1))
        
        if run_test_with_repeat "$test"; then
            passed_tests=$((passed_tests + 1))
        else
            failed_tests=$((failed_tests + 1))
        fi
    done
    
    # Check for dmesg errors
    if [ "$DMESG_SCAN" = "true" ]; then
        dmesg | diff "$log_dir/dmesg_snapshot.log" - | grep -i "error\|fail\|warn" > "$log_dir/dmesg_errors.log" || true
        if [ -s "$log_dir/dmesg_errors.log" ]; then
            log_warn "New kernel errors detected (see dmesg_errors.log)"
        fi
    fi
    
    # Generate summary
    {
        echo "=== GStreamer Display Tests Summary ==="
        echo "Total Tests: $total_tests"
        echo "Passed: $passed_tests"
        echo "Failed: $failed_tests"
        echo "Timeout: ${TIMEOUT}s"
        echo "Repeat: $REPEAT (policy: $REPEAT_POLICY)"
        echo "Strict Mode: $STRICT"
        echo "Dmesg Scan: $DMESG_SCAN"
    } > "$log_dir/summary.txt"
    
    # Generate CSV results
    {
        echo "test_name,status,attempts,passed,failed"
        for test in $tests_to_run; do
            if grep -q "PASSED.*$test" "$log_dir"/*.log 2>/dev/null; then
                echo "$test,PASS,$REPEAT,$REPEAT,0"
            else
                echo "$test,FAIL,$REPEAT,0,$REPEAT"
            fi
        done
    } > "$log_dir/results.csv"
    
    # Generate JUnit XML
    generate_junit_xml "$log_dir" "$TESTNAME" "$tests_to_run"
    
    # Final result
    if [ $failed_tests -eq 0 ]; then
        echo "PASS $TESTNAME" > "$res_file"
        log_pass "$TESTNAME: All tests passed ($passed_tests/$total_tests)"
        exit 0
    else
        echo "FAIL $TESTNAME" > "$res_file"
        log_fail "$TESTNAME: Some tests failed ($failed_tests/$total_tests)"
        exit 0
    fi
}

generate_junit_xml() {
    local log_dir="$1"
    local suite_name="$2"
    local tests="$3"
    local xml_file="$log_dir/.junit_cases.xml"
    
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"$suite_name\">"
        
        for test in $tests; do
            if grep -q "PASSED.*$test" "$log_dir"/*.log 2>/dev/null; then
                echo "  <testcase name=\"$test\" status=\"pass\"/>"
            else
                echo "  <testcase name=\"$test\" status=\"fail\">"
                echo "    <failure message=\"Test failed\"/>"
                echo "  </testcase>"
            fi
        done
        
        echo "</testsuite>"
    } > "$xml_file"
}

# Execute main
main "$@"
