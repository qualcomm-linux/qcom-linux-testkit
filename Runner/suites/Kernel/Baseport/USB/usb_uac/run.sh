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

# Check if dependencies are installed, else skip test
deps_list="grep sed sort wc tr readlink"
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
  printf '\n%-9s %-9s %-18s %-s\n' "DEVICE" "VID:PID" "DRIVER" "PRODUCT"
  printf '%s\n' "--------------------------------------------------------"
  dev_info_db=""
  for dev in $(printf "%s\n" "$audio_device_list" | sed '/^$/d'); do
    sys="/sys/bus/usb/devices/$dev"
    vid=$([ -r "$sys/idVendor"  ]  && tr -d '[:space:]' < "$sys/idVendor"  || echo -)
    pid=$([ -r "$sys/idProduct" ]  && tr -d '[:space:]' < "$sys/idProduct" || echo -)
    if [ -r "$sys/product" ]; then
      product=$(tr -d '\000' < "$sys/product")
    else
      product="-"
    fi
	# Determine driver from the UAC interface driver symlink
    driver="-"

    for intf in "$sys":*; do
      # Only consider UAC interfaces (bInterfaceClass == 01)
      if [ -r "$intf/bInterfaceClass" ] && grep -qx '01' "$intf/bInterfaceClass"; then
        # Resolve driver symlink and extract driver name
        if [ -L "$intf/driver" ]; then
          link="$(readlink "$intf/driver" 2>/dev/null)"
          driver="$(printf "%s\n" "$link" | grep -o 'snd-usb-audio' || echo -)"
        fi
		break
      fi
    done
    dev_info_db="${dev_info_db}\n${dev}|${vid}:${pid}|${driver}|${product}"
    printf '%-9s %-9s %-18s %-s\n' "$dev" "$vid:$pid" "$driver" "$product"
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

# Map ALSA USB cards to their parent USB device id (e.g., 1-2.3 from 1-2.3:1.0)
card_map=""
while IFS= read -r c; do
    [ -n "$c" ] || continue
    link="$(readlink "/sys/class/sound/card${c}/device" 2>/dev/null || true)"
    [ -n "$link" ] || continue
    base="${link##*/}"
    parent="${base%%:*}"
    [ -n "$parent" ] || continue
    card_map="${card_map}${parent}|${c}\n"
done <<EOF
$usb_alsa_card_nums
EOF

# For each detected UAC device, verify mapped ALSA card(s) and device nodes
has_devnodes_count=0
for dev in $(printf "%s\n" "$audio_device_list" | sed '/^$/d'); do
	# Look up device details for debug messages
	vidpid="$(printf "%b" "$dev_info_db" | sed -n "s/^${dev}|\\([^|]*\\)|.*/\\1/p" | head -n1)"
	driver_info="$(printf "%b" "$dev_info_db" | sed -n "s/^${dev}|[^|]*|\\([^|]*\\)|.*/\\1/p" | head -n1)"
	product_info="$(printf "%b" "$dev_info_db" | sed -n "s/^${dev}|[^|]*|[^|]*|\\(.*\\)$/\\1/p" | head -n1)"
	
	missing_nodes=0

	# Cards mapped to this USB device
	cards_for_dev="$(printf "%b" "$card_map" | sed -n "s/^${dev}|\\([0-9][0-9]*\\)$/\\1/p" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

	if [ -z "$cards_for_dev" ]; then
		log_info "UAC device $dev ($vidpid '$product_info', driver: $driver_info): No ALSA card mapped"
		missing_nodes=1
		continue
	fi

	for c in $cards_for_dev; do
		card_path="/sys/class/sound/card$c"
		ctrl_dev="/dev/snd/controlC$c"

		# Check if control device exists
		if [ ! -e "$ctrl_dev" ]; then
			log_info "UAC device $dev (card$c): Missing control device $ctrl_dev"
			missing_nodes=1
		else
			log_info "UAC device $dev ($vidpid '$product_info') -> card$c: $ctrl_dev exists"
		fi

		# Check for PCM devices (playback/capture)
		pcm_found=0

		for pcm in "$card_path"/pcmC"${c}"D*p "$card_path"/pcmC"${c}"D*c; do
			[ -e "$pcm" ] || continue
			pcm_found=1
			pcm_name="${pcm##*/}"
			dev_node="/dev/snd/${pcm_name}"
			case "$pcm_name" in
				*p) pcm_dir="playback" ;;
				*c) pcm_dir="capture" ;;
				*)  pcm_dir="unknown" ;;
			esac
			if [ -e "$dev_node" ]; then
				log_info "  PCM device ($pcm_dir): $dev_node exists"
			else
				log_info "  PCM device ($pcm_dir): $dev_node missing"
				missing_nodes=1
			fi
		done

		if [ "$pcm_found" -eq 0 ]; then
			log_info "  No PCM devices found for card$c"
			missing_nodes=1
		fi
	done
	if [ "$missing_nodes" -eq 0 ]; then
		has_devnodes_count=$((has_devnodes_count + 1))
	fi
done

if [ "${has_devnodes_count:-0}" -eq "$audio_device_count" ] 2>/dev/null; then
	log_pass "$TESTNAME : Test Passed - All ($audio_device_count/$audio_device_count) USB Audio device(s) detected have associated ALSA device nodes present"
	echo "$TESTNAME PASS" > "$RES_FILE"
	exit 0
else
    log_fail "$TESTNAME : Test Failed - $((audio_device_count - has_devnodes_count))/$audio_device_count USB Audio device(s) missing associated ALSA device nodes"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
