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
. "$TOOLS/lib_optee.sh"
TESTNAME="OPTEE_Native_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

OPTEE_XTEST_BIN_SOURCE="default"
OPTEE_XTEST_CASES_SOURCE="default-safe-allowlist"
OPTEE_XTEST_TIMEOUT_SOURCE="default"
if [ -n "${OPTEE_XTEST_BIN:-}" ]; then
    OPTEE_XTEST_BIN_SOURCE="environment"
fi
if [ -n "${OPTEE_XTEST_CASES:-}" ]; then
    OPTEE_XTEST_CASES_SOURCE="environment"
fi
if [ -n "${OPTEE_XTEST_TIMEOUT:-}" ]; then
    OPTEE_XTEST_TIMEOUT_SOURCE="environment"
fi
OPTEE_XTEST_BIN="${OPTEE_XTEST_BIN:-xtest}"
OPTEE_XTEST_CASES="${OPTEE_XTEST_CASES:-1001,1002}"
OPTEE_XTEST_TIMEOUT="${OPTEE_XTEST_TIMEOUT:-30}"
OPTEE_XTEST_TIMEOUT_MAX=300
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
CASE_LIST_FILE="$RESULT_DIR/cases.list"
DEVICE_INVENTORY="$RESULT_DIR/tee_devices.tsv"
OPTEE_EXECUTED_PASS_COUNT=0

# usage
# Takes no arguments, prints the CLI contract to stdout, returns 0, and has no
# side effects.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --xtest PATH        Override xtest command discovery" \
        "  --cases LIST        Select a subset of the built-in safe allowlist" \
        "  --timeout SECONDS   Per-case timeout, default: 30" \
        "  -h, --help" \
        "The OP-TEE device and default xtest command are discovered automatically." \
        "Only the built-in safe allowlist may be selected."
}

# parse_args <arguments...>
# Parses CLI options into OPTEE_* globals without producing stdout. Returns 0
# on success or 2 for an unknown option or missing value and has no other side
# effects.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --xtest)
                [ "$#" -ge 2 ] || return 2
                OPTEE_XTEST_BIN="$2"
                OPTEE_XTEST_BIN_SOURCE="cli"
                shift 2
                ;;
            --cases)
                [ "$#" -ge 2 ] || return 2
                OPTEE_XTEST_CASES="$2"
                OPTEE_XTEST_CASES_SOURCE="cli"
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                OPTEE_XTEST_TIMEOUT="$2"
                OPTEE_XTEST_TIMEOUT_SOURCE="cli"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                return 2
                ;;
        esac
    done
}

parse_args "$@" || {
    usage >&2
    exit 2
}

test_result_init "$TESTNAME" "$RES_FILE"
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "OP-TEE native validation: running only an explicitly allowlisted, bounded xtest regression subset"
log_info "Configuration: xtest=$OPTEE_XTEST_BIN xtest_source=$OPTEE_XTEST_BIN_SOURCE cases=$OPTEE_XTEST_CASES cases_source=$OPTEE_XTEST_CASES_SOURCE timeout=${OPTEE_XTEST_TIMEOUT}s timeout_source=$OPTEE_XTEST_TIMEOUT_SOURCE"
log_info "[OPTEE-POLICY] device=dynamic xtest=$OPTEE_XTEST_BIN xtest_source=$OPTEE_XTEST_BIN_SOURCE cases=$OPTEE_XTEST_CASES cases_source=$OPTEE_XTEST_CASES_SOURCE allowlist=$OPTEE_SAFE_XTEST_CASES"

if [ -z "$OPTEE_XTEST_BIN" ]; then
    test_result_record "FAIL" "OP-TEE xtest command must not be empty"
    test_result_finish
fi

case "$OPTEE_XTEST_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "OP-TEE xtest timeout must be a positive integer"
        test_result_finish
        ;;
esac
if ! awk \
    -v timeout="$OPTEE_XTEST_TIMEOUT" \
    -v maximum="$OPTEE_XTEST_TIMEOUT_MAX" \
    'BEGIN { exit !(timeout <= maximum) }'; then
    test_result_record "FAIL" "OP-TEE xtest timeout must not exceed ${OPTEE_XTEST_TIMEOUT_MAX}s per case"
    test_result_finish
fi

case "$OPTEE_XTEST_CASES" in
    '')
        test_result_record "FAIL" "No xtest case was selected"
        test_result_finish
        ;;
    ,*|*,|*,,*|*[!0-9,]*)
        test_result_record "FAIL" "OP-TEE xtest case selection is malformed, observed=$OPTEE_XTEST_CASES"
        test_result_finish
        ;;
esac

if ! optee_capture_device_inventory "$DEVICE_INVENTORY"; then
    test_result_record "FAIL" "TEE device inventory could not be captured"
    test_result_finish
