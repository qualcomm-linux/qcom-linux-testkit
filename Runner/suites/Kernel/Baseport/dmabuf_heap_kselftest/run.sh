#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="dmabuf_heap_kselftest"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "================================================================================"
log_info "============ Starting $TESTNAME Testcase ======================================="
log_info "================================================================================"

pass=true

DEFAULT_BINARY_PATH="/kselftest/dmabuf-heaps/dmabuf-heap"
BINARY_PATH="$DEFAULT_BINARY_PATH"

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run DMA-BUF Heap kselftest.

Options:
  -b, --binary-path <path>   Path to dmabuf-heap test binary
                             (default: $DEFAULT_BINARY_PATH)
  -h, --help                 Show this help and exit

Examples:
  $(basename "$0")
  $(basename "$0") --binary-path /vendor/bin/dmabuf-heap
  $(basename "$0") -b /data/local/tmp/dmabuf-heap
EOF
}

# Simple flag parser (POSIX sh)
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--binary-path)
            shift
            if [ $# -eq 0 ]; then
                echo "[ERROR] Missing value for --binary-path" >&2
                print_usage
                exit 2
            fi
            BINARY_PATH="$1"
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --) # end of options
            shift
            break
            ;;
        -*)
            echo "[ERROR] Unknown option: $1" >&2
            print_usage
            exit 2
            ;;
        *)  # positional (ignored to avoid old behavior)
            ;;
    esac
    shift
done

log_info "DMA-BUF Heap Kselftest Binary Path: $BINARY_PATH"

log_info "=== Checking for dmabuf-heap binary ==="

if [ ! -f "$BINARY_PATH" ]; then
    log_fail "dmabuf-heap binary not found at: $BINARY_PATH"
    log_info "Please provide the correct path as an argument:"
    log_info "  ./run.sh /path/to/dmabuf-heap"
    pass=false
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if [ ! -x "$BINARY_PATH" ]; then
    log_fail "dmabuf-heap binary is not executable: $BINARY_PATH"
    pass=false
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_pass "dmabuf-heap binary found and executable"

log_info "=== Running dmabuf-heap kselftest ==="

output_file="./OUTPUTFILE.res"

log_info "Executing: $BINARY_PATH"
if "$BINARY_PATH" > "$output_file" 2>&1; then
    test_exit_code=0
else
    test_exit_code=$?
fi

# Display the output
log_info "Test output:"
log_info "----------------------------------------"
while IFS= read -r line; do
    log_info "$line"
done < "$output_file"
log_info "----------------------------------------"

# Check if output contains TAP format
if ! grep -q "TAP version" "$output_file"; then
    log_warn "Output does not appear to be in TAP format"
fi


pass_count=0
fail_count=0
skip_count=0
error_count=0

# Parse the totals line if present
if grep -q "# Totals:" "$output_file"; then
    totals_line=$(grep "# Totals:" "$output_file")
    log_info "Test summary: $totals_line"

    pass_count=$(echo "$totals_line" | grep -o " pass:[0-9]*" | cut -d':' -f2)
    fail_count=$(echo "$totals_line" | grep -o " fail:[0-9]*" | cut -d':' -f2)
    skip_count=$(echo "$totals_line" | grep -o "skip:[0-9]*" | cut -d':' -f2)
    error_count=$(echo "$totals_line" | grep -o "error:[0-9]*" | cut -d':' -f2)

    pass_count=${pass_count:-0}
    fail_count=${fail_count:-0}
    skip_count=${skip_count:-0}
    error_count=${error_count:-0}
else
    pass_count=$(grep -c "^ok " "$output_file" || echo 0)
    fail_count=$(grep -c "^not ok " "$output_file" || echo 0)
    skip_count=$(grep -c "# SKIP" "$output_file" || echo 0)
fi

log_info "  Passed:  $pass_count"
log_info "  Failed:  $fail_count"
log_info "  Skipped: $skip_count"
log_info "  Errors:  $error_count"

if [ "$fail_count" -gt 0 ] || [ "$error_count" -gt 0 ]; then
    log_fail "Test FAILED: $fail_count failure(s), $error_count error(s)"
    pass=false
elif [ "$test_exit_code" -ne 0 ]; then
    log_fail "Test binary exited with non-zero code: $test_exit_code"
    pass=false
elif [ "$pass_count" -eq 0 ]; then
    log_fail "No tests passed - possible execution issue"
    pass=false
else
    log_pass "All tests passed successfully ($pass_count passed, $skip_count skipped)"
fi

rm -f "$output_file"

if $pass; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi