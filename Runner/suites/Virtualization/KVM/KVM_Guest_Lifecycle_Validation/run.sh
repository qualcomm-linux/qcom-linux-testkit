#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
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
    exit 1
fi

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_kvm.sh"
TESTNAME="KVM_Guest_Lifecycle_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

BINARY=""
KERNEL="/opt/kvm-guest/Image"
INITRD="/opt/kvm-guest/initramfs.cpio.gz"
VCPUS=""
MEMORY="256"
TIMEOUT="120"

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Boot an isolated Linux KVM guest, execute a console command and verify clean shutdown.
  --binary <value>  Installed lkvm executable, otherwise PATH discovery
  --kernel <value>  Image-provided guest kernel
  --initrd <value>  Guest initramfs with the kvm-guest ready protocol
  --vcpus <value>  Guest CPU count, otherwise up to two online host CPUs
  --memory <value>  Guest memory in MiB
  --timeout <value>  Overall guest boot, command and shutdown deadline in seconds
EOF
}

# parse_args <arguments>...
# Parse explicit values before accessing runtime evidence.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_finish FAIL "Missing value for $1"
        fi
        case "$2" in
            --*)
                test_result_finish FAIL "Missing value for $1 before option=$2"
                ;;
        esac
        case "$1" in
            --binary)
                BINARY="$2"
                ;;
            --kernel)
                KERNEL="$2"
                ;;
            --initrd)
                INITRD="$2"
                ;;
            --vcpus)
                VCPUS="$2"
                ;;
            --memory)
                MEMORY="$2"
                ;;
            --timeout)
                TIMEOUT="$2"
                ;;
            *)
                test_result_finish FAIL "Unknown option=$1"
                ;;
        esac
        shift 2
    done
}

parse_args "$@"

# shellcheck disable=SC2034 # Read by the shared dependency helper.
CHECK_DEPS_RECOVER=0
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat awk grep sed tr uname mkdir mktemp date; then
    test_result_finish SKIP "Required shell tools are absent, provision them in the image"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create retained evidence under CWD=$PWD"


if ! CHECK_DEPS_NO_EXIT=1 check_dependencies python3 env setsid; then
    test_result_finish SKIP "Guest console validation requires image-provided python3, env and setsid"
fi
case "$(uname -m)" in
    aarch64|arm64)
        ;;
    *)
        test_result_finish SKIP "This guest launch contract requires an Arm64 host and matching guest assets"
        ;;
esac
if [ -z "$VCPUS" ]; then
    online=$(cat /sys/devices/system/cpu/online 2>/dev/null)
    if ! kernel_cpu_list_valid "$online"; then
        test_result_finish SKIP "Cannot discover host online CPUs, provide sysfs CPU topology or --vcpus"
    fi
    VCPUS=$(expand_cpu_list "$online" | awk 'END {print NR > 1 ? 2 : NR}')
fi
for value in "$VCPUS" "$MEMORY" "$TIMEOUT"; do
    if ! printf '%s\n' "$value" | grep -Eq '^[1-9][0-9]{0,7}$'; then
        test_result_finish FAIL "CPU count, memory and timeout must be positive decimal integers of at most eight digits"
    fi
done
if [ -z "$BINARY" ]; then
    BINARY=$(command -v lkvm 2>/dev/null || true)
else
    BINARY=$(command -v "$BINARY" 2>/dev/null || true)
fi
if [ -z "$BINARY" ] || [ ! -x "$BINARY" ] || [ ! -s "$KERNEL" ] || [ ! -s "$INITRD" ]; then
    test_result_finish SKIP "Provision lkvm and a matching guest kernel/initramfs, or select them with --binary, --kernel and --initrd"
fi
if ! kvm_check_boot_dmesg_errors "$OUT_DIR/before"; then
    test_result_finish FAIL "KVM initialization contains faults, inspect $OUT_DIR/before"
fi
kvm_check_device_node
device_status=$?
if [ "$device_status" -eq 2 ]; then
    test_result_finish SKIP "No /dev/kvm, enable KVM and firmware virtualization support"
elif [ "$device_status" -ne 0 ]; then
    test_result_finish FAIL "The existing /dev/kvm is unusable, check permissions and device provisioning"
fi
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_finish SKIP "Guest validation needs readable kernel logs for host health evidence"
fi
if ! awk -v memory="$MEMORY" '
    /^MemAvailable:/ {found=1; enough=($2 >= memory*2048)}
    END {exit !(found && enough)}
' /proc/meminfo; then
    test_result_finish SKIP "Guest memory=$MEMORY MiB exceeds half of available host memory, choose a smaller guest or a larger isolated target"
fi
if [ ! -d "${HOME:-}" ] || [ ! -w "$HOME" ]; then
    test_result_finish SKIP "kvmtool requires a writable existing HOME for its control socket"
