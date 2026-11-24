#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Validate weston-simple-damage through an existing usable Weston runtime.
#
# weston-simple-damage is a CPU-rendered SHM client that exercises the
# compositor's damage-tracking mechanism by periodically marking dirty regions
# of the surface buffer.
#
# Graphics-mode policy:
# - --auto is the default and preserves the currently active graphics stack.
# - --base validates that the active runtime is the MSM/freedreno base stack.
# - --overlay validates that the active runtime is the KGSL/Adreno overlay stack.
# - This runner does not install/remove graphics packages, modify boot artifacts,
#   or restart Weston merely to change graphics mode.
#
# The existing Weston runtime is discovered and reused. PASS/FAIL/SKIP is
# written to the result file and testcase outcome paths exit 0 for LAVA.

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

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_display.sh"

if [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_pkg_provider.sh"
fi

TESTNAME="weston-simple-damage"

DURATION="${DURATION:-30s}"
STOP_GRACE="${STOP_GRACE:-3s}"
WAIT_SECS="${WAIT_SECS:-10}"
ALLOW_RELAUNCH="${ALLOW_RELAUNCH:-0}"
VALIDATE_WAYLAND_PROTO="${VALIDATE_WAYLAND_PROTO:-1}"
VALIDATE_SCREENSHOT="${VALIDATE_SCREENSHOT:-0}"
REQUESTED_GRAPHICS_MODE="${REQUESTED_GRAPHICS_MODE:-auto}"

OS_ID="unknown"
DESKTOP_OS=0
APP_PID=""

# Initialize the result file at the suite's absolute path before argument
# parsing so that any early exit from an invalid option or missing argument
# writes FAIL rather than leaving a stale result from a previous run.
# Using SCRIPT_DIR (absolute) rather than a relative path ensures the correct
# file is targeted regardless of the caller's working directory.
if command -v test_result_init >/dev/null 2>&1; then
    test_result_init "$TESTNAME" "${SCRIPT_DIR}/${TESTNAME}.res" 2>/dev/null || \
        rm -f "${SCRIPT_DIR}/${TESTNAME}.res" 2>/dev/null || true
else
    rm -f "${SCRIPT_DIR}/${TESTNAME}.res" 2>/dev/null || true
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base|--no-overlay)
            REQUESTED_GRAPHICS_MODE="base"
            ;;

        --overlay|--qcom-overlay|--enable-overlay)
            REQUESTED_GRAPHICS_MODE="overlay"
            ;;

        --auto)
            REQUESTED_GRAPHICS_MODE="auto"
            ;;

        --wait-secs)
            shift

            if [ "$#" -eq 0 ]; then
                log_fail "--wait-secs requires an argument"
                test_result_finish FAIL "$TESTNAME FAIL - --wait-secs requires an argument"
            fi

            WAIT_SECS="$1"
            ;;

        --wait-secs=*)
            WAIT_SECS=${1#*=}
            ;;

        --allow-relaunch)
            ALLOW_RELAUNCH=1
            ;;

        --no-allow-relaunch)
            ALLOW_RELAUNCH=0
            ;;

        --validate-wayland-proto)
            VALIDATE_WAYLAND_PROTO=1
            ;;

        --no-validate-wayland-proto)
            VALIDATE_WAYLAND_PROTO=0
            ;;

        --validate-screenshot)
            VALIDATE_SCREENSHOT=1
            ;;

        --no-validate-screenshot)
            VALIDATE_SCREENSHOT=0
            ;;

        -h|--help)
            cat <<EOF_USAGE
Usage: $0 [OPTIONS]

Graphics options:
  --auto                    Reuse and validate the active graphics stack, default
  --base                    Require the active MSM/freedreno base stack
  --overlay                 Require the active KGSL/Adreno overlay stack

Runtime options:
  --wait-secs N             Weston readiness timeout, default: 10
  --allow-relaunch          Allow recovery of an existing managed Weston runtime
  --no-allow-relaunch       Do not allow managed Weston recovery, default

Validation options:
  --validate-wayland-proto  Require Wayland protocol evidence, default
  --no-validate-wayland-proto
  --validate-screenshot     Enable screenshot-delta validation
  --no-validate-screenshot  Disable screenshot-delta validation, default

Other options:
  -h, --help                Show this help

Environment:
  DURATION                  Client runtime, default: 30s
  STOP_GRACE                Client termination grace, default: 3s
  REQUESTED_GRAPHICS_MODE   auto, base, or overlay
