# kms_setmode Test

## Overview
The kms_setmode test is an IGT (Intel GPU Tools) test that validates mode setting functionality in the KMS (Kernel Mode Setting) display subsystem. This test verifies the kernel's ability to set and switch between different display modes.

## Test Description
This test validates:
- Display mode setting operations
- Mode switching between different resolutions and refresh rates
- Multi-monitor mode configuration
- Display pipeline configuration
- CRTC (Cathode Ray Tube Controller) and connector management
- Mode validation and compatibility checking

## Prerequisites
- IGT GPU tools must be installed on the target device
- Display hardware must be available and connected
- Weston compositor will be stopped during test execution

## Usage

### Basic Usage (Default)
```bash
./run-test.sh kms_setmode
```
The test will automatically use the binary at `/usr/libexec/igt-gpu-tools/kms_setmode`

### With Custom Binary Path
```bash
./run-test.sh kms_setmode --kms-setmode-path /custom/path/to/kms_setmode
```

Or:
```bash
./run-test.sh kms_setmode /custom/path/to/kms_setmode
```

### Help
```bash
cd Runner/suites/Multimedia/Display/igt-gpu-tools/kms_setmode
./run.sh --help
```

## Test Results
The test generates:
- **Result file**: `kms_setmode.res` - Contains PASS/FAIL/SKIP status
- **Log file**: `kms_setmode_log.txt` - Contains detailed test output

## Expected Behavior
- **PASS**: All subtests succeed or some subtests succeed with others skipped
- **SKIP**: All subtests are skipped (e.g., when display hardware is not available)
- **FAIL**: One or more subtests fail or the test exits with a non-zero code

## Common Issues
1. **No Display Connected**: The test requires an active display connection. Ensure a monitor is connected.

2. **Mode Not Supported**: Some display modes may not be supported by the hardware or monitor. This will result in test skips for those specific modes.

3. **Display Flicker**: During mode switching tests, you may observe brief display flicker or blanking. This is expected behavior.

4. **Binary Not Found**: Ensure IGT GPU tools are installed:
   ```bash
   # Check if binary exists
   ls -l /usr/libexec/igt-gpu-tools/kms_setmode
   ```

## Test Coverage
The test typically covers:
- Single display mode setting
- Multiple display configurations
- Mode switching sequences
- Invalid mode rejection
- Display pipeline state validation

## Notes
- The test automatically stops Weston before execution
- Mode setting tests may cause brief display disruptions
- Test output is parsed for SUCCESS, FAIL, and SKIP counts
- The test validates both successful mode sets and proper error handling for invalid modes
- Results may vary based on display hardware capabilities and connected monitors
