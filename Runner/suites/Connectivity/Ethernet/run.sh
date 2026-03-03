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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Ethernet"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

res_file="./$TESTNAME.res"
summary_file="./$TESTNAME.summary"
rm -f "$res_file" "$summary_file"
: >"$summary_file"

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Config knobs (safe defaults)
LINK_TIMEOUT_S="${LINK_TIMEOUT_S:-5}"
IP_TIMEOUT_S="${IP_TIMEOUT_S:-10}"
PING_TARGET="${PING_TARGET:-8.8.8.8}"
PING_COUNT="${PING_COUNT:-4}"
PING_WAIT_S="${PING_WAIT_S:-2}"
PING_RETRIES="${PING_RETRIES:-3}"

log_info "Config: LINK_TIMEOUT_S=${LINK_TIMEOUT_S} IP_TIMEOUT_S=${IP_TIMEOUT_S} PING_TARGET=${PING_TARGET} PING_RETRIES=${PING_RETRIES} PING_COUNT=${PING_COUNT} PING_WAIT_S=${PING_WAIT_S}"

# Gate on kernel config BEFORE dependency checks (as requested)
if ! check_kernel_config "CONFIG_QCA808X_PHY"; then
    log_warn "$TESTNAME : CONFIG_QCA808X_PHY not enabled; skipping Ethernet test"
    echo "$TESTNAME SKIP" >"$res_file"
    exit 0
fi

# Check for dependencies
check_dependencies ip ping

# ethtool is required for robust fallback on 100M-locked ports
if ! command -v ethtool >/dev/null 2>&1; then
    log_warn "ethtool not found; cannot apply robust link-speed fallback; skipping"
    echo "$TESTNAME SKIP" >"$res_file"
    exit 0
fi

ETH_IFACES="$(get_ethernet_interfaces)"
log_info "Auto-detected Ethernet interfaces: $ETH_IFACES"

if [ -z "$ETH_IFACES" ]; then
    log_warn "No Ethernet interfaces detected."
    echo "No Ethernet interfaces detected." >>"$summary_file"
    echo "$TESTNAME SKIP" >"$res_file"
    exit 0
fi

# Detect if a network manager is active once (avoid fighting it per interface)
nm_active=0
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet NetworkManager 2>/dev/null \
       || systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        nm_active=1
    fi
fi

if [ "$nm_active" -eq 1 ]; then
    log_info "Network manager detected (NetworkManager/systemd-networkd active): will wait for IP, will NOT run udhcpc."
else
    log_info "No network manager detected: will use try_dhcp_client_safe if IP is missing."
fi

any_passed=0
any_tested=0
any_skipped=0

