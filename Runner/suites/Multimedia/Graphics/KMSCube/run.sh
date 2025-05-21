#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# KMSCube Validator Script (Yocto-Compatible)
# No input arguments required.

RESULT_DIR="${RESULT_DIR:-/tmp}"
LOG_FILE="$RESULT_DIR/kmscube_validation_$(date +%Y%m%d_%H%M%S).log"
TESTNAME="KMSCube"

# Fixed frame count
FRAME_COUNT=999

# Import common functions
. "$(pwd)/init_env"
. "$TOOLS/functestlib.sh"

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"

# Validate if kmscube binary is available
if ! command -v kmscube >/dev/null 2>&1; then
    printf "%s[ERROR]%s kmscube not found in system path.\n" "$RED" "$NC"
    log_fail "$TESTNAME : kmscube binary not found"
    echo "$TESTNAME SKIP" > "$test_path/$TESTNAME.res"
    exit 1
fi

# Check if DRM device exists
if [ ! -e /dev/dri/card0 ]; then
    echo "[ERROR] /dev/dri/card0 not found." | tee -a "$LOG_FILE"
    log_fail "$TESTNAME : DRM device not found"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    exit 1
fi

# Print result helper
log_result() {
    local result="$1"
    if [ "$result" -eq 0 ]; then
        echo "$TESTNAME PASS" | tee -a "$LOG_FILE"
    else
        echo "$TESTNAME FAIL" | tee -a "$LOG_FILE"
    fi
}

# Run kmscube and validate output
kmscube_test() {
    echo "[INFO] Running kmscube test with --count=$FRAME_COUNT..." | tee -a "$LOG_FILE"

    # Clear previous log
    : > "$LOG_FILE"

    # Run kmscube and log output
    /usr/bin/kmscube --device /dev/dri/card0 --count="$FRAME_COUNT" 2>&1 | tee -a "$LOG_FILE"

    # Calculate expected frame output
    EXPECTED_FRAMES=$((FRAME_COUNT - 1))

    # Check for expected output
    if grep -q "Rendered $EXPECTED_FRAMES frames" "$LOG_FILE"; then
        printf "\n%s[PASS]%s kmscube rendered %s frames successfully.\n" "$GREEN" "$NC" "$EXPECTED_FRAMES" | tee -a "$LOG_FILE"
        return 0
    else
        printf "\n%s[FAIL]%s kmscube did not render %s frames.\n" "$RED" "$NC" "$EXPECTED_FRAMES" | tee -a "$LOG_FILE"
        return 1
    fi
}

main() {
    # Stop Weston if running
    if pgrep -x "weston" >/dev/null; then
        echo "[INFO] Weston is running. Attempting to stop it..." | tee -a "$LOG_FILE"
        killall weston
        sleep 2
        if pgrep -x "weston" >/dev/null; then
            echo "[WARN] Failed to stop Weston. It may interfere with kmscube." | tee -a "$LOG_FILE"
        else
            echo "[INFO] Weston stopped successfully." | tee -a "$LOG_FILE"
        fi
    else
        echo "[INFO] Weston is not running." | tee -a "$LOG_FILE"
    fi

    kmscube_test
    result=$?
    log_result "KMSCube Test" $result
    log_info "------------------- Completed $TESTNAME Testcase ----------------------------"
    exit $result
}

main