EOF_USAGE
            exit 0
            ;;

        *)
            log_fail "Unknown option: $1"
            test_result_finish FAIL "$TESTNAME FAIL - unknown option: $1"
            ;;
    esac

    shift
done

case "$REQUESTED_GRAPHICS_MODE" in
    auto|base|overlay)
        ;;
    *)
        log_fail "Unsupported graphics mode: $REQUESTED_GRAPHICS_MODE"
        test_result_finish FAIL "$TESTNAME FAIL - unsupported graphics mode: $REQUESTED_GRAPHICS_MODE"
        ;;
esac

case "$WAIT_SECS" in
    ''|*[!0-9]*)
        log_fail "WAIT_SECS must be a positive integer: $WAIT_SECS"
        test_result_finish FAIL "$TESTNAME FAIL - invalid WAIT_SECS: $WAIT_SECS"
        ;;
esac

if [ "$WAIT_SECS" -le 0 ]; then
    log_fail "WAIT_SECS must be greater than zero: $WAIT_SECS"
    test_result_finish FAIL "$TESTNAME FAIL - invalid WAIT_SECS: $WAIT_SECS"
fi

case "$ALLOW_RELAUNCH" in
    0|1)
        ;;
    *)
        log_fail "ALLOW_RELAUNCH must be 0 or 1: $ALLOW_RELAUNCH"
        test_result_finish FAIL "$TESTNAME FAIL - invalid ALLOW_RELAUNCH: $ALLOW_RELAUNCH"
        ;;
esac

case "$VALIDATE_WAYLAND_PROTO" in
    0|1)
        ;;
    *)
        log_fail "VALIDATE_WAYLAND_PROTO must be 0 or 1: $VALIDATE_WAYLAND_PROTO"
        test_result_finish FAIL "$TESTNAME FAIL - invalid VALIDATE_WAYLAND_PROTO: $VALIDATE_WAYLAND_PROTO"
        ;;
esac

case "$VALIDATE_SCREENSHOT" in
    0|1)
        ;;
    *)
        log_fail "VALIDATE_SCREENSHOT must be 0 or 1: $VALIDATE_SCREENSHOT"
        test_result_finish FAIL "$TESTNAME FAIL - invalid VALIDATE_SCREENSHOT: $VALIDATE_SCREENSHOT"
        ;;
esac

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"

if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    log_fail "$TESTNAME FAIL - test directory not found"
    echo "$TESTNAME FAIL" >"./${TESTNAME}.res"
    exit 1
fi

cd "$test_path" || exit 1

RES_FILE="./${TESTNAME}.res"
RUN_LOG="./${TESTNAME}_run.log"
ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || printf '%s' 0)"
STDOUT_LOG="./${TESTNAME}_stdout_${ts}.log"

# Re-initialize now that we are in the correct test directory. This clears any
# result written by an early validation exit above and resets the counters.
if command -v test_result_init >/dev/null 2>&1; then
    test_result_init "$TESTNAME" "$RES_FILE" 2>/dev/null || : >"$RES_FILE"
else
    : >"$RES_FILE"
fi
: >"$RUN_LOG"
: >"$STDOUT_LOG"

# cleanup_client stops the background client process and then chains the
# init_env stdout/FIFO capture cleanup (_runner_stdout_cleanup) so its pipe
# and tee process are drained before the shell exits.
#
# bounded_timeout_cancel from functestlib.sh handles the KILL escalation and
# returns non-zero when the child survives, retaining the PID so callers can
# detect and report the failure without discarding ownership.
# shellcheck disable=SC2317
cleanup_client()
{
    cc_status="${1:-$?}"

    if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        if command -v bounded_timeout_cancel >/dev/null 2>&1; then
            BOUNDED_TIMEOUT_PID="$APP_PID" bounded_timeout_cancel
            _cc_stop_rc=$?
        else
            _cc_stop_rc=0
            sg=0
            while [ "$sg" -lt 3 ] && kill -0 "$APP_PID" 2>/dev/null; do
                sleep 1; sg=$((sg + 1))
            done
            if kill -0 "$APP_PID" 2>/dev/null; then
                kill -KILL "$APP_PID" 2>/dev/null || true
                sg=0
                while [ "$sg" -lt 3 ] && kill -0 "$APP_PID" 2>/dev/null; do
                    sleep 1; sg=$((sg + 1))
                done
                kill -0 "$APP_PID" 2>/dev/null && _cc_stop_rc=1
            fi
        fi
        if [ "$_cc_stop_rc" -ne 0 ]; then
            # Child survived SIGKILL: retain APP_PID (do not reap).
            log_warn "$TESTNAME cleanup: client PID $APP_PID did not terminate after SIGKILL"
        else
            if ! kill -0 "$APP_PID" 2>/dev/null; then
                wait "$APP_PID" 2>/dev/null || true
            fi
            APP_PID=""
        fi
    else
        APP_PID=""
    fi

    # Chain the init_env stdout capture cleanup when it is active so the tee
    # pipe and FIFO are drained before the process exits.  _runner_stdout_cleanup
    # clears the traps and calls exit, so this must be the last statement.
    if [ "${__RUN_STDOUT_ACTIVE:-0}" = "1" ] &&
       command -v _runner_stdout_cleanup >/dev/null 2>&1; then
        _runner_stdout_cleanup "$cc_status"
    else
        exit "$cc_status"
    fi
}

