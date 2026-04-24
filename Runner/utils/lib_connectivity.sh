#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Connectivity-specific helper library layered on top of functestlib.sh.
# Source functestlib.sh before sourcing this file.
# Best-effort helper to unblock WiFi before discovery or retry loops.
# Silent success is acceptable on minimal images where rfkill may be absent.
wifi_unblock_rfkill() {
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi >/dev/null 2>&1 || true
        rfkill unblock all >/dev/null 2>&1 || true
    fi
}

# Retry WiFi interface discovery for a bounded time while unblocking rfkill.
# Prints interface name on success and returns non-zero on timeout.
wait_for_wifi_interface() {
    max_wait="${1:-30}"
    sleep_step="${2:-2}"
    waited=0
    iface=""

    case "$max_wait" in
        ''|*[!0-9]*)
            max_wait=30
            ;;
    esac

    case "$sleep_step" in
        ''|*[!0-9]*)
            sleep_step=2
            ;;
    esac

    if [ "$max_wait" -le 0 ] 2>/dev/null; then
        max_wait=30
    fi
    if [ "$sleep_step" -le 0 ] 2>/dev/null; then
        sleep_step=2
    fi

    while [ "$waited" -lt "$max_wait" ]; do
        wifi_unblock_rfkill

        iface="$(get_wifi_interface 2>/dev/null || true)"
        if [ -n "$iface" ]; then
            printf '%s\n' "$iface"
            return 0
        fi

        sleep "$sleep_step"
        waited=$((waited + sleep_step))
    done

    return 1
}

# Reuse the existing DT matcher with caller-provided WiFi node/compatible
# patterns so run.sh stays small and gets built-in logging from functestlib.sh.
wifi_dt_present() {
    dt_confirm_node_or_compatible_all "$@"
}

# Print WiFi-related loaded modules and, when found, the resolved .ko path
# using existing is_module_loaded() and find_kernel_module() helpers.
wifi_log_module_info() {
    mod=""
    mod_path=""

    for mod in "$@"; do
        [ -n "$mod" ] || continue

        if is_module_loaded "$mod"; then
            log_pass "Module loaded: $mod"
        else
            log_info "Module not loaded: $mod"
        fi

        mod_path="$(find_kernel_module "$mod" 2>/dev/null || true)"
        if [ -n "$mod_path" ]; then
            log_info "[module-path] $mod -> $mod_path"
        fi
    done
}

