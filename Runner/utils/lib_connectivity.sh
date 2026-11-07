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
#
# Optional recovery knobs:
# WIFI_RECOVERY_RELOAD=1|0
# Enable one controlled WiFi driver reload if no interface appears.
#
# WIFI_RECOVERY_RELOAD_AFTER_S=N
# Try reload after N seconds of waiting. Default: half of max_wait.
#
# WIFI_RECOVERY_MODULES="mod1 mod2 ..."
# Leaf WiFi driver modules eligible for reload.
#
# Notes:
# - stdout is reserved only for the detected interface name.
# - diagnostics go to stderr because callers use command substitution.
# - shared modules such as cfg80211/mac80211/mhi must not be reloaded here.
# wifi_wait_command <limit> <label> <command...>
# Run within the discovery deadline, reserving module restoration separately.
wifi_wait_command() (
    wifi_op_limit="$1"
    wifi_op_label="$2"
    shift 2
    wifi_op_remaining=$((wifi_wait_deadline - $(get_monotonic_seconds)))
    [ "$wifi_op_remaining" -gt 0 ] || return 124
    if [ "$wifi_op_limit" -gt "$wifi_op_remaining" ]; then
        wifi_op_limit="$wifi_op_remaining"
    fi
    run_with_managed_timeout "$wifi_op_limit" "$PWD" "$wifi_op_label" "$@"
)

wait_for_wifi_interface() {
    max_wait="${1:-60}"
    sleep_step="${2:-2}"
    waited=0
    wifi_wait_started=$(get_monotonic_seconds)
    iface=""
    settle_done=0
    reload_done=0
    reload_after=""
    mod=""
    recovery_modules="${WIFI_RECOVERY_MODULES:-ath12k_wifi7 ath12k_pci ath12k_ahb ath11k_pci ath11k_ahb ath11k_snoc ath10k_snoc ath10k_pci ath10k_sdio}"

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

    reload_after="${WIFI_RECOVERY_RELOAD_AFTER_S:-}"
    case "$reload_after" in
        ''|*[!0-9]*)
            reload_after=$((max_wait / 2))
            ;;
    esac

    if [ "$reload_after" -le 0 ] 2>/dev/null; then
        reload_after="$sleep_step"
    fi

    # Keep stdout reserved only for the detected interface name because callers
    # commonly use command substitution:
    # wifi_iface="$(wait_for_wifi_interface ...)"
    #
    # All diagnostics must go to stderr to avoid contaminating the returned
    # interface name.
    wifi_wait_deadline=$((wifi_wait_started + max_wait))
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
                wifi_wait_command 5 wifi-udev udevadm trigger --action=add --subsystem-match=net >/dev/null 2>&1 || true
                wifi_wait_command 5 wifi-settle udevadm settle --timeout=5 >/dev/null 2>&1 || true

                iface="$(get_wifi_interface 2>/dev/null || true)"
                if [ -n "$iface" ]; then
                    printf '%s\n' "$iface"
                    return 0
                fi
            fi
        fi

        if [ "${WIFI_RECOVERY_RELOAD:-1}" = "1" ] &&
           [ "$reload_done" -eq 0 ] &&
           [ "$waited" -ge "$reload_after" ] &&
           command -v modprobe >/dev/null 2>&1; then
            reload_done=1

            for mod in $recovery_modules; do
                [ -n "$mod" ] || continue

                if ! is_module_loaded "$mod"; then
                    continue
                fi

                log_warn "No WiFi interface after ${waited}s; attempting one controlled reload of $mod" >&2

                if wifi_wait_command 10 wifi-unload modprobe -r "$mod" >/dev/null 2>&1; then
                    sleep 2

                    if run_with_managed_timeout 10 "$PWD" wifi-reload modprobe "$mod" >/dev/null 2>&1; then
                        log_info "Reloaded WiFi module: $mod" >&2

                        wifi_unblock_rfkill

                        if command -v udevadm >/dev/null 2>&1; then
                            wifi_wait_command 5 wifi-udev udevadm trigger --action=add --subsystem-match=net >/dev/null 2>&1 || true
                            wifi_wait_command 5 wifi-settle udevadm settle --timeout=5 >/dev/null 2>&1 || true
                        fi

                        iface="$(get_wifi_interface 2>/dev/null || true)"
                        if [ -n "$iface" ]; then
                            printf '%s\n' "$iface"
                            return 0
                        fi
                    else
                        log_warn "Reload failed for WiFi module $mod after unload" >&2
                    fi
                else
                    log_warn "Could not unload WiFi module $mod; it may be busy" >&2
                fi

                # Attempt only one loaded leaf driver module.
                break
            done
        fi

        waited=$(($(get_monotonic_seconds) - wifi_wait_started))
        [ "$waited" -lt "$max_wait" ] || break
        wifi_wait_delay="$sleep_step"
        if [ "$wifi_wait_delay" -gt "$((max_wait - waited))" ]; then
            wifi_wait_delay=$((max_wait - waited))
        fi
        sleep "$wifi_wait_delay"
        waited=$(($(get_monotonic_seconds) - wifi_wait_started))

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

