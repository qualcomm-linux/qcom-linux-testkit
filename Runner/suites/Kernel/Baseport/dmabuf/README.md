# DMA-BUF Configuration Validation Test

## Overview

This test validates the DMA-BUF subsystem configuration on Qualcomm platforms, including kernel configuration, device tree setup, and system interfaces.

## Test Coverage

### 1. Kernel Configuration Validation
**Mandatory**:
- `CONFIG_DMA_SHARED_BUFFER CONFIG_DMABUF_HEAPS CONFIG_DMABUF_HEAPS_SYSTEM CONFIG_TEE_DMABUF_HEAPS CONFIG_HAS_DMA` - Core DMA-BUF support

**Optional but Recommended**:
- `CONFIG_DMA_HEAP` - Modern DMA heap interface
- `CONFIG_DMA_CMA` - Contiguous Memory Allocator

### 2. Device Tree Validation
- Reserved memory nodes (`/proc/device-tree/reserved-memory`)
- Platform-specific DMA heap nodes
- Memory region sizes and configurations

## Usage

### Run directly:
```bash
cd /path/to/Runner/suites/Kernel/Baseport/dmabuf
./run.sh
```

### Run via test runner:
```bash
cd /path/to/Runner
./run-test.sh dmabuf
```

## Test Results

Generates:
- `dmabuf.res` - Final result (PASS/FAIL)
- Console output with detailed validation steps

## Prerequisites

### Required:
- `CONFIG_DMA_SHARED_BUFFER=y` in kernel config


## Expected Output

```
[Executing test case: dmabuf] 1970-01-01 09:29:40 -
[INFO] 1970-01-01 09:29:40 - ================================================================================
[INFO] 1970-01-01 09:29:40 - ============ Starting dmabuf Testcase =======================================
[INFO] 1970-01-01 09:29:40 - ================================================================================
[INFO] 1970-01-01 09:29:40 - === Kernel Configuration Validation ===
[PASS] 1970-01-01 09:29:40 - Kernel config CONFIG_DMA_SHARED_BUFFER is enabled
[PASS] 1970-01-01 09:29:41 - Kernel config CONFIG_DMABUF_HEAPS is enabled
[PASS] 1970-01-01 09:29:41 - Kernel config CONFIG_DMABUF_HEAPS_SYSTEM is enabled
[PASS] 1970-01-01 09:29:41 - Kernel config CONFIG_TEE_DMABUF_HEAPS is enabled
[PASS] 1970-01-01 09:29:41 - Kernel config CONFIG_HAS_DMA is enabled
[PASS] 1970-01-01 09:29:41 - Core DMA-BUF configs available
[INFO] 1970-01-01 09:29:41 - Checking optional DMA-BUF configurations...
[FAIL] 1970-01-01 09:29:41 - Kernel config CONFIG_DMA_HEAP is missing or not enabled
[WARN] 1970-01-01 09:29:41 -   CONFIG_DMA_HEAP: not enabled (optional)
[FAIL] 1970-01-01 09:29:41 - Kernel config CONFIG_DMA_CMA is missing or not enabled
[WARN] 1970-01-01 09:29:41 -   CONFIG_DMA_CMA: not enabled (optional)
[INFO] 1970-01-01 09:29:41 - === Device Tree Validation ===
[INFO] 1970-01-01 09:29:41 - Found reserved-memory node
[INFO] 1970-01-01 09:29:41 -   Region: adsp-rpc-remote-heap@9cb80000
[INFO] 1970-01-01 09:29:41 -   Region: adsp@86100000
[INFO] 1970-01-01 09:29:41 -   Region: aop-cmd-db@80860000
[INFO] 1970-01-01 09:29:41 -   Region: aop@80800000
[INFO] 1970-01-01 09:29:41 -   Region: camera@84300000
[INFO] 1970-01-01 09:29:41 -   Region: cdsp-secure-heap@81800000
[INFO] 1970-01-01 09:29:41 -   Region: cdsp@88900000
[INFO] 1970-01-01 09:29:41 -   Region: cpucp@80b00000
[INFO] 1970-01-01 09:29:41 -   Region: cvp@8ae00000
[INFO] 1970-01-01 09:29:41 -   Region: debug-vm@d0600000
[INFO] 1970-01-01 09:29:41 -   Region: gpu-microcode@8b31a000
[INFO] 1970-01-01 09:29:41 -   Region: hyp@80000000
[INFO] 1970-01-01 09:29:41 -   Region: ipa-fw@8b300000
[INFO] 1970-01-01 09:29:41 -   Region: ipa-gsi@8b310000
[INFO] 1970-01-01 09:29:41 -   Region: mpss@8b800000
[INFO] 1970-01-01 09:29:41 -   Region: qtee@c1300000
[INFO] 1970-01-01 09:29:41 -   Region: sec-apps@808ff000
[INFO] 1970-01-01 09:29:41 -   Region: smem@80900000
[INFO] 1970-01-01 09:29:41 -   Region: tags@c0100000
[INFO] 1970-01-01 09:29:41 -   Region: trusted-apps@c1800000
[INFO] 1970-01-01 09:29:41 -   Region: tz-stat@c0000000
[INFO] 1970-01-01 09:29:41 -   Region: video@8a700000
[INFO] 1970-01-01 09:29:41 -   Region: wlan-fw@80c00000
[INFO] 1970-01-01 09:29:41 -   Region: wpss@84800000
[INFO] 1970-01-01 09:29:41 -   Region: xbl-uefi-res@80880000
[INFO] 1970-01-01 09:29:41 -   Region: xbl@80700000
[INFO] 1970-01-01 09:29:41 -   Region: zap@8b71a000
[INFO] 1970-01-01 09:29:41 - Found DMA heap node: /proc/device-tree/soc@0/dma-controller@1dc4000
[INFO] 1970-01-01 09:29:41 - Found DMA heap node: /proc/device-tree/soc@0/dma-controller@3a84000
[INFO] 1970-01-01 09:29:41 - Found DMA heap node: /proc/device-tree/soc@0/dma-controller@900000
[INFO] 1970-01-01 09:29:41 - Found DMA heap node: /proc/device-tree/soc@0/dma-controller@a00000
[INFO] 1970-01-01 09:29:41 - Found DMA heap node: /proc/device-tree/soc@0/dma-ranges
[INFO] 1970-01-01 09:29:41 - Found DMA heap node: /proc/device-tree/soc@0/dma@117f000
[PASS] 1970-01-01 09:29:41 - Device tree validation passed (found 6 relevant nodes)
[INFO] 1970-01-01 09:29:41 - Found DMA heap device directory: /dev/dma_heap
[PASS] 1970-01-01 09:29:41 -   Available heap: system
[PASS] 1970-01-01 09:29:41 - Total heaps found: 1
[PASS] 1970-01-01 09:29:41 - dmabuf : Test Passed
[INFO] 1970-01-01 09:29:41 - -------------------Completed dmabuf Testcase----------------------------
```

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
