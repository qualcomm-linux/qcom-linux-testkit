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
# Include all external utilities used by this script
deps_list="grep sed sort wc tr readlink head awk"
check_dependencies "$deps_list"

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

# Build ALSA card -> USB device map via sysfs (use /proc/asound/cards only for logging)
card_map=""
for card_dir in /sys/class/sound/card*; do
    [ -d "$card_dir" ] || continue
    c="${card_dir##*/}"
    c="${c#card}"
    target="$(readlink -f "$card_dir/device" 2>/dev/null || true)"
    [ -n "$target" ] || continue

    cur="$target"
    usb_parent=""
    # Walk up until a USB device (with idVendor/idProduct) or an interface dir (X-Y:Z.W) is found
    while [ "$cur" != "/" ] && [ -z "$usb_parent" ]; do
        if [ -r "$cur/idVendor" ] && [ -r "$cur/idProduct" ]; then
            base="${cur##*/}"
            usb_parent="$base"
            break
        fi
        base="${cur##*/}"
        case "$base" in
            *:*)
                usb_parent="${base%%:*}"
                break
                ;;
        esac
        cur="$(dirname "$cur")"
    done

    [ -n "$usb_parent" ] || continue

    # Only map cards whose parent USB device is in detected UAC device list
    if printf "%s\n" "$audio_device_list" | sed '/^$/d' | grep -qx "$usb_parent"; then
        card_map="${card_map}${usb_parent}|${c}\n"
        log_info "Mapped ALSA card$c -> USB device $usb_parent"
    fi
done

# For each detected UAC device, verify mapped ALSA card(s) and device nodes
has_devnodes_count=0
for dev in $(printf "%s\n" "$audio_device_list" | sed '/^$/d'); do
	# Look up device details for debug messages (literal field matching)
	vidpid="$(printf "%b" "$dev_info_db" | awk -F'|' -v dev="$dev" '$1==dev{print $2; exit}')"
	driver_info="$(printf "%b" "$dev_info_db" | awk -F'|' -v dev="$dev" '$1==dev{print $3; exit}')"
	product_info="$(printf "%b" "$dev_info_db" | awk -F'|' -v dev="$dev" '$1==dev{print $4; exit}')"
	
	missing_nodes=0

	# Cards mapped to this USB device (literal field matching)
	cards_for_dev="$(printf "%b" "$card_map" | awk -F'|' -v dev="$dev" '$1==dev{print $2}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

	if [ -z "$cards_for_dev" ]; then
		log_info "UAC device $dev ($vidpid '$product_info', driver: $driver_info): No ALSA card mapped"
		missing_nodes=1
		continue
	fi

	for c in $cards_for_dev; do
		ctrl_dev="/dev/snd/controlC$c"

		# Check if control device exists
		if [ ! -e "$ctrl_dev" ]; then
			log_info "UAC device $dev (card$c): Missing control device $ctrl_dev"
			missing_nodes=1
		else
			log_info "UAC device $dev ($vidpid '$product_info') -> card$c: $ctrl_dev exists"
		fi

		# Validate PCMs using /proc/asound/pcm, then verify corresponding /dev nodes
		has_play_cap="$(awk -v c="$c" '
			BEGIN{p=0;cap=0}
			/^[0-9]+-[0-9]+:/ {
				s=$1
				s=sub(":", "", s)
			}
			/^[0-9]+-[0-9]+:/ {
				split($1,a,"-"); gsub(":","",a[2]); if ((a[1]+0)==c) {
					if ($0 ~ /playback[[:space:]]+[1-9]/) p=1
					if ($0 ~ /capture[[:space:]]+[1-9]/) cap=1
				}
			}
			END{ printf "%d %d\n", p, cap }
		' /proc/asound/pcm 2>/dev/null || printf "0 0\n")"

		has_play="$(printf "%s" "$has_play_cap" | awk '{print $1}')"
		has_cap="$(printf "%s" "$has_play_cap" | awk '{print $2}')"

		if [ "${has_play:-0}" -eq 1 ]; then
			play_node_exists=0
			for n in /dev/snd/pcmC"${c}"D*p; do
				[ -e "$n" ] || continue
				log_info "  PCM device (playback): $n exists"
				play_node_exists=1
			done
			if [ "$play_node_exists" -eq 0 ]; then
				log_info "  PCM device (playback): nodes missing for card$c"
				missing_nodes=1
			fi
		else
			log_info "  No playback streams for card$c"
		fi

		if [ "${has_cap:-0}" -eq 1 ]; then
			cap_node_exists=0
			for n in /dev/snd/pcmC"${c}"D*c; do
				[ -e "$n" ] || continue
				log_info "  PCM device (capture): $n exists"
				cap_node_exists=1
			done
			if [ "$cap_node_exists" -eq 0 ]; then
				log_info "  PCM device (capture): nodes missing for card$c"
				missing_nodes=1
			fi
		else
			log_info "  No capture streams for card$c"
		fi

		if [ "${has_play:-0}" -eq 0 ] && [ "${has_cap:-0}" -eq 0 ]; then
			log_info "  No PCM playback/capture streams found for card$c"
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
