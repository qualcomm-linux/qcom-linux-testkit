#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# weston-simple-shm validation
# - Uses lib_display runtime helpers
# - No local overlay detection duplication
# - Base expects healthy Weston runtime
# - CI default does not relaunch Weston
# - Overlay can optionally relaunch only with --allow-relaunch
# - Exercises actual weston-simple-shm format behaviour
# - Logs client command, env, stdout/stderr, and result into each case log
# - CI friendly PASS FAIL SKIP semantics, always exits 0 after test start

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
    echo "[ERROR] Could not find init_env, starting at $SCRIPT_DIR" >&2
    exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_display.sh"

TESTNAME="weston-simple-shm"

test_path="$(find_test_case_by_name "$TESTNAME")" || {
    log_fail "$TESTNAME, test directory not found"
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 0
}

cd "$test_path" || exit 1

RES_FILE="./${TESTNAME}.res"
RUN_LOG="./${TESTNAME}_run.log"

: >"$RES_FILE"
: >"$RUN_LOG"

WAIT_SECS="${WAIT_SECS:-10}"
DURATION="${DURATION:-5}"
STARTUP_WAIT="${STARTUP_WAIT:-3}"
STOP_GRACE="${STOP_GRACE:-3}"
ALLOW_RELAUNCH="${ALLOW_RELAUNCH:-0}"
REQUIRED_FORMATS="${REQUIRED_FORMATS:-default xrgb8888}"
OPTIONAL_FORMATS="${OPTIONAL_FORMATS:-argb8888 rgb565}"
CASE_LOG_LINES="${CASE_LOG_LINES:-40}"

print_usage() {
    cat <<EOF
Usage: ./run.sh [OPTIONS]

Options:
  --allow-relaunch Allow Weston runtime relaunch when runtime is unhealthy
                          Default is disabled and should stay disabled for CI
  --duration SEC Keep each weston-simple-shm case running for SEC seconds, default: ${DURATION}
  --startup-wait SEC Wait SEC seconds after launch before startup verdict, default: ${STARTUP_WAIT}
  --stop-grace SEC Grace period after INT before KILL, default: ${STOP_GRACE}
  --required-formats STR Space-separated required formats, default: "${REQUIRED_FORMATS}"
  --optional-formats STR Space-separated optional formats, default: "${OPTIONAL_FORMATS}"
  -h, --help Show this help

Notes:
  - Use the literal token "default" to run weston-simple-shm without -F.
  - Required formats affect PASS/FAIL.
  - Optional formats are logged for coverage and do not change final verdict.
  - CI should not use --allow-relaunch by default.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --allow-relaunch)
            ALLOW_RELAUNCH=1
            shift
            ;;
        --duration)
            if [ $# -lt 2 ]; then
                log_fail "$TESTNAME, missing value for --duration"
                echo "$TESTNAME FAIL" >"$RES_FILE"
                exit 0
            fi
            DURATION="$2"
            shift 2
            ;;
        --startup-wait)
            if [ $# -lt 2 ]; then
                log_fail "$TESTNAME, missing value for --startup-wait"
                echo "$TESTNAME FAIL" >"$RES_FILE"
                exit 0
            fi
            STARTUP_WAIT="$2"
            shift 2
            ;;
        --stop-grace)
            if [ $# -lt 2 ]; then
                log_fail "$TESTNAME, missing value for --stop-grace"
                echo "$TESTNAME FAIL" >"$RES_FILE"
                exit 0
            fi
            STOP_GRACE="$2"
            shift 2
            ;;
        --required-formats)
            if [ $# -lt 2 ]; then
                log_fail "$TESTNAME, missing value for --required-formats"
                echo "$TESTNAME FAIL" >"$RES_FILE"
                exit 0
            fi
            REQUIRED_FORMATS="$2"
            shift 2
            ;;
        --optional-formats)
            if [ $# -lt 2 ]; then
                log_fail "$TESTNAME, missing value for --optional-formats"
                echo "$TESTNAME FAIL" >"$RES_FILE"
                exit 0
            fi
            OPTIONAL_FORMATS="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
        *)
            log_fail "$TESTNAME, unknown argument $1"
            print_usage
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
            ;;
    esac
