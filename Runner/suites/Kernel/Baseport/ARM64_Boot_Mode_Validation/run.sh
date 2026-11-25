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
TESTNAME="ARM64_Boot_Mode_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

EXPECTED_MODE=""

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate consistent Arm64 CPU entry exception levels.
  --expected-mode <value>  Optional EL1 or EL2 contract, otherwise require consistent entry
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
            --expected-mode)
                EXPECTED_MODE="$2"
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


case "$EXPECTED_MODE" in
    ''|EL1|EL2)
        ;;
    *)
        test_result_finish FAIL "--expected-mode must be EL1 or EL2"
        ;;
esac

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

if grep -Fq 'CPU: CPUs started in inconsistent modes' "$snapshot"; then
    test_result_finish FAIL "The kernel detected inconsistent CPU entry modes, inspect $snapshot"
fi
sed -n 's/.*CPU: All CPU(s) started at \(EL[12]\).*/\1/p' "$snapshot" >"$OUT_DIR/entry-mode.log"
count=$(awk 'END {print NR}' "$OUT_DIR/entry-mode.log")
if [ "$count" -eq 0 ]; then
    test_result_finish SKIP "CPU entry-mode log is unavailable or rotated, retain the early Arm64 SMP boot log"
fi
if [ "$count" -ne 1 ]; then
    test_result_finish FAIL "Expected one completed CPU entry-mode check, found $count entries"
fi
mode=$(cat "$OUT_DIR/entry-mode.log")
if [ -n "$EXPECTED_MODE" ] && [ "$mode" != "$EXPECTED_MODE" ]; then
    test_result_record FAIL "CPU entry mode=$mode differs from expected=$EXPECTED_MODE"
else
    test_result_record PASS "Kernel confirms every boot CPU entered at $mode"
fi

test_result_finish
