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

# --- Dependency check ---
check_dependencies() {
    missing=0
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command '$cmd' not found in PATH."
            missing=1
        fi
    done
    [ "$missing" -ne 0 ] && exit 1
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

