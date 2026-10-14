#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# KMSCube Validator Script (Yocto-Compatible, POSIX sh)

# usage
# Print the supported KMSCube command-line options.
usage() {
    cat <<EOF
Usage: ${0##*/} [--base|--overlay|--auto] [--timeout SECONDS] [--help]

Run the KMSCube DRM/GBM validation.

Options:
  --base             Use upstream MSM/freedreno on supported desktop distros.
  --overlay          Use the Qualcomm graphics overlay on supported desktop distros.
  --auto             Preserve and validate the currently active graphics stack.
  --timeout SECONDS  Stop kmscube if it exceeds this duration, default: 60.
  -h, --help         Show this help text and exit without changing target state.
EOF
}

# parse_args ARG...
# Parse graphics-mode and timeout options into runner globals.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --base|--no-overlay)
                REQUESTED_GRAPHICS_MODE="base"
                ;;
            --overlay)
                REQUESTED_GRAPHICS_MODE="overlay"
                ;;
            --auto)
                REQUESTED_GRAPHICS_MODE="auto"
                ;;
            --timeout)
                shift

                if [ "$#" -eq 0 ]; then
                    PARSE_ERROR="--timeout requires a value"
                    return 1
                fi

                KMSCUBE_TIMEOUT="$1"
                ;;
            --timeout=*)
                KMSCUBE_TIMEOUT=${1#*=}
                ;;
            -h|--help)
                SHOW_HELP=1
                ;;
            --)
                shift
                if [ "$#" -gt 0 ]; then
                    PARSE_ERROR="unexpected positional argument: $1"
                    return 1
                fi
                break
                ;;
            *)
                PARSE_ERROR="unknown argument: $1"
                return 1
                ;;
        esac
        shift
    done

    return 0
}

REQUESTED_GRAPHICS_MODE="default"
KMSCUBE_TIMEOUT=60
SHOW_HELP=0
PARSE_ERROR=""

parse_args "$@"
PARSE_RC=$?

if [ "$SHOW_HELP" -eq 1 ]; then
    usage
    exit 0
fi

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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
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

TESTNAME="KMSCube"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1

LOG_FILE="./${TESTNAME}_run.log"
FAILURE_LOG="./${TESTNAME}_failure_markers.log"

if [ "$PARSE_RC" -ne 0 ]; then
    rm -f "$RES_FILE"
    log_fail "$TESTNAME FAIL - $PARSE_ERROR"
    usage >&2
    printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

case "$KMSCUBE_TIMEOUT" in
    ''|*[!0-9]*|0)
        rm -f "$RES_FILE"
        log_fail "$TESTNAME FAIL - --timeout must be a positive integer, value=$KMSCUBE_TIMEOUT"
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
        ;;
esac

FRAME_COUNT="${FRAME_COUNT:-999}"
EXPECTED_MIN=$((FRAME_COUNT - 1))

KMSCUBE_DRM_CONNECTOR=""
KMSCUBE_DRM_DEV=""

OS_ID="unknown"
DISTRO_GPU_HANDLING_SUPPORTED=0
UBUNTU_GRAPHICS_VARIANT=""

GPU_MODULE="msm_kgsl"
GPU_OVERLAY_DEVICE="/dev/kgsl-3d0"
GPU_OVERLAY_GBM_PACKAGE="${GPU_OVERLAY_GBM_PACKAGE:-}"

DISPLAY_MANAGER_SERVICE="${DISPLAY_MANAGER_SERVICE:-display-manager.service}"
DISPLAY_MANAGER_STATE_FILE="/tmp/qcom-testkit-${TESTNAME}-display-manager.$$.state"
weston_stopped_by_test=0

rm -f \
    "$RES_FILE" \
    "$LOG_FILE" \
    "$FAILURE_LOG" \
    "$DISPLAY_MANAGER_STATE_FILE"

trap '
if [ "${weston_stopped_by_test:-0}" -eq 1 ] &&
   command -v weston_restore_runtime >/dev/null 2>&1; then
    weston_restore_runtime 15 >/dev/null 2>&1 || true
