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
TESTNAME="UART_Loopback_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

RESULT_DIR="$SCRIPT_DIR/.${TESTNAME}.work.$$"
UART_DEVICE="${UART_DEVICE:-}"
UART_BAUDS="${UART_BAUDS:-${UART_BAUD:-auto}}"
UART_PAYLOAD_BYTES="${UART_PAYLOAD_BYTES:-4096}"
UART_LOOPBACK_TIMEOUT="${UART_LOOPBACK_TIMEOUT:-10}"
UART_LOOPBACK_FIXTURE="${UART_LOOPBACK_FIXTURE:-0}"

cleanup() {
    uart_loopback_cleanup >/dev/null 2>&1 || true
    rm -rf "$RESULT_DIR"
}

usage() {
    cat <<EOF
Usage: $0 [options]
  --device PATH       Override auto-detection with a non-console UART device
  --baud LIST         Comma-separated baud rates, default: $UART_BAUDS
  --payload-bytes N   Bytes transferred at each baud, default: $UART_PAYLOAD_BYTES
  --timeout SECONDS   Read and write timeout, default: $UART_LOOPBACK_TIMEOUT
  --fixture            Confirm that an external TX-to-RX loopback fixture is connected
  -h, --help          Show this help

Environment equivalents: UART_DEVICE, UART_BAUDS, UART_PAYLOAD_BYTES,
  UART_LOOPBACK_TIMEOUT, UART_LOOPBACK_FIXTURE. UART_BAUD remains a compatible
  single-value fallback.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --device)
                [ "$#" -ge 2 ] || return 2
                UART_DEVICE="$2"
                shift 2
                ;;
            --baud)
                [ "$#" -ge 2 ] || return 2
                UART_BAUDS="$2"
                shift 2
                ;;
            --payload-bytes)
                [ "$#" -ge 2 ] || return 2
                UART_PAYLOAD_BYTES="$2"
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                UART_LOOPBACK_TIMEOUT="$2"
                shift 2
                ;;
            --fixture)
                UART_LOOPBACK_FIXTURE=1
                shift
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
    for numeric_value in "$UART_PAYLOAD_BYTES" "$UART_LOOPBACK_TIMEOUT"; do
        case "$numeric_value" in
            ''|*[!0-9]*|0)
                log_error "Payload bytes and timeout must be positive integers"
                return 2
                ;;
        esac
    done

    if [ -z "$UART_BAUDS" ]; then
        log_error "UART baud list must not be empty"
        return 2
    fi
    if [ "$UART_BAUDS" != "auto" ]; then
        case "$UART_BAUDS" in
            ,*|*,|*,,*)
                log_error "UART baud list contains an empty element: $UART_BAUDS"
                return 2
                ;;
        esac
        validate_uart_remaining_bauds=$UART_BAUDS
        while [ -n "$validate_uart_remaining_bauds" ]; do
            case "$validate_uart_remaining_bauds" in
                *,*)
                    validate_uart_baud=${validate_uart_remaining_bauds%%,*}
                    validate_uart_remaining_bauds=${validate_uart_remaining_bauds#*,}
                    ;;
                *)
                    validate_uart_baud=$validate_uart_remaining_bauds
                    validate_uart_remaining_bauds=""
                    ;;
            esac
            case "$validate_uart_baud" in
                ''|*[!0-9]*|0)
                    log_error "UART baud rates must be positive integers: $validate_uart_baud"
                    return 2
                    ;;
            esac
        done
    fi
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
if ! bus_validation_require_commands awk basename cmp dd grep mkdir od readlink rm sh sleep stty tr wc; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required image-provided UART loopback utilities are unavailable"
fi
if ! bus_validation_bool_true "$UART_LOOPBACK_FIXTURE"; then
    test_result_finish "SKIP" "$TESTNAME SKIP: external UART loopback fixture was not explicitly enabled, use --fixture or UART_LOOPBACK_FIXTURE=1"
fi

UART_SELECTION_SOURCE=override
if [ -z "$UART_DEVICE" ]; then
    UART_SELECTION_SOURCE=auto
    UART_DEVICE=$(uart_loopback_select_device 2>/dev/null)
    UART_SELECTION_STATUS=$?
    if [ "$UART_SELECTION_STATUS" -eq 1 ]; then
        test_result_finish "SKIP" "$TESTNAME SKIP: multiple eligible UART devices were detected, select one with --device or UART_DEVICE"
    fi
fi
if [ -z "$UART_DEVICE" ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no accessible DT-backed physical non-console UART was detected"
fi
if [ "$UART_BAUDS" = "auto" ]; then
    UART_BAUDS=$(uart_loopback_select_bauds "$UART_DEVICE")
    UART_BAUD_SELECTION_STATUS=$?
    if [ "$UART_BAUD_SELECTION_STATUS" -ne 0 ] || [ -z "$UART_BAUDS" ]; then
        test_result_finish "FAIL" "$TESTNAME FAIL: could not derive a baud matrix for $UART_DEVICE"
    fi
fi
log_info "Configuration: device=$UART_DEVICE selection=$UART_SELECTION_SOURCE bauds=$UART_BAUDS payload_bytes=$UART_PAYLOAD_BYTES timeout=${UART_LOOPBACK_TIMEOUT}s fixture=external-confirmed"

log_info "UART loopback: validating exact data transfer across the selected baud matrix with termios restoration after every case"
UART_REMAINING_BAUDS=$UART_BAUDS
while [ -n "$UART_REMAINING_BAUDS" ]; do
    case "$UART_REMAINING_BAUDS" in
        *,*)
            UART_BAUD=${UART_REMAINING_BAUDS%%,*}
            UART_REMAINING_BAUDS=${UART_REMAINING_BAUDS#*,}
            ;;
        *)
            UART_BAUD=$UART_REMAINING_BAUDS
            UART_REMAINING_BAUDS=""
            ;;
    esac
    log_info "---- UART functional case: device=$UART_DEVICE baud=$UART_BAUD bytes=$UART_PAYLOAD_BYTES ----"
    uart_loopback_validate \
        "$UART_DEVICE" \
        "$UART_BAUD" \
        "$UART_LOOPBACK_TIMEOUT" \
        "$RESULT_DIR" \
        "$UART_PAYLOAD_BYTES"
    loopback_status=$?
    case "$loopback_status" in
        0)
            test_result_record "PASS" "UART exact payload transfer passed on $UART_DEVICE at $UART_BAUD baud"
            ;;
        1)
            test_result_record "FAIL" "UART loopback failed on $UART_DEVICE at $UART_BAUD baud, see $RESULT_DIR/uart_loopback_${UART_BAUD}.log"
            ;;
        2)
            test_result_record "SKIP" "UART loopback at $UART_BAUD baud is not runnable on $UART_DEVICE, the preceding UART-LOOPBACK line identifies the console or active owner"
            ;;
        *)
            test_result_record "FAIL" "UART loopback helper returned unexpected status $loopback_status at $UART_BAUD baud"
            ;;
    esac
done

test_result_finish
