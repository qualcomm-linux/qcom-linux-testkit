#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# --- Logging helpers ---
log() {
    level=$1
    shift
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}
log_info()  { log "INFO"  "$@"; }
log_pass()  { log "PASS"  "$@"; }
log_fail()  { log "FAIL"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_skip()  { log "SKIP"  "$@"; }
log_warn()  { log "WARN"  "$@"; }

# --- Kernel Log Collection ---
get_kernel_log() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -k -b
    elif command -v dmesg >/dev/null 2>&1; then
        dmesg
    elif [ -f /var/log/kern.log ]; then
        cat /var/log/kern.log
    else
        log_warn "No kernel log source found"
        return 1
    fi
}

# Locate a kernel module (.ko) file by name
# Tries to find it under current kernel version first, then all module trees
find_kernel_module() {
    module_name="$1"
    kver=$(uname -r)

    # Attempt to find module under the currently running kernel
    module_path=$(find "/lib/modules/$kver" -name "${module_name}.ko" 2>/dev/null | head -n 1)

    # If not found, search all available module directories
    if [ -z "$module_path" ]; then
        log_warn "Module not found under /lib/modules/$kver, falling back to full search in /lib/modules/"
        module_path=$(find /lib/modules/ -name "${module_name}.ko" 2>/dev/null | head -n 1)

        # Warn if found outside current kernel version
        if [ -n "$module_path" ]; then
            found_version=$(echo "$module_path" | cut -d'/' -f4)
            if [ "$found_version" != "$kver" ]; then
                log_warn "Found ${module_name}.ko under $found_version, not under current kernel ($kver)"
            fi
        fi
    fi
    echo "$module_path"
}

# Check if a kernel module is currently loaded
is_module_loaded() {
    module_name="$1"
    /sbin/lsmod | awk '{print $1}' | grep -q "^${module_name}$"
}

# Insert a kernel module with optional parameters
load_kernel_module() {
    module_path="$1"
    shift
    params="$*"

    module_name=$(basename "$module_path" .ko)

    if is_module_loaded "$module_name"; then
        log_info "Module $module_name is already loaded"
        return 0
    fi

    if [ ! -f "$module_path" ]; then
        log_error "Module file not found: $module_path"
        return 1
    fi

    log_info "Loading module: $module_path $params"
    if /sbin/insmod "$module_path" "$params" 2>insmod_err.log; then
        log_info "Module $module_name loaded successfully"
        return 0
    else
        log_error "insmod failed: $(cat insmod_err.log)"
        return 1
    fi
}

# Remove a kernel module by name with optional forced removal
unload_kernel_module() {
    module_name="$1"
    force="$2"

    if ! is_module_loaded "$module_name"; then
        log_info "Module $module_name is not loaded, skipping unload"
        return 0
    fi

    log_info "Attempting to remove module: $module_name"
    if /sbin/rmmod "$module_name" 2>rmmod_err.log; then
        log_info "Module $module_name removed via rmmod"
        return 0
    fi

    log_warn "rmmod failed: $(cat rmmod_err.log)"
    log_info "Trying modprobe -r as fallback"
    if /sbin/modprobe -r "$module_name" 2>modprobe_err.log; then
        log_info "Module $module_name removed via modprobe"
        return 0
    fi

    log_warn "modprobe -r failed: $(cat modprobe_err.log)"

    if [ "$force" = "true" ]; then
        log_warn "Trying forced rmmod: $module_name"
        if /sbin/rmmod -f "$module_name" 2>>rmmod_err.log; then
            log_info "Module $module_name force removed"
            return 0
        else
            log_error "Forced rmmod failed: $(cat rmmod_err.log)"
            return 1
        fi
    fi

    log_error "Unable to unload module: $module_name"
    return 1
}

# --- Dependency check ---
check_dependencies() {
    missing=0
    missing_cmds=""
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_warn "Required command '$cmd' not found in PATH."
            missing=1
            missing_cmds="$missing_cmds $cmd"
        fi
    done
    if [ "$missing" -ne 0 ]; then
        testname="${TESTNAME:-}"
        log_skip "${testname:-UnknownTest} SKIP: missing dependencies:$missing_cmds"
        if [ -n "$testname" ]; then
            echo "$testname SKIP" > "./$testname.res"
        fi
        exit 0
    fi
}

# --- Test case directory lookup ---
find_test_case_by_name() {
    test_name=$1
    base_dir="${__RUNNER_SUITES_DIR:-$ROOT_DIR/suites}"
    # Only search under the SUITES directory!
    testpath=$(find "$base_dir" -type d -iname "$test_name" -print -quit 2>/dev/null)
    echo "$testpath"
}

find_test_case_bin_by_name() {
    test_name=$1
    base_dir="${__RUNNER_UTILS_BIN_DIR:-$ROOT_DIR/common}"
    find "$base_dir" -type f -iname "$test_name" -print -quit 2>/dev/null
}

find_test_case_script_by_name() {
    test_name=$1
    base_dir="${__RUNNER_UTILS_BIN_DIR:-$ROOT_DIR/common}"
    find "$base_dir" -type d -iname "$test_name" -print -quit 2>/dev/null
}

check_kernel_config() {
    configs="$1"
    for config_key in $configs; do
        if zcat /proc/config.gz | grep -qE "^$config_key=(y|m)"; then
            log_pass "Kernel config $config_key is enabled"
        else
            log_fail "Kernel config $config_key is missing or not enabled"
            return 1
        fi
    done
    return 0
}