done

APP_PID=""

# Called indirectly via trap.
# shellcheck disable=SC2317
cleanup_client() {
    if [ -n "$APP_PID" ]; then
        if kill -0 "$APP_PID" 2>/dev/null; then
            kill -INT "$APP_PID" 2>/dev/null || true
            sleep 1
            if kill -0 "$APP_PID" 2>/dev/null; then
                kill -KILL "$APP_PID" 2>/dev/null || true
            fi
        fi
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    fi
}

show_case_log_output() {
    scl_log="$1"
    scl_prefix="$2"

    if [ ! -f "$scl_log" ]; then
        log_info "[$scl_prefix] log file not found, $scl_log"
        return 0
    fi

    if [ ! -s "$scl_log" ]; then
        log_info "[$scl_prefix] client log is empty"
        return 0
    fi

    log_info "[$scl_prefix] client output from, $scl_log"
    sed -n "1,${CASE_LOG_LINES}p" "$scl_log" 2>/dev/null | while IFS= read -r line; do
        [ -n "$line" ] && log_info "[$scl_prefix] $line"
    done

    line_count="$(wc -l <"$scl_log" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$line_count" ]; then
        line_count=0
    fi
    if [ "$line_count" -gt "$CASE_LOG_LINES" ]; then
        log_info "[$scl_prefix] output truncated to first ${CASE_LOG_LINES} lines, total_lines=${line_count}"
    fi
}

