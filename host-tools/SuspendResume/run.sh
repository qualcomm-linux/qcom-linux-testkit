#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

TESTNAME="SuspendResume"
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase (ADB-based)----------------------------"
log_info "=== Test Initialization ==="

# ============================================================================
# ADB-BASED SUSPEND/RESUME TEST
# ============================================================================
# This version uses adb commands to control the device remotely, which is
# compatible with LAVA's upcoming adb support framework.
# ============================================================================

# Configuration
SUSPEND_DURATION=30  # seconds to suspend
WAIT_TIMEOUT=40      # seconds to wait for device to resume

# Check if adb is available
if ! command -v adb >/dev/null 2>&1; then
    log_fail "adb command not found - this test requires adb to be installed"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Check that exactly one device is connected
log_info "Checking for connected ADB devices..."

# Count devices using grep (handles Windows line endings better than awk)
DEVICE_COUNT=$(adb devices 2>/dev/null | grep -v "List of devices" | grep "device" | wc -l | tr -d ' \t\r\n')

# Ensure DEVICE_COUNT is a valid integer
if [ -z "$DEVICE_COUNT" ]; then
    DEVICE_COUNT=0
fi

log_info "Detected $DEVICE_COUNT device(s)"

if [ "$DEVICE_COUNT" -eq 0 ]; then
    log_fail "No ADB devices connected - please connect a device"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
elif [ "$DEVICE_COUNT" -gt 1 ]; then
    log_fail "Multiple ADB devices connected ($DEVICE_COUNT devices) - please connect only one device"
    log_info "Connected devices:"
    adb devices
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Single device detected - proceeding with test"
log_info "Waiting for device to be ready..."
adb wait-for-device

# Get root access
log_info "Obtaining root access..."
adb root
sleep 2
adb wait-for-device

# Remount filesystems as read-write
log_info "Remounting filesystems as read-write..."
adb shell "mount -o remount,rw /" 2>/dev/null || true
adb shell "mount -o remount,rw /usr" 2>/dev/null || true

# Mount debugfs
log_info "Mounting debugfs..."
adb shell "mount -t debugfs none /sys/kernel/debug" 2>/dev/null || true

# ============================================================================
# PRE-SUSPEND: Capture initial state
# ============================================================================

log_info "Capturing pre-suspend state..."

# Get initial suspend count
INITIAL_SUSPEND_COUNT=$(adb shell "cat /sys/power/suspend_stats/success 2>/dev/null" | tr -d '\r\n' || echo "0")
log_info "Initial suspend count: $INITIAL_SUSPEND_COUNT"

# Verify suspend stats are accessible
if [ -z "$INITIAL_SUSPEND_COUNT" ] || [ "$INITIAL_SUSPEND_COUNT" = "0" ]; then
    log_warn "Suspend stats may not be available or this is first suspend"
fi

# ============================================================================
# TRIGGER SUSPEND
# ============================================================================

log_info "Triggering suspend for $SUSPEND_DURATION seconds..."
log_info "Command: rtcwake -d /dev/rtc0 -m no -s $SUSPEND_DURATION && systemctl suspend"

# Execute suspend command (this will disconnect adb)
adb shell "rtcwake -d /dev/rtc0 -m no -s $SUSPEND_DURATION && systemctl suspend" &
SUSPEND_PID=$!

# Give the suspend command time to execute
sleep 5

# ============================================================================
# WAIT FOR RESUME
# ============================================================================

log_info "Waiting for device to resume (timeout: ${WAIT_TIMEOUT}s)..."

# Wait for device to come back online using counter-based timeout
WAIT_COUNT=0
DEVICE_RESUMED=0

while [ $WAIT_COUNT -lt $WAIT_TIMEOUT ]; do
    # Try to check if device is responsive (non-blocking check)
    if adb shell "echo test" >/dev/null 2>&1; then
        DEVICE_RESUMED=1
        log_pass "Device resumed successfully after ${WAIT_COUNT}s"
        break
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
    
    # Log progress every 10 seconds
    if [ $((WAIT_COUNT % 10)) -eq 0 ]; then
        log_info "Still waiting... (${WAIT_COUNT}s elapsed)"
    fi
done

# Clean up background process
kill $SUSPEND_PID 2>/dev/null || true
wait $SUSPEND_PID 2>/dev/null || true

if [ $DEVICE_RESUMED -eq 0 ]; then
    log_fail "$TESTNAME : Device did not resume within ${WAIT_TIMEOUT}s timeout"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# Give system a moment to stabilize after resume
sleep 3

# ============================================================================
# POST-RESUME: Validate suspend/resume cycle
# ============================================================================