check_dt_nodes() {
    node_paths="$1"
    log_info "$node_paths"
    found=false
    for node in $node_paths; do
        log_info "$node"
        if [ -d "$node" ] || [ -f "$node" ]; then
            log_pass "Device tree node exists: $node"
            found=true
        fi
    done
 
    if [ "$found" = true ]; then
        return 0
    else
        log_fail "Device tree node(s) missing: $node_paths"
        return 1
    fi
}

check_driver_loaded() {
    drivers="$1"
    for driver in $drivers; do
        if [ -z "$driver" ]; then
            log_fail "No driver/module name provided to check_driver_loaded"
            return 1
        fi
        if grep -qw "$driver" /proc/modules || lsmod | awk '{print $1}' | grep -qw "$driver"; then
            log_pass "Driver/module '$driver' is loaded"
            return 0
        else
            log_fail "Driver/module '$driver' is not loaded"
            return 1
        fi
    done
}

# --- Optional: POSIX-safe repo root detector ---
detect_runner_root() {
    path=$1
    while [ "$path" != "/" ]; do
        if [ -d "$path/suites" ]; then
            echo "$path"
            return
        fi
        path=$(dirname "$path")
    done
    echo ""
}

# ----------------------------
# Additional Utility Functions
# ----------------------------
# Function is to check for network connectivity status
check_network_status() {
    echo "[INFO] Checking network connectivity..."

    # Get first active IPv4 address (excluding loopback)
    ip_addr=$(ip -4 addr show scope global up | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

    if [ -n "$ip_addr" ]; then
        echo "[PASS] Network is active. IP address: $ip_addr"

        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "[PASS] Internet is reachable."
            return 0
        else
            echo "[WARN] Network active but no internet access."
            return 2
        fi
    else
        echo "[FAIL] No active network interface found."
        return 1
    fi
}

# If the tar file already exists,then function exit. Otherwise function to check the network connectivity and it will download tar from internet.
extract_tar_from_url() {
    url=$1
    filename=$(basename "$url")

    check_tar_file "$url"
    status=$?
    if [ "$status" -eq 0 ]; then
        log_info "Already extracted. Skipping download."
        return 0
    elif [ "$status" -eq 1 ]; then
        log_info "File missing or invalid. Will download and extract."
        check_network_status || return 1
        log_info "Downloading $url..."
        wget -O "$filename" "$url" || {
            log_fail "Failed to download $filename"
            return 1
        }
        log_info "Extracting $filename..."
        tar -xvf "$filename" || {
            log_fail "Failed to extract $filename"
            return 1
        }
    elif [ "$status" -eq 2 ]; then
        log_info "File exists and is valid, but not yet extracted. Proceeding to extract."
        tar -xvf "$filename" || {
            log_fail "Failed to extract $filename"
            return 1
        }
    fi

    # Optionally, check that extraction succeeded
    first_entry=$(tar -tf "$filename" 2>/dev/null | head -n1 | cut -d/ -f1)
    if [ -n "$first_entry" ] && [ -e "$first_entry" ]; then
        log_pass "Files extracted successfully ($first_entry exists)."
        return 0
    else
        log_fail "Extraction did not create expected entry: $first_entry"
        return 1
    fi
}

# Function to check if a tar file exists
check_tar_file() {
    url=$1
    filename=$(basename "$url")

    # 1. Check file exists
    if [ ! -f "$filename" ]; then
        log_error "File $filename does not exist."
        return 1
    fi

    # 2. Check file is non-empty
    if [ ! -s "$filename" ]; then
        log_error "File $filename exists but is empty."
        return 1
    fi

    # 3. Check file is a valid tar archive
    if ! tar -tf "$filename" >/dev/null 2>&1; then
        log_error "File $filename is not a valid tar archive."
        return 1
    fi

    # 4. Check if already extracted: does the first entry in the tar exist?
    first_entry=$(tar -tf "$filename" 2>/dev/null | head -n1 | cut -d/ -f1)
    if [ -n "$first_entry" ] && [ -e "$first_entry" ]; then
        log_pass "$filename has already been extracted ($first_entry exists)."
        return 0
    fi

    log_info "$filename exists and is valid, but not yet extracted."
    return 2
}

# Check if weston is running
weston_is_running() {
    pgrep -x weston >/dev/null 2>&1
}

# Stop all Weston processes
weston_stop() {
    if weston_is_running; then
        log_info "Stopping Weston..."
        pkill -x weston
        for i in $(seq 1 10); do
			log_info "Waiting for Weston to stop with $i attempt "
            if ! weston_is_running; then
                log_info "Weston stopped successfully"
                return 0
            fi
            sleep 1
        done
        log_error "Failed to stop Weston after waiting."
        return 1
    else
        log_info "Weston is not running."
    fi
    return 0
}

# Start weston with correct env if not running
weston_start() {
    export XDG_RUNTIME_DIR="/dev/socket/weston"
    mkdir -p "$XDG_RUNTIME_DIR"

    # Remove stale Weston socket if it exists
    if [ -S "$XDG_RUNTIME_DIR/weston" ]; then
        log_info "Removing stale Weston socket."
        rm -f "$XDG_RUNTIME_DIR/weston"
    fi

    if weston_is_running; then
        log_info "Weston already running."
        return 0
    fi
    # Clean up stale sockets for wayland-0 (optional)
    [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && rm -f "$XDG_RUNTIME_DIR/wayland-1"
    nohup weston --continue-without-input --idle-time=0 > weston.log 2>&1 &
    sleep 3

    if weston_is_running; then
        log_info "Weston started."
        return 0
    else
        log_error "Failed to start Weston."
        return 1
    fi
}

# Returns true (0) if interface is administratively and physically up
is_interface_up() {
    iface="$1"
    if [ -f "/sys/class/net/$iface/operstate" ]; then
        [ "$(cat "/sys/class/net/$iface/operstate")" = "up" ]
    elif command -v ip >/dev/null 2>&1; then
        ip link show "$iface" 2>/dev/null | grep -qw "state UP"
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$iface" 2>/dev/null | grep -qw "UP"
    else
        return 1
    fi
}

# Returns true (0) if physical link/carrier is detected (cable plugged in)
is_link_up() {
    iface="$1"
    [ -f "/sys/class/net/$iface/carrier" ] && [ "$(cat "/sys/class/net/$iface/carrier")" = "1" ]
}

# Returns true (0) if interface is Ethernet type (type 1 in sysfs)
is_ethernet_interface() {
    iface="$1"
    [ -f "/sys/class/net/$iface/type" ] && [ "$(cat "/sys/class/net/$iface/type")" = "1" ]
}

# Get all Ethernet interfaces (excluding common virtual types)
get_ethernet_interfaces() {
    for path in /sys/class/net/*; do
        iface=$(basename "$path")
        case "$iface" in
            lo|docker*|br-*|veth*|virbr*|tap*|tun*|wl*) continue ;;
        esac
        if is_ethernet_interface "$iface"; then
            echo "$iface"
        fi
    done
}

# Bring up interface with retries (down before up).
bringup_interface() {
    iface="$1"; retries="${2:-3}"; sleep_sec="${3:-2}"; i=0
    while [ $i -lt "$retries" ]; do
        if command -v ip >/dev/null 2>&1; then
            ip link set "$iface" down
            sleep 1
            ip link set "$iface" up
            sleep "$sleep_sec"
            ip link show "$iface" | grep -q "state UP" && return 0
        elif command -v ifconfig >/dev/null 2>&1; then
            ifconfig "$iface" down
            sleep 1
            ifconfig "$iface" up
            sleep "$sleep_sec"
            ifconfig "$iface" | grep -q "UP" && return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# Wait for a valid IPv4 address on the given interface, up to a timeout (default 30s)
wait_for_ip_address() {
    iface="$1"
    timeout="${2:-30}"
    elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        ip_addr=$(get_ip_address "$iface")
        if [ -n "$ip_addr" ]; then
            if echo "$ip_addr" | grep -q '^169\.254'; then
                echo "$ip_addr"
                return 2
            fi
            echo "$ip_addr"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# Get the IPv4 address for a given interface.
get_ip_address() {
    iface="$1"
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show "$iface" | awk '{print $4}' | cut -d/ -f1 | head -n1
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -n1
    fi
}

# Run a command with a timeout (in seconds)
run_with_timeout() {
    timeout="$1"; shift
    ( "$@" ) &
    pid=$!
    ( sleep "$timeout"; kill "$pid" 2>/dev/null ) &
    watcher=$!
    wait $pid 2>/dev/null
    status=$?
    kill $watcher 2>/dev/null
    return $status
}

# DHCP client logic (dhclient and udhcpc with timeouts)
run_dhcp_client() {
    iface="$1"
    timeout="${2:-10}"
    ip_addr=""
    log_info "Attempting DHCP on $iface (timeout ${timeout}s)..."
    if command -v dhclient >/dev/null 2>&1; then
        log_info "Trying dhclient for $iface"
        run_with_timeout "$timeout" dhclient "$iface"
        ip_addr=$(wait_for_ip_address "$iface" 5)
        if [ -n "$ip_addr" ]; then
            echo "$ip_addr"
            return 0
        fi
    fi
    if command -v udhcpc >/dev/null 2>&1; then
        log_info "Trying udhcpc for $iface"
        run_with_timeout "$timeout" udhcpc -i "$iface" -T 3 -t 3
        ip_addr=$(wait_for_ip_address "$iface" 5)
        if [ -n "$ip_addr" ]; then
            echo "$ip_addr"
            return 0
        fi
    fi
    log_warn "DHCP failed for $iface"
    return 1
}

# Safely run DHCP client without disrupting existing config
try_dhcp_client_safe() {
    iface="$1"
    timeout="${2:-10}"

    current_ip=$(get_ip_address "$iface")
    if [ -n "$current_ip" ] && ! echo "$current_ip" | grep -q '^169\.254'; then
        log_info "$iface already has valid IP: $current_ip. Skipping DHCP."
        return 0
    fi

    if ! command -v udhcpc >/dev/null 2>&1; then
        log_warn "udhcpc not found, skipping DHCP attempt"
        return 1
    fi

    # Use a no-op script to avoid flushing IPs
    safe_dhcp_script="/tmp/dhcp-noop-$$.sh"
    cat <<'EOF' > "$safe_dhcp_script"
#!/bin/sh
exit 0
EOF
    chmod +x "$safe_dhcp_script"

    log_info "Attempting DHCP on $iface safely..."
    (udhcpc -i "$iface" -n -q -s "$safe_dhcp_script" >/dev/null 2>&1) &
    dhcp_pid=$!
    sleep "$timeout"
    kill "$dhcp_pid" 2>/dev/null
    rm -f "$safe_dhcp_script"
    return 0
}

# Remove paired BT device by MAC
bt_cleanup_paired_device() {
    mac="$1"
    expect <<EOF > /dev/null 2>&1
log_user 0
spawn bluetoothctl
expect "#" { send "remove $mac\r" }
expect "#" { send "quit\r" }
EOF
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
                ""|\#*) continue ;;  # Skip blank lines and comments
                *) WHITELIST_ENTRIES="${WHITELIST_ENTRIES}${line}
" ;;
            esac
        done < "$1"
    fi
}

# bt_in_whitelist <mac> <name>
# Checks if a given device (MAC and optional name) exists
# Returns:
#     0 (success) if found
#     1 (failure) if not found
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

# bt_scan_devices
# Attempts to detect nearby Bluetooth devices using:
#   1. hcitool scan
#   2. fallback: bluetoothctl scan (via expect)
# Returns:
#   0 - if devices found
#   1 - if no devices found or error
bt_scan_devices() {
    timestamp=$(date '+%Y%m%d_%H%M%S')
    scan_log="scan_${timestamp}.log"
    found_log="found_devices_${timestamp}.log"
    : > "$scan_log"
    : > "$found_log"

    log_info "Detecting Bluetooth adapter..."
    hcidev=$(hciconfig | awk '/^hci/ { print $1 }' | head -n1)
    if [ -z "$hcidev" ]; then
        log_error "No Bluetooth adapter found"
        return 1
    fi

    log_info "Using Bluetooth adapter: $hcidev"
    hciconfig "$hcidev" up

    log_info "Running Bluetooth scan via hcitool..."
    if hcitool -i "$hcidev" scan > hcitool_scan.tmp 2>/dev/null; then
        tail -n +2 hcitool_scan.tmp | awk '{ printf "%s %s\n", $1, $2}' > "$found_log"
        rm -f hcitool_scan.tmp
        [ -s "$found_log" ] && return 0
    fi

    log_warn "hcitool scan returned nothing. Falling back to bluetoothctl scan..."
    expect <<EOF > "$scan_log"
log_user 0
spawn bluetoothctl
expect "#" { send "power on\r" }
expect "#" { send "agent NoInputNoOutput\r" }
expect "#" { send "default-agent\r" }
expect "#" { send "scan on\r" }
sleep 10
send "scan off\r"
expect "#" { send "quit\r" }
EOF

    grep -E "^\s*\[NEW\] Device" "$scan_log" | awk '{ print $4, substr($0, index($0, $5)) }' > "$found_log"
    if [ ! -s "$found_log" ]; then
        log_warn "Scan log is empty. Possible issue with bluetoothctl or adapter."
        return 1
    fi

    return 0
}

# Pair with Bluetooth device using MAC (with retries and timestamped logs)
bt_pair_with_mac() {
    bt_mac="$1"
    max_retries=3
    retry=1

    while [ "$retry" -le "$max_retries" ]; do
        log_info "Attempt $retry: Pairing with $bt_mac using bluetoothctl"

        timestamp=$(date '+%Y%m%d_%H%M%S')
        sanitized_mac=$(echo "$bt_mac" | sed 's/:/_/g')
        logfile="pairing_attempt_${sanitized_mac}_${timestamp}.log"

        expect <<EOF | tee -a "$logfile"
log_user 1
set timeout 30

spawn bluetoothctl
expect {
    -re {.*[#>]} { send "power on\r" }
}
expect {
    -re {.*[#>]} { send "remove $bt_mac\r" }
}
expect {
    -re {.*[#>]} { send "scan on\r" }
}
sleep 5
expect {
    -re {.*[#>]} { send "scan off\r" }
}
expect {
    -re {.*[#>]} { send "agent KeyboardOnly\r" }
}
expect {
    -re {.*[#>]} { send "default-agent\r" }
}
expect {
    -re {.*[#>]} { send "pair $bt_mac\r" }
}
expect {
    -re {.*Confirm passkey.*yes/no.*} {
        send "yes\r"
        exp_continue
    }
    -re {.*Paired: yes.*} {
        send "quit\r"
        exit 0
    }
    -re {.*Pairing successful.*} {
        send "quit\r"
        exit 0
    }
    -re {.*Failed to pair.*} {
        send "quit\r"
        exit 1
    }
    -re {.*Device $bt_mac not available.*} {
        send "quit\r"
        exit 2
    }
    timeout {
        send "quit\r"
        exit 3
    }
}
EOF

        result=$?
        case "$result" in
            0)
                log_pass "Pairing successful with $bt_mac"
                return 0
                ;;
            1|3)
                log_warn "Pairing attempt $retry failed for $bt_mac. Retrying after unpairing again..."
                bt_cleanup_paired_device "$bt_mac"
                ;;
            2)
                log_warn "Device $bt_mac not available. Check proximity and power."
                ;;
            *)
                log_warn "Unexpected pairing error code: $result"
                ;;
        esac

        retry=$((retry + 1))
        sleep 2
    done

    log_fail "Pairing failed after $max_retries attempts for $bt_mac"
    return 1
}

# Post-pairing connection test with bluetoothctl and l2ping fallback
bt_post_pair_connect() {
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
log_user 0
set timeout 10
spawn bluetoothctl
expect {
    -re ".*#.*" {}
}
send "connect $target_mac\r"
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

    log_info "Falling back to l2ping to trigger Bluetooth link with $target_mac"
    if command -v l2ping >/dev/null 2>&1; then
        if l2ping -c 3 -t 5 "$target_mac" >>"${base_logfile}_l2ping.log" 2>&1; then
            if bluetoothctl info "$target_mac" | grep -q "Connected: yes"; then
                log_pass "Fallback l2ping worked - device is now connected"
                return 0
            fi
        else
            log_warn "l2ping failed or no response"
        fi
    else
        log_warn "l2ping not available - skipping fallback"
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

# Scan and pair (dynamic adapter, timestamped logs)
bt_scan_and_pair() {
    target_name="$1"
    target_mac="$2"
    scan_attempts=3
    found=0
    timestamp=$(date '+%Y%m%d_%H%M%S')
    scan_log="scan_${timestamp}.log"
    found_log="found_devices_${timestamp}.log"
    : > "$scan_log"
    : > "$found_log"

    log_info "Detecting Bluetooth adapter..."
    hcidev=$(hciconfig | awk '/^hci/ { print $1 }' | head -n1)
    if [ -z "$hcidev" ]; then
        log_error "No Bluetooth adapter found"
        return 1
    fi
    log_info "Using Bluetooth adapter: $hcidev"
    hciconfig "$hcidev" up

    log_info "Checking for connected devices..."
    for mac in $(bluetoothctl paired-devices | awk '{print $2}'); do
        if bluetoothctl info "$mac" | grep -q "Connected: yes"; then
            log_info "Disconnecting $mac..."
            bluetoothctl disconnect "$mac" >/dev/null 2>&1
        fi
    done

    i=1
    while [ "$i" -le "$scan_attempts" ]; do
        log_info "Scan attempt $i of $scan_attempts..."
        expect <<EOF > "$scan_log"
log_user 0
spawn bluetoothctl
expect "#" { send "power on\r" }
expect "#" { send "agent NoInputNoOutput\r" }
expect "#" { send "default-agent\r" }
expect "#" { send "scan on\r" }
sleep 20
send "scan off\r"
expect "#" { send "quit\r" }
EOF

        grep -iE 'Device ([0-9A-F]{2}:){5}[0-9A-F]{2}' "$scan_log" | awk '{print $2, $3}' > "$found_log"

        if grep -q "$target_mac" "$found_log"; then
            found=1
            break
        fi
        i=$((i + 1))
    done

    if [ "$found" -ne 1 ]; then
        log_warn "Device $target_mac ($target_name) not found after $scan_attempts attempts"
        return 1
    fi

    log_info "Device $target_mac found. Proceeding to pair..."

    if bluetoothctl paired-devices | grep -q "$target_mac"; then
        log_info "Device $target_mac is already paired. Unpairing..."
        bluetoothctl remove "$target_mac" >/dev/null 2>&1
        sleep 1
    fi

    i=1
    while [ "$i" -le 3 ]; do
        log_info "Pairing attempt $i..."
        if expect <<EOF
log_user 1
spawn bluetoothctl
expect "#" { send "agent KeyboardOnly\r" }
expect "#" { send "default-agent\r" }
expect "#" { send "pair $target_mac\r" }
expect {
    "Pairing successful" { send "quit\r"; exit 0 }
    "Failed to pair" { send "quit\r"; exit 1 }
    timeout { exit 1 }
}
EOF
        then
            log_pass "Pairing successful with $target_mac"
            return 0
        fi
        log_warn "Pairing failed attempt $i/3..."
        i=$((i + 1))
        sleep 1
    done

    log_fail "Pairing failed after 3 attempts"
    return 1
}

# Select Bluetooth target device from scanned results based on name and/or MAC and whitelist
select_bt_target_device() {
    found_log="$1"
    bt_name="$2"
    bt_mac="$3"
    whitelist="$4"
    result_mac=""

    while IFS= read -r line; do
        mac=$(echo "$line" | awk '{ print $1 }')
        name=$(echo "$line" | cut -d' ' -f2-)

        log_info "Parsed: MAC=$mac NAME=$name"

        if [ -n "$whitelist" ]; then
            log_info "Debug: WHITELIST entry='$whitelist'"
            if [ "$mac" != "$whitelist" ]; then
                continue
            fi
        fi

        if [ -n "$bt_mac" ]; then
            if [ "$mac" = "$bt_mac" ]; then
                log_info "MAC matched WHITELIST and target: $mac"
                result_mac="$mac"
                break
            fi
        elif [ "$name" = "$bt_name" ]; then
            log_info "Name match found and MAC in whitelist: $name ($mac)"
            result_mac="$mac"
            break
        fi
    done < "$found_log"

    [ -n "$result_mac" ] && echo "$result_mac" && return 0
    return 1
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

    log_info "Running l2ping test for $target_mac"
    if l2ping -c 3 -t 5 "$target_mac" >>"$logfile" 2>&1; then
        log_pass "l2ping to $target_mac succeeded"
        return 0
    else
        log_warn "l2ping to $target_mac failed"
        return 1
    fi
}
# Find remoteproc path by firmware substring
get_remoteproc_path_by_firmware() {
    name="$1"
    idx=""
    path=""
    idx=$(cat /sys/class/remoteproc/remoteproc*/firmware 2>/dev/null | grep -n "$name" | cut -d: -f1 | head -n1)
    [ -z "$idx" ] && return 1
    idx=$((idx - 1))
    path="/sys/class/remoteproc/remoteproc${idx}"
    [ -d "$path" ] && echo "$path" && return 0
    return 1
}

# Get remoteproc state
get_remoteproc_state() {
    rproc_path="$1"
    [ -f "$rproc_path/state" ] && cat "$rproc_path/state"
}

# Wait for a remoteproc to reach a specific state
wait_remoteproc_state() {
    rproc_path="$1"
    target="$2"
    retries="${3:-6}"
    i=0
    while [ $i -lt "$retries" ]; do
        state=$(get_remoteproc_state "$rproc_path")
        [ "$state" = "$target" ] && return 0
        sleep 1
        i=$((i+1))
    done
    return 1
}

# Stop remoteproc
stop_remoteproc() {
    rproc_path="$1"
    echo stop > "$rproc_path/state"
    wait_remoteproc_state "$rproc_path" "offline" 6
}

# Start remoteproc
start_remoteproc() {
    rproc_path="$1"
    echo start > "$rproc_path/state"
    wait_remoteproc_state "$rproc_path" "running" 6
}

# Validate remoteproc running state with retries and logging
validate_remoteproc_running() {
    fw_name="$1"
    log_file="${2:-/dev/null}"
    max_wait_secs="${3:-10}"
    delay_per_try_secs="${4:-1}"

    rproc_path=$(get_remoteproc_path_by_firmware "$fw_name")
    if [ -z "$rproc_path" ]; then
        echo "[ERROR] Remoteproc for '$fw_name' not found" >> "$log_file"
        {
            echo "---- Last 20 remoteproc dmesg logs ----"
            dmesg | grep -i "remoteproc" | tail -n 20
            echo "----------------------------------------"
        } >> "$log_file"
        return 1
    fi

    total_waited=0
    while [ "$total_waited" -lt "$max_wait_secs" ]; do
        state=$(get_remoteproc_state "$rproc_path")
        if [ "$state" = "running" ]; then
            return 0
        fi
        sleep "$delay_per_try_secs"
        total_waited=$((total_waited + delay_per_try_secs))
    done

    echo "[ERROR] $fw_name remoteproc did not reach 'running' state within ${max_wait_secs}s (last state: $state)" >> "$log_file"
    {
        echo "---- Last 20 remoteproc dmesg logs ----"
        dmesg | grep -i "remoteproc" | tail -n 20
        echo "----------------------------------------"
    } >> "$log_file"
    return 1
}

# Clean up WiFi test environment (reusable for other tests)
wifi_cleanup() {
    iface="$1"
    log_info "Cleaning up WiFi test environment..."
    killall -q wpa_supplicant 2>/dev/null
    rm -f /tmp/wpa_supplicant.conf nmcli.log wpa.log
    if [ -n "$iface" ]; then
        ip link set "$iface" down 2>/dev/null || ifconfig "$iface" down 2>/dev/null
    fi
}

# Extract credentials from args/env/file
get_wifi_credentials() {
    ssid="$1"
    pass="$2"
    if [ -z "$ssid" ] || [ -z "$pass" ]; then
        ssid="${SSID:-$ssid}"
        pass="${PASSWORD:-$pass}"
    fi
    if [ -z "$ssid" ] || [ -z "$pass" ]; then
        if [ -f "./ssid_list.txt" ]; then
            read -r ssid pass _ < ./ssid_list.txt
        fi
    fi
    ssid=$(echo "$ssid" | xargs)
    pass=$(echo "$pass" | xargs)
    if [ -z "$ssid" ] || [ -z "$pass" ]; then
        return 1
    fi
    printf '%s %s\n' "$ssid" "$pass"
    return 0
}

# POSIX-compliant: Retry a shell command up to N times with delay
retry_command() {
    cmd="$1"
    retries="$2"
    delay="$3"
    i=1
    while [ "$i" -le "$retries" ]; do
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Attempt $i/$retries failed: $cmd"
        i=$((i + 1))
        sleep "$delay"
    done
    return 1
}

# Connect using nmcli with retries (returns 0 on success)
wifi_connect_nmcli() {
    iface="$1"
    ssid="$2"
    pass="$3"
    if command -v nmcli >/dev/null 2>&1; then
        log_info "Trying to connect using nmcli..."
        retry_command "nmcli dev wifi connect \"$ssid\" password \"$pass\" ifname \"$iface\" 2>&1 | tee nmcli.log" 3 3
        return $?
    fi
    return 1
}

# Connect using wpa_supplicant+udhcpc with retries (returns 0 on success)
wifi_connect_wpa_supplicant() {
    iface="$1"
    ssid="$2"
    pass="$3"
    if command -v wpa_supplicant >/dev/null 2>&1 && command -v udhcpc >/dev/null 2>&1; then
        log_info "Falling back to wpa_supplicant + udhcpc"
        WPA_CONF="/tmp/wpa_supplicant.conf"
        {
            echo "ctrl_interface=/var/run/wpa_supplicant"
            echo "network={"
            echo " ssid=\"$ssid\""
            echo " key_mgmt=WPA-PSK"
            echo " pairwise=CCMP TKIP"
            echo " group=CCMP TKIP"
            echo " psk=\"$pass\""
            echo "}"
        } > "$WPA_CONF"
        killall -q wpa_supplicant 2>/dev/null
        retry_command "wpa_supplicant -B -i \"$iface\" -D nl80211 -c \"$WPA_CONF\" 2>&1 | tee wpa.log" 3 2
        sleep 4
        udhcpc -i "$iface" >/dev/null 2>&1
        sleep 2
        return 0
    fi
    log_error "Neither nmcli nor wpa_supplicant+udhcpc available"
    return 1
}

# Get IPv4 address (returns IP or empty)
wifi_get_ip() {
    iface="$1"
    ip=""
    if command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2; exit}')
    fi
    if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
        ip=$(ip addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
    fi
    echo "$ip"
}

# Log+exit helpers with optional cleanup
log_pass_exit() {
    # Usage: log_pass_exit "$TESTNAME" "Message" cleanup_func arg
    TESTNAME="$1"
    MSG="$2"
    CLEANUP_FUNC="$3"
    CLEANUP_ARG="$4"
    log_pass "$MSG"
    echo "$TESTNAME PASS" > "./$TESTNAME.res"
    if [ -n "$CLEANUP_FUNC" ] && command -v "$CLEANUP_FUNC" >/dev/null 2>&1; then
        "$CLEANUP_FUNC" "$CLEANUP_ARG"
    fi
    exit 0
}

log_fail_exit() {
    # Usage: log_fail_exit "$TESTNAME" "Message" cleanup_func arg
    TESTNAME="$1"
    MSG="$2"
    CLEANUP_FUNC="$3"
    CLEANUP_ARG="$4"
    log_fail "$MSG"
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    if [ -n "$CLEANUP_FUNC" ] && command -v "$CLEANUP_FUNC" >/dev/null 2>&1; then
        "$CLEANUP_FUNC" "$CLEANUP_ARG"
    fi
    exit 1
}

log_skip_exit() {
    # Usage: log_skip_exit "$TESTNAME" "Message" cleanup_func arg
    TESTNAME="$1"
    MSG="$2"
    CLEANUP_FUNC="$3"
    CLEANUP_ARG="$4"
    log_skip "$MSG"
    echo "$TESTNAME SKIP" > "./$TESTNAME.res"
    if [ -n "$CLEANUP_FUNC" ] && command -v "$CLEANUP_FUNC" >/dev/null 2>&1; then
        "$CLEANUP_FUNC" "$CLEANUP_ARG"
    fi
    exit 0
}

# Robust systemd service check: returns 0 if networkd up, 0 if systemd missing, 1 if error
check_systemd_services() {
    # If systemd not present, pass for minimal or kernel-only builds
    if ! command -v systemctl >/dev/null 2>&1; then
        log_info "systemd/systemctl not found (kernel/minimal build). Skipping service checks."
        return 0
    fi
    for service in "$@"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            if ! systemctl is-active --quiet "$service"; then
                log_warn "$service not running. Retrying start..."
                retry_command "systemctl start $service" 3 2
                if ! systemctl is-active --quiet "$service"; then
                    log_fail "$service failed to start after 3 retries."
                    return 1
                else
                    log_pass "$service started after retry."
                fi
            fi
        else
            log_warn "$service not enabled or not found."
        fi
    done
    return 0
}

# Ensure udhcpc default.script exists, create if missing
ensure_udhcpc_script() {
    udhcpc_dir="/usr/share/udhcpc"
    udhcpc_script="$udhcpc_dir/default.script"
    udhcpc_backup="$udhcpc_script.bak"

    if [ ! -d "$udhcpc_dir" ]; then
        mkdir -p "$udhcpc_dir" || return 1
    fi

    # Backup if script already exists and is not a backup yet
    if [ -f "$udhcpc_script" ] && [ ! -f "$udhcpc_backup" ]; then
        cp "$udhcpc_script" "$udhcpc_backup"
    fi

    if [ ! -x "$udhcpc_script" ]; then
        cat > "$udhcpc_script" <<'EOF'
#!/bin/sh
case "$1" in
    deconfig)
        ip addr flush dev "$interface"
        ;;
    renew|bound)
        echo "[INFO] Configuring $interface with IP: $ip/$subnet"
        ip addr flush dev "$interface"
        ip addr add "$ip/$subnet" dev "$interface"
        ip link set "$interface" up
        if [ -n "$router" ]; then
            ip route del default dev "$interface" 2>/dev/null
            ip route add default via "$router" dev "$interface"
        fi
