# SuspendResume Validation Test
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview
This test case validates the system suspend/resume functionality on the target device using ADB-based remote control. It triggers a suspend cycle, waits for the device to resume, and validates the suspend/resume operation through multiple checks including suspend statistics, kernel logs, and Qualcomm-specific power management statistics.

## Test Performs:
1. Connects to device via ADB and obtains root access
2. Remounts filesystems as read-write
3. Mounts debugfs for accessing kernel statistics
4. Captures initial suspend count from `/sys/power/suspend_stats/success`
5. Triggers suspend using `rtcwake` (30-second timer) and `systemctl suspend`
6. Waits for device to resume (40-second timeout)
7. Validates suspend/resume cycle through three checks:
   - **Check 1**: Verifies suspend count incremented
   - **Check 2**: Verifies suspend entry markers in dmesg
   - **Check 3**: Verifies resume markers in dmesg
8. Collects comprehensive debug statistics:
   - Kernel suspend statistics
   - Qualcomm power management statistics (AOSD, ADSP, CDSP, DDR, CXSD)
   - Complete qcom_stats and suspend_stats dumps

## Usage
Instructions:
1. **Copy repo to Host Machine**: Clone or download the repository to your host machine where ADB is installed.
2. **Connect Device**: Ensure exactly **one** target device is connected via ADB and visible with `adb devices`.
3. **Run Test**: Execute the test script which will remotely control the device via ADB.

Run the SuspendResume test using:
---

#### Quick Example
```sh
git clone <this-repo>
cd <this-repo>

# Ensure exactly one device is connected
adb devices

# Run the test from the new location
cd host-tools/SuspendResume
./run.sh
```

**Note:** The test requires exactly one ADB device to be connected. If multiple devices are detected, the test will skip with an error message.

---

## Prerequisites
1. **ADB**: The `adb` command must be available on the host machine
2. **Single Device Connection**: Exactly one target device must be connected via ADB
   - The test will automatically detect and validate device count
   - Multiple devices will cause the test to skip with an error message
3. **Root Access**: Device must allow `adb root` for root access
4. **Kernel Support**: Device must support:
   - `rtcwake` command for RTC-based wakeup
   - `systemctl suspend` for triggering suspend
   - Suspend statistics in `/sys/power/suspend_stats/`
   - Debugfs support for accessing kernel debug information
5. **RTC Device**: `/dev/rtc0` must be present and functional
6. **Framework Files**: `init_env` and `functestlib.sh` must be present and correctly configured

## Configuration
The test uses the following default configuration (can be modified in run.sh):
```sh
SUSPEND_DURATION=30  # seconds to suspend
WAIT_TIMEOUT=40      # seconds to wait for device to resume
```

## Result Format
Test result will be saved in `SuspendResume.res` as:

## Output
A .res file is generated in the same directory:
- `SuspendResume PASS` - All validation checks passed
- `SuspendResume FAIL` - One or more validation checks failed
- `SuspendResume SKIP` - ADB not available or prerequisites not met

## Validation Checks

### Check 1: Suspend Count Increment
Verifies that `/sys/power/suspend_stats/success` incremented after suspend/resume cycle.

### Check 2: Suspend Entry Markers
Searches dmesg for suspend entry indicators:
- `PM: suspend entry`
- `Freezing user space processes`

### Check 3: Resume Markers
Searches dmesg for resume indicators:
- `PM: suspend exit`
- `Restarting tasks`

## Debug Statistics Collected

The test collects comprehensive power management statistics:

### Kernel Suspend Stats
- `/sys/kernel/debug/suspend_stats` - Overall suspend statistics

### Qualcomm Power Stats
- `/sys/kernel/debug/qcom_stats/aosd` - Always-On Subsystem Domain stats
- `/sys/kernel/debug/qcom_stats/adsp` - Audio DSP stats
- `/sys/kernel/debug/qcom_stats/adsp_island` - ADSP Island mode stats
- `/sys/kernel/debug/qcom_stats/cdsp` - Compute DSP stats
- `/sys/kernel/debug/qcom_stats/ddr` - DDR stats
- `/sys/kernel/debug/qcom_stats/cxsd` - CX Subsystem Domain stats

