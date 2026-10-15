# dmabuf Test

## Overview
The dmabuf test is an IGT (Intel GPU Tools) test that validates DMA-BUF (Direct Memory Access Buffer) functionality in the display subsystem. This test verifies the kernel's ability to handle DMA-BUF operations for graphics memory sharing.

## Test Description
This test validates:
- DMA-BUF allocation and management
- Memory sharing between different subsystems
- Buffer import/export operations
- Kernel selftests for DMA-BUF functionality

## Prerequisites
- IGT GPU tools must be installed on the target device
- Display hardware must be available
- Weston compositor will be stopped during test execution

## Usage

### Basic Usage (Default)
```bash
./run-test.sh dmabuf
```
The test will automatically use the binary at `/usr/libexec/igt-gpu-tools/dmabuf`

### With Custom Binary Path
```bash
./run-test.sh dmabuf --dmabuf-path /custom/path/to/dmabuf
```

Or:
```bash
./run-test.sh dmabuf /custom/path/to/dmabuf
```

### Help
```bash
cd Runner/suites/Multimedia/Display/igt-gpu-tools/dmabuf
./run.sh --help
```

## Test Results
The test generates:
- **Result file**: `dmabuf.res` - Contains PASS/FAIL/SKIP status
- **Log file**: `dmabuf_log.txt` - Contains detailed test output

## Expected Behavior
- **PASS**: All subtests succeed or some subtests succeed with others skipped
- **SKIP**: All subtests are skipped (e.g., when kernel selftests are not available)
- **FAIL**: One or more subtests fail or the test exits with a non-zero code

## Common Issues
1. **Test Skipped**: If the test shows "SKIP", it typically means the required kernel selftests are not available on the system. This is not necessarily an error - it indicates the test requirements are not met.

2. **Binary Not Found**: Ensure IGT GPU tools are installed:
   ```bash
   # Check if binary exists
   ls -l /usr/libexec/igt-gpu-tools/dmabuf
   ```

## Notes
- The test automatically stops Weston before execution
- Exit code 77 indicates a SKIP condition (standard IGT behavior)
- Test output is parsed for SUCCESS, FAIL, and SKIP counts
