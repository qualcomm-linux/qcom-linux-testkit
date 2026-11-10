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

    run_with_bounded_timeout 10 python3 - <<'PY'
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
# Reuses captured snapshot and retained fault blocks for this operation.
#
# Returns:
# 0 if no fatal error is detected
# 1 if fatal KVM/EL2-related messages are detected
kvm_check_boot_dmesg_errors() {
    kvm_log_dir="$1"
    if [ "${KVM_CAPTURED_DIR:-}" != "$kvm_log_dir" ]; then
        scan_dmesg_errors "$kvm_log_dir" 'kvm|hyp|el2|vgic|gicv' \
            'dummy regulator|probe deferred|using dummy regulator|EEXIST' || true
        KVM_CAPTURED_DIR="$kvm_log_dir"
    fi
    if [ "${DMESG_ACCESS_STATUS:-unknown}" != available ]; then
        log_warn "KVM kernel log access: ${DMESG_ACCESS_STATUS:-unknown}, see $kvm_log_dir"
    fi
    # The generic error filter does not include all HYP availability messages.
    grep -Ei '(^|[^[:alnum:]_])(kvm|hyp|el2|vgic|gicv)([^[:alnum:]_]|$)' "$kvm_log_dir/dmesg_snapshot.log" \
        | grep -vE 'Kernel command line:|Command line:' >"$kvm_log_dir/kvm_dmesg.log" 2>/dev/null || true
    cp "$kvm_log_dir/dmesg_errors.log" "$kvm_log_dir/kvm_errors.log" || return 1
    grep -Ei '(^|[^[:alnum:]_])(failed|failure|error|unavailable|panic|BUG|Oops)([^[:alnum:]_]|$)|not available|not in hyp|(^|:)[[:space:]]*KVM[[:space:]]+(is[[:space:]]+)?disabled' \
        "$kvm_log_dir/kvm_dmesg.log" >>"$kvm_log_dir/kvm_errors.log" || true
    if [ -s "$kvm_log_dir/kvm_errors.log" ]; then
        cat "$kvm_log_dir/kvm_errors.log"
        log_fail "KVM/EL2 initialization errors found in $kvm_log_dir/kvm_errors.log"
        return 1
    fi
    return 0
}

