#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Robustly find and source init_env
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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="cma"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "================================================================================"
log_info "============ Starting $TESTNAME Testcase ======================================="
log_info "================================================================================"

pass=true

log_info "=== CMA Kernel Configuration Validation ==="

# Core CMA configs
CORE_CMA_CONFIGS="CONFIG_CMA CONFIG_DMA_CMA CONFIG_CMA_DEBUG CONFIG_CMA_DEBUGFS"

if ! check_kernel_config "$CORE_CMA_CONFIGS"; then
    log_fail "CMA kernel configuration not enabled"
    pass=false
else
    log_pass "CMA kernel configuration validated"
fi

OPTIONAL_CMA_CONFIGS="CONFIG_CMA_SIZE_MBYTES CONFIG_CMA_SIZE_SEL_MBYTES CONFIG_CMA_AREAS"

log_info "Checking optional CMA configurations..."
for cfg in $OPTIONAL_CMA_CONFIGS; do
    if check_kernel_config "$cfg" 2>/dev/null; then
        value=$(grep "^$cfg=" /proc/config.gz 2>/dev/null | cut -d'=' -f2 || echo "enabled")
        log_info "  $cfg: $value"
    else
        log_info "  $cfg: not set (optional)"
    fi
done

log_info "=== CMA Memory Statistics ==="

if [ -f "/proc/meminfo" ]; then
    if grep -q "CmaTotal" /proc/meminfo; then
        cma_total=$(grep "CmaTotal" /proc/meminfo | awk '{print $2}')
        cma_free=$(grep "CmaFree" /proc/meminfo | awk '{print $2}')
        cma_used=$((cma_total - cma_free))
        
        # Convert to MB for readability
        cma_total_mb=$((cma_total / 1024))
        cma_free_mb=$((cma_free / 1024))
        cma_used_mb=$((cma_used / 1024))
        
        log_info "CMA Memory Statistics:"
        log_info "  Total: ${cma_total_mb} MB (${cma_total} kB)"
        log_info "  Free:  ${cma_free_mb} MB (${cma_free} kB)"
        log_info "  Used:  ${cma_used_mb} MB (${cma_used} kB)"
        
        # Calculate usage percentage
        if [ "$cma_total" -gt 0 ]; then
            usage_percent=$((cma_used * 100 / cma_total))
            log_info "  Usage: ${usage_percent}%"
        fi
        
        if [ "$cma_total" -lt 1024 ]; then
            log_fail "CMA total size is very small (< 1 MB)"
			pass=false
        else
            log_pass "CMA memory statistics validated"
        fi
    else
        log_fail "CMA statistics not found in /proc/meminfo"
        pass=false
    fi
else
    log_fail "/proc/meminfo not accessible"
    pass=false
fi

if [ -d "/proc/device-tree/reserved-memory" ]; then
    region_count=0
    for region in /proc/device-tree/reserved-memory/*; do
        if [ -d "$region" ]; then
            region_count=$((region_count + 1))
        fi
    done
    log_info "Total reserved memory regions: $region_count"
fi

log_info "=== CMA Initialization and Runtime ==="

# Check dmesg for CMA initialization
if dmesg | grep -i -q "cma.*reserved"; then
    log_pass "CMA initialization messages found in dmesg:"
    
    dmesg | grep -i "cma.*reserved" | tail -n 5 | while IFS= read -r line; do
        log_info "  $line"
    done
else
    log_fail "No CMA initialization messages found in dmesg"
	pass=false
fi

if dmesg | grep -i -q "cma.*alloc\|cma.*release"; then
    log_info "CMA allocation/release activity detected"
    alloc_count=$(dmesg | grep -i -c "cma.*alloc" || echo 0)
    release_count=$(dmesg | grep -i -c "cma.*release" || echo 0)
    log_info "  Allocations: $alloc_count"
    log_info "  Releases: $release_count"
fi

if dmesg | grep -i "cma" | grep -i -q "error\|fail\|warn"; then
    log_fail "CMA warnings/errors found in dmesg:"
	pass=false
    dmesg | grep -i "cma" | grep -i "error\|fail\|warn" | tail -n 3 | while IFS= read -r line; do
        log_warn "  $line"
    done
fi

log_info "=== CMA Sysfs/Debugfs Interface ==="

if [ -d "/sys/kernel/debug/cma" ]; then
    log_info "Found CMA debugfs: /sys/kernel/debug/cma"
    
    # List CMA areas
    if [ -d "/sys/kernel/debug/cma" ]; then
        cma_area_count=0
        for area in /sys/kernel/debug/cma/*; do
            if [ -d "$area" ]; then
                area_name=$(basename "$area")
                log_info "  CMA area: $area_name"
                cma_area_count=$((cma_area_count + 1))
            fi
        done
        log_info "  Total CMA areas: $cma_area_count"
    fi
else
    log_warn "CMA debugfs not found (may need debugfs mounted)"
fi

if [ -f "/proc/vmstat" ]; then
    if grep -q "cma" /proc/vmstat; then
        log_pass "CMA statistics in /proc/vmstat:"
        grep "cma" /proc/vmstat | while IFS= read -r line; do
            log_info "  $line"
        done
	else
		log_fail "CMA statistics not found in /proc/vmstat:"
		pass=false
    fi
fi

log_info "================================================================================"

if $pass; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
