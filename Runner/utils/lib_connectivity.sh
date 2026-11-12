#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Connectivity-specific helper library layered on top of functestlib.sh.
# Source functestlib.sh before sourcing this file.
# Best-effort helper to unblock WiFi before discovery or retry loops.
# Silent success is acceptable on minimal images where rfkill may be absent.
wifi_unblock_rfkill() (
    wur_selected="${1:-${WIFI_IFACE:-}}"
    wur_device=""
    if [ -n "$wur_selected" ]; then
        wur_device=$(readlink -f "/sys/class/net/$wur_selected/device") || return 1
    fi
    for wur_node in /sys/class/rfkill/rfkill*; do
        [ -r "$wur_node/type" ] || continue
        [ "$(cat "$wur_node/type")" = wlan ] || continue
        wur_radio=$(readlink -f "$wur_node/device") || continue
        if [ -n "$wur_device" ]; then
            case "$wur_radio" in
                "$wur_device"|"$wur_device"/*)
                    ;;
                *)
                    continue
                    ;;
            esac
        fi
        if [ "$(cat "$wur_node/soft")" = 1 ]; then
            printf '%s\n' 0 >"$wur_node/soft" || return 1
        fi
    done
)

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

wait_for_wifi_interface() (
    max_wait="${1:-60}"
    sleep_step="${2:-2}"
    waited=0
    wifi_wait_started=$(get_monotonic_seconds)
    iface=""
    settle_done=0
    reload_done=0
    reload_after=""
    mod=""
    wifi_restore_module=""
    trap 'if [ -n "$wifi_restore_module" ]; then
        run_with_managed_timeout 10 "$PWD" wifi-restore modprobe "$wifi_restore_module" >&2 || exit 3
    fi' 0
    trap 'exit 3' HUP INT TERM
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
        wifi_unblock_rfkill "${WIFI_IFACE:-}"

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

                wifi_restore_module="$mod"
                if wifi_wait_command 10 wifi-unload modprobe -r "$mod" >/dev/null 2>&1; then
                    sleep 2

                    if run_with_managed_timeout 10 "$PWD" wifi-reload modprobe "$mod" >/dev/null 2>&1; then
                        wifi_restore_module=""
                        log_info "Reloaded WiFi module: $mod" >&2

                        wifi_unblock_rfkill "${WIFI_IFACE:-}"

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
                        log_fail "Reload failed for WiFi module $mod after unload" >&2
                        return 3
                    fi
                else
                    if is_module_loaded "$mod"; then
                        wifi_restore_module=""
                    fi
                    log_warn "Could not unload WiFi module $mod, it may be busy" >&2
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
)

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

# wifi_filter_regulatory_warnings <captured-log> <warning-file>
# Print remaining lines and retain only optional global database lookup warnings.
# No kernel read or readiness claim occurs. Callers must validate their runtime.
# Return 0 on successful classification, 2 on unavailable input/output.
wifi_filter_regulatory_warnings() (
    wfrw_input="$1"
    wfrw_warnings="$2"
    [ -r "$wfrw_input" ] || return 2
    : >"$wfrw_warnings" || return 2
    awk -v warnings="$wfrw_warnings" '
        {
            text=$0
            sub(/^[[:space:]]*/, "", text)
            while (text ~ /^\[[^]]*\]/) {
                sub(/^\[[^]]*\][[:space:]]*/, "", text)
            }
            if (text ~ /^cfg80211: failed to load regulatory[.]db[[:space:]]*$/ ||
                text ~ /^[^:]*regulatory: Direct firmware load for regulatory[.]db failed with error -2[[:space:]]*$/) {
                print $0 >> warnings
            } else {
                print
            }
        }
    ' "$wfrw_input" || return 2
)

