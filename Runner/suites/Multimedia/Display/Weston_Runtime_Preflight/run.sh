#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Validate Weston and Wayland runtime health before Weston client tests.
# - Dynamic runtime discovery, no hardcoded runtime path assumptions
# - Default mode is strict runtime gating, no relaunch attempted
# - Optional relaunch mode can try to recover Weston runtime
# - CI-friendly PASS/FAIL/SKIP semantics, always exits 0

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

TESTNAME="Weston_Runtime_Preflight"

usage()
{
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --wait-secs N Seconds to wait for Weston runtime discovery, default: 10
  --validate-eglinfo Enable EGL pipeline diagnostics, default
  --no-validate-eglinfo Disable EGL pipeline diagnostics
  --allow-relaunch Allow runtime relaunch attempt when Weston is unhealthy
  -h, --help Show this help
EOF
}

WAIT_SECS="${WAIT_SECS:-10}"
VALIDATE_EGLINFO="${VALIDATE_EGLINFO:-1}"
ALLOW_RELAUNCH="${ALLOW_RELAUNCH:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --wait-secs)
            shift
            if [ $# -eq 0 ]; then
                echo "[ERROR] --wait-secs requires an argument" >&2
                exit 1
            fi
            WAIT_SECS="$1"
            ;;
        --wait-secs=*)
            WAIT_SECS=${1#*=}
            ;;
        --validate-eglinfo)
            VALIDATE_EGLINFO=1
            ;;
        --no-validate-eglinfo)
            VALIDATE_EGLINFO=0
            ;;
        --allow-relaunch)
            ALLOW_RELAUNCH=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

test_path="$(find_test_case_by_name "$TESTNAME")" || {
    log_fail "$TESTNAME, test directory not found"
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}

cd "$test_path" || exit 1

RES_FILE="./${TESTNAME}.res"
RUN_LOG="./${TESTNAME}_run.log"

: >"$RES_FILE"
: >"$RUN_LOG"

log_info "Weston log directory, $SCRIPT_DIR"
log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase --------------------------"
log_info "Config, WAIT_SECS=${WAIT_SECS} VALIDATE_EGLINFO=${VALIDATE_EGLINFO} ALLOW_RELAUNCH=${ALLOW_RELAUNCH}"

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform
fi

if command -v display_detect_build_flavour >/dev/null 2>&1; then
    display_detect_build_flavour
else
    DISPLAY_BUILD_FLAVOUR="base"
    DISPLAY_EGL_VENDOR_JSON=""
fi

if [ "$DISPLAY_BUILD_FLAVOUR" = "overlay" ]; then
    log_info "Build flavor, overlay, EGL vendor JSON present: ${DISPLAY_EGL_VENDOR_JSON}"
else
    log_info "Build flavor, base, no Adreno EGL vendor JSON found"
fi

if ! display_log_snapshot_and_require_connector "$TESTNAME" 200; then
    echo "${TESTNAME} SKIP" >"$RES_FILE"
    exit 0
fi

export ALLOW_RELAUNCH
if ! weston_prepare_runtime "$TESTNAME" "$WAIT_SECS" runtime; then
    echo "${TESTNAME} FAIL" >"$RES_FILE"
    exit 0
fi

if command -v display_select_primary_connector >/dev/null 2>&1; then
    primary_connector="$(display_select_primary_connector 2>/dev/null || true)"
    if [ -n "$primary_connector" ]; then
        log_info "Primary connector, ${primary_connector}"
        if command -v display_connector_cur_mode >/dev/null 2>&1; then
            primary_mode="$(display_connector_cur_mode "$primary_connector" 2>/dev/null || true)"
            if [ -n "$primary_mode" ] && [ "$primary_mode" != "-" ]; then
                log_info "Primary connector current mode, ${primary_mode}"
            fi
        fi
    fi
fi

if [ "$VALIDATE_EGLINFO" -ne 0 ] && command -v display_print_eglinfo_pipeline >/dev/null 2>&1; then
    log_info "Collecting EGL pipeline diagnostics"
    if ! display_print_eglinfo_pipeline auto; then
        log_warn "EGL pipeline detection did not complete cleanly, continuing"
    fi
fi

log_info "Final decision for ${TESTNAME}, PASS"
echo "${TESTNAME} PASS" >"$RES_FILE"
log_pass "${TESTNAME} : PASS"
exit 0
