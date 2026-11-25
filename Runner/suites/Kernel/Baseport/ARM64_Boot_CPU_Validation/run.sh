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
TESTNAME="ARM64_Boot_CPU_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

EXPECTED_MPIDR=""

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate the physical boot CPU identity recorded by the Arm64 kernel.
  --expected-mpidr <value>  Expected physical boot CPU MPIDR in hexadecimal
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
            --expected-mpidr)
                EXPECTED_MPIDR="$2"
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


if [ -z "$EXPECTED_MPIDR" ]; then
    test_result_finish SKIP "Provide --expected-mpidr from the firmware boot contract"
fi
if ! printf '%s\n' "$EXPECTED_MPIDR" | grep -Eq '^(0[xX])?[0-9a-fA-F]{1,16}$'; then
    test_result_finish FAIL "--expected-mpidr must contain up to 16 hexadecimal digits"
fi

case "$(uname -m)" in
    aarch64|arm64)
        ;;
    *)
        test_result_finish SKIP "This boot contract requires an Arm64 kernel"
        ;;
esac
scan_dmesg_errors "$OUT_DIR/kernel" '.' '' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_finish SKIP "Kernel boot evidence is inaccessible, provide kernel-log access and inspect $OUT_DIR/kernel"
fi
snapshot="$OUT_DIR/kernel/dmesg_snapshot.log"

sed -n 's/.*Booting Linux on physical CPU \(0x[0-9a-fA-F]*\) .*/\1/p' "$snapshot" >"$OUT_DIR/boot-mpidr.log"
count=$(awk 'END {print NR}' "$OUT_DIR/boot-mpidr.log")
if [ "$count" -eq 0 ]; then
    test_result_finish SKIP "Boot CPU log is unavailable or rotated, run with a retained early kernel log"
fi
if [ "$count" -ne 1 ]; then
    test_result_finish FAIL "Expected one boot CPU identity, found $count entries in the captured log"
fi
observed=$(sed 's/^0x//; s/^0*//' "$OUT_DIR/boot-mpidr.log" | tr 'A-F' 'a-f')
expected=$(printf '%s\n' "$EXPECTED_MPIDR" | sed 's/^0[xX]//; s/^0*//' | tr 'A-F' 'a-f')
if [ "${observed:-0}" = "${expected:-0}" ]; then
    test_result_record PASS "Physical boot CPU matches MPIDR=$EXPECTED_MPIDR"
else
    test_result_record FAIL "Boot CPU MPIDR=0x${observed:-0} differs from expected=$EXPECTED_MPIDR"
fi

test_result_finish
