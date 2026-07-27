#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Validate USB Video Class (UVC) device detection and creation of /dev/video* nodes
# Requires at least one USB Video peripheral (e.g., USB webcam) connected to a USB Host port.

TESTNAME="usb_uvc"

# Robustly find and source init_env
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

# Default result file (works even before functestlib is available)
# shellcheck disable=SC2034
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"

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
    echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
    exit 0
fi

# Only source if not already loaded (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

# Resolve test path and cd (single SKIP/exit path)
SKIP_REASON=""
test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
  SKIP_REASON="$TESTNAME SKIP - test path not found"
elif ! cd "$test_path"; then
  SKIP_REASON="$TESTNAME SKIP - cannot cd into $test_path"
else
  RES_FILE="$test_path/${TESTNAME}.res"
fi

if [ -n "$SKIP_REASON" ]; then
  log_skip "$SKIP_REASON"
  echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
  exit 0
fi

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Check if dependencies are installed, else skip test
# Include all external utilities used by this script
deps_list="grep sed sort wc tr readlink head awk"
check_dependencies "$deps_list"

# Detect unique devices with bInterfaceClass = 0e (UVC) under /sys/bus/usb/devices
# Accept common encodings: '0e', '0E', or decimal '14'
log_info "=== USB Video device Detection ==="
video_device_list="$(
  for f in /sys/bus/usb/devices/*/bInterfaceClass; do
    [ -r "$f" ] || continue
    if grep -qx '0e' "$f" || grep -qx '0E' "$f" || grep -qx '14' "$f"; then
      d=${f%/bInterfaceClass}
      d=${d%:*}
      printf '%s\n' "${d##*/}"
    fi
  done 2>/dev/null | sort -u
)"

video_device_count="$(printf "%s\n" "$video_device_list" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
log_info "Number of USB video devices found: $video_device_count"

if [ "$video_device_count" -gt 0 ] 2>/dev/null; then
  log_info "=== Enumerated USB Video Devices ==="
  printf '\n%-9s %-9s %-18s %-s\n' "DEVICE" "VID:PID" "DRIVER" "PRODUCT"
  printf '%s\n' "--------------------------------------------------------"
  dev_info_db=""
  associated_nodes=""
  for dev in $(printf "%s\n" "$video_device_list" | sed '/^$/d'); do
    sys="/sys/bus/usb/devices/$dev"
    vid=$([ -r "$sys/idVendor"  ]  && tr -d '[:space:]' < "$sys/idVendor"  || echo -)
    pid=$([ -r "$sys/idProduct" ]  && tr -d '[:space:]' < "$sys/idProduct" || echo -)
    if [ -r "$sys/product" ]; then
      product=$(tr -d '\000' < "$sys/product")
    else
      product="-"
    fi
    # Determine driver from the UVC interface driver symlink
    driver="-"
    for intf in "$sys":*; do
      # Only consider UVC interfaces (bInterfaceClass == 0e/14)
      if [ -r "$intf/bInterfaceClass" ] && { grep -qx '0e' "$intf/bInterfaceClass" || grep -qx '0E' "$intf/bInterfaceClass" || grep -qx '14' "$intf/bInterfaceClass"; }; then
        # Resolve driver symlink and extract driver name
        if [ -L "$intf/driver" ]; then
          link="$(readlink "$intf/driver" 2>/dev/null)"
          driver="$(printf "%s\n" "$link" | grep -o 'uvcvideo' || echo -)"
        fi
        break
      fi
    done
    dev_info_db="${dev_info_db}\n${dev}|${vid}:${pid}|${driver}|${product}"
    printf '%-9s %-9s %-18s %-s\n' "$dev" "$vid:$pid" "$driver" "$product"

    # Print associated /dev/video* nodes for this UVC device
    for intf in "$sys":*; do
      # Only consider UVC interfaces (bInterfaceClass == 0e/14)
      if [ -r "$intf/bInterfaceClass" ] && { grep -qx '0e' "$intf/bInterfaceClass" || grep -qx '0E' "$intf/bInterfaceClass" || grep -qx '14' "$intf/bInterfaceClass"; }; then
        if [ -d "$intf/video4linux" ]; then
          for v in "$intf"/video4linux/video*; do
            [ -e "$v" ] || continue
            node="/dev/$(basename "$v")"
            if [ -e "$node" ]; then
              log_info "UVC device $dev (${vid}:${pid} '${product}', driver: ${driver}): ${node} exists"
              associated_nodes="${associated_nodes}\n${node}"
            fi
          done
        fi
      fi
    done
  done
  printf '\n'
fi

if [ "$video_device_count" -le 0 ] 2>/dev/null; then
    log_fail "$TESTNAME : Test Failed - No 'USB Video Device' found"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

# Count only /dev/video* nodes associated with detected UVC devices
video_node_count="$(printf "%b\n" "$associated_nodes" | sed '/^$/d' | sort -u | wc -l | tr -d '[:space:]')"
log_info "Number of /dev/video* nodes found: ${video_node_count:-0}"

# Pass if the number of /dev/video* nodes is at least the number of detected UVC devices
if [ "${video_node_count:-0}" -ge "$video_device_count" ] 2>/dev/null; then
  log_pass "$TESTNAME : Test Passed - Found /dev/video* nodes for detected UVC device(s)"
  echo "$TESTNAME PASS" > "$RES_FILE"
  exit 0
else
  log_fail "$TESTNAME : Test Failed - /dev/video* nodes do not exist for detected UVC device(s)"
  echo "$TESTNAME FAIL" > "$RES_FILE"
  exit 0
fi
