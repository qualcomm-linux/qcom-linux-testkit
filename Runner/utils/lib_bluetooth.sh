#!/bin/sh
# lib_bluetooth.sh - Bluetooth-specific helpers split out from functestlib.sh
# Copyright (c) Qualcomm Technologies, Inc.
# SPDX-License-Identifier: BSD-3-Clause#
# This file is meant to be sourced *after* init_env and functestlib.sh:
# . "$TOOLS/functestlib.sh"
# . "$TOOLS/lib_bluetooth.sh"

# Read one value from /etc/os-release.
bt_os_release_value() {
    bt_orv_key="$1"

    [ -n "$bt_orv_key" ] || return 1
    [ -r /etc/os-release ] || return 1

    sed -n "s/^${bt_orv_key}=//p" /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//'
}

# Detect Ubuntu Server or Desktop.
# Override with BT_UBUNTU_VARIANT=server|desktop.
bt_detect_ubuntu_variant() {
    bt_duv_override="${BT_UBUNTU_VARIANT:-auto}"

    case "$bt_duv_override" in
        server|desktop)
            printf '%s\n' "$bt_duv_override"
            return 0
            ;;
        auto|"")
            ;;
        *)
            log_warn "Invalid BT_UBUNTU_VARIANT=$bt_duv_override; using auto detection" >&2
            ;;
    esac

    bt_duv_variant_id="$(
        bt_os_release_value VARIANT_ID 2>/dev/null |
            tr '[:upper:]' '[:lower:]'
    )"

    case "$bt_duv_variant_id" in
        *desktop*)
            printf '%s\n' "desktop"
            return 0
            ;;
        *server*|minimal|core)
            printf '%s\n' "server"
            return 0
            ;;
    esac

    if command -v dpkg-query >/dev/null 2>&1; then
        for bt_duv_pkg in \
            ubuntu-desktop \
            ubuntu-desktop-minimal \
            ubuntu-desktop-raspi
        do
            if dpkg-query -W -f='${Status}\n' "$bt_duv_pkg" 2>/dev/null |
                grep -q '^install ok installed$'; then
                printf '%s\n' "desktop"
                return 0
            fi
        done

        if dpkg-query -W -f='${Status}\n' ubuntu-server 2>/dev/null |
            grep -q '^install ok installed$'; then
            printf '%s\n' "server"
            return 0
        fi
    fi

    if [ -s /etc/X11/default-display-manager ]; then
        printf '%s\n' "desktop"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 &&
       systemctl is-active --quiet display-manager.service 2>/dev/null; then
        printf '%s\n' "desktop"
        return 0
    fi

    # Qualcomm Ubuntu Server images may not install the ubuntu-server
    # meta-package. An Ubuntu image without desktop evidence is Server.
    printf '%s\n' "server"
    return 0
}

# Run systemctl --user for the prepared Ubuntu Bluetooth user.
bt_ubuntu_user_systemctl() {
    if [ -z "${BT_UBUNTU_USER:-}" ] ||
       [ -z "${BT_UBUNTU_USER_UID:-}" ] ||
       [ -z "${BT_UBUNTU_RUNTIME_DIR:-}" ]; then
        log_fail "Ubuntu Bluetooth user manager has not been prepared"
        return 1
    fi

    if [ "$(id -u 2>/dev/null || echo 1)" = "$BT_UBUNTU_USER_UID" ]; then
        env \
            HOME="$BT_UBUNTU_USER_HOME" \
            USER="$BT_UBUNTU_USER" \
            LOGNAME="$BT_UBUNTU_USER" \
            XDG_RUNTIME_DIR="$BT_UBUNTU_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="$BT_UBUNTU_DBUS_ADDRESS" \
            systemctl --user "$@"
        return $?
    fi

    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$BT_UBUNTU_USER" -- \
            env \
                HOME="$BT_UBUNTU_USER_HOME" \
                USER="$BT_UBUNTU_USER" \
                LOGNAME="$BT_UBUNTU_USER" \
                XDG_RUNTIME_DIR="$BT_UBUNTU_RUNTIME_DIR" \
                DBUS_SESSION_BUS_ADDRESS="$BT_UBUNTU_DBUS_ADDRESS" \
                systemctl --user "$@"
        return $?
    fi

    log_fail "runuser is unavailable; cannot control $BT_UBUNTU_USER user services"
    return 1
}

# Ensure the Debian-family Bluetooth control tools required by the shared
# power and scan helpers are installed before a suite starts.
bt_prepare_debian_bluetooth_tools() {
    bt_pdbt_os_id="$1"

    case "$bt_pdbt_os_id" in
        debian|ubuntu)
            ;;
        *)
            return 0
            ;;
    esac

    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        log_fail "Debian-family Bluetooth tool preparation must run as root"
        return 1
    fi

    if ! command -v pkg_ensure_command >/dev/null 2>&1 &&
       [ -n "${TOOLS:-}" ] &&
       [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
        # shellcheck disable=SC1090,SC1091
        . "$TOOLS/lib_pkg_provider.sh"
    fi

    if ! command -v pkg_ensure_command >/dev/null 2>&1; then
        log_fail "Bluetooth command package helper is unavailable"
        return 1
    fi

    # rfkill is used for bounded controller recovery. expect provides the PTY
    # needed for the same bluetoothctl interaction as a manual session.
    for bt_pdbt_command in rfkill expect; do
        if ! pkg_ensure_command "$bt_pdbt_command"; then
            log_fail "Failed to prepare required Bluetooth command: $bt_pdbt_command"
            return 1
        fi
    done

    return 0
}

# Prepare the Ubuntu Bluetooth stack used by all current BT tests.
# Debian receives the shared control-tool preparation and no Ubuntu-specific
# service or desktop changes. Yocto and other distributions return unchanged.
bt_prepare_ubuntu_stack() {
    if command -v pkg_detect_os_id >/dev/null 2>&1; then
        bt_pus_os_id="$(pkg_detect_os_id 2>/dev/null || echo unknown)"
    else
        bt_pus_os_id="$(
            bt_os_release_value ID 2>/dev/null |
                tr '[:upper:]' '[:lower:]'
        )"
    fi

    if ! bt_prepare_debian_bluetooth_tools "$bt_pus_os_id"; then
        return 1
    fi

    if [ "$bt_pus_os_id" != "ubuntu" ]; then
        return 0
    fi

    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        log_fail "Ubuntu Bluetooth stack preparation must run as root"
        return 1
    fi

    bt_pus_variant="$(bt_detect_ubuntu_variant)"

    case "$bt_pus_variant" in
        server|desktop)
            ;;
        *)
            log_fail "Unable to determine Ubuntu Bluetooth variant"
            return 1
            ;;
    esac

    log_info "Ubuntu Bluetooth stack preparation: variant=$bt_pus_variant"

    BT_UBUNTU_WIREPLUMBER_CONFIG_CHANGED=0
    export BT_UBUNTU_WIREPLUMBER_CONFIG_CHANGED

    if [ "$bt_pus_variant" = "server" ]; then
        if ! command -v pkg_ensure_package_set >/dev/null 2>&1; then
            if [ -n "${TOOLS:-}" ] &&
               [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
                # shellcheck disable=SC1090,SC1091
                . "$TOOLS/lib_pkg_provider.sh"
            fi
        fi

        if ! command -v pkg_ensure_package_set >/dev/null 2>&1; then
            log_fail "Bluetooth package-set helper is unavailable"
            return 1
        fi

        if command -v pkg_ensure_required_package_set_present \
            >/dev/null 2>&1; then
            if ! pkg_ensure_required_package_set_present bluetooth; then
                log_fail "Failed to prepare Ubuntu Server Bluetooth packages"
                return 1
            fi
        elif ! pkg_ensure_package_set bluetooth; then
            log_fail "Failed to prepare Ubuntu Server Bluetooth packages"
            return 1
        fi

        bt_pus_wp_target="${BT_WIREPLUMBER_BLUETOOTH_CONF:-/usr/share/wireplumber/wireplumber.conf.d/50-bluetooth.conf}"
        bt_pus_wp_dir="$(dirname "$bt_pus_wp_target")"
        bt_pus_wp_tmp="${bt_pus_wp_target}.tmp.$$"

        if ! mkdir -p "$bt_pus_wp_dir"; then
            log_fail "Failed to create WirePlumber config directory: $bt_pus_wp_dir"
            return 1
        fi

        cat >"$bt_pus_wp_tmp" <<'CONFIG_EOF'
wireplumber.profiles = {
  main = {
    monitor.bluez = required
    monitor.bluez-midi = optional
    monitor.bluez.seat-monitoring = disabled
  }
}
CONFIG_EOF

        if [ -r "$bt_pus_wp_target" ] &&
           cmp -s "$bt_pus_wp_tmp" "$bt_pus_wp_target"; then
            rm -f "$bt_pus_wp_tmp"
            log_pass "WirePlumber Bluetooth configuration is already present"
        else
            if ! chmod 0644 "$bt_pus_wp_tmp" ||
               ! mv "$bt_pus_wp_tmp" "$bt_pus_wp_target"; then
                rm -f "$bt_pus_wp_tmp"
                log_fail "Failed to install WirePlumber Bluetooth configuration"
                return 1
            fi

            BT_UBUNTU_WIREPLUMBER_CONFIG_CHANGED=1
            export BT_UBUNTU_WIREPLUMBER_CONFIG_CHANGED

            log_pass "Installed WirePlumber Bluetooth configuration: $bt_pus_wp_target"
        fi
    else
        log_info "Ubuntu Desktop detected; package installation is not required"
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log_fail "systemctl is required for Ubuntu Bluetooth validation"
        return 1
    fi

    if ! systemctl start bluetooth.service >/dev/null 2>&1; then
        log_fail "Failed to start bluetooth.service"
        systemctl status bluetooth.service --no-pager 2>/dev/null || true
        return 1
    fi

    bt_pus_wait=0
    while [ "$bt_pus_wait" -lt 20 ]; do
        if systemctl is-active --quiet bluetooth.service; then
            break
        fi

        sleep 1
        bt_pus_wait=$((bt_pus_wait + 1))
    done

    if ! systemctl is-active --quiet bluetooth.service; then
        log_fail "bluetooth.service is not active"
        systemctl status bluetooth.service --no-pager 2>/dev/null || true
        return 1
    fi

    log_pass "bluetooth.service is active"

    BT_UBUNTU_USER="${BT_UBUNTU_USER:-qcom}"

    if ! id "$BT_UBUNTU_USER" >/dev/null 2>&1; then
        log_fail "Ubuntu Bluetooth test user does not exist: $BT_UBUNTU_USER"
        return 1
    fi

    BT_UBUNTU_USER_UID="$(id -u "$BT_UBUNTU_USER" 2>/dev/null || true)"
    BT_UBUNTU_USER_HOME="$(
        getent passwd "$BT_UBUNTU_USER" 2>/dev/null |
            awk -F: 'NR == 1 { print $6 }'
    )"
    [ -n "$BT_UBUNTU_USER_HOME" ] ||
        BT_UBUNTU_USER_HOME="/home/$BT_UBUNTU_USER"

    BT_UBUNTU_RUNTIME_DIR="/run/user/$BT_UBUNTU_USER_UID"
    BT_UBUNTU_DBUS_ADDRESS="unix:path=$BT_UBUNTU_RUNTIME_DIR/bus"

    export \
        BT_UBUNTU_USER \
        BT_UBUNTU_USER_UID \
        BT_UBUNTU_USER_HOME \
        BT_UBUNTU_RUNTIME_DIR \
        BT_UBUNTU_DBUS_ADDRESS

    if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$BT_UBUNTU_USER" >/dev/null 2>&1 || true
    fi

    systemctl start "user@${BT_UBUNTU_USER_UID}.service" >/dev/null 2>&1 || true

    bt_pus_wait=0
    while [ "$bt_pus_wait" -lt 15 ]; do
        if [ -S "$BT_UBUNTU_RUNTIME_DIR/bus" ]; then
            break
        fi

        sleep 1
        bt_pus_wait=$((bt_pus_wait + 1))
    done

    if [ ! -S "$BT_UBUNTU_RUNTIME_DIR/bus" ]; then
        log_fail "Ubuntu Bluetooth user bus is unavailable: $BT_UBUNTU_RUNTIME_DIR/bus"
        return 1
    fi

    log_pass "Ubuntu Bluetooth user manager is ready: user=$BT_UBUNTU_USER uid=$BT_UBUNTU_USER_UID"

    bt_pus_restart_user_services=0

    if [ "$BT_UBUNTU_WIREPLUMBER_CONFIG_CHANGED" -eq 1 ]; then
        bt_pus_restart_user_services=1
    fi

    if ! bt_ubuntu_user_systemctl \
        is-active --quiet pipewire.service wireplumber.service; then
        bt_pus_restart_user_services=1
    fi

    if [ "$bt_pus_restart_user_services" -eq 1 ]; then
        log_info "Restarting PipeWire and WirePlumber for user=$BT_UBUNTU_USER"

        if ! bt_ubuntu_user_systemctl \
            restart pipewire.service wireplumber.service; then
            log_fail "Failed to restart Ubuntu Bluetooth user services"
            return 1
        fi
    fi

    bt_pus_wait=0
    while [ "$bt_pus_wait" -lt 20 ]; do
        if bt_ubuntu_user_systemctl \
            is-active --quiet pipewire.service wireplumber.service; then
            break
        fi

        sleep 1
        bt_pus_wait=$((bt_pus_wait + 1))
    done

    if ! bt_ubuntu_user_systemctl \
        is-active --quiet pipewire.service wireplumber.service; then
        log_fail "PipeWire and WirePlumber user services are not ready"
        return 1
    fi

    log_pass "PipeWire and WirePlumber user services are active"

    if [ ! -d /sys/module/bluetooth ] &&
       ! grep -q '^bluetooth[[:space:]]' /proc/modules 2>/dev/null; then
        if command -v modprobe >/dev/null 2>&1; then
            log_info "Bluetooth kernel core is not active; attempting modprobe bluetooth"
            modprobe bluetooth >/dev/null 2>&1 || true
        fi
    fi

    if [ ! -d /sys/module/bluetooth ] &&
       ! grep -q '^bluetooth[[:space:]]' /proc/modules 2>/dev/null; then
        log_fail "Bluetooth kernel core is not present"
        return 1
    fi

    log_pass "Bluetooth kernel core is present"
    log_pass "Ubuntu Bluetooth stack is ready: variant=$bt_pus_variant"
    return 0
}

