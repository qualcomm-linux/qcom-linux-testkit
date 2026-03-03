# CMA (Contiguous Memory Allocator) Enablement Test

## Overview

This test validates CMA (Contiguous Memory Allocator) enablement, configuration, and functionality on Qualcomm platforms. CMA is essential for allocating large contiguous memory blocks required by multimedia devices like cameras, displays, and video encoders.

## What is CMA?

CMA (Contiguous Memory Allocator) is a Linux kernel framework that:
- Reserves a pool of physically contiguous memory at boot time
- Allows normal page allocations from this pool when not in use
- Provides large contiguous allocations when needed by devices
- Critical for DMA operations requiring physically contiguous buffers

## Test Coverage

### 1. CMA Kernel Configuration
- **CONFIG_CMA** - Core CMA support (mandatory)
- **CONFIG_DMA_CMA** - Core CMA support (mandatory)
- **CONFIG_CMA_DEBUG** - Core CMA support (mandatory)
- **CONFIG_CMA_DEBUGFS** - Core CMA support (mandatory)
- **CONFIG_CMA_SIZE_MBYTES** - Default CMA size configuration
- **CONFIG_CMA_SIZE_SEL_MBYTES** - CMA size selection method
- **CONFIG_CMA_AREAS** - Maximum number of CMA areas

### 2. CMA Memory Statistics
- Total CMA memory available
- Free CMA memory
- Used CMA memory
- Usage percentage calculation
- Size validation (minimum 1MB)

### 3. CMA Device Tree Configuration
- CMA size from device tree
- CMA alignment properties
- Reserved memory region enumeration

### 4. CMA Initialization and Runtime
- CMA reservation messages in kernel logs
- CMA allocation/release activity
- Error and warning detection
- Runtime behavior validation

### 5. CMA Sysfs/Debugfs Interface
- CMA debugfs (`/sys/kernel/debug/cma`)
- CMA area enumeration
- Per-area allocation statistics
- CMA statistics in `/proc/vmstat`

## Usage

### Run directly:
```bash
cd /path/to/Runner/suites/Kernel/Baseport/cma
./run.sh
```

### Run via test runner:
```bash
cd /path/to/Runner
./run-test.sh cma
```

## Test Results

Generates:
- `cma.res` - Final result (PASS/FAIL)
- Console output with detailed CMA information

## Prerequisites

### Required:
- `CONFIG_DMA_CMA=y` `CONFIG_CMA=y` `CONFIG_CMA_DEBUG=y` `CONFIG_CMA_DEBUGFS=y` in kernel configuration
- CMA memory reserved (via device tree or kernel command line)

### Optional:
- Debugfs mounted at `/sys/kernel/debug` (for detailed statistics)
- Root or appropriate permissions

## Expected Output

```
[INFO] 1980-01-06 00:18:47 - ================================================================================
[INFO] 1980-01-06 00:18:47 - ============ Starting cma Testcase =======================================
[INFO] 1980-01-06 00:18:47 - ================================================================================
[INFO] 1980-01-06 00:18:47 - === CMA Kernel Configuration Validation ===
[PASS] 1980-01-06 00:18:47 - Kernel config CONFIG_CMA is enabled
[PASS] 1980-01-06 00:18:47 - Kernel config CONFIG_DMA_CMA is enabled
[PASS] 1980-01-06 00:18:47 - Kernel config CONFIG_CMA_DEBUG is enabled
[PASS] 1980-01-06 00:18:47 - Kernel config CONFIG_CMA_DEBUGFS is enabled
[PASS] 1980-01-06 00:18:47 - CMA kernel configuration validated
[INFO] 1980-01-06 00:18:47 - Checking optional CMA configurations...
[FAIL] 1980-01-06 00:18:47 - Kernel config CONFIG_CMA_SIZE_MBYTES is missing or not enabled
[INFO] 1980-01-06 00:18:47 -   CONFIG_CMA_SIZE_MBYTES: not set (optional)
[PASS] 1980-01-06 00:18:47 - Kernel config CONFIG_CMA_SIZE_SEL_MBYTES is enabled
[INFO] 1980-01-06 00:18:47 -   CONFIG_CMA_SIZE_SEL_MBYTES:
[FAIL] 1980-01-06 00:18:48 - Kernel config CONFIG_CMA_AREAS is missing or not enabled
[INFO] 1980-01-06 00:18:48 -   CONFIG_CMA_AREAS: not set (optional)
[INFO] 1980-01-06 00:18:48 - === CMA Memory Statistics ===
[INFO] 1980-01-06 00:18:48 - CMA Memory Statistics:
[INFO] 1980-01-06 00:18:48 -   Total: 172 MB (176128 kB)
[INFO] 1980-01-06 00:18:48 -   Free:  119 MB (122548 kB)
[INFO] 1980-01-06 00:18:48 -   Used:  52 MB (53580 kB)
[INFO] 1980-01-06 00:18:48 -   Usage: 30%
[PASS] 1980-01-06 00:18:48 - CMA memory statistics validated
[INFO] 1980-01-06 00:18:48 - Total reserved memory regions: 32
[INFO] 1980-01-06 00:18:48 - === CMA Initialization and Runtime ===
[PASS] 1980-01-06 00:18:48 - CMA initialization messages found in dmesg:
[INFO] 1980-01-06 00:18:48 -   [   17.510276] cma: cma_alloc(cma ffffffc0823f1b38, name: reserved, count 2, align 1)
[INFO] 1980-01-06 00:18:48 -   [   17.924390] cma: cma_alloc(cma ffffffc0823f1b38, name: reserved, count 32, align 5)
[INFO] 1980-01-06 00:18:48 -   [   17.935579] cma: cma_alloc(cma ffffffc0823f1b38, name: reserved, count 128, align 7)
[INFO] 1980-01-06 00:18:48 -   [   18.501219] cma: cma_alloc(cma ffffffc0823f1b38, name: reserved, count 2, align 1)
[INFO] 1980-01-06 00:18:48 - CMA allocation/release activity detected
[INFO] 1980-01-06 00:18:48 -   Allocations: 42
[INFO] 1980-01-06 00:18:48 -   Releases: 8
[INFO] 1980-01-06 00:18:48 - === CMA Sysfs/Debugfs Interface ===
[INFO] 1980-01-06 00:18:48 - Found CMA debugfs: /sys/kernel/debug/cma
[INFO] 1980-01-06 00:18:48 -   CMA area: reserved
[INFO] 1980-01-06 00:18:48 -   Total CMA areas: 1
[PASS] 1980-01-06 00:18:48 - CMA statistics in /proc/vmstat:
[INFO] 1980-01-06 00:18:48 -   nr_free_cma 30637
[INFO] 1980-01-06 00:18:48 -   cma_alloc_success 21
[INFO] 1980-01-06 00:18:48 -   cma_alloc_fail 0
[INFO] 1980-01-06 00:18:48 - ================================================================================
[PASS] 1980-01-06 00:18:48 - cma : Test Passed
```

## CMA Configuration Methods

### 1. Device Tree Configuration (Recommended)
```dts
reserved-memory {
    #address-cells = <2>;
    #size-cells = <2>;
    ranges;

    linux,cma {
        compatible = "shared-dma-pool";
        reusable;
        size = <0x0 0x20000000>;  /* 512 MB */
        alignment = <0x0 0x00400000>;  /* 4 MB */
        linux,cma-default;
    };
};
```

### 2. Kernel Command Line
```bash
cma=512M
```

### 3. Kernel Config Default
```
CONFIG_CMA_SIZE_MBYTES=512
```



## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
