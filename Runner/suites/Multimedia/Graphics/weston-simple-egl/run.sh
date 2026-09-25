#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Validate weston-simple-egl through a usable Weston compositor.
#
# Desktop distributions:
# - default to the upstream MSM/freedreno base stack
# - --overlay selects the Qualcomm KGSL/Adreno package and boot stack
# - --auto validates the currently selected stack without changing it
# - use the unsynchronized client benchmark with a 60 FPS functional target in
#   automatic FPS mode because packaged clients may not report synchronized
#   redraws
#
# Yocto and other image-based distributions:
# - preserve the existing image-selected graphics and Weston flow
# - do not install/remove graphics packages or alter boot artifacts
# - preserve the existing detected-refresh FPS policy and synchronized client
#
# PASS/FAIL/SKIP is written to the result file. After testcase execution, the
# runner exits 0 for compatibility with the existing LAVA flow.

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

if [ -r "$TOOLS/lib_module_reload.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_module_reload.sh"
fi

TESTNAME="weston-simple-egl"

DURATION="${DURATION:-30s}"
STOP_GRACE="${STOP_GRACE:-3s}"
WAIT_SECS="${WAIT_SECS:-10}"

FPS_EXPECT_MODE="${FPS_EXPECT_MODE:-auto}"
EXPECT_FPS="${EXPECT_FPS:-}"
EXPECT_FPS_DEFAULT="${EXPECT_FPS_DEFAULT:-60}"
FPS_TOL_PCT="${FPS_TOL_PCT:-10}"
MIN_FPS_PCT="${MIN_FPS_PCT:-85}"
REQUIRE_FPS="${REQUIRE_FPS:-1}"
DESKTOP_FUNCTIONAL_FPS_CAP="${DESKTOP_FUNCTIONAL_FPS_CAP:-60}"
CLOCK_STEP_TOLERANCE="${CLOCK_STEP_TOLERANCE:-2}"

REQUESTED_GRAPHICS_MODE="default"
ALLOW_RELAUNCH="${ALLOW_RELAUNCH:-0}"

GPU_MODULE="${GPU_MODULE:-msm_kgsl}"
GPU_OVERLAY_DEVICE="${GPU_OVERLAY_DEVICE:-/dev/kgsl-3d0}"
GPU_OVERLAY_GBM_PACKAGE="${GPU_OVERLAY_GBM_PACKAGE:-}"

OS_ID="unknown"
DISTRO_GPU_HANDLING_SUPPORTED=0
APP_PID=""

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
                echo "[ERROR] --wait-secs requires an argument" >&2
                exit 1
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

        --strict-refresh-fps)
            FPS_EXPECT_MODE="detected"
            REQUIRE_FPS=1
            ;;

        --require-fps)
            REQUIRE_FPS=1
            ;;

        --no-require-fps)
            REQUIRE_FPS=0
            ;;

        -h|--help)
            cat <<EOF_USAGE
Usage: $0 [OPTIONS]

Graphics options:
  --base                Select upstream MSM/freedreno on desktop distributions
  --overlay             Select Qualcomm KGSL/Adreno on desktop distributions
  --auto                Keep and validate the currently active graphics stack

Runtime options:
  --wait-secs N         Weston readiness timeout, default: 10
  --allow-relaunch      Allow managed Weston recovery or relaunch
  --no-allow-relaunch   Do not allow managed Weston relaunch

FPS options:
  --strict-refresh-fps  Gate against the detected output refresh rate
  --require-fps         Require FPS evidence, default
  --no-require-fps      Record FPS when available but do not gate on it

Defaults:
  Desktop automatic mode uses the unsynchronized client benchmark and a
  minimum-throughput gate. Image-based and strict-refresh runs remain
  compositor-synchronized.

Other options:
  -h, --help            Show this help