# Return success when there is evidence that a WiFi software stack is present,
# even if no netdev has been created yet. Used to separate FAIL from SKIP.
wifi_stack_present() {
    mod=""

    for mod in ath12k_wifi7 ath12k ath11k ath11k_pci ath10k_pci ath10k_snoc cfg80211 mac80211 mhi; do
        if is_module_loaded "$mod"; then
            return 0
        fi
    done

    if [ -d /sys/class/ieee80211 ]; then
        if ls /sys/class/ieee80211/* >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v iw >/dev/null 2>&1; then
        if iw phy 2>/dev/null | grep . >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# Infer target-specific WiFi driver configs from loaded modules and kernel log
# so ATH11K or ATH12K checks are only enforced when relevant on the target.
infer_wifi_driver_cfgs() {
    cfgs=""

    if is_module_loaded ath11k || get_kernel_log 2>/dev/null | grep -Eq '(^|[^[:alnum:]_])ath11k([^[:alnum:]_]|$)'; then
        cfgs="CONFIG_ATH11K"
    fi

    if is_module_loaded ath12k || is_module_loaded ath12k_wifi7 || get_kernel_log 2>/dev/null | grep -Eq '(^|[^[:alnum:]_])ath12k([^[:alnum:]_]|$)|(^|[^[:alnum:]_])ath12k_wifi7([^[:alnum:]_]|$)'; then
        if [ -n "$cfgs" ]; then
            cfgs="$cfgs CONFIG_ATH12K"
        else
            cfgs="CONFIG_ATH12K"
        fi
    fi

    printf '%s\n' "$cfgs"
}

# Scan kernel logs for WiFi driver probe/runtime failures and print matched
# lines to stdout. Returns success when probe failures are present.
wifi_has_probe_failures() {
    outdir="$1"
    tag="${2:-wifi-probe-check}"
    include_regex="wifi|wlan|ath|cfg80211|mac80211|qca|wcn|firmware|mhi|pci|msi|qmi"
    exclude_regex="using dummy regulator|Loading compiled-in X.509 certificates for regulatory database"
    errfile=""
    failure_file=""
    tmp_matches=""
    line=""

    if [ -z "$outdir" ]; then
        outdir="/tmp/wifi_dmesg"
    fi

    mkdir -p "$outdir" >/dev/null 2>&1 || true
    errfile="$outdir/dmesg_errors.log"
    failure_file="$outdir/wifi_probe_failures.log"
    : >"$failure_file"

    if command -v scan_dmesg_errors >/dev/null 2>&1; then
        scan_dmesg_errors "$outdir" "$include_regex" "$exclude_regex" >/dev/null 2>&1 || true
    fi

    if [ -s "$errfile" ]; then
        grep -Ei \
            '(ath|wifi|wlan|qca|wcn).*(probe with driver .* failed|failed to alloc msi|qmi dma allocation failed|failed to create .*wlan|failed to register .*wlan|Direct firmware load .* failed|firmware.*failed|failed to load board data|failed to fetch board data|mhi.*failed)|(probe with driver .* failed|failed to alloc msi|qmi dma allocation failed|failed to create .*wlan|failed to register .*wlan|Direct firmware load .* failed|firmware.*failed|failed to load board data|failed to fetch board data|mhi.*failed).*(ath|wifi|wlan|qca|wcn)' \
            "$errfile" 2>/dev/null >>"$failure_file" || true
    fi

    tmp_matches="$(get_kernel_log 2>/dev/null | grep -Ei \
        '(ath|wifi|wlan|qca|wcn).*(probe with driver .* failed|failed to alloc msi|qmi dma allocation failed|failed to create .*wlan|failed to register .*wlan|Direct firmware load .* failed|firmware.*failed|failed to load board data|failed to fetch board data|mhi.*failed)|(probe with driver .* failed|failed to alloc msi|qmi dma allocation failed|failed to create .*wlan|failed to register .*wlan|Direct firmware load .* failed|firmware.*failed|failed to load board data|failed to fetch board data|mhi.*failed).*(ath|wifi|wlan|qca|wcn)' \
        || true)"

    if [ -n "$tmp_matches" ]; then
        printf '%s\n' "$tmp_matches" >>"$failure_file"
    fi

    if [ -s "$failure_file" ]; then
        awk '!seen[$0]++' "$failure_file" >"${failure_file}.dedup" 2>/dev/null || cp "$failure_file" "${failure_file}.dedup" 2>/dev/null || true

        log_fail "[$tag] matched WiFi probe/runtime failures:"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            log_fail "[$tag] $line"
        done < "${failure_file}.dedup"

        rm -f "${failure_file}.dedup"
        return 0
    fi

    return 1
}

# Print wireless runtime state from iw, sysfs, ip, and rfkill so missing
# interface cases are diagnosable directly from testcase stdout.
wifi_dump_runtime_info() {
    log_info "--- iw dev ---"
    iw dev 2>/dev/null || true

    log_info "--- iw phy ---"
    iw phy 2>/dev/null || true

    log_info "--- /sys/class/ieee80211 ---"
    ls -l /sys/class/ieee80211 2>/dev/null || true

    log_info "--- /sys/class/net ---"
    ls -l /sys/class/net 2>/dev/null || true

    log_info "--- ip -o link show ---"
    ip -o link show 2>/dev/null || true

    log_info "--- wireless markers ---"
    for n in /sys/class/net/*; do
        [ -e "$n" ] || continue
        i="$(basename "$n")"
        marker="$i:"

        if [ -d "$n/wireless" ]; then
            marker="$marker wireless-dir=yes"
        fi
        if [ -e "$n/phy80211" ]; then
            marker="$marker phy80211=yes"
        fi

        dev_path="$(readlink -f "$n/device" 2>/dev/null || true)"
        log_info "[wireless-marker] $marker ${dev_path:-<no-device-path>}"
    done

    log_info "--- rfkill list ---"
    rfkill list 2>/dev/null || true
}

# Emit a compact WiFi debug bundle to stdout using existing DT and runtime
# helpers so CI logs clearly explain missing interface or probe failures.
wifi_dump_debug_info() {
    wifi_dt_present "$@" || true
    wifi_dump_runtime_info
}