echo "[INFO] Setting DNS to 8.8.8.8"
echo "nameserver 8.8.8.8" > /etc/resolv.conf
        ;;
esac
exit 0
EOF
        chmod +x "$udhcpc_script"
    fi

    echo "$udhcpc_script"
}

# Resotre back the default.script
restore_udhcpc_script() {
    udhcpc_dir="/usr/share/udhcpc"
    udhcpc_script="$udhcpc_dir/default.script"
    udhcpc_backup="$udhcpc_script.bak"

    if [ -f "$udhcpc_backup" ]; then
        mv -f "$udhcpc_backup" "$udhcpc_script"
        echo "[INFO] Restored original udhcpc default.script"
    fi
}

# Bring an interface up or down using available tools
# Usage: bring_interface_up_down <iface> <up|down>
bring_interface_up_down() {
    iface="$1"
    state="$2"
    if command -v ip >/dev/null 2>&1; then
        ip link set "$iface" "$state"
    elif command -v ifconfig >/dev/null 2>&1; then
        if [ "$state" = "up" ]; then
            ifconfig "$iface" up
        else
            ifconfig "$iface" down
        fi
    else
        log_error "No ip or ifconfig tools found to bring $iface $state"
        return 1
    fi
}

wifi_write_wpa_conf() {
    iface="$1"
    ssid="$2"
    pass="$3"
    conf_file="/tmp/wpa_supplicant_${iface}.conf"
    {
        echo "ctrl_interface=/var/run/wpa_supplicant"
        echo "network={"
        echo " ssid=\"$ssid\""
        echo " key_mgmt=WPA-PSK"
        echo " pairwise=CCMP TKIP"
        echo " group=CCMP TKIP"
        echo " psk=\"$pass\""
        echo "}"
    } > "$conf_file"
    echo "$conf_file"
}