Environment:
  DURATION                    Client runtime, default: 30s
  STOP_GRACE                  Client termination grace, default: 3s
  FPS_EXPECT_MODE             auto, detected, or fixed
  EXPECT_FPS                  Fixed expected FPS when configured
  EXPECT_FPS_DEFAULT          Fallback expected FPS, default: 60
  FPS_TOL_PCT                 Fixed-mode tolerance, default: 10
  MIN_FPS_PCT                 Minimum percentage, default: 85
  REQUIRE_FPS                 0 or 1, default: 1
  DESKTOP_FUNCTIONAL_FPS_CAP  Desktop auto-mode FPS cap, default: 60
  TIME_SYNC_WAIT              Clock sync wait bound in seconds, 0 disables, default: 20
  CLOCK_STEP_TOLERANCE        Wall-clock step tolerance in seconds, default: 2
EOF_USAGE
            exit 0
            ;;

        *)
            echo "[ERROR] Unknown option: $1" >&2
            cat >&2 <<EOF_USAGE
Usage: $0 [--base|--overlay|--auto] [--strict-refresh-fps]
          [--wait-secs N] [--allow-relaunch|--no-allow-relaunch]
          [--require-fps|--no-require-fps]
EOF_USAGE
            exit 1
            ;;
    esac

    shift
done

case "$WAIT_SECS" in
    ''|*[!0-9]*)
        echo "[ERROR] WAIT_SECS must be a positive integer: $WAIT_SECS" >&2
        exit 1
        ;;
esac

if [ "$WAIT_SECS" -le 0 ]; then
    echo "[ERROR] WAIT_SECS must be greater than zero: $WAIT_SECS" >&2
    exit 1
fi

case "$REQUIRE_FPS" in
    0|1)
        ;;
    *)
        echo "[ERROR] REQUIRE_FPS must be 0 or 1: $REQUIRE_FPS" >&2
        exit 1
        ;;
esac

case "$ALLOW_RELAUNCH" in
    0|1)
        ;;
    *)
        echo "[ERROR] ALLOW_RELAUNCH must be 0 or 1: $ALLOW_RELAUNCH" >&2
        exit 1
        ;;
esac

case "$DESKTOP_FUNCTIONAL_FPS_CAP" in
    ''|*[!0-9]*)
        echo "[ERROR] DESKTOP_FUNCTIONAL_FPS_CAP must be an integer: $DESKTOP_FUNCTIONAL_FPS_CAP" >&2
        exit 1
        ;;
esac

if [ "$DESKTOP_FUNCTIONAL_FPS_CAP" -le 0 ]; then
    echo "[ERROR] DESKTOP_FUNCTIONAL_FPS_CAP must be greater than zero" >&2
    exit 1
fi

if ! is_unsigned_number "$CLOCK_STEP_TOLERANCE"; then
    echo "[ERROR] CLOCK_STEP_TOLERANCE must be a non-negative integer: $CLOCK_STEP_TOLERANCE" >&2
    exit 1
fi

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"

if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    log_fail "$TESTNAME FAIL - test directory not found"
    echo "$TESTNAME FAIL" >"./${TESTNAME}.res"
    exit 1
fi

cd "$test_path" || exit 1

RES_FILE="./${TESTNAME}.res"
RUN_LOG="./${TESTNAME}_run.log"

: >"$RES_FILE"
: >"$RUN_LOG"

cleanup_client()
{
    cleanup_pid="${APP_PID:-}"

    if [ -n "$cleanup_pid" ] &&
       kill -0 "$cleanup_pid" 2>/dev/null; then
        kill -TERM "$cleanup_pid" 2>/dev/null || true
        sleep 1

        if kill -0 "$cleanup_pid" 2>/dev/null; then
            kill -KILL "$cleanup_pid" 2>/dev/null || true
        fi

        wait "$cleanup_pid" 2>/dev/null || true
    fi

    APP_PID=""
}

trap 'cleanup_client' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