# Prepare distribution-specific Bluetooth packages and services.
# Ubuntu and Debian retain the existing preparation behavior. CentOS ensures
# the minimal BlueZ and Qualcomm/Atheros firmware package set is present.
# Yocto and other image-managed distributions return unchanged.
bt_prepare_bluetooth_stack() {
    if command -v pkg_detect_os_id >/dev/null 2>&1; then
        bt_pbs_os_id="$(pkg_detect_os_id 2>/dev/null || echo unknown)"
    else
        bt_pbs_os_id="$(
            bt_os_release_value ID 2>/dev/null |
                tr '[:upper:]' '[:lower:]'
        )"
    fi

    if [ "$bt_pbs_os_id" != "centos" ]; then
        bt_prepare_ubuntu_stack
        return $?
    fi

    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        log_fail "CentOS Bluetooth stack preparation must run as root"
        return 1
    fi

    if ! command -v pkg_ensure_required_package_set_present \
        >/dev/null 2>&1; then
        if [ -n "${TOOLS:-}" ] &&
           [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
            # shellcheck disable=SC1090,SC1091
            . "$TOOLS/lib_pkg_provider.sh"
        fi
    fi

    if ! command -v pkg_ensure_required_package_set_present \
        >/dev/null 2>&1; then
        log_fail "Bluetooth package-set helper is unavailable"
        return 1
    fi

    log_info "CentOS Bluetooth stack preparation: ensuring BlueZ, firmware, and expect packages"

    bt_pbs_firmware_present_before=0
    if command -v pkg_have_package >/dev/null 2>&1 &&
       pkg_have_package atheros-firmware; then
        bt_pbs_firmware_present_before=1
    fi

    if ! pkg_ensure_required_package_set_present bluetooth; then
        log_fail "Failed to prepare CentOS Bluetooth packages"
        return 1
    fi

    if [ "$bt_pbs_firmware_present_before" -eq 0 ]; then
        log_warn "atheros-firmware was newly provisioned, reboot the target if the active HCI controller still reports an all-zero BD address"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl start bluetooth.service >/dev/null 2>&1; then
            log_fail "Failed to start bluetooth.service on CentOS"
            systemctl status bluetooth.service --no-pager 2>/dev/null || true
            return 1
        fi

        if ! systemctl is-active --quiet bluetooth.service; then
            log_fail "bluetooth.service is not active on CentOS"
            systemctl status bluetooth.service --no-pager 2>/dev/null || true
            return 1
        fi

        log_pass "bluetooth.service is active"
    fi

    log_pass "CentOS Bluetooth stack packages are ready"
    return 0
}

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
    out="$(bluetoothctl list 2>/dev/null | sanitize_bt_output || true)"

    if ! printf '%s\n' "$out" | grep -qi '^[[:space:]]*Controller[[:space:]]'; then
        # mark fallback (so btctl_script logs the interactive mode message once)
        BTCTLINTERACTIVEFALLBACK=1
        out="$(btctl_script "list" "quit" | sanitize_bt_output || true)"
    fi

    printf '%s\n' "$out" | awk '
        tolower($1) == "controller" { print $2; exit }
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
 
    # Prefer sysfs discovery because current BlueZ distributions may omit the
    # deprecated hciconfig utility.
    if [ -z "${adapter}" ]; then
        adapter="$(listhcis 2>/dev/null | sed -n '1p')"
    fi
    adapter="${adapter%:}"
 
    if [ -z "${adapter}" ]; then
        log_error "No Bluetooth adapter found"
        return 1
    fi
 
    log_info "Using Bluetooth adapter: ${adapter}"
    if command -v hciconfig >/dev/null 2>&1; then
        hciconfig "${adapter}" up 2>/dev/null || true
    fi
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

# Fallback scan path using one interactive bluetoothctl session.
#
# This is used when the normal non-interactive scan path completes but no
# devices are parsed. Some BlueZ/minimal images do not reliably emit discovery
# events through repeated non-interactive bluetoothctl invocations, while an
# interactive session behaves like the manual flow:
#
#   bluetoothctl
#   select <adapter>
#   power on
#   scan on
#   scan off
#   devices
#
# Args:
#   $1 = adapter, for example hci1
#   $2 = scan window in seconds
#   $3 = optional target MAC in uppercase
#
# Returns:
#   0 = at least one device seen, or target MAC seen when provided
#   1 = no matching device found
bt_scan_devices_interactive_fallback() {
    adapter="$1"
    scan_window="${2:-10}"
    mac_id_up="${3:-}"
 
    case "$scan_window" in
        ""|*[!0-9]*)
            scan_window=10
            ;;
    esac
 
    if [ "$scan_window" -le 0 ] 2>/dev/null; then
        scan_window=10
    fi
 
    total_timeout=$((scan_window + 15))
 
    log_warn "bt_scan_devices: trying interactive bluetoothctl fallback on $adapter for ${scan_window}s"
 
    if command -v run_with_timeout >/dev/null 2>&1; then
        fallback_out="$(
            {
                printf 'select %s\n' "$adapter"
                sleep 1
                printf 'power on\n'
                sleep 1
                printf 'scan on\n'
                sleep "$scan_window"
                printf 'scan off\n'
                sleep 1
                printf 'devices\n'
                sleep 1
                printf 'quit\n'
            } | run_with_timeout "$total_timeout" bluetoothctl 2>&1 | sanitize_bt_output || true
        )"
    else
        fallback_out="$(
            {
                printf 'select %s\n' "$adapter"
                sleep 1
                printf 'power on\n'
                sleep 1
                printf 'scan on\n'
                sleep "$scan_window"
                printf 'scan off\n'
                sleep 1
                printf 'devices\n'
                sleep 1
                printf 'quit\n'
            } | bluetoothctl 2>&1 | sanitize_bt_output || true
        )"
    fi
 
    cache_out="$(
        bt_list_devices_raw 2>/dev/null \
            | sanitize_bt_output || true
    )"
 
    found_lines="$(
        {
            printf '%s\n' "$fallback_out"
            printf '%s\n' "$cache_out"
        } | awk '
            function is_hex_pair(s) {
                return s ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/
            }
 
            function is_mac(m, a,n,i) {
                n = split(m, a, ":")
                if (n != 6) {
                    return 0
                }
 
                for (i = 1; i <= 6; i++) {
                    if (!is_hex_pair(a[i])) {
                        return 0
                    }
                }
 
                return 1
            }
 
            function is_property_token(s) {
                return s ~ /^(RSSI|UUIDs:|TxPower|ManufacturerData|ManufacturerData\.|Paired|Connected|Advertising|Flags:|ServiceData|Alias:|Class:|Icon:|Modalias:|Services)/
            }
 
            function emit_device(mac, name) {
                mac = toupper(mac)
 
                if (name == "") {
                    name = "<unknown>"
                }
 
                if (!(mac in seen)) {
                    seen[mac] = name
                    order[++count] = mac
                } else if (seen[mac] == "<unknown>" && name != "<unknown>") {
                    seen[mac] = name
                }
            }
 
            {
                mac = ""
                start = 0
 
                if ($1 == "[NEW]" && $2 == "Device" && is_mac($3)) {
                    mac = $3
                    start = 4
                } else if ($1 == "Device" && is_mac($2)) {
                    mac = $2
                    start = 3
                } else {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "Device" && (i + 1) <= NF && is_mac($(i + 1))) {
                            mac = $(i + 1)
                            start = i + 2
                            break
                        }
                    }
                }
 
                if (mac == "") {
                    next
                }
 
                name = ""
                for (i = start; i <= NF; i++) {
                    if (is_property_token($i)) {
                        break
                    }
 
                    if ($i == "") {
                        continue
                    }
 
                    name = name (name == "" ? "" : " ") $i
                }
 
                sub(/[[:space:]]+$/, "", name)
 
                if (name ~ /^[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]$/) {
                    name = "<unknown>"
                }
 
                emit_device(mac, name)
            }
 
            END {
                for (i = 1; i <= count; i++) {
                    mac = order[i]
                    print mac, seen[mac]
                }
            }
        '
    )"
 
    if [ -z "$found_lines" ]; then
        log_warn "bt_scan_devices: interactive fallback parsed no devices"
        log_info "bt_scan_devices: interactive fallback output tail:"
        printf '%s\n' "$fallback_out" | tail -n 20 | while IFS= read -r line; do
            [ -n "$line" ] && log_info " [fallback] $line"
        done
        return 1
    fi
 
    log_info "bt_scan_devices: devices seen during interactive fallback"
    printf '%s\n' "$found_lines" | while IFS= read -r line; do
        [ -n "$line" ] && log_info " $line"
    done
 
    if [ -n "${SCAN_RESULT:-}" ]; then
        printf '%s\n' "$found_lines" > "$SCAN_RESULT"
    fi
 
    if [ -n "$mac_id_up" ]; then
        match_line="$(
            printf '%s\n' "$found_lines" \
                | awk -v target="$mac_id_up" '
                    toupper($1) == target {
                        print
                        found = 1
                        exit
                    }
 
                    END {
                        if (found != 1) {
                            exit 1
                        }
                    }
                '
        )"
 
        if [ -n "$match_line" ]; then
            return 0
        fi
 
        log_warn "bt_scan_devices: target MAC not seen during interactive fallback: $mac_id_up"
        return 1
    fi
 
    return 0
}

# Scan for nearby BT devices using bluetoothctl.
#
# Env:
# BT_ADAPTER : adapter, for example hci0; auto-detected if unset
# SCAN_SECONDS : scan window per attempt, default 10
# SCAN_ATTEMPTS : scan attempts, default 3
# SCAN_RETRY_DELAY : delay between attempts, default 2
# MAC_ID : optional AA:BB:CC:DD:EE:FF; if set, succeed only if seen
# SCAN_RESULT : optional file to store parsed scan result lines
#
# Usage:
# bt_scan_devices # generic scan, succeeds if any valid MAC is seen
# bt_scan_devices AA:..:FF # target scan, succeeds only if target MAC is seen
#
# Output:
# MAC NAME
#
# Return:
# 0 on success
# 1 on failure
#
# Notes:
# - Reuses existing helper name; do not add a parallel scan helper.
# - Parses live bluetoothctl scan output and cached bluetoothctl devices output.
# - Accepts MAC-only discovery because name resolution can be delayed.
# - Keeps positional MAC support for existing callers.
# shellcheck disable=SC2120
bt_scan_devices() {
    adapter="${BT_ADAPTER:-}"
    scan_window="${SCAN_SECONDS:-10}"
    scan_attempts="${SCAN_ATTEMPTS:-3}"
    scan_retry_delay="${SCAN_RETRY_DELAY:-2}"
    mac_id="${MAC_ID:-}"

    if [ -z "$mac_id" ] && [ -n "${1:-}" ]; then
        mac_id="$1"
    fi

    case "$scan_window" in
        ""|*[!0-9]*)
            scan_window=10
            ;;
    esac

    case "$scan_attempts" in
        ""|*[!0-9]*)
            scan_attempts=3
            ;;
    esac

    case "$scan_retry_delay" in
        ""|*[!0-9]*)
            scan_retry_delay=2
            ;;
    esac

    if [ "$scan_window" -le 0 ] 2>/dev/null; then
        scan_window=10
    fi

    if [ "$scan_attempts" -le 0 ] 2>/dev/null; then
        scan_attempts=3
    fi

    if [ "$scan_retry_delay" -lt 0 ] 2>/dev/null; then
        scan_retry_delay=2
    fi

    if [ -z "$adapter" ] && command -v findhcisysfs >/dev/null 2>&1; then
        adapter="$(findhcisysfs 2>/dev/null || true)"
    fi

    if [ -z "$adapter" ] && command -v hciconfig >/dev/null 2>&1; then
        adapter="$(
            hciconfig 2>/dev/null \
                | awk '/^hci[0-9]+:/ { print $1; exit }'
        )"
    fi

    adapter="${adapter%:}"

    if [ -z "$adapter" ]; then
        log_error "bt_scan_devices: No Bluetooth adapter found"
        return 1
    fi

    mac_id_up=""
    if [ -n "$mac_id" ]; then
        mac_id_up="$(printf '%s\n' "$mac_id" | tr '[:lower:]' '[:upper:]')"
    fi

    log_info "bt_scan_devices: using adapter $adapter"
    log_info "bt_scan_devices: scan_window=${scan_window}s attempts=${scan_attempts} retry_delay=${scan_retry_delay}s"

    if command -v btpower >/dev/null 2>&1; then
        if ! btpower "$adapter" on; then
            log_warn "bt_scan_devices: btpower($adapter on) did not report success; continuing"
        fi
    else
        run_with_timeout 3 bluetoothctl power on >/dev/null 2>&1 || true
    fi

    run_with_timeout 3 bluetoothctl select "$adapter" >/dev/null 2>&1 || true

    attempt=1
    found_lines=""

    while [ "$attempt" -le "$scan_attempts" ]; do
        log_info "bt_scan_devices: scan attempt ${attempt}/${scan_attempts}"

        live_out="$(
            {
                run_with_timeout 3 bluetoothctl select "$adapter" 2>/dev/null || true
                run_with_timeout 3 bluetoothctl power on 2>/dev/null || true
                run_with_timeout "$((scan_window + 5))" \
                    bluetoothctl --timeout "$scan_window" scan on 2>&1 || true
            } | sanitize_bt_output
        )"

        if command -v bt_set_scan >/dev/null 2>&1; then
            if ! bt_set_scan off "$adapter"; then
                log_warn "bt_scan_devices: bt_set_scan(off) reported failure after attempt $attempt"
            fi
        else
            run_with_timeout 5 bluetoothctl scan off >/dev/null 2>&1 || true
        fi

        if command -v bt_list_devices_raw >/dev/null 2>&1; then
            cache_out="$(
                bt_list_devices_raw 2>/dev/null \
                    | sanitize_bt_output || true
            )"
        else
            cache_out="$(
                bluetoothctl devices 2>/dev/null \
                    | sanitize_bt_output || true
            )"
        fi

        found_lines="$(
            {
                printf '%s\n' "$live_out"
                printf '%s\n' "$cache_out"
            } | awk '
                function is_hex_pair(s) {
                    return s ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/
                }

                function is_mac(m, a,n,i) {
                    n = split(m, a, ":")
                    if (n != 6) {
                        return 0
                    }

                    for (i = 1; i <= 6; i++) {
                        if (!is_hex_pair(a[i])) {
                            return 0
                        }
                    }

                    return 1
                }

                function is_property_token(s) {
                    return s ~ /^(RSSI|UUIDs:|TxPower|ManufacturerData|ManufacturerData\.|Paired|Connected|Advertising|Flags:|ServiceData|Alias:|Class:|Icon:|Modalias:|Services)/
                }

                function emit_device(mac, name) {
                    mac = toupper(mac)

                    if (name == "") {
                        name = "<unknown>"
                    }

                    if (!(mac in seen)) {
                        seen[mac] = name
                        order[++count] = mac
                    } else if (seen[mac] == "<unknown>" && name != "<unknown>") {
                        seen[mac] = name
                    }
                }

                {
                    mac = ""
                    start = 0

                    for (i = 1; i <= NF; i++) {
                        if ($i == "Device" && (i + 1) <= NF && is_mac($(i + 1))) {
                            mac = $(i + 1)
                            start = i + 2
                            break
                        }
                    }

                    if (mac == "") {
                        next
                    }

                    name = ""
                    for (i = start; i <= NF; i++) {
                        if (is_property_token($i)) {
                            break
                        }

                        if ($i == "") {
                            continue
                        }

                        name = name (name == "" ? "" : " ") $i
                    }

                    sub(/[[:space:]]+$/, "", name)

                    if (name ~ /^[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]$/) {
                        name = "<unknown>"
                    }

                    emit_device(mac, name)
                }

                END {
                    for (i = 1; i <= count; i++) {
                        mac = order[i]
                        print mac, seen[mac]
                    }
                }
            '
        )"

        if [ -n "$found_lines" ]; then
            log_info "bt_scan_devices: devices seen during attempt $attempt"
            printf '%s\n' "$found_lines" | while IFS= read -r line; do
                if [ -n "$line" ]; then
                    log_info " $line"
                fi
            done

            if [ -n "${SCAN_RESULT:-}" ]; then
                printf '%s\n' "$found_lines" > "$SCAN_RESULT"
            fi

            if [ -n "$mac_id_up" ]; then
                match_line="$(
                    printf '%s\n' "$found_lines" \
                        | awk -v target="$mac_id_up" '
                            toupper($1) == target {
                                print
                                found = 1
                                exit
                            }

                            END {
                                if (found != 1) {
                                    exit 1
                                }
                            }
                        '
                )"

                if [ -n "$match_line" ]; then
                    return 0
                fi

                log_warn "bt_scan_devices: target MAC not seen in attempt $attempt: $mac_id"
            else
                return 0
            fi
        else
            log_warn "bt_scan_devices: no devices parsed in attempt $attempt"
        fi

        attempt=$((attempt + 1))

        if [ "$attempt" -le "$scan_attempts" ]; then
            sleep "$scan_retry_delay"
        fi
    done

    if [ "${BT_SCAN_INTERACTIVE_FALLBACK:-1}" = "1" ] && \
       command -v expect >/dev/null 2>&1; then
        log_warn "bt_scan_devices: trying expect PTY fallback"
        if bt_scan_devices_expect "$mac_id"; then
            return 0
        fi
    fi

    if [ "${BT_SCAN_INTERACTIVE_FALLBACK:-1}" = "1" ]; then
        if bt_scan_devices_interactive_fallback "$adapter" "$scan_window" "$mac_id_up"; then
            return 0
        fi
    else
        log_info "bt_scan_devices: interactive fallback disabled by BT_SCAN_INTERACTIVE_FALLBACK=0"
    fi

    if [ -n "$mac_id" ]; then
        log_warn "bt_scan_devices: MAC_ID not found after ${scan_attempts} attempts: $mac_id"
    else
        log_warn "bt_scan_devices: no devices found after ${scan_attempts} attempts"
    fi

    return 1
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
    #tr -d '\r' 2>/dev/null || true
    tr -d '\r' \
    | sed 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g' \
    | tr -cd '\11\12\15\40-\176'
}

# ret: 0=controller visible in *non-interactive* "bluetoothctl list", 1=none
btcontrollerpresentplain() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 2 bluetoothctl list 2>/dev/null \
            | sanitize_bt_output \
            | grep -qi '^[[:space:]]*Controller[[:space:]]'
        return $?
    fi

    bluetoothctl list 2>/dev/null \
        | sanitize_bt_output \
        | grep -qi '^[[:space:]]*Controller[[:space:]]'
}

# Log useful Bluetooth diagnostics.
#
# Usage:
# btloghcidiag [adapter] [mode] [test_path]
#
# Modes:
# basic - lightweight diagnostics for controller visibility warnings
# failure - full diagnostics for real BT test failures
#
# test_path:
# Optional path passed to scan_dmesg_errors when mode=failure.
btloghcidiag() {
    adapter="${1:-}"
    diag_mode="${2:-basic}"
    diag_test_path="${3:-}"
    bt_dmesg_modules="bluetooth|hci0|qca|wcn|btqca|hci_uart|serdev|rfkill|firmware|timeout"

    log_warn "Bluetooth diagnostics: controller visibility/state is inconsistent"

    if [ -n "$adapter" ]; then
        log_warn "Adapter: $adapter"
    fi

    if command -v hciconfig >/dev/null 2>&1; then
        if [ "$diag_mode" = "failure" ]; then
            hci_out="$(hciconfig -a 2>/dev/null || true)"
            log_warn "hciconfig -a output:"
        else
            hci_out="$(hciconfig 2>/dev/null || true)"
            log_warn "hciconfig output:"
        fi

        if [ -n "$hci_out" ]; then
            printf '%s\n' "$hci_out" |
                sanitize_bt_output |
                sed 's/^/[BT-DIAG] /'
        else
            log_warn "hciconfig output is empty. HCI attach may be incomplete."
        fi
    else
        log_warn "hciconfig not found; cannot dump HCI state"
    fi

    if command -v bluetoothctl >/dev/null 2>&1; then
        log_warn "bluetoothctl list:"
        if command -v timeout >/dev/null 2>&1; then
            timeout 5 bluetoothctl list 2>&1 |
                sanitize_bt_output |
                sed 's/^/[BT-DIAG] /' || true
        else
            bluetoothctl list 2>&1 |
                sanitize_bt_output |
                sed 's/^/[BT-DIAG] /' || true
        fi

        log_warn "bluetoothctl show:"
        if command -v timeout >/dev/null 2>&1; then
            timeout 5 bluetoothctl show 2>&1 |
                sanitize_bt_output |
                sed 's/^/[BT-DIAG] /' || true
        else
            bluetoothctl show 2>&1 |
                sanitize_bt_output |
                sed 's/^/[BT-DIAG] /' || true
        fi
    else
        log_warn "bluetoothctl not found; cannot dump controller state"
    fi

    if [ "$diag_mode" != "failure" ]; then
        return 0
    fi

    if command -v rfkill >/dev/null 2>&1; then
        log_warn "rfkill list:"
        rfkill list 2>&1 |
            sed 's/^/[BT-DIAG] /' || true
    else
        log_warn "rfkill not found; cannot dump rfkill state"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl status bluetooth --no-pager:"
        systemctl status bluetooth --no-pager 2>&1 |
            sed 's/^/[BT-DIAG] /' || true
    else
        log_warn "systemctl not found; cannot dump bluetooth.service status"
    fi

    if command -v journalctl >/dev/null 2>&1; then
        log_warn "journalctl -u bluetooth -b --no-pager | tail -100:"
        journalctl -u bluetooth -b --no-pager 2>&1 |
            tail -n 100 |
            sed 's/^/[BT-DIAG] /' || true
    else
        log_warn "journalctl not found; cannot dump bluetooth logs"
    fi

    if command -v dmesg >/dev/null 2>&1; then
        log_warn "Bluetooth-related dmesg tail:"
        dmesg 2>&1 |
            grep -Ei "$bt_dmesg_modules" |
            tail -n 200 |
            sed 's/^/[BT-DIAG] /' || true
    else
        log_warn "dmesg not found; cannot dump kernel Bluetooth logs"
    fi

    if [ -n "$diag_test_path" ] && command -v scan_dmesg_errors >/dev/null 2>&1; then
        log_warn "Running scan_dmesg_errors for Bluetooth-related modules"
        scan_dmesg_errors "$diag_test_path" "$bt_dmesg_modules" "" || true
    fi

    log_warn "Bluetooth firmware candidates:"

    fw_list="${TMPDIR:-/tmp}/bt_fw_candidates_$$.txt"
    : > "$fw_list"

    for qca_root in /lib/firmware/qca /usr/lib/firmware/qca; do
        [ -d "$qca_root" ] || continue

        log_warn "Firmware root: $qca_root"

        if command -v find >/dev/null 2>&1; then
            find "$qca_root" -maxdepth 2 -type f \
                \( -name '*btfw*' -o \
                   -name '*BT*' -o \
                   -name '*bt*' -o \
                   -name '*nv*' -o \
                   -name '*.tlv' -o \
                   -name '*.bin' -o \
                   -name '*.mbn' -o \
                   -name '*.b*' \) \
                -print 2>/dev/null >> "$fw_list"
        fi
    done

    if [ -s "$fw_list" ]; then
        sort -u "$fw_list" 2>/dev/null |
        while IFS= read -r fw_file || [ -n "$fw_file" ]; do
            [ -n "$fw_file" ] || continue

            if command -v print_path_meta >/dev/null 2>&1; then
                print_path_meta "$fw_file" 2>/dev/null |
                    sed 's/^/[BT-DIAG] /' || true
            elif command -v stat >/dev/null 2>&1; then
                stat -c '%A %U %G %a %n' "$fw_file" 2>/dev/null |
                    sed 's/^/[BT-DIAG] /' || true
            else
                printf '%s\n' "$fw_file" |
                    sed 's/^/[BT-DIAG] /'
            fi
        done
    else
        if command -v btfwpresent >/dev/null 2>&1; then
            fw_dir="$(btfwpresent 2>/dev/null || true)"

            if [ -n "$fw_dir" ]; then
                log_warn "btfwpresent found Bluetooth firmware under: $fw_dir"

                if command -v find >/dev/null 2>&1; then
                    find "$fw_dir" -maxdepth 1 -type f -print 2>/dev/null |
                    while IFS= read -r fw_file || [ -n "$fw_file" ]; do
                        [ -n "$fw_file" ] || continue

                        if command -v print_path_meta >/dev/null 2>&1; then
                            print_path_meta "$fw_file" 2>/dev/null |
                                sed 's/^/[BT-DIAG] /' || true
                        elif command -v stat >/dev/null 2>&1; then
                            stat -c '%A %U %G %a %n' "$fw_file" 2>/dev/null |
                                sed 's/^/[BT-DIAG] /' || true
                        else
                            printf '%s\n' "$fw_file" |
                                sed 's/^/[BT-DIAG] /'
                        fi
                    done
                else
                    log_warn "find not available; firmware file listing skipped"
                fi
            else
                log_warn "No Bluetooth firmware candidates found by btfwpresent"
            fi
        else
            log_warn "No Bluetooth firmware candidates found under known QCA firmware roots"
        fi
    fi

    rm -f "$fw_list" 2>/dev/null || true
}

# Warn+diag once per run if "bluetoothctl list" is empty in non-interactive mode.
btwarniflistempty() {
    adapter="${1:-}"

    if [ -n "${BTWARNEDLISTEMPTY:-}" ]; then
        return 0
    fi

    if btcontrollerpresentplain; then
        return 0
    fi

    BTWARNEDLISTEMPTY=1

    log_warn "bluetoothctl list returned no controllers in non-interactive mode."
    log_warn "On minimal/ramdisk images this can be normal; interactive bluetoothctl may still work."
    log_info "Proceeding with interactive bluetoothctl for controller queries (non-interactive output incomplete on some images)."

    btloghcidiag "$adapter"
    return 1
}

# Run bluetoothctl with a list of commands.
# Each argument becomes one line; callers can also pass a single
# multi-line string if they prefer.
btctl_script() {
    if [ "$#" -eq 0 ]; then
        return 0
    fi

    # Log once per run when we actually end up using interactive bluetoothctl
    # (Gate it via BTCTLINTERACTIVEFALLBACK so it prints only on the fallback path)
    if [ "${BTCTLINTERACTIVEFALLBACK:-0}" = "1" ] && [ -z "${BTINTERACTIVEMODELOGGED:-}" ]; then
        log_info "Proceeding with interactive bluetoothctl for controller queries (non-interactive output incomplete on some images)."
        BTINTERACTIVEMODELOGGED=1
    fi

    if command -v run_with_timeout >/dev/null 2>&1; then
        {
            for line in "$@"; do
                [ -n "$line" ] || continue
                printf '%s\n' "$line"
                sleep 0.2
            done
            sleep 1
        } | run_with_timeout 6 bluetoothctl 2>/dev/null
        return $?
    fi

    {
        for line in "$@"; do
            [ -n "$line" ] || continue
            printf '%s\n' "$line"
            sleep 0.2
        done
        sleep 1
    } | bluetoothctl 2>/dev/null
}

# Request a Bluetooth controller power transition while keeping bluetoothctl
# connected long enough for BlueZ to complete its asynchronous operation.
# Args: <adapter> <on|off>
bt_request_power() {
    # Keep the adapter argument for API compatibility. The original helper
    # deliberately used BlueZ's default controller, which is required by some
    # minimal/Yocto bluetoothctl implementations.
    want="${2:-}"
    settle_seconds="${BT_POWER_REQUEST_WAIT:-5}"

    case "$want" in
        on|off)
            ;;
        *)
            return 1
            ;;
    esac

    case "$settle_seconds" in
        ""|*[!0-9]*)
            settle_seconds=5
            ;;
    esac

    if [ "$settle_seconds" -lt 1 ] 2>/dev/null; then
        settle_seconds=1
    fi

    request_timeout=$((settle_seconds + 8))

    # bluetoothctl changes behaviour when stdin is a pipe on some BlueZ
    # releases. Use a PTY when expect is available, matching the manual
    # `bluetoothctl` flow and waiting for BlueZ to acknowledge the command.
    if command -v expect >/dev/null 2>&1; then
        BT_POWER_REQUEST_MODE="$want" \
            BT_POWER_REQUEST_SETTLE="$settle_seconds" \
            expect <<'__BT_POWER__'
                set timeout 15
                set mode $env(BT_POWER_REQUEST_MODE)
                set settle $env(BT_POWER_REQUEST_SETTLE)

                proc wait_prompt {} {
                    expect {
                        -re {(\r\n|\n)?(\[.*\][#>]|[#>])} {
                            return 1
                        }
                        timeout {
                            return 0
                        }
                        eof {
                            return 0
                        }
                    }
                }

                spawn bluetoothctl
                if {![wait_prompt]} {
                    exit 1
                }

                send "power $mode\r"
                expect {
                    -re {Changing power (on|off) succeeded} {}
                    -re {(Failed|failed|not available|No default controller)} {
                        exit 1
                    }
                    timeout {
                        exit 1
                    }
                    eof {
                        exit 1
                    }
                }

                after [expr {$settle * 1000}]
                send "show\r"
                if {![wait_prompt]} {
                    exit 1
                }

                send "quit\r"
                expect {
                    eof {}
                    timeout {}
                }
__BT_POWER__
        return $?
    fi

    if command -v run_with_timeout >/dev/null 2>&1; then
        {
            printf 'power %s\n' "$want"
            sleep "$settle_seconds"
            printf 'quit\n'
        } | run_with_timeout "$request_timeout" bluetoothctl 2>/dev/null
        return $?
    fi

    {
        printf 'power %s\n' "$want"
        sleep "$settle_seconds"
        printf 'quit\n'
    } | bluetoothctl 2>/dev/null
}

# bt_set_scan on|off [adapter]
# NOTE:
#   - We deliberately ignore adapter here and rely on BlueZ's default controller,
#     which matches the manual "bluetoothctl ; scan on" usage.
#   - Non-expect, pure CLI.
bt_set_scan() {
    mode="$1"
    # $2 (adapter) is currently unused but kept for API compatibility.
    # adapter="${2:-}"

    [ -n "$mode" ] || return 2

    case "$mode" in
        on)
            timeout="${BT_SCAN_ON_TIMEOUT:-15}"

            if command -v log_info >/dev/null 2>&1; then
                log_info "bt_set_scan(on): running 'bluetoothctl --timeout $timeout scan on'"
            fi

            out="$(bluetoothctl --timeout "$timeout" scan on 2>&1 || true)"

            if command -v sanitize_bt_output >/dev/null 2>&1 && \
               command -v log_info >/dev/null 2>&1; then
                printf '%s\n' "$out" | sanitize_bt_output | while IFS= read -r line; do
                    [ -n "$line" ] && log_info " [scan on] $line"
                done
            fi

            # Success marker
            if printf '%s\n' "$out" | grep -q "Discovery started"; then
                sleep 1
                return 0
            fi

            # Soft-fail (caller decides), but try interactive fallback once
            out2="$(btctl_script "scan on" "quit" 2>/dev/null | sanitize_bt_output || true)"
            if printf '%s\n' "$out2" | grep -q "Discovery started"; then
                sleep 1
                return 0
            fi

            sleep 1
            return 1
            ;;

        off)
            timeout="${BT_SCAN_OFF_TIMEOUT:-5}"
            discovering_state=""

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

            # Treat an explicitly confirmed stop as success.
            if printf '%s\n' "$out" | grep -q "Discovery stopped"; then
                sleep 1
                return 0
            fi
            if printf '%s\n' "$out" | grep -qi "Failed to stop discovery"; then
                discovering_state="$(bt_is_discovering 2>/dev/null || true)"
                [ -n "$discovering_state" ] || discovering_state="unknown"

                if [ "$discovering_state" = "no" ]; then
                    if command -v log_info >/dev/null 2>&1; then
                        log_info "bt_set_scan(off): discovery is already stopped, treating scan off as success"
                    fi
                    sleep 1
                    return 0
                fi
            fi

            # Fallback: interactive bluetoothctl (needed on minimal/ramdisk)
            if command -v log_warn >/dev/null 2>&1; then
                if [ -n "$discovering_state" ]; then
                    log_warn "bt_set_scan(off): BlueZ failed to stop discovery and state is $discovering_state, falling back to interactive bluetoothctl"
                else
                    log_warn "bt_set_scan(off): non-interactive scan off did not confirm stop, falling back to interactive bluetoothctl"
                fi
            fi

            out2="$(btctl_script "scan off" "quit" 2>/dev/null | sanitize_bt_output || true)"
            if printf '%s\n' "$out2" | grep -q "Discovery stopped"; then
                sleep 1
                return 0
            fi
            if printf '%s\n' "$out2" | grep -qi "Failed to stop discovery"; then
                discovering_state="$(bt_is_discovering 2>/dev/null || true)"
                [ -n "$discovering_state" ] || discovering_state="unknown"

                if [ "$discovering_state" = "no" ]; then
                    if command -v log_info >/dev/null 2>&1; then
                        log_info "bt_set_scan(off): discovery is already stopped, treating scan off as success"
                    fi
                    sleep 1
                    return 0
                fi

                if command -v log_warn >/dev/null 2>&1; then
                    log_warn "bt_set_scan(off): interactive scan off failed and discovery state is $discovering_state"
                fi
            fi

            sleep 1
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

# Return the best usable HCI adapter from sysfs.
#
# Selection order:
#   1. HCI visible to bluetoothctl and with valid BD address
#   2. HCI with valid non-zero BD address
#   3. HCI visible to bluetoothctl
#   4. HCI that appears UP/RUNNING
#   5. First HCI present as last-resort fallback
#
# This avoids selecting dead placeholder controllers such as:
#   hci0 UART 00:00:00:00:00:00 DOWN
# when another controller is actually usable, for example:
#   hci1 USB  8C:FD:F0:96:54:45 UP RUNNING
findhcisysfs() {
    first=""
    best_visible_valid=""
    best_valid=""
    best_visible=""
    best_up=""
 
    for h in /sys/class/bluetooth/hci*; do
        [ -d "$h" ] || continue
 
        dev="$(basename "$h")"
        [ -n "$dev" ] || continue
 
        [ -z "$first" ] && first="$dev"
 
        if btbdok "$dev" >/dev/null 2>&1; then
            if btcontrollervisible "$dev" >/dev/null 2>&1; then
                best_visible_valid="$dev"
                break
            fi
 
            [ -z "$best_valid" ] && best_valid="$dev"
        fi
 
        if [ -z "$best_visible" ] && btcontrollervisible "$dev" >/dev/null 2>&1; then
            best_visible="$dev"
        fi
 
        if [ -z "$best_up" ] && hascmd hciconfig; then
            if hciconfig "$dev" 2>/dev/null | grep -q 'UP RUNNING'; then
                best_up="$dev"
            fi
        fi
    done
 
    if [ -n "$best_visible_valid" ]; then
        printf '%s\n' "$best_visible_valid"
        return 0
    fi
 
    if [ -n "$best_valid" ]; then
        printf '%s\n' "$best_valid"
        return 0
    fi
 
    if [ -n "$best_visible" ]; then
        printf '%s\n' "$best_visible"
        return 0
    fi
 
    if [ -n "$best_up" ]; then
        printf '%s\n' "$best_up"
        return 0
    fi
 
    if [ -n "$first" ]; then
        printf '%s\n' "$first"
        return 0
    fi
 
    return 1
}

# Normalize and validate a Bluetooth address read from a runtime interface.
# stdout: uppercase MAC when valid
bt_normalize_bdaddr() {
    bt_nba_addr="$(
        printf '%s' "${1:-}" |
            tr '[:lower:]' '[:upper:]' |
            tr -d '[:space:]'
    )"

    case "$bt_nba_addr" in
        00:00:00:00:00:00|'')
            return 1
            ;;
        [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F])
            printf '%s\n' "$bt_nba_addr"
            return 0
            ;;
    esac

    return 1
}

# Resolve the device-tree node associated with an HCI adapter.
# stdout: resolved DT node path
bt_adapter_dt_node() {
    bt_adn_adapter="${1:-}"
    bt_adn_current=""
    bt_adn_node=""

    [ -n "$bt_adn_adapter" ] || return 1
    [ -e "/sys/class/bluetooth/$bt_adn_adapter/device" ] || return 1

    bt_adn_current="$(
        readlink -f "/sys/class/bluetooth/$bt_adn_adapter/device" \
            2>/dev/null || true
    )"

    while [ -n "$bt_adn_current" ] && [ "$bt_adn_current" != "/" ]; do
        if [ -L "$bt_adn_current/of_node" ] ||
           [ -d "$bt_adn_current/of_node" ]; then
            bt_adn_node="$(
                readlink -f "$bt_adn_current/of_node" 2>/dev/null || true
            )"

            if [ -n "$bt_adn_node" ] && [ -d "$bt_adn_node" ]; then
                printf '%s\n' "$bt_adn_node"
                return 0
            fi
        fi

        bt_adn_parent="$(dirname "$bt_adn_current")"
        [ "$bt_adn_parent" != "$bt_adn_current" ] || break
        bt_adn_current="$bt_adn_parent"
    done

    return 1
}

# Read an authoritative Bluetooth address provisioned in device tree.
# stdout: uppercase MAC when a valid six-byte property is present
btgetdtbdaddr() {
    bt_gdba_adapter="${1:-}"
    bt_gdba_node=""
    bt_gdba_property=""
    bt_gdba_bytes=""
    bt_gdba_addr=""

    bt_gdba_node="$(bt_adapter_dt_node "$bt_gdba_adapter" 2>/dev/null || true)"
    [ -n "$bt_gdba_node" ] || return 1

    for bt_gdba_name in local-bd-address qcom,local-bd-address; do
        bt_gdba_property="$bt_gdba_node/$bt_gdba_name"
        [ -r "$bt_gdba_property" ] || continue

        bt_gdba_bytes="$(
            od -An -tx1 -N 6 -v "$bt_gdba_property" 2>/dev/null |
                tr '\n' ' ' |
                tr -s ' ' |
                sed 's/^ //;s/ $//'
        )"

        # Intentional splitting of the six hexadecimal bytes returned by od.
        # shellcheck disable=SC2086
        set -- $bt_gdba_bytes
        [ "$#" -eq 6 ] || continue

        if [ -e "$bt_gdba_node/reversed-bd-address" ]; then
            bt_gdba_addr="$6:$5:$4:$3:$2:$1"
        else
            bt_gdba_addr="$1:$2:$3:$4:$5:$6"
        fi

        if bt_normalize_bdaddr "$bt_gdba_addr"; then
            return 0
        fi
    done

    return 1
}

