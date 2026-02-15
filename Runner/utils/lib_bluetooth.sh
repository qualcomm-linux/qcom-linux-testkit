#!/bin/sh
# lib_bluetooth.sh - Bluetooth-specific helpers split out from functestlib.sh
# Copyright (c) Qualcomm Technologies, Inc.
# SPDX-License-Identifier: BSD-3-Clause#
# This file is meant to be sourced *after* init_env and functestlib.sh:
# . "$TOOLS/functestlib.sh"
# . "$TOOLS/lib_bluetooth.sh"

bt_has_controller() {
# Use plain bluetoothctl list here; the expect wrapper is overkill and
# sometimes swallows the "Controller ..." line for pipelines.
    if bluetoothctl list 2>/dev/null \
        | sanitize_bt_output \
        | grep -qi '^[[:space:]]*Controller[[:space:]]'
    then
        return 0
    fi
    return 1
}

# stdout: first controller MAC from `bluetoothctl list` (e.g. 00:00:00:00:5A:AD)
# return: 0 if found and printed, 1 if no controller line found
bt_first_mac() {
    bluetoothctl list 2>/dev/null \
        | sanitize_bt_output \
        | awk '
            {
                # strip CR, defensive
            }
            tolower($1) == "controller" {
                print $2;
                exit
            }
        '
}

# Remove paired BT device by MAC
bt_cleanup_paired_device() {
    mac="$1"
    log_info "Removing paired device: $mac"

    # Non-interactive remove to avoid “AlreadyExists”
    bluetoothctl remove "$mac" >/dev/null 2>&1 || true

    # Full Expect cleanup (captures transcript in a logfile)
    cleanup_log="bt_cleanup_${mac}_$(date +%Y%m%d_%H%M%S).log"
    if expect <<EOF >"$cleanup_log" 2>&1
log_user 1
spawn bluetoothctl
set timeout 10

# Match the prompt once, then send all commands in sequence
expect -re "#|\\[.*\\]#" {
    send "power on\r"
    send "agent off\r"
    send "agent NoInputNoOutput\r"
    send "default-agent\r"
    send "remove $mac\r"
    send "quit\r"
}

expect eof
EOF
    then
        log_info "Device $mac removed successfully (see $cleanup_log)"
    else
        log_warn "Failed to remove device $mac (see $cleanup_log)"
    fi
}

# Retry a shell command N times with sleep
retry_command_bt() {
    cmd="$1"
    msg="$2"
    max="${3:-3}"
    count=1
    while [ "$count" -le "$max" ]; do
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Retry $count/$max failed: $msg"
        count=$((count + 1))
        sleep 2
    done
    return 1
}

# Check if a device (MAC or Name) is in the whitelist
bt_in_whitelist() {
    device_name="$1"
    device_mac="$2"

    whitelist_value="${WHITELIST:-}"
    log_info "Checking if MAC='$device_mac' or NAME='$device_name' is in whitelist: '$whitelist_value'"

    echo "$whitelist_value" | tr -s ' ' '\n' | while IFS= read -r allowed; do
        if [ "$allowed" = "$device_mac" ] || [ "$allowed" = "$device_name" ]; then
            log_info "MAC or NAME matched and allowed: $allowed"
            return 0
        fi
    done

    log_info "MAC matched but neither MAC nor NAME in whitelist"
    return 1
}

# bt_parse_whitelist <whitelist_file>
# Reads a whitelist file where each line has:
bt_parse_whitelist() {
    WHITELIST_ENTRIES=""
    if [ -n "$1" ] && [ -f "$1" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) continue ;; # Skip blank lines and comments
                *) WHITELIST_ENTRIES="${WHITELIST_ENTRIES}${line}
" ;;
            esac
        done < "$1"
    fi
}

# bt_in_whitelist <mac> <name>
# Checks if a given device (MAC and optional name) exists
# Returns:
# 0 (success) if found
# 1 (failure) if not found
bt_in_whitelist() {
    mac="$1"
    name="$2"

    echo "$WHITELIST_ENTRIES" | while IFS= read -r entry || [ -n "$entry" ]; do
        entry_mac=$(echo "$entry" | awk '{print $1}')
        entry_name=$(echo "$entry" | cut -d' ' -f2-)
        if [ "$mac" = "$entry_mac" ] && { [ -z "$entry_name" ] || [ "$name" = "$entry_name" ]; }; then
            exit 0
        fi
    done

    return 1
}

