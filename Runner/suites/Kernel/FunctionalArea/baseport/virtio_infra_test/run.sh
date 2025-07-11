#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
QEMU_DIR=""
VOLATILE_DIR=""

# Search for init_env
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
    exit 1
fi
 
# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

# Search for myqemu directory
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    [ -d "$SEARCH/myqemu" ] && QEMU_DIR="$SEARCH/myqemu" && break
    SEARCH=$(dirname "$SEARCH")
done

[ -z "$QEMU_DIR" ] && echo "[ERROR] Could not find myqemu directory" >&2 && exit 1

# Fix permissions for myqemu
chmod -R 777 "$QEMU_DIR"

# Search for volatile directory
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    [ -d "$SEARCH/volatile" ] && VOLATILE_DIR="$SEARCH/volatile" && break
    SEARCH=$(dirname "$SEARCH")
done

[ -z "$VOLATILE_DIR" ] && echo "[ERROR] Could not find volatile directory" >&2 && exit 1

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

(
    cd "$QEMU_DIR" || exit 1
    ./ld-linux-aarch64.so.1 --library-path . ./qemu-system-aarch64 \
        -M virt -m 2G \
        -drive file="$VOLATILE_DIR/qcom-guestvm-image-qcs9100-ride-sx.ext4",if=virtio,format=raw,bus=1,unit=0 \
        -kernel "$VOLATILE_DIR/Image" \
        -cpu host --enable-kvm -smp 4 -nographic -append 'root=/dev/vda' \
        < "$input_file" > "$serial_log" 2>&1 &
    echo $! > "$SCRIPT_DIR/qemu.pid"
)

QEMU_PID=$(cat "$SCRIPT_DIR/qemu.pid")
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

if [ $found_login -eq 1 ]; then
    log_pass "Login prompt detected"
else
    log_fail "Login prompt not detected"
fi

if [ $found_kvm -eq 1 ]; then
    log_pass "KVM usage confirmed in boot logs"
else
    log_warn "KVM not explicitly found in logs — fallback may have occurred"
fi

if [ $found_login -eq 1 ]; then
    echo "$TESTNAME PASS" > "$res_file"
else
    echo "$TESTNAME FAIL" > "$res_file"
fi

kill "$QEMU_PID" >/dev/null 2>&1
rm -f "$input_file" "$SCRIPT_DIR/qemu.pid"
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