# Return success when there is runtime evidence that WiFi registered a real
# device/phy/netdev.
#
# This intentionally does not treat generic module-only state as success.
# Modules such as cfg80211, mac80211, and mhi may be loaded even when no WiFi
# hardware has registered a phy or netdev.
#
# Used by tests to decide whether missing interface is a real runtime failure
# or a platform/no-device skip.
wifi_stack_present() {
    iface=""

    iface="$(get_wifi_interface 2>/dev/null || true)"
    if [ -n "$iface" ]; then
        return 0
    fi

    if [ -d /sys/class/ieee80211 ]; then
        if find /sys/class/ieee80211 -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep . >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v iw >/dev/null 2>&1; then
        if iw phy 2>/dev/null | grep . >/dev/null 2>&1; then
            return 0
        fi

        if iw dev 2>/dev/null | grep -E '^[[:space:]]*Interface[[:space:]]+' >/dev/null 2>&1; then
            return 0
        fi
    fi

    for n in /sys/class/net/*; do
        [ -e "$n" ] || continue

        if [ -d "$n/wireless" ] || [ -e "$n/phy80211" ]; then
            return 0
        fi
    done

    return 1
}

# Infer target-specific WiFi driver configs from loaded modules and kernel log
# so ATH11K or ATH12K checks are only enforced when relevant on the target.
infer_wifi_driver_cfgs() {
    wifi_cfg_families=$(wifi_runtime_families | sort -u)
    for wifi_cfg_family in $wifi_cfg_families; do
        case "$wifi_cfg_family" in
            ath10k)
                printf '%s\n' CONFIG_ATH10K
                ;;
            ath11k)
                printf '%s\n' CONFIG_ATH11K
                ;;
            ath12k)
                printf '%s\n' CONFIG_ATH12K
                ;;
        esac
    done
}

# Scan kernel logs for WiFi driver probe/runtime failures and print matched
# lines to stdout. Returns success when probe failures are present.
wifi_has_probe_failures() {
    outdir="$1"
    tag="${2:-wifi-probe-check}"
    include_regex="wifi|wlan|ath|cfg80211|mac80211|qca|wcn|firmware|mhi|pci|msi|qmi"
    exclude_regex="using dummy regulator|Loading compiled-in X.509 certificates for regulatory database"
    failure_regex='(ath|wifi|wlan|qca|wcn).*(probe with driver .* failed|failed to alloc msi|qmi dma allocation failed|failed to create .*wlan|failed to register .*wlan|Direct firmware load .* failed|firmware.*failed|failed to load board data|failed to fetch board data|mhi.*failed)|(probe with driver .* failed|failed to alloc msi|qmi dma allocation failed|failed to create .*wlan|failed to register .*wlan|Direct firmware load .* failed|firmware.*failed|failed to load board data|failed to fetch board data|mhi.*failed).*(ath|wifi|wlan|qca|wcn)'
    recoverable_dma_regex='qmi dma allocation failed.*will try later with small size'
    errfile=""
    failure_file=""
    filtered_failure_file=""
    tmp_matches=""
    line=""

    if [ -z "$outdir" ]; then
        outdir="/tmp/wifi_dmesg"
    fi

    mkdir -p "$outdir" >/dev/null 2>&1 || true
    errfile="$outdir/dmesg_errors.log"
    failure_file="$outdir/wifi_probe_failures.log"
    filtered_failure_file="${failure_file}.filtered"
    : >"$failure_file"

    if command -v scan_dmesg_errors >/dev/null 2>&1; then
        scan_dmesg_errors "$outdir" "$include_regex" "$exclude_regex" >/dev/null 2>&1 || true
    fi

    if [ -s "$errfile" ]; then
        grep -Ei "$failure_regex" "$errfile" 2>/dev/null >>"$failure_file" || true
    fi

    tmp_matches="$(
        get_kernel_log 2>/dev/null |
            grep -Ei "$failure_regex" ||
            true
    )"

    if [ -n "$tmp_matches" ]; then
        printf '%s\n' "$tmp_matches" >>"$failure_file"
    fi

    # ath12k can first request a large QMI DMA buffer and then explicitly
    # retry with a smaller buffer. Treat that exact retry/fallback indication
    # as informational; retain all other DMA allocation failures as failures.
    if grep -Eiq "$recoverable_dma_regex" "$failure_file" 2>/dev/null; then
        log_info "[$tag] Ignoring recoverable WiFi QMI DMA allocation fallback(s):"

        grep -Ei "$recoverable_dma_regex" "$failure_file" 2>/dev/null |
            awk '!seen[$0]++' |
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                log_info "[$tag] $line"
            done
    fi

    grep -Eiv "$recoverable_dma_regex" "$failure_file" >"$filtered_failure_file" 2>/dev/null || true
    mv "$filtered_failure_file" "$failure_file"

    if [ -s "$failure_file" ]; then
        awk '!seen[$0]++' "$failure_file" >"${failure_file}.dedup" 2>/dev/null ||
            cp "$failure_file" "${failure_file}.dedup" 2>/dev/null ||
            true

        log_fail "[$tag] matched WiFi probe/runtime failures:"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            log_fail "[$tag] $line"
        done <"${failure_file}.dedup"

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

# wifi_find_firmware_asset <root> <basename-pattern>...
# Prints the first readable regular file or symlink matching the ordered
# patterns. Returns 0 on a match and 1 when the root or asset is unavailable.
# This helper does not modify the firmware tree.
wifi_find_firmware_asset() {
    wifi_ffa_root="$1"
    shift

    [ -d "$wifi_ffa_root" ] || return 1

    for wifi_ffa_name in "$@"; do
        wifi_ffa_path="$(
            find "$wifi_ffa_root" \
                \( -type f -o -type l \) \
                -name "$wifi_ffa_name" \
                -print 2>/dev/null |
                while IFS= read -r wifi_ffa_candidate; do
                    if [ -r "$wifi_ffa_candidate" ]; then
                        printf '%s\n' "$wifi_ffa_candidate"
                        break
                    fi
                done
        )"

        if [ -n "$wifi_ffa_path" ]; then
            printf '%s\n' "$wifi_ffa_path"
            return 0
        fi
    done

    return 1
}

# wifi_driver_family <driver-or-module-name>
# Normalize driver names, never board names or installed firmware directories.
wifi_driver_family() {
    case "$1" in
        ath10k*)
            printf '%s\n' ath10k
            ;;
        ath11k*)
            printf '%s\n' ath11k
            ;;
        ath12k*)
            printf '%s\n' ath12k
            ;;
        *)
            return 1
            ;;
    esac
}

# wifi_bound_family <device-path>
# Resolve the actual bound driver, including built-in drivers without lsmod data.
wifi_bound_family() (
    wifi_bound_path=$(readlink -f "$1/driver") || return 1
    wifi_driver_family "${wifi_bound_path##*/}"
)