if [ -z "$GPU_OVERLAY_GBM_PACKAGE" ]; then
    case "$OS_ID" in
        ubuntu)
            GPU_OVERLAY_GBM_PACKAGE="libgbm-msm"
            ;;
        *)
            GPU_OVERLAY_GBM_PACKAGE="libgbm-msm1"
            ;;
    esac
fi

case "$OS_ID" in
    debian|ubuntu|centos|rhel|fedora)
        DISTRO_GPU_HANDLING_SUPPORTED=1

        if [ "$REQUESTED_GRAPHICS_MODE" = "default" ]; then
            REQUESTED_GRAPHICS_MODE="base"
        fi

        ;;

    *)
        if [ "$REQUESTED_GRAPHICS_MODE" = "default" ]; then
            REQUESTED_GRAPHICS_MODE="auto"
        fi
        ;;
esac

log_info "Weston log directory, $SCRIPT_DIR"
log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase --------------------------"
log_info "Detected OS, $OS_ID"
log_info "Config, REQUESTED_GRAPHICS_MODE=${REQUESTED_GRAPHICS_MODE} DURATION=${DURATION} STOP_GRACE=${STOP_GRACE} WAIT_SECS=${WAIT_SECS} ALLOW_RELAUNCH=${ALLOW_RELAUNCH}"
log_info "FPS config, MODE=${FPS_EXPECT_MODE} EXPECT_FPS=${EXPECT_FPS:-<unset>} DEFAULT=${EXPECT_FPS_DEFAULT} TOLERANCE=${FPS_TOL_PCT}% MIN_PERCENT=${MIN_FPS_PCT}% REQUIRE_FPS=${REQUIRE_FPS} DESKTOP_CAP=${DESKTOP_FUNCTIONAL_FPS_CAP}"

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform
fi

for required_helper in \
    display_ensure_weston_test_dependencies \
    display_detect_build_flavour \
    display_log_snapshot_and_require_connector \
    display_resolve_fps_policy \
    display_resolve_test_fps_gate_policy \
    display_apply_test_fps_gate_policy; do
    if ! command -v "$required_helper" >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - required helper is unavailable: $required_helper"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
done

if ! display_ensure_weston_test_dependencies "$TESTNAME"; then
    log_skip "$TESTNAME SKIP - Weston client dependencies are unavailable"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ "$DISTRO_GPU_HANDLING_SUPPORTED" -eq 1 ]; then
    if ! command -v display_prepare_desktop_graphics_stack >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - display_prepare_desktop_graphics_stack helper is unavailable"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi

    display_prepare_desktop_graphics_stack \
        "$TESTNAME" \
        "$REQUESTED_GRAPHICS_MODE" \
        "$GPU_MODULE" \
        "$GPU_OVERLAY_DEVICE" \
        "$GPU_OVERLAY_GBM_PACKAGE"
    stack_rc=$?

    case "$stack_rc" in
        0)
            ;;
        2)
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
        *)
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
            ;;
    esac
else
    log_info "Graphics package-stack and GPU boot-mode handling skipped for os=$OS_ID"
fi

display_detect_build_flavour

case "${DISPLAY_BUILD_FLAVOUR:-base}" in
    overlay)
        log_info "Detected graphics flavor, overlay"
        log_info "Adreno EGL vendor JSON, ${DISPLAY_EGL_VENDOR_JSON:-<not-found>}"
        ;;

    *)
        DISPLAY_BUILD_FLAVOUR="base"
        DISPLAY_EGL_VENDOR_JSON=""
        log_info "Detected graphics flavor, base"
        ;;
esac

if [ "$DISTRO_GPU_HANDLING_SUPPORTED" -eq 1 ] &&
   [ "$REQUESTED_GRAPHICS_MODE" = "auto" ]; then
    if ! command -v display_select_egl_vendor >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - required desktop auto-mode helper is unavailable: display_select_egl_vendor"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi

    if [ "$DISPLAY_BUILD_FLAVOUR" = "overlay" ]; then
        if ! display_select_egl_vendor adreno; then
            log_fail "$TESTNAME FAIL - failed to select the detected Adreno EGL vendor"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi

    else
        if ! display_select_egl_vendor mesa; then
            log_skip "$TESTNAME SKIP - detected base stack has no usable Mesa EGL vendor"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi

    fi
