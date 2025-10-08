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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="WiFi_Manual_IP"
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# ---------------- CLI (SSID/PASSWORD) ----------------
SSID=""
PASSWORD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --ssid)
            shift
            if [ -n "${1:-}" ]; then
                SSID="$1"
            fi
            ;;
        --password)
            shift
            if [ -n "${1:-}" ]; then
                PASSWORD="$1"
            fi
            ;;
        --help|-h)
            echo "Usage: $0 [--ssid SSID] [--password PASS]"
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"
            ;;
    esac
    shift
done

# Trap to always restore udhcpc script
trap 'restore_udhcpc_script' EXIT

# Credential extraction (from CLI, env, or ssid_list.txt via helper)
if ! CRED="$(get_wifi_credentials "$SSID" "$PASSWORD")" || [ -z "$CRED" ]; then
    log_skip_exit "$TESTNAME" "WiFi: SSID and/or password missing. Skipping test."
fi

SSID="$(echo "$CRED" | awk '{print $1}')"
PASSWORD="$(echo "$CRED" | awk '{print $2}')"
log_info "Using SSID='$SSID' and PASSWORD='[hidden]'"

check_dependencies iw wpa_supplicant udhcpc ip

WIFI_IF="$(get_wifi_interface)"
if [ -z "$WIFI_IF" ]; then
    log_fail_exit "$TESTNAME" "No WiFi interface detected."
fi

UDHCPC_SCRIPT="$(ensure_udhcpc_script)"
if [ ! -x "$UDHCPC_SCRIPT" ]; then
    log_fail_exit "$TESTNAME" "Failed to create udhcpc script."
fi

wifi_cleanup() {
    killall -q wpa_supplicant 2>/dev/null
    rm -f /tmp/wpa_supplicant.conf wpa.log
    ip link set "$WIFI_IF" down 2>/dev/null
}

# Generate WPA config using helper (no duplicate code!)
WPA_CONF="$(wifi_write_wpa_conf "$WIFI_IF" "$SSID" "$PASSWORD")"
if [ ! -f "$WPA_CONF" ]; then
    log_fail_exit "$TESTNAME" "Failed to create WPA config" wifi_cleanup
fi

killall -q wpa_supplicant 2>/dev/null
wpa_supplicant -B -i "$WIFI_IF" -c "$WPA_CONF" 2>&1 | tee wpa.log
sleep 4

# Run udhcpc with the script
udhcpc -i "$WIFI_IF" -s "$UDHCPC_SCRIPT" -n -q &
sleep 8

IP="$(ip addr show "$WIFI_IF" | awk '/inet / {print $2}' | cut -d/ -f1)"
if [ -n "$IP" ]; then
    log_info "WiFi got IP: $IP (manual DHCP via udhcpc)"
    if ping -I "$WIFI_IF" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_pass_exit "$TESTNAME" "WiFi: Internet connectivity verified via ping" wifi_cleanup
    else
        log_fail_exit "$TESTNAME" "WiFi: Ping test failed after DHCP/manual IP" wifi_cleanup
    fi
else
    log_fail_exit "$TESTNAME" "Failed to acquire IP via udhcpc" wifi_cleanup
fi
