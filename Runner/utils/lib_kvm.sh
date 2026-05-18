#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Common KVM/virtualization validation helpers.
#
# This library must be sourced after functestlib.sh.
#
# Reuse from functestlib.sh:
# log_info/log_pass/log_fail/log_skip/log_warn
# check_dependencies
# check_kernel_config
# scan_dmesg_errors
# get_kernel_log
# detect_platform
# get_remoteproc_by_firmware, when available
#
# Return-code convention:
# 0 = validation passed / evidence found
# 1 = validation failed
# 2 = validation not applicable or dependency missing; caller should SKIP

# Validate /dev/kvm presence, type, and access permissions.
#
# Returns:
# 0 if /dev/kvm is present, character device, readable, and writable
# 1 if /dev/kvm exists but is not usable
# 2 if /dev/kvm is not present
kvm_check_device_node() {
    if [ ! -e /dev/kvm ]; then
        log_skip "/dev/kvm is not present"
        return 2
    fi

    if [ ! -c /dev/kvm ]; then
        log_fail "/dev/kvm exists but is not a character device"
        return 1
    fi

    if [ ! -r /dev/kvm ]; then
        log_fail "/dev/kvm exists but is not readable"
        return 1
    fi

    if [ ! -w /dev/kvm ]; then
        log_fail "/dev/kvm exists but is not writable"
        return 1
    fi

    log_pass "/dev/kvm is present and accessible"
    return 0
}