fi

case "$REQUESTED_GRAPHICS_MODE" in
    base)
        if [ "$DISPLAY_BUILD_FLAVOUR" != "base" ]; then
            log_skip "$TESTNAME SKIP - base mode requested but the Qualcomm overlay is still active, reboot may be required"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi
        ;;

    overlay)
        if [ "$DISPLAY_BUILD_FLAVOUR" != "overlay" ]; then
            log_skip "$TESTNAME SKIP - overlay mode requested but the Adreno overlay is not active, reboot may be required"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi
        ;;
esac

# Preserve the existing image-overlay EGL vendor override. Desktop vendor
# selection was already completed through display_select_egl_vendor.
if [ "$DISTRO_GPU_HANDLING_SUPPORTED" -eq 0 ] &&
   [ "$DISPLAY_BUILD_FLAVOUR" = "overlay" ] &&
   [ -n "${DISPLAY_EGL_VENDOR_JSON:-}" ]; then
    __EGL_VENDOR_LIBRARY_FILENAMES="$DISPLAY_EGL_VENDOR_JSON"
    export __EGL_VENDOR_LIBRARY_FILENAMES

    log_info "EGL vendor override, $__EGL_VENDOR_LIBRARY_FILENAMES"
fi

if ! display_log_snapshot_and_require_connector "$TESTNAME" 200; then
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

case "$OS_ID" in
    debian|ubuntu|centos|rhel|fedora)
        if [ "$OS_ID" = "ubuntu" ] &&
           command -v display_adopt_gnome_wayland_session >/dev/null 2>&1 &&
           display_adopt_gnome_wayland_session; then
            log_info "Using the active GNOME Wayland session for onscreen EGL validation"
        elif ! command -v weston_prepare_runtime >/dev/null 2>&1; then
            log_fail "$TESTNAME FAIL - weston_prepare_runtime helper is unavailable"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        elif ! weston_prepare_runtime \
                "$TESTNAME" \
                "$WAIT_SECS" \
                client \
                "$ALLOW_RELAUNCH"; then
            log_fail "$TESTNAME FAIL - no usable managed Weston runtime is available for onscreen EGL clients"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi
        ;;

    *)
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
        ;;
esac

if ! display_resolve_fps_policy; then
    log_fail "$TESTNAME FAIL - failed to resolve FPS policy"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

# Strict refresh mode must never silently degrade to the fixed 60 FPS fallback.
if [ "$FPS_EXPECT_MODE" = "detected" ] &&
   [ "${DISPLAY_FPS_MODE:-}" != "detected" ]; then
    log_fail "$TESTNAME FAIL - strict refresh FPS requested but the active refresh rate could not be detected"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if ! display_resolve_test_fps_gate_policy \
    "$OS_ID" \
    "$FPS_EXPECT_MODE" \
    "$EXPECT_FPS" \
    "$DESKTOP_FUNCTIONAL_FPS_CAP" \
    "$MIN_FPS_PCT"; then
    log_fail "$TESTNAME FAIL - failed to resolve testcase FPS gate policy"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ "${DISPLAY_RUNTIME_MODEL:-}" = "desktop-gnome-session" ]; then
    # GDM intentionally throttles non-interactive greeter clients, so their
    # compositor frame cadence is not a display-refresh or GPU-performance
    # measurement. The client connection and EGL startup remain validated.
    DISPLAY_TEST_FPS_POLICY="desktop-session-connectivity"
    export DISPLAY_TEST_FPS_POLICY
    log_info "FPS policy, desktop-session-connectivity, GNOME greeter throttling is not performance evidence"
fi