fi
if command -v display_restore_service_from_state >/dev/null 2>&1; then
    display_restore_service_from_state "$DISPLAY_MANAGER_STATE_FILE" >/dev/null 2>&1 || true
fi
rm -f "$DISPLAY_MANAGER_STATE_FILE"
' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Detect OS once ----------------------------------------------------------
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
        centos|rhel)
            GPU_OVERLAY_GBM_PACKAGE="gbm-msm-backend"
            ;;
        *)
            GPU_OVERLAY_GBM_PACKAGE="libgbm-msm1"
            ;;
    esac
fi

case "$OS_ID" in
    ubuntu)
        DISTRO_GPU_HANDLING_SUPPORTED=1
        ;;

    debian|centos|rhel|fedora)
        DISTRO_GPU_HANDLING_SUPPORTED=1
        ;;
esac

if ! command -v display_resolve_graphics_mode >/dev/null 2>&1; then
    log_fail "$TESTNAME FAIL - required graphics policy helper is unavailable: display_resolve_graphics_mode"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

REQUESTED_GRAPHICS_MODE="$(
    display_resolve_graphics_mode \
        "$OS_ID" \
        "$REQUESTED_GRAPHICS_MODE"
)" || {
    log_fail "$TESTNAME FAIL - unable to resolve graphics mode for os=$OS_ID"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
}

if [ "$OS_ID" = "ubuntu" ]; then
    if ! command -v display_detect_ubuntu_variant >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - required Ubuntu profile helper is unavailable: display_detect_ubuntu_variant"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi

    UBUNTU_GRAPHICS_VARIANT="$(display_detect_ubuntu_variant)"
    log_info "Ubuntu graphics profile, $UBUNTU_GRAPHICS_VARIANT"

    if [ "$UBUNTU_GRAPHICS_VARIANT" = "server" ]; then
        log_skip "$TESTNAME SKIP - Ubuntu Server is headless, run this graphics test on Ubuntu Desktop with a connected DRM display"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi

    if [ "$REQUESTED_GRAPHICS_MODE" = "base" ]; then
        log_skip "$TESTNAME SKIP - Ubuntu Desktop supports the Qualcomm overlay graphics configuration, use the default mode or --overlay"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
fi

log_info "Graphics mode, requested=$REQUESTED_GRAPHICS_MODE os=$OS_ID"

# --- Configure requested package and boot stack ------------------------------
# Yocto/qcom-distro images keep their native image-selected graphics stack.
if [ "$DISTRO_GPU_HANDLING_SUPPORTED" -eq 1 ]; then
    for required_helper in \
        pkg_ensure_command \
        display_prepare_desktop_graphics_stack \
        display_detect_build_flavour \
        display_select_egl_vendor \
        display_stop_service_for_drm \
        display_restore_service_from_state; do
        if ! command -v "$required_helper" >/dev/null 2>&1; then
            log_fail "$TESTNAME FAIL - required helper is unavailable: $required_helper"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi
    done

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

    if [ "$REQUESTED_GRAPHICS_MODE" = "auto" ]; then
        display_detect_build_flavour

        if [ "${DISPLAY_BUILD_FLAVOUR:-base}" = "overlay" ]; then
            if ! display_select_egl_vendor adreno; then
                log_fail "$TESTNAME FAIL - failed to select the detected Adreno EGL vendor"
                echo "$TESTNAME FAIL" >"$RES_FILE"
                exit 0
            fi
        elif ! display_select_egl_vendor mesa; then
            log_skip "$TESTNAME SKIP - detected base stack has no usable Mesa EGL vendor"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi
    fi
else
    log_info "Graphics package-stack and GPU boot-mode handling skipped for os=$OS_ID"
fi

# modetest provides connector diagnostics before the no-display decision.
# CentOS continues with sysfs display detection when the command is absent
# because no verified CentOS package currently provides it.
if ! command -v modetest >/dev/null 2>&1; then
    if [ "$OS_ID" = "centos" ]; then
        log_warn "modetest is unavailable on CentOS, continuing with sysfs display detection"
    elif [ "$DISTRO_GPU_HANDLING_SUPPORTED" -eq 1 ]; then
        log_info "modetest is missing, attempting package recovery"

        if ! pkg_ensure_command modetest; then
            log_fail "$TESTNAME FAIL - failed to recover required command modetest, install the mapped libdrm-tests package"
            printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi

        hash -r 2>/dev/null || true
    else
        log_skip "$TESTNAME SKIP - required command modetest is absent from the image"
        printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