run_format_case() {
    rfc_format="$1"
    rfc_required="$2"
    rfc_case_name="$1"
    rfc_case_log=""
    rfc_rc=0
    rfc_elapsed=0
    rfc_status="FAIL"
    rfc_cmd=""

    if [ "$rfc_format" = "default" ]; then
        rfc_case_name="default"
        rfc_cmd="$SHM_BIN"
    else
        rfc_cmd="$SHM_BIN -F $rfc_format"
    fi

    timestamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo 19700101-000000)"
    rfc_case_log="./${TESTNAME}_${rfc_case_name}_${timestamp}.log"

    : >"$rfc_case_log"

    {
        printf '%s\n' "case_name=${rfc_case_name}"
        printf '%s\n' "format=${rfc_format}"
        printf '%s\n' "required=${rfc_required}"
        printf '%s\n' "command=${rfc_cmd}"
        printf '%s\n' "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
        printf '%s\n' "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
        printf '%s\n' "----- client stdout/stderr begin -----"
    } >>"$rfc_case_log"

    log_info "----- weston-simple-shm case start, format=${rfc_format} required=${rfc_required} -----"
    log_info "Case log, ${rfc_case_log}"
    log_info "Launch command, ${rfc_cmd}"

    if [ "$rfc_format" = "default" ]; then
        "$SHM_BIN" >>"$rfc_case_log" 2>&1 &
    else
        "$SHM_BIN" -F "$rfc_format" >>"$rfc_case_log" 2>&1 &
    fi
    APP_PID="$!"

    sleep "$STARTUP_WAIT"

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        wait "$APP_PID" 2>/dev/null
        rfc_rc=$?

        {
            printf '%s\n' "----- client stdout/stderr end -----"
            printf '%s\n' "startup_rc=${rfc_rc}"
        } >>"$rfc_case_log"

        if grep -F "not supported by compositor" "$rfc_case_log" >/dev/null 2>&1; then
            if [ "$rfc_required" = "1" ]; then
                log_fail "Required format not supported by compositor, ${rfc_format}"
                printf '%s\n' "result=FAIL reason=compositor-unsupported" >>"$rfc_case_log"
                show_case_log_output "$rfc_case_log" "client"
                printf '%s\n' "case=${rfc_format} status=FAIL reason=compositor-unsupported log=${rfc_case_log}" >>"$RUN_LOG"
                APP_PID=""
                return 1
            fi
            log_warn "Optional format not supported by compositor, ${rfc_format}"
            printf '%s\n' "result=SKIP reason=compositor-unsupported" >>"$rfc_case_log"
            show_case_log_output "$rfc_case_log" "client"
            printf '%s\n' "case=${rfc_format} status=SKIP reason=compositor-unsupported log=${rfc_case_log}" >>"$RUN_LOG"
            APP_PID=""
            return 2
        fi

        if grep -F "not supported by client" "$rfc_case_log" >/dev/null 2>&1; then
            if [ "$rfc_required" = "1" ]; then
                log_fail "Required format not supported by client binary, ${rfc_format}"
                printf '%s\n' "result=FAIL reason=client-unsupported" >>"$rfc_case_log"
                show_case_log_output "$rfc_case_log" "client"
                printf '%s\n' "case=${rfc_format} status=FAIL reason=client-unsupported log=${rfc_case_log}" >>"$RUN_LOG"
                APP_PID=""
                return 1
            fi
            log_warn "Optional format not supported by client binary, ${rfc_format}"
            printf '%s\n' "result=SKIP reason=client-unsupported" >>"$rfc_case_log"
            show_case_log_output "$rfc_case_log" "client"
            printf '%s\n' "case=${rfc_format} status=SKIP reason=client-unsupported log=${rfc_case_log}" >>"$RUN_LOG"
            APP_PID=""
            return 2
        fi

        log_fail "weston-simple-shm exited during startup, format=${rfc_format}, rc=${rfc_rc}"
        printf '%s\n' "result=FAIL reason=startup-exit rc=${rfc_rc}" >>"$rfc_case_log"
        show_case_log_output "$rfc_case_log" "client"
        printf '%s\n' "case=${rfc_format} status=FAIL reason=startup-exit rc=${rfc_rc} log=${rfc_case_log}" >>"$RUN_LOG"
        APP_PID=""
        return 1
    fi

    log_info "weston-simple-shm started successfully, format=${rfc_format}, monitoring for ${DURATION} seconds"

    rfc_elapsed=0
    while [ "$rfc_elapsed" -lt "$DURATION" ]; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            wait "$APP_PID" 2>/dev/null
            rfc_rc=$?

            {
                printf '%s\n' "----- client stdout/stderr end -----"
                printf '%s\n' "monitor_rc=${rfc_rc}"
                printf '%s\n' "result=FAIL reason=early-exit"
            } >>"$rfc_case_log"

            log_fail "weston-simple-shm exited before completing monitor window, format=${rfc_format}, rc=${rfc_rc}"
            show_case_log_output "$rfc_case_log" "client"
            printf '%s\n' "case=${rfc_format} status=FAIL reason=early-exit rc=${rfc_rc} log=${rfc_case_log}" >>"$RUN_LOG"
            APP_PID=""
            return 1
        fi
        sleep 1
        rfc_elapsed=$((rfc_elapsed + 1))
    done

    log_info "Stopping weston-simple-shm with SIGINT, format=${rfc_format}, grace=${STOP_GRACE}s"
    kill -INT "$APP_PID" 2>/dev/null || true

    rfc_elapsed=0
    while [ "$rfc_elapsed" -lt "$STOP_GRACE" ]; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            break
        fi
        sleep 1
        rfc_elapsed=$((rfc_elapsed + 1))
    done

    if kill -0 "$APP_PID" 2>/dev/null; then
        log_warn "weston-simple-shm did not stop after SIGINT, sending KILL, format=${rfc_format}"
        kill -KILL "$APP_PID" 2>/dev/null || true
    fi

    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""

    {
        printf '%s\n' "----- client stdout/stderr end -----"
        printf '%s\n' "result=PASS"
    } >>"$rfc_case_log"

    show_case_log_output "$rfc_case_log" "client"

    rfc_status="PASS"
    log_pass "weston-simple-shm case passed, format=${rfc_format}"
    printf '%s\n' "case=${rfc_format} status=${rfc_status} log=${rfc_case_log}" >>"$RUN_LOG"
    log_info "----- weston-simple-shm case end, format=${rfc_format}, status=${rfc_status} -----"
    return 0
}