# wifi_alias_modules <modalias>
# Resolve only wireless aliases from the running kernel's module metadata.
# This also works with BusyBox modprobe builds lacking --resolve-alias.
wifi_alias_modules() (
    wifi_alias_value="$1"
    for wifi_alias_file in /lib/modules/"$(uname -r)"/modules.alias /lib/modules/"$(uname -r)"/modules.builtin.alias; do
        [ -r "$wifi_alias_file" ] || continue
        awk '$1 == "alias" && $3 ~ /^ath(10|11|12)k/ {print $2, $3}' "$wifi_alias_file" |
            while read -r wifi_alias_pattern wifi_alias_module; do
                # shellcheck disable=SC2254 # Kernel module aliases are glob patterns.
                case "$wifi_alias_value" in
                    $wifi_alias_pattern)
                        printf '%s\n' "$wifi_alias_module"
                        ;;
                esac
            done
    done
)

# wifi_runtime_families
# Enumerate active PHY/bus drivers, then resolve enumerated device modaliases.
# Modaliases include the enabled runtime DT nodes instantiated on the platform
# bus. Installed firmware alone is never evidence of applicable hardware.
wifi_runtime_families() (
    wifi_discovery_started=$(get_monotonic_seconds)
    for wifi_device in /sys/class/ieee80211/*/device /sys/bus/platform/devices/* /sys/bus/pci/devices/* /sys/bus/sdio/devices/*; do
        [ -d "$wifi_device" ] || continue
        if wifi_bound_family "$wifi_device"; then
            continue
        fi
        # A device bound to a different driver is not an unloaded WiFi candidate.
        [ ! -L "$wifi_device/driver" ] || continue
        if [ "$(($(get_monotonic_seconds) - wifi_discovery_started))" -ge 20 ]; then
            log_warn "WiFi runtime alias discovery exceeded 20 seconds" >&2
            return 1
        fi
        [ -r "$wifi_device/modalias" ] || continue
        wifi_alias=$(cat "$wifi_device/modalias")
        # Resolve the installed metadata without loading any module.
        for wifi_module in $(wifi_alias_modules "$wifi_alias"); do
            wifi_driver_family "$wifi_module" || true
        done
    done
    return 0
)

# wifi_family_has_phy <family>
# Require a PHY bound to the requested family, not a sibling radio or module.
wifi_family_has_phy() (
    for wifi_phy in /sys/class/ieee80211/*; do
        [ -d "$wifi_phy" ] || continue
        if [ "$(wifi_bound_family "$wifi_phy/device")" = "$1" ]; then
            log_info "WiFi family $1 has runtime PHY ${wifi_phy##*/}" >&2
            return 0
        fi
    done
    return 1
)