fi

log_info "-------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase -------------------"

# --- Display snapshot --------------------------------------------------------
if command -v display_debug_snapshot >/dev/null 2>&1; then
    display_debug_snapshot "pre-display-check"
fi

if command -v modetest >/dev/null 2>&1; then
    log_info "----- modetest -M msm -ac (capped at 200 lines) -----"

    modetest -M msm -ac 2>&1 |
        sed -n '1,200p' |
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            log_info "[modetest] $line"
        done

    log_info "----- End modetest -M msm -ac -----"
else
    log_warn "modetest not found in PATH, skipping modetest snapshot"
fi

have_connector=0

if command -v display_connected_summary >/dev/null 2>&1; then
    sysfs_summary="$(display_connected_summary)"

    if [ -n "$sysfs_summary" ] &&
       [ "$sysfs_summary" != "none" ]; then
        have_connector=1
        log_info "Connected display (sysfs): $sysfs_summary"
    fi
fi

if [ "$have_connector" -eq 0 ]; then
    log_skip "$TESTNAME SKIP - no connected DRM display found"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if command -v display_select_primary_connector >/dev/null 2>&1; then
    if KMSCUBE_DRM_CONNECTOR="$(display_select_primary_connector)"; then
        [ -n "$KMSCUBE_DRM_CONNECTOR" ] ||
            log_warn "display_select_primary_connector returned empty output"
    else
        KMSCUBE_DRM_CONNECTOR=""
        log_warn "display_select_primary_connector failed, connected display mapping may be unavailable"
    fi
else
    log_warn "display_select_primary_connector helper not found, connected display mapping may be unavailable"
fi

if command -v display_select_primary_drm_device >/dev/null 2>&1; then
    if KMSCUBE_DRM_DEV="$(display_select_primary_drm_device)"; then
        [ -n "$KMSCUBE_DRM_DEV" ] ||
            log_warn "display_select_primary_drm_device returned empty output, kmscube will use default DRM device selection"
    else
        KMSCUBE_DRM_DEV=""
        log_warn "display_select_primary_drm_device failed, kmscube will use default DRM device selection"
    fi
else
    log_warn "display_select_primary_drm_device helper not found, kmscube will use default DRM device selection"
fi

if [ -n "$KMSCUBE_DRM_DEV" ]; then
    log_info "Selected KMS connector: ${KMSCUBE_DRM_CONNECTOR:-<unknown>}"
    log_info "Selected KMS DRM device: $KMSCUBE_DRM_DEV"
else
    log_warn "Could not map connected display to a DRM card, kmscube will use default device selection"
fi

# --- Basic DRM availability guard -------------------------------------------
set -- /dev/dri/card* 2>/dev/null

if [ ! -e "$1" ]; then
    log_skip "$TESTNAME SKIP - no /dev/dri/card* nodes"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --- Dependencies ------------------------------------------------------------
if [ "$DISTRO_GPU_HANDLING_SUPPORTED" -eq 1 ]; then
    CHECK_DEPS_RECOVER=1
else
    CHECK_DEPS_RECOVER=0
fi

if [ "$OS_ID" = "centos" ]; then
    if ! CHECK_DEPS_RECOVER="$CHECK_DEPS_RECOVER" \
        CHECK_DEPS_NO_EXIT=1 \
        check_dependencies kmscube; then
        log_skip "$TESTNAME SKIP - kmscube is unavailable from the configured CentOS repositories, publish or provision the kmscube package"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
else
    if ! CHECK_DEPS_RECOVER="$CHECK_DEPS_RECOVER" \
        CHECK_DEPS_NO_EXIT=1 \
        check_dependencies kmscube modetest; then
        log_skip "$TESTNAME SKIP - missing dependencies: kmscube and/or modetest"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
fi

