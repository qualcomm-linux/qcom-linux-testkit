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
    max_wait="${1:-60}"
    sleep_step="${2:-2}"
    waited=0
    iface=""
    settle_done=0
 
    case "$max_wait" in
        ''|*[!0-9]*)
            max_wait=60
            ;;
    esac
 
    case "$sleep_step" in
        ''|*[!0-9]*)
            sleep_step=2
            ;;
    esac
 
    if [ "$max_wait" -le 0 ] 2>/dev/null; then
        max_wait=60
    fi
 
    if [ "$sleep_step" -le 0 ] 2>/dev/null; then
        sleep_step=2
    fi
 
    # Keep stdout reserved only for the detected interface name because callers
    # commonly use command substitution:
    #   wifi_iface="$(wait_for_wifi_interface ...)"
    #
    # All diagnostics must go to stderr to avoid contaminating the returned
    # interface name.
    log_info "Waiting up to ${max_wait}s for WiFi interface creation" >&2
 
    while [ "$waited" -lt "$max_wait" ]; do
        wifi_unblock_rfkill
 
        iface="$(get_wifi_interface 2>/dev/null || true)"
        if [ -n "$iface" ]; then
            printf '%s\n' "$iface"
            return 0
        fi
 
        if [ "$settle_done" -eq 0 ]; then
            settle_done=1
 
            if command -v udevadm >/dev/null 2>&1; then
                log_info "No WiFi interface yet; triggering net add uevents and waiting for udev settle" >&2
                udevadm trigger --action=add --subsystem-match=net >/dev/null 2>&1 || true
                udevadm settle --timeout=5 >/dev/null 2>&1 || true
 
                iface="$(get_wifi_interface 2>/dev/null || true)"
                if [ -n "$iface" ]; then
                    printf '%s\n' "$iface"
                    return 0
                fi
            fi
        fi
 
        sleep "$sleep_step"
        waited=$((waited + sleep_step))
 
        if [ "$waited" -gt 0 ] && [ $((waited % 10)) -eq 0 ]; then
            log_info "Still waiting for WiFi interface... waited=${waited}s/${max_wait}s" >&2
        fi
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
 
        mod_path="$(find_kernel_module "$mod" 2>/dev/null | awk '/^\// { print; exit }' || true)"
        if [ -n "$mod_path" ]; then
            log_info "[module-path] $mod -> $mod_path"
        else
            log_info "[module-path] $mod -> not found"
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

# Detect WiFi firmware family and a representative firmware file under
# /lib/firmware for ath12k, ath11k, or ath10k based platforms.
wifi_detect_firmware_info() {
    WIFI_FW_FILE=""
    WIFI_FW_FAMILY=""
    WIFI_FW_BASENAME=""
    WIFI_FW_SIZE=""

    if [ -d /lib/firmware/ath12k ]; then
        WIFI_FW_FILE="$(find /lib/firmware/ath12k -type f -name amss.bin -print -quit 2>/dev/null)"
        if [ -n "$WIFI_FW_FILE" ]; then
            WIFI_FW_FAMILY="ath12k"
        fi
    fi

    if [ -z "$WIFI_FW_FILE" ] && [ -d /lib/firmware/ath11k ]; then
        WIFI_FW_FILE="$(find /lib/firmware/ath11k -type f -name amss.bin -print -quit 2>/dev/null)"
        if [ -n "$WIFI_FW_FILE" ]; then
            WIFI_FW_FAMILY="ath11k"
        else
            WIFI_FW_FILE="$(find /lib/firmware/ath11k -type f -name wpss.mbn -print -quit 2>/dev/null)"
            if [ -n "$WIFI_FW_FILE" ]; then
                WIFI_FW_FAMILY="ath11k"
            fi
        fi
    fi

    if [ -z "$WIFI_FW_FILE" ] && [ -d /lib/firmware/ath10k ]; then
        WIFI_FW_FILE="$(find /lib/firmware/ath10k -type f -name wlanmdsp.mbn -print -quit 2>/dev/null)"
        if [ -n "$WIFI_FW_FILE" ]; then
            WIFI_FW_FAMILY="ath10k"
        else
            WIFI_FW_FILE="$(find /lib/firmware/ath10k -type f -name 'firmware-*.bin' -print -quit 2>/dev/null)"
            if [ -n "$WIFI_FW_FILE" ]; then
                WIFI_FW_FAMILY="ath10k"
            fi
        fi
    fi

    if [ -z "$WIFI_FW_FILE" ] || [ -z "$WIFI_FW_FAMILY" ]; then
        return 1
    fi

    WIFI_FW_BASENAME="${WIFI_FW_FILE##*/}"
    WIFI_FW_SIZE="$(stat -c%s "$WIFI_FW_FILE" 2>/dev/null || echo unknown)"

    # These variables are intentionally returned to callers through shell scope.
    : "$WIFI_FW_BASENAME" "$WIFI_FW_SIZE"

    return 0
}

