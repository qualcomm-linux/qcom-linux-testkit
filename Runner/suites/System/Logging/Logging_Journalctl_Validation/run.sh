#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Logging / journalctl validation:
# - verifies required logging tools are available
# - verifies systemd-journald service is active
# - prints journald service status to stdout
# - detects an active /var/log sink file
# - prints available log files under /var/log
# - emits a custom test message through logger
# - verifies the message in journalctl and prints the matched line
# - verifies the message in the detected log file and prints the matched line
# - validates journal storage mode sanity
# - validates journal boot list sanity
# - validates unit-scoped journal queries
# - validates priority-based journal filtering
# - writes PASS/FAIL to .res and exits 0 so LAVA can continue

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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_logger.sh"

TESTNAME="Logging_Journalctl_Validation"
RETRY_COUNT="${RETRY_COUNT:-5}"
RETRY_SLEEP_SECS="${RETRY_SLEEP_SECS:-1}"

test_path="$(find_test_case_by_name "$TESTNAME")"
if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies journalctl systemctl logger grep sed awk tail; then
    log_skip "$TESTNAME SKIP: missing dependencies"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Config, RETRY_COUNT=$RETRY_COUNT RETRY_SLEEP_SECS=$RETRY_SLEEP_SECS"

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform
fi

log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='$(uname -r 2>/dev/null || echo unknown)' arch='$(uname -m 2>/dev/null || echo unknown)'"

log_info "----- systemd-journald service snapshot -----"
journald_state="$(systemctl is-active systemd-journald.service 2>/dev/null || echo unknown)"
log_info "Service: systemd-journald.service state=$journald_state"
systemctl status systemd-journald.service --no-pager --full 2>/dev/null | sed -n '1,12p' | while IFS= read -r line; do
    [ -n "$line" ] && log_info "[journald-status] $line"
done
log_info "----- End systemd-journald service snapshot -----"

if ! check_systemd_services systemd-journald.service; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! logging_detect_log_file; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! logging_emit_test_message; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! logging_verify_test_message_in_journalctl "$RETRY_COUNT" "$RETRY_SLEEP_SECS"; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! logging_verify_test_message_in_log_file "$RETRY_COUNT" "$RETRY_SLEEP_SECS"; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! logging_check_journal_storage_mode; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! logging_check_boot_list_sanity; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! logging_check_unit_scoped_query systemd-journald.service; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! logging_emit_priority_test_message; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! logging_verify_priority_message_in_journalctl "$RETRY_COUNT" "$RETRY_SLEEP_SECS"; then
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

log_pass "$TESTNAME : PASS"
echo "$TESTNAME PASS" > "$RES_FILE"
exit 0
