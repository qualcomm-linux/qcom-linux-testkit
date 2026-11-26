#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Reusable IGT GPU tools operations for the msm_* runners.
# Requires functestlib.sh, lib_display.sh for DRM node mapping, and
# lib_module_reload.sh for GPU boot-mode detection.
# Function variables use per-function prefixes, POSIX sh has no local.

# Kernel error lines from the msm DRM device, its GPU and DRM core.
IGT_KLOG_MODULES='msm_dpu|msm_drm|msm_gpu|adreno[^:]*|\[drm'
# IGT writes its own "[IGT] <test>: starting/finished subtest" markers to the kernel log.
IGT_KLOG_EXCLUDE='dummy regulator|supply [^ ]+ not found|using dummy regulator|\[IGT\] '
# Fault attribution: the msm module token, the msm DRM source path, and
# GPU/DRM symbols. A bare "msm" would also match other Qualcomm drivers.
IGT_KLOG_FAULT_MODULES='\[msm\]|drivers/gpu/drm/msm/|adreno|a[2-8]xx_|msm_(gpu|gem|ioctl|ringbuffer|fence|iommu|mmu|job|submitqueue|devfreq|drv)|drm_sched_'
IGT_KLOG_FAULT_HEADERS='BUG:|WARNING:|Oops|Internal error:|Kernel panic|kernel BUG at|Unable to handle|Unhandled fault|invalid opcode:'

# igt_gpu_owner
# Print the GPU owner selected at boot: kgsl, msm or unknown.
igt_gpu_owner() {
    igo_mode="unknown"
    if command -v mrv_qcom_gpu_boot_mode >/dev/null 2>&1; then
        igo_mode="$(mrv_qcom_gpu_boot_mode 2>/dev/null || true)"
        [ -n "$igo_mode" ] || igo_mode="unknown"
    fi
    if [ -e /dev/kgsl-3d0 ]; then
        igo_mode="kgsl"
    fi
    printf '%s\n' "$igo_mode"
}

# igt_select_msm_device
# Print the msm render node IGT must use. IGT_DEVICE is honoured when it is a
# drm:/dev/dri/<node> filter, otherwise the first msm render node is used.
# The runner passes the node to IGT with --device, which overrides .igtrc.
# Returns: 0 with the node, 1 when no msm node exists, 2 for an unsupported
# or non-msm IGT_DEVICE filter.
igt_select_msm_device() {
    if [ -n "${IGT_DEVICE:-}" ]; then
        case "$IGT_DEVICE" in
            drm:/dev/dri/card[0-9]*|drm:/dev/dri/renderD[0-9]*)
                ;;
            *)
                return 2
                ;;
        esac
        isd_node="$(display_drm_sibling_node "${IGT_DEVICE#drm:}" renderD)" || return 2
        [ "$(display_drm_driver_name "$isd_node" 2>/dev/null)" = "msm" ] || return 2
        printf '%s\n' "$isd_node"
        return 0
    fi
    display_drm_first_render_node msm
}

# igt_opened_devices_match <log-file> <render-node>
# Check every "Opened device:" line in the IGT log against the selected device.
# Returns: 0 when all match, 1 on a mismatch, 2 when the log reports no device.
igt_opened_devices_match() {
    iodm_nodes="$(sed -n 's/^Opened device: //p' "$1" 2>/dev/null)"
    [ -n "$iodm_nodes" ] || return 2
    iodm_rc=0
    # A here-document keeps the loop in this shell so iodm_rc survives it.
    while IFS= read -r iodm_node; do
        [ -n "$iodm_node" ] || continue
        iodm_render="$(display_drm_sibling_node "$iodm_node" renderD 2>/dev/null || true)"
        if [ "$iodm_render" != "$2" ]; then
            log_fail "IGT opened $iodm_node, expected the device of $2"
            iodm_rc=1
        fi
    done <<EOF
$iodm_nodes
EOF
    return "$iodm_rc"
}

# igt_run_binary <timeout> <log-file> <binary> [args...]
# Run an IGT binary under the shared managed timeout with output in log-file.
# Only the IGT process is redirected, so caller traps keep the runner stdout.
# Set MANAGED_TIMEOUT_USE_SESSION=1 in the caller to own the whole process group.
# Returns the IGT exit status, or 124 when the deadline expired.
igt_run_binary() {
    irb_timeout="$1"
    irb_log="$2"
    shift 2
    irb_dir="${irb_log%/*}"
    irb_label="${1##*/}"
    : >"$irb_log" || return 1
    # shellcheck disable=SC2016 # Expanded by the IGT launcher shell.
    run_with_managed_timeout "$irb_timeout" "$irb_dir" "$irb_label" \
        sh -c 'irb_out="$1"; shift; exec "$@" >>"$irb_out" 2>&1' sh "$irb_log" "$@"
}