# kvm_log_readiness <output-directory>
# Capture readiness before callers gate on config, /dev/kvm, or optional clients.
# This diagnostic does not replace ioctl or QEMU functional validation.
kvm_log_readiness() {
    kvm_readiness_dir="$1"
    KVM_CAPTURED_DIR=""
    log_info "KVM runtime: kernel=$(uname -r) architecture=$(uname -m)"
    kvm_log_dt_identity
    for kvm_config in CONFIG_VIRTUALIZATION CONFIG_KVM; do
        check_kernel_config "$kvm_config" || true
    done
    ls -l /dev/kvm 2>&1 || true
    if ! kvm_check_boot_dmesg_errors "$kvm_readiness_dir"; then
        log_fail "KVM initialization failed, check firmware EL2 handoff and kernel diagnostics above"
        return 1
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
            readlink -f "$root"
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
kvm_dt_find_remoteproc_nodes() (
    for kdfn_rproc in /sys/class/remoteproc/remoteproc*; do
        [ -d "$kdfn_rproc" ] || continue
        kdfn_owner=$(readlink -f "$kdfn_rproc/device" 2>/dev/null || true)
        if [ -z "$kdfn_owner" ]; then
            kdfn_owner=$(readlink -f "$kdfn_rproc" 2>/dev/null || true)
            kdfn_owner=${kdfn_owner%/remoteproc/*}
        fi
        kdfn_node=$(readlink -f "$kdfn_owner/of_node" 2>/dev/null || true)
        [ -d "$kdfn_node" ] || continue
        dt_node_enabled "$kdfn_node" || continue
        printf '%s\n' "$kdfn_node"
    done
)

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
kvm_dt_remoteproc_has_iommus() (
    kdr_nodes=$(kvm_dt_find_remoteproc_nodes) || return 1
    [ -n "$kdr_nodes" ] || return 2
    while IFS= read -r kdr_node; do
        if [ -s "$kdr_node/iommus" ]; then
            log_info "Remoteproc DT declares DMA translation: $kdr_node, runtime attachment must also be verified"
            return 0
        fi
    done <<KVM_DT_NODES
$kdr_nodes
KVM_DT_NODES
    return 1
)

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
# This is used as runtime DMA attachment evidence and avoids hardcoding board names.
#
# Returns:
# 0 if at least one sysfs evidence path is found
# 1 if no evidence path is found
kvm_sysfs_remoteproc_iommu_evidence() (
    ksri_out=$(test_create_run_directory "$PWD/results/kvm-iommu") || return 1
    iommu_validate_runtime_devices "$ksri_out" registered
    ksri_rc=$?
    [ "$ksri_rc" -le 1 ] || return 1
    [ -r "$ksri_out/iommu_contexts.tsv" ] || return 1
    ksri_nodes=$(kvm_dt_find_remoteproc_nodes) || return 1
    [ -n "$ksri_nodes" ] || return 1
    while IFS= read -r ksri_node; do
        if awk -F '|' -v node="$ksri_node" '
            ($1 == node || index($1, node "/") == 1) {
                found=1
                if ($NF != "PASS") failed=1
            }
            END { exit (!found || failed) }
        ' "$ksri_out/iommu_contexts.tsv"; then
            log_info "Remoteproc has verified runtime DMA group attachment: $ksri_node"
            return 0
        fi
    done <<KVM_IOMMU_NODES
$ksri_nodes
KVM_IOMMU_NODES
    return 1
)

# Validate runtime remoteproc DMA attachment evidence.
#
# This helper reuses functestlib.sh remoteproc discovery when available, but it
# does not duplicate secure PIL or remoteproc lifecycle validation.
#
# Checks:
# - live DT identity
# - remoteproc state summary
# - remoteproc DT iommus evidence
# - exact runtime DMA group and reverse device membership
#
# Returns:
# 0 if remoteproc DMA/IOMMU runtime evidence is found
# 1 if remoteproc exists but verified DMA attachment is missing
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
        log_info "No remoteproc DT/sysfs entries found; remoteproc DMA validation is not applicable."
        return 2
    fi

    if [ "$sysfs_rc" -eq 0 ]; then
        log_pass "Runtime remoteproc/IOMMU attachment verified, this does not identify a FIT configuration."
        return 0
    fi

    log_fail "Remoteproc entries exist, but no remoteproc DMA/IOMMU runtime evidence was found."
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
    accel_log="$PWD/kvm_qemu_accel_help.$$"

    [ -n "$qemu_bin" ] || return 1

    run_with_bounded_timeout_capture 10 "${accel_log}.process" "$qemu_bin" -accel help >"$accel_log" 2>&1
    rc=$?

    if [ "$rc" -ne 0 ]; then
        log_warn "$qemu_bin -accel help failed"
        while IFS= read -r line; do
            log_warn "[qemu-accel] $line"
        done <"$accel_log"
        return 1
    fi

    while IFS= read -r line; do
        log_info "[qemu-accel] $line"
    done <"$accel_log"

    if grep -Ei '(^|[[:space:]])kvm($|[[:space:]])' "$accel_log" >/dev/null 2>&1; then
        log_pass "QEMU advertises KVM acceleration"
        return 0
    fi
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
    machine_log="$PWD/kvm_qemu_machine_help.$$"
    cpu_log="$PWD/kvm_qemu_cpu_help.$$"

    [ -n "$qemu_bin" ] || return 1

    run_with_bounded_timeout 10 "$qemu_bin" -version 2>&1 | while IFS= read -r line; do
        log_info "[qemu-version] $line"
    done

    run_with_bounded_timeout_capture 10 "${machine_log}.process" "$qemu_bin" -machine help >"$machine_log" 2>&1 || true
    head -n 20 "$machine_log" 2>/dev/null | while IFS= read -r line; do
        log_info "[qemu-machine] $line"
    done

    run_with_bounded_timeout_capture 10 "${cpu_log}.process" "$qemu_bin" -cpu help >"$cpu_log" 2>&1 || true
    head -n 20 "$cpu_log" 2>/dev/null | while IFS= read -r line; do
        log_info "[qemu-cpu] $line"
    done

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