# Scan for nearby BT devices using bluetoothctl via expect.
# Env:
# BT_ADAPTER : adapter (e.g., hci0); auto-detected if unset (trailing ':' stripped)
# SCAN_SECONDS : scan duration (default 10)
# MAC_ID : optional AA:BB:CC:DD:EE:FF; if set, succeed only if seen
# LOG_DIR : directory for logs; defaults to current dir
# Usage:
# bt_scan_devices # list all devices
# bt_scan_devices AA:..:FF # success only if that MAC is seen
# Output: prints "MAC NAME" lines; returns 0 if any device (or MAC_ID) found.
# shellcheck disable=SC2120
bt_scan_devices_expect() {
    adapter="${BT_ADAPTER:-}"
    duration="${SCAN_SECONDS:-10}"
    mac_id="${MAC_ID:-}"
    [ -z "${mac_id}" ] && [ -n "${1:-}" ] && mac_id="$1"   # allow positional MAC
 
    # Detect adapter; hciconfig prints "hci0:"; strip trailing colon.
    if [ -z "${adapter}" ]; then
        adapter="$(hciconfig 2>/dev/null | awk '/^hci[0-9]+/ {print $1}' | head -n1)"
    fi
    adapter="${adapter%:}"
 
    if [ -z "${adapter}" ]; then
        log_error "No Bluetooth adapter found"
        return 1
    fi
 
    log_info "Using Bluetooth adapter: ${adapter}"
    hciconfig "${adapter}" up 2>/dev/null || true
    sleep 1
 
    # Expect flow (prompt-tolerant, in-memory capture)
    scan_raw="$(expect -c "
log_user 1
set timeout 30
set dev \"${adapter}\"
set d ${duration}
spawn bluetoothctl
expect -re {#|\\\[.*\\\]#}
send \"power on\\r\"
expect -re {#|\\\[.*\\\]#}
send \"select \$dev\\r\"
expect -re {#|\\\[.*\\\]#}
send \"agent NoInputNoOutput\\r\"
expect -re {#|\\\[.*\\\]#}
send \"default-agent\\r\"
expect -re {#|\\\[.*\\\]#}
send \"scan on\\r\"
after [expr {\$d * 1000}]
send \"scan off\\r\"
expect -re {#|\\\[.*\\\]#} {}
send \"quit\\r\"
expect { timeout {} eof {} }
" 2>&1)"
 
    log_info "scan_raw size: $(printf '%s' "${scan_raw}" | wc -c) bytes"
    printf '%s\n' "${scan_raw}" | head -n 3 | sed 's/^/[RAW] /' >&2
 
    # Clean CRs; sanity check for "Device " lines
    scan_clean="$(printf '%s' "${scan_raw}" | tr -d '\r')"
    if ! printf '%s' "${scan_clean}" | grep -q 'Device '; then
        log_warn "No 'Device ' lines found after scan. Check bluetoothctl output/locale."
        return 1
    fi
    log_info "scan_clean size: $(printf '%s' "${scan_clean}" | wc -c) bytes"
    printf '%s\n' "${scan_clean}" | head -n 3 | sed 's/^/[CLN] /' >&2
 
    # Build unique "MAC NAME" lines (BusyBox-safe MAC check)
    found_lines="$(
        printf '%s\n' "${scan_clean}" |
        awk '
          function is_hex_pair(s,    c1,c2) {
            if (length(s)!=2) return 0
            c1=substr(s,1,1); c2=substr(s,2,1)
            return index("0123456789ABCDEFabcdef", c1) && index("0123456789ABCDEFabcdef", c2)
          }
          function is_mac(m,    a,n,i) {
            n = split(m, a, ":"); if (n!=6) return 0
            for (i=1;i<=6;i++) if (!is_hex_pair(a[i])) return 0
            return 1
          }
          /Device/ {
            mac=""; start=0
            if ($1=="[NEW]" && $2=="Device")        { mac=$3; start=4 }   # [NEW] Device MAC Name...
            else if ($1=="Device")                  { mac=$2; start=3 }   # Device MAC Name...
            else {
              for (i=1;i<=NF;i++) if ($i=="Device") { mac=$(i+1); start=i+2; break }
            }
            if (is_mac(mac)) {
              name=""
              for (i=start;i<=NF;i++) name = name (i==start?"":" ") $i
              sub(/[[:space:]]+$/,"",name)
              # drop status-only lines (RSSI/UUIDs/etc.) and hyphenated-MAC-as-name noise
              if (name ~ /^(RSSI|UUIDs:|TxPower|ManufacturerData(\.|:)?|Paired|Connected|Advertising|Flags:|ServiceData|Alias:|Class:|Icon:|Modalias:|Services)/) next
              if (name ~ /^[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}$/) next
              if (name=="") next
              print mac, name
            }
          }
        ' | sort -u
    )"
 
    if [ -z "${found_lines}" ]; then
        log_warn "Parsed 0 devices (format/parser issue?)."
        return 1
    fi
 
    if [ -n "${mac_id}" ]; then
        if match_line="$(printf '%s\n' "${found_lines}" | awk -v t="${mac_id}" 'BEGIN{IGNORECASE=1} $1==t {print; exit 0} END{exit 1}')"; then
            printf '%s\n' "${match_line}"
            return 0
        fi
        log_warn "MAC_ID not found: ${mac_id}"
        return 1
    fi
 
    printf '%s\n' "${found_lines}"
    return 0
}

# Scan for nearby BT devices using bluetoothctl (no expect).
# Env:
#   BT_ADAPTER   : adapter (e.g. hci0); auto-detected if unset
#   SCAN_SECONDS : total scan window (default 10)
#   MAC_ID       : optional AA:BB:CC:DD:EE:FF; if set, succeed only if seen
# Usage:
#   bt_scan_devices               # list all devices (prints "MAC NAME" lines)
#   bt_scan_devices AA:..:FF      # success only if that MAC is seen
# Return:
#   0 on success, 1 on failure (no devices / MAC not found)
# shellcheck disable=SC2120
bt_scan_devices() {
    adapter="${BT_ADAPTER:-}"
    scan_window="${SCAN_SECONDS:-10}"
    mac_id="${MAC_ID:-}"

    # Allow positional MAC as first arg if MAC_ID not set
    if [ -z "$mac_id" ] && [ -n "${1:-}" ]; then
        mac_id="$1"
    fi

    # Detect adapter (hci0, hci1, ...)
    if [ -z "$adapter" ] && command -v hciconfig >/dev/null 2>&1; then
        adapter="$(hciconfig 2>/dev/null | awk '/^hci[0-9]+:/ {print $1}' | head -n1)"
    fi
    adapter="${adapter%:}"

    if [ -z "$adapter" ]; then
        log_error "bt_scan_devices: No Bluetooth adapter found"
        return 1
    fi

    log_info "bt_scan_devices: using adapter $adapter (window=${scan_window}s)"

    # Make sure adapter is powered on (best-effort)
    if command -v btpower >/dev/null 2>&1; then
        if ! btpower "$adapter" on; then
            log_warn "bt_scan_devices: btpower($adapter on) did not report success; continuing anyway"
        fi
    else
        log_info "bt_scan_devices: btpower helper missing, assuming adapter is already powered."
    fi

    # Start scan using CLI helper (non-expect)
    if ! bt_set_scan on; then
        log_warn "bt_scan_devices: bt_set_scan(on) reported failure; will still poll 'devices'."
    fi

    start_ts=$(date +%s 2>/dev/null || printf '%s\n' 0)
    [ "$scan_window" -le 0 ] 2>/dev/null && scan_window=10

    found_lines=""
    seen_target=0

    # Poll 'bluetoothctl devices' for up to scan_window seconds
    while :; do
        devices_out="$(
            bluetoothctl devices 2>/dev/null | sanitize_bt_output || true
        )"

        if [ -n "$devices_out" ]; then
            # Convert "Device MAC NAME..." → "MAC NAME" lines, unique
            found_lines="$(
                printf '%s\n' "$devices_out" | awk '
                  function is_hex_pair(s,    c1,c2) {
                    if (length(s)!=2) return 0
                    c1=substr(s,1,1); c2=substr(s,2,1)
                    return index("0123456789ABCDEFabcdef", c1) && index("0123456789ABCDEFabcdef", c2)
                  }
                  function is_mac(m,    a,n,i) {
                    n = split(m, a, ":"); if (n!=6) return 0
                    for (i=1;i<=6;i++) if (!is_hex_pair(a[i])) return 0
                    return 1
                  }
                  /^Device[[:space:]]/ {
                    mac=$2
                    if (!is_mac(mac)) next
                    name=""
                    for (i=3;i<=NF;i++) name = name (i==3?"":" ") $i
                    sub(/[[:space:]]+$/,"",name)
                    if (name=="") next
                    print mac, name
                  }
                ' | sort -u
            )"

            if [ -n "$found_lines" ]; then
                if [ -n "$mac_id" ]; then
                    if printf '%s\n' "$found_lines" \
                        | awk -v t="$mac_id" 'BEGIN{IGNORECASE=1} $1==t {exit 0} END{exit 1}'
                    then
                        seen_target=1
                        break
                    fi
                else
                    # Any device is enough if no MAC_ID filter
                    seen_target=1
                    break
                fi
            fi
        fi

        # Check timeout
        now_ts=$(date +%s 2>/dev/null || printf '%s\n' "$scan_window")
        elapsed=$((now_ts - start_ts))
        if [ "$elapsed" -ge "$scan_window" ]; then
            break
        fi
        sleep 1
    done

    # Stop scan (best-effort)
    if ! bt_set_scan off; then
        log_warn "bt_scan_devices: bt_set_scan(off) reported failure"
    fi

    if [ -z "$found_lines" ]; then
        log_warn "bt_scan_devices: no devices parsed from 'bluetoothctl devices'"
        return 1
    fi

    if [ -n "$mac_id" ]; then
        # Print only the matching line if available
        match_line="$(
            printf '%s\n' "$found_lines" \
            | awk -v t="$mac_id" 'BEGIN{IGNORECASE=1} $1==t {print; exit}'
        )"
        if [ -n "$match_line" ]; then
            printf '%s\n' "$match_line"
            return 0
        fi
        log_warn "bt_scan_devices: MAC_ID not found: $mac_id"
        return 1
    fi

    # No filter: print all MAC/NAME pairs
    printf '%s\n' "$found_lines"
    return 0
}

# Pair with Bluetooth device using MAC (with retries and timestamped logs)
bt_pair_with_mac_expect() {
    bt_mac="$1"
    # Replace colons, strip any whitespace so no trailing spaces in filenames
    safe_mac=$(echo "$bt_mac" | tr ':' '_' | tr -d '[:space:]')
    max_retries=3
    retry=1

    while [ "$retry" -le "$max_retries" ]; do
        log_info "Interactive pairing attempt $retry for $bt_mac"
        log_file="$PWD/bt_headless_pair_${safe_mac}_$(date +%s).log"

        expect -c "
log_user 1
set timeout 30
set bt_mac \"$bt_mac\"

spawn bluetoothctl

expect -re {#|\\\[.*\\\]#} { send \"power on\r\" }
expect -re {#|\\\[.*\\\]#} { send \"agent NoInputNoOutput\r\" }
expect -re {#|\\\[.*\\\]#} { send \"default-agent\r\" }
expect -re {#|\\\[.*\\\]#} { send \"scan on\r\" }
sleep 10
send \"scan off\r\"
sleep 1
send \"pair \$bt_mac\r\"

expect {
    -re {Confirm passkey.*yes/no} {
        send \"yes\r\"
        exp_continue
    }
    -re {Authorize service.*yes/no} {
        send \"yes\r\"
        exp_continue
    }
    timeout {
        send \"quit\r\"
        exit 0
    }
    eof {
        exit 0
    }
}
" > "$log_file" 2>&1

        # Now analyze the log
        if grep -q "Pairing successful" "$log_file"; then
            log_pass "Pairing successful with $bt_mac"
            return 0
        elif grep -q "Failed to pair: org.bluez.Error" "$log_file"; then
            log_warn "Pairing failed with $bt_mac (BlueZ error)"
        elif grep -q "AuthenticationCanceled" "$log_file"; then
            log_warn "Pairing canceled with $bt_mac"
        else
            log_warn "Pairing failed with unknown reason (check $log_file)"
        fi

        bt_cleanup_paired_device "$bt_mac"
        retry=$((retry + 1))
        sleep 2
    done

    log_fail "Pairing failed after $max_retries attempts for $bt_mac"
    return 1
}

bt_pair_with_mac() {
    if [ $# -lt 1 ]; then
        log_error "Usage: bt_pair_with_mac <MAC> [adapter]"
        return 1
    fi
 
    mac=$1
 
    # Optional second arg: adapter; otherwise use default helper or hci0
    if [ $# -ge 2 ]; then
        adapter=$2
    else
        if command -v bt_get_default_adapter >/dev/null 2>&1; then
            adapter=$(bt_get_default_adapter)
        else
            adapter="hci0"
        fi
    fi
 
    if ! command -v bluetoothctl >/dev/null 2>&1; then
        log_error "bt_pair_with_mac: bluetoothctl not found in PATH"
        return 1
    fi
 
    # Safe logfile name: MAC with ':' -> '_' (same pattern as your last working snapshot)
    safe_mac=$(printf '%s\n' "$mac" | tr '[:lower:]' '[:upper:]' | tr ':' '_')
    ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%s)
    logfile="bt_pair_${safe_mac}_${ts}.log"
  
    log_info "Ensuring controller is powered on before pairing (adapter=${adapter})..."
    if command -v btpower >/dev/null 2>&1; then
        btpower "$adapter" on >>"$logfile" 2>&1 || \
            log_warn "bt_pair_with_mac: btpower reported a failure (continuing)."
    else
        log_warn "bt_pair_with_mac: 'btpower' helper not found; assuming adapter is powered."
    fi
 
    # ---------------- First attempt: no internal scan ----------------
    log_info "Attempting bluetoothctl 'pair $mac' (no internal scan)..."
    bluetoothctl --timeout 20 pair "$mac" >>"$logfile" 2>&1 || true
 
    # Success = explicit "Pairing successful" only (no 'Paired: yes' check)
    if grep -qi 'Pairing successful' "$logfile"; then
        log_info "bt_pair_with_mac: successfully paired with $mac"
        return 0
    fi
 
    # ---------------- Fallback: only if device was "not available" ----------------
    if grep -qi 'not available' "$logfile"; then
        log_warn "bt_pair_with_mac: device not available; running short scan+retry for $mac"
 
        if command -v bt_scan_devices >/dev/null 2>&1; then
            # Append scan logs to the same file for full context
            bt_scan_devices "$mac" >>"$logfile" 2>&1 || \
                log_warn "bt_pair_with_mac: bt_scan_devices reported a failure (continuing)."
        else
            log_warn "bt_pair_with_mac: bt_scan_devices helper not found; skipping scan retry."
        fi
 
        log_info "Retrying bluetoothctl 'pair $mac' after scan..."
        bluetoothctl --timeout 20 pair "$mac" >>"$logfile" 2>&1 || true
 
        if grep -qi 'Pairing successful' "$logfile"; then
            log_info "bt_pair_with_mac: successfully paired with $mac after scan retry"
            return 0
        fi
    fi
    # -----------------------------------------------------------------
 
    log_warn "bt_pair_with_mac: bluetoothctl did not report successful pairing for $mac (see $logfile)"
    return 1
}

# Utility to reliably scan and pair Bluetooth devices through a unified workflow of repeated attempts.
retry_scan_and_pair() {
    retry=1
    max_retries=2

    while [ "$retry" -le "$max_retries" ]; do
        log_info "Bluetooth scan attempt $retry..."
        bt_scan_devices

        if [ -n "$BT_MAC" ]; then
            log_info "Matching against: BT_NAME='$BT_NAME', BT_MAC='$BT_MAC', WHITELIST='$WHITELIST'"
            if ! bt_in_whitelist "$BT_MAC" "$BT_NAME"; then
                log_warn "Expected device not found or not in whitelist"
                retry=$((retry + 1))
                continue
            fi
            bt_cleanup_paired_device "$BT_MAC"
            if bt_pair_with_mac "$BT_MAC"; then
                return 0
            fi

        elif [ -n "$BT_NAME" ]; then
            matched_mac=$(awk -v name="$BT_NAME" 'tolower($0) ~ tolower(name) { print $1; exit }' "$SCAN_RESULT")
            if [ -n "$matched_mac" ]; then
                log_info "Found matching device by name ($BT_NAME): $matched_mac"
                bt_cleanup_paired_device "$matched_mac"
                if bt_pair_with_mac "$matched_mac"; then
                    BT_MAC="$matched_mac"
                    return 0
                fi
            else
                log_warn "Device with name $BT_NAME not found in scan results"
            fi

        else
            log_warn "No MAC or device name provided, and whitelist is empty"
        fi

        retry=$((retry + 1))
    done

    log_fail "Retry scan and pair failed after $max_retries attempts"
    return 1
}

# Post-pairing connection test with bluetoothctl and l2ping fallback
bt_post_pair_connect_1() {
    target_mac="$1"
    sanitized_mac=$(echo "$target_mac" | tr ':' '_')
    timestamp=$(date '+%Y%m%d_%H%M%S')
    base_logfile="bt_connect_${sanitized_mac}_${timestamp}"
    max_attempts=3
    attempt=1

    if bluetoothctl info "$target_mac" | grep -q "Connected: yes"; then
        log_info "Device $target_mac is already connected, skipping explicit connect"
        log_pass "Post-pair connection successful"
        return 0
    fi

    while [ "$attempt" -le "$max_attempts" ]; do
        log_info "Attempting to connect post-pair (try $attempt): $target_mac"
        logfile="${base_logfile}_attempt${attempt}.log"

        expect <<EOF >"$logfile" 2>&1
log_user 1
set timeout 10
spawn bluetoothctl
expect -re "#|\\[.*\\]#" { send "trust $target_mac\r" }
expect -re "#|\\[.*\\]#" { send "connect $target_mac\r" }

expect {
    -re "Connection successful" { exit 0 }
    -re "Failed to connect|Device not available" { exit 1 }
    timeout { exit 1 }
}
EOF
        result=$?
        if [ "$result" -eq 0 ]; then
            log_pass "Post-pair connection successful"
            return 0
        fi
        log_warn "Connect attempt $attempt failed (check $logfile)"
        attempt=$((attempt + 1))
        sleep 2
    done

    # Fallback to l2ping
    log_info "Falling back to l2ping for $target_mac"
    l2ping_log="${base_logfile}_l2ping_${timestamp}.log"
    if command -v l2ping >/dev/null 2>&1; then
        # Capture all output—even if ping succeeds, we log it
        if l2ping -c 3 -t 5 "$target_mac" 2>&1 | tee "$l2ping_log" | grep -q "bytes from"; then
            log_pass "Fallback l2ping succeeded for $target_mac (see $l2ping_log)"
            return 0
        else
            log_warn "l2ping failed or no response for $target_mac (see $l2ping_log)"
        fi
    else
        log_warn "l2ping not available, skipping fallback"
    fi
    log_fail "Post-pair connection failed for $target_mac"
    return 1
}

bt_post_pair_connect() {
    target_mac="$1"
    sanitized_mac=$(echo "$target_mac" | tr ':' '_')
    timestamp=$(date '+%Y%m%d_%H%M%S')
    base_logfile="bt_connect_${sanitized_mac}_${timestamp}"
 
    # Already connected? (like when pair leaves us connected)
    if bluetoothctl info "$target_mac" 2>/dev/null \
        | sanitize_bt_output \
        | grep -q 'Connected:[[:space:]]*yes'
    then
        log_info "Device $target_mac already Connected=yes"
        log_pass "Post-pair connection successful"
        return 0
    fi
 
    max_attempts=3
    attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        logfile="${base_logfile}_attempt${attempt}.log"
        log_info "Attempting bluetoothctl connect (try $attempt/$max_attempts) to $target_mac"
 
        bluetoothctl <<EOF >"$logfile" 2>&1
power on
trust $target_mac
connect $target_mac
quit
EOF
 
        if bluetoothctl info "$target_mac" 2>/dev/null \
            | sanitize_bt_output \
            | grep -q 'Connected:[[:space:]]*yes'
        then
            log_pass "Post-pair connection successful to $target_mac (see $logfile)"
            return 0
        fi
 
        if grep -q "Failed to connect" "$logfile"; then
            log_warn "bluetoothctl reported connect failure for $target_mac (see $logfile)"
        else
            log_warn "No 'Connected: yes' for $target_mac after attempt $attempt (see $logfile)"
        fi
 
        attempt=$((attempt + 1))
        sleep 2
    done
 
    # Final fallback: l2ping (this is what the test ultimately cares about)
    if command -v l2ping >/dev/null 2>&1; then
        l2ping_log="${base_logfile}_l2ping.log"
        log_info "Falling back to l2ping for $target_mac"
        if l2ping -c 3 -t 5 "$target_mac" 2>&1 \
            | tee "$l2ping_log" \
            | grep -q "bytes from"
        then
            log_pass "l2ping succeeded for $target_mac (see $l2ping_log)"
            return 0
        fi
        log_warn "l2ping failed or no response for $target_mac (see $l2ping_log)"
    else
        log_warn "l2ping not available, skipping connectivity fallback for $target_mac"
    fi
 
    log_fail "Post-pair connection failed for $target_mac"
    return 1
}

# Find MAC address from device name in scan log
bt_find_mac_by_name() {
    target="$1"
    log="$2"
    grep -i "$target" "$log" | awk '{print $3}' | head -n1
}

bt_remove_all_paired_devices() {
    log_info "Removing all previously paired Bluetooth devices..."
    bluetoothctl paired-devices | awk '/Device/ {print $2}' | while read -r dev; do
        log_info "Removing paired device $dev"
        bluetoothctl remove "$dev" >/dev/null
    done
}

# Validate connectivity using l2ping
bt_l2ping_check() {
    target_mac="$1"
    logfile="$2"
 
    if ! command -v l2ping >/dev/null 2>&1; then
        log_warn "l2ping command not available - skipping"
        return 1
    fi
 
    # Small grace period after connect so the remote side can settle
    sleep 2
 
    attempts=2
    i=1
 
    while [ "$i" -le "$attempts" ]; do
        log_info "Running l2ping test for $target_mac (attempt $i/$attempts)"
        if l2ping -c 3 -t 5 "$target_mac" >>"$logfile" 2>&1; then
            log_pass "l2ping to $target_mac succeeded on attempt $i"
            return 0
        fi
        log_warn "l2ping to $target_mac failed on attempt $i"
        i=$((i + 1))
        sleep 2
    done
 
    log_warn "l2ping to $target_mac failed after $attempts attempts"
    return 1
}

hascmd() { command -v "$1" >/dev/null 2>&1; }

# Strip carriage returns (and any accidental Windows-style line endings)
sanitize_bt_output() {
    # Strip CR (\r) from bluetoothctl / expect output.
    # Ignore EPIPE when the downstream command (awk/grep) exits early.
    tr -d '\r' 2>/dev/null || true
}

# Run bluetoothctl with a list of commands.
# Each argument becomes one line; callers can also pass a single
# multi-line string if they prefer.
btctl_script() {
    # If nothing to send, do nothing
    if [ "$#" -eq 0 ]; then
        return 0
    fi
 
    {
        # Each argument is printed as a separate line
        for line in "$@"; do
            # Skip empty arguments to be safe
            [ -n "$line" ] || continue
            printf '%s\n' "$line"
        done
    } | bluetoothctl 2>/dev/null
}

# bt_set_scan on|off [adapter]
# NOTE:
#   - We deliberately ignore adapter here and rely on BlueZ's default controller,
#     which matches the manual "bluetoothctl ; scan on" usage.
#   - Non-expect, pure CLI.
bt_set_scan() {
    want="${1:-}"
    # adapter="${2:-}"  # currently unused but kept for API compatibility
 
    case "$want" in
        on)
            log_info "Enabling scan via 'bluetoothctl scan on'"
            if ! printf 'scan on\n' | bluetoothctl >/dev/null 2>&1; then
                log_warn "bt_set_scan(on): bluetoothctl scan on failed"
                return 1
            fi
            ;;
	off)
        timeout="${BT_SCAN_OFF_TIMEOUT:-5}"
 
        if command -v log_info >/dev/null 2>&1; then
            log_info "bt_set_scan(off): running 'bluetoothctl --timeout $timeout scan off'"
        fi
 
        out="$(bluetoothctl --timeout "$timeout" scan off 2>&1 || true)"
 
        if command -v sanitize_bt_output >/dev/null 2>&1 && \
           command -v log_info >/dev/null 2>&1; then
            printf '%s\n' "$out" | sanitize_bt_output | while IFS= read -r line; do
                [ -n "$line" ] && log_info " [scan off] $line"
            done
        fi
 
        # Consider both "Discovery stopped" and "Failed to stop discovery"
        # (already stopped) as success.
        if printf '%s\n' "$out" | grep -q "Discovery stopped"; then
            return 0
        fi
        if printf '%s\n' "$out" | grep -q "Failed to stop discovery"; then
            log_info "bt_set_scan(off): discovery was already stopped, treating as success"
            return 0
        fi
 
        return 1
        ;;
 
 
        *)
            log_warn "bt_set_scan: invalid argument '$want' (expected on/off)"
            return 2
            ;;
    esac
 
    # Give BlueZ a very short moment to apply the change
    sleep 1
    return 0
}

rfkillunblocksysfs() {
    ok=1
    for d in /sys/class/rfkill/rfkill*; do
        [ -d "$d" ] || continue
        tfile="$d/type"
        [ -r "$tfile" ] || continue
        if [ "$(cat "$tfile" 2>/dev/null)" = "bluetooth" ]; then
            if [ -w "$d/state" ]; then echo 0 > "$d/state" 2>/dev/null || ok=0
            elif [ -w "$d/soft" ]; then echo 0 > "$d/soft" 2>/dev/null || ok=0
            fi
        fi
    done
    return $ok
}

listhcis() {
    found=0
    for h in /sys/class/bluetooth/hci*; do
        [ -d "$h" ] || continue
        basename "$h"
        found=1
    done
    if [ $found -eq 0 ] && hascmd hciconfig; then
        hciconfig 2>/dev/null | awk -F: '/^hci[0-9]+:/ {print $1}'
    fi
}

findhcisysfs() {
    for h in /sys/class/bluetooth/hci*; do
        [ -d "$h" ] || continue
        basename "$h"
        return 0
    done
    return 1
}

# stdout: MAC if known (e.g. 00:00:00:00:5A:AD)
# ret: 0=ok, 1=not found
btgetbdaddr() {
    dev="${1:-}"
 
    if command -v hciconfig >/dev/null 2>&1; then
        if [ -n "$dev" ]; then
            addr="$(hciconfig -a "$dev" 2>/dev/null | awk '/BD Address:/ {print $3; exit}')"
        else
            addr="$(hciconfig -a 2>/dev/null        | awk '/BD Address:/ {print $3; exit}')"
        fi
        if [ -n "$addr" ]; then
            # IMPORTANT: no log_info here, this is used in command substitution.
            printf '%s\n' "$addr"
            return 0
        fi
    fi
 
    # No logging here either, caller will log if needed.
    return 1
}

# ret: 0=controller visible, 1=none
btcontrollerpresent() {
    # Use plain bluetoothctl list here; the expect wrapper is overkill and
    # sometimes swallows the "Controller ..." line for pipelines.
    if bluetoothctl list 2>/dev/null \
        | sanitize_bt_output \
        | grep -qi '^[[:space:]]*Controller[[:space:]]'
    then
        return 0
    fi
    return 1
}

# Usage: btensurepublicaddr hci0
# Logic:
#   - If bluetoothctl already sees a Controller -> no-op (no expect)
#   - Else read BD from hciconfig and run "menu mgmt / public-addr <BD>" via btctl_script
# Return:
#   0 = controller visible (already or now)
#   1 = failed to make visible
#   2 = could not read BD address
btensurepublicaddr() {
    dev="${1:-}"
 
    # Already visible: nothing to do.
    if btcontrollerpresent; then
        log_info "controller already visible via bluetoothctl, skip public-addr"
        return 0
    fi
 
    # Read BD address and sanitize to a single MAC token
    mac="$(
        btgetbdaddr "$dev" 2>/dev/null \
        | head -n 1 \
        | awk '{print $NF}'
    )"
 
    if [ -z "$mac" ]; then
        log_warn "could not read bd address ${dev:+for $dev} public-addr cannot be applied"
        return 2
    fi
 
    log_info "applying bluetoothctl public-addr $mac"
 
    # Drive bluetoothctl menu mgmt non-interactively (no expect)
    btctl_script "menu mgmt
public-addr $mac
back
quit" >/dev/null 2>&1 || true
 
    # --- NEW: poll for controller visibility (handle BlueZ async delay) ---
    i=0
    max_wait=5   # seconds
    while [ "$i" -lt "$max_wait" ]; do
        if btcontrollerpresent; then
            log_info "controller visible after public-addr $mac (waited ${i}s)"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
 
    log_warn "controller still not visible after public-addr $mac (after ${max_wait}s)"
    return 1
}

# Ensure at least one controller is visible to bluetoothctl.
# Optionally takes an adapter name (e.g. hci0) to use for public-addr.
# Usage:
#   bt_ensure_controller_visible              # auto-detect adapter
#   bt_ensure_controller_visible hci0
# Returns:
#   0 = controller visible (already or after public-addr)
#   1 = still no controller visible
bt_ensure_controller_visible() {
    adapter="${1:-}"
 
    # Fast path: already visible
    if btcontrollerpresent; then
        return 0
    fi
 
    # Try to guess adapter from sysfs if not provided
    if [ -z "$adapter" ]; then
        if findhcisysfs >/dev/null 2>&1; then
            adapter="$(findhcisysfs 2>/dev/null || true)"
        fi
    fi
 
    if [ -n "$adapter" ]; then
        log_info "Using adapter for public-addr/bootstrap: $adapter"
        btensurepublicaddr "$adapter" || \
            log_warn "btensurepublicaddr($adapter) did not report success; will re-check controllers."
    else
        log_warn "No HCI adapter found in sysfs; cannot apply public-addr."
    fi
 
    # Final controller visibility check
    if btcontrollerpresent; then
        return 0
    fi
 
    return 1
}

# Resolve a controller handle we can safely use with `bluetoothctl select`.
# Input: "hci0" or "MAC". Output: MAC address suitable for `select`.
bt_resolve_controller_id() {
    in="${1-}"
    # If it already looks like a MAC, keep it.
    case "$in" in
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
            printf '%s\n' "$in"
            return 0
        ;;
    esac

    # If it's hciN (or empty), grab the first Controller from `bluetoothctl list`.
    # This works because after `public-addr` you get exactly one visible controller anyway.
    mac="$(bluetoothctl list 2>/dev/null | awk '/^Controller / {print $2; exit}')"
    if [ -n "$mac" ]; then
        printf '%s\n' "$mac"
        return 0
    fi
    # Fallback: print input (may be empty) and fail
    printf '%s\n' "$in"
    return 1
}

# Run bluetoothctl with optional mgmt/public-addr handling.
# Usage: btbluetoothctl "<adapter or empty>" "<newline-separated commands>"
btbluetoothctl() {
    # Usage: btbluetoothctl "<adapter or empty>" "<multi-line commands>"
    dev="$1"
    shift
    cmds="$1"

    BT_DEV="$dev" BT_CMDS="$cmds" expect << "__BTCTL__"
        log_user 1
        set timeout 12

        # Very permissive prompt matcher: '>' or '#' with/without [bluetooth...]
        proc waitp {} { expect -re {(\r\n|\n)?(\[.*\][#>]|[#>])} }

        set dev $env(BT_DEV)
        set lines $env(BT_CMDS)

        # Detect if we must enter 'menu mgmt' (for public-addr, etc.)
        set enter_mgmt 0
        if {[string match "*public-addr *" $lines] || [string match "*menu mgmt*" $lines]} {
            set enter_mgmt 1
        }

        spawn bluetoothctl
        waitp

        # Stabilize agent (idempotent)
        send "agent off\r"; waitp
        send "agent NoInputNoOutput\r";waitp
        send "default-agent\r"; waitp

        if {$enter_mgmt} {
            send "menu mgmt\r"; waitp
        }

        # Run every provided line
        foreach l [split $lines "\n"] {
            if {[string trim $l] eq ""} { continue }
            send "$l\r"
            waitp
        }

        if {$enter_mgmt} {
            send "back\r"; waitp
        }

        send "quit\r"
        expect { eof {} timeout {} }
__BTCTL__
}

# Return "yes" or "no" for adapter power state.
# Usage: btshowpowered [hciX]
# Stdout: yes|no
# Exit: 0 on known state, 1 if undetermined
btshowpowered() {
    dev="${1:-}"
    out="$(btbluetoothctl "$dev" "select $dev\nshow")"

    printf '%s\n' "$out" | grep -qi 'No default controller\|Controller .* not available' && return 2

    val="$(
        printf '%s\n' "$out" \
        | sed -n 's/^[[:space:]]*Powered:[[:space:]]*//p' \
        | tr '[:upper:]' '[:lower:]' \
        | head -n 1
    )"

    [ "$val" = "yes" ] && return 0
    [ "$val" = "no" ] && return 1
    return 2
}

btlist() {
    btbluetoothctl "" "list"
}

btbringup() {
    rfkillunblocksysfs || true
    if hascmd hciconfig; then
        listhcis | while IFS= read -r h; do
            [ -n "$h" ] || continue
            hciconfig "$h" up 2>/dev/null || true
        done
    fi
    if btlist | grep -q '^Controller[[:space:]]'; then return 0; fi
    return 1
}

# Read controller Powered state via 'bluetoothctl show'.
# Prints 'yes' or 'no' when known; prints 'unknown' otherwise.
# Return:
# 0 => printed yes/no successfully
# 1 => unable to determine (printed 'unknown')
bt_get_power() {
    out="$(bluetoothctl show 2>/dev/null | sanitize_bt_output || true)"

    state="$(
        printf '%s\n' "$out" \
        | awk -F':[[:space:]]*' '
            /^[[:space:]]*Powered:/ {
                v = tolower($2);
                gsub(/[[:space:]\r]+/, "", v);
                print v;
                exit
            }
        '
    )"

    if [ -z "$state" ]; then
        printf '%s\n' "unknown"
        return 1
    fi

    printf '%s\n' "$state"
    if [ "$state" = "yes" ] || [ "$state" = "no" ]; then
        return 0
    fi

    return 1
}

# Usage: bt_set_power on|off
# Return:
# 0 => requested state achieved (Powered: yes/no)
# 1 => we never saw the requested state
bt_set_power() {
    want="$1"
    case "$want" in
        on) target="yes" ;;
        off) target="no" ;;
        *) return 1 ;;
    esac

    # Fire command once; then poll state.
    btctl_script "power $want\nshow\nquit" >/dev/null 2>&1 || true

    i=0
    max_tries=5
    while [ "$i" -lt "$max_tries" ]; do
        state="$(bt_get_power 2>/dev/null || printf '%s\n' "unknown")"
        if [ "$state" = "$target" ]; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    return 1
}

# Set controller scan state using bluetoothctl, with an internal timeout
# and logging. This wraps the standalone working pattern:
#   bluetoothctl --timeout 15 scan on
#   bluetoothctl --timeout 5 scan off
#
# Usage:
#   bt_set_scan on  [adapter]
#   bt_set_scan off [adapter]
#
# Returns:
#   0 on "reasonable success", non-zero on clear error. Caller still
#   validates devices list / discovering state for real PASS/FAIL.
bt_set_scan() {
    mode="$1"
    # $2 (adapter) is currently unused here but kept for API compatibility.
 
    if [ -z "$mode" ]; then
        # Invalid usage
        return 2
    fi
 
    case "$mode" in
        on)
            timeout="${BT_SCAN_ON_TIMEOUT:-15}"
 
            # Informative log if logging helpers are available
            if command -v log_info >/dev/null 2>&1; then
                log_info "bt_set_scan(on): running 'bluetoothctl --timeout $timeout scan on'"
            fi
 
            out="$(bluetoothctl --timeout "$timeout" scan on 2>&1 || true)"
 
            # Optional: pretty log of the scan-on output
            if command -v sanitize_bt_output >/dev/null 2>&1 && \
               command -v log_info >/dev/null 2>&1; then
                printf '%s\n' "$out" | sanitize_bt_output | while IFS= read -r line; do
                    [ -n "$line" ] && log_info " [scan on] $line"
                done
            fi
 
            # Treat it as success if we at least see Discovery started
            printf '%s\n' "$out" | grep -q "Discovery started" && return 0
            # Otherwise soft-fail: caller still decides based on devices list.
            return 1
            ;;
 
        off)
            timeout="${BT_SCAN_OFF_TIMEOUT:-5}"
 
            if command -v log_info >/dev/null 2>&1; then
                log_info "bt_set_scan(off): running 'bluetoothctl --timeout $timeout scan off'"
            fi
 
            out="$(bluetoothctl --timeout "$timeout" scan off 2>&1 || true)"
 
            if command -v sanitize_bt_output >/dev/null 2>&1 && \
               command -v log_info >/dev/null 2>&1; then
                printf '%s\n' "$out" | sanitize_bt_output | while IFS= read -r line; do
                    [ -n "$line" ] && log_info " [scan off] $line"
                done
            fi
 
            # If Discovery stopped shows up, good.
            printf '%s\n' "$out" | grep -q "Discovery stopped" && return 0
            return 1
            ;;
 
        *)
            if command -v log_warn >/dev/null 2>&1; then
                log_warn "bt_set_scan: unsupported mode '$mode' (expected on|off)"
            fi
            return 2
            ;;
    esac
}

