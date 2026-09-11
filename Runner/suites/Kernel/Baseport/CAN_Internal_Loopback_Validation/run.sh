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
. "$TOOLS/lib_bus.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_pkg_provider.sh"
TESTNAME="CAN_Internal_Loopback_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

RESULT_DIR="$SCRIPT_DIR/.${TESTNAME}.work.$$"
CAN_INTERFACE="${CAN_INTERFACE:-}"
CAN_LOOPBACK_MODE="${CAN_LOOPBACK_MODE:-auto}"
CAN_BITRATE="${CAN_BITRATE:-500000}"
CAN_DBITRATE="${CAN_DBITRATE:-2000000}"
CAN_LOOPBACK_TIMEOUT="${CAN_LOOPBACK_TIMEOUT:-10}"

cleanup() {
    can_internal_loopback_cleanup >/dev/null 2>&1 || true
    rm -rf "$RESULT_DIR"
}

usage() {
    cat <<EOF
Usage: $0 [options]
  --interface NAME    Override auto-detection with a physical CAN interface
  --mode auto|classic|fd
                      Frame modes, default: $CAN_LOOPBACK_MODE
  --bitrate BPS       Classic arbitration bitrate, default: $CAN_BITRATE
  --dbitrate BPS      CAN FD data bitrate, default: $CAN_DBITRATE
  --timeout SECONDS   Receive timeout, default: $CAN_LOOPBACK_TIMEOUT
  -h, --help          Show this help

The interface must initially be down. The test applies the requested bitrates.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --interface)
                [ "$#" -ge 2 ] || return 2
                CAN_INTERFACE="$2"
                shift 2
                ;;
            --mode)
                [ "$#" -ge 2 ] || return 2
                CAN_LOOPBACK_MODE="$2"
                shift 2
                ;;
            --bitrate)
                [ "$#" -ge 2 ] || return 2
                CAN_BITRATE="$2"
                shift 2
                ;;
            --dbitrate)
                [ "$#" -ge 2 ] || return 2
                CAN_DBITRATE="$2"
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                CAN_LOOPBACK_TIMEOUT="$2"
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

validate_config() {
    case "$CAN_LOOPBACK_MODE" in
        auto|classic|fd)
            ;;
        *)
            log_error "Unsupported CAN loopback mode: $CAN_LOOPBACK_MODE"
            return 2
            ;;
    esac
    for numeric_value in "$CAN_LOOPBACK_TIMEOUT" "$CAN_BITRATE" "$CAN_DBITRATE"; do
        case "$numeric_value" in
            ''|*[!0-9]*|0)
                log_error "CAN timeout, bitrate, and data bitrate must be positive integers"
                return 2
                ;;
        esac
    done
}

if ! parse_args "$@"; then
    usage >&2
    exit 2
fi
if ! validate_config; then
    usage >&2
    exit 2
fi

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
trap cleanup EXIT HUP INT TERM

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create temporary evidence directory"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
CAN_SELECTION_SOURCE=override
if [ -z "$CAN_INTERFACE" ]; then
    CAN_SELECTION_SOURCE=auto
    CAN_INTERFACE=$(can_internal_loopback_select_interface "$CAN_LOOPBACK_MODE" 2>/dev/null)
    CAN_SELECTION_STATUS=$?
    if [ "$CAN_SELECTION_STATUS" -eq 1 ]; then
        test_result_finish "SKIP" "$TESTNAME SKIP: multiple eligible CAN interfaces were detected, select one with --interface or CAN_INTERFACE"
    fi
    if [ "$CAN_SELECTION_STATUS" -eq 3 ]; then
        test_result_finish "FAIL" "$TESTNAME FAIL: unsupported CAN loopback mode $CAN_LOOPBACK_MODE"
    fi