# Replace the init_env signal traps with our own so cleanup_client runs first.
# cleanup_client chains _runner_stdout_cleanup at the end to preserve the
# stdout capture teardown installed by init_env.
trap 'cleanup_client "$?"' EXIT
trap 'cleanup_client 129' HUP
trap 'cleanup_client 130' INT
trap 'cleanup_client 143' TERM

if command -v pkg_detect_os_id >/dev/null 2>&1; then
    OS_ID="$(pkg_detect_os_id 2>/dev/null || true)"
elif [ -r /etc/os-release ]; then
    OS_ID="$(
        sed -n 's/^ID=//p' /etc/os-release |
            head -n 1 |
            tr -d '"' |
            tr '[:upper:]' '[:lower:]'
    )"
fi

[ -n "$OS_ID" ] || OS_ID="unknown"

case "$OS_ID" in
    debian|ubuntu|centos|rhel|fedora)
        DESKTOP_OS=1
        ;;
esac

log_info "Weston log directory, $SCRIPT_DIR"
log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase --------------------------"
log_info "Detected OS, $OS_ID"
log_info "Config, REQUESTED_GRAPHICS_MODE=${REQUESTED_GRAPHICS_MODE} DURATION=${DURATION} WAIT_SECS=${WAIT_SECS} ALLOW_RELAUNCH=${ALLOW_RELAUNCH} VALIDATE_WAYLAND_PROTO=${VALIDATE_WAYLAND_PROTO} VALIDATE_SCREENSHOT=${VALIDATE_SCREENSHOT}"

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform
fi

for required_helper in \
    display_detect_build_flavour \
    display_log_snapshot_and_require_connector; do
    if ! command -v "$required_helper" >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - required helper is unavailable: $required_helper"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
done

# Check that required Weston client binaries are present. These runners do not
# install packages: CHECK_DEPS_RECOVER=0 enforces check-only mode so that
# absent dependencies produce SKIP rather than triggering package installation.
# This does not affect the recovery behavior of other suites.
_wdep_save_cdr="${CHECK_DEPS_RECOVER-__unset__}"
_wdep_save_cdne="${CHECK_DEPS_NO_EXIT-__unset__}"
CHECK_DEPS_RECOVER=0
CHECK_DEPS_NO_EXIT=1
export CHECK_DEPS_RECOVER CHECK_DEPS_NO_EXIT

_wdep_list="$TESTNAME"
case "$OS_ID" in
    debian|ubuntu|centos|rhel|fedora)
        _wdep_list="$_wdep_list weston"
        ;;
esac

if ! check_dependencies "$_wdep_list"; then
    log_skip "$TESTNAME SKIP - required Weston client dependencies are unavailable"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    case "$_wdep_save_cdr" in
        __unset__) unset CHECK_DEPS_RECOVER ;;
        *) CHECK_DEPS_RECOVER="$_wdep_save_cdr"; export CHECK_DEPS_RECOVER ;;
    esac
    case "$_wdep_save_cdne" in
        __unset__) unset CHECK_DEPS_NO_EXIT ;;
        *) CHECK_DEPS_NO_EXIT="$_wdep_save_cdne"; export CHECK_DEPS_NO_EXIT ;;
    esac
    exit 0
fi

case "$_wdep_save_cdr" in
    __unset__) unset CHECK_DEPS_RECOVER ;;
    *) CHECK_DEPS_RECOVER="$_wdep_save_cdr"; export CHECK_DEPS_RECOVER ;;
