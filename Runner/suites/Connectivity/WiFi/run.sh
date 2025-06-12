#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

# shellcheck disable=SC1090
if [ -z "$__INIT_ENV_LOADED" ]; then
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="WiFi"
res_file="./$TESTNAME.res"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Test -----------------"

# Credential extraction
if ! CRED=$(get_wifi_credentials "$1" "$2") || [ -z "$CRED" ]; then
    log_fail "SSID and password not provided via argument, env, or file."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

SSID=$(echo "$CRED" | awk '{print $1}')
PASSWORD=$(echo "$CRED" | awk '{print $2}')
SSID=$(echo "$SSID" | xargs)
PASSWORD=$(echo "$PASSWORD" | xargs)
if [ -z "$SSID" ] || [ -z "$PASSWORD" ]; then
    log_fail "SSID and password could not be extracted."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Using SSID='$SSID' and PASSWORD='[hidden]'"

# Minimal global dependencies for scanning and pinging
check_dependencies iw ping

check_systemd_services systemd-networkd.service || {
    log_error "Network services check failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}

# Find WiFi interface (auto-detect)
WIFI_IFACE="$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')"
if [ -z "$WIFI_IFACE" ]; then
    log_fail "No WiFi interface found (via iw dev)"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "Using WiFi interface: $WIFI_IFACE"

cleanup() {
    log_info "Cleaning up WiFi test environment..."
    killall -q wpa_supplicant 2>/dev/null
    rm -f /tmp/wpa_supplicant.conf nmcli.log wpa.log
    ip link set "$WIFI_IFACE" down 2>/dev/null || ifconfig "$WIFI_IFACE" down 2>/dev/null
}

# Try nmcli first
if command -v nmcli >/dev/null 2>&1; then
    log_info "Trying to connect using nmcli..."
    if nmcli dev wifi connect "$SSID" password "$PASSWORD" ifname "$WIFI_IFACE" 2>&1 | tee nmcli.log; then
        log_pass "Connected to $SSID using nmcli"
        IP=$(ip addr show "$WIFI_IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)
        log_info "IP Address: $IP"
        if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
            log_pass "Internet connectivity verified via ping"
            echo "$TESTNAME PASS" > "$res_file"
            cleanup
            exit 0
        else
            log_fail "Ping test failed after nmcli connection"
        fi
    fi
fi

# Fallback to wpa_supplicant + udhcpc if both are available
if command -v wpa_supplicant >/dev/null 2>&1 && command -v udhcpc >/dev/null 2>&1; then
    log_info "Falling back to wpa_supplicant + udhcpc"
    WPA_CONF="/tmp/wpa_supplicant.conf"
    {
        echo "ctrl_interface=/var/run/wpa_supplicant"
        echo "network={"
        echo " ssid=\"$SSID\""
        echo " key_mgmt=WPA-PSK"
        echo " pairwise=CCMP TKIP"
        echo " group=CCMP TKIP"
        echo " psk=\"$PASSWORD\""
        echo "}"
    } > "$WPA_CONF"

    killall -q wpa_supplicant 2>/dev/null
    wpa_supplicant -B -i "$WIFI_IFACE" -D nl80211 -c "$WPA_CONF" 2>&1 | tee wpa.log
    sleep 4
    udhcpc -i "$WIFI_IFACE" >/dev/null 2>&1
    sleep 2

    IP=$(ip addr show "$WIFI_IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)
    if [ -n "$IP" ]; then
        log_pass "Got IP via udhcpc: $IP"
        if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
            log_pass "Internet connectivity verified via ping"
            echo "$TESTNAME PASS" > "$res_file"
            cleanup
            exit 0
        else
            log_fail "Ping test failed after wpa_supplicant connection"
        fi
    else
        log_fail "Failed to acquire IP via udhcpc"
    fi
else
    log_error "Neither nmcli nor wpa_supplicant+udhcpc available"
fi

log_fail "$TESTNAME : Test Failed"
echo "$TESTNAME FAIL" > "$res_file"
cleanup
exit 1