# wifi_detect_firmware_info [family]
# Find a provisioned asset for the runtime family, including compressed files.
wifi_detect_firmware_info() {
    wifi_selected_family="${1:-$(wifi_runtime_families | sort -u | head -n 1)}"
    WIFI_FW_FILE=""
    WIFI_FW_FAMILY=""
    WIFI_FW_BASENAME=""
    WIFI_FW_SIZE=""

    if [ "$wifi_selected_family" = ath12k ] && [ -d /lib/firmware/ath12k ]; then
        WIFI_FW_FILE="$(
            wifi_find_firmware_asset \
                /lib/firmware/ath12k \
                amss.bin \
                amss.bin.xz \
                amss.bin.zst
        )"
        if [ -n "$WIFI_FW_FILE" ]; then
            WIFI_FW_FAMILY="ath12k"
        fi
    fi

    if [ "$wifi_selected_family" = ath11k ] && [ -d /lib/firmware/ath11k ]; then
        WIFI_FW_FILE="$(
            wifi_find_firmware_asset \
                /lib/firmware/ath11k \
                amss.bin \
                amss.bin.xz \
                amss.bin.zst
        )"
        if [ -n "$WIFI_FW_FILE" ]; then
            WIFI_FW_FAMILY="ath11k"
        else
            WIFI_FW_FILE="$(
                wifi_find_firmware_asset \
                    /lib/firmware/ath11k \
                    wpss.mbn \
                    wpss.mbn.xz \
                    wpss.mbn.zst
            )"
            if [ -n "$WIFI_FW_FILE" ]; then
                WIFI_FW_FAMILY="ath11k"
            fi
        fi
    fi

    if [ "$wifi_selected_family" = ath10k ] && [ -d /lib/firmware/ath10k ]; then
        WIFI_FW_FILE="$(
            wifi_find_firmware_asset \
                /lib/firmware/ath10k \
                wlanmdsp.mbn \
                wlanmdsp.mbn.xz \
                wlanmdsp.mbn.zst
        )"
        if [ -n "$WIFI_FW_FILE" ]; then
            WIFI_FW_FAMILY="ath10k"
        else
            WIFI_FW_FILE="$(
                wifi_find_firmware_asset \
                    /lib/firmware/ath10k \
                    'firmware-*.bin' \
                    'firmware-*.bin.xz' \
                    'firmware-*.bin.zst'
            )"
            if [ -n "$WIFI_FW_FILE" ]; then
                WIFI_FW_FAMILY="ath10k"
            fi
        fi
    fi

    if [ -z "$WIFI_FW_FILE" ] || [ -z "$WIFI_FW_FAMILY" ]; then
        return 1
    fi

    WIFI_FW_BASENAME="${WIFI_FW_FILE##*/}"
    WIFI_FW_SIZE="$(stat -Lc%s "$WIFI_FW_FILE" 2>/dev/null || echo unknown)"

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

        if run_with_managed_timeout 15 "$PWD" wifi-load modprobe "$mod" 2>/dev/null; then
            log_info "Loaded WiFi module: $mod"
            return 0
        fi
    done

    return 1
}

# Perform family-specific WiFi runtime preparation for ath12k, ath11k, or
# ath10k using logging only; callers decide the final testcase result.
wifi_handle_firmware_family() {
    if wifi_family_has_phy "$1"; then
        return 0
    fi
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
                wpss.mbn|wpss.mbn.xz|wpss.mbn.zst)
                    log_info "ath11k WPSS firmware detected, validating wpss remoteproc."
                    if validate_remoteproc_running "wpss"; then
                        log_info "Remoteproc 'wpss' is active and validated."
                        return 0
                    fi
                    log_fail "Remoteproc 'wpss' validation failed."
                    return 1
                    ;;
                amss.bin|amss.bin.xz|amss.bin.zst)
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
    if wifi_family_has_phy "$1"; then
        return 0
    fi
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
    wifi_phy_started=$(get_monotonic_seconds)
    while [ "$(($(get_monotonic_seconds) - wifi_phy_started))" -lt 15 ]; do
        if wifi_family_has_phy "$1"; then
            return 0
        fi
        sleep 1
    done
    return 1
}
