#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="dmabuf"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "================================================================================"
log_info "============ Starting $TESTNAME Testcase ======================================="
log_info "================================================================================"

if ! check_dependencies "find grep basename"; then
    log_skip "$TESTNAME : Dependency check failed. Skipping."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

pass=true

log_info "=== Kernel Configuration Validation ==="

if [ ! -f /proc/config.gz ]; then
    log_warn "/proc/config.gz not found — kernel config checks will be skipped"
    log_warn "Ensure CONFIG_IKCONFIG and CONFIG_IKCONFIG_PROC are enabled in the kernel"
else
    CORE_CONFIGS="CONFIG_DMA_SHARED_BUFFER CONFIG_DMABUF_HEAPS CONFIG_DMABUF_HEAPS_SYSTEM"

    if ! check_kernel_config "$CORE_CONFIGS"; then
        log_fail "Core DMA-BUF kernel config validation failed"
        pass=false
    else
        log_pass "Core DMA-BUF configs available"
    fi

    OPTIONAL_CONFIGS="CONFIG_TEE_DMABUF_HEAPS CONFIG_HAS_DMA CONFIG_DMA_HEAP CONFIG_DMA_CMA"

    log_info "Checking optional DMA-BUF configurations..."
    for cfg in $OPTIONAL_CONFIGS; do
        if check_optional_config "$cfg" 2>/dev/null; then
            log_pass "  $cfg: enabled"
        else
            log_warn "  $cfg: not enabled (optional)"
        fi
    done
fi

log_info "=== Device Tree Validation ==="

found_nodes=0

if [ -d "/proc/device-tree/reserved-memory" ]; then
    log_info "Found reserved-memory node"
    
    for region in /proc/device-tree/reserved-memory/*; do
        if [ -d "$region" ]; then
            region_name=$(basename "$region")
            log_info "  Region: $region_name"
        fi
    done
fi

if check_dt_nodes "/proc/device-tree/soc*/dma* /proc/device-tree/soc*/qcom,ion* /proc/device-tree/ion*"; then
    log_pass "At least one node was found."
	found_nodes=$((found_nodes + 1))
else
    log_fail "None of the requested nodes were found."
	echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if [ "$found_nodes" -gt 0 ]; then
    log_pass "Device tree validation passed (found $found_nodes relevant nodes)"
else
    log_fail "No DMA-BUF specific device-tree nodes found"
	pass=false
fi

# Check for DMA heap devices
if [ -d "/dev/dma_heap" ]; then
    log_info "Found DMA heap device directory: /dev/dma_heap"
    
    heap_count=0
    for heap in /dev/dma_heap/*; do
        if [ -e "$heap" ]; then
            heap_name=$(basename "$heap")
            log_pass "  Available heap: $heap_name"
            heap_count=$((heap_count + 1))
        fi
    done
    log_pass "Total heaps found: $heap_count"
else
    log_fail "DMA heap device directory not found"
	pass=false
fi

if [ -f "/sys/kernel/debug/dma_buf/bufinfo" ]; then
    log_info "DMA-BUF buffer information:"
    
    # Count total buffers
    total_bufs=$(grep -c "^Dma-buf" /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null || echo 0)
    log_info "  Total DMA-BUF buffers: $total_bufs"
    
    # Calculate total size (if available)
    if grep -q "size:" /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null; then
        total_size=$(awk '/size:/ {sum+=$2} END {print sum}' /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null || echo 0)
        total_size_mb=$((total_size / 1024 / 1024))
        log_info "  Total DMA-BUF memory: ${total_size_mb} MB"
    fi
else
    log_warn "DMA-BUF bufinfo not available (debugfs may not be mounted)"
fi

if $pass; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0