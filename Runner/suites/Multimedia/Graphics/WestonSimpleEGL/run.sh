#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Description: Script to test the 'weston-simple-egl' Wayland client for 30 seconds and log the result.

# Set the result directory, defaulting to /tmp if not already set
RESULT_DIR="${RESULT_DIR:-/tmp}"

# Create a log file with a timestamp
LOG_FILE="$RESULT_DIR/WestonSimpleEGL_$(date +%Y%m%d_%H%M%S).log"

# Define the test name
TESTNAME="WestonSimpleEGL"

# Set environment variables required for Weston/Wayland
export XDG_RUNTIME_DIR=/dev/socket/weston
export WAYLAND_DISPLAY=wayland-1

# Ensure the runtime directory exists and has the correct permissions
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# Source environment initialization and test utility functions
. "$(pwd)/init_env"
. "$TOOLS/functestlib.sh"

# Locate the test case path using the test name
test_path=$(find_test_case_by_name "$TESTNAME")

# Log the start of the test
log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"

# Check if Weston compositor is running
if ! pgrep -x "weston" >/dev/null; then
    echo "[ERROR] Weston is not running." | tee -a "$LOG_FILE"
    log_fail "$TESTNAME : Weston not running"
    echo "$TESTNAME SKIP" > "$test_path/$TESTNAME.res"
    exit 1
fi

# Check if the 'weston-simple-egl' binary is available in the system path
if ! command -v weston-simple-egl >/dev/null 2>&1; then
    echo "[ERROR] weston-simple-egl not found in system path." | tee -a "$LOG_FILE"
    log_fail "$TESTNAME : weston-simple-egl binary not found"
    echo "$TESTNAME SKIP" > "$test_path/$TESTNAME.res"
    exit 1
fi

# Function to run the 'weston-simple-egl' client for 30 seconds
run_weston_simple_egl() {
    echo "[INFO] Running weston-simple-egl for 30 seconds..." | tee -a "$LOG_FILE"
    # Run the client and capture its output using 'script'
    script -q -c "weston-simple-egl" "$LOG_FILE" 2>/dev/null &
    EGL_PID=$!
    sleep 30
    # Terminate the client after 30 seconds
    kill $EGL_PID 2>/dev/null
}

# Function to analyze the log and determine if the test passed
log_result() {
    local count
    # Count how many times "5 seconds" appears in the log (expected: 5 times for 30 seconds)
    count=$(grep -i -o "5 seconds" "$LOG_FILE" | wc -l)

    if [ "$count" -eq 5 ]; then
        echo "[INFO] weston-simple-egl successfully executed for 30 seconds." | tee -a "$LOG_FILE"
        echo "$TESTNAME PASS" | tee -a "$LOG_FILE"
        echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
        return 0
    else
        echo "[ERROR] weston-simple-egl did not execute correctly." | tee -a "$LOG_FILE"
        echo "$TESTNAME FAIL" | tee -a "$LOG_FILE"
        echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
        return 1
    fi
}

# Main function to run the test and log the result
main() {
    run_weston_simple_egl
    sleep 5  # Wait a bit before checking the log
    log_result
    log_info "------------------- Completed $TESTNAME Testcase ----------------------------"
}

# Execute the main function
main
