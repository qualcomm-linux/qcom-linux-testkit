#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#==============================================================================
# GStreamer Camera Tests - Camera Capture, Encoding, Preview, and Snapshot
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

TESTNAME="Gstreamer_Camera_Tests"
test_path=$(find_test_case_by_name "$TESTNAME")
res_file="$test_path/$TESTNAME.res"
log_dir="$test_path/logs_$TESTNAME"

# Default parameters
TIMEOUT="${TIMEOUT:-120}"
REPEAT="${REPEAT:-1}"
REPEAT_POLICY="${REPEAT_POLICY:-all}"
STRICT="${STRICT:-false}"
DMESG_SCAN="${DMESG_SCAN:-true}"
CAMERA_DEVICE="${CAMERA_DEVICE:-/dev/video0}"
CAPTURE_DURATION="${CAPTURE_DURATION:-5}"

# Test list
ALL_TESTS="camera-preview camera-h264-encode camera-h265-encode camera-snapshot camera-jpeg-encode"

#==============================================================================
# Helper Functions
#==============================================================================

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

GStreamer Camera Tests - Camera capture, encoding, preview, and snapshot validation

OPTIONS:
    --all                   Run all camera tests
    --test <name>           Run specific test
    --list                  List available tests
    --timeout <seconds>     Timeout per test (default: 120)
    --camera <device>       Camera device (default: /dev/video0)
    --duration <seconds>    Capture duration (default: 5)
    --repeat <count>        Repeat count (default: 1)
    --repeat-policy <all|any>  Pass policy (default: all)
    --strict                Fail on warnings (default: false)
    --no-dmesg              Skip dmesg error scanning (default: scan enabled)
    --help                  Show this help

AVAILABLE TESTS:
    camera-preview          - Live camera preview to waylandsink
    camera-h264-encode      - Capture and encode to H.264
    camera-h265-encode      - Capture and encode to H.265
    camera-snapshot         - Capture single frame snapshot (PNG)
    camera-jpeg-encode      - Capture and encode to JPEG

EXAMPLES:
    $0 --all
    $0 --test camera-preview
    $0 --all --camera /dev/video2 --duration 10
    $0 --test camera-h264-encode --repeat 3

EOF
}

list_tests() {
    echo "Available Camera Tests:"
    for test in $ALL_TESTS; do
        echo "  - $test"
    done
}

check_camera_device() {
    log_info "Using libcamera for camera access"
    log_info "Camera device parameter: $CAMERA_DEVICE"
    
    # Check if libcamera can detect cameras
    if command -v libcamera-hello >/dev/null 2>&1; then
        log_info "Checking libcamera camera detection..."
        if timeout 5 libcamera-hello --list-cameras > /tmp/libcamera_list.txt 2>&1; then
            log_info "Available cameras:"
            cat /tmp/libcamera_list.txt | head -20
        else
            log_warn "libcamera camera detection timed out or failed"
        fi
        rm -f /tmp/libcamera_list.txt
    fi
    
    # Check if libcamerasrc is available
    if ! gst-inspect-1.0 libcamerasrc >/dev/null 2>&1; then
        log_error "libcamerasrc plugin not available"
        return 1
    fi
    
    log_info "libcamerasrc plugin is available"
    return 0
}

check_dependencies() {
    local missing=""
    
    if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
        missing="$missing gstreamer1.0-tools"
    fi
    
    if ! gst-inspect-1.0 libcamerasrc >/dev/null 2>&1; then
        missing="$missing gstreamer1.0-libcamera (libcamerasrc)"
    fi
    
    if ! gst-inspect-1.0 videoconvert >/dev/null 2>&1; then
        missing="$missing gstreamer1.0-plugins-base (videoconvert)"
    fi
    
    if ! command -v libcamera-hello >/dev/null 2>&1; then
        log_warn "libcamera-hello not found, camera detection may be limited"
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
    
    # Check for camera-specific errors
    if grep -qi "cannot identify device\|no such device\|device busy" "$log_file"; then
        log_error "$test_name: Camera device error detected"
        grep -Ei "cannot identify device|no such device|device busy" "$log_file"
        errors=$((errors + 1))
    fi
    
    return $errors
}

run_gst_pipeline() {
    local test_name="$1"
    local pipeline="$2"
    local log_file="$log_dir/${test_name}.log"
    local timeout_val="$TIMEOUT"
    
    log_info "Running $test_name (timeout: ${timeout_val}s)"
    log_info "Pipeline: $pipeline"
    
    # Run pipeline with timeout
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

test_camera_preview() {
    local test_name="camera-preview"
    local log_file="$log_dir/${test_name}.log"
    
    log_info "=== Test: $test_name ==="
    
    # Calculate number of frames (duration * 30fps)
    local num_buffers=$((CAPTURE_DURATION * 30))
    
    # Pipeline: Camera preview to Wayland display using libcamera
    local pipeline="libcamerasrc num-buffers=$num_buffers ! \
video/x-raw,width=1920,height=1080,framerate=30/1 ! \
videoconvert ! \
waylandsink"
    
    if run_gst_pipeline "$test_name" "$pipeline"; then
        if validate_pipeline_output "$log_file" "$test_name"; then
            log_pass "$test_name: PASSED"
            return 0
        fi
    fi
    
    log_fail "$test_name: FAILED"
    return 1
}

test_camera_h264_encode() {
    local test_name="camera-h264-encode"
    local log_file="$log_dir/${test_name}.log"
    local output_file="$test_path/camera_h264.mp4"
    
    log_info "=== Test: $test_name ==="
    
    # Calculate number of frames
    local num_buffers=$((CAPTURE_DURATION * 30))
    
    # Pipeline: Camera capture and H.264 encode using libcamera
    local pipeline="libcamerasrc num-buffers=$num_buffers ! \
video/x-raw,width=1920,height=1080,framerate=30/1 ! \
videoconvert ! \
video/x-raw,format=NV12 ! \
v4l2h264enc extra-controls=\"controls,video_bitrate=4000000\" ! \
h264parse ! \
qtmux ! \
filesink location=$output_file"
    
    if run_gst_pipeline "$test_name" "$pipeline"; then
        if validate_pipeline_output "$log_file" "$test_name"; then
            if [ -f "$output_file" ]; then
                local file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null)
                if [ "$file_size" -gt 0 ]; then
                    log_info "$test_name: Output file created: $output_file (${file_size} bytes)"
                    log_pass "$test_name: PASSED"
                    return 0
                else
                    log_error "$test_name: Output file is empty"
                fi
            else
                log_error "$test_name: Output file not created"
            fi
        fi
    fi
    
    log_fail "$test_name: FAILED"
    return 1
}

test_camera_h265_encode() {
    local test_name="camera-h265-encode"
    local log_file="$log_dir/${test_name}.log"
    local output_file="$test_path/camera_h265.mp4"
    
    log_info "=== Test: $test_name ==="
    
    # Calculate number of frames
    local num_buffers=$((CAPTURE_DURATION * 30))
    
    # Pipeline: Camera capture and H.265 encode using libcamera
    local pipeline="libcamerasrc num-buffers=$num_buffers ! \
video/x-raw,width=1920,height=1080,framerate=30/1 ! \
videoconvert ! \
video/x-raw,format=NV12 ! \
v4l2h265enc extra-controls=\"controls,video_bitrate=4000000\" ! \
h265parse ! \
qtmux ! \
filesink location=$output_file"
    
    if run_gst_pipeline "$test_name" "$pipeline"; then
        if validate_pipeline_output "$log_file" "$test_name"; then
            if [ -f "$output_file" ]; then
                local file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null)
                if [ "$file_size" -gt 0 ]; then
                    log_info "$test_name: Output file created: $output_file (${file_size} bytes)"
                    log_pass "$test_name: PASSED"
                    return 0
                else
                    log_error "$test_name: Output file is empty"
                fi
            else
                log_error "$test_name: Output file not created"
            fi
        fi
    fi
    
    log_fail "$test_name: FAILED"
    return 1
}

test_camera_snapshot() {
    local test_name="camera-snapshot"
    local log_file="$log_dir/${test_name}.log"
    local output_file="$test_path/camera_snapshot.png"
    
    log_info "=== Test: $test_name ==="
    
    # Pipeline: Capture single frame and save as PNG using libcamera
    local pipeline="libcamerasrc num-buffers=1 ! \
video/x-raw,width=1920,height=1080 ! \
videoconvert ! \
pngenc ! \
filesink location=$output_file"
    
    if run_gst_pipeline "$test_name" "$pipeline"; then
        if validate_pipeline_output "$log_file" "$test_name"; then
            if [ -f "$output_file" ]; then
                local file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null)
                if [ "$file_size" -gt 0 ]; then
                    log_info "$test_name: Snapshot created: $output_file (${file_size} bytes)"
                    log_pass "$test_name: PASSED"
                    return 0
                else
                    log_error "$test_name: Snapshot file is empty"
                fi
            else
                log_error "$test_name: Snapshot file not created"
            fi
        fi
    fi
    
    log_fail "$test_name: FAILED"
    return 1
}

test_camera_jpeg_encode() {
    local test_name="camera-jpeg-encode"
    local log_file="$log_dir/${test_name}.log"
    local output_file="$test_path/camera_jpeg.jpg"
    
    log_info "=== Test: $test_name ==="
    
    # Pipeline: Capture and encode to JPEG using libcamera
    local pipeline="libcamerasrc num-buffers=1 ! \
video/x-raw,width=1920,height=1080 ! \
videoconvert ! \
jpegenc quality=90 ! \
filesink location=$output_file"
    
    if run_gst_pipeline "$test_name" "$pipeline"; then
        if validate_pipeline_output "$log_file" "$test_name"; then
            if [ -f "$output_file" ]; then
                local file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null)
                if [ "$file_size" -gt 0 ]; then
                    log_info "$test_name: JPEG created: $output_file (${file_size} bytes)"
                    log_pass "$test_name: PASSED"
                    return 0
                else
                    log_error "$test_name: JPEG file is empty"
                fi
            else
                log_error "$test_name: JPEG file not created"
            fi
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
            camera-preview)
                if test_camera_preview; then
                    pass_count=$((pass_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            camera-h264-encode)
                if test_camera_h264_encode; then
                    pass_count=$((pass_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            camera-h265-encode)
                if test_camera_h265_encode; then
                    pass_count=$((pass_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            camera-snapshot)
                if test_camera_snapshot; then
                    pass_count=$((pass_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            camera-jpeg-encode)
                if test_camera_jpeg_encode; then
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
            --camera)
                CAMERA_DEVICE="$2"
                shift 2
                ;;
            --duration)
                CAPTURE_DURATION="$2"
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
    log_info "Camera device: $CAMERA_DEVICE"
    log_info "Capture duration: ${CAPTURE_DURATION}s"
    
    # Pre-checks
    if ! check_dependencies; then
        echo "SKIP $TESTNAME" > "$res_file"
        log_skip "$TESTNAME: Missing dependencies"
        exit 0
    fi
    
    if ! check_camera_device; then
        echo "SKIP $TESTNAME" > "$res_file"
        log_skip "$TESTNAME: Camera device not available"
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
        echo "=== GStreamer Camera Tests Summary ==="
        echo "Total Tests: $total_tests"
        echo "Passed: $passed_tests"
        echo "Failed: $failed_tests"
        echo "Camera Device: $CAMERA_DEVICE"
        echo "Capture Duration: ${CAPTURE_DURATION}s"
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
