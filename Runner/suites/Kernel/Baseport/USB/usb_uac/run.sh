#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Validate USB Audio Class (UAC) device detection
# Requires at least one USB Audio peripheral (e.g., USB headset, microphone, sound card) connected to a USB Host port.

TESTNAME="usb_uac"

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

# Check if grep is installed, else skip test
deps_list="grep sed sort wc tr"
if ! check_dependencies "$deps_list"; then
  log_skip "$TESTNAME SKIP - missing dependencies: $deps_list"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# Detect unique devices with bInterfaceClass = 01 (UAC) under /sys/bus/usb/devices
log_info "=== USB Audio device Detection ==="
audio_device_list="$(
  for f in /sys/bus/usb/devices/*/bInterfaceClass; do
    [ -r "$f" ] || continue
    if grep -qx '01' "$f"; then
      d=${f%/bInterfaceClass}
      d=${d%:*}
      printf '%s\n' "${d##*/}"
    fi
  done 2>/dev/null | sort -u
)"

audio_device_count="$(printf "%s\n" "$audio_device_list" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
log_info "Number of USB audio devices found: $audio_device_count"

if [ "$audio_device_count" -gt 0 ] 2>/dev/null; then
  log_info "=== Enumerated USB Audio Devices ==="
  printf '\n%-9s %-9s %-s\n' "DEVICE" "VID:PID" "PRODUCT"
  printf '%s\n' "--------------------------------------------------------"
  for dev in $(printf "%s\n" "$audio_device_list" | sed '/^$/d'); do
    sys="/sys/bus/usb/devices/$dev"
    vid=$([ -r "$sys/idVendor"  ]  && tr -d '[:space:]' < "$sys/idVendor"  || echo -)
    pid=$([ -r "$sys/idProduct" ]  && tr -d '[:space:]' < "$sys/idProduct" || echo -)
    if [ -r "$sys/product" ]; then
      product=$(tr -d '\000' < "$sys/product")
    else
      product="-"
    fi
    printf '%-9s %-9s %-s\n' "$dev" "$vid:$pid" "$product"
  done
  printf '\n'
fi

if [ "$audio_device_count" -le 0 ] 2>/dev/null; then
    log_fail "$TESTNAME : Test Failed - No 'USB Audio Device' found"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

# Verify ALSA is available
if [ ! -r /proc/asound/cards ]; then
    log_fail "$TESTNAME : Test Failed - ALSA not available (/proc/asound/cards missing)"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if [ -r /proc/asound/cards ]; then
    log_info "ALSA cards (/proc/asound/cards):"
    while IFS= read -r line; do
        log_info "  $line"
    done < /proc/asound/cards
fi

# Identify ALSA cards that correspond to USB
usb_alsa_card_nums="$(sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]\{1,\}\[[^]]*\]:[[:space:]]\{1,\}USB.*/\1/p' /proc/asound/cards | sort -u)"
usb_alsa_card_count="$(printf "%s\n" "$usb_alsa_card_nums" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
log_info "Number of ALSA USB sound cards: $usb_alsa_card_count"

if [ "$usb_alsa_card_count" -le 0 ] 2>/dev/null; then
    log_fail "$TESTNAME : Test Failed - No ALSA 'USB' cards found for detected USB Audio device(s)"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

# For each USB ALSA card, ensure playback or capture device nodes exist
missing_nodes=0
while IFS= read -r c; do
    card_path="/sys/class/sound/card$c"
    ctrl_dev="/dev/snd/controlC$c"
    has_pcm_p=0
    has_pcm_c=0

    # Detect at least one playback/capture PCM node for the card
    for n in /dev/snd/pcmC"${c}"D*p; do
        [ -e "$n" ] && has_pcm_p=1 && break
    done
    for n in /dev/snd/pcmC"${c}"D*c; do
        [ -e "$n" ] && has_pcm_c=1 && break
    done

    if [ ! -e "$card_path" ]; then
        log_fail "Missing sysfs sound card path: $card_path"
        missing_nodes=1
    fi
    if [ ! -e "$ctrl_dev" ]; then
        log_fail "Missing ALSA control device: $ctrl_dev"
        missing_nodes=1
    fi
    if [ "$has_pcm_p" -ne 1 ] && [ "$has_pcm_c" -ne 1 ]; then
        log_fail "Missing ALSA PCM device(s) for card $c (no playback or capture node found)"
        missing_nodes=1
    else
        msg="ALSA card $c device nodes present:"
        [ "$has_pcm_p" -eq 1 ] && msg="$msg playback"
        [ "$has_pcm_c" -eq 1 ] && msg="$msg capture"
        log_info "$msg"
    fi
done <<EOF
$usb_alsa_card_nums
EOF

if [ "$missing_nodes" -ne 0 ] 2>/dev/null; then
    log_fail "$TESTNAME : Test Failed - One or more ALSA device nodes are missing for USB sound card(s)"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

log_pass "$TESTNAME : Test Passed - USB Audio device(s) detected and ALSA device nodes present"
echo "$TESTNAME PASS" > "$RES_FILE"
exit 0
