# DMA-BUF Heap Kselftest Test

## Overview

This test runs the `dmabuf-heap` binary from the Linux kernel selftests suite to validate DMA-BUF heap functionality. The test executes the kselftest binary, parses its TAP (Test Anything Protocol) output, and determines pass/fail based on the results.

## What is dmabuf-heap kselftest?

The `dmabuf-heap` kselftest is part of the Linux kernel's self-testing framework. It validates:
- DMA-BUF heap allocation and importing
- Buffer zeroing behavior
- Compatibility with older/newer allocation methods
- Error handling for invalid operations
- Integration with VGEM (Virtual GEM) driver

## Test Coverage

### 1. Binary Validation
- Checks if dmabuf-heap binary exists at specified path
- Verifies binary has execute permissions

### 2. Test Execution
- Runs the dmabuf-heap kselftest binary
- Captures all output (stdout and stderr)
- Displays complete test output in logs

### 3. TAP Output Parsing
- Parses TAP format output
- Extracts test counts (pass/fail/skip/error)
- Identifies skipped tests and reasons

### 4. Result Determination
- Marks test as PASS if no failures or errors
- Marks test as FAIL if any test fails or errors occur
- Reports skipped tests as warnings (not failures)

## Usage

### Default Usage (uses default path):
```bash
cd /path/to/Runner/suites/Kernel/Baseport/dmabuf_heap_kselftest
./run.sh
```

This uses the default binary path: `/kselftest/dmabuf-heaps/dmabuf-heap`

### Custom Binary Path:
```bash
cd /path/to/Runner/suites/Kernel/Baseport/dmabuf_heap_kselftest
./run.sh /custom/path/to/dmabuf-heap
```

### Via Test Runner:
```bash
cd /path/to/Runner
./run-test.sh dmabuf_heap_kselftest
```

## Test Results

Generates:
- `dmabuf_heap_kselftest.res` - Final result (PASS/FAIL)
- Console output with complete test execution details

## Prerequisites

### Required:
- `dmabuf-heap` binary from kernel selftests
- DMA-BUF heap support in kernel (`CONFIG_DMA_HEAP`)
- Execute permissions on the binary

### Optional:
- VGEM driver (`CONFIG_DRM_VGEM`) - for import/export tests
- CMA support (`CONFIG_DMA_CMA`) - for contiguous allocations

## Expected Output

### Successful Test Run:
```
[INFO] 1970-01-01 10:20:21 - ================================================================================
[INFO] 1970-01-01 10:20:21 - ============ Starting dmabuf_heap_kselftest Testcase =======================================
[INFO] 1970-01-01 10:20:21 - ================================================================================
[INFO] 1970-01-01 10:20:21 - DMA-BUF Heap Kselftest Binary Path: /kselftest/dmabuf-heaps/dmabuf-heap
[INFO] 1970-01-01 10:20:21 - === Checking for dmabuf-heap binary ===
[PASS] 1970-01-01 10:20:21 - dmabuf-heap binary found and executable
[INFO] 1970-01-01 10:20:21 - === Running dmabuf-heap kselftest ===
[INFO] 1970-01-01 10:20:21 - Executing: /kselftest/dmabuf-heaps/dmabuf-heap
[INFO] 1970-01-01 10:20:21 - Test output:
[INFO] 1970-01-01 10:20:21 - ----------------------------------------
[INFO] 1970-01-01 10:20:21 - TAP version 13
[INFO] 1970-01-01 10:20:21 - 1..11
[INFO] 1970-01-01 10:20:21 - # Testing heap: system
[INFO] 1970-01-01 10:20:21 - # =======================================
[INFO] 1970-01-01 10:20:21 - # Testing allocation and importing:
[INFO] 1970-01-01 10:20:21 - ok 1 # SKIP Could not open vgem -1
[INFO] 1970-01-01 10:20:21 - ok 2 test_alloc_and_import dmabuf sync succeeded
[INFO] 1970-01-01 10:20:21 - # Testing alloced 4k buffers are zeroed:
[INFO] 1970-01-01 10:20:21 - ok 3 Allocate and fill a bunch of buffers
[INFO] 1970-01-01 10:20:21 - ok 4 Allocate and validate all buffers are zeroed
[INFO] 1970-01-01 10:20:21 - # Testing alloced 1024k buffers are zeroed:
[INFO] 1970-01-01 10:20:21 - ok 5 Allocate and fill a bunch of buffers
[INFO] 1970-01-01 10:20:21 - ok 6 Allocate and validate all buffers are zeroed
[INFO] 1970-01-01 10:20:21 - # Testing (theoretical) older alloc compat:
[INFO] 1970-01-01 10:20:21 - ok 7 dmabuf_heap_alloc_older
[INFO] 1970-01-01 10:20:21 - # Testing (theoretical) newer alloc compat:
[INFO] 1970-01-01 10:20:21 - ok 8 dmabuf_heap_alloc_newer
[INFO] 1970-01-01 10:20:21 - # Testing expected error cases:
[INFO] 1970-01-01 10:20:21 - ok 9 Error expected on invalid fd -1
[INFO] 1970-01-01 10:20:21 - ok 10 Error expected on invalid heap flags -1
[INFO] 1970-01-01 10:20:21 - ok 11 Error expected on invalid heap flags -1
[INFO] 1970-01-01 10:20:21 - # 1 skipped test(s) detected. Consider enabling relevant config options to improve coverage.
[INFO] 1970-01-01 10:20:21 - # Totals: pass:10 fail:0 xfail:0 xpass:0 skip:1 error:0
[INFO] 1970-01-01 10:20:21 - ----------------------------------------
[INFO] 1970-01-01 10:20:21 - Test summary: # Totals: pass:10 fail:0 xfail:0 xpass:0 skip:1 error:0
[INFO] 1970-01-01 10:20:21 -   Passed:  10
[INFO] 1970-01-01 10:20:21 -   Failed:  0
[INFO] 1970-01-01 10:20:21 -   Skipped: 1
[INFO] 1970-01-01 10:20:21 -   Errors:  0
[WARN] 1970-01-01 10:20:21 - 1 test(s) were skipped
[INFO] 1970-01-01 10:20:21 - Consider enabling relevant config options to improve coverage
[PASS] 1970-01-01 10:20:21 - All tests passed successfully (10 passed, 1 skipped)
[PASS] 1970-01-01 10:20:21 - dmabuf_heap_kselftest : Test Passed
```