if [ "${DISPLAY_TEST_FPS_POLICY:-shared}" = "desktop-functional-cap" ]; then
    log_info "FPS policy, desktop-functional-cap"
    log_info "Detected output refresh, ${DISPLAY_TEST_FPS_REFRESH:-unknown}Hz"
    log_info "Functional FPS target, ${DISPLAY_TEST_FPS_EXPECTED:-unknown}"
    log_info "Minimum acceptable FPS, ${DISPLAY_TEST_FPS_MIN_OK:-unknown}"
elif [ "${DISPLAY_FPS_MODE:-}" = "detected" ]; then
    log_info "Resolved FPS policy, mode=${DISPLAY_FPS_MODE} refresh=${DISPLAY_FPS_DETECTED_HZ}Hz expected=${DISPLAY_FPS_EXPECTED} min_ok=${DISPLAY_FPS_MIN_OK}"
else
    log_info "Resolved FPS policy, mode=${DISPLAY_FPS_MODE} expected=${DISPLAY_FPS_EXPECTED} range=[${DISPLAY_FPS_MIN_OK},${DISPLAY_FPS_MAX_OK}]"
fi

if command -v display_debug_snapshot >/dev/null 2>&1; then
    display_debug_snapshot "${TESTNAME}: before-refresh-policy"
fi

case "$OS_ID" in
    debian|ubuntu|centos|rhel|fedora)
        log_info "Desktop distribution detected, keeping the active Weston output mode unchanged"
        ;;

    *)
        if command -v display_apply_fps_refresh_policy >/dev/null 2>&1; then
            display_apply_fps_refresh_policy || true
        else
            log_warn "display_apply_fps_refresh_policy helper is unavailable"
        fi

        if [ "${WESTON_OUTPUT_MODE_UPDATED:-0}" = "1" ]; then
            log_info "Weston output configuration changed, revalidating the image-provided runtime"

            if ! display_prepare_image_weston_runtime \
                "$TESTNAME" \
                "$WAIT_SECS" \
                "$DISPLAY_BUILD_FLAVOUR"; then
                log_fail "$TESTNAME FAIL - image-provided Weston runtime did not recover after output-mode update"
                echo "$TESTNAME FAIL" >"$RES_FILE"
                exit 0
            fi
        fi
        ;;
esac

if command -v display_debug_snapshot >/dev/null 2>&1; then
    display_debug_snapshot "${TESTNAME}: after-refresh-policy"
fi

if command -v display_is_cpu_renderer >/dev/null 2>&1; then
    if display_is_cpu_renderer wayland; then
        log_skip "$TESTNAME SKIP - CPU or software renderer detected on the Wayland EGL path"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
else
    log_warn "display_is_cpu_renderer helper is unavailable, continuing without renderer gating"
fi

BIN="$(command -v "$TESTNAME" 2>/dev/null || true)"

if [ -z "$BIN" ]; then
    log_skip "$TESTNAME SKIP - required binary is unavailable"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_info "Using client binary, $BIN"
log_info "Wayland socket, ${DISPLAY_WAYLAND_SOCKET:-<unknown>}"
log_info "Wayland session user, ${DISPLAY_WAYLAND_SESSION_USER:-current-user}"
log_info "XDG_RUNTIME_DIR, ${DISPLAY_WAYLAND_SESSION_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-<unset>}}"
log_info "WAYLAND_DISPLAY, $(basename "${DISPLAY_WAYLAND_SOCKET:-${WAYLAND_DISPLAY:-<unset>}}")"

SIMPLE_EGL_CLIENT_ARG=""
SIMPLE_EGL_LAUNCH_MODE="compositor-synchronized"
SIMPLE_EGL_FPS_SOURCE="client-synchronized"