# Resolve the exact Qualcomm NVM firmware selected by the current-boot driver
# log. Avoid choosing an arbitrary NVM from a multi-board firmware package.
# stdout: readable firmware path
bt_find_loaded_nvm_firmware() {
    bt_flnf_adapter="${1:-}"
    bt_flnf_name=""
    bt_flnf_log=""
    bt_flnf_adapter_log=""

    if command -v get_kernel_log >/dev/null 2>&1; then
        bt_flnf_log="$(get_kernel_log 2>/dev/null || true)"
    fi

    [ -n "$bt_flnf_log" ] || return 1

    if [ -n "$bt_flnf_adapter" ]; then
        bt_flnf_adapter_log="$(
            printf '%s\n' "$bt_flnf_log" |
                grep -i -E "Bluetooth:[[:space:]]+${bt_flnf_adapter}:|${bt_flnf_adapter}:" \
                2>/dev/null || true
        )"

        if [ -n "$bt_flnf_adapter_log" ]; then
            bt_flnf_log="$bt_flnf_adapter_log"
        fi
    fi

    bt_flnf_name="$(
        printf '%s\n' "$bt_flnf_log" |
            awk '
                {
                    lower = tolower($0)
                    marker = "using nvm file:"
                    start = index(lower, marker)

                    if (start == 0) {
                        marker = "qca downloading "
                        start = index(lower, marker)
                    }

                    if (start == 0) {
                        next
                    }

                    value = substr($0, start + length(marker))
                    sub(/^[[:space:]]+/, "", value)
                    split(value, fields, /[[:space:]]+/)
                    gsub(/[,"]+$/, "", fields[1])

                    name = tolower(fields[1])
                    sub(/^.*\//, "", name)

                    if (name ~ /^(msnv|cmnv|apnv|crnv|htnv|hmtnv|hpnv|wcnhpnv|nvm_)/) {
                        print fields[1]
                    }
                }
            ' |
            tail -n 1
    )"

    [ -n "$bt_flnf_name" ] || return 1

    case "$bt_flnf_name" in
        /*)
            for bt_flnf_path in \
                "$bt_flnf_name" \
                "$bt_flnf_name.xz" \
                "$bt_flnf_name.zst"
            do
                if [ -r "$bt_flnf_path" ]; then
                    printf '%s\n' "$bt_flnf_path"
                    return 0
                fi
            done
            ;;
        *)
            for bt_flnf_root in /lib/firmware /usr/lib/firmware; do
                for bt_flnf_path in \
                    "$bt_flnf_root/$bt_flnf_name" \
                    "$bt_flnf_root/$bt_flnf_name.xz" \
                    "$bt_flnf_root/$bt_flnf_name.zst"
                do
                    if [ -r "$bt_flnf_path" ]; then
                        printf '%s\n' "$bt_flnf_path"
                        return 0
                    fi
                done
            done
            ;;
    esac

    return 1
}

# Stream a raw or compressed firmware file to stdout.
bt_stream_firmware() {
    bt_sf_path="${1:-}"

    [ -r "$bt_sf_path" ] || return 1

    case "$bt_sf_path" in
        *.xz)
            if command -v xz >/dev/null 2>&1; then
                xz -dc "$bt_sf_path"
            elif command -v xzcat >/dev/null 2>&1; then
                xzcat "$bt_sf_path"
            else
                return 1
            fi
            ;;
        *.zst)
            if command -v zstd >/dev/null 2>&1; then
                zstd -q -d -c "$bt_sf_path"
            elif command -v zstdcat >/dev/null 2>&1; then
                zstdcat "$bt_sf_path"
            else
                return 1
            fi
            ;;
        *)
            command cat "$bt_sf_path"
            ;;
    esac
}

# Read the BD address from tag 2 of the exact Qualcomm TLV NVM selected by the
# kernel. Qualcomm stores bdaddr_t bytes least-significant byte first.
# stdout: uppercase MAC when the firmware contains a valid address
btgetfirmwarebdaddr() {
    bt_gfba_adapter="${1:-}"
    bt_gfba_path="${2:-}"
    bt_gfba_addr=""

    if [ -z "$bt_gfba_path" ]; then
        bt_gfba_path="$(
            bt_find_loaded_nvm_firmware "$bt_gfba_adapter" \
                2>/dev/null || true
        )"
    fi

    [ -n "$bt_gfba_path" ] || return 1

    bt_gfba_addr="$(
        bt_stream_firmware "$bt_gfba_path" 2>/dev/null |
            od -An -tu1 -v 2>/dev/null |
            awk '
                {
                    for (i = 1; i <= NF; i++) {
                        bytes[++count] = $i
                    }
                }

                END {
                    if (count < 4) {
                        exit 1
                    }

                    type = bytes[1]
                    tlv_length = bytes[2] + (bytes[3] * 256) + (bytes[4] * 65536)
                    offset = 5

                    if (type == 4) {
                        if (count < 8) {
                            exit 1
                        }

                        type = bytes[5]
                        tlv_length = bytes[6] + (bytes[7] * 256) + (bytes[8] * 65536)
                        offset = 9
                    }

                    if (type != 2) {
                        exit 1
                    }

                    limit = offset + tlv_length - 1
                    if (limit > count) {
                        limit = count
                    }

                    while ((offset + 11) <= limit) {
                        tag_id = bytes[offset] + (bytes[offset + 1] * 256)
                        tag_len = bytes[offset + 2] + (bytes[offset + 3] * 256)
                        data = offset + 12

                        if ((data + tag_len - 1) > limit) {
                            exit 1
                        }

                        if (tag_id == 2 && tag_len == 6) {
                            printf "%02X:%02X:%02X:%02X:%02X:%02X\n", bytes[data + 5], bytes[data + 4], bytes[data + 3], bytes[data + 2], bytes[data + 1], bytes[data]
                            exit 0
                        }

                        offset = data + tag_len
                    }

                    exit 1
                }
            '
    )" || bt_gfba_addr=""

    bt_normalize_bdaddr "$bt_gfba_addr"
}

# stdout: MAC if known (e.g. 00:00:00:00:5A:AD)
# ret: 0=ok, 1=not found
btgetbdaddr() {
    dev="${1:-}"
    addr=""

    if [ -z "$dev" ]; then
        dev="$(listhcis 2>/dev/null | sed -n '1p')"
    fi

    if [ -n "$dev" ] && [ -r "/sys/class/bluetooth/$dev/address" ]; then
        addr="$(cat "/sys/class/bluetooth/$dev/address" 2>/dev/null || true)"

        if bt_normalize_bdaddr "$addr"; then
            return 0
        fi
    fi

    if command -v hciconfig >/dev/null 2>&1; then
        if [ -n "$dev" ]; then
            addr="$(hciconfig -a "$dev" 2>/dev/null | awk '/BD Address:/ {print $3; exit}')"
        else
            addr="$(hciconfig -a 2>/dev/null        | awk '/BD Address:/ {print $3; exit}')"
        fi
        if bt_normalize_bdaddr "$addr"; then
            return 0
        fi
    fi

    if [ -n "$dev" ] && command -v btmgmt >/dev/null 2>&1; then
        bt_gba_index="${dev#hci}"

        case "$bt_gba_index" in
            ''|*[!0-9]*)
                ;;
            *)
                if command -v run_with_timeout >/dev/null 2>&1; then
                    bt_gba_info="$(
                        run_with_timeout 3 \
                            btmgmt --index "$bt_gba_index" info \
                            2>/dev/null || true
                    )"
                elif command -v timeout >/dev/null 2>&1; then
                    bt_gba_info="$(
                        timeout 3 btmgmt --index "$bt_gba_index" info \
                            2>/dev/null || true
                    )"
                else
                    bt_gba_info="$(
                        btmgmt --index "$bt_gba_index" info 2>/dev/null || true
                    )"
                fi

                addr="$(
                    printf '%s\n' "$bt_gba_info" |
                        awk 'tolower($1) == "addr" { print $2; exit }'
                )"

                if bt_normalize_bdaddr "$addr"; then
                    return 0
                fi
                ;;
        esac
    fi
 
    # No logging here either, caller will log if needed.
    return 1
}

bt_log_selected_adapter() {
    adapter="${1:-}"
    reason="${2:-auto-detect}"

    [ -n "$adapter" ] || return 0

    addr="$(btgetbdaddr "$adapter" 2>/dev/null | head -n 1 | awk '{print $NF}' || true)"
    [ -n "$addr" ] || addr="unknown"

    bus="unknown"
    state="unknown"
    visible="no"
    bd_status="invalid"

    if hascmd hciconfig; then
        hci_out="$(hciconfig -a "$adapter" 2>/dev/null || true)"

        bus="$(
            printf '%s\n' "$hci_out" |
                awk -F: '/Bus:/ {
                    v=$2
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                    print v
                    exit
                }'
        )"
        [ -n "$bus" ] || bus="unknown"

        if printf '%s\n' "$hci_out" | grep -q 'UP RUNNING'; then
            state="UP RUNNING"
        elif printf '%s\n' "$hci_out" | grep -q 'DOWN'; then
            state="DOWN"
        fi
    fi

    if btcontrollervisible "$adapter" >/dev/null 2>&1; then
        visible="yes"
    fi

    if btbdok "$adapter" >/dev/null 2>&1; then
        bd_status="valid"
    fi

    log_info "Selected Bluetooth adapter: $adapter reason=$reason bus=$bus state=$state bd_addr=$addr bd_status=$bd_status bluetoothctl_visible=$visible"
}

# ret: 0=controller visible, 1=none
btcontrollerpresent() {
    # Fast path: cheap one-shot (works on some builds)
    if command -v timeout >/dev/null 2>&1; then
        if timeout 2 bluetoothctl list 2>/dev/null \
            | sanitize_bt_output \
            | grep -qi '^[[:space:]]*Controller[[:space:]]'
        then
            return 0
        fi
    else
        if bluetoothctl list 2>/dev/null \
            | sanitize_bt_output \
            | grep -qi '^[[:space:]]*Controller[[:space:]]'
        then
            return 0
        fi
    fi

    # Announce fallback once per process (prevents log spam across loops/calls)
    if [ -z "${BTCTLINTERACTIVEFALLBACK:-}" ]; then
        log_warn "bluetoothctl list returned no controllers in non-interactive mode."
        log_warn "On minimal/ramdisk images this can be normal; interactive bluetoothctl may still work."
        log_info "Proceeding with interactive bluetoothctl for controller queries (non-interactive output incomplete on some images)."
        BTCTLINTERACTIVEFALLBACK=1
    fi

    # Robust path: interactive list+quit, retry for async BlueZ readiness
    i=0
    maxwait=15
    while [ "$i" -lt "$maxwait" ]; do
        if btctl_script "list" "quit" \
            | sanitize_bt_output \
            | grep -qi '^[[:space:]]*Controller[[:space:]]'
        then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    return 1
}

# ret: 0=controller visible, 1=not visible
# This is just a clearer alias/wrapper if you prefer the name.
bt_controller_visible() {
    btcontrollervisible "${1:-}"
}

# Usage: btensurepublicaddr hci0
# Apply a public address through btmgmt using the numeric HCI index.
btmgmtsetpublicaddr() {
    bt_mspa_dev="${1:-}"
    bt_mspa_addr="${2:-}"
    bt_mspa_index="${bt_mspa_dev#hci}"
    bt_mspa_output=""

    command -v btmgmt >/dev/null 2>&1 || return 1

    case "$bt_mspa_index" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    if ! bt_mspa_addr="$(bt_normalize_bdaddr "$bt_mspa_addr")"; then
        return 1
    fi

    if command -v run_with_timeout >/dev/null 2>&1; then
        if ! bt_mspa_output="$(
            run_with_timeout 10 \
                btmgmt --index "$bt_mspa_index" \
                public-addr "$bt_mspa_addr" 2>&1
        )"; then
            log_warn "btmgmt failed to configure public address $bt_mspa_addr on $bt_mspa_dev"
            [ -z "$bt_mspa_output" ] || printf '%s\n' "$bt_mspa_output" >&2
            return 1
        fi
    elif command -v timeout >/dev/null 2>&1; then
        if ! bt_mspa_output="$(
            timeout 10 btmgmt --index "$bt_mspa_index" \
                public-addr "$bt_mspa_addr" 2>&1
        )"; then
            log_warn "btmgmt failed to configure public address $bt_mspa_addr on $bt_mspa_dev"
            [ -z "$bt_mspa_output" ] || printf '%s\n' "$bt_mspa_output" >&2
            return 1
        fi
    elif ! bt_mspa_output="$(
        btmgmt --index "$bt_mspa_index" public-addr "$bt_mspa_addr" 2>&1
    )"; then
        log_warn "btmgmt failed to configure public address $bt_mspa_addr on $bt_mspa_dev"
        [ -z "$bt_mspa_output" ] || printf '%s\n' "$bt_mspa_output" >&2
        return 1
    fi

    log_info "btmgmt configured public address $bt_mspa_addr on $bt_mspa_dev"
    [ -z "$bt_mspa_output" ] || printf '%s\n' "$bt_mspa_output" >&2
    return 0
}

# Usage: btensurepublicaddr hci0
# Logic:
#   - If bluetoothctl already sees a Controller, do nothing
#   - Otherwise use a valid runtime, device-tree, or selected NVM address
#   - Prefer the direct btmgmt public-addr command used by MSL hosts
# Return:
#   0 = controller visible (already or now)
#   1 = failed to make visible
#   2 = could not read BD address
btensurepublicaddr() {
    dev="${1:-}"
    mac=""
    mac_source=""
    firmware_path=""
 
    # A visible controller with a valid runtime address needs no bootstrap.
    # Do not accept an all-zero controller merely because BlueZ lists it.
    if btbdok "$dev" && btcontrollervisible "$dev"; then
        log_info "controller already visible via bluetoothctl, skip public-addr"
        return 0
    fi

    if btbdok "$dev"; then
        mac="$(btgetbdaddr "$dev" 2>/dev/null | sed -n '1p')"
        mac_source="runtime"
    elif mac="$(btgetdtbdaddr "$dev" 2>/dev/null | sed -n '1p')" &&
         [ -n "$mac" ]; then
        mac_source="device-tree"
    else
        firmware_path="$(
            bt_find_loaded_nvm_firmware "$dev" 2>/dev/null || true
        )"

        if [ -n "$firmware_path" ]; then
            mac="$(
                btgetfirmwarebdaddr "$dev" "$firmware_path" \
                    2>/dev/null | sed -n '1p'
            )"
        fi

        if [ -n "$mac" ]; then
            mac_source="firmware-nvm:$firmware_path"
        fi
    fi

    if [ -z "$mac" ]; then
        log_warn "Bluetooth adapter ${dev:-<unknown>} has no valid runtime, device-tree, or selected firmware NVM BD address, public-addr cannot be applied"
        return 2
    fi

    log_info "Applying public address $mac from $mac_source to $dev"

    bt_public_addr_applied=0
    if btmgmtsetpublicaddr "$dev" "$mac"; then
        bt_public_addr_applied=1
    elif command -v bluetoothctl >/dev/null 2>&1; then
        log_warn "Direct btmgmt public-addr failed, trying the bluetoothctl management fallback"

        if btctl_script "menu mgmt
public-addr $mac
back
quit" >/dev/null 2>&1; then
            bt_public_addr_applied=1
        fi
    fi

    if [ "$bt_public_addr_applied" -eq 0 ]; then
        log_warn "Unable to apply public address $mac to $dev"
        return 1
    fi

    # Poll for the runtime address and BlueZ controller visibility because both
    # are updated asynchronously after the management command completes.
    i=0
    max_wait="${BT_CONTROLLER_VISIBLE_WAIT:-15}"

    case "$max_wait" in
        ''|*[!0-9]*)
            max_wait=15
            ;;
    esac

    while [ "$i" -lt "$max_wait" ]; do
        if btbdok "$dev" && btcontrollervisible "$dev"; then
            log_info "Controller $dev is visible after applying public address $mac"
            return 0
        fi

        sleep 1
        i=$((i + 1))
    done

    log_warn "Controller $dev is not ready after applying public address $mac and waiting ${max_wait}s"
    return 1
}

btcontrollervisible() {
    # Usage:
    #   btcontrollervisible
    #   btcontrollervisible hci0
    #   btcontrollervisible 00:11:22:33:44:55
    #
    # Returns: 0 if controller visible to bluetoothctl, else 1
 
    arg="${1:-}"
    addr=""
    dev=""
    out=""
 
    # Normalize arg
    case "$arg" in
        hci[0-9]*)
            dev="$arg"
            if [ -r "/sys/class/bluetooth/$dev/address" ]; then
                addr="$(cat "/sys/class/bluetooth/$dev/address" 2>/dev/null || true)"
            fi
            ;;
        *:*:*:*:*:*)
            addr="$arg"
            ;;
        *)
            ;;
    esac
 
    btctlrun() {
        if command -v run_with_timeout >/dev/null 2>&1; then
            run_with_timeout 2 bluetoothctl "$@" 2>/dev/null || true
        elif command -v timeout >/dev/null 2>&1; then
            timeout 2 bluetoothctl "$@" 2>/dev/null || true
        else
            bluetoothctl "$@" 2>/dev/null || true
        fi
    }
 
    # bluetoothctl list
    out="$(btctlrun list)"
    if [ -n "$out" ]; then
        if [ -n "$addr" ]; then
            printf '%s\n' "$out" | grep -qi "$addr" && return 0
        fi
        printf '%s\n' "$out" | grep -q '^Controller ' && return 0
    fi
 
    # bluetoothctl show
    out="$(btctlrun show)"
    if [ -n "$out" ]; then
        if [ -n "$addr" ]; then
            printf '%s\n' "$out" | grep -qi "$addr" && return 0
        fi
        printf '%s\n' "$out" | grep -q '^Controller ' && return 0
    fi
 
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
    if btcontrollervisible "$adapter"; then
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
    if btcontrollervisible "$adapter"; then
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

    # Fallback: interactive bluetoothctl (needed on minimal/ramdisk)
    if [ -z "$val" ]; then
        out="$(btctl_script "show" "quit" 2>/dev/null | sanitize_bt_output || true)"
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
    fi

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
    out="$(
        run_with_timeout 3 bluetoothctl show 2>/dev/null \
            | sanitize_bt_output \
            | tr -d '\r'
    )"
 
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
    out="$(
        run_with_timeout 3 bluetoothctl devices 2>/dev/null \
            | sanitize_bt_output || true
    )"

    if [ -z "$out" ]; then
        # If controller list is already known-flaky, mark fallback so btctl_script logs once.
        if ! btcontrollerpresentplain; then
            BTCTLINTERACTIVEFALLBACK=1
        fi

        out="$(btctl_script "devices" "quit" | sanitize_bt_output || true)"
    fi

    printf '%s\n' "$out"
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
    mac=""
 
    # If a specific adapter is provided (e.g. hci0), resolve to BDADDR and use "show <BDADDR>"
    # because "select hci0" is unreliable on some minimal/ramdisk setups.
    if [ -n "$dev" ]; then
        mac="$(
            btgetbdaddr "$dev" 2>/dev/null \
            | head -n 1 \
            | awk '{print $NF}'
        )"
    fi
 
    # Newer BlueZ versions complete `show` synchronously when invoked with
    # arguments. Prefer that form before the interactive fallback below. The
    # fallback is retained for minimal images where non-interactive output is
    # incomplete.
    if [ -n "$mac" ]; then
        if command -v run_with_timeout >/dev/null 2>&1; then
            out="$(
                run_with_timeout 3 bluetoothctl show "$mac" 2>/dev/null \
                    | sanitize_bt_output || true
            )"
        else
            out="$(bluetoothctl show "$mac" 2>/dev/null | sanitize_bt_output || true)"
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
    fi

    # The default controller form is the most portable query on Debian and
    # Ubuntu. It also covers BlueZ releases that do not accept an address as
    # the argument to `show`.
    if [ -z "$state" ]; then
        if command -v run_with_timeout >/dev/null 2>&1; then
            out="$(
                run_with_timeout 3 bluetoothctl show 2>/dev/null \
                    | sanitize_bt_output || true
            )"
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
    fi

    if [ -z "$state" ] && [ -n "$mac" ]; then
        out="$(
            btctl_script "show $mac" "quit" 2>/dev/null \
                | sanitize_bt_output || true
        )"
    elif [ -z "$state" ]; then
        out="$(
            btctl_script "show" "quit" 2>/dev/null \
                | sanitize_bt_output || true
        )"
    fi
 
    if [ -z "$state" ]; then
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
 
    # Fallback: try default controller if adapter-specific attempt didn’t yield Powered:
    if [ -z "$state" ]; then
        out="$(
            btctl_script "show" "quit" 2>/dev/null \
                | sanitize_bt_output || true
        )"
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
# btpower ADAPTER on|off
# Request a BlueZ controller power transition and require two consecutive exact
# Powered=yes/no observations before reporting success.
# Inputs: adapter identifier and target state. Output: diagnostic logs only.
# Returns: 0 when the requested state is stable, 1 when it is not achieved, and
# 2 when no controller state can be read. Side effects: may issue bounded
# bluetoothctl power requests and wait between verification samples.
btpower() {
    dev="${1:-}"
    want="${2:-}"
 
    case "$want" in
        on)
            target_state=yes
            ;;
        off)
            target_state=no
            ;;
        *)
            log_warn "btpower: invalid target state '$want'"
            return 1
            ;;
    esac
 
    cur_state="$(btgetpower "$dev" 2>/dev/null || true)"
    [ -z "$cur_state" ] && cur_state="unknown"

    if [ "$cur_state" = "$target_state" ]; then
        log_info "btpower: $dev already Powered=$target_state, confirming stable state."
        sleep 1
        confirm_state="$(btgetpower "$dev" 2>/dev/null || true)"
        if [ "$confirm_state" = "$target_state" ]; then
            log_info "btpower: $dev Powered=$target_state confirmed stable without a new request."
            return 0
        fi
        log_warn "btpower: $dev initial Powered=$target_state observation was not stable, observed=${confirm_state:-unknown} on confirmation"
    fi
 
    log_info "btpower: requesting '$want' on $dev (current=$cur_state)"

    request_attempts="${BT_POWER_REQUEST_ATTEMPTS:-3}"
    verify_attempts="${BT_POWER_VERIFY_ATTEMPTS:-10}"
    retry_delay="${BT_POWER_REQUEST_RETRY_DELAY:-2}"
    required_confirmations=2

    case "$request_attempts" in
        ""|*[!0-9]*) request_attempts=3 ;;
    esac
    case "$verify_attempts" in
        ""|*[!0-9]*) verify_attempts=10 ;;
    esac
    case "$retry_delay" in
        ""|*[!0-9]*) retry_delay=2 ;;
    esac

    if [ "$request_attempts" -lt 1 ] 2>/dev/null; then
        request_attempts=1
    fi
    if [ "$verify_attempts" -lt 1 ] 2>/dev/null; then
        verify_attempts=1
    fi
    if [ "$verify_attempts" -lt "$required_confirmations" ] 2>/dev/null; then
        verify_attempts="$required_confirmations"
    fi

    log_info "btpower: request attempts=$request_attempts verify attempts=$verify_attempts stable confirmations=$required_confirmations retry delay=${retry_delay}s"
    if command -v expect >/dev/null 2>&1; then
        log_info "btpower: using an expect PTY for interactive bluetoothctl power requests"
    else
        log_warn "btpower: expect is unavailable, using the portable stdin-pipe fallback"
    fi

    request_attempt=1
    state=""
    pstate=""

    while [ "$request_attempt" -le "$request_attempts" ]; do
        # Drive bluetoothctl interactively against BlueZ's default controller,
        # which matches the established minimal/ramdisk flow. Its exit status
        # is informational because BlueZ completes power changes asynchronously.
        if ! bt_request_power "$dev" "$want" >/dev/null 2>&1; then
            log_warn "btpower: bluetoothctl request attempt $request_attempt/$request_attempts exited without confirmation"
        fi

        verify_attempt=1
        stable_confirmations=0
        while [ "$verify_attempt" -le "$verify_attempts" ]; do
            state="$(btgetpower "$dev" 2>/dev/null || true)"

            if [ "$state" = "$target_state" ]; then
                stable_confirmations=$((stable_confirmations + 1))
            else
                stable_confirmations=0
            fi

            if [ "$stable_confirmations" -ge "$required_confirmations" ]; then
                log_info "btpower: $dev Powered=$state confirmed stable after request attempt $request_attempt."
                return 0
            fi

            if [ "$stable_confirmations" -gt 0 ]; then
                log_info "btpower: $dev Powered=$state confirmation $stable_confirmations/$required_confirmations"
            fi

            sleep 1
            verify_attempt=$((verify_attempt + 1))
        done

        # Keep PowerState as diagnostic evidence only. A PASS always requires
        # the stable Powered=yes/no value above.
        out="$(
            btctl_script "show" "quit" 2>/dev/null \
                | sanitize_bt_output || true
        )"
        pstate="$(printf '%s\n' "$out" \
            | awk -F':[[:space:]]*' '
                /^[[:space:]]*PowerState:/ {
                    v = tolower($2);
                    gsub(/\r/, "", v);
                    gsub(/[[:space:]]+/, "", v);
                    print v;
                    exit
                }')"

        if [ "$request_attempt" -lt "$request_attempts" ]; then
            log_warn "btpower: request attempt $request_attempt/$request_attempts did not reach $want, retrying in ${retry_delay}s (Powered=${state:-unknown}, PowerState=${pstate:-unknown})"
            sleep "$retry_delay"
        fi

        request_attempt=$((request_attempt + 1))
    done
 
    if [ -z "$state" ]; then
        log_warn "btpower: unable to read Powered state for $dev after request. (PowerState last='$pstate')"
        return 2
    fi
 
    log_warn "btpower: $dev state after request is '$state' (wanted $want). (PowerState last='$pstate')"
    return 1
}

# Return success for public Qualcomm/Atheros Bluetooth firmware and NVM names.
bt_qca_firmware_name_supported() {
    bt_qfns_name="$(basename "${1:-}")"

    case "$bt_qfns_name" in
        msbtfw*|msnv*|cmbtfw*|cmnv*|apbtfw*|apnv*|\
        crbtfw*|crnv*|htbtfw*|htnv*|hmtbtfw*|hmtnv*|\
        hpbtfw*|hpnv*|wcnhpbtfw*|wcnhpnv*)
            return 0
            ;;
    esac

    return 1
}

# Print the directory containing the first readable supported firmware file.
btfwpresent() {
    bt_fwp_file=""

    for bt_fwp_root in \
        /lib/firmware/qca \
        /usr/lib/firmware/qca \
        /lib/firmware \
        /usr/lib/firmware
    do
        [ -d "$bt_fwp_root" ] || continue

        bt_fwp_file="$(
            find "$bt_fwp_root" -maxdepth 4 \
                \( -type f -o -type l \) -print 2>/dev/null |
            (
                while IFS= read -r bt_fwp_candidate ||
                      [ -n "$bt_fwp_candidate" ]; do
                    [ -r "$bt_fwp_candidate" ] || continue

                    if bt_qca_firmware_name_supported "$bt_fwp_candidate"; then
                        printf '%s\n' "$bt_fwp_candidate"
                        exit 0
                    fi
                done

                exit 1
            )
        )" || bt_fwp_file=""

        if [ -n "$bt_fwp_file" ]; then
            dirname "$bt_fwp_file"
            return 0
        fi
    done

    return 1
}

bt_wait_ready() {
    bt_wr_max_wait="${1:-60}"
    bt_wr_sleep_step="${2:-2}"
    bt_wr_requested_adapter="${3:-${BT_ADAPTER:-}}"
    bt_wr_waited=0
    bt_wr_started_service=0
    bt_wr_adapter=""

    BT_RUNTIME_READY_ADAPTER=""

    if [ -z "$bt_wr_max_wait" ]; then
        bt_wr_max_wait=60
    fi
    if [ -z "$bt_wr_sleep_step" ]; then
        bt_wr_sleep_step=2
    fi

    case "$bt_wr_max_wait" in
        ''|*[!0-9]*)
            bt_wr_max_wait=60
            ;;
    esac
    case "$bt_wr_sleep_step" in
        ''|*[!0-9]*)
            bt_wr_sleep_step=2
            ;;
    esac

    if [ "$bt_wr_max_wait" -le 0 ] 2>/dev/null; then
        bt_wr_max_wait=60
    fi
    if [ "$bt_wr_sleep_step" -le 0 ] 2>/dev/null; then
        bt_wr_sleep_step=2
    fi

    while [ "$bt_wr_waited" -le "$bt_wr_max_wait" ]; do
        if [ -n "$bt_wr_requested_adapter" ]; then
            bt_wr_adapter="$bt_wr_requested_adapter"
        else
            bt_wr_fallback_adapter="$(listhcis 2>/dev/null | sed -n '1p')"
            bt_wr_adapter="$(
                listhcis 2>/dev/null |
                    while IFS= read -r bt_wr_candidate; do
                        if btbdok "$bt_wr_candidate"; then
                            printf '%s\n' "$bt_wr_candidate"
                            break
                        fi
                    done
            )"

            if [ -z "$bt_wr_adapter" ]; then
                bt_wr_adapter="$bt_wr_fallback_adapter"
            fi
        fi

        if btsvcactive &&
           [ -n "$bt_wr_adapter" ] &&
           btbdok "$bt_wr_adapter"; then
            BT_RUNTIME_READY_ADAPTER="$bt_wr_adapter"
            log_info "Bluetooth runtime became ready after ${bt_wr_waited}s with usable adapter $bt_wr_adapter."
            return 0
        fi

        if [ "$bt_wr_started_service" -eq 0 ]; then
            if command -v systemctl >/dev/null 2>&1; then
                if ! btsvcactive; then
                    log_info "Bluetooth service not active yet, attempting start."
                    systemctl start bluetooth.service >/dev/null 2>&1 || true
                fi
            fi
            bt_wr_started_service=1
        fi

        if [ "$bt_wr_waited" -eq "$bt_wr_max_wait" ]; then
            break
        fi

        bt_wr_delay="$bt_wr_sleep_step"
        bt_wr_remaining=$((bt_wr_max_wait - bt_wr_waited))
        if [ "$bt_wr_delay" -gt "$bt_wr_remaining" ]; then
            bt_wr_delay="$bt_wr_remaining"
        fi

        sleep "$bt_wr_delay"
        bt_wr_waited=$((bt_wr_waited + bt_wr_delay))
    done

    if [ -n "$bt_wr_adapter" ]; then
        log_warn "Bluetooth runtime did not become ready within ${bt_wr_max_wait}s, adapter $bt_wr_adapter has no valid BD address"
    else
        log_warn "Bluetooth runtime did not become ready within ${bt_wr_max_wait}s, no HCI adapter appeared"
    fi

    return 1
}

# Perform one controlled recovery attempt for an incompletely initialized
# Bluetooth runtime. The controller is left unblocked and bluetooth.service is
# left running for subsequent tests.
#
# Usage:
#   bt_recover_runtime [ADAPTER]
bt_recover_runtime() {
    bt_rr_adapter="${1:-}"
    bt_rr_action=0

    log_warn "Attempting one controlled Bluetooth runtime recovery"

    if command -v rfkill >/dev/null 2>&1; then
        log_info "Cycling the Bluetooth software rfkill state"
        rfkill block bluetooth >/dev/null 2>&1 || true
        sleep 2
        rfkill unblock bluetooth >/dev/null 2>&1 || true
        sleep 2
        bt_rr_action=1
    elif command -v rfkillunblocksysfs >/dev/null 2>&1; then
        log_info "Unblocking Bluetooth through sysfs"
        rfkillunblocksysfs >/dev/null 2>&1 || true
        bt_rr_action=1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        log_info "Restarting bluetooth.service after the recovery attempt"
        if command -v run_with_timeout >/dev/null 2>&1; then
            run_with_timeout 15 \
                systemctl restart bluetooth.service >/dev/null 2>&1 || true
        else
            systemctl restart bluetooth.service >/dev/null 2>&1 || true
        fi
        bt_rr_action=1
    fi

    if [ -n "$bt_rr_adapter" ]; then
        btensurepublicaddr "$bt_rr_adapter" || true
    fi

    if [ -n "$bt_rr_adapter" ] && command -v hciconfig >/dev/null 2>&1; then
        hciconfig "$bt_rr_adapter" up >/dev/null 2>&1 || true
        bt_rr_action=1
    fi

    if [ "$bt_rr_action" -eq 0 ]; then
        log_warn "No supported Bluetooth recovery mechanism is available"
        return 1
    fi

    return 0
}

# Ensure Bluetooth reaches a usable state, including bounded recovery retries.
# A usable runtime has an active service and an HCI adapter with a valid,
# non-zero BD address. BT_RUNTIME_RECOVERED and BT_RUNTIME_READY_ADAPTER are
# updated for callers that want to report whether recovery was required.
#
# Usage:
#   bt_ensure_runtime_ready [ADAPTER] [INITIAL_WAIT] [RECOVERY_WAIT] [ATTEMPTS]
bt_ensure_runtime_ready() {
    bt_err_adapter="${1:-${BT_ADAPTER:-}}"
    bt_err_initial_wait="${2:-${BT_RUNTIME_READY_WAIT:-20}}"
    bt_err_recovery_wait="${3:-${BT_RUNTIME_RECOVERY_WAIT:-40}}"
    bt_err_attempts="${4:-${BT_RUNTIME_RECOVERY_ATTEMPTS:-2}}"
    bt_err_attempt=1

    # Exported result state for suite callers.
    # shellcheck disable=SC2034
    BT_RUNTIME_RECOVERED=0
    # shellcheck disable=SC2034
    BT_RUNTIME_READY_ADAPTER=""
    # shellcheck disable=SC2034
    BT_RUNTIME_FAILURE_REASON=""

    for bt_err_value in \
        "$bt_err_initial_wait" \
        "$bt_err_recovery_wait" \
        "$bt_err_attempts"
    do
        case "$bt_err_value" in
            ''|*[!0-9]*|0)
                log_error "Bluetooth readiness waits and attempts must be positive integers"
                return 2
                ;;
        esac
    done

    bt_err_bootstrap_adapter="$bt_err_adapter"
    if [ -z "$bt_err_bootstrap_adapter" ]; then
        bt_err_bootstrap_adapter="$(listhcis 2>/dev/null | sed -n '1p')"
    fi

    if [ -n "$bt_err_bootstrap_adapter" ] &&
       ! btbdok "$bt_err_bootstrap_adapter"; then
        log_info "Bluetooth adapter $bt_err_bootstrap_adapter has no valid runtime BD address, attempting authoritative public-address bootstrap"
        btensurepublicaddr "$bt_err_bootstrap_adapter" || true
    fi

    if bt_wait_ready "$bt_err_initial_wait" 2 "$bt_err_adapter"; then
        return 0
    fi

    while [ "$bt_err_attempt" -le "$bt_err_attempts" ]; do
        log_warn "Bluetooth recovery attempt $bt_err_attempt/$bt_err_attempts"

        bt_err_recovery_adapter="$bt_err_adapter"
        if [ -z "$bt_err_recovery_adapter" ]; then
            bt_err_recovery_adapter="$(listhcis 2>/dev/null | sed -n '1p')"
        fi

        if bt_recover_runtime "$bt_err_recovery_adapter"; then
            log_info "Waiting up to ${bt_err_recovery_wait}s after Bluetooth recovery"

            if bt_wait_ready \
                "$bt_err_recovery_wait" \
                2 \
                "$bt_err_adapter"; then
                # shellcheck disable=SC2034
                BT_RUNTIME_RECOVERED=1
                log_warn "Bluetooth runtime recovered on attempt $bt_err_attempt"
                return 0
            fi
        else
            log_warn "Bluetooth recovery attempt $bt_err_attempt could not perform a recovery action"
        fi

        bt_err_attempt=$((bt_err_attempt + 1))
    done

    bt_err_final_adapter="$bt_err_adapter"
    if [ -z "$bt_err_final_adapter" ]; then
        bt_err_final_adapter="$(listhcis 2>/dev/null | sed -n '1p')"
    fi

    bt_err_raw_addr=""
    if [ -n "$bt_err_final_adapter" ] &&
       [ -r "/sys/class/bluetooth/$bt_err_final_adapter/address" ]; then
        bt_err_raw_addr="$(
            cat "/sys/class/bluetooth/$bt_err_final_adapter/address" \
                2>/dev/null || true
        )"
        bt_err_raw_addr="$(
            printf '%s' "$bt_err_raw_addr" |
                tr '[:lower:]' '[:upper:]' |
                tr -d '[:space:]'
        )"
    fi

    if [ "$bt_err_raw_addr" = "00:00:00:00:00:00" ]; then
        BT_RUNTIME_FAILURE_REASON="Bluetooth adapter $bt_err_final_adapter reports an all-zero BD address after recovery, verify Qualcomm firmware and platform BD-address provisioning, then reboot after any firmware package update"
    elif [ -n "$bt_err_final_adapter" ]; then
        BT_RUNTIME_FAILURE_REASON="Bluetooth adapter $bt_err_final_adapter has no valid runtime BD address after recovery, verify Qualcomm firmware and platform BD-address provisioning"
    else
        BT_RUNTIME_FAILURE_REASON="No Bluetooth HCI adapter appeared after recovery, verify the kernel driver, firmware, and hardware description"
    fi

    export BT_RUNTIME_FAILURE_REASON
    log_error "$BT_RUNTIME_FAILURE_REASON"
    return 1
}

btfwloaded() {
    adapter="${1:-}"
 
    # ---- Configurable patterns (override via env if needed) ----
    # Success markers:
    # - UART controllers usually log final setup marker.
    # - USB QCA controllers can log rampatch/NVM/QCA patch+firmware markers.
    success_re="${BTFW_SUCCESS_RE:-setup on UART is completed|setup on uart is completed|using rampatch file|using NVM file|QCA: patch.*firmware}"
 
    # Fatal-ish errors. These should be evaluated against the selected adapter
    # when an adapter is provided, so a dead placeholder hci0 does not fail a
    # working hci1 USB controller.
    fatal_re="${BTFW_FATAL_RE:-tx timeout|Reading QCA version information failed|failed to open firmware|firmware file.*not found|download.*firmware.*failed|failed to download.*firmware|timeout waiting for firmware|firmware.*load.*failed}"
 
    # Retry/transient hints.
    transient_re="${BTFW_TRANSIENT_RE:-Retry BT power ON|retry bt power on|reset|re-init|reinit|failed.*[(]-110[)]}"
 
    # ---- Collect recent relevant current-boot kernel log ----
    if command -v get_kernel_log >/dev/null 2>&1; then
        out="$(
            get_kernel_log 2>/dev/null \
            | grep -i -E 'Bluetooth|hci[0-9]|QCA|wcn|btqca|WCN' \
            | tail -n "${BTFW_DMESG_TAIL:-600}"
        )"
    else
        out="$(
            dmesg 2>/dev/null \
            | grep -i -E 'Bluetooth|hci[0-9]|QCA|wcn|btqca|WCN' \
            | tail -n "${BTFW_DMESG_TAIL:-600}"
        )"
    fi
 
    if [ -z "$out" ]; then
        log_warn "btfwloaded: no Bluetooth/QCA/WCN messages found in current-boot kernel log."
        return 1
    fi
 
    # If caller provided hciN, evaluate firmware markers for that adapter only.
    # This avoids hci0 UART timeout noise causing a warning/failure when hci1 USB
    # is the selected working controller.
    if [ -n "$adapter" ]; then
        adapter_out="$(
            printf '%s\n' "$out" \
            | grep -i -E "Bluetooth:[[:space:]]+${adapter}:|${adapter}:"
        )"
 
        if [ -n "$adapter_out" ]; then
            out="$adapter_out"
            log_info "btfwloaded: evaluating firmware log for selected adapter $adapter"
        else
            log_warn "btfwloaded: no adapter-specific kernel log found for $adapter; falling back to global BT log"
        fi
    fi
 
    # ---- Find last success line number and last fatal line number ----
    last_success="$(
        printf '%s\n' "$out" \
        | awk -v IGNORECASE=1 -v re="$success_re" '
            $0 ~ re { n=NR }
            END { if (n > 0) print n; else print 0 }
        '
    )"
 
    last_fatal="$(
        printf '%s\n' "$out" \
        | awk -v IGNORECASE=1 -v re="$fatal_re" '
            $0 ~ re { n=NR }
            END { if (n > 0) print n; else print 0 }
        '
    )"
 
    saw_transient="$(
        printf '%s\n' "$out" \
        | awk -v IGNORECASE=1 -v re="$transient_re" '
            $0 ~ re { found=1; exit }
            END { if (found) print 1; else print 0 }
        '
    )"
 
    # ---- Decision tree ----
    if [ "$last_success" -eq 0 ]; then
        log_warn "btfwloaded: no firmware success marker found${adapter:+ for $adapter} (pattern: $success_re). Recent kernel-log tail:"
        printf '%s\n' "$out" | tail -n 30 >&2
        return 1
    fi
 
    # Fatal after success => FAIL only within the selected adapter scope.
    if [ "$last_fatal" -gt "$last_success" ]; then
        log_warn "btfwloaded: fatal BT/QCA errors occurred after firmware success marker${adapter:+ for $adapter}, treating as FAIL."
        printf '%s\n' "$out" | tail -n 40 >&2
        return 1
    fi
 
    # Fatal before success OR transient hints => WARN.
    if [ "$last_fatal" -gt 0 ] && [ "$last_fatal" -lt "$last_success" ]; then
        log_warn "btfwloaded: transient errors occurred before firmware success marker${adapter:+ for $adapter}, treating as WARN."
        printf '%s\n' "$out" | tail -n 30 >&2
        return 2
    fi
 
    if [ "$saw_transient" -eq 1 ]; then
        log_warn "btfwloaded: retry/transient indicators seen in kernel log${adapter:+ for $adapter}, firmware success marker present, treating as WARN."
        printf '%s\n' "$out" | tail -n 30 >&2
        return 2
    fi
 
    log_info "btfwloaded: firmware load/setup completed cleanly${adapter:+ for $adapter} from current-boot kernel log."
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

# Return success if adapter has a valid non-zero BD address.
#
# Usage:
#   btbdok hci0
#
# Returns:
#   0 = BD address is present and not all zeros
#   1 = missing, invalid, or all zeros
btbdok() {
    dev="${1:-}"
    addr=""

    addr="$(btgetbdaddr "$dev" 2>/dev/null || true)"
    [ -n "$addr" ]
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
        
	devices_out="$(bt_list_devices_raw || true)"
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

    saw_yes=0
    saw_unknown=0

    i=0
    while [ "$i" -lt "$attempts" ]; do
        disc_state="$(bt_is_discovering 2>/dev/null || printf '%s\n' "unknown")"
        log_info "Discovering state during scan OFF (iteration $((i + 1))/$attempts): $disc_state"

        if [ "$disc_state" = "no" ]; then
            return 0
        fi
        if [ "$disc_state" = "yes" ]; then
            saw_yes=1
        fi
        if [ "$disc_state" = "unknown" ]; then
            saw_unknown=1
        fi

        i=$((i + 1))
        sleep "$step_secs"
    done

    # Small tweak:
    # If we never saw Discovering=yes and state reporting is always unknown (common on minimal/ramdisk),
    # treat scan-off as best-effort success to avoid flakiness/noisy warnings.
    if [ "$saw_unknown" -eq 1 ] && [ "$saw_yes" -eq 0 ]; then
        log_warn "Discovering state stayed 'unknown' during scan OFF polling; treating scan-off as best-effort success."
        return 0
    fi

    log_warn "Discovering did not settle to 'no' within scan OFF polling window."
    return 1
}

# Return BD address for a given HCI adapter using sysfs or hciconfig.
# Prints empty output if the adapter is missing or address cannot be parsed.
bt_hci_bdaddr() {
    adapter="$1"

    [ -n "$adapter" ] || return 1

    btgetbdaddr "$adapter"
}

# Check whether an HCI adapter is usable for BT_ON_OFF.
# Requires a non-zero BD address. When hciconfig is available, retain its
# UP/RUNNING check. Otherwise use BlueZ controller visibility as the runtime
# state evidence. Returns 0 when usable and 1 otherwise, with no output or
# runtime state changes.
bt_adapter_is_usable() {
    adapter="$1"
    out=""

    [ -n "$adapter" ] || return 1

    if ! btbdok "$adapter"; then
        return 1
    fi

    if command -v hciconfig >/dev/null 2>&1; then
        out="$(hciconfig "$adapter" 2>/dev/null || true)"
        if printf '%s\n' "$out" | grep -q 'UP RUNNING'; then
            return 0
        fi

        return 1
    fi

    btcontrollervisible "$adapter"
}

# Select the best available Bluetooth adapter.
# Prefer UP/RUNNING + non-zero BD address, then fallback to non-zero BD only.
bt_select_usable_adapter() {
    adapters=""
    adapter=""
    addr=""

    if command -v hciconfig >/dev/null 2>&1; then
        adapters="$(hciconfig 2>/dev/null | awk -F: '/^hci[0-9]+:/ { print $1 }')"

        for adapter in $adapters; do
            if bt_adapter_is_usable "$adapter"; then
                printf '%s\n' "$adapter"
                return 0
            fi
        done

        for adapter in $adapters; do
            addr="$(bt_hci_bdaddr "$adapter" 2>/dev/null || true)"
            case "$addr" in
                ""|"00:00:00:00:00:00")
                    continue
                    ;;
                *)
                    printf '%s\n' "$adapter"
                    return 0
                    ;;
            esac
        done
    fi

    if command -v findhcisysfs >/dev/null 2>&1; then
        findhcisysfs 2>/dev/null || true
        return 0
    fi

    return 1
}

# Log all HCI candidates with address/state details for CI/LAVA debug.
# This helps explain why one adapter was selected or ignored.
bt_log_hci_candidates() {
    adapters=""
    adapter=""
    out=""
    addr=""
    state=""
    usable="no"

    if ! command -v hciconfig >/dev/null 2>&1; then
        log_info "Optional hciconfig is unavailable, using sysfs and BlueZ adapter evidence"
        return 0
    fi

    adapters="$(hciconfig 2>/dev/null | awk -F: '/^hci[0-9]+:/ { print $1 }')"
    if [ -z "$adapters" ]; then
        log_warn "No HCI adapters reported by hciconfig."
        return 0
    fi

    for adapter in $adapters; do
        out="$(hciconfig "$adapter" 2>/dev/null || true)"
        addr="$(bt_hci_bdaddr "$adapter" 2>/dev/null || true)"
        state="$(printf '%s\n' "$out" | awk '/UP|DOWN|RUNNING/ {
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }')"

        [ -n "$addr" ] || addr="unknown"
        [ -n "$state" ] || state="unknown"

        usable="no"
        if bt_adapter_is_usable "$adapter"; then
            usable="yes"
        fi

        log_info "[bt-adapter] $adapter addr=$addr state='$state' usable=$usable"
    done
}
