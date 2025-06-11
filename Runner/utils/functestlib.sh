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