### Complete Dumps
- All entries in `/sys/kernel/debug/qcom_stats/`
- All entries in `/sys/power/suspend_stats/`

## Skip Criteria
The test will be skipped if:
1. `adb` command is not found on the host machine
2. No ADB devices are connected
3. Multiple ADB devices are connected (only one device is allowed)
4. Device is not responding to ADB commands

## Failure Criteria
The test will fail if:
1. Device does not resume within the timeout period (40 seconds)
2. Suspend count does not increment
3. Suspend entry markers are not found in kernel log
4. Resume markers are not found in kernel log

## Sample Log - Success
```
[INFO] 2026-02-01 20:30:00 - -----------------------------------------------------------------------------------------
[INFO] 2026-02-01 20:30:00 - -------------------Starting SuspendResume Testcase (ADB-based)----------------------------
[INFO] 2026-02-01 20:30:00 - === Test Initialization ===
[INFO] 2026-02-01 20:30:00 - Checking for connected ADB devices...
[INFO] 2026-02-01 20:30:01 - Detected 1 device(s)
[INFO] 2026-02-01 20:30:01 - Single device detected - proceeding with test
[INFO] 2026-02-01 20:30:01 - Waiting for device to be ready...
[INFO] 2026-02-01 20:30:02 - Obtaining root access...
[INFO] 2026-02-01 20:30:04 - Remounting filesystems as read-write...
[INFO] 2026-02-01 20:30:05 - Mounting debugfs...
[INFO] 2026-02-01 20:30:06 - Capturing pre-suspend state...
[INFO] 2026-02-01 20:30:06 - Initial suspend count: 5
[INFO] 2026-02-01 20:30:06 - Triggering suspend for 30 seconds...
[INFO] 2026-02-01 20:30:06 - Command: rtcwake -d /dev/rtc0 -m no -s 30 && systemctl suspend
[INFO] 2026-02-01 20:30:11 - Waiting for device to resume (timeout: 40s)...
[PASS] 2026-02-01 20:30:38 - Device resumed successfully
[INFO] 2026-02-01 20:30:41 - Post-resume phase: Validating suspend/resume cycle
[INFO] 2026-02-01 20:30:42 - Current suspend count: 6
[PASS] 2026-02-01 20:30:42 - Validation 1 PASSED: Suspend count increased from 5 to 6
[INFO] 2026-02-01 20:30:42 - Checking for suspend entry markers in kernel log...
[PASS] 2026-02-01 20:30:43 - Validation 2 PASSED: Suspend entry markers found
[INFO] 2026-02-01 20:30:43 - Checking for resume markers in kernel log...
[PASS] 2026-02-01 20:30:44 - Validation 3 PASSED: Resume markers found
[INFO] 2026-02-01 20:30:44 - Collecting debug statistics...
[PASS] 2026-02-01 20:30:50 - SuspendResume : Test Passed - Suspend/Resume cycle completed successfully
```