KMSCUBE_BIN="$(command -v kmscube 2>/dev/null || true)"
log_info "Using kmscube: ${KMSCUBE_BIN:-<not found>}"

if ! command -v run_with_managed_timeout >/dev/null 2>&1; then
    log_fail "$TESTNAME FAIL - required timeout helper is unavailable: run_with_managed_timeout"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

# --- GPU acceleration gating -------------------------------------------------
if command -v display_is_cpu_renderer >/dev/null 2>&1; then
    if display_is_cpu_renderer gbm >/dev/null 2>&1; then
        if display_is_cpu_renderer gbm; then
            log_skip "$TESTNAME SKIP - CPU/software renderer detected on GBM"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi
    else
        log_warn "display_is_cpu_renderer gbm not supported, falling back to auto"

        if display_is_cpu_renderer auto; then
            log_skip "$TESTNAME SKIP - CPU/software renderer detected"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi
    fi
else
    log_warn "display_is_cpu_renderer helper not found, continuing without GPU acceleration gating"
fi

# --- Release DRM master ------------------------------------------------------
if weston_is_running; then
    log_info "Weston is running, stopping it so kmscube can acquire DRM master"

    if weston_stop >/dev/null 2>&1; then
        weston_stopped_by_test=1
    else
        log_warn "weston_stop returned non-zero, re-checking Weston state"

        if ! weston_is_running; then
            weston_stopped_by_test=1
        fi
    fi
fi

if weston_is_running; then
    log_warn "Weston remains running, kmscube may fail to acquire DRM master"
fi

case "$OS_ID" in
    debian|ubuntu|centos|rhel|fedora)
        if ! display_stop_service_for_drm \
            "$DISPLAY_MANAGER_SERVICE" \
            "$KMSCUBE_DRM_DEV" \
            "$DISPLAY_MANAGER_STATE_FILE"; then
            log_fail "$TESTNAME FAIL - failed to release display-manager DRM ownership"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi
        ;;
    *)
        log_info "Display-manager handling skipped for os=$OS_ID"
        ;;
esac

# --- Execute kmscube ---------------------------------------------------------
unset WAYLAND_DISPLAY

EGL_PLATFORM_SAVED="${EGL_PLATFORM:-}"
export EGL_PLATFORM=gbm

rc=0

if [ -n "$KMSCUBE_DRM_DEV" ]; then
    log_info "Running kmscube on $KMSCUBE_DRM_DEV with --count=${FRAME_COUNT}, timeout=${KMSCUBE_TIMEOUT}s"

    run_with_managed_timeout \
        "$KMSCUBE_TIMEOUT" \
        /tmp \
        kmscube \
        "$KMSCUBE_BIN" \
        -D "$KMSCUBE_DRM_DEV" \
        --count="${FRAME_COUNT}" >"$LOG_FILE" 2>&1
    rc=$?
else
    log_info "Running kmscube with default DRM device selection and --count=${FRAME_COUNT}, timeout=${KMSCUBE_TIMEOUT}s"

    run_with_managed_timeout \
        "$KMSCUBE_TIMEOUT" \
        /tmp \
        kmscube \
        "$KMSCUBE_BIN" \
        --count="${FRAME_COUNT}" >"$LOG_FILE" 2>&1
    rc=$?
fi

if [ -n "$EGL_PLATFORM_SAVED" ]; then
    export EGL_PLATFORM="$EGL_PLATFORM_SAVED"
else
    unset EGL_PLATFORM
fi

if [ "$rc" -eq 124 ]; then
    log_fail "$TESTNAME : Execution timed out after ${KMSCUBE_TIMEOUT}s - see $LOG_FILE"
    cat "$LOG_FILE"
    echo "$TESTNAME FAIL" >"$RES_FILE"

    if [ "$weston_stopped_by_test" -eq 1 ]; then
        log_info "Restoring Weston after timeout"

        if weston_restore_runtime 15; then
            weston_stopped_by_test=0
        else
            log_error "Failed to restore Weston runtime after $TESTNAME timeout"
        fi
    fi

    display_restore_service_from_state "$DISPLAY_MANAGER_STATE_FILE" || true
    exit 1
fi