elif ! can_internal_loopback_interface_is_ready "$CAN_INTERFACE"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: requested interface $CAN_INTERFACE is not a down physical SocketCAN interface, package recovery was not attempted"
fi
if [ -z "$CAN_INTERFACE" ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no unique down physical CAN interface was detected"
fi
pkg_ensure_host_distro_package_set_present can-loopback
CAN_PACKAGE_STATUS=$?
case "$CAN_PACKAGE_STATUS" in
    0)
        log_info "CAN functional package set is ready"
        ;;
    1)
        test_result_finish "SKIP" "$TESTNAME SKIP: failed to recover CAN functional packages for $(pkg_detect_os_id)"
        ;;
    2)
        log_info "CAN package recovery is not applicable, using image-provided commands"
        ;;
    *)
        test_result_finish "FAIL" "$TESTNAME FAIL: package preparation returned unexpected status $CAN_PACKAGE_STATUS"
        ;;
esac
if ! bus_validation_require_commands awk candump cansend cat grep ip mkdir sed sleep tr; then
    test_result_finish "SKIP" "$TESTNAME SKIP: ip or CAN-utils are unavailable after applicable package recovery"
fi
CAN_LOOPBACK_MODES=$CAN_LOOPBACK_MODE
if [ "$CAN_LOOPBACK_MODE" = "auto" ]; then
    CAN_LOOPBACK_MODES=$(can_internal_loopback_select_modes "$CAN_INTERFACE")
    CAN_MODE_SELECTION_STATUS=$?
    if [ "$CAN_MODE_SELECTION_STATUS" -ne 0 ] || [ -z "$CAN_LOOPBACK_MODES" ]; then
        test_result_finish "FAIL" "$TESTNAME FAIL: could not derive loopback modes for $CAN_INTERFACE"
    fi
fi
log_info "Configuration: interface=$CAN_INTERFACE selection=$CAN_SELECTION_SOURCE modes=$CAN_LOOPBACK_MODES bitrate=$CAN_BITRATE dbitrate=$CAN_DBITRATE timeout=${CAN_LOOPBACK_TIMEOUT}s"

log_info "CAN loopback: validating standard, extended, and available FD frame paths while checking packet and error-counter deltas"
CAN_REMAINING_MODES=$CAN_LOOPBACK_MODES
while [ -n "$CAN_REMAINING_MODES" ]; do
    case "$CAN_REMAINING_MODES" in
        *,*)
            CAN_MODE=${CAN_REMAINING_MODES%%,*}
            CAN_REMAINING_MODES=${CAN_REMAINING_MODES#*,}
            ;;
        *)
            CAN_MODE=$CAN_REMAINING_MODES
            CAN_REMAINING_MODES=""
            ;;
    esac
    log_info "---- CAN functional case: interface=$CAN_INTERFACE mode=$CAN_MODE ----"
    can_internal_loopback_validate \
        "$CAN_INTERFACE" \
        "$CAN_MODE" \
        "$CAN_LOOPBACK_TIMEOUT" \
        "$RESULT_DIR" \
        "$CAN_BITRATE" \
        "$CAN_DBITRATE"
    loopback_status=$?
    case "$loopback_status" in
        0)
            test_result_record "PASS" "CAN $CAN_MODE internal loopback frames and counter deltas passed on $CAN_INTERFACE"
            ;;
        1)
            test_result_record "FAIL" "CAN $CAN_MODE internal loopback failed on $CAN_INTERFACE, see $RESULT_DIR/can_loopback_rx_${CAN_MODE}.log and $RESULT_DIR/can_loopback_statistics_${CAN_MODE}.log"
            ;;
        2)
            if [ "$CAN_LOOPBACK_MODE" = "fd" ]; then
                test_result_record "FAIL" "CAN FD was explicitly requested but $CAN_INTERFACE rejected bitrate=$CAN_BITRATE dbitrate=$CAN_DBITRATE configuration"
            else
                test_result_record "SKIP" "$CAN_INTERFACE does not accept the automatic $CAN_MODE configuration"
            fi
            ;;
        *)
            test_result_record "FAIL" "CAN loopback helper returned unexpected status $loopback_status for mode $CAN_MODE"
            ;;
    esac
done

test_result_finish