esac
case "$_wdep_save_cdne" in
    __unset__) unset CHECK_DEPS_NO_EXIT ;;
    *) CHECK_DEPS_NO_EXIT="$_wdep_save_cdne"; export CHECK_DEPS_NO_EXIT ;;
esac

display_detect_build_flavour

case "${DISPLAY_BUILD_FLAVOUR:-base}" in
    overlay)
        DISPLAY_BUILD_FLAVOUR="overlay"
        log_info "Detected graphics flavor, overlay"
        log_info "Adreno EGL vendor JSON, ${DISPLAY_EGL_VENDOR_JSON:-<not-found>}"
        ;;

    *)
        DISPLAY_BUILD_FLAVOUR="base"
        DISPLAY_EGL_VENDOR_JSON=""
        log_info "Detected graphics flavor, base"
        ;;
esac

case "$REQUESTED_GRAPHICS_MODE" in
    base)
        if [ "$DISPLAY_BUILD_FLAVOUR" != "base" ]; then
            log_skip "$TESTNAME SKIP - base mode requested but the active graphics stack is overlay"
            log_info "Switch the platform to base and restart Weston before rerunning this client"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi
        ;;

    overlay)
        if [ "$DISPLAY_BUILD_FLAVOUR" != "overlay" ]; then
            log_skip "$TESTNAME SKIP - overlay mode requested but the active graphics stack is base"
            log_info "Switch the platform to overlay and restart Weston before rerunning this client"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi
        ;;

    auto)
        log_info "Graphics mode auto, reusing active stack=$DISPLAY_BUILD_FLAVOUR"
        ;;
esac

# Select the client-side EGL vendor to match the already active stack when the
# shared helper is available. This does not modify packages or restart Weston.
if [ "$DESKTOP_OS" -eq 1 ] &&
   command -v display_select_egl_vendor >/dev/null 2>&1; then
    if [ "$DISPLAY_BUILD_FLAVOUR" = "overlay" ]; then
        if ! display_select_egl_vendor adreno; then
            log_warn "Could not select the Adreno EGL vendor, continuing because this client uses SHM only"
        fi
    else
        if ! display_select_egl_vendor mesa; then
            log_warn "Could not select the Mesa EGL vendor, continuing because this client uses SHM only"
        fi
    fi
elif [ "$DISPLAY_BUILD_FLAVOUR" = "overlay" ] &&
     [ -n "${DISPLAY_EGL_VENDOR_JSON:-}" ]; then
    __EGL_VENDOR_LIBRARY_FILENAMES="$DISPLAY_EGL_VENDOR_JSON"
    export __EGL_VENDOR_LIBRARY_FILENAMES
fi

if [ -n "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" ]; then
    log_info "EGL vendor JSON, $__EGL_VENDOR_LIBRARY_FILENAMES"
else
    log_info "EGL vendor JSON, native discovery"
fi

if ! display_log_snapshot_and_require_connector "$TESTNAME" 120; then
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ "$DESKTOP_OS" -eq 1 ]; then
    if ! command -v weston_prepare_runtime >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - weston_prepare_runtime helper is unavailable"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi

    if ! weston_prepare_runtime \
        "$TESTNAME" \
        "$WAIT_SECS" \
        client \
        "$ALLOW_RELAUNCH"; then
        log_fail "$TESTNAME FAIL - no usable existing Weston runtime is available"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
else
    if ! command -v display_prepare_image_weston_runtime >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - display_prepare_image_weston_runtime helper is unavailable"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi

    if ! display_prepare_image_weston_runtime \
        "$TESTNAME" \
        "$WAIT_SECS" \
        "$DISPLAY_BUILD_FLAVOUR"; then
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
fi

BIN="$(command -v "$TESTNAME" 2>/dev/null || true)"

if [ -z "$BIN" ]; then
    log_skip "$TESTNAME SKIP - required client binary is unavailable"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_info "Using client, $BIN"
log_info "Wayland socket, ${DISPLAY_WAYLAND_SOCKET:-<unknown>}"
log_info "XDG_RUNTIME_DIR, ${XDG_RUNTIME_DIR:-<unset>}"
log_info "WAYLAND_DISPLAY, ${WAYLAND_DISPLAY:-<unset>}"

shot_begin_rc=2