# Query Discovering state via 'bluetoothctl show'.
# Prints: yes|no|unknown
# Return:
# 0 => yes/no
# 1 => unknown / not found
bt_is_discovering() {
    out="$(bluetoothctl show 2>/dev/null | sanitize_bt_output || true)"

    val="$(
        printf '%s\n' "$out" \
        | awk -F':[[:space:]]*' '
            /^[[:space:]]*Discovering:/ {
                v = tolower($2);
                gsub(/[[:space:]\r]+/, "", v);
                print v;
                exit
            }
        '
    )"

    if [ -z "$val" ]; then
        printf '%s\n' "unknown"
        return 1
    fi

    printf '%s\n' "$val"
    if [ "$val" = "yes" ] || [ "$val" = "no" ]; then
        return 0
    fi

    return 1
}

bt_pair_once() {
    # Requires BT_REMOTE_MAC in env
    ctrl_mac="$(bt_first_mac 2>/dev/null || true)"
    if [ -z "${ctrl_mac:-}" ]; then
        log WARN "bt_pair_once: no controller MAC parsed from bluetoothctl list"
        return 2
    fi

    if [ -z "${BT_REMOTE_MAC:-}" ]; then
        log WARN "bt_pair_once: BT_REMOTE_MAC not set, skipping pair/connect."
        return 2
    fi

    log INFO "Attempting pair/connect to remote ${BT_REMOTE_MAC} from controller ${ctrl_mac}"

    btctl_script \
        "select $ctrl_mac" \
        "scan on" \
        "pair ${BT_REMOTE_MAC}" \
        "connect ${BT_REMOTE_MAC}" \
        "scan off" >/dev/null 2>&1 || true

    # Give BT stack some time to process pairing/connection
    sleep 5

    # Pairing check
    if bt_check_paired "$BT_REMOTE_MAC"; then
        log INFO "Remote ${BT_REMOTE_MAC} is PAIRED=YES (bluetoothctl info)."
    else
        log WARN "Remote ${BT_REMOTE_MAC} not reported as Paired=yes."
    fi

    # Connection check
    if bt_check_connected "$BT_REMOTE_MAC"; then
        log INFO "Remote ${BT_REMOTE_MAC} is CONNECTED=YES (bluetoothctl info)."
    else
        log WARN "Remote ${BT_REMOTE_MAC} not reported as Connected=yes."
    fi

    return 0
}

