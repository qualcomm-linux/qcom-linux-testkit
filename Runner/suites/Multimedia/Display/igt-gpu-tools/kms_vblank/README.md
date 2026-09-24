# kms_vblank Test

## Overview
The kms_vblank test is an IGT (Intel GPU Tools) test that validates vertical blanking (VBLANK) functionality in the KMS (Kernel Mode Setting) display subsystem. This test verifies the kernel's ability to handle VBLANK events and timing.

## Test Description
This test validates:
- VBLANK event generation and handling
- VBLANK timing accuracy
- VBLANK synchronization across multiple pipes
- VBLANK wait operations
- Display refresh timing

## Prerequisites
- IGT GPU tools must be installed on the target device
- Display hardware must be available and connected
- Weston compositor will be stopped during test execution

## Usage

### Basic Usage (Default)
```bash
./run-test.sh kms_vblank
```
The test will automatically use the binary at `/usr/libexec/igt-gpu-tools/kms_vblank` with default subtest filtering.

**Default Arguments**: `--run-subtest '*,!*suspend*,!*rpm*'`
- Runs all subtests except those related to suspend and runtime power management
- These subtests are excluded to prevent hanging or system instability

### With Custom Binary Path
```bash
./run-test.sh kms_vblank --kms-vblank-path /custom/path/to/kms_vblank
```

### With Custom Subtest Filter
```bash
./run-test.sh kms_vblank --run-subtest 'pipe-A-*'
```

### Help
```bash
cd Runner/suites/Multimedia/Display/igt-gpu-tools/kms_vblank
./run.sh --help
```

## Test Results
The test generates:
- **Result file**: `kms_vblank.res` - Contains PASS/FAIL/SKIP status
- **Log file**: `kms_vblank_log.txt` - Contains detailed test output

## Expected Behavior
- **PASS**: All subtests succeed or some subtests succeed with others skipped
- **SKIP**: All subtests are skipped (e.g., when display hardware is not available)
- **FAIL**: One or more subtests fail or the test exits with a non-zero code

## Subtest Filtering
The default subtest filter excludes:
- `*suspend*` - Suspend-related tests that may hang the system
- `*rpm*` - Runtime power management tests that may cause issues

This filtering ensures the test runs reliably without hanging. You can override this with the `--run-subtest` parameter if needed.

## Common Issues
1. **Test Hangs**: If the test hangs, ensure you're using the default subtest filter which excludes problematic tests.

2. **No Display Connected**: The test requires an active display connection. Ensure a monitor is connected.

3. **Binary Not Found**: Ensure IGT GPU tools are installed:
   ```bash
   # Check if binary exists
   ls -l /usr/libexec/igt-gpu-tools/kms_vblank
   ```

## Notes
- The test automatically stops Weston before execution
- VBLANK tests are timing-sensitive and may show variations based on display refresh rate
- Test output is parsed for SUCCESS, FAIL, and SKIP counts
- The default subtest filter is recommended for automated testing