# Validate the KVM userspace API through /dev/kvm ioctl calls.
#
# Checks:
# - open("/dev/kvm") succeeds
# - KVM_GET_API_VERSION returns 12
# - KVM_CREATE_VM succeeds
#
# Notes:
# Uses python3 to avoid requiring a compiled helper binary on target.
#
# Returns:
# 0 if KVM API validation passes
# 1 if /dev/kvm API validation fails
# 2 if python3 is unavailable
kvm_check_api_version() {
    if ! command -v python3 >/dev/null 2>&1; then
        log_skip "python3 is not available; cannot run /dev/kvm ioctl API check"
        return 2
    fi

    python3 - <<'PY'
import fcntl
import os
import sys

KVM_GET_API_VERSION = 0xAE00
KVM_CREATE_VM = 0xAE01
EXPECTED_API = 12

try:
    fd = os.open("/dev/kvm", os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
except OSError as exc:
    print("open(/dev/kvm) failed: %s" % exc)
    sys.exit(1)

try:
    api = fcntl.ioctl(fd, KVM_GET_API_VERSION, 0)
except OSError as exc:
    print("KVM_GET_API_VERSION failed: %s" % exc)
    os.close(fd)
    sys.exit(1)

if api != EXPECTED_API:
    print("Unexpected KVM API version: got=%s expected=%s" % (api, EXPECTED_API))
    os.close(fd)
    sys.exit(1)

try:
    vmfd = fcntl.ioctl(fd, KVM_CREATE_VM, 0)
except OSError as exc:
    print("KVM_CREATE_VM failed: %s" % exc)
    os.close(fd)
    sys.exit(1)

try:
    os.close(vmfd)
except OSError:
    pass

os.close(fd)
print("KVM API check passed: KVM_GET_API_VERSION=%s KVM_CREATE_VM=ok" % api)
sys.exit(0)
PY
    rc=$?

    if [ "$rc" -eq 0 ]; then
        log_pass "/dev/kvm ioctl API validation passed"
        return 0
    fi

    log_fail "/dev/kvm ioctl API validation failed"
    return 1
}

# Scan kernel logs for fatal KVM/EL2/HYP/GIC virtualization errors.
#
# Args:
# $1 - output directory where dmesg logs should be collected
#
# Behavior:
# Uses scan_dmesg_errors from functestlib.sh when available.
# Falls back to get_kernel_log/dmesg capture otherwise.
#
# Returns:
# 0 if no fatal error is detected
# 1 if fatal KVM/EL2-related messages are detected
kvm_check_boot_dmesg_errors() {
    outdir="$1"
    include_regex='kvm|KVM|hyp|HYP|el2|EL2|vgic|VGIC|gicv|GICV'
    exclude_regex='not found|dummy regulator|probe deferred|using dummy regulator|EEXIST'

    mkdir -p "$outdir" 2>/dev/null || true

    if command -v scan_dmesg_errors >/dev/null 2>&1; then
        scan_dmesg_errors "$outdir" "$include_regex" "$exclude_regex" || true

        if [ -s "$outdir/dmesg_errors.log" ]; then
            if grep -Ei 'fail|failed|error|disabled|unavailable|not in hyp|hyp mode|EL2.*unavailable|HYP.*unavailable|KVM.*not available|kvm.*not available|panic|BUG|Oops' "$outdir/dmesg_errors.log" >/dev/null 2>&1; then
                log_fail "Fatal KVM/EL2 related messages found in dmesg: $outdir/dmesg_errors.log"
                return 1
            fi

            log_warn "KVM/EL2 related dmesg messages found but no fatal pattern matched: $outdir/dmesg_errors.log"
            return 0
        fi

        log_info "No relevant KVM/EL2 dmesg errors found."
        return 0
    fi

    if command -v get_kernel_log >/dev/null 2>&1; then
        get_kernel_log >"$outdir/dmesg_snapshot.log" 2>/dev/null || true
    elif command -v dmesg >/dev/null 2>&1; then
        dmesg >"$outdir/dmesg_snapshot.log" 2>/dev/null || true
    else
        log_warn "No kernel log source available for KVM dmesg validation"
        return 0
    fi

    if grep -Ei 'KVM|kvm|HYP|hyp|EL2|el2' "$outdir/dmesg_snapshot.log" >/dev/null 2>&1; then
        grep -Ei 'KVM|kvm|HYP|hyp|EL2|el2' "$outdir/dmesg_snapshot.log" >"$outdir/kvm_dmesg.log" 2>/dev/null || true
        log_info "KVM/EL2 dmesg lines captured: $outdir/kvm_dmesg.log"

        if grep -Ei 'fail|failed|error|disabled|unavailable|not in hyp|hyp mode|EL2.*unavailable|HYP.*unavailable|KVM.*not available|kvm.*not available|panic|BUG|Oops' "$outdir/kvm_dmesg.log" >/dev/null 2>&1; then
            log_fail "Fatal KVM/EL2 related messages found in dmesg: $outdir/kvm_dmesg.log"
            return 1
        fi
    else
        log_warn "No KVM/EL2 dmesg lines found"
    fi

    return 0
}

# Print available live device-tree root paths.
#
# Device-tree may be exposed through either:
# /proc/device-tree
# /sys/firmware/devicetree/base
#
# Returns:
# Prints existing DT roots to stdout
kvm_dt_roots() {
    for root in /proc/device-tree /sys/firmware/devicetree/base; do
        if [ -d "$root" ]; then
            printf '%s\n' "$root"
        fi
    done
}

# Log live device-tree identity information.
#
# Logs:
# - DT root path
# - model
# - compatible
#
# This helper is logging-only.
#
# Returns:
# Always returns 0
kvm_log_dt_identity() {
    for root in $(kvm_dt_roots); do
        log_info "DT root: $root"

        if [ -r "$root/model" ]; then
            model="$(tr '\000' ' ' <"$root/model" 2>/dev/null)"
            log_info "DT model: $model"
        fi

        if [ -r "$root/compatible" ]; then
            compat="$(tr '\000' ' ' <"$root/compatible" 2>/dev/null)"
            log_info "DT compatible: $compat"
        fi
    done

    return 0
}

# Find likely remoteproc/rproc nodes from the live device tree.
#
# Returns:
# Prints matching DT node paths to stdout.
kvm_dt_find_remoteproc_nodes() {
    for root in $(kvm_dt_roots); do
        find "$root" -type d 2>/dev/null | grep -Ei '/([^/]*remoteproc[^/]*|[^/]*rproc[^/]*)$' || true
    done
}

# Check whether live DT has remoteproc IOMMU evidence.
#
# Checks:
# - remoteproc/rproc DT nodes exist
# - at least one matching node or path has an iommus property
#
# Returns:
# 0 if remoteproc DT IOMMU evidence is found
# 1 if remoteproc DT nodes exist but no IOMMU evidence is found
# 2 if no remoteproc DT nodes are found
kvm_dt_remoteproc_has_iommus() {
    node_file="/tmp/kvm_remoteproc_nodes.$$"
    iommu_file="/tmp/kvm_remoteproc_iommus.$$"
    node_count=0
    iommu_count=0

    rm -f "$node_file" "$iommu_file" 2>/dev/null || true

    kvm_dt_find_remoteproc_nodes >"$node_file" 2>/dev/null || true

    if [ -s "$node_file" ]; then
        while IFS= read -r node; do
            [ -n "$node" ] || continue
            node_count=$((node_count + 1))
            log_info "[EL2-DT] remoteproc DT node: $node"

            if [ -e "$node/iommus" ]; then
                iommu_count=$((iommu_count + 1))
                log_info "[EL2-DT] remoteproc DT iommus present: $node/iommus"
            fi
        done <"$node_file"
    fi

    for root in $(kvm_dt_roots); do
        find "$root" -type f -name iommus 2>/dev/null | grep -Ei 'remoteproc|rproc|adsp|cdsp|gpdsp|wpss' || true
    done >"$iommu_file" 2>/dev/null || true

    if [ -s "$iommu_file" ]; then
        while IFS= read -r found_file; do
            [ -n "$found_file" ] || continue
            iommu_count=$((iommu_count + 1))
            log_info "[EL2-DT] remoteproc/iommus evidence: $found_file"
        done <"$iommu_file"
    fi

    rm -f "$node_file" "$iommu_file" 2>/dev/null || true

    if [ "$node_count" -eq 0 ]; then
        return 2
    fi

    if [ "$iommu_count" -gt 0 ]; then
        return 0
    fi

    return 1
}

# Log remoteproc instances using sysfs and functestlib.sh helpers when present.
#
# This helper is logging-only. It must not stop, start, or reset remoteprocs.
#
# Returns:
# 0 if at least one remoteproc instance is logged
# 2 if no remoteproc entries are found
kvm_log_remoteproc_state_summary() {
    found=0
    entries=""
    fw=""
    rpath=""
    rstate=""
    rfirm=""
    rname=""

    for rproc in /sys/class/remoteproc/remoteproc*; do
        [ -e "$rproc" ] || continue
        found=1

        fw="$(cat "$rproc/firmware" 2>/dev/null || echo unknown)"
        rstate="$(cat "$rproc/state" 2>/dev/null || echo unknown)"
        rname="$(cat "$rproc/name" 2>/dev/null || echo unknown)"

        log_info "[remoteproc] path=$rproc name=$rname firmware=$fw state=$rstate"
    done

    if command -v get_remoteproc_by_firmware >/dev/null 2>&1; then
        for fw in adsp cdsp cdsp0 cdsp1 gpdsp gpdsp0 gpdsp1 wpss modem; do
            entries="$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null || true)"
            [ -n "$entries" ] || continue

            while IFS='|' read -r rpath rstate rfirm rname; do
                [ -n "$rpath" ] || continue
                found=1
                log_info "[remoteproc-helper] fw=$fw path=$rpath state=$rstate firmware=$rfirm name=$rname"
            done <<__KVM_RPROC_ENTRIES__
$entries
__KVM_RPROC_ENTRIES__
        done
    fi

    if [ "$found" -eq 0 ]; then
        log_info "No /sys/class/remoteproc entries found"
        return 2
    fi

    return 0
}

# Check runtime sysfs evidence that remoteproc devices are connected through
# IOMMU/devlink/platform relationships.
#
# This is used as dynamic EL2-DTB evidence and avoids hardcoding board names.
#
# Returns:
# 0 if at least one sysfs evidence path is found
# 1 if no evidence path is found
kvm_sysfs_remoteproc_iommu_evidence() {
    evidence_count=0

    for path in \
        /sys/kernel/iommu_groups/*/devices/*remoteproc* \
        /sys/kernel/iommu_groups/*/devices/*rproc* \
        /sys/kernel/iommu_groups/*/devices/*adsp* \
        /sys/kernel/iommu_groups/*/devices/*cdsp* \
        /sys/kernel/iommu_groups/*/devices/*gpdsp* \
        /sys/class/devlink/*remoteproc* \
        /sys/class/devlink/*rproc* \
        /sys/class/devlink/*adsp* \
        /sys/class/devlink/*cdsp* \
        /sys/class/devlink/*gpdsp* \
        /sys/devices/platform/*/*remoteproc* \
        /sys/devices/platform/*/*rproc* \
        /sys/bus/platform/devices/*remoteproc* \
        /sys/bus/platform/devices/*rproc*
    do
        [ -e "$path" ] || continue
        evidence_count=$((evidence_count + 1))
        log_info "[EL2-SYSFS] remoteproc/IOMMU/devlink evidence: $path"
    done

    if [ "$evidence_count" -gt 0 ]; then
        return 0
    fi

    return 1
}

# Validate dynamic EL2-DTB runtime evidence.
#
# This helper reuses functestlib.sh remoteproc discovery when available, but it
# does not duplicate secure PIL or remoteproc lifecycle validation.
#
# Checks:
# - live DT identity
# - remoteproc state summary
# - remoteproc DT iommus evidence
# - remoteproc sysfs IOMMU/devlink/platform evidence
#
# Returns:
# 0 if EL2 remoteproc/IOMMU runtime evidence is found
# 1 if remoteproc exists but EL2-style evidence is missing
# 2 if no remoteproc DT/sysfs entries exist, so validation is not applicable
kvm_check_el2_runtime_evidence() {
    dt_rc=1
    sysfs_rc=1
    rproc_rc=2

    kvm_log_dt_identity

    kvm_log_remoteproc_state_summary
    rproc_rc=$?

    kvm_dt_remoteproc_has_iommus
    dt_rc=$?

    kvm_sysfs_remoteproc_iommu_evidence
    sysfs_rc=$?

    if [ "$rproc_rc" -eq 2 ] && [ "$dt_rc" -eq 2 ]; then
        log_info "No remoteproc DT/sysfs entries found; EL2 remoteproc validation is not applicable."
        return 2
    fi

    if [ "$dt_rc" -eq 0 ] || [ "$sysfs_rc" -eq 0 ]; then
        log_pass "EL2 remoteproc/IOMMU runtime evidence found."
        return 0
    fi

    log_fail "Remoteproc entries exist, but no EL2 remoteproc/IOMMU runtime evidence was found."
    return 1
}

# Locate a QEMU system emulator suitable for KVM validation.
#
# Search order:
# qemu-system-aarch64
# qemu-system-arm
# qemu-kvm
#
# Returns:
# 0 and prints binary path if found
# 1 if no suitable QEMU binary is found
kvm_find_qemu_binary() {
    for bin in qemu-system-aarch64 qemu-system-arm qemu-kvm; do
        if command -v "$bin" >/dev/null 2>&1; then
            command -v "$bin"
            return 0
        fi
    done

    return 1
}

# Locate qemu-img.
#
# Returns:
# 0 and prints binary path if found
# 1 if qemu-img is not found
kvm_find_qemu_img() {
    if command -v qemu-img >/dev/null 2>&1; then
        command -v qemu-img
        return 0
    fi

    return 1
}

# Validate whether QEMU advertises KVM acceleration support.
#
# Args:
# $1 - QEMU system binary path
#
# Returns:
# 0 if "kvm" is listed in "-accel help"
# 1 otherwise
kvm_check_qemu_kvm_accel() {
    qemu_bin="$1"
    accel_log="/tmp/kvm_qemu_accel_help.$$"

    [ -n "$qemu_bin" ] || return 1

    "$qemu_bin" -accel help >"$accel_log" 2>&1
    rc=$?

    if [ "$rc" -ne 0 ]; then
        log_warn "$qemu_bin -accel help failed"
        while IFS= read -r line; do
            log_warn "[qemu-accel] $line"
        done <"$accel_log"
        rm -f "$accel_log" 2>/dev/null || true
        return 1
    fi

    while IFS= read -r line; do
        log_info "[qemu-accel] $line"
    done <"$accel_log"

    if grep -Ei '(^|[[:space:]])kvm($|[[:space:]])' "$accel_log" >/dev/null 2>&1; then
        rm -f "$accel_log" 2>/dev/null || true
        log_pass "QEMU advertises KVM acceleration"
        return 0
    fi

    rm -f "$accel_log" 2>/dev/null || true
    log_fail "QEMU does not advertise KVM acceleration"
    return 1
}

# Log basic QEMU version, machine, and CPU capability information.
#
# Args:
# $1 - QEMU system binary path
#
# This helper is logging-only and should not fail the test by itself.
#
# Returns:
# 0 if called with a non-empty binary path
# 1 if no binary path is provided
kvm_qemu_probe() {
    qemu_bin="$1"
    machine_log="/tmp/kvm_qemu_machine_help.$$"
    cpu_log="/tmp/kvm_qemu_cpu_help.$$"

    [ -n "$qemu_bin" ] || return 1

    "$qemu_bin" -version 2>&1 | while IFS= read -r line; do
        log_info "[qemu-version] $line"
    done

    "$qemu_bin" -machine help >"$machine_log" 2>&1 || true
    head -n 20 "$machine_log" 2>/dev/null | while IFS= read -r line; do
        log_info "[qemu-machine] $line"
    done
    rm -f "$machine_log" 2>/dev/null || true

    "$qemu_bin" -cpu help >"$cpu_log" 2>&1 || true
    head -n 20 "$cpu_log" 2>/dev/null | while IFS= read -r line; do
        log_info "[qemu-cpu] $line"
    done
    rm -f "$cpu_log" 2>/dev/null || true

    return 0
}

# Validate /dev/net/tun availability for VM networking.
#
# This is optional infrastructure. Missing tun should warn, not fail,
# unless the caller explicitly requires networking.
#
# Returns:
# 0 if /dev/net/tun exists
# 1 otherwise
kvm_check_tun_device() {
    if [ -c /dev/net/tun ]; then
        log_pass "/dev/net/tun is present"
        return 0
    fi

    log_warn "/dev/net/tun is not present; VM networking may be limited"
    return 1
}

# Validate vhost-net availability for accelerated virtio-net.
#
# This is optional infrastructure. Missing vhost-net should warn, not fail,
# unless the caller explicitly requires accelerated networking.
#
# Returns:
# 0 if /dev/vhost-net exists or vhost_net module is loaded
# 1 otherwise
kvm_check_vhost_net() {
    if [ -c /dev/vhost-net ]; then
        log_pass "/dev/vhost-net is present"
        return 0
    fi

    if grep -qw vhost_net /proc/modules 2>/dev/null; then
        log_pass "vhost_net module is loaded"
        return 0
    fi

    log_warn "vhost-net is not available; virtio-net acceleration may be limited"
    return 1
}

# Log optional KVM kernel config without emitting FAIL on missing configs.
#
# Args:
#   $1 - kernel config name
#
# Returns:
#   0 if config is enabled as y/m
#   1 if config is missing or config source is unavailable
kvm_log_optional_kernel_config() {
    cfg="$1"

    if [ -z "$cfg" ]; then
        return 1
    fi

    if [ -r /proc/config.gz ]; then
        if command -v zgrep >/dev/null 2>&1; then
            if zgrep -Eq "^${cfg}=(y|m)$" /proc/config.gz 2>/dev/null; then
                log_info "Optional KVM config $cfg is enabled"
                return 0
            fi
        elif command -v gzip >/dev/null 2>&1; then
            if gzip -dc /proc/config.gz 2>/dev/null | grep -Eq "^${cfg}=(y|m)$"; then
                log_info "Optional KVM config $cfg is enabled"
                return 0
            fi
        fi
    fi

    log_warn "Optional KVM config not enabled or not visible: $cfg"
    return 1
}