# Get current Discovering state from bluetoothctl show.
# Prints one of: yes | no | unknown
bt_get_discovering() {
    out="$(bluetoothctl show 2>/dev/null | sanitize_bt_output | tr -d '\r')"
 
    case "$out" in
        *"Discovering: yes"*)
            echo "yes"
            return 0
            ;;
        *"Discovering: no"*)
            echo "no"
            return 0
            ;;
        *)
            echo "unknown"
            return 1
            ;;
    esac
}

# Wait until Discovering == expected ("yes" or "no")
# Usage: bt_wait_discovering yes [max_iter] [sleep_secs]
bt_wait_discovering() {
    expected="$1"          # yes/no
    max_iter="${2:-10}"
    sleep_secs="${3:-2}"

    i=1
    while [ "$i" -le "$max_iter" ]; do
	state="$(bt_get_discovering "" 2>/dev/null || echo "unknown")"
        log_info "Discovering state during wait (iteration $i/$max_iter): $state"
        if [ "$state" = "$expected" ]; then
            return 0
        fi
        sleep "$sleep_secs"
        i=$((i + 1))
    done
    return 1
}

# Raw devices output from bluetoothctl
bt_list_devices_raw() {
    bluetoothctl devices 2>/dev/null | sanitize_bt_output
}

# Check whether devices are seen, optionally for a specific MAC.
# Usage:
#   bt_devices_seen ""          -> returns success if any devices exist
#   bt_devices_seen AA:BB:...   -> success only if that MAC is listed
bt_devices_seen() {
    target_mac="$1" # may be empty

    out="$(bt_list_devices_raw)"
    if [ -z "$out" ]; then
        # no devices at all
        return 1
    fi

    # No target: any device is good enough
    if [ -z "$target_mac" ]; then
        return 0
    fi

    tmac_upper=$(printf '%s\n' "$target_mac" | tr '[:lower:]' '[:upper:]')

    # Extract all MACs and compare
    printf '%s\n' "$out" \
        | awk '/^Device /{print toupper($2)}' \
        | grep -q "$tmac_upper"
}

# Perform a scan window and validate results.
# Args:
#   $1 = adapter name (e.g., hci0)
#   $2 = target MAC (may be empty for generic scan)
# Return:
#   0 = PASS (devices seen / target MAC found)
#   1 = FAIL (no devices / target MAC missing)
bt_scan_validate() {
    adapter="$1"
    target_mac="$2" # may be empty
    fail=0
 
    # --- Ensure power ON ---
    initial_power="$(btgetpower "$adapter" 2>/dev/null || echo "unknown")"
    if [ "$initial_power" != "yes" ]; then
        log_info "Adapter $adapter initial power=$initial_power; forcing power on before scan."
        if ! btpower "$adapter" on; then
            log_fail "Failed to power on $adapter before scan."
            return 1
        fi
        log_info "Adapter $adapter powered on for scan."
    else
        log_pass "Power ON verified before scan."
    fi
 
    if [ -n "$target_mac" ]; then
        log_info "Target MAC provided for BT_SCAN: $target_mac"
    else
        log_info "No target MAC provided, BT_SCAN will just verify that some devices are visible."
    fi
 
    # --- Scan ON phase ---
    log_info "Testing scan ON..."
    if ! bt_set_scan on; then
        log_warn "bt_set_scan(on) reported immediate failure; will still poll Discovering/devices."
    fi
 
    # Wait for Discovering=yes (best-effort)
    if bt_wait_discovering yes 10 2; then
        log_info "Observed Discovering=yes during scan ON window."
    else
        log_warn "Never observed Discovering=yes during scan ON polling window (may indicate stack/timing issue)."
    fi
 
    # Give a small extra window for devices to accumulate
    sleep 2
 
    dev_out="$(bt_list_devices_raw)"
    if [ -n "$dev_out" ]; then
        log_info "Devices seen by bluetoothctl after scan ON:"
        printf '%s\n' "$dev_out" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            log_info "  $line"
        done
    else
        log_info "Devices seen by bluetoothctl after scan ON: (none)"
    fi
 
    if ! bt_devices_seen "$target_mac"; then
        if [ -n "$target_mac" ]; then
            log_fail "Target MAC $target_mac not found in 'bluetoothctl devices' after scan ON window."
        else
            log_fail "No devices discovered in 'bluetoothctl devices' after scan ON window."
        fi
        fail=1
    else
        if [ -n "$target_mac" ]; then
            log_pass "Target MAC $target_mac present in 'bluetoothctl devices' after scan ON."
        else
            log_pass "At least one device present in 'bluetoothctl devices' after scan ON."
        fi
        fail=0
    fi
 
    # --- Scan OFF phase ---
    log_info "Testing scan OFF..."
    if ! bt_set_scan off; then
        log_warn "bt_set_scan(off) reported immediate failure; will still poll Discovering."
    fi
 
    if bt_wait_discovering no 10 2; then
        log_pass "Discovering=no observed after scan OFF polling."
    else
        log_warn "Did not observe Discovering=no within timeout after scan OFF."
    fi
 
    return "$fail"
}

bt_check_paired() {
    # bt_check_paired <remote-mac>
    rem="$1"
    out="$(
        bluetoothctl info "$rem" 2>/dev/null | tr -d '\r'
    )" || out=""
    [ -n "$out" ] || return 2

    val="$(
        printf '%s\n' "$out" \
        | awk -F':[[:space:]]*' '
            /^[[:space:]]*Paired:/ {
                v = tolower($2);
                gsub(/[[:space:]]+/, "", v);
                print v;
                exit
            }
        '
    )"

    [ -n "$val" ] || return 2
    [ "$val" = "yes" ] && return 0
    return 1
}

bt_check_connected() {
    # bt_check_connected <remote-mac>
    rem="$1"
    out="$(
        bluetoothctl info "$rem" 2>/dev/null | tr -d '\r'
    )" || out=""
    [ -n "$out" ] || return 2

    val="$(
        printf '%s\n' "$out" \
        | awk -F':[[:space:]]*' '
            /^[[:space:]]*Connected:/ {
                v = tolower($2);
                gsub(/[[:space:]]+/, "", v);
                print v;
                exit
            }
        '
    )"

    [ -n "$val" ] || return 2
    [ "$val" = "yes" ] && return 0
    return 1
}

btgetpower() {
    dev="${1-}"
    state=""

    # Prefer adapter-specific show if provided
    if [ -n "$dev" ]; then
        out="$(bluetoothctl show "$dev" 2>/dev/null | sanitize_bt_output || true)"
    else
        out="$(bluetoothctl show 2>/dev/null | sanitize_bt_output || true)"
    fi

    state="$(printf '%s\n' "$out" \
        | awk -F':[[:space:]]*' '
            /^[[:space:]]*Powered:/ {
                v = tolower($2);
                gsub(/\r/, "", v);
                gsub(/[[:space:]]+/, "", v);
                print v;
                exit
            }
        ')"

    # Fallback: try default controller if adapter one failed
    if [ -z "$state" ]; then
        out="$(bluetoothctl show 2>/dev/null | sanitize_bt_output || true)"
        state="$(printf '%s\n' "$out" \
            | awk -F':[[:space:]]*' '
                /^[[:space:]]*Powered:/ {
                    v = tolower($2);
                    gsub(/\r/, "", v);
                    gsub(/[[:space:]]+/, "", v);
                    print v;
                    exit
                }
            ')"
    fi

    [ -n "$state" ] || return 2

    if [ "$state" = "yes" ] || [ "$state" = "no" ]; then
        printf '%s\n' "$state"
        return 0
    fi

    return 2
}

