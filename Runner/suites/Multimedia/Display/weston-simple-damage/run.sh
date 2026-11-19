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
            echo "[ERROR] Unknown option: $1" >&2
            echo "Usage: $0 [--auto|--base|--overlay] [--wait-secs N]" >&2
            exit 1
            ;;
    esac

    shift
done

case "$REQUESTED_GRAPHICS_MODE" in
    auto|base|overlay)
        ;;
    *)
        echo "[ERROR] Unsupported graphics mode: $REQUESTED_GRAPHICS_MODE" >&2
        exit 1
        ;;
esac

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

case "$ALLOW_RELAUNCH" in
    0|1)
        ;;
    *)
        echo "[ERROR] ALLOW_RELAUNCH must be 0 or 1: $ALLOW_RELAUNCH" >&2
        exit 1
        ;;
esac

case "$VALIDATE_WAYLAND_PROTO" in
    0|1)
        ;;
    *)
        echo "[ERROR] VALIDATE_WAYLAND_PROTO must be 0 or 1" >&2
        exit 1
        ;;
esac

case "$VALIDATE_SCREENSHOT" in
    0|1)
        ;;
    *)
        echo "[ERROR] VALIDATE_SCREENSHOT must be 0 or 1" >&2
        exit 1
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

: >"$RES_FILE"
: >"$RUN_LOG"
: >"$STDOUT_LOG"

# cleanup_client is invoked indirectly through trap.
# shellcheck disable=SC2317
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
    display_ensure_weston_test_dependencies \
    display_detect_build_flavour \
    display_log_snapshot_and_require_connector; do
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

log_info "Launching $TESTNAME for $DURATION"

start_ts="$(date +%s)"
rc=0

if command -v run_with_timeout >/dev/null 2>&1; then
    if command -v stdbuf >/dev/null 2>&1; then
        run_with_timeout \
            "$DURATION" \
            stdbuf \
            -oL \
            -eL \
            "$BIN" >>"$RUN_LOG" 2>&1
        rc=$?
    else
        run_with_timeout \
            "$DURATION" \
            "$BIN" >>"$RUN_LOG" 2>&1
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

    "$BIN" >>"$RUN_LOG" 2>&1 &
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

        rc=143
    else
        wait "$APP_PID" 2>/dev/null
        rc=$?
    fi

    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
fi

unset WAYLAND_DEBUG

end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))

log_info "Client finished, rc=$rc elapsed=${elapsed}s"

tail -n 400 "$RUN_LOG" >"$STDOUT_LOG" 2>/dev/null || true

final="PASS"

case "$rc" in
    0|124|137|143)
        ;;
    *)
        log_fail "$TESTNAME exited unexpectedly, rc=$rc"
        final="FAIL"
        ;;
esac

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
fi

if [ "$VALIDATE_SCREENSHOT" -ne 0 ] &&
   [ "$shot_begin_rc" -eq 0 ]; then
    if command -v display_screenshot_delta_end >/dev/null 2>&1; then
        display_screenshot_delta_end "$TESTNAME"
        shot_end_rc=$?

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
    else
        log_warn "display_screenshot_delta_end helper is unavailable"
    fi
fi

echo "$TESTNAME $final" >"$RES_FILE"

if [ "$final" = "PASS" ]; then
    log_pass "$TESTNAME : PASS"
else
    log_fail "$TESTNAME : FAIL"
fi

exit 0