if [ "$VALIDATE_SCREENSHOT" -ne 0 ]; then
    if command -v display_screenshot_delta_begin >/dev/null 2>&1; then
        display_screenshot_delta_begin "$TESTNAME" "$SCRIPT_DIR"
        shot_begin_rc=$?

        case "$shot_begin_rc" in
            0)
                log_info "Screenshot before client launch was captured"
                ;;
            2)
                log_warn "Screenshot tool is unavailable, skipping screenshot-delta validation"
                ;;
            *)
                log_warn "Could not capture the initial screenshot, skipping screenshot-delta validation"
                ;;
        esac
    else
        log_warn "Screenshot-delta helper is unavailable"
    fi
fi

if [ "$VALIDATE_WAYLAND_PROTO" -ne 0 ]; then
    WAYLAND_DEBUG=1
    export WAYLAND_DEBUG
fi

duration_secs="$(
    printf '%s\n' "$DURATION" |
        sed -n 's/^\([0-9][0-9]*\)s$/\1/p'
)"
case "$duration_secs" in
    ''|0)
        log_fail "$TESTNAME FAIL - DURATION must be a positive integer followed by s: $DURATION"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
        ;;
esac

log_info "Launching $TESTNAME for $DURATION"

start_ts="$(date +%s)"
rc=0
# Track whether the launcher initiated the client stop. rc=143 alone cannot
# establish that the test controlled the stop: the child can receive SIGTERM
# from an external source and exit with the same status. Only the launcher
# branch below sets this flag.
launcher_stopped=0

# Start the client in the background so we can capture the "after" screenshot
# while it is still rendering, then wait the full configured duration.
if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL "$BIN" >>"$RUN_LOG" 2>&1 &
else
    "$BIN" >>"$RUN_LOG" 2>&1 &
fi
APP_PID=$!

# Phase 1: wait for rendering evidence before the mid-run screenshot.
# Use half the configured duration, bounded to [3, duration-1] seconds.
render_wait=$((duration_secs / 2))
[ "$render_wait" -lt 3 ] && render_wait=3
[ "$render_wait" -ge "$duration_secs" ] && render_wait=$((duration_secs - 1))

phase1_elapsed=0
while [ "$phase1_elapsed" -lt "$render_wait" ]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    sleep 1
    phase1_elapsed=$((phase1_elapsed + 1))
done

# Capture the "after" screenshot while the client is still alive.
# This avoids a false negative caused by the client window disappearing before
# the second capture on an otherwise static desktop.
shot_end_rc=2
if [ "$VALIDATE_SCREENSHOT" -ne 0 ] && [ "$shot_begin_rc" -eq 0 ]; then
    if kill -0 "$APP_PID" 2>/dev/null; then
        if command -v display_screenshot_delta_end >/dev/null 2>&1; then
            display_screenshot_delta_end "$TESTNAME"
            shot_end_rc=$?
        else
            log_warn "display_screenshot_delta_end helper is unavailable"
        fi
    else
        log_warn "Client exited before the mid-run screenshot could be captured"
    fi
fi

# Phase 2: wait the remaining portion of the configured duration.
remaining=$((duration_secs - phase1_elapsed))
phase2_elapsed=0
while [ "$phase2_elapsed" -lt "$remaining" ]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    sleep 1
    phase2_elapsed=$((phase2_elapsed + 1))
done

# Stop the client. Set launcher_stopped=1 only when our launcher sends
# SIGTERM and bounded_timeout_cancel confirms the child has stopped.
# If the child survives SIGKILL, launcher_stopped is cleared, the testcase
# is marked failed, and APP_PID is retained so the EXIT trap can reattempt.
if kill -0 "$APP_PID" 2>/dev/null; then
    launcher_stopped=1
    kill -TERM "$APP_PID" 2>/dev/null || true
    if command -v bounded_timeout_cancel >/dev/null 2>&1; then
        BOUNDED_TIMEOUT_PID="$APP_PID" bounded_timeout_cancel
        _stop_rc=$?
    else
        _stop_rc=0
        sg=0
        while [ "$sg" -lt 3 ] && kill -0 "$APP_PID" 2>/dev/null; do
            sleep 1; sg=$((sg + 1))
        done
        if kill -0 "$APP_PID" 2>/dev/null; then
            kill -KILL "$APP_PID" 2>/dev/null || true
            sg=0
            while [ "$sg" -lt 3 ] && kill -0 "$APP_PID" 2>/dev/null; do
                sleep 1; sg=$((sg + 1))
            done
            kill -0 "$APP_PID" 2>/dev/null && _stop_rc=1
        fi
    fi
    if [ "$_stop_rc" -ne 0 ]; then
        # Child survived SIGKILL: ownership is retained until the EXIT trap
        # reattempts. Mark the testcase failed and clear the launcher flag.
        log_fail "$TESTNAME client did not terminate after SIGKILL; PID $APP_PID may be in D state"
        launcher_stopped=0
        rc=1
    else
        rc=143
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            wait "$APP_PID" 2>/dev/null || true
        fi
        APP_PID=""
    fi
