#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

TESTNAME="Apps_Suspend_Resume"
SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
PYTHON_BIN="${PYTHON_BIN:-python3}"

cd "$SCRIPT_DIR" || exit 1
rm -f "$RES_FILE"

log_info() {
    printf '[INFO] %s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)" "$*"
}

log_fail() {
    printf '[FAIL] %s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)" "$*"
}

log_skip() {
    printf '[SKIP] %s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)" "$*"
}

write_result_if_missing() {
    result="$1"

    if [ ! -s "$RES_FILE" ]; then
        echo "$TESTNAME $result" > "$RES_FILE"
    fi
}

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME host test ----------------------------"
log_info "Result file, $RES_FILE"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    log_skip "python3 is not available on host"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

if [ ! -f "$SCRIPT_DIR/suspend_resume.py" ]; then
    log_fail "suspend_resume.py not found in $SCRIPT_DIR"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

"$PYTHON_BIN" "$SCRIPT_DIR/suspend_resume.py" \
    --result-file "$RES_FILE" \
    "$@"
rc=$?

case "$rc" in
    0)
        write_result_if_missing "PASS"
        ;;
    77)
        write_result_if_missing "SKIP"
        ;;
    *)
        write_result_if_missing "FAIL"
        ;;
esac

log_info "Final result, $(cat "$RES_FILE" 2>/dev/null || echo unknown)"
log_info "------------------- Completed $TESTNAME host test ----------------------------"

exit "$rc"