# Try to load the first available module from the provided list, succeeding
# if one is already loaded or modprobe succeeds for one candidate.
wifi_load_first_available_module() {
    mod=""

    for mod in "$@"; do
        [ -n "$mod" ] || continue

        if is_module_loaded "$mod"; then
            log_info "Module already loaded: $mod"
            return 0
        fi

        if modprobe "$mod" 2>/dev/null; then
            log_info "Loaded WiFi module: $mod"
            return 0
        fi
    done

    return 1
}

# Perform family-specific WiFi runtime preparation for ath12k, ath11k, or
# ath10k using logging only; callers decide the final testcase result.
wifi_handle_firmware_family() {
    family="$1"
    basename="$2"

    case "$family" in
        ath12k)
            log_info "ath12k firmware detected, handling WCN7850 / Wi-Fi 7 class platform."
            if wifi_load_first_available_module ath12k_wifi7 ath12k_pci ath12k_ahb ath12k; then
                return 0
            fi
            log_fail "Failed to load any ath12k module: ath12k_wifi7/ath12k_pci/ath12k_ahb/ath12k"
            return 1
            ;;
        ath11k)
            case "$basename" in
                wpss.mbn)
                    log_info "ath11k WPSS firmware detected, validating wpss remoteproc."
                    if validate_remoteproc_running "wpss"; then
                        log_info "Remoteproc 'wpss' is active and validated."
                        return 0
                    fi
                    log_fail "Remoteproc 'wpss' validation failed."
                    return 1
                    ;;
                amss.bin)
                    log_info "ath11k amss.bin firmware detected, handling PCI/AHB/SNOC class platform."
                    if wifi_load_first_available_module ath11k_pci ath11k_ahb ath11k_snoc ath11k; then
                        return 0
                    fi
                    log_fail "Failed to load any ath11k module: ath11k_pci/ath11k_ahb/ath11k_snoc/ath11k"
                    return 1
                    ;;
                *)
                    log_fail "Unsupported ath11k firmware type: $basename"
                    return 1
                    ;;
            esac
            ;;
        ath10k)
            log_info "ath10k firmware detected, handling WCN3990/QCM2290 class platform."
            if wifi_load_first_available_module ath10k_snoc ath10k_pci ath10k_sdio ath10k_core; then
                return 0
            fi
            log_fail "Failed to load any ath10k module: ath10k_snoc/ath10k_pci/ath10k_sdio/ath10k_core"
            return 1
            ;;
        *)
            log_fail "Unsupported WiFi family detected: $family"
            return 1
            ;;
    esac
}

