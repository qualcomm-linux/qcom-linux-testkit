#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

# --- Parse CLI argument for custom binary path ---
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --binary-path=PATH   Specify a custom path to the posix_timers binary else run by default from /usr/bin.
  -h, --help           Show this help message and exit.

Example:
  $0 --binary-path=/custom/path/posix_timers
  $0 

EOF
}


BINARY_PATH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --binary-path=*)
            BINARY_PATH="${1#*=}"
            ;;
		-h|--help)
            show_help
            exit 0
            ;;
        *)
            ;;
    esac
    shift
done

TESTNAME="Timer"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# --- Determine binary to use ---
if [ -n "$BINARY_PATH" ]; then
    BINARY="$BINARY_PATH"
else
    BINARY="posix_timers"
fi

# --- Check if binary exists in PATH or at custom path ---
check_dependencies "$BINARY"
if [ $? -ne 0 ]; then
    log_skip "$TESTNAME : Binary '$BINARY' not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Run the binary and capture the output
OUTPUT=$($BINARY)
echo $OUTPUT

# Check if "pass:7" is in the output
if echo "${OUTPUT}" | grep "pass:7"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
