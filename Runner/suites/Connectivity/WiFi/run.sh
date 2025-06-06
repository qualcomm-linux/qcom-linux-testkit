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

# Parse SSID and PASSWORD from args/env/file
SSID="$1"
PASSWORD="$2"

if [ -z "$SSID" ] || [ -z "$PASSWORD" ]; then
    SSID="${SSID:-$SSID_ENV}"
    PASSWORD="${PASSWORD:-$PASSWORD_ENV}"
fi

if [ -z "$SSID" ] || [ -z "$PASSWORD" ]; then
    if [ -f "./ssid_list.txt" ]; then
        SSID=$(awk 'NR==1 {print $1}' ./ssid_list.txt)
        PASSWORD=$(awk 'NR==1 {print $2}' ./ssid_list.txt)
        log_info "Using SSID and password from ssid_list.txt"
    else
        log_fail "SSID and password not provided via argument, env, or file."
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi
fi

# Define cleanup function
cleanup() {
    log_info "Cleaning up WiFi test environment..."
    pkill -f "wpa_supplicant -i wlan0" 2>/dev/null
    rm -f /tmp/wpa_supplicant.conf
    ifconfig wlan0 0.0.0.0 >/dev/null 2>&1
}

# Check required dependencies
check_dependencies ifconfig ping
check_systemd_services systemd-networkd.service || {
    log_error "Network services check failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}

# Try nmcli first
if command -v nmcli >/dev/null 2>&1; then
    log_info "Trying to connect using nmcli..."
    nmcli dev wifi connect "$SSID" password "$PASSWORD" 2>&1 | tee nmcli.log && {
        log_pass "Connected to $SSID using nmcli"
        IP=$(ifconfig wlan0 | awk '/inet / {print $2}')
        log_info "IP Address: $IP"
        if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
            log_pass "Internet connectivity verified via ping"
            echo "$TESTNAME PASS" > "$res_file"
            cleanup
            exit 0
        else
            log_fail "Ping test failed after nmcli connection"
        fi
    }
fi

# Fall back to wpa_supplicant + udhcpc
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

    killall wpa_supplicant 2>/dev/null
    wpa_supplicant -B -i wlan0 -D nl80211 -c "$WPA_CONF" 2>&1 | tee wpa.log
    sleep 4
    udhcpc -i wlan0 >/dev/null 2>&1
    sleep 2

    IP=$(ifconfig wlan0 | awk '/inet / {print $2}')
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