fi
optee_log_device_inventory "$DEVICE_INVENTORY" 16
OPTEE_SELECTION=$(optee_select_device "$DEVICE_INVENTORY" 2>/dev/null || true)
OPTEE_DEVICE=$(printf '%s\n' "$OPTEE_SELECTION" | cut -f 1)
OPTEE_DEVICE_SOURCE=$(printf '%s\n' "$OPTEE_SELECTION" | cut -f 2)
if [ -z "$OPTEE_DEVICE" ]; then
    test_result_record "SKIP" "No public native OP-TEE character device was identified from implementation_id or runtime parent evidence, tee_devices=$OPTEE_TEE_DEVICE_COUNT public_devices=$OPTEE_PUBLIC_DEVICE_COUNT native_candidates=$OPTEE_NATIVE_DEVICE_COUNT artifact=$DEVICE_INVENTORY"
    test_result_finish
fi

if [ -x "$OPTEE_XTEST_BIN" ]; then
    XTEST_PATH=$(readlink -f "$OPTEE_XTEST_BIN")
else
    XTEST_PATH=$(command -v "$OPTEE_XTEST_BIN" 2>/dev/null || true)
fi
if [ -z "$XTEST_PATH" ]; then
    log_info "[OPTEE-XTEST-DISCOVERY] requested=$OPTEE_XTEST_BIN resolved=not-found path=${PATH:-unset}"
    test_result_record "SKIP" "Native OP-TEE is present at $OPTEE_DEVICE but xtest is not image-provided"
    test_result_finish
fi

printf '%s\n' "$OPTEE_XTEST_CASES" | tr ',' '\n' | sort -u >"$CASE_LIST_FILE"
case_count=0
while IFS= read -r case_id; do
    if ! optee_xtest_case_is_allowed "$case_id"; then
        test_result_record "FAIL" "xtest case $case_id is outside the safe allowlist: $OPTEE_SAFE_XTEST_CASES"
        test_result_finish
    fi
    case_count=$((case_count + 1))
done <"$CASE_LIST_FILE"

if [ "$case_count" -eq 0 ]; then
    test_result_record "FAIL" "No xtest case was selected"
    test_result_finish
fi

log_info "[OPTEE-DISCOVERY] device=$OPTEE_DEVICE source=$OPTEE_DEVICE_SOURCE tee_identifier=optee-tz xtest=$XTEST_PATH selected_cases=$case_count"

while IFS= read -r case_id; do
    case_log="$RESULT_DIR/xtest_${case_id}.log"
    log_info "[OPTEE-XTEST] case=$case_id phase=start suite=regression level=0 timeout=${OPTEE_XTEST_TIMEOUT}s"
    run_with_timeout_log \
        "$OPTEE_XTEST_TIMEOUT" \
        "$case_log" \
        "$XTEST_PATH" -d optee-tz -t regression -l 0 "$case_id"
    xtest_rc=$?
    optee_validate_xtest_log "$case_log"
    validation_rc=$?
    optee_log_xtest_summary "$case_log" "$case_id"

    if [ "$xtest_rc" -eq 0 ] && [ "$validation_rc" -eq 0 ]; then
        log_info "[OPTEE-XTEST] case=$case_id rc=0 summary=pass artifact=$case_log"
        test_result_record "PASS" "Native OP-TEE xtest regression case $case_id passed"
        OPTEE_EXECUTED_PASS_COUNT=$((OPTEE_EXECUTED_PASS_COUNT + 1))
    elif [ "$xtest_rc" -eq 0 ] && [ "$validation_rc" -eq 2 ]; then
        log_info "[OPTEE-XTEST] case=$case_id rc=0 summary=skipped artifact=$case_log"
        test_result_record "SKIP" "Native OP-TEE xtest regression case $case_id was skipped by xtest, likely due to an optional PTA"
    else
        log_fail "[OPTEE-XTEST] case=$case_id rc=$xtest_rc summary=invalid-or-failed artifact=$case_log"
        log_file_with_label "OPTEE-XTEST-$case_id-DETAIL" "$case_log" 30
        test_result_record "FAIL" "Native OP-TEE xtest regression case $case_id failed or lacked a complete zero-failure summary"
    fi
done <"$CASE_LIST_FILE"

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'optee|tee|tee-supplicant' \
    'dynamic shared memory is disabled'
dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for OP-TEE health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$dmesg_rc" -eq 0 ]; then
    log_file_with_label "OPTEE-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 25
    test_result_record "FAIL" "OP-TEE kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No persistent OP-TEE kernel errors were found"
fi

if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$OPTEE_EXECUTED_PASS_COUNT" -eq 0 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: every selected native OP-TEE case was skipped by xtest"
fi

test_result_finish