for iface in $ETH_IFACES; do
    log_info "---- Testing interface: $iface ----"

    # FAST PATH (no ethtool dependency here):
    # If link is already up AND a valid (non-link-local) IPv4 exists, skip bring-up/DHCP.
    ip_addr="$(get_ip_address "$iface" 2>/dev/null || true)"
    if is_valid_ipv4 "$ip_addr" && iface_link_up "$iface"; then
        log_info "$iface fast-path: link is up and valid IP already present ($ip_addr). Skipping link bring-up/IP acquisition."

        log_pass "$iface is UP"
        log_info "$iface got IP: $ip_addr"
        any_tested=1

        if run_ping_check "$iface"; then
            log_pass "Ethernet connectivity verified via ping"
            echo "$iface: PASS (IP: $ip_addr, ping OK)" >>"$summary_file"
            any_passed=1
        else
            log_fail "Ping test failed for $iface"
            echo "$iface: FAIL (IP: $ip_addr, ping failed)" >>"$summary_file"
        fi

        continue
    fi

    # Debug snapshot (compact)
    carrier="?"
    if [ -r "/sys/class/net/$iface/carrier" ]; then
        carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "?")
    fi
    log_info "$iface: initial carrier=$carrier"
    ip link show "$iface" 2>/dev/null | while IFS= read -r l; do [ -n "$l" ] && log_info "[ip-link] $l"; done
    ethtool "$iface" 2>/dev/null | awk -F': ' '/^[[:space:]]*(Speed:|Duplex:|Auto-negotiation:|Link detected:)/ {print}' \
        | while IFS= read -r l; do [ -n "$l" ] && log_info "[ethtool] $l"; done

    log_info "Bringing link up with fallback for $iface (timeout=${LINK_TIMEOUT_S}s)..."
    if ethEnsureLinkUpWithFallback "$iface" "$LINK_TIMEOUT_S"; then
        sp="-"
        if sp=$(ethGetLinkSpeedMbps "$iface" 2>/dev/null); then
            log_info "$iface link is UP (speed=${sp}Mb/s)"
        else
            log_info "$iface link is UP (speed=unknown)"
        fi
        ethtool "$iface" 2>/dev/null | awk -F': ' '/^[[:space:]]*(Speed:|Duplex:|Auto-negotiation:|Link detected:)/ {print}' \
            | while IFS= read -r l; do [ -n "$l" ] && log_info "[ethtool] $l"; done
    else
        # Decide SKIP/FAIL post-failure
        carrier="?"
        if [ -r "/sys/class/net/$iface/carrier" ]; then
            carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "?")
        fi

        log_info "Link bring-up failed for $iface. Diagnostics:"
        ip link show "$iface" 2>/dev/null | while IFS= read -r l; do [ -n "$l" ] && log_info "[ip-link] $l"; done
        ethtool "$iface" 2>/dev/null | sed -n '1,80p' | while IFS= read -r l; do [ -n "$l" ] && log_info "[ethtool] $l"; done

        if [ "$carrier" = "0" ]; then
            log_warn "$iface: no link detected (carrier=0); treating as no-cable and skipping"
            echo "$iface: SKIP (no cable/link; carrier=0)" >>"$summary_file"
            any_skipped=1
        elif [ "$carrier" = "1" ]; then
            log_fail "$iface: carrier=1 but link did not come up after fallback; failing"
            echo "$iface: FAIL (link bring-up failed; carrier=1)" >>"$summary_file"
            any_tested=1
        else
            link_detected="unknown"
            link_detected=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/^[[:space:]]*Link detected:/ {print $2; exit 0}' || true)
            [ -n "$link_detected" ] || link_detected="unknown"

            if [ "$link_detected" = "no" ]; then
                log_warn "$iface: Link detected: no; treating as no-cable and skipping"
                echo "$iface: SKIP (no cable/link; ethtool Link detected: no)" >>"$summary_file"
                any_skipped=1
            else
                log_fail "$iface: link did not come up after fallback (carrier unknown, Link detected=${link_detected}); failing"
                echo "$iface: FAIL (link bring-up failed; carrier unknown, Link detected=${link_detected})" >>"$summary_file"
                any_tested=1
            fi
        fi
        continue
    fi

    # IP acquisition only if needed
    ip_addr="$(get_ip_address "$iface" 2>/dev/null || true)"
    if [ -n "$ip_addr" ]; then
        log_info "$iface pre-existing IP: $ip_addr"
    else
        log_info "$iface has no IPv4 address yet."
    fi

    if ! is_valid_ipv4 "$ip_addr"; then
        if [ "$nm_active" -eq 1 ]; then
            log_info "Waiting up to ${IP_TIMEOUT_S}s for IP on $iface (managed by network manager)..."
            ip_addr="$(wait_for_ip_address "$iface" "$IP_TIMEOUT_S" 2>/dev/null || true)"
        else
            log_info "Attempting safe DHCP on $iface (timeout=${IP_TIMEOUT_S}s)..."
            if try_dhcp_client_safe "$iface" "$IP_TIMEOUT_S"; then
                ip_addr="$(get_ip_address "$iface" 2>/dev/null || true)"
            fi
        fi
    fi

    ip -4 addr show "$iface" 2>/dev/null | while IFS= read -r l; do [ -n "$l" ] && log_info "[ip-addr] $l"; done
    ip route show dev "$iface" 2>/dev/null | sed -n '1,40p' | while IFS= read -r l; do [ -n "$l" ] && log_info "[ip-route:$iface] $l"; done

    if ! is_valid_ipv4 "$ip_addr"; then
        if [ -z "$ip_addr" ]; then
            log_warn "$iface did not obtain an IP address, skipping"
            echo "$iface: SKIP (no IP)" >>"$summary_file"
            any_skipped=1
        else
            log_warn "$iface got only link-local IP ($ip_addr), skipping"
            echo "$iface: SKIP (link-local only: $ip_addr)" >>"$summary_file"
            any_skipped=1
        fi
        continue
    fi

    log_pass "$iface is UP"
    log_info "$iface got IP: $ip_addr"

    any_tested=1

    if run_ping_check "$iface"; then
        log_pass "Ethernet connectivity verified via ping"
        echo "$iface: PASS (IP: $ip_addr, ping OK)" >>"$summary_file"
        any_passed=1
    else
        log_fail "Ping test failed for $iface"
        echo "$iface: FAIL (IP: $ip_addr, ping failed)" >>"$summary_file"
    fi
done

log_info "---- Ethernet Interface Test Summary ----"
if [ -f "$summary_file" ]; then
    cat "$summary_file"
else
    log_info "No summary information recorded."
fi

# Option B: use any_skipped so ShellCheck doesn't warn, and keep it visible in logs.
log_info "Counters: any_tested=$any_tested any_passed=$any_passed any_skipped=$any_skipped"

if [ "$any_passed" -gt 0 ]; then
    echo "$TESTNAME PASS" >"$res_file"
    exit 0
fi

if [ "$any_tested" -gt 0 ]; then
    echo "$TESTNAME FAIL" >"$res_file"
    exit 0
fi

log_warn "No interfaces were tested (all were skipped)."
echo "No suitable Ethernet interfaces found. All were no-link, link-local, or no-IP." >>"$summary_file"
echo "$TESTNAME SKIP" >"$res_file"
exit 0