fi
# A PTY is required by kvmtool, piping stdin alone silently drops console input.
# Python supplies the terminal without starting another shell or altering HOME.
# shellcheck disable=SC2034 # Shared timeout/finish consume these controls.
MANAGED_TIMEOUT_USE_SESSION=1
# shellcheck disable=SC2034
TEST_RESULT_CLEANUP=managed_timeout_cancel_bounded
trap 'test_result_finish FAIL "KVM guest lifecycle validation interrupted"' HUP INT TERM
outer_timeout=$((TIMEOUT + 5))
run_with_managed_timeout "$outer_timeout" "$OUT_DIR" guest python3 - \
    "$BINARY" "$KERNEL" "$INITRD" "$VCPUS" "$MEMORY" "$TIMEOUT" "$OUT_DIR" <<'PY' >"$OUT_DIR/driver.log" 2>&1
import errno
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import time
import uuid

binary, kernel, initrd, vcpus, memory, timeout, output = sys.argv[1:]
output = Path(output)
nonce = uuid.uuid4().hex
start = time.monotonic()
deadline = start + int(timeout)
master, slave = os.openpty()
guest = None
buffer = b''
status = 1
console = (output / 'console.log').open('wb')
evidence = (output / 'guest-evidence.log').open('w')


def await_console(pattern):
    # Exchange framed console messages while retaining the complete byte stream.
    global buffer
    expression = re.compile(pattern, re.MULTILINE)
    while time.monotonic() < deadline:
        match = expression.search(buffer.replace(b'\r', b''))
        if match:
            return match
        readable, unused_write, unused_error = select.select([master], [], [], 0.1)
        if readable:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b''
            if not chunk:
                raise RuntimeError('Guest console closed before the expected response')
            console.write(chunk)
            console.flush()
            buffer = (buffer + chunk)[-1048576:]
        elif guest.poll() is not None:
            raise RuntimeError('VMM exited before the expected response')
    raise TimeoutError('Guest console deadline expired')


try:
    guest = subprocess.Popen(
        [binary, 'run', '--name', 'testkit-' + nonce, '--kernel', kernel,
         '--initrd', initrd, '--cpus', vcpus, '--mem', memory,
         '--console', 'virtio', '--network', 'mode=none', '--params', 'quiet'],
        stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    slave = None
    ready = await_console(rb'^kvm-guest: ready[^\n]*\bvcpus=([0-9]+)(?: |\n)')
    evidence.write('boot_seconds=%.3f\n' % (time.monotonic() - start))
    if int(ready.group(1)) != int(vcpus):
        raise RuntimeError('Guest online CPU count differs from requested vCPUs')
    evidence.write('boot=PASS\nvcpus=PASS\n')
    # Echoed input contains the arithmetic expression, only execution prints 42.
    command = "printf 'testkit-" + nonce + ": %s\\n' \"$((6 * 7))\"\n"
    os.write(master, command.encode())
    await_console(('^testkit-' + nonce + ': 42\n').encode())
    evidence.write('command=PASS\n')
    os.write(master, b'poweroff -f\n')
    while guest.poll() is None and time.monotonic() < deadline:
        readable, unused_write, unused_error = select.select([master], [], [], 0.1)
        if readable:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b''
            console.write(chunk)
    if guest.poll() is None:
        raise TimeoutError('Guest did not power off within the overall deadline')
    if guest.returncode != 0:
        raise RuntimeError('VMM exited status=' + str(guest.returncode))
    evidence.write('shutdown=PASS\n')
    status = 0
except Exception as error:
    print(str(error), flush=True)
finally:
    if guest is not None and guest.poll() is None:
        guest.terminate()
        try:
            guest.wait(timeout=2)
        except subprocess.TimeoutExpired:
            guest.kill()
            try:
                guest.wait(timeout=2)
            except subprocess.TimeoutExpired:
                print('VMM survived bounded cleanup', flush=True)
                status = 1
    if slave is not None:
        os.close(slave)
    os.close(master)
    console.close()
    evidence.close()
sys.exit(status)
PY
guest_status=$?
if [ "$guest_status" -ne 0 ]; then
    test_result_record FAIL "Guest lifecycle exited status=$guest_status, inspect $OUT_DIR/driver.log and console.log"
else
    for stage in boot vcpus command shutdown; do
        if grep -Fxq "$stage=PASS" "$OUT_DIR/guest-evidence.log"; then
            test_result_record PASS "Guest lifecycle stage=$stage completed"
        else
            test_result_record FAIL "Guest lifecycle omitted evidence for stage=$stage"
        fi
    done
fi
if ! kvm_check_boot_dmesg_errors "$OUT_DIR/after"; then
    test_result_record FAIL "Guest execution produced host kernel faults, inspect $OUT_DIR/after"
elif [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_record FAIL "Host kernel evidence became unavailable after guest execution"
fi

test_result_finish