# Treat explicit error and failure words from kmscube as authoritative even
# when the process exits successfully. Ignore common zero-failure summaries.
awk '
    {
        line = tolower($0)
        has_error = line ~ /(^|[^[:alnum:]_])error([^[:alnum:]_]|$)/
        has_failure = line ~ /(^|[^[:alnum:]_])fail(ed|ure|ures)?([^[:alnum:]_]|$)/
        zero_failure = (
            line ~ /fail(ed|ure|ures)?[[:space:]]*[:=][[:space:]]*0([^0-9]|$)/ ||
            line ~ /(^|[^0-9])0[[:space:]]+(tests?[[:space:]]+)?fail(ed|ure|ures)?([^[:alnum:]_]|$)/
        )

        if ((has_error || has_failure) && !zero_failure) {
            print
        }
    }
' "$LOG_FILE" >"$FAILURE_LOG"

FAILURE_MARKER_COUNT="$(awk 'END { print NR + 0 }' "$FAILURE_LOG")"

if [ "$FAILURE_MARKER_COUNT" -gt 0 ]; then
    log_error "kmscube reported ERROR or FAIL output, matches=$FAILURE_MARKER_COUNT artifact=$FAILURE_LOG"

    while IFS= read -r failure_line; do
        [ -n "$failure_line" ] || continue
        log_error "[kmscube-output] $failure_line"
    done <"$FAILURE_LOG"
fi

if [ "$rc" -ne 0 ]; then
    log_fail "$TESTNAME : Execution failed (rc=$rc) - see $LOG_FILE"
    cat "$LOG_FILE"
    echo "$TESTNAME FAIL" >"$RES_FILE"

    if [ "$weston_stopped_by_test" -eq 1 ]; then
        log_info "Restoring Weston after failure"

        if weston_restore_runtime 15; then
            weston_stopped_by_test=0
        else
            log_error "Failed to restore Weston runtime after $TESTNAME failure"
        fi
    fi

    display_restore_service_from_state "$DISPLAY_MANAGER_STATE_FILE" || true
    exit 1
fi

# --- Parse rendered frame count ----------------------------------------------
FRAMES_RENDERED="$(
    awk '
        BEGIN {
            IGNORECASE = 1
        }

        /Rendered[[:space:]][0-9]+[[:space:]]+frames/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+$/) {
                    n = $i
                }
            }

            last = n
        }

        END {
            if (last != "") {
                print last
            }
        }
    ' "$LOG_FILE"
)"

[ -n "$FRAMES_RENDERED" ] || FRAMES_RENDERED=0

if [ "$EXPECTED_MIN" -lt 0 ]; then
    EXPECTED_MIN=0
fi

log_info "kmscube reported: Rendered ${FRAMES_RENDERED} frames (requested ${FRAME_COUNT}, min acceptable ${EXPECTED_MIN})"

restore_failed=0

if [ "$weston_stopped_by_test" -eq 1 ]; then
    log_info "Restoring Weston after $TESTNAME completion"

    if weston_restore_runtime 15; then
        weston_stopped_by_test=0
    else
        restore_failed=1
        log_error "Failed to restore Weston runtime after $TESTNAME"
    fi
fi

if ! display_restore_service_from_state "$DISPLAY_MANAGER_STATE_FILE"; then
    restore_failed=1
fi

# --- Verdict -----------------------------------------------------------------
if [ "$FAILURE_MARKER_COUNT" -gt 0 ]; then
    log_fail "$TESTNAME : FAIL (kmscube reported ERROR or FAIL output, matches=${FAILURE_MARKER_COUNT})"
    printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

if [ "$FRAMES_RENDERED" -lt "$EXPECTED_MIN" ]; then
    log_fail "$TESTNAME : FAIL (rendered ${FRAMES_RENDERED} < ${EXPECTED_MIN})"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

if [ "$restore_failed" -ne 0 ]; then
    log_fail "$TESTNAME : FAIL (rendered ${FRAMES_RENDERED}, but display runtime restore failed)"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

log_pass "$TESTNAME : PASS"
echo "$TESTNAME PASS" >"$RES_FILE"

log_info "------------------- Completed $TESTNAME Testcase ------------------"
exit 0