## Sample Log - Failure (Device Not Resuming)
```
[INFO] 2026-02-01 20:30:00 - -----------------------------------------------------------------------------------------
[INFO] 2026-02-01 20:30:00 - -------------------Starting SuspendResume Testcase (ADB-based)----------------------------
[INFO] 2026-02-01 20:30:00 - === Test Initialization ===
[INFO] 2026-02-01 20:30:00 - Checking for connected ADB devices...
[INFO] 2026-02-01 20:30:01 - Detected 1 device(s)
[INFO] 2026-02-01 20:30:01 - Single device detected - proceeding with test
[INFO] 2026-02-01 20:30:01 - Waiting for device to be ready...
[INFO] 2026-02-01 20:30:02 - Obtaining root access...
[INFO] 2026-02-01 20:30:04 - Remounting filesystems as read-write...
[INFO] 2026-02-01 20:30:05 - Mounting debugfs...
[INFO] 2026-02-01 20:30:06 - Capturing pre-suspend state...
[INFO] 2026-02-01 20:30:06 - Initial suspend count: 5
[INFO] 2026-02-01 20:30:06 - Triggering suspend for 30 seconds...
[INFO] 2026-02-01 20:30:06 - Command: rtcwake -d /dev/rtc0 -m no -s 30 && systemctl suspend
[INFO] 2026-02-01 20:30:11 - Waiting for device to resume (timeout: 40s)...
[INFO] 2026-02-01 20:30:16 - Still waiting... (10s elapsed)
[INFO] 2026-02-01 20:30:26 - Still waiting... (20s elapsed)
[INFO] 2026-02-01 20:30:36 - Still waiting... (30s elapsed)
[INFO] 2026-02-01 20:30:46 - Still waiting... (40s elapsed)
[FAIL] 2026-02-01 20:30:51 - SuspendResume : Device did not resume within 40s timeout
```

## Sample Log - Skip (Multiple Devices)
```
[INFO] 2026-02-01 20:30:00 - -----------------------------------------------------------------------------------------
[INFO] 2026-02-01 20:30:00 - -------------------Starting SuspendResume Testcase (ADB-based)----------------------------
[INFO] 2026-02-01 20:30:00 - === Test Initialization ===
[INFO] 2026-02-01 20:30:00 - Checking for connected ADB devices...
[INFO] 2026-02-01 20:30:01 - Detected 2 device(s)
[FAIL] 2026-02-01 20:30:01 - Multiple ADB devices connected (2 devices) - please connect only one device
[INFO] 2026-02-01 20:30:01 - Connected devices:
List of devices attached
ABC123456789    device
DEF987654321    device
```

## Sample Log - Skip (No Devices)
```
[INFO] 2026-02-01 20:30:00 - -----------------------------------------------------------------------------------------
[INFO] 2026-02-01 20:30:00 - -------------------Starting SuspendResume Testcase (ADB-based)----------------------------
[INFO] 2026-02-01 20:30:00 - === Test Initialization ===
[INFO] 2026-02-01 20:30:00 - Checking for connected ADB devices...
[INFO] 2026-02-01 20:30:01 - Detected 0 device(s)
[FAIL] 2026-02-01 20:30:01 - No ADB devices connected - please connect a device
```

## Integration with LAVA
This test is designed to work with LAVA's ADB support framework. The YAML configuration file (`SuspendResume.yaml`) defines the test metadata and execution steps for LAVA integration.

## Troubleshooting

### Device Not Resuming
- Check if RTC device (`/dev/rtc0`) is functional
- Verify `rtcwake` command works manually
- Check if suspend is supported: `cat /sys/power/state`
- Increase `WAIT_TIMEOUT` if device takes longer to resume

### ADB Connection Issues
- Verify device is visible: `adb devices`
- Ensure only one device is connected (disconnect other devices if multiple are shown)
- Try `adb kill-server && adb start-server`
- Check USB connection and drivers

### Multiple Devices Connected
- The test requires exactly one device to be connected
- Disconnect all but one device before running the test
- Use `adb devices` to verify only one device is listed

### Permission Issues
- Ensure `adb root` works on your device
- Some devices may require unlocked bootloader for root access

### Missing Statistics
- Verify debugfs is mounted: `adb shell mount | grep debugfs`
- Check if qcom_stats are available: `adb shell ls /sys/kernel/debug/qcom_stats/`

## Notes
- The test uses a 30-second suspend duration by default
- A 40-second timeout is used to wait for device resume
- All commands are executed remotely via ADB
- The test is non-destructive and safe to run multiple times
- Debug statistics collection is best-effort and won't fail the test if unavailable

## License
SPDX-License-Identifier: BSD-3-Clause-Clear
