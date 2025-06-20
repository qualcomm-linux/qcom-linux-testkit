#!/bin/sh
 
#Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#SPDX-License-Identifier: BSD-3-Clause-Clear
 
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

TESTNAME="Ethernet"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
summary_file="./$TESTNAME.summary"
rm -f "$res_file" "$summary_file"
 
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Check for dependencies
check_dependencies ip ping

# User-specified interface (argument) or all detected
user_iface="$1"
if [ -n "$user_iface" ]; then
    ETH_IFACES="$user_iface"
    log_info "User specified interface: $user_iface"
else
    ETH_IFACES="$(get_ethernet_interfaces)"
    log_info "Auto-detected Ethernet interfaces: $ETH_IFACES"
fi

if [ -z "$ETH_IFACES" ]; then
    log_warn "No Ethernet interfaces detected."
    echo "No Ethernet interfaces detected." >> "$summary_file"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

any_passed=0
any_tested=0

for iface in $ETH_IFACES; do
    log_info "---- Testing interface: $iface ----"

    if ! is_interface_up "$iface"; then
        log_warn "$iface is DOWN, skipping"
        echo "$iface: SKIP (down/no cable)" >> "$summary_file"
        continue
    fi

    ip_addr=$(get_ip_address "$iface")
    if [ -z "$ip_addr" ]; then
        if try_dhcp_client_safe "$iface" 10; then
            ip_addr=$(get_ip_address "$iface")
            log_info "$iface obtained IP after DHCP: $ip_addr"
        fi
    fi

    if [ -z "$ip_addr" ]; then
        log_warn "$iface did not obtain an IP address after DHCP attempt, skipping"
        echo "$iface: SKIP (no IP, DHCP failed)" >> "$summary_file"
        continue
    fi

    if echo "$ip_addr" | grep -q '^169\.254'; then
        log_warn "$iface got only link-local IP ($ip_addr), skipping"
        echo "$iface: SKIP (link-local only: $ip_addr)" >> "$summary_file"
        continue
    fi

    log_pass "$iface is UP"
    log_info "$iface got IP: $ip_addr"

    any_tested=1
    retries=3
    pass=0
    for i in $(seq 1 $retries); do
        if ping -I "$iface" -c 4 -W 2 8.8.8.8 >/dev/null 2>&1; then
            log_pass "Ethernet connectivity verified via ping"
            echo "$iface: PASS (IP: $ip_addr, ping OK)" >> "$summary_file"
            pass=1
            any_passed=1
            break
        else
            log_warn "Ping failed for $iface (attempt $i/$retries)"
            sleep 2
        fi
    done

    if [ "$pass" -eq 0 ]; then
        log_fail "Ping test failed for $iface"
        echo "$iface: FAIL (IP: $ip_addr, ping failed)" >> "$summary_file"
    fi
done

log_info "---- Ethernet Interface Test Summary ----"
if [ -f "$summary_file" ]; then
    cat "$summary_file"
else
    log_info "No summary information recorded."
fi

if [ "$any_passed" -gt 0 ]; then
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
elif [ "$any_tested" -gt 0 ]; then
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
else
    log_warn "No interfaces were tested (all were skipped)."
    echo "No suitable Ethernet interfaces found. All were down, link-local, or failed to get IP." >> "$summary_file"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
