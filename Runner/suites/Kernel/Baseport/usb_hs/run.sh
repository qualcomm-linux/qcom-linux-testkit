#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Validate that at least one non-hub USB peripheral is enumerated at High-Speed (>= 480 Mb/s).
# This test ignores hubs and only considers actual USB devices.

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
    __INIT_ENV_LOADED=1
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="usb_hs"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "=== Detecting non-hub High-Speed USB devices ==="

# We rely on sysfs entries under /sys/bus/usb/devices for authoritative device speed.
# Criteria:
#  - Only consider entries with bDeviceClass (device-level), skip interface-only entries.
#  - Ignore hubs: device class 0x09 (9).
#  - Consider a device High-Speed if speed (Mb/s) is >= 480.

non_hub_count=0
hs_count=0

for d in /sys/bus/usb/devices/*; do
    [ -d "$d" ] || continue

    # Must be a device (has bDeviceClass); skip interface/function entries like 1-1:1.0
    if [ ! -f "$d/bDeviceClass" ]; then
        continue
    fi

    class="$(tr -d '[:space:]' 2>/dev/null < "$d/bDeviceClass")"
    case "$class" in
        09|9|0x09|0X09) # Hub device; ignore
            continue
            ;;
    esac

    raw_speed="$(cat "$d/speed" 2>/dev/null || echo 0)"
    speed_int="${raw_speed%%.*}"
    case "$speed_int" in
        ''|*[!0-9]*)
            speed_int=0
            ;;
    esac

    busnum="$(cat "$d/busnum" 2>/dev/null || echo "?")"
    devnum="$(cat "$d/devnum" 2>/dev/null || echo "?")"
    idVendor="$(cat "$d/idVendor" 2>/dev/null || echo "0000")"
    idProduct="$(cat "$d/idProduct" 2>/dev/null || echo "0000")"
    product="$(cat "$d/product" 2>/dev/null || true)"
    [ -n "$product" ] || product="(unknown)"

    echo "Device: $busnum $devnum ${idVendor}:${idProduct} \"$product\" ${raw_speed}"

    non_hub_count=$((non_hub_count + 1))
    if [ "$speed_int" -ge 480 ]; then
        hs_count=$((hs_count + 1))
    fi
done

echo "High-Speed (>=480 Mb/s) device count: $hs_count"

if [ "$non_hub_count" -eq 0 ]; then
    log_fail "$TESTNAME : Test Failed - No non-hub USB peripherals detected. Only hubs or no devices present."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if [ "$hs_count" -gt 0 ]; then
    log_pass "$TESTNAME : Test Passed - $hs_count High-Speed device(s) found among $non_hub_count non-hub device(s)."
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed - No non-hub USB device enumerated at High-Speed (>= 480 Mb/s)."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