## Test Details

### Test 1: Allocation and Importing
- Tests basic DMA-BUF allocation
- Tests importing buffers between devices
- Requires VGEM driver (skipped if not available)

### Test 2-6: Buffer Zeroing
- Validates that newly allocated buffers are zeroed
- Tests with different buffer sizes (4KB, 1024KB)
- Ensures no data leakage from previous allocations

### Test 7-8: Compatibility Tests
- Tests backward compatibility with older allocation methods
- Tests forward compatibility with newer allocation methods
- Ensures API stability

### Test 9-11: Error Handling
- Tests invalid file descriptor handling
- Tests invalid heap flags
- Ensures proper error reporting

## Troubleshooting

### Binary Not Found
**Error**: `dmabuf-heap binary not found at: /kselftest/dmabuf-heaps/dmabuf-heap`

**Solutions**:
1. Verify kselftest is installed on the system
2. Check the actual location of the binary:
   ```bash
   find / -name dmabuf-heap 2>/dev/null
   ```
3. Provide correct path as argument:
   ```bash
   ./run.sh /actual/path/to/dmabuf-heap
   ```

### Binary Not Executable
**Error**: `dmabuf-heap binary is not executable`

**Solution**:
```bash
chmod +x /kselftest/dmabuf-heaps/dmabuf-heap
```

### VGEM Tests Skipped
**Warning**: `ok 1 # SKIP Could not open vgem -1`

**Cause**: VGEM driver not loaded or not available

**Solution** (optional - not required for test to pass):
```bash
# Load VGEM module
modprobe vgem

# Or enable in kernel config
CONFIG_DRM_VGEM=m
```

### No DMA Heaps Available
**Error**: Test fails with heap enumeration errors

**Solution**: Enable DMA heap support in kernel:
```
CONFIG_DMA_HEAP=y
CONFIG_DMA_CMA=y
```

## Building dmabuf-heap Binary

If the binary is not available, you can build it from kernel sources:

```bash
# Navigate to kernel source
cd /path/to/linux

# Build dmabuf-heaps selftests
make -C tools/testing/selftests/dmabuf-heaps

# Binary will be at:
# tools/testing/selftests/dmabuf-heaps/dmabuf-heap
```

## Kernel Config Requirements

### Mandatory:
```
CONFIG_DMA_SHARED_BUFFER=y
CONFIG_DMA_HEAP=y
```

### Recommended:
```
CONFIG_DMA_CMA=y
CONFIG_DRM_VGEM=m  # For import/export tests
```

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