# Usage: btpower hci0 on|off
# Returns:
#   0 = requested state achieved (including when already in that state)
#   1 = requested state not achieved
#   2 = no controller / state unknown
btpower() {
    dev="${1:-}"
    want="${2:-}"
 
    case "$want" in
        on|off)
            ;;
        *)
            log_warn "btpower: invalid target state '$want'"
            return 1
            ;;
    esac
 
    # ---- Early check: avoid redundant toggles ----
    cur_state="$(btgetpower "$dev" 2>/dev/null || true)"
    [ -z "$cur_state" ] && cur_state="unknown"
 
    if [ "$want" = "on" ] && [ "$cur_state" = "yes" ]; then
        log_info "btpower: $dev already Powered=yes; skipping 'power on'."
        return 0
    fi
 
    if [ "$want" = "off" ] && [ "$cur_state" = "no" ]; then
        log_info "btpower: $dev already Powered=no; skipping 'power off'."
        return 0
    fi
 
    log_info "btpower: requesting '$want' on $dev (current=$cur_state)"
 
    # ---- Existing behaviour: drive HCI or bluetoothctl, then poll ----
    if [ -n "$dev" ] && command -v hciconfig >/dev/null 2>&1; then
        case "$want" in
            on)
                hciconfig "$dev" up >/dev/null 2>&1 || true
                ;;
            off)
                hciconfig "$dev" down >/dev/null 2>&1 || true
                ;;
        esac
    else
        # Fallback: drive via bluetoothctl main menu (no 'select hci0' — that breaks)
        printf 'power %s\nquit\n' "$want" | bluetoothctl >/dev/null 2>&1 || true
    fi
 
    # Now poll btgetpower a few times to see if BlueZ agrees
    i=0
    max_tries=5
    state=""
    while [ "$i" -lt "$max_tries" ]; do
        state="$(btgetpower "$dev" 2>/dev/null || true)"
 
        # Could not read state at all → try again briefly
        if [ -z "$state" ]; then
            sleep 1
            i=$((i + 1))
            continue
        fi
 
        if [ "$want" = "on" ] && [ "$state" = "yes" ]; then
            log_info "btpower: $dev Powered=yes after request."
            return 0
        fi
 
        if [ "$want" = "off" ] && [ "$state" = "no" ]; then
            log_info "btpower: $dev Powered=no after request."
            return 0
        fi
 
        # Mismatch, give BlueZ a moment more
        sleep 1
        i=$((i + 1))
    done
 
    # After polling, decide error type
    if [ -z "$state" ]; then
        log_warn "btpower: unable to read Powered state for $dev after request."
        return 2 # unknown / no Powered line
    fi
 
    log_warn "btpower: $dev state after request is '$state' (wanted $want)."
    return 1 # we read a state but it never matched the target
}

btfwpresent() {
    dir=""
    for d in /lib/firmware/qca /usr/lib/firmware/qca /lib/firmware /usr/lib/firmware; do
        [ -d "$d" ] || continue
        if ls "$d"/msbtfw*.mbn "$d"/msbtfw*.tlv "$d"/msnv*.bin >/dev/null 2>&1; then
            dir="$d"; break
        fi
    done
    [ -n "$dir" ] || return 1
    printf '%s\n' "$dir"
    return 0
}