# Validate family-specific module visibility and print module/path details,
# including explicit ath10k core and bus driver checks.
wifi_verify_family_modules() {
    family="$1"

    case "$family" in
        ath12k)
            log_info "Checking active ath12k-related kernel modules."
            wifi_log_module_info ath12k_wifi7 ath12k ath12k_pci ath12k_ahb cfg80211 mac80211 mhi

            ath12k_core_ok=0
            ath12k_bus_ok=0

            if is_module_loaded ath12k; then
                ath12k_core_ok=1
            else
                log_fail "ath12k core module is not loaded."
            fi

            if is_module_loaded ath12k_wifi7 || is_module_loaded ath12k_pci || is_module_loaded ath12k_ahb; then
                ath12k_bus_ok=1
            else
                log_fail "No ath12k transport/top module detected: ath12k_wifi7/ath12k_pci/ath12k_ahb"
            fi

            if [ "$ath12k_core_ok" -eq 1 ] && [ "$ath12k_bus_ok" -eq 1 ]; then
                return 0
            fi

            return 1
            ;;
        ath11k)
            log_info "Checking active ath11k-related kernel modules."
            wifi_log_module_info ath11k ath11k_pci ath11k_ahb ath11k_snoc cfg80211 mac80211

            if is_module_loaded ath11k || is_module_loaded ath11k_pci || \
               is_module_loaded ath11k_ahb || is_module_loaded ath11k_snoc; then
                return 0
            fi

            log_fail "No ath11k-related kernel module detected."
            return 1
            ;;
        ath10k)
            log_info "Checking active ath10k-related kernel modules."
            wifi_log_module_info ath10k_core ath10k_snoc ath10k_pci ath10k_sdio cfg80211 mac80211

            ath10k_core_ok=0
            ath10k_bus_ok=0

            if is_module_loaded ath10k_core; then
                ath10k_core_ok=1
            else
                log_fail "ath10k_core module is not loaded."
            fi

            if is_module_loaded ath10k_snoc || is_module_loaded ath10k_pci || is_module_loaded ath10k_sdio; then
                ath10k_bus_ok=1
            else
                log_fail "No ath10k bus driver module detected: ath10k_snoc/ath10k_pci/ath10k_sdio"
            fi

            if [ "$ath10k_core_ok" -eq 1 ] && [ "$ath10k_bus_ok" -eq 1 ]; then
                return 0
            fi

            return 1
            ;;
        *)
            log_fail "Unsupported WiFi family for module validation: $family"
            return 1
            ;;
    esac
}

# Check kernel logs and runtime wireless state for evidence that WiFi firmware
# was consumed by the driver. Returns success when firmware load/use evidence exists.
wifi_firmware_loaded() {
    family="$1"
    tag="${2:-wifi-firmware}"
    pattern=""
    matches=""
    phy_path=""
    phy=""
    phy_found=0

    case "$family" in
        ath12k)
            pattern='ath12k|ath12k_wifi7|WCN7850|wcn7850|amss.bin|m3.bin|board-2.bin|Hardware name|firmware'
            ;;
        ath11k)
            pattern='ath11k|WCN6855|WCN6750|wcn6855|wcn6750|amss.bin|wpss.mbn|board-2.bin|remoteproc|firmware'
            ;;
        ath10k)
            pattern='ath10k|WCN3990|wcn3990|wlanmdsp.mbn|firmware-[0-9].bin|board-2.bin|firmware'
            ;;
        *)
            log_warn "[$tag] Unsupported WiFi firmware family for load evidence check: $family"
            return 1
            ;;
    esac
    
    matches="$(get_kernel_log 2>/dev/null | grep -Ei "$pattern" | \
    grep -Eiv 'failed|failure|error|timeout|unable|crash|fatal|Modules linked in' | tail -n 40 || true)"

    if [ -n "$matches" ]; then
        printf '%s\n' "$matches" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            log_info "[$tag] $line"
        done
        return 0
    fi

    if [ -d /sys/class/ieee80211 ]; then
        for phy_path in /sys/class/ieee80211/*; do
            [ -e "$phy_path" ] || continue
            phy_found=1
            break
        done

        if [ "$phy_found" -eq 1 ]; then
            log_info "[$tag] /sys/class/ieee80211 contains wireless phy entries."

            for phy_path in /sys/class/ieee80211/*; do
                [ -e "$phy_path" ] || continue
                phy="${phy_path##*/}"
                log_info "[$tag] phy detected: $phy"
            done

            return 0
        fi
    fi

    if command -v iw >/dev/null 2>&1; then
        if iw phy 2>/dev/null | grep . >/dev/null 2>&1; then
            log_info "[$tag] iw phy reports wireless PHY availability."
            return 0
        fi
    fi

    log_warn "[$tag] No positive WiFi firmware load/use evidence found for family: $family"
    return 1
}
