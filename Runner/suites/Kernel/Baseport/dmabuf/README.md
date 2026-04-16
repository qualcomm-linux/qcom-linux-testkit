# DMA-BUF Configuration Validation Test

## Overview

This test validates the DMA-BUF subsystem configuration on Qualcomm platforms, including kernel configuration, device tree setup, and system interfaces.

## Test Coverage

### 1. Kernel Configuration Validation
**Mandatory**:
- `CONFIG_DMA_SHARED_BUFFER CONFIG_DMABUF_HEAPS CONFIG_DMABUF_HEAPS_SYSTEM` - Core DMA-BUF support

**Optional but Recommended**:
- `CONFIG_DMA_HEAP` - Modern DMA heap interface
- `CONFIG_DMA_CMA` - Contiguous Memory Allocator
- `CONFIG_TEE_DMABUF_HEAPS` 
- `CONFIG_HAS_DMA`

### 2. Device Tree Validation
- Reserved memory nodes (`/proc/device-tree/reserved-memory`) - informational
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
[INFO] 2026-03-23 12:39:05 - ================================================================================
[INFO] 2026-03-23 12:39:05 - ============ Starting dmabuf Testcase =======================================
[INFO] 2026-03-23 12:39:05 - ================================================================================
[INFO] 2026-03-23 12:39:05 - === Kernel Configuration Validation ===
[PASS] 2026-03-23 12:39:05 - Kernel config CONFIG_DMA_SHARED_BUFFER is enabled
[PASS] 2026-03-23 12:39:05 - Kernel config CONFIG_DMABUF_HEAPS is enabled
[PASS] 2026-03-23 12:39:06 - Kernel config CONFIG_DMABUF_HEAPS_SYSTEM is enabled
[PASS] 2026-03-23 12:39:06 - Core DMA-BUF configs available
[INFO] 2026-03-23 12:39:06 - Checking optional DMA-BUF configurations...
[PASS] 2026-03-23 12:39:06 - Kernel config CONFIG_TEE_DMABUF_HEAPS is enabled
[PASS] 2026-03-23 12:39:06 -   CONFIG_TEE_DMABUF_HEAPS: enabled
[PASS] 2026-03-23 12:39:06 - Kernel config CONFIG_HAS_DMA is enabled
[PASS] 2026-03-23 12:39:06 -   CONFIG_HAS_DMA: enabled
[WARN] 2026-03-23 12:39:06 - Kernel config CONFIG_DMA_HEAP is missing or not enabled
[WARN] 2026-03-23 12:39:06 -   CONFIG_DMA_HEAP: not enabled (optional)
[WARN] 2026-03-23 12:39:06 - Kernel config CONFIG_DMA_CMA is missing or not enabled
[WARN] 2026-03-23 12:39:06 -   CONFIG_DMA_CMA: not enabled (optional)
[INFO] 2026-03-23 12:39:06 - === Device Tree Validation ===
[INFO] 2026-03-23 12:39:06 - Found reserved-memory node
[INFO] 2026-03-23 12:39:06 -   Region: adsp-region@95c00000
[INFO] 2026-03-23 12:39:06 -   Region: adsp-rpc-remote-heap-region@94a00000
[INFO] 2026-03-23 12:39:06 -   Region: aop-cmd-db-region@90860000
[INFO] 2026-03-23 12:39:06 -   Region: aop-image-region@90800000
[INFO] 2026-03-23 12:39:06 -   Region: camera-region@95200000
[INFO] 2026-03-23 12:39:06 -   Region: cdsp-region@99980000
[INFO] 2026-03-23 12:39:06 -   Region: cvp-region@9b782000
[INFO] 2026-03-23 12:39:06 -   Region: gpdsp-region@97b00000
[INFO] 2026-03-23 12:39:06 -   Region: gpu-microcode-region@9b780000
[INFO] 2026-03-23 12:39:06 -   Region: lpass-machine-learning-region@93b00000
[INFO] 2026-03-23 12:39:06 -   Region: q6-adsp-dtb-region@97a00000
[INFO] 2026-03-23 12:39:06 -   Region: q6-cdsp-dtb-region@99900000
[INFO] 2026-03-23 12:39:06 -   Region: q6-gpdsp-dtb-region@97a80000
[INFO] 2026-03-23 12:39:06 -   Region: smem@90900000
[INFO] 2026-03-23 12:39:06 -   Region: video-region@9be82000
[INFO] 2026-03-23 12:39:06 - /proc/device-tree/soc*/dma* /proc/device-tree/soc*/qcom,ion* /proc/device-tree/ion*
[INFO] 2026-03-23 12:39:06 - /proc/device-tree/soc@0/dma-controller@1dc4000
[PASS] 2026-03-23 12:39:06 - Device tree node exists: /proc/device-tree/soc@0/dma-controller@1dc4000
[INFO] 2026-03-23 12:39:06 - /proc/device-tree/soc@0/dma-controller@900000
[PASS] 2026-03-23 12:39:06 - Device tree node exists: /proc/device-tree/soc@0/dma-controller@900000
[INFO] 2026-03-23 12:39:06 - /proc/device-tree/soc@0/dma-controller@a00000
[PASS] 2026-03-23 12:39:06 - Device tree node exists: /proc/device-tree/soc@0/dma-controller@a00000
[INFO] 2026-03-23 12:39:06 - /proc/device-tree/soc@0/dma-controller@b00000
[PASS] 2026-03-23 12:39:06 - Device tree node exists: /proc/device-tree/soc@0/dma-controller@b00000
[INFO] 2026-03-23 12:39:06 - /proc/device-tree/soc*/qcom,ion*
[INFO] 2026-03-23 12:39:06 - /proc/device-tree/ion*
[PASS] 2026-03-23 12:39:06 - At least one node was found.
[PASS] 2026-03-23 12:39:06 - Device tree validation passed (found 1 relevant nodes)
[INFO] 2026-03-23 12:39:06 - Found DMA heap device directory: /dev/dma_heap
[PASS] 2026-03-23 12:39:06 -   Available heap: system
[PASS] 2026-03-23 12:39:06 - Total heaps found: 1
[INFO] 2026-03-23 12:39:06 - DMA-BUF buffer information:
[INFO] 2026-03-23 12:39:06 -   Total DMA-BUF buffers: 1
[PASS] 2026-03-23 12:39:06 - dmabuf : Test Passed
[INFO] 2026-03-23 12:39:06 - -------------------Completed dmabuf Testcase----------------------------
```

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