if [ "${DISPLAY_TEST_FPS_POLICY:-shared}" = "desktop-functional-cap" ]; then
    simple_egl_help="$("$BIN" -h 2>&1)"

    if printf '%s\n' "$simple_egl_help" |
        grep -Eq '(^|[[:space:]])-b([[:space:]]|$)'; then
        SIMPLE_EGL_CLIENT_ARG="-b"
        SIMPLE_EGL_LAUNCH_MODE="desktop-unsynchronized-benchmark"
        SIMPLE_EGL_FPS_SOURCE="client-unsynchronized-benchmark"
        log_info "Benchmark FPS is unsynchronized EGL throughput, not display refresh"
    else
        log_warn "weston-simple-egl does not advertise -b, keeping compositor-synchronized mode"
    fi
fi

log_info "Client mode, $SIMPLE_EGL_LAUNCH_MODE"

set -- "$BIN"

if [ -n "$SIMPLE_EGL_CLIENT_ARG" ]; then
    set -- "$@" "$SIMPLE_EGL_CLIENT_ARG"
fi

# Retain the existing environment on Yocto. Upstream weston-simple-egl prints
# FPS unconditionally, while vendor builds may also honor these variables.
SIMPLE_EGL_FPS=1
WESTON_SIMPLE_EGL_FPS=1
export SIMPLE_EGL_FPS
export WESTON_SIMPLE_EGL_FPS

# A clock step inside the window corrupts both the interval and the client's
# frame accounting. Settle the clock first, measure monotonically, then check
# whether a step slipped in anyway.
wait_for_time_sync || true

log_info "Launching $TESTNAME for $DURATION"

start_ts="$(date +%s)"
start_mono="$(get_monotonic_seconds)"
rc=0

if command -v run_with_timeout >/dev/null 2>&1; then
    log_info "Using run_with_timeout"

    if [ -n "${DISPLAY_WAYLAND_SESSION_USER:-}" ] &&
       command -v timeout >/dev/null 2>&1; then
        log_info "Using session-local timeout to reap the desktop Wayland client"

        if command -v stdbuf >/dev/null 2>&1; then
            display_run_in_wayland_session \
                timeout \
                "$DURATION" \
                stdbuf \
                -oL \
                -eL \
                "$@" >>"$RUN_LOG" 2>&1
            rc=$?
        else
            log_warn "stdbuf is unavailable, running the client without line buffering"

            display_run_in_wayland_session \
                timeout \
                "$DURATION" \
                "$@" >>"$RUN_LOG" 2>&1
            rc=$?
        fi
    elif command -v stdbuf >/dev/null 2>&1; then
        run_with_timeout \
            "$DURATION" \
            display_run_in_wayland_session \
            stdbuf \
            -oL \
            -eL \
            "$@" >>"$RUN_LOG" 2>&1
        rc=$?
    else
        log_warn "stdbuf is unavailable, running the client without line buffering"

        run_with_timeout \
            "$DURATION" \
            display_run_in_wayland_session \
            "$@" >>"$RUN_LOG" 2>&1
        rc=$?
    fi
else
    log_warn "run_with_timeout is unavailable, using bounded process control"

    duration_secs="$(
        printf '%s\n' "$DURATION" |
            sed -n 's/^\([0-9][0-9]*\)s$/\1/p'
    )"

    stop_grace_secs="$(
        printf '%s\n' "$STOP_GRACE" |
            sed -n 's/^\([0-9][0-9]*\)s$/\1/p'
    )"

    [ -n "$duration_secs" ] || duration_secs=30
    [ -n "$stop_grace_secs" ] || stop_grace_secs=3

    display_run_in_wayland_session "$@" >>"$RUN_LOG" 2>&1 &
    APP_PID=$!
    run_elapsed=0

    while [ "$run_elapsed" -lt "$duration_secs" ]; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            break
        fi

        sleep 1
        run_elapsed=$((run_elapsed + 1))
    done

    if kill -0 "$APP_PID" 2>/dev/null; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        grace_elapsed=0

        while [ "$grace_elapsed" -lt "$stop_grace_secs" ]; do
            if ! kill -0 "$APP_PID" 2>/dev/null; then
                break
            fi

            sleep 1
            grace_elapsed=$((grace_elapsed + 1))
        done

        if kill -0 "$APP_PID" 2>/dev/null; then
            kill -KILL "$APP_PID" 2>/dev/null || true
        fi

        wait "$APP_PID" 2>/dev/null || true
        rc=143
    else
        wait "$APP_PID"
        rc=$?
    fi

    APP_PID=""
