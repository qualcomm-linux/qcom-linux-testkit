# kms_sysfs_edid_timing Test

## Overview
The kms_sysfs_edid_timing test is an IGT (Intel GPU Tools) test that validates EDID (Extended Display Identification Data) timing information exposed through the sysfs interface. This test verifies the kernel's ability to correctly parse and expose display timing information.

## Test Description
This test validates:
- EDID data parsing and exposure via sysfs
- Display timing information accuracy
- Sysfs interface for EDID access
- Display mode information retrieval
- Monitor capability detection

## Prerequisites
- IGT GPU tools must be installed on the target device
- Display hardware must be available and connected
- A monitor with valid EDID data must be connected
- Weston compositor will be stopped during test execution

## Usage

### Basic Usage (Default)
```bash
./run-test.sh kms_sysfs_edid_timing
```
The test will automatically use the binary at `/usr/libexec/igt-gpu-tools/kms_sysfs_edid_timing`

### With Custom Binary Path
```bash
./run-test.sh kms_sysfs_edid_timing --kms-sysfs-edid-timing-path /custom/path/to/kms_sysfs_edid_timing
```

Or:
```bash
./run-test.sh kms_sysfs_edid_timing /custom/path/to/kms_sysfs_edid_timing
```

### Help
```bash
cd Runner/suites/Multimedia/Display/igt-gpu-tools/kms_sysfs_edid_timing
./run.sh --help
```

## Test Results
The test generates:
- **Result file**: `kms_sysfs_edid_timing.res` - Contains PASS/FAIL/SKIP status
- **Log file**: `kms_sysfs_edid_timing_log.txt` - Contains detailed test output

## Expected Behavior
- **PASS**: All subtests succeed or some subtests succeed with others skipped
- **SKIP**: All subtests are skipped (e.g., when no display is connected or EDID is not available)
- **FAIL**: One or more subtests fail or the test exits with a non-zero code

## Common Issues
1. **No Display Connected**: The test requires a monitor with valid EDID data. Ensure a display is properly connected.

2. **EDID Not Available**: Some displays may not provide EDID data or the data may be corrupted. This will result in test skips.

3. **Sysfs Access**: Ensure the sysfs interface is accessible and properly mounted:
   ```bash
   # Check sysfs DRM entries
   ls -l /sys/class/drm/
   ```

4. **Binary Not Found**: Ensure IGT GPU tools are installed:
   ```bash
   # Check if binary exists
   ls -l /usr/libexec/igt-gpu-tools/kms_sysfs_edid_timing
   ```

## Notes
- The test automatically stops Weston before execution
- EDID data is display-specific and test results may vary based on the connected monitor
- Test output is parsed for SUCCESS, FAIL, and SKIP counts
- This test is non-destructive and only reads EDID information