# Find the first available WiFi interface (wl* or wlan0), using 'ip' or 'ifconfig'.
# Prints the interface name, or returns non-zero if not found.
get_wifi_interface() {
    WIFI_IF=""

    # Prefer 'ip' if available.
    if command -v ip >/dev/null 2>&1; then
        WIFI_IF=$(ip link | awk -F: '/ wl/ {print $2}' | tr -d ' ' | head -n1)
        if [ -z "$WIFI_IF" ]; then
            WIFI_IF=$(ip link | awk -F: '/^[0-9]+: wl/ {print $2}' | tr -d ' ' | head -n1)
        fi
        if [ -z "$WIFI_IF" ] && ip link show wlan0 >/dev/null 2>&1; then
            WIFI_IF="wlan0"
        fi
    else
        # Fallback to 'ifconfig' if 'ip' is missing.
        if command -v ifconfig >/dev/null 2>&1; then
            WIFI_IF=$(ifconfig -a 2>/dev/null | grep -o '^wl[^:]*' | head -n1)
            if [ -z "$WIFI_IF" ] && ifconfig wlan0 >/dev/null 2>&1; then
                WIFI_IF="wlan0"
            fi
        fi
    fi

    if [ -n "$WIFI_IF" ]; then
        echo "$WIFI_IF"
        return 0
    else
        return 1
    fi
}