log_info "Post-resume phase: Validating suspend/resume cycle"

# Remount debugfs again (may have been unmounted during suspend)
adb shell "mount -t debugfs none /sys/kernel/debug" 2>/dev/null || true

# Get current suspend count
CURRENT_SUSPEND_COUNT=$(adb shell "cat /sys/power/suspend_stats/success 2>/dev/null" | tr -d '\r\n' || echo "0")
log_info "Current suspend count: $CURRENT_SUSPEND_COUNT"

# ============================================================================
# VALIDATION CHECKS
# ============================================================================

VALIDATION_PASSED=1

# Validation Check 1: Verify suspend count incremented
if [ "$CURRENT_SUSPEND_COUNT" -le "$INITIAL_SUSPEND_COUNT" ]; then
    log_fail "Validation 1 FAILED: Suspend count did not increase (expected > $INITIAL_SUSPEND_COUNT, got $CURRENT_SUSPEND_COUNT)"
    VALIDATION_PASSED=0
else
    log_pass "Validation 1 PASSED: Suspend count increased from $INITIAL_SUSPEND_COUNT to $CURRENT_SUSPEND_COUNT"
fi

# Validation Check 2: Verify suspend entry markers in dmesg
log_info "Checking for suspend entry markers in kernel log..."
SUSPEND_ENTRY=$(adb shell "dmesg | grep -E 'PM: suspend entry|Freezing user space processes'" | tail -5)
if [ -z "$SUSPEND_ENTRY" ]; then
    log_fail "Validation 2 FAILED: Suspend entry markers not found in kernel log"
    VALIDATION_PASSED=0
else
    log_pass "Validation 2 PASSED: Suspend entry markers found"
    echo "$SUSPEND_ENTRY" | while IFS= read -r line; do
        log_info "  $line"
    done
fi

# Validation Check 3: Verify resume markers in dmesg
log_info "Checking for resume markers in kernel log..."
RESUME_MARKERS=$(adb shell "dmesg | grep -E 'PM: suspend exit|Restarting tasks'" | tail -5)
if [ -z "$RESUME_MARKERS" ]; then
    log_fail "Validation 3 FAILED: Resume markers not found in kernel log"
    VALIDATION_PASSED=0
else
    log_pass "Validation 3 PASSED: Resume markers found"
    echo "$RESUME_MARKERS" | while IFS= read -r line; do
        log_info "  $line"
    done
fi

# ============================================================================
# DEBUG INFO COLLECTION
# ============================================================================

log_info "Collecting debug statistics..."

# Collect kernel suspend statistics
log_info "=== Suspend Stats ==="
adb shell "cat /sys/kernel/debug/suspend_stats" 2>/dev/null || log_warn "Could not read suspend_stats"

# Collect Qualcomm-specific power statistics
log_info "=== Qualcomm Power Stats ==="

log_info "--- AOSD Stats ---"
adb shell "cat /sys/kernel/debug/qcom_stats/aosd" 2>/dev/null || log_warn "Could not read aosd stats"

log_info "--- ADSP Stats ---"
adb shell "cat /sys/kernel/debug/qcom_stats/adsp" 2>/dev/null || log_warn "Could not read adsp stats"

log_info "--- ADSP Island Stats ---"
adb shell "cat /sys/kernel/debug/qcom_stats/adsp_island" 2>/dev/null || log_warn "Could not read adsp_island stats"

log_info "--- CDSP Stats ---"
adb shell "cat /sys/kernel/debug/qcom_stats/cdsp" 2>/dev/null || log_warn "Could not read cdsp stats"

log_info "--- DDR Stats ---"
adb shell "cat /sys/kernel/debug/qcom_stats/ddr" 2>/dev/null || log_warn "Could not read ddr stats"

log_info "--- CXSD Stats ---"
adb shell "cat /sys/kernel/debug/qcom_stats/cxsd" 2>/dev/null || log_warn "Could not read cxsd stats"

# Dump all qcom_stats entries
log_info "=== All Qcom Stats (grep) ==="
adb shell "cd /sys/kernel/debug/qcom_stats && grep -r . 2>/dev/null" || log_warn "Could not grep qcom_stats"

# Dump all suspend_stats entries  
log_info "=== All Suspend Stats (grep) ==="
adb shell "cd /sys/power/suspend_stats && grep -r . 2>/dev/null" || log_warn "Could not grep suspend_stats"

# ============================================================================
# FINAL RESULT
# ============================================================================

if [ $VALIDATION_PASSED -eq 1 ]; then
    log_pass "$TESTNAME : Test Passed - Suspend/Resume cycle completed successfully"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed - One or more validation checks failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