# wifi_fallback_runtime_ready <driver> <controller> <mac|regulatory> <output-directory>
# Validate the exact warning owner through bound PHY/netdev state. No mutation.
# Print readiness diagnostics. Return 0 when usable, 1 when broken, 2 when the
# image lacks required evidence tools. Retain bounded iw output in the directory.
wifi_fallback_runtime_ready() (
    wfr_driver="$1"
    wfr_controller="$2"
    wfr_kind="$3"
    wfr_out="$4"
    for wfr_phy in /sys/class/ieee80211/*; do
        [ -d "$wfr_phy" ] || continue
        wfr_device=$(readlink -f "$wfr_phy/device") || continue
        [ "${wfr_device##*/}" = "$wfr_controller" ] || continue
        wfr_bound=$(readlink -f "$wfr_device/driver") || continue
        [ "${wfr_bound##*/}" = "$wfr_driver" ] || continue
        wfr_netdev=""
        for wfr_net in /sys/class/net/*; do
            [ "$(readlink -f "$wfr_net/phy80211" 2>/dev/null)" = "$(readlink -f "$wfr_phy")" ] || continue
            wfr_mac=$(cat "$wfr_net/address" 2>/dev/null) || continue
            if printf '%s\n' "$wfr_mac" | awk -F: '
                NF != 6 { exit 1 }
                {
                    for (part=1; part<=6; part++) {
                        if ($part !~ /^[[:xdigit:]][[:xdigit:]]$/) exit 1
                    }
                    if ($0 == "00:00:00:00:00:00" ||
                        substr($1, 2, 1) !~ /[02468aAcCeE]/) exit 1
                }
            '; then
                wfr_netdev=${wfr_net##*/}
                break
            fi
        done
        if [ -z "$wfr_netdev" ]; then
            log_fail "WiFi fallback owner=$wfr_controller has no matching netdev with a valid unicast MAC"
            return 1
        fi
        log_info "WiFi fallback owner=$wfr_controller driver=$wfr_driver phy=${wfr_phy##*/} interface=$wfr_netdev effective_mac=$wfr_mac"
        [ "$wfr_kind" = regulatory ] || return 0
        if ! command -v iw >/dev/null 2>&1; then
            log_warn "Regulatory fallback health is unverified, image-provided iw is required"
            return 2
        fi
        wfr_name=${wfr_phy##*/}
        run_with_timeout_log 5 "$wfr_out/$wfr_name-info.log" iw phy "$wfr_name" info || return 1
        run_with_timeout_log 5 "$wfr_out/$wfr_name-reg.log" iw reg get || return 1
        # A retained domain must have rules and the selected PHY must expose
        # usable channels. NO-IR/passive channels are valid, disabled ones are not.
        awk '/\*.*MHz.*\[[0-9]+\]/ && !/disabled/ { usable=1 }
             END { exit !usable }' "$wfr_out/$wfr_name-info.log" || return 1
        awk -v selected="${wfr_name#phy}" '
            /^global/ { section="global" }
            /^phy#/ {
                id=$1
                sub(/^phy#/, "", id)
                section=id
                if (id == selected) found=1
            }
            /^[[:space:]]*country ([A-Z][A-Z]|00):/ { country[section]=1 }
            /^[[:space:]]*\([0-9]+.* - [0-9]+/ { rules[section]=1 }
            END {
                key=found ? selected : "global"
                exit !(country[key] && rules[key])
            }
        ' "$wfr_out/$wfr_name-reg.log" || return 1
        log_info "WiFi regulatory fallback owner=$wfr_controller retains a domain with usable channels, no country change was requested by this test"
        return 0
    done
    log_fail "WiFi fallback owner=$wfr_controller driver=$wfr_driver has no bound wireless PHY"
    return 1
)

# wifi_classify_probe_failures <captured-directory> [initial|final]
# Classify retained scanner candidates without a new kernel read. Initial checks
# defer only documented fallbacks, final checks require matching runtime proof.
# Print diagnostics and retain candidates/readiness/failures. Return 0 for faults,
# 1 for no confirmed faults, 2 for unavailable evidence. Never infer testcase PASS.
wifi_classify_probe_failures() (
    wcp_dir="$1"
    wcp_phase="${2:-final}"
    case "$wcp_phase" in
        initial|final)
            ;;
        *)
            return 2
            ;;
    esac
    [ -s "$wcp_dir/dmesg_snapshot.log" ] && [ -r "$wcp_dir/dmesg_errors.log" ] || return 2
    wifi_filter_regulatory_warnings "$wcp_dir/dmesg_errors.log" \
        "$wcp_dir/wifi_regulatory_warnings.log" >"$wcp_dir/wifi_candidates.log" || return 2
    : >"$wcp_dir/wifi_fallbacks.log" || return 2
    : >"$wcp_dir/wifi_fallback_owners.log" || return 2
    awk -v warnings="$wcp_dir/wifi_fallbacks.log" \
        -v owners="$wcp_dir/wifi_fallback_owners.log" '
        {
            text=$0
            sub(/^[[:space:]]*/, "", text)
            while (text ~ /^\[[^]]*\]/) sub(/^\[[^]]*\][[:space:]]*/, "", text)
            kind=""
            if (text ~ /^ath10k[^[:space:]:]* [^[:space:]]+: invalid MAC address; choosing random$/) kind="mac"
            if (text ~ /^ath11k[^[:space:]:]* [^[:space:]]+: Failed to set the requested Country regulatory setting$/) kind="regulatory"
            split(text, fields, " ")
            owner=fields[2]
            sub(/:$/, "", owner)
            key=fields[1] "|" owner
            if (owner !~ /^[[:alnum:]_.:-]+$/) kind=""
            # Controllers can log concurrently. Pair the next error from this
            # controller only, never borrow a country warning from another radio.
            if (text ~ /^ath11k[^[:space:]:]* [^[:space:]]+: failed to process regulatory info -22$/ && pending[key]) kind="regulatory"
            delete pending[key]
            if (text ~ /: Failed to set the requested Country regulatory setting$/ && kind == "regulatory") pending[key]=1
            if (kind != "") {
                print $0 >> warnings
                print fields[1] "|" owner "|" kind >> owners
            } else {
                print
            }
        }
    ' "$wcp_dir/wifi_candidates.log" >"$wcp_dir/wifi_probe_failures.log" || return 2
    # Driver crash notifications need not contain the generic scanner error
    # keywords. Keep these fatal events even when the radio recovered later.
    awk '
        {
            text=tolower($0)
            sub(/^[[:space:]]*/, "", text)
            while (text ~ /^\[[^]]*\]/) sub(/^\[[^]]*\][[:space:]]*/, "", text)
            if (text ~ /^ath(10|11|12)k[^[:space:]:]*([[:space:]][^:]*)?:.*firmware crashed([[:space:][:punct:]]|$)/) print
        }
    ' "$wcp_dir/dmesg_snapshot.log" >"$wcp_dir/wifi_crashes.log" || return 2
    cat "$wcp_dir/wifi_crashes.log" >>"$wcp_dir/wifi_probe_failures.log" || return 2
    if [ -s "$wcp_dir/wifi_regulatory_warnings.log" ]; then
        log_warn "Global regulatory database lookup failed, wireless runtime validation is still required"
        log_file_with_label WIFI-REGULATORY "$wcp_dir/wifi_regulatory_warnings.log"
    fi
    wcp_unverified=0
    sort -u "$wcp_dir/wifi_fallback_owners.log" >"$wcp_dir/wifi_fallback_owners.list" || return 2
    while IFS='|' read -r wcp_driver wcp_owner wcp_kind; do
        if [ "$wcp_phase" = initial ]; then
            log_warn "WiFi $wcp_kind fallback owner=$wcp_owner is pending runtime and functional validation"
            continue
        fi
        wcp_artifact=$(printf '%s' "$wcp_owner" | tr ':' '-') || return 2
        wifi_fallback_runtime_ready "$wcp_driver" "$wcp_owner" "$wcp_kind" "$wcp_dir" \
            >"$wcp_dir/$wcp_artifact-$wcp_kind-readiness.log" 2>&1
        wcp_status=$?
        log_file_with_label WIFI-FALLBACK-READINESS "$wcp_dir/$wcp_artifact-$wcp_kind-readiness.log"
        case "$wcp_status" in
            0)
                ;;
            2)
                wcp_unverified=1
                ;;
            *)
                printf 'WiFi %s fallback validation failed for %s driver=%s\n' \
                    "$wcp_kind" "$wcp_owner" "$wcp_driver" >>"$wcp_dir/wifi_probe_failures.log" || return 2
                ;;
        esac
    done <"$wcp_dir/wifi_fallback_owners.list"
    if [ -s "$wcp_dir/wifi_fallbacks.log" ]; then
        log_file_with_label WIFI-FALLBACK "$wcp_dir/wifi_fallbacks.log"
    fi
    if [ -s "$wcp_dir/wifi_probe_failures.log" ]; then
        log_file_with_label WIFI-ERROR "$wcp_dir/wifi_probe_failures.log"
        return 0
    fi
    [ "$wcp_unverified" -eq 0 ] || return 2
    return 1
)

