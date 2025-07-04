#!/bin/sh
 
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
 
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
QEMU_DIR=""
IMG_FILE=""
FS_FILE=""
 
# Locate and source init_env
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done
 
[ -z "$INIT_ENV" ] && echo "[ERROR] Could not find init_env" >&2 && exit 1
 
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
 
# Source functestlib
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
 
# Find QEMU binaries
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    [ -d "$SEARCH/myqemu" ] && QEMU_DIR="$SEARCH/myqemu" && break
    SEARCH=$(dirname "$SEARCH")
done
 
[ -z "$QEMU_DIR" ] && echo "[ERROR] Could not find myqemu directory" >&2 && exit 1
chmod -R 777 "$QEMU_DIR"
 
# Find kernel image and ext4 filesystem
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    [ -z "$IMG_FILE" ] && [ -f "$SEARCH/Image" ] && IMG_FILE="$SEARCH/Image"
    [ -z "$FS_FILE" ] && FS_FILE=$(find "$SEARCH" -maxdepth 1 -name "*.ext4" | head -n 1)
    [ -n "$IMG_FILE" ] && [ -n "$FS_FILE" ] && break
    SEARCH=$(dirname "$SEARCH")
done
 
[ -z "$IMG_FILE" ] && echo "[ERROR] Kernel Image not found" >&2 && exit 1
[ -z "$FS_FILE" ] && echo "[ERROR] Rootfs .ext4 file not found" >&2 && exit 1
 
TESTNAME="virtio_infra_test"
res_file="./$TESTNAME.res"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
 
serial_log="$PWD/virtio_serial.log"
input_file="$PWD/qemu_input.txt"
 
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
 
rm -f "$res_file" "$serial_log" "$input_file"
 
log_info "Creating temporary input file for QEMU..."
echo -e "\n\n" > "$input_file"
 
log_info "Launching QEMU with KVM..."
cd "$QEMU_DIR" || exit 1
export LD_LIBRARY_PATH="$QEMU_DIR"
 
./qemu-system-aarch64 \
    -M virt -m 2G \
    -drive file="$FS_FILE",if=virtio,format=raw,bus=1,unit=0 \
    -kernel "$IMG_FILE" \
    -cpu host --enable-kvm -smp 4 -nographic -append 'root=/dev/vda' \
    < "$input_file" > "$serial_log" 2>&1 &
 
QEMU_PID=$!
echo "$QEMU_PID" > "$SCRIPT_DIR/qemu.pid"
 
log_info "Waiting for VM to boot (checking logs)..."
 
timeout=90
found_login=0
found_kvm=0
 
for i in $(seq 1 "$timeout"); do
    grep -q "login:" "$serial_log" && found_login=1
    grep -qi "kvm" "$serial_log" && found_kvm=1
    [ $found_login -eq 1 ] && break
    sleep 1
done
 
# Check KVM
if [ $found_kvm -eq 1 ]; then
    log_pass "KVM usage confirmed in boot logs"
else
    log_warn "KVM not explicitly found in logs — fallback may have occurred"
    echo "$TESTNAME FAIL" > "$res_file"
    kill "$QEMU_PID" >/dev/null 2>&1
    rm -f "$input_file" "$SCRIPT_DIR/qemu.pid"
    log_info "-------------------Completed $TESTNAME Testcase----------------------------"
    exit 1
fi
 
# Check login
if [ $found_login -eq 1 ]; then
    log_pass "Login prompt detected"
else
    log_fail "Login prompt not detected"
    echo "$TESTNAME FAIL" > "$res_file"
    kill "$QEMU_PID" >/dev/null 2>&1
    rm -f "$input_file" "$SCRIPT_DIR/qemu.pid"
    log_info "-------------------Completed $TESTNAME Testcase----------------------------"
    exit 1
fi
 
echo "$TESTNAME PASS" > "$res_file"
kill "$QEMU_PID" >/dev/null 2>&1
rm -f "$input_file" "$SCRIPT_DIR/qemu.pid"
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
 