trap 'cleanup_client' EXIT HUP INT TERM

log_info "Weston log directory, $SCRIPT_DIR"
log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase --------------------------"
log_info "Config, WAIT_SECS=${WAIT_SECS} DURATION=${DURATION} STARTUP_WAIT=${STARTUP_WAIT} STOP_GRACE=${STOP_GRACE} ALLOW_RELAUNCH=${ALLOW_RELAUNCH}"
log_info "Required formats, ${REQUIRED_FORMATS}"
log_info "Optional formats, ${OPTIONAL_FORMATS}"

if [ "$ALLOW_RELAUNCH" = "1" ]; then
    log_warn "Weston relaunch is enabled for this run"
else
    log_info "Weston relaunch is disabled by default, recommended for CI"
fi

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform
fi

display_detect_build_flavour

if [ "$DISPLAY_BUILD_FLAVOUR" = "overlay" ]; then
    log_info "Build flavor, overlay, EGL vendor JSON present: ${DISPLAY_EGL_VENDOR_JSON}"
else
    log_info "Build flavor, base, no Adreno EGL vendor JSON found"
fi

if ! display_log_snapshot_and_require_connector "$TESTNAME" 200; then
    echo "${TESTNAME} SKIP" >"$RES_FILE"
    exit 0
fi

if ! weston_prepare_runtime "$TESTNAME" "$WAIT_SECS" runtime "$ALLOW_RELAUNCH"; then
    echo "${TESTNAME} FAIL" >"$RES_FILE"
    exit 0
fi

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies grep sed wc; then
    log_skip "$TESTNAME SKIP: missing dependencies"
    echo "${TESTNAME} SKIP" >"$RES_FILE"
    exit 0
fi

SHM_BIN="$(command -v weston-simple-shm 2>/dev/null || true)"
if [ -z "$SHM_BIN" ]; then
    log_skip "weston-simple-shm binary not found, skipping"
    echo "${TESTNAME} SKIP" >"$RES_FILE"
    exit 0
fi

required_fail_count=0
required_pass_count=0
optional_pass_count=0
optional_skip_count=0

for fmt in $REQUIRED_FORMATS; do
    if run_format_case "$fmt" 1; then
        required_pass_count=$((required_pass_count + 1))
    else
        required_fail_count=$((required_fail_count + 1))
    fi
done

for fmt in $OPTIONAL_FORMATS; do
    if run_format_case "$fmt" 0; then
        optional_pass_count=$((optional_pass_count + 1))
    else
        rc=$?
        if [ "$rc" -eq 2 ]; then
            optional_skip_count=$((optional_skip_count + 1))
        else
            log_warn "Optional format case failed unexpectedly, ${fmt}"
            optional_skip_count=$((optional_skip_count + 1))
        fi
    fi
done

trap - EXIT HUP INT TERM

log_info "Summary, required_pass=${required_pass_count} required_fail=${required_fail_count} optional_pass=${optional_pass_count} optional_skip=${optional_skip_count}"

if [ "$required_fail_count" -eq 0 ] && [ "$required_pass_count" -gt 0 ]; then
    log_info "Final decision for ${TESTNAME}, PASS"
    echo "${TESTNAME} PASS" >"$RES_FILE"
    log_pass "${TESTNAME} : PASS"
    exit 0
fi

log_fail "${TESTNAME}, one or more required format cases failed"
echo "${TESTNAME} FAIL" >"$RES_FILE"
exit 0