# wifi_has_probe_failures <output-directory> [tag] [initial|final]
# Capture WiFi kernel health and classify through the shared runtime contract.
# Return 0 for faults, 1 for no confirmed faults, 2 for unavailable evidence.
wifi_has_probe_failures() {
    wpf_out="${1:-$PWD/wifi_dmesg}"
    wpf_tag="${2:-wifi-probe-check}"
    # Firmware failures must belong to WiFi, Bluetooth shares QCA/WCN names.
    wpf_include='ath(10|11|12)k[^[:space:]:]*|wifi[^[:space:]:]*|wlan[^[:space:]:]*|cfg80211|mac80211|([^[:space:]:]+[[:space:]]+)?regulatory'
    wpf_exclude='using dummy regulator|Loading compiled-in X.509 certificates for regulatory database|qmi dma allocation failed.*will try later with small size'
    mkdir -p "$wpf_out" || return 2
    scan_dmesg_errors "$wpf_out" "$wpf_include" "$wpf_exclude" || true
    if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
        log_warn "[$wpf_tag] Kernel health unverified, inspect $wpf_out/dmesg_access.log"
        return 2
    fi
    wifi_classify_probe_failures "$wpf_out" "${3:-final}"
}

# wifi_dump_runtime_info [output-directory]
# Print bounded iw/ip and sysfs diagnostics, retaining full command output in CWD.
# No radio changes or kernel reads occur. Return 1 only for artifact setup failure.
wifi_dump_runtime_info() {
    wdr_out="${1:-$PWD/wifi_runtime}"
    mkdir -p "$wdr_out" || return 1
    for wdr_label in iw-dev iw-phy iw-reg ip-link; do
        case "$wdr_label" in
            iw-dev)
                set -- iw dev
                ;;
            iw-phy)
                set -- iw phy
                ;;
            iw-reg)
                set -- iw reg get
                ;;
            ip-link)
                set -- ip -details link show
                ;;
        esac
        if command -v "$1" >/dev/null 2>&1; then
            run_with_timeout_log 5 "$wdr_out/$wdr_label.log" "$@"
            wdr_status=$?
            log_info "WiFi diagnostic=$wdr_label exit_status=$wdr_status artifact=$wdr_out/$wdr_label.log"
            log_file_with_label "$wdr_label" "$wdr_out/$wdr_label.log" 80
        else
            log_warn "WiFi diagnostic=$wdr_label unavailable, image has no $1"
        fi
    done
    : >"$wdr_out/sysfs.log" || return 1
    for wdr_phy_path in /sys/class/ieee80211/*; do
        [ -d "$wdr_phy_path" ] || continue
        wdr_phy_device=$(readlink -f "$wdr_phy_path/device" 2>/dev/null || true)
        wdr_phy_driver=$(readlink -f "$wdr_phy_path/device/driver" 2>/dev/null || true)
        printf 'phy=%s driver=%s device=%s\n' "${wdr_phy_path##*/}" \
            "${wdr_phy_driver:-unbound}" "${wdr_phy_device:-unavailable}" >>"$wdr_out/sysfs.log"
        wdr_parent="$wdr_phy_device"
        while [ -n "$wdr_parent" ] && [ "$wdr_parent" != / ]; do
            wdr_dt=$(readlink -f "$wdr_parent/of_node" 2>/dev/null || true)
            if [ -d "$wdr_dt" ]; then
                wdr_compatible=$(dt_property_text "$wdr_dt" compatible 2>/dev/null || true)
                printf 'phy=%s dt=%s compatible=%s\n' "${wdr_phy_path##*/}" \
                    "$wdr_dt" "$wdr_compatible" >>"$wdr_out/sysfs.log"
                break
            fi
            wdr_parent=${wdr_parent%/*}
        done
    done
    for n in /sys/class/net/*; do
        [ -e "$n" ] || continue
        [ -e "$n/phy80211" ] || [ -d "$n/wireless" ] || continue
        i="${n##*/}"
        marker="$i:"
        for wdr_property in address addr_assign_type flags operstate; do
            wdr_value=$(cat "$n/$wdr_property" 2>/dev/null || printf '%s' unavailable)
            marker="$marker $wdr_property=$wdr_value"
        done
        wdr_driver=$(readlink -f "$n/device/driver" 2>/dev/null || true)
        wdr_phy=$(readlink -f "$n/phy80211" 2>/dev/null || true)
        dev_path="$(readlink -f "$n/device" 2>/dev/null || true)"
        printf '%s driver=%s phy=%s device=%s\n' "$marker" \
            "${wdr_driver:-unbound}" "${wdr_phy:-unavailable}" "${dev_path:-unavailable}" >>"$wdr_out/sysfs.log"
    done
    for wdr_radio in /sys/class/rfkill/*; do
        [ -r "$wdr_radio/type" ] || continue
        [ "$(cat "$wdr_radio/type")" = wlan ] || continue
        printf 'rfkill=%s name=%s soft=%s hard=%s\n' "${wdr_radio##*/}" \
            "$(cat "$wdr_radio/name" 2>/dev/null)" "$(cat "$wdr_radio/soft" 2>/dev/null)" \
            "$(cat "$wdr_radio/hard" 2>/dev/null)" >>"$wdr_out/sysfs.log"
    done
    log_file_with_label WIFI-SYSFS "$wdr_out/sysfs.log" 80
    return 0
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

    WIFI_FW_FAMILY="$wifi_selected_family"
    # shellcheck disable=SC2034 # Reported by the firmware runner.
    # shellcheck disable=SC2034 # Public result consumed by another script.
    WIFI_FW_EVIDENCE="asset"
    # DT firmware requests belong to the bound wireless PHY's controller.
    for wifi_fw_phy in /sys/class/ieee80211/*; do
        [ -e "$wifi_fw_phy" ] || continue
        [ "$(wifi_bound_family "$wifi_fw_phy/device")" = "$wifi_selected_family" ] || continue
        wifi_fw_owner=$(readlink -f "$wifi_fw_phy/device") || continue
        while [ "$wifi_fw_owner" != / ]; do
            wifi_fw_dt=$(readlink -f "$wifi_fw_owner/of_node" 2>/dev/null || true)
            if [ -d "$wifi_fw_dt" ] && dt_node_enabled "$wifi_fw_dt"; then
                for wifi_fw_property in firmware-name qcom,firmware-name; do
                    wifi_fw_request=$(dt_property_text "$wifi_fw_dt" "$wifi_fw_property" 2>/dev/null || true)
                    for wifi_fw_part in $wifi_fw_request; do
                        if WIFI_FW_FILE=$(find_image_firmware "$wifi_fw_part"); then
                            WIFI_FW_BASENAME="${WIFI_FW_FILE##*/}"
                            WIFI_FW_SIZE=$(stat -Lc%s "$WIFI_FW_FILE" 2>/dev/null || printf '%s' unknown)
                            return 0
                        fi
                    done
                done
            fi
            wifi_fw_owner=${wifi_fw_owner%/*}
            [ -n "$wifi_fw_owner" ] || break
        done
        # Registered PHY is stronger runtime proof than an unrelated family's
        # first firmware file. Built-in or consumed firmware need not stay on disk.
        WIFI_FW_FILE="not-exposed"
        WIFI_FW_BASENAME=""
        WIFI_FW_SIZE="unknown"
        # shellcheck disable=SC2034 # Public result consumed by another script.
        WIFI_FW_EVIDENCE="registered-phy"
        return 0
    done
    # Keep image-asset discovery for unbound legacy transports as diagnostics.
    # A candidate below is not consumed-firmware proof, the PHY check still gates.
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

# wifi_firmware_loaded <family> [log-tag] [timeout-seconds]
# Poll for a PHY bound to the selected family without restarting hardware.
# Returns 0 when ready, 1 on timeout and 2 for invalid input or interrupted wait.
# Diagnostics go to stderr. Callers must validate retained kernel health too.
wifi_firmware_loaded() (
    wifi_phy_limit="${3:-60}"
    if ! is_unsigned_number "$wifi_phy_limit" ||
       ! [ "$wifi_phy_limit" -gt 0 ] 2>/dev/null ||
       ! [ "$wifi_phy_limit" -le 3600 ] 2>/dev/null; then
        log_fail "WiFi readiness timeout must be a whole number from 1 to 3600 seconds" >&2
        return 2
    fi
    wifi_phy_limit=$(printf '%s\n' "$wifi_phy_limit" | awk '{ printf "%d", $1 }')
    wifi_phy_started=$(get_monotonic_seconds)
    wifi_phy_polls=0
    wifi_phy_progress=0
    while :; do
        wifi_phy_elapsed=$(($(get_monotonic_seconds) - wifi_phy_started))
        if wifi_family_has_phy "$1"; then
            log_info "[WIFI-READINESS] family=$1 status=ready elapsed=${wifi_phy_elapsed}s timeout=${wifi_phy_limit}s" >&2
            return 0
        fi
        # Bound the poll count too if no usable monotonic clock is exposed.
        if [ "$wifi_phy_elapsed" -ge "$wifi_phy_limit" ] ||
           [ "$wifi_phy_polls" -ge "$wifi_phy_limit" ]; then
            log_fail "[WIFI-READINESS] family=$1 status=timeout elapsed=${wifi_phy_elapsed}s timeout=${wifi_phy_limit}s, no bound wireless PHY appeared" >&2
            return 1
        fi
        if [ "$wifi_phy_polls" -ge "$wifi_phy_progress" ]; then
            log_info "[WIFI-READINESS] family=$1 status=waiting elapsed=${wifi_phy_elapsed}s timeout=${wifi_phy_limit}s" >&2
            wifi_phy_progress=$((wifi_phy_polls + 10))
        fi
        sleep 1 || return 2
        wifi_phy_polls=$((wifi_phy_polls + 1))
    done
)