# Auto-detect eMMC block device (non-removable, not UFS)
detect_emmc_partition_block() {
    if command -v lsblk >/dev/null 2>&1 && command -v udevadm >/dev/null 2>&1; then
        for part in $(lsblk -lnpo NAME,TYPE | awk '$2 == "part" {print $1}'); do
            if udevadm info --query=all --name="$part" 2>/dev/null | grep -qi "mmcblk"; then
                echo "$part"
                return 0
            fi
        done
    fi

    for part in /dev/mmcblk*p[0-9]*; do
        [ -e "$part" ] || continue
        if command -v udevadm >/dev/null 2>&1 && udevadm info --query=all --name="$part" | grep -qi "mmcblk"; then
            echo "$part"
            return 0
        fi
    done
    return 1
}

# Auto-detect UFS block device (via udev vendor info or path hint)
detect_ufs_partition_block() {
    if command -v lsblk >/dev/null 2>&1 && command -v udevadm >/dev/null 2>&1; then
        for part in $(lsblk -lnpo NAME,TYPE | awk '$2 == "part" {print $1}'); do
            if udevadm info --query=all --name="$part" 2>/dev/null | grep -qi "ufs"; then
                echo "$part"
                return 0
            fi
        done
    fi

    for part in /dev/sd[a-z][0-9]*; do
        [ -e "$part" ] || continue
        if command -v udevadm >/dev/null 2>&1 &&
           udevadm info --query=all --name="$part" 2>/dev/null | grep -qi "ufs"; then
            echo "$part"
            return 0
        fi
    done
    return 1
}