btfwloaded() {
    # ---- Configurable patterns (override via env if needed) ----
    # "Final success" (strongest marker that FW+UART setup completed)
    success_re="${BTFW_SUCCESS_RE:-setup on UART is completed|setup on uart is completed}"

    # "Fatal-ish" errors: these should FAIL only if they occur after the final success,
    # otherwise they indicate transient issues during bring-up -> WARN.
    fatal_re="${BTFW_FATAL_RE:-tx timeout|Reading QCA version information failed|failed to open firmware|firmware file.*not found|download.*firmware.*failed|failed to download.*firmware|timeout waiting for firmware|firmware.*load.*failed}"

    # Retry/transient hints: if success exists and we see these, we likely want WARN.
    transient_re="${BTFW_TRANSIENT_RE:-Retry BT power ON|retry bt power on|reset|re-init|reinit|failed.*\\(-110\\)}"

    # ---- Collect recent relevant dmesg ----
    # Filter for BT/QCA/WCN related lines; keep a reasonable window.
    out="$(
        dmesg 2>/dev/null \
        | grep -i -E 'Bluetooth|hci[0-9]|QCA|wcn|btqca|WCN' \
        | tail -n "${BTFW_DMESG_TAIL:-600}"
    )"

    if [ -z "$out" ]; then
        log_warn "btfwloaded: no recent Bluetooth/QCA/WCN messages in dmesg."
        return 1
    fi

    # ---- Find last success line number and last fatal line number ----
    # We use line order within $out (monotonic, no need for real timestamps).
    last_success="$(
        printf '%s\n' "$out" \
        | awk -v IGNORECASE=1 -v re="$success_re" '
            $0 ~ re { n=NR }
            END { if (n>0) print n; else print 0 }
        '
    )"

    last_fatal="$(
        printf '%s\n' "$out" \
        | awk -v IGNORECASE=1 -v re="$fatal_re" '
            $0 ~ re { n=NR }
            END { if (n>0) print n; else print 0 }
        '
    )"

    # Also note if we saw any explicit transient/retry indicator
    saw_transient="$(
        printf '%s\n' "$out" \
        | awk -v IGNORECASE=1 -v re="$transient_re" '
            $0 ~ re { found=1; exit }
            END { if (found) print 1; else print 0 }
        '
    )"

    # ---- Decision tree ----
    if [ "$last_success" -eq 0 ]; then
        log_warn "btfwloaded: no final success marker found (pattern: $success_re). Recent tail:"
        printf '%s\n' "$out" | tail -n 30 >&2
        return 1
    fi

    # Fatal after success => FAIL (setup looked done, but then errors happened later)
    if [ "$last_fatal" -gt "$last_success" ]; then
        log_warn "btfwloaded: fatal BT/QCA errors occurred after final setup marker; treating as FAIL."
        printf '%s\n' "$out" | tail -n 40 >&2
        return 1
    fi

    # Fatal before success OR transient hints => WARN (retry scenario)
    if [ "$last_fatal" -gt 0 ] && [ "$last_fatal" -lt "$last_success" ]; then
        log_warn "btfwloaded: transient errors occurred before final setup marker; treating as WARN."
        printf '%s\n' "$out" | tail -n 30 >&2
        return 2
    fi

    if [ "$saw_transient" -eq 1 ]; then
        log_warn "btfwloaded: retry/transient indicators seen; final setup marker present; treating as WARN."
        printf '%s\n' "$out" | tail -n 30 >&2
        return 2
    fi

    log_info "btfwloaded: firmware load/setup completed cleanly (no fatal errors after final setup marker)."
    return 0
}

btkmdpresent() {
    present=0
    for m in bluetooth hci_uart btqca; do
        if [ -d "/sys/module/$m" ]; then present=1; break; fi
    done
    if [ $present -eq 1 ]; then return 0; fi
    if dmesg 2>/dev/null | grep -qi 'HCI UART protocol QCA registered'; then
        return 0
    fi
    return 1
}

btsvcactive() {
    if hascmd systemctl; then
        if systemctl is-active bluetooth.service >/dev/null 2>&1; then return 0; fi
    fi
    if pgrep bluetoothd >/dev/null 2>&1; then return 0; fi
    return 1
}

bthcipresent() {
    findhcisysfs >/dev/null 2>&1 && return 0
    return 1
}

btbdok() {
    dev="${1-}"
    hascmd hciconfig || return 2
    addr="$(hciconfig -a "$dev" 2>/dev/null | awk '/BD Address:/ {print $3; exit}')"
    [ -n "$addr" ] || return 2
    case "$addr" in
        00:00:00:00:00:00) return 1 ;;
        *) return 0 ;;
    esac
}

# Robust polling after scan ON:
#   - Waits up to max_wait_secs for:
#       * Discovering=yes at least once (informational)
#       * Either TARGET_MAC (if non-empty) or any devices in `bluetoothctl devices`
#   - Logs intermediate Discovering states and final devices snapshot.
# Usage:
#   bt_scan_poll_on ""          # just check that some devices appear (default 20s)
#   bt_scan_poll_on AA:BB:..    # look for specific MAC
#   bt_scan_poll_on "$mac" 30 1 # custom max_wait + step
# Returns:
#   0 = success (target found OR at least one device discovered)
#   1 = failure (no devices / no target within polling window)
bt_scan_poll_on() {
    target_mac="${1:-}"
    max_wait_secs="${2:-20}"
    step_secs="${3:-2}"

    # Ensure sane values
    if [ "$max_wait_secs" -le 0 ] 2>/dev/null; then
        max_wait_secs=20
    fi
    if [ "$step_secs" -le 0 ] 2>/dev/null; then
        step_secs=2
    fi

    attempts=$((max_wait_secs / step_secs))
    [ "$attempts" -lt 1 ] && attempts=1

    seen_disc_yes=0
    seen_devices=0
    seen_target=0
    devices_snapshot=""

    i=0
    while [ "$i" -lt "$attempts" ]; do
        disc_state="$(bt_is_discovering 2>/dev/null || printf '%s\n' "unknown")"
        log_info "Discovering state during scan ON (iteration $((i + 1))/$attempts): $disc_state"

        if [ "$disc_state" = "yes" ]; then
            seen_disc_yes=1
        fi

        devices_out="$(
            bluetoothctl devices 2>/dev/null | sanitize_bt_output || true
        )"
        devices_snapshot="$devices_out"

        if [ -n "$target_mac" ]; then
            if printf '%s\n' "$devices_out" | grep -qi "$target_mac"; then
                seen_target=1
                seen_devices=1
                log_info "Target MAC $target_mac visible in devices (iteration $((i + 1)))."
                break
            fi
        else
            if [ -n "$devices_out" ]; then
                seen_devices=1
                log_info "At least one device visible in devices (iteration $((i + 1)))."
                break
            fi
        fi

        i=$((i + 1))
        sleep "$step_secs"
    done

    log_info "Devices seen by bluetoothctl (if any) after scan ON polling:"
    if [ -n "$devices_snapshot" ]; then
        printf '%s\n' "$devices_snapshot"
    else
        log_info "(no entries in 'bluetoothctl devices')"
    fi

    if [ "$seen_disc_yes" -eq 0 ]; then
        log_warn "Never observed Discovering=yes during scan ON polling (may indicate stack issue)."
    fi

    # Decide result, but leave PASS/FAIL wording to run.sh
    if [ -n "$target_mac" ]; then
        [ "$seen_target" -eq 1 ] && return 0
        return 1
    fi

    [ "$seen_devices" -eq 1 ] && return 0
    return 1
}

# Robust polling after scan OFF:
#   - Waits up to max_wait_secs for Discovering=no
# Usage:
#   bt_scan_poll_off           # default ~10s
#   bt_scan_poll_off 15 1      # custom max_wait + step
# Returns:
#   0 = observed Discovering=no
#   1 = did not settle to 'no' within polling window
bt_scan_poll_off() {
    max_wait_secs="${1:-10}"
    step_secs="${2:-1}"

    if [ "$max_wait_secs" -le 0 ] 2>/dev/null; then
        max_wait_secs=10
    fi
    if [ "$step_secs" -le 0 ] 2>/dev/null; then
        step_secs=1
    fi

    attempts=$((max_wait_secs / step_secs))
    [ "$attempts" -lt 1 ] && attempts=1

    i=0
    while [ "$i" -lt "$attempts" ]; do
        disc_state="$(bt_is_discovering 2>/dev/null || printf '%s\n' "unknown")"
        log_info "Discovering state during scan OFF (iteration $((i + 1))/$attempts): $disc_state"

        if [ "$disc_state" = "no" ]; then
            return 0
        fi

        i=$((i + 1))
        sleep "$step_secs"
    done

    log_warn "Discovering did not settle to 'no' within scan OFF polling window."
    return 1
}
