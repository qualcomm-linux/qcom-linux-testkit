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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="WiFi_Firmware_Driver"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

RES_FILE="./${TESTNAME}.res"
: >"$RES_FILE"

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

if ! check_dependencies find grep modprobe lsmod cat stat; then
    log_skip "$TESTNAME SKIP - required tools (find/grep/modprobe/lsmod/cat/stat) missing"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# Detect SoC from /proc/device-tree/model
if [ -f /proc/device-tree/model ]; then
    read -r soc_model < /proc/device-tree/model
else
    soc_model="Unknown"
fi
log_info "Detected SoC model: $soc_model"

# ---------------------------------------------------------------------------
# Firmware detection: support ath11k (amss.bin / wpss.mbn) and ath10k (WCN3990)
# ---------------------------------------------------------------------------
log_info "Scanning for WiFi firmware (ath11k / ath10k)..."

fwfile=""
wifi_family=""

# Prefer ath11k if present (Lemans/Monaco/Kodiak type platforms)
if [ -d /lib/firmware/ath11k ]; then
    if find /lib/firmware/ath11k/ -type f -name "amss.bin" -print -quit 2>/dev/null | grep -q .; then
        fwfile=$(find /lib/firmware/ath11k/ -type f -name "amss.bin" -print -quit 2>/dev/null)
        wifi_family="ath11k"
    elif find /lib/firmware/ath11k/ -type f -name "wpss.mbn" -print -quit 2>/dev/null | grep -q .; then
        fwfile=$(find /lib/firmware/ath11k/ -type f -name "wpss.mbn" -print -quit 2>/dev/null)
        wifi_family="ath11k"
    fi
fi

# If no ath11k firmware found, try ath10k (e.g. WCN3990 on RB1/QCM2290)
if [ -z "$fwfile" ] && [ -d /lib/firmware/ath10k ]; then
    # Look for wlan firmware or generic firmware-*.bin
    if find /lib/firmware/ath10k/ -type f -name "wlanmdsp.mbn" -print -quit 2>/dev/null | grep -q .; then
        fwfile=$(find /lib/firmware/ath10k/ -type f -name "wlanmdsp.mbn" -print -quit 2>/dev/null)
        wifi_family="ath10k"
    elif find /lib/firmware/ath10k/ -type f -name "firmware-*.bin" -print -quit 2>/dev/null | grep -q .; then
        fwfile=$(find /lib/firmware/ath10k/ -type f -name "firmware-*.bin" -print -quit 2>/dev/null)
        wifi_family="ath10k"
    fi
fi

if [ -z "$fwfile" ] || [ -z "$wifi_family" ]; then
    log_skip "$TESTNAME SKIP - No ath11k/ath10k WiFi firmware found under /lib/firmware (ath11k or ath10k)"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

size=$(stat -c%s "$fwfile" 2>/dev/null)
basename=$(basename "$fwfile")
log_info "Detected WiFi firmware family: $wifi_family"
log_info "Detected firmware [$basename]: $fwfile (size: $size bytes)"

suite_rc=0

# ---------------------------------------------------------------------------
# Family-specific handling (load / validate) – use log_* only, decide at end
# ---------------------------------------------------------------------------
case "$wifi_family" in
    ath11k)
        case "$basename" in
            wpss.mbn)
                log_info "Platform using wpss.mbn firmware (e.g., Kodiak - WPSS via remoteproc)"
                if validate_remoteproc_running "wpss"; then
                    log_info "Remoteproc 'wpss' is active and validated."
                else
                    log_fail "Remoteproc 'wpss' validation failed."
                    suite_rc=1
                fi
                log_info "No ath11k_pci module load needed for wpss-based platform."
                ;;
            amss.bin)
                log_info "amss.bin firmware detected (e.g., WCN6855 - Lemans/Monaco via ath11k_pci)"
                if ! modprobe ath11k_pci 2>/dev/null; then
                    log_fail "Failed to load ath11k_pci module."
                    suite_rc=1
                else
                    log_info "ath11k_pci module loaded successfully."
                fi
                ;;
            *)
                log_skip "$TESTNAME SKIP - Unsupported ath11k firmware type: $basename"
                echo "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
                ;;
        esac
        ;;
    ath10k)
        log_info "ath10k firmware detected (e.g., WCN3990 on RB1/QCM2290)."
        # Ensure ath10k_core + one of the bus drivers (snoc/pci/sdio) are loaded
        if ! lsmod | grep -q '^ath10k_core\s'; then
            log_info "ath10k_core not loaded yet; attempting to load ath10k bus drivers..."
            bus_loaded=0
            for m in ath10k_snoc ath10k_pci ath10k_sdio; do
                if modprobe "$m" 2>/dev/null; then
                    log_info "Loaded ath10k bus driver module: $m"
                    bus_loaded=1
                    break
                fi
            done
            if [ "$bus_loaded" -ne 1 ]; then
                log_fail "Failed to load any ath10k bus driver (ath10k_snoc/ath10k_pci/ath10k_sdio)."
                suite_rc=1
            fi
        else
            log_info "ath10k_core already loaded; skipping bus driver modprobe attempts."
        fi
        ;;
    *)
        log_skip "$TESTNAME SKIP - Unsupported WiFi family detected: $wifi_family"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Module visibility checks (family-specific) – explicitly verify ath10k modules
# ---------------------------------------------------------------------------
if [ "$wifi_family" = "ath11k" ]; then
    log_info "Checking active ath11k-related kernel modules via lsmod..."
    if lsmod | grep -Eq '^ath11k(_.*)?\s'; then
        lsmod | grep -E '^ath11k(_.*)?\s' | while read -r mod_line; do
            log_info " Module loaded: $mod_line"
        done
    else
        log_fail "No ath11k-related kernel module detected via lsmod."
        suite_rc=1
    fi
elif [ "$wifi_family" = "ath10k" ]; then
    log_info "Checking active ath10k-related kernel modules via lsmod..."
    if lsmod | grep -q '^ath10k_core\s'; then
        log_info " Core module loaded: ath10k_core"
    else
        log_fail "ath10k_core module is not loaded."
        suite_rc=1
    fi

    if lsmod | grep -Eq '^ath10k_(snoc|pci|sdio)\s'; then
        lsmod | grep -E '^ath10k_(snoc|pci|sdio)\s' | while read -r mod_line; do
            log_info " Bus driver loaded: $mod_line"
        done
    else
        log_fail "No ath10k bus driver module (ath10k_snoc/ath10k_pci/ath10k_sdio) detected via lsmod."
        suite_rc=1
    fi
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if [ "$suite_rc" -eq 0 ]; then
    log_pass "$TESTNAME: PASS - WiFi firmware and driver validation successful."
    echo "$TESTNAME PASS" >"$RES_FILE"
    exit 0
fi

log_fail "$TESTNAME: FAIL - WiFi firmware/driver validation encountered errors."
echo "$TESTNAME FAIL" >"$RES_FILE"
exit 1
