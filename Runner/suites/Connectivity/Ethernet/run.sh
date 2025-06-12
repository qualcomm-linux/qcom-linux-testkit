#!/bin/sh
 
#Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#SPDX-License-Identifier: BSD-3-Clause-Clear
 
# Source init_env and functestlib.sh
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
 
# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
 
TESTNAME="Ethernet"
test_path=$(find_test_case_by_name "$TESTNAME") || {
    log_fail "$TESTNAME : Test directory not found."
    echo "FAIL $TESTNAME" > "./$TESTNAME.res"
    exit 1
}
 
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"
summary_file="./$TESTNAME.summary"
rm -f "$res_file" "$summary_file"
 
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Check for dependencies
check_dependencies ip ping

RETRIES=3
SLEEP_SEC=2

user_iface="$1"
iface_list=""
if [ -n "$user_iface" ]; then
    iface_list="$user_iface"
    log_info "User specified interface: $user_iface"
else
    iface_list=$(get_ethernet_interfaces)
    log_info "Enumerating all detected Ethernet interfaces: $iface_list"
fi

pass_count=0
fail_count=0
skip_count=0

for iface in $iface_list; do
    log_info "---- Testing interface: $iface ----"
    if ! is_link_up "$iface"; then
        log_warn "No cable detected or carrier not present on $iface. Skipping."
        echo "$iface: SKIP (no cable)" >> "$summary_file"
        skip_count=$((skip_count + 1))
        continue
    fi

    if ! bringup_interface "$iface" "$RETRIES" "$SLEEP_SEC"; then
        log_fail "Failed to bring up $iface after $RETRIES attempts"
        echo "$iface: FAIL (up failed)" >> "$summary_file"
        fail_count=$((fail_count + 1))
        continue
    fi
    log_pass "$iface is UP"

    # Try DHCP client if present (optional)
    if ! wait_for_ip_address "$iface" 10 >/dev/null; then
        if command -v dhclient >/dev/null 2>&1; then
            log_info "Trying dhclient for $iface"
            dhclient "$iface"
            sleep 2
        elif command -v udhcpc >/dev/null 2>&1; then
            log_info "Trying udhcpc for $iface"
            udhcpc -i "$iface"
            sleep 2
        fi
    fi

    ip_addr=$(wait_for_ip_address "$iface" 10)
    if [ -z "$ip_addr" ]; then
        log_fail "$iface did not get IP address"
        echo "$iface: FAIL (no IP)" >> "$summary_file"
        fail_count=$((fail_count + 1))
        continue
    fi
    log_pass "$iface got IP address: $ip_addr"

    i=0
    ping_success=0
    while [ $i -lt $RETRIES ]; do
        if ping -I "$iface" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
            log_pass "$iface: Ethernet connectivity verified via ping"
            echo "$iface: PASS" >> "$summary_file"
            pass_count=$((pass_count + 1))
            ping_success=1
            break
        fi
        log_warn "$iface: Ping failed (attempt $((i + 1))/$RETRIES)... retrying"
        sleep "$SLEEP_SEC"
        i=$((i + 1))
    done
    if [ $ping_success -eq 0 ]; then
        log_fail "$iface: Ping test failed after $RETRIES attempts"
        echo "$iface: FAIL (ping)" >> "$summary_file"
        fail_count=$((fail_count + 1))
    fi
done

log_info "---- Ethernet Interface Test Summary ----"
cat "$summary_file"

if [ $pass_count -gt 0 ]; then
    log_pass "At least one interface PASS; overall PASS"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "No interfaces passed connectivity test"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