fi

end_ts="$(date +%s)"
end_mono="$(get_monotonic_seconds)"
elapsed=$((end_mono - start_mono))

clock_step="$(
    clock_step_seconds \
        "$start_mono" \
        "$start_ts" \
        "$end_mono" \
        "$end_ts"
)"

clock_stepped=0

if [ "$clock_step" -gt "$CLOCK_STEP_TOLERANCE" ]; then
    clock_stepped=1
fi

log_info "Client finished, rc=${rc} elapsed=${elapsed}s"

if [ "$clock_stepped" -eq 1 ]; then
    log_warn "System clock stepped by ${clock_step}s during the run; FPS samples from the client are not trustworthy"
fi

fps_count=0
fps_avg="-"
fps_min="-"
fps_max="-"

if command -v display_parse_fps_log >/dev/null 2>&1 &&
   display_parse_fps_log "$RUN_LOG"; then
    fps_count="$DISPLAY_FPS_COUNT"
    fps_avg="$DISPLAY_FPS_AVG"
    fps_min="$DISPLAY_FPS_MIN"
    fps_max="$DISPLAY_FPS_MAX"

    log_info "FPS stats, samples=${fps_count} avg=${fps_avg} min=${fps_min} max=${fps_max} single_frame=${DISPLAY_FPS_SINGLE_FRAME:-0}"
else
    log_warn "No FPS samples were detected in $RUN_LOG"
fi

fps_for_summary="$fps_avg"

if [ "$fps_count" -eq 0 ]; then
    fps_for_summary="-"
fi

if [ "${DISPLAY_TEST_FPS_POLICY:-shared}" = "desktop-functional-cap" ]; then
    log_info "Result summary, rc=${rc} elapsed=${elapsed}s fps=${fps_for_summary} mode=desktop-functional target=${DISPLAY_TEST_FPS_EXPECTED:-unknown} min_ok=${DISPLAY_TEST_FPS_MIN_OK:-unknown} graphics=${DISPLAY_BUILD_FLAVOUR} source=${SIMPLE_EGL_FPS_SOURCE}"
elif [ "${DISPLAY_TEST_FPS_POLICY:-shared}" = "desktop-session-connectivity" ]; then
    log_info "Result summary, rc=${rc} elapsed=${elapsed}s fps=${fps_for_summary} mode=desktop-session-connectivity graphics=${DISPLAY_BUILD_FLAVOUR} source=${SIMPLE_EGL_FPS_SOURCE}"
elif [ "${DISPLAY_FPS_MODE:-}" = "detected" ]; then
    log_info "Result summary, rc=${rc} elapsed=${elapsed}s fps=${fps_for_summary} mode=${DISPLAY_FPS_MODE} refresh=${DISPLAY_FPS_DETECTED_HZ}Hz expected=${DISPLAY_FPS_EXPECTED} min_ok=${DISPLAY_FPS_MIN_OK} graphics=${DISPLAY_BUILD_FLAVOUR} source=${SIMPLE_EGL_FPS_SOURCE}"
else
    log_info "Result summary, rc=${rc} elapsed=${elapsed}s fps=${fps_for_summary} mode=${DISPLAY_FPS_MODE} expected=${DISPLAY_FPS_EXPECTED} range=[${DISPLAY_FPS_MIN_OK},${DISPLAY_FPS_MAX_OK}] graphics=${DISPLAY_BUILD_FLAVOUR} source=${SIMPLE_EGL_FPS_SOURCE}"
fi

final="PASS"

