#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
. "${PWD}"/init_env
#import platform
. "${TOOLS}"/platform.sh

__RUNNER_SUITES_DIR="/var/Runner/suites"
__RUNNER_UTILS_BIN_DIR="/var/common"

#This function used for test logging
log() {
    local level="$1"
    shift
    # echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a /var/test_framework.log
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a /var/test_output.log
}
# Find test case path by name
find_test_case_by_name() {
    local test_name="$1"
    if [ -d "$__RUNNER_SUITES_DIR" ]; then
        find $__RUNNER_SUITES_DIR -type d -iname "$test_name" 2>/dev/null
    else
        find "${PWD}" -type d -iname "$test_name" 2>/dev/null
    fi
}

# Find test case path by name
find_test_case_bin_by_name() {
    local test_name="$1"
    find $__RUNNER_UTILS_BIN_DIR -type f -iname "$test_name" 2>/dev/null
}

# Find test case path by name
find_test_case_script_by_name() {
    local test_name="$1"
    if [ -d "$__RUNNER_UTILS_BIN_DIR" ]; then
        find $__RUNNER_UTILS_BIN_DIR -type d -iname "$test_name" 2>/dev/null
    else
        find "${PWD}" -type d -iname "$test_name" 2>/dev/null
    fi
}

check_dependencies() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            log_error "ERROR: Required command '$cmd' not found in PATH."
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        log_error "Exiting due to missing dependencies."
        exit 1
    else
    log_pass "Test related dependencies are present."
    fi
}

# Logging levels
log_info() { log "INFO" "$@"; }
log_pass() { log "PASS" "$@"; }
log_fail() { log "FAIL" "$@"; }
log_error() { log "ERROR" "$@"; }


## this doc fn comes last
FUNCTIONS="\
log_info \
log_pass \
log_fail \
log_error \
find_test_case_by_name \
find_test_case_bin_by_name \
find_test_case_script_by_name  \
log \
"

functestlibdoc()
{
  echo "functestlib.sh"
  echo ""
  echo "Functions:"
  for fn in $FUNCTIONS; do
    echo $fn
    eval $fn"_doc"
    echo ""
  done
  echo "Note, these functions will probably not work with >=32 CPUs"
}

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
    local url="$1"
    local filename
    local extracted_files
	
	# Extract the filename from the URL
    filename=$(basename "$url")
    if check_tar_file "$filename"; then
        echo "[PASS] file already exists, Hence skipping downloading"
        return 0
    fi
	
    check_network_status
    network_status=$?
    if [ $network_status -ne 0 ]; then
        extract_tar_from_url "$TAR_URL"
    fi

    # Download the file using wget
    echo "[INFO] Downloading $url..."
    wget -O "$filename" "$url"

    # Check if wget was successful
    if [ $? -ne 0 ]; then
        echo "[FAIL] Failed to download the file."
        return 1
    fi

    # Extract the tar file
    echo "[INFO] Extracting $filename..."
    tar -xvf "$filename"

    # Check if tar was successful
    if [ $? -ne 0 ]; then
        echo "[FAIL] Failed to extract the file."
        return 1
    fi

    # Check if any files were extracted
    extracted_files=$(tar -tf "$filename")
    if [ -z "$extracted_files" ]; then
        echo "[FAIL] No files were extracted."
        return 1
    else
        echo "[PASS] Files extracted successfully:"
        echo "[INFO] $extracted_files"
        return 0
    fi
}

# Function to check if a tar file exists
check_tar_file() {
    local url="$1"
    local filename
    local extracted_files

    # Extract the filename from the URL
    filename=$(basename "$url")
    if [ -f "$filename" ]; then
        return 0
    else
        return 1
    fi
}