else
    wait "$APP_PID" 2>/dev/null
    rc=$?
    APP_PID=""
fi

unset WAYLAND_DEBUG

end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))

log_info "Client finished, rc=$rc elapsed=${elapsed}s"

tail -n 400 "$RUN_LOG" >"$STDOUT_LOG" 2>/dev/null || true

final="PASS"

# Base the completion verdict on launcher_stopped, not on the child's exit
# status. rc=143 alone cannot prove the launcher stopped the client: the child
# may receive an external SIGTERM and exit with that status even when the test
# did not initiate the stop.
if [ "$launcher_stopped" -eq 1 ]; then
    # Launcher-initiated stop after the configured duration: the only
    # unambiguous proof that the client ran the full requested window.
    log_info "Client ran the configured duration and was stopped by the launcher, elapsed=${elapsed}s"
elif [ "$rc" -eq 0 ]; then
    # Client exited cleanly on its own. These clients loop indefinitely until
    # stopped, so a clean exit before the duration elapses indicates a Wayland
    # disconnect or other early termination.
    if [ "$elapsed" -lt $((duration_secs - 2)) ]; then
        log_fail "$TESTNAME exited with rc=0 after ${elapsed}s (expected ~${duration_secs}s); likely a Wayland disconnect"
        final="FAIL"
    fi
elif [ "$rc" -eq 143 ]; then
    # rc=143 without launcher_stopped: SIGTERM came from an external source,
    # not from this test framework.
    log_fail "$TESTNAME received SIGTERM (rc=143) not initiated by the test launcher"
    final="FAIL"
elif [ "$rc" -eq 137 ]; then
    # SIGKILL not sent by this test framework.
    log_fail "$TESTNAME received SIGKILL (rc=137); not initiated by the test"
    final="FAIL"
else
    log_fail "$TESTNAME exited unexpectedly, rc=$rc elapsed=${elapsed}s"
    final="FAIL"
fi

if [ "$elapsed" -le 1 ]; then
    log_fail "$TESTNAME exited too quickly, elapsed=${elapsed}s"
    final="FAIL"
fi

if [ "$VALIDATE_WAYLAND_PROTO" -ne 0 ]; then
    if command -v display_wayland_proto_validate >/dev/null 2>&1; then
        if display_wayland_proto_validate "$RUN_LOG"; then
            log_pass "Wayland protocol validation passed"
        else
            log_fail "Wayland protocol validation failed"
            final="FAIL"
        fi
    else
        log_warn "display_wayland_proto_validate helper is unavailable"
    fi

    if command -v display_wayland_damage_validate >/dev/null 2>&1; then
        if display_wayland_damage_validate "$RUN_LOG"; then
            log_pass "Damage protocol validation passed"
        else
            log_fail "Damage protocol validation failed: wl_surface damage calls or frame-callback progress not found in WAYLAND_DEBUG log"
            final="FAIL"
        fi
    else
        log_warn "display_wayland_damage_validate helper is unavailable"
    fi
fi

# Screenshot result evaluation. The capture was taken mid-run above while the
# client window was still visible. Only evaluate when both captures completed.
if [ "$VALIDATE_SCREENSHOT" -ne 0 ] && [ "$shot_begin_rc" -eq 0 ]; then
    case "$shot_end_rc" in
        0)
            log_pass "Screenshot delta validation passed"
            ;;
        1)
            log_fail "Screenshot delta validation found no visible change"
            final="FAIL"
            ;;
        *)
            log_warn "Screenshot delta validation could not be completed"
            ;;
    esac
fi

echo "$TESTNAME $final" >"$RES_FILE"

if [ "$final" = "PASS" ]; then
    log_pass "$TESTNAME : PASS"
else
    log_fail "$TESTNAME : FAIL"
fi

exit 0