# Check for dmesg I/O errors and log summary
scan_dmesg_errors() {
    label="$1"                   # Example: "ufs", "emmc", "wifi"
    output_dir="$2"              # Directory to store logs
    extra_keywords="$3"          # (Optional) Space-separated keywords for this label

    [ -z "$label" ] && return 1
    [ -z "$output_dir" ] && output_dir="."

    snapshot_file="$output_dir/${label}_dmesg_snapshot.log"
    error_file="$output_dir/${label}_dmesg_errors.log"

    log_info "Scanning dmesg for recent $label-related I/O errors..."

    dmesg | tail -n 300 > "$snapshot_file"

    # Common error indicators
    common_keywords="error fail timeout reset crc abort fault invalid fatal warn"

    # Build keyword pattern (common + optional extra)
    pattern="($common_keywords"
    if [ -n "$extra_keywords" ]; then
        pattern="$pattern|$extra_keywords"
    fi
    pattern="$pattern)"

    # Filter: lines must match label and error pattern
    grep -iE "$label" "$snapshot_file" | grep -iE "$pattern" > "$error_file"

    if [ -s "$error_file" ]; then
        log_warn "Detected potential $label-related errors in dmesg:"
        while IFS= read -r line; do
            log_warn " dmesg: $line"
        done < "$error_file"
    else
        log_info "No $label-related errors found in recent dmesg logs."
    fi
}
getsocId() {
    if [ -r /sys/devices/soc0/soc_id ]; then
        cat /sys/devices/soc0/soc_id
    else
        log_error "soc_id file not found or not readable"
        return 1
    fi
}
