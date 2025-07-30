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

# load_kernel_module <path-to-ko> [params...]
# 1) If already loaded, no-op
# 2) Try insmod <ko> [params]
# 3) If that fails, try modprobe <modname> [params]
load_kernel_module() {
    module_path="$1"; shift
    params="$*"
    module_name=$(basename "$module_path" .ko)

    if is_module_loaded "$module_name"; then
        log_info "Module $module_name is already loaded"
        return 0
    fi

    if [ ! -f "$module_path" ]; then
        log_error "Module file not found: $module_path"
        # still try modprobe if it exists in modules directory
    else
        log_info "Loading module via insmod: $module_path $params"
        if /sbin/insmod "$module_path" "$params" 2>insmod_err.log; then
            log_info "Module $module_name loaded successfully via insmod"
            return 0
        else
            log_warn "insmod failed: $(cat insmod_err.log)"
        fi
    fi

    # fallback to modprobe
    log_info "Falling back to modprobe $module_name $params"
    if /sbin/modprobe "$module_name" "$params" 2>modprobe_err.log; then
        log_info "Module $module_name loaded successfully via modprobe"
        return 0
    else
        log_error "modprobe failed: $(cat modprobe_err.log)"
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

# Check each given kernel config is set to y/m in /proc/config.gz, logs result, returns 0/1.
check_kernel_config() {
    cfgs=$1
    for config_key in $cfgs; do
        if command -v zgrep >/dev/null 2>&1; then
            if zgrep -qE "^${config_key}=(y|m)" /proc/config.gz 2>/dev/null; then
                log_pass "Kernel config $config_key is enabled"
            else
                log_fail "Kernel config $config_key is missing or not enabled"
                return 1
            fi
        else
            # Fallback if zgrep is unavailable
            if gzip -dc /proc/config.gz 2>/dev/null | grep -qE "^${config_key}=(y|m)"; then
                log_pass "Kernel config $config_key is enabled"
            else
                log_fail "Kernel config $config_key is missing or not enabled"
                return 1
            fi
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
    sleep 1
 
    log_info "Running Bluetooth scan via hcitool (synchronous)..."
    script -q -c "hcitool -i $hcidev scan" "$scan_log"
    grep -E '^(\s)*([0-9A-F]{2}:){5}[0-9A-F]{2}' "$scan_log" | awk '{print $1, $2}' > "$found_log"
 
    if [ -s "$found_log" ]; then
        log_info "hcitool scan found devices, skipping bluetoothctl fallback."
        return 0
    fi
 
    log_warn "hcitool scan returned nothing. Falling back to bluetoothctl scan..."
 
    expect <<EOF >> "$scan_log"
log_user 0
spawn bluetoothctl
expect -re "#|\\\[.*\\\]#" { send "power on\r" }
expect -re "#|\\\[.*\\\]#" { send "agent NoInputNoOutput\r" }
expect -re "#|\\\[.*\\\]#" { send "default-agent\r" }
expect -re "#|\\\[.*\\\]#" { send "scan on\r" }
sleep 10
send "scan off\r"
expect -re "#|\\\[.*\\\]#" { send "quit\r" }
EOF
 
    grep -E "^\s*\[NEW\] Device" "$scan_log" | awk '{print $4, substr($0, index($0, $5))}' > "$found_log"
 
    if [ ! -s "$found_log" ]; then
        log_warn "Scan log is empty. Possible issue with bluetoothctl or adapter."
        return 1
    fi
 
    return 0
}

# Pair with Bluetooth device using MAC (with retries and timestamped logs)
bt_pair_with_mac() {
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

    log_info "Running l2ping test for $target_mac"
    if l2ping -c 3 -t 5 "$target_mac" >>"$logfile" 2>&1; then
        log_pass "l2ping to $target_mac succeeded"
        return 0
    else
        log_warn "l2ping to $target_mac failed"
        return 1
    fi
}

###############################################################################
# get_remoteproc_by_firmware <short-fw-name> [outfile] [all]
# - If outfile is given: append *all* matches as "<path>|<state>|<firmware>|<name>"
#   (one per line) and return 0 if at least one match.
# - If no outfile: print the *first* match to stdout and return 0.
# - Returns 1 if nothing matched, 3 if misuse (no fw argument).
###############################################################################
get_remoteproc_by_firmware() {
    fw="$1"
    out="$2"      # optional: filepath to append results
    list_all="$3" # set to "all" to continue past first match 

    [ -n "$fw" ] || return 3 # misuse if no firmware provided

    found=0
    for p in /sys/class/remoteproc/remoteproc*; do
        [ -d "$p" ] || continue

        # read name, firmware, state
        name=""
        [ -r "$p/name" ]     && IFS= read -r name     <"$p/name"
        firmware=""
        [ -r "$p/firmware" ] && IFS= read -r firmware <"$p/firmware"
        state="unknown"
        [ -r "$p/state" ]    && IFS= read -r state    <"$p/state"

        case "$name $firmware" in
            *"$fw"*)
                line="${p}|${state}|${firmware}|${name}"
                if [ -n "$out" ]; then
                    printf '%s\n' "$line" >>"$out"
                    found=1
                    continue
                fi

                # print to stdout and possibly stop
                printf '%s\n' "$line"
                found=1
                [ "$list_all" = "all" ] || return 0
                ;;
        esac
    done

    # if we appended to a file, success if found>=1
    if [ "$found" -eq 1 ]; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# dt_has_remoteproc_fw <fw-short>
#   Return:
#     0 = DT describes this remoteproc firmware
#     1 = DT does not describe it
#     3 = misuse (no argument)
# ------------------------------------------------------------------------------
dt_has_remoteproc_fw() {
    fw="$1"
    [ -n "$fw" ] || return 3
 
    base="/proc/device-tree"
    [ -d "$base" ] || return 1
 
    # lower-case match key
    fw_lc=$(printf '%s\n' "$fw" | tr '[:upper:]' '[:lower:]')
 
    # new fast-path (any smp2p-<fw>* or remoteproc-<fw>* directory)
    found=0
    for d in "$base"/smp2p-"$fw"* "$base"/remoteproc-"$fw"*; do
        [ -d "$d" ] && found=1 && break
    done
    [ "$found" -eq 1 ] && return 0
 
    # 2) Shallow find (<depth 2) for any node/prop name containing fw
    if find "$base" -maxdepth 2 -iname "*$fw_lc*" -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi
 
    # 3) Grep soc@0 and aliases for a first match
    if grep -Iq -m1 -F "$fw_lc" "$base/soc@0" "$base/aliases" 2>/dev/null; then
        return 0
    fi
 
    # 4) Fallback: grep entire DT tree
    if grep -Iq -m1 -F "$fw_lc" "$base" 2>/dev/null; then
        return 0
    fi
 
    return 1
}

# Get remoteproc state
get_remoteproc_state() {
    rp="$1"
    [ -z "$rp" ] && { printf '\n'; return 1; }
 
    case "$rp" in
        /sys/*) rpath="$rp" ;;
        *)      rpath="/sys/class/remoteproc/$rp" ;;
    esac
 
    state_file="$rpath/state"
    if [ -r "$state_file" ]; then
        IFS= read -r state < "$state_file" || state=""
        printf '%s\n' "$state"
        return 0
    fi
    printf '\n'
    return 1
}

# wait_remoteproc_state <sysfs-path> <desired_state> <timeout_s> <poll_interval_s>
wait_remoteproc_state() {
    rp="$1"; want="$2"; to=${3:-10}; poll=${4:-1}
 
    case "$rp" in
        /sys/*) rpath="$rp" ;;
        *)      rpath="/sys/class/remoteproc/$rp" ;;
    esac
 
    start_ts=$(date +%s)
    while :; do
        cur=$(get_remoteproc_state "$rpath")
        [ "$cur" = "$want" ] && return 0
 
        now_ts=$(date +%s)
        [ $((now_ts - start_ts)) -ge "$to" ] && {
            log_info "Waiting for state='$want' timed out (got='$cur')..."
            return 1
        }
        sleep "$poll"
    done
}

# Stop remoteproc
stop_remoteproc() {
    rproc_path="$1"
 
    # Resolve to a real sysfs dir if only a name was given
    case "$rproc_path" in
        /sys/*) path="$rproc_path" ;;
        remoteproc*) path="/sys/class/remoteproc/$rproc_path" ;;
        *) path="$rproc_path" ;;  # last resort, assume caller passed full path
    esac
 
    statef="$path/state"
    if [ ! -w "$statef" ]; then
        log_warn "stop_remoteproc: state file not found/writable: $statef"
        return 1
    fi
 
    printf 'stop\n' >"$statef" 2>/dev/null || return 1
    wait_remoteproc_state "$path" offline 6
}
 
# Start remoteproc
start_remoteproc() {
    rproc_path="$1"
 
    case "$rproc_path" in
        /sys/*) path="$rproc_path" ;;
        remoteproc*) path="/sys/class/remoteproc/$rproc_path" ;;
        *) path="$rproc_path" ;;
    esac
 
    statef="$path/state"
    if [ ! -w "$statef" ]; then
        log_warn "start_remoteproc: state file not found/writable: $statef"
        return 1
    fi
 
    printf 'start\n' >"$statef" 2>/dev/null || return 1
    wait_remoteproc_state "$path" running 6
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

# acquire_test_lock <testname>
acquire_test_lock() {
    lockfile="/var/lock/$1.lock"
    exec 9>"$lockfile"
    if ! flock -n 9; then
        log_warn "Could not acquire lock on $lockfile → SKIP"
        echo "$1 SKIP" > "./$1.res"
        exit 0
    fi
    log_info "Acquired lock on $lockfile"
}

# release_test_lock
release_test_lock() {
    flock -u 9
    log_info "Released lock"
}

# summary_report <testname> <mode> <stop_time_s> <start_time_s> <rpmsg_result>
# Appends a machine‐readable summary line to the test log
summary_report() {
    test="$1"
    mode="$2"
    stop_t="$3"
    start_t="$4"
    rp="$5"
    log_info "Summary for ${test}: mode=${mode} stop_time_s=${stop_t} start_time_s=${start_t} rpmsg=${rp}"
}

# dump_rproc_logs <sysfs-path> <label>
# Captures debug trace + filtered dmesg into a timestamped log
dump_rproc_logs() {
    rpath="$1"; label="$2"
    ts=$(date +%Y%m%d_%H%M%S)
    base=$(basename "$rpath")
    logfile="rproc_${base}_${label}_${ts}.log"
    log_info "Dumping ${base} [${label}] → ${logfile}"
    [ -r "$rpath/trace" ] && cat "$rpath/trace" >"$logfile"
    dmesg --ctime | grep -i "$base" >>"$logfile" 2>/dev/null || :
}

# find_rpmsg_ctrl_for <short-name>
# e.g. find_rpmsg_ctrl_for adsp
find_rpmsg_ctrl_for() {
    want="$1"  # e.g. "adsp"

    for dev in /dev/rpmsg_ctrl*; do
        [ -e "$dev" ] || continue

        base=$(basename "$dev")
        sysfs="/sys/class/rpmsg/${base}"

        # resolve the rpmsg_ctrl node’s real path
        target=$(readlink -f "$sysfs/device")
        # climb up to the remoteprocX directory
        remoteproc_dir=$(dirname "$(dirname "$(dirname "$target")")")

        # Try the 'name' file
        if [ -r "$remoteproc_dir/name" ]; then
            rpname=$(cat "$remoteproc_dir/name")
            if echo "$rpname" | grep -qi "^${want}"; then
                printf '%s\n' "$dev"
                return 0
            fi
        fi

        # Fallback: try the 'firmware' file, strip extension
        if [ -r "$remoteproc_dir/firmware" ]; then
            fw=$(basename "$(cat "$remoteproc_dir/firmware")")   # adsp.mbn
            short="${fw%%.*}"                                    # adsp
            if echo "$short" | grep -qi "^${want}"; then
                printf '%s\n' "$dev"
                return 0
            fi
        fi
    done

    return 1
}

# Given a remoteproc *absolute* path (e.g. /sys/class/remoteproc/remoteproc2),
# return the FIRST matching /sys/class/rpmsg/rpmsg_ctrlN path.
find_rpmsg_ctrl_for_rproc() {
    rproc_path="$1"
    for c in /sys/class/rpmsg/rpmsg_ctrl*; do
        [ -e "$c" ] || continue
        # device symlink for ctrl points into ...remoteprocX/...rpmsg_ctrl...
        devlink=$(readlink -f "$c/device" 2>/dev/null) || continue
        case "$devlink" in
            "$rproc_path"/*) printf '%s\n' "$c"; return 0 ;;
        esac
    done
    return 1
}

# Ensure /dev node exists for a sysfs rpmsg item (ctrl or data). Echo /dev/… path.
rpmsg_sys_to_dev() {
    sys="$1"
    dev="/dev/$(basename "$sys")"
    if [ ! -e "$dev" ]; then
        [ -r "$sys/dev" ] || return 1
        IFS=: read -r maj min < "$sys/dev" || return 1
        mknod "$dev" c "$maj" "$min" 2>/dev/null || return 1
        chmod 600 "$dev" 2>/dev/null
    fi
    printf '%s\n' "$dev"
}

# Find existing rpmsg data endpoints that belong to this remoteproc path.
# Echo all matching /dev/rpmsgN (one per line). Return 0 if any, 1 if none.
find_rpmsg_data_for_rproc() {
    rproc_path="$1"
    found=0
    for d in /sys/class/rpmsg/rpmsg[0-9]*; do
        [ -e "$d" ] || continue
        devlink=$(readlink -f "$d/device" 2>/dev/null) || continue
        case "$devlink" in
            "$rproc_path"/*)
                if node=$(rpmsg_sys_to_dev "$d"); then
                    printf '%s\n' "$node"
                    found=1
                fi
                ;;
        esac
    done
    [ "$found" -eq 1 ]
}

# Create a new endpoint via ctrl/create (no hardcoded name: we pick the first free)
# If firmware doesn't expose ping service, this may still not respond; we just create.
# Returns /dev/rpmsgN or empty on failure.
rpmsg_create_ep_generic() {
    ctrl_sys="$1"
    name="${2:-gen-test}"   # generic endpoint name
    src="${3:-0}"
    dst="${4:-0}"
 
    create_file="$(readlink -f "$ctrl_sys")/create"
    [ -w "$create_file" ] || return 1
 
    # Request endpoint creation
    printf '%s %s %s\n' "$name" "$src" "$dst" >"$create_file" 2>/dev/null || return 1
 
    # Pick the newest rpmsg* sysfs node without using 'ls -t' (SC2012)
    new_sys=$(
        find -L /sys/class/rpmsg -maxdepth 1 -type l -name 'rpmsg[0-9]*' \
            -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2}'
    )
 
    [ -n "$new_sys" ] || return 1
 
    rpmsg_sys_to_dev "$new_sys"
}

# Try to exercise the channel by write-read loopback.
# Without protocol knowledge, we can only do a heuristic:
# write "PING\n", read back; if anything comes, treat as success.
rpmsg_try_echo() {
    node="$1"
    # write
    printf 'PING\n' >"$node" 2>/dev/null || return 1
    # read (2s timeout if available)
    if command -v timeout >/dev/null 2>&1; then
        reply=$(timeout 2 cat "$node" 2>/dev/null)
    else
        reply=$(dd if="$node" bs=256 count=1 2>/dev/null)
    fi
    [ -n "$reply" ] || return 1
    return 0
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

# wait_for_path <path> [timeout_sec]
wait_for_path() {
    _p="$1"; _t="${2:-3}"
    i=0
    while [ "$i" -lt "$_t" ]; do
        [ -e "$_p" ] && return 0
        sleep 1
        i=$((i+1))
    done
    return 1
}

###############################################################################
# scan_dmesg_errors
#
# Only scans *new* dmesg lines for true error patterns (since last test run).
# Keeps a timestamped error log history for each run.
# Handles dmesg with/without timestamps. Cleans up markers/logs if test dir is gone.
# Usage: scan_dmesg_errors "$SCRIPT_DIR" [optional_extra_keywords...]
###############################################################################
scan_dmesg_errors() {
    prefix="$1"
    module_regex="$2"   # e.g. 'qcom_camss|camss|isp'
    exclude_regex="${3:-"dummy regulator|supply [^ ]+ not found|using dummy regulator"}"
    shift 3

    mkdir -p "$prefix"

    DMESG_SNAPSHOT="$prefix/dmesg_snapshot.log"
    DMESG_ERRORS="$prefix/dmesg_errors.log"
    DATE_STAMP=$(date +%Y%m%d-%H%M%S)
    DMESG_HISTORY="$prefix/dmesg_errors_$DATE_STAMP.log"

    # Error patterns (edit as needed for your test coverage)
    err_patterns='Unknown symbol|probe failed|fail(ed)?|error|timed out|not found|invalid|corrupt|abort|panic|oops|unhandled|can.t (start|init|open|allocate|find|register)'

    rm -f "$DMESG_SNAPSHOT" "$DMESG_ERRORS"
    dmesg > "$DMESG_SNAPSHOT" 2>/dev/null

    # 1. Match lines with correct module and error pattern
    # 2. Exclude lines with harmless patterns (using dummy regulator etc)
    grep -iE "^\[[^]]+\][[:space:]]+($module_regex):.*($err_patterns)" "$DMESG_SNAPSHOT" \
        | grep -vEi "$exclude_regex" > "$DMESG_ERRORS" || true

    cp "$DMESG_ERRORS" "$DMESG_HISTORY"

    if [ -s "$DMESG_ERRORS" ]; then
        log_info "dmesg scan: found non-benign module errors in $DMESG_ERRORS (history: $DMESG_HISTORY)"
        return 0
    fi
    log_info "No relevant, non-benign errors for modules [$module_regex] in recent dmesg."
    return 1
}

# Skip unwanted device tree node names during DT parsing (e.g., aliases, metadata).
# Used to avoid traversing irrelevant or special nodes in recursive scans.
dt_should_skip_node() {
    case "$1" in
        ''|__*|phandle|name|'#'*|aliases|chosen|reserved-memory|interrupt-controller|thermal-zones)
            return 0 ;;
    esac
    return 1
}

# Recursively yield all directories (nodes) under a DT root path.
# Terminates early if a match result is found in the provided file.
dt_yield_node_paths() {
    _root="$1"
    _matchresult="$2"
    # If we've already matched, stop recursion immediately!
    [ -s "$_matchresult" ] && return
    for entry in "$_root"/*; do
        [ -d "$entry" ] || continue
        [ -s "$_matchresult" ] && return
        echo "$entry"
        dt_yield_node_paths "$entry" "$_matchresult"
    done
}

# Recursively search for files named "compatible" in DT paths.
# Terminates early if a match result is already present.
dt_yield_compatible_files() {
    _root="$1"
    _matchresult="$2"
    [ -s "$_matchresult" ] && return
    for entry in "$_root"/*; do
        [ -e "$entry" ] || continue
        [ -s "$_matchresult" ] && return
        if [ -f "$entry" ] && [ "$(basename "$entry")" = "compatible" ]; then
            echo "$entry"
        elif [ -d "$entry" ]; then
            dt_yield_compatible_files "$entry" "$_matchresult"
        fi
    done
}

# Searches /proc/device-tree for nodes or compatible strings matching input patterns.
# Returns success and matched path if any pattern is found; used in pre-test validation.
dt_confirm_node_or_compatible() {
    root="/proc/device-tree"
    matchflag=$(mktemp) || exit 1
    matchresult=$(mktemp) || { rm -f "$matchflag"; exit 1; }

    for pattern in "$@"; do
        # Node search: strict prefix (e.g., "isp" only matches "isp@...")
        for entry in $(dt_yield_node_paths "$root" "$matchresult"); do
            [ -s "$matchresult" ] && break
            node=$(basename "$entry")
            dt_should_skip_node "$node" && continue
            printf '%s' "$node" | grep -iEq "^${pattern}(@|$)" || continue
            log_info "[DTFIND] Node name strict prefix match: $entry (pattern: $pattern)"
            if [ ! -s "$matchresult" ]; then
                echo "${pattern}:${entry}" > "$matchresult"
            fi
            touch "$matchflag"
        done
        [ -s "$matchresult" ] && break

        # Compatible property search: strict (prefix or whole word)
        for file in $(dt_yield_compatible_files "$root" "$matchresult"); do
            [ -s "$matchresult" ] && break
            compdir=$(dirname "$file")
            node=$(basename "$compdir")
            dt_should_skip_node "$node" && continue
            compval=$(tr '\0' ' ' < "$file")
            printf '%s' "$compval" | grep -iEq "(^|[ ,])${pattern}([ ,]|$)" || continue
            log_info "[DTFIND] Compatible strict match: $file (${compval}) (pattern: $pattern)"
            if [ ! -s "$matchresult" ]; then
                echo "${pattern}:${file}" > "$matchresult"
            fi
            touch "$matchflag"
        done
        [ -s "$matchresult" ] && break
    done

    if [ -f "$matchflag" ] && [ -s "$matchresult" ]; then
        cat "$matchresult"
        rm -f "$matchflag" "$matchresult"
        return 0
    fi
    rm -f "$matchflag" "$matchresult"
    return 1
}

# Detects and returns the first available media node (e.g., /dev/media0).
# Returns failure if no media nodes are present.
detect_media_node() {
    for node in /dev/media*; do
        if [ -e "$node" ]; then
            printf '%s\n' "$node"
            return 0
        fi
    done
    return 1
}

# Runs the Python pipeline parser with a topology file to emit camera blocks.
# Returns structured per-pipeline output for further processing.
run_camera_pipeline_parser() {
    # Input: path to topo file (e.g., /tmp/cam_topo.txt)
    # Output: emits parse output to stdout
    TOPO_FILE="$1"

    if [ ! -f "$TOPO_FILE" ]; then
        log_error "Topology file $TOPO_FILE not found"
        return 1
    fi

PYTHON_SCRIPT="$TOOLS/camera/parse_media_topology.py"
    if [ ! -x "$PYTHON_SCRIPT" ]; then
        log_error "Camera pipeline parser script not found at $PYTHON_SCRIPT"
        return 1
    fi

    log_info "Invoking camera pipeline parser with $TOPO_FILE"
    python3 "$PYTHON_SCRIPT" "$TOPO_FILE"
}

# Shortcut to detect a media node, dump topology, and run the parser on it.
# Intended for quick standalone camera pipeline detection.
get_camera_pipeline_blocks() {
    TOPO_FILE="/tmp/parse_topo.$$"
    MEDIA_NODE=$(detect_media_node)
    if [ -z "$MEDIA_NODE" ]; then
        echo "[ERROR] Failed to detect media node" >&2
        return 1
    fi
    media-ctl -p -d "$MEDIA_NODE" >"$TOPO_FILE" 2>/dev/null
    PARSE_SCRIPT="${TOOLS}/camera/parse_media_topology.py"
    if [ ! -f "$PARSE_SCRIPT" ]; then
        echo "[ERROR] Python script $PARSE_SCRIPT not found" >&2
        rm -f "$TOPO_FILE"
        return 1
    fi
    python3 "$PARSE_SCRIPT" "$TOPO_FILE"
    ret=$?
    rm -f "$TOPO_FILE"
    return "$ret"
}

# Parses a single pipeline block file into shell variables and lists.
# Each key-value line sets up variables for media-ctl or yavta operations.
parse_pipeline_block() {
    block_file="$1"

    # Unset and export all variables that will be assigned
    unset SENSOR VIDEO FMT YAVTA_DEV YAVTA_FMT YAVTA_W YAVTA_H
    unset MEDIA_CTL_V_LIST MEDIA_CTL_L_LIST
    unset YAVTA_CTRL_PRE_LIST YAVTA_CTRL_LIST YAVTA_CTRL_POST_LIST

    export SENSOR VIDEO FMT YAVTA_DEV YAVTA_FMT YAVTA_W YAVTA_H
    export MEDIA_CTL_V_LIST MEDIA_CTL_L_LIST
    export YAVTA_CTRL_PRE_LIST YAVTA_CTRL_LIST YAVTA_CTRL_POST_LIST

    while IFS= read -r bline || [ -n "$bline" ]; do
        key=$(printf "%s" "$bline" | awk -F':' '{print $1}')
        val=$(printf "%s" "$bline" | sed 's/^[^:]*://')
        case "$key" in
            SENSOR) SENSOR=$val ;;
            VIDEO) VIDEO=$val ;;
            YAVTA_DEV) YAVTA_DEV=$val ;;
            YAVTA_W) YAVTA_W=$val ;;
            YAVTA_H) YAVTA_H=$val ;;
            YAVTA_FMT) YAVTA_FMT=$val ;;
            MEDIA_CTL_V) MEDIA_CTL_V_LIST="$MEDIA_CTL_V_LIST
$val" ;;
            MEDIA_CTL_L) MEDIA_CTL_L_LIST="$MEDIA_CTL_L_LIST
$val" ;;
            YAVTA_CTRL_PRE) YAVTA_CTRL_PRE_LIST="$YAVTA_CTRL_PRE_LIST
$val" ;;
            YAVTA_CTRL) YAVTA_CTRL_LIST="$YAVTA_CTRL_LIST
$val" ;;
            YAVTA_CTRL_POST) YAVTA_CTRL_POST_LIST="$YAVTA_CTRL_POST_LIST
$val" ;;
        esac
    done < "$block_file"

    # Fallback: if VIDEO is not emitted, use YAVTA_DEV
    if [ -z "$VIDEO" ] && [ -n "$YAVTA_DEV" ]; then
        VIDEO="$YAVTA_DEV"
    fi
}

# Applies media configuration (format and links) using media-ctl from parsed pipeline block.
# Resets media graph first and applies user-specified format override if needed.
configure_pipeline_block() {
    MEDIA_NODE="$1" USER_FORMAT="$2"

    media-ctl -d "$MEDIA_NODE" --reset >/dev/null 2>&1

    # Apply MEDIA_CTL_V (override format if USER_FORMAT set)
    printf "%s\n" "$MEDIA_CTL_V_LIST" | while IFS= read -r vline || [ -n "$vline" ]; do
        [ -z "$vline" ] && continue
        vline_new="$vline"
        if [ -n "$USER_FORMAT" ]; then
            vline_new=$(printf "%s" "$vline_new" | sed -E "s/fmt:[^/]+\/([0-9]+x[0-9]+)/fmt:${USER_FORMAT}\/\1/g")
        fi
        media-ctl -d "$MEDIA_NODE" -V "$vline_new" >/dev/null 2>&1
    done

    # Apply MEDIA_CTL_L
    printf "%s\n" "$MEDIA_CTL_L_LIST" | while IFS= read -r lline || [ -n "$lline" ]; do
        [ -z "$lline" ] && continue
        media-ctl -d "$MEDIA_NODE" -l "$lline" >/dev/null 2>&1
    done
}

# Executes yavta pipeline controls and captures frames from a video node.
# Handles pre-capture and post-capture register writes, with detailed result code
execute_capture_block() {
    FRAMES="$1" FORMAT="$2"

    # Pre-stream controls
    printf "%s\n" "$YAVTA_CTRL_PRE_LIST" | while IFS= read -r ctrl; do
        [ -z "$ctrl" ] && continue
        dev=$(echo "$ctrl" | awk '{print $1}')
        reg=$(echo "$ctrl" | awk '{print $2}')
        val=$(echo "$ctrl" | awk '{print $3}')
        yavta --no-query -w "$reg $val" "$dev" >/dev/null 2>&1
    done

    # Stream-on controls
    printf "%s\n" "$YAVTA_CTRL_LIST" | while IFS= read -r ctrl; do
        [ -z "$ctrl" ] && continue
        dev=$(echo "$ctrl" | awk '{print $1}')
        reg=$(echo "$ctrl" | awk '{print $2}')
        val=$(echo "$ctrl" | awk '{print $3}')
        yavta --no-query -w "$reg $val" "$dev" >/dev/null 2>&1
    done

    # Capture
    if [ -n "$YAVTA_DEV" ] && [ -n "$FORMAT" ] && [ -n "$YAVTA_W" ] && [ -n "$YAVTA_H" ]; then
        OUT=$(yavta -B capture-mplane -c -I -n "$FRAMES" -f "$FORMAT" -s "${YAVTA_W}x${YAVTA_H}" -F "$YAVTA_DEV" --capture="$FRAMES" --file="frame-#.bin" 2>&1)
        RET=$?
        if echo "$OUT" | grep -qi "Unsupported video format"; then
            return 2
        elif [ $RET -eq 0 ] && echo "$OUT" | grep -q "Captured [1-9][0-9]* frames"; then
            return 0
        else
            return 1
        fi
    else
        return 3
    fi

    # Post-stream controls
    printf "%s\n" "$YAVTA_CTRL_POST_LIST" | while IFS= read -r ctrl; do
        [ -z "$ctrl" ] && continue
        dev=$(echo "$ctrl" | awk '{print $1}')
        reg=$(echo "$ctrl" | awk '{print $2}')
        val=$(echo "$ctrl" | awk '{print $3}')
        yavta --no-query -w "$reg $val" "$dev" >/dev/null 2>&1
    done
}