# igt_count_subtests <log-file> <status-regex>
# Print the number of "Subtest <name>: <status>" lines in the IGT log.
igt_count_subtests() {
    ics_count=$(grep -Ec "^Subtest [^:]+: ($2)" "$1" 2>/dev/null)
    case "$ics_count" in
        ''|*[!0-9]*)
            ics_count=0
            ;;
    esac
    printf '%s\n' "$ics_count"
}

# igt_list_subtests <log-file> <status-regex>
# Print the "Subtest <name>: <status>" lines matching status-regex.
igt_list_subtests() {
    grep -E "^Subtest [^:]+: ($2)" "$1" 2>/dev/null || true
}

# igt_log_version <log-file>
# Print the IGT version reported in the log, or unknown.
igt_log_version() {
    ilv_version="$(sed -n 's/^IGT-Version: //p' "$1" 2>/dev/null | head -n 1)"
    printf '%s\n' "${ilv_version:-unknown}"
}

# igt_kernel_log_capture <dir>
# Capture the kernel log and msm/adreno/drm error lines into dir.
# Sets IGT_KLOG_STATUS (available or unavailable) and IGT_KLOG_ACCESS_LOG.
# Returns: 0 when the capture is usable, 1 when the kernel log was unavailable.
igt_kernel_log_capture() {
    # The scan runs in a subshell so a signal trap never inherits its redirection.
    IGT_KLOG_STATUS="$(
        scan_dmesg_errors "$1" "$IGT_KLOG_MODULES" "$IGT_KLOG_EXCLUDE" >/dev/null 2>&1
        printf '%s' "${DMESG_ACCESS_STATUS:-unknown}"
    )"
    [ -n "$IGT_KLOG_STATUS" ] || IGT_KLOG_STATUS="unknown"
    # shellcheck disable=SC2034 # Read by the runners for the evidence-unavailable warning.
    IGT_KLOG_ACCESS_LOG="$1/dmesg_access.log"
    [ "$IGT_KLOG_STATUS" = "available" ]
}

# igt_new_lines <baseline> <current> <out>
# Write lines of current that are absent from baseline to out.
# Returns: 0 on success, 1 when the comparison itself failed.
igt_new_lines() {
    if [ ! -s "$1" ]; then
        cp "$2" "$3" 2>/dev/null
        return
    fi
    grep -vxF -f "$1" "$2" >"$3" 2>/dev/null
    [ "$?" -le 1 ]
}

# igt_kernel_log_compare <pre-dir> <post-dir> <out-dir>
# Write error lines and attributed GPU fault blocks that are new in the post
# capture to out-dir/dmesg_errors.log and out-dir/dmesg_faults.log.
# Sets IGT_KLOG_NEW_ERRORS and IGT_KLOG_NEW_FAULTS (fault block headers).
# Returns: 0 on success, 1 when a scan or comparison failed, so the result
# must be treated as unavailable evidence rather than a clean log.
igt_kernel_log_compare() {
    iklc_pre="$1"
    iklc_post="$2"
    iklc_out="$3"
    iklc_rc=0
    IGT_KLOG_NEW_ERRORS=0
    IGT_KLOG_NEW_FAULTS=0

    igt_new_lines "$iklc_pre/dmesg_errors.log" "$iklc_post/dmesg_errors.log" \
        "$iklc_out/dmesg_errors.log" || iklc_rc=1

    for iklc_dir in "$iklc_pre" "$iklc_post"; do
        if ! kernel_log_filter_faults "$iklc_dir/dmesg_snapshot.log" "$IGT_KLOG_FAULT_MODULES" \
            >"$iklc_dir/dmesg_faults.log" 2>/dev/null; then
            iklc_rc=1
        fi
    done
    igt_new_lines "$iklc_pre/dmesg_faults.log" "$iklc_post/dmesg_faults.log" \
        "$iklc_out/dmesg_faults.log" || iklc_rc=1

    if [ -f "$iklc_out/dmesg_errors.log" ]; then
        IGT_KLOG_NEW_ERRORS=$(wc -l <"$iklc_out/dmesg_errors.log" | tr -d '[:space:]')
    fi
    if [ -f "$iklc_out/dmesg_faults.log" ]; then
        IGT_KLOG_NEW_FAULTS=$(grep -cE -- "$IGT_KLOG_FAULT_HEADERS" "$iklc_out/dmesg_faults.log")
    fi
    case "$IGT_KLOG_NEW_ERRORS" in ''|*[!0-9]*) IGT_KLOG_NEW_ERRORS=0 ;; esac
    case "$IGT_KLOG_NEW_FAULTS" in ''|*[!0-9]*) IGT_KLOG_NEW_FAULTS=0 ;; esac
    return "$iklc_rc"
}

# igt_log_file_lines <log-level> <prefix> <file> <max-lines>
# Log up to max-lines of file with the given log level (info, warn, fail).
igt_log_file_lines() {
    head -n "$4" "$3" 2>/dev/null | while IFS= read -r iflf_line; do
        "log_$1" "$2 $iflf_line"
    done
}