case "$rc" in
    0|143)
        ;;
    124)
        if [ "${DISPLAY_RUNTIME_MODEL:-}" != "desktop-gnome-session" ]; then
            log_fail "$TESTNAME execution timed out unexpectedly, rc=$rc runtime=${DISPLAY_RUNTIME_MODEL:-unknown}"
            final="FAIL"
        fi
        ;;
    *)
        log_fail "$TESTNAME execution failed, rc=$rc"
        final="FAIL"
        ;;
esac

if [ "$elapsed" -le 1 ]; then
    log_fail "$TESTNAME exited too quickly, elapsed=${elapsed}s"
    final="FAIL"
fi


if [ "$clock_stepped" -eq 1 ]; then
    # Averaging across a step measures the step, not the GPU.
    log_skip "$TESTNAME SKIP - system clock stepped by ${clock_step}s during the ${elapsed}s run, FPS gate skipped (samples=${fps_count} avg=${fps_avg} max=${fps_max} single_frame=${DISPLAY_FPS_SINGLE_FRAME:-0})"

    if [ "$final" = "PASS" ]; then
        final="SKIP"
    fi
elif ! display_apply_test_fps_gate_policy \
    "$fps_avg" \
    "$fps_count" \
    "$REQUIRE_FPS"; then
    final="FAIL"
fi

if [ "$final" != "PASS" ]; then
    log_info "----- Last 200 client log lines -----"

    tail -n 200 "$RUN_LOG" 2>/dev/null |
        while IFS= read -r line; do
            log_info "[client] $line"
        done

    log_info "----- End client log -----"
fi

{
    printf '%s\n' "requested_graphics_mode=$REQUESTED_GRAPHICS_MODE"
    printf '%s\n' "detected_graphics_mode=$DISPLAY_BUILD_FLAVOUR"
    printf '%s\n' "os_id=$OS_ID"
    printf '%s\n' "runtime_model=${DISPLAY_RUNTIME_MODEL:-unknown}"
    printf '%s\n' "wayland_socket=${DISPLAY_WAYLAND_SOCKET:-unknown}"
    printf '%s\n' "simple_egl_launch_mode=$SIMPLE_EGL_LAUNCH_MODE"
    printf '%s\n' "simple_egl_client_arg=${SIMPLE_EGL_CLIENT_ARG:-none}"
    printf '%s\n' "fps_sample_source=$SIMPLE_EGL_FPS_SOURCE"
    printf '%s\n' "fps_gate_policy=${DISPLAY_TEST_FPS_POLICY:-shared}"
    printf '%s\n' "fps_required=$REQUIRE_FPS"
    printf '%s\n' "fps_gate_refresh=${DISPLAY_TEST_FPS_REFRESH:-unknown}"
    printf '%s\n' "fps_gate_expected=${DISPLAY_TEST_FPS_EXPECTED:-unknown}"
    printf '%s\n' "fps_gate_minimum=${DISPLAY_TEST_FPS_MIN_OK:-unknown}"
    printf '%s\n' "client_rc=$rc"
    printf '%s\n' "elapsed_seconds=$elapsed"
    printf '%s\n' "clock_step_seconds=$clock_step"
    printf '%s\n' "fps_samples=$fps_count"
    printf '%s\n' "fps_single_frame_samples=${DISPLAY_FPS_SINGLE_FRAME:-0}"
    printf '%s\n' "fps_average=$fps_avg"
    printf '%s\n' "fps_minimum=$fps_min"
    printf '%s\n' "fps_maximum=$fps_max"
    printf '%s\n' "result=$final"
} >>"$RUN_LOG"

echo "$TESTNAME $final" >"$RES_FILE"

trap - EXIT HUP INT TERM
cleanup_client

case "$final" in
    PASS)
        log_pass "$TESTNAME : PASS"
        ;;
    SKIP)
        log_skip "$TESTNAME : SKIP"
        ;;
    *)
        log_fail "$TESTNAME : FAIL"
        ;;
esac

log_info "------------------- Completed ${TESTNAME} Testcase -------------------------"
exit 0
