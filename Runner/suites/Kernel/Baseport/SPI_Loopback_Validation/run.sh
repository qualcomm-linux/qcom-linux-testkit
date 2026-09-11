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
TESTNAME="SPI_Loopback_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

RESULT_DIR="$SCRIPT_DIR/.${TESTNAME}.work.$$"
SPI_DEVICE="${SPI_DEVICE:-}"
SPI_SPEED_HZ="${SPI_SPEED_HZ:-1000000}"
SPI_BITS_PER_WORD="${SPI_BITS_PER_WORD:-8}"
SPI_MODES="${SPI_MODES:-${SPI_MODE:-0,1,2,3}}"
SPI_LOOPBACK_TYPE="${SPI_LOOPBACK_TYPE:-auto}"
SPI_LOOPBACK_PAYLOAD="${SPI_LOOPBACK_PAYLOAD:-QLI_SPI_LOOPBACK}"
SPI_LOOPBACK_TIMEOUT="${SPI_LOOPBACK_TIMEOUT:-10}"
SPI_LOOPBACK_FIXTURE="${SPI_LOOPBACK_FIXTURE:-0}"

cleanup() {
    rm -rf "$RESULT_DIR"
}

usage() {
    cat <<EOF
Usage: $0 [options]
  --device PATH       Override auto-detection with a spidev node
  --speed HZ          Transfer speed, default: $SPI_SPEED_HZ
  --bits COUNT        Bits per word, default: $SPI_BITS_PER_WORD
  --modes LIST        Comma-separated SPI modes, default: $SPI_MODES
  --loopback TYPE     auto, internal, or external, default: $SPI_LOOPBACK_TYPE
  --payload TEXT      Short ASCII payload, default: $SPI_LOOPBACK_PAYLOAD
  --timeout SECONDS   Transfer timeout, default: $SPI_LOOPBACK_TIMEOUT
  --fixture            Confirm that an external MOSI-to-MISO loopback fixture is connected
  -h, --help          Show this help
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --device)
                [ "$#" -ge 2 ] || return 2
                SPI_DEVICE="$2"
                shift 2
                ;;
            --speed)
                [ "$#" -ge 2 ] || return 2
                SPI_SPEED_HZ="$2"
                shift 2
                ;;
            --bits)
                [ "$#" -ge 2 ] || return 2
                SPI_BITS_PER_WORD="$2"
                shift 2
                ;;
            --modes)
                [ "$#" -ge 2 ] || return 2
                SPI_MODES="$2"
                shift 2
                ;;
            --loopback)
                [ "$#" -ge 2 ] || return 2
                SPI_LOOPBACK_TYPE="$2"
                shift 2
                ;;
            --payload)
                [ "$#" -ge 2 ] || return 2
                SPI_LOOPBACK_PAYLOAD="$2"
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                SPI_LOOPBACK_TIMEOUT="$2"
                shift 2
                ;;
            --fixture)
                SPI_LOOPBACK_FIXTURE=1
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
    for numeric_value in "$SPI_SPEED_HZ" "$SPI_BITS_PER_WORD" "$SPI_LOOPBACK_TIMEOUT"; do
        case "$numeric_value" in
            ''|*[!0-9]*|0)
                log_error "SPI speed, bits per word, and timeout must be positive integers"
                return 2
                ;;
        esac
    done
    if [ -z "$SPI_LOOPBACK_PAYLOAD" ]; then
        log_error "SPI loopback payload must not be empty"
        return 2
    fi
    case "$SPI_MODES" in
        ''|,*|*,|*,,*)
            log_error "SPI mode list is empty or contains an empty element: $SPI_MODES"
            return 2
            ;;
    esac
    validate_spi_remaining_modes=$SPI_MODES
    while [ -n "$validate_spi_remaining_modes" ]; do
        case "$validate_spi_remaining_modes" in
            *,*)
                validate_spi_mode=${validate_spi_remaining_modes%%,*}
                validate_spi_remaining_modes=${validate_spi_remaining_modes#*,}
                ;;
            *)
                validate_spi_mode=$validate_spi_remaining_modes
                validate_spi_remaining_modes=""
                ;;
        esac
        case "$validate_spi_mode" in
            0|1|2|3)
                ;;
            *)
                log_error "Unsupported SPI mode: $validate_spi_mode"
                return 2
                ;;
        esac
    done
    case "$SPI_LOOPBACK_TYPE" in
        auto|internal|external)
            ;;
        *)
            log_error "Unsupported SPI loopback type: $SPI_LOOPBACK_TYPE"
            return 2
            ;;
    esac
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
if ! bus_validation_require_commands basename cat cmp dirname grep mkdir od readlink rm tr wc; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required image-provided SPI loopback utilities are unavailable"
fi

SPI_SELECTION_SOURCE=override
if [ -z "$SPI_DEVICE" ]; then
    SPI_SELECTION_SOURCE=auto
    SPI_DEVICE=$(spi_loopback_select_device 2>/dev/null)
    SPI_SELECTION_STATUS=$?
    if [ "$SPI_SELECTION_STATUS" -eq 1 ]; then
        test_result_finish "SKIP" "$TESTNAME SKIP: multiple accessible spidev nodes were detected, select one with --device or SPI_DEVICE"
    fi
fi
if [ -z "$SPI_DEVICE" ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no accessible image-provided spidev node was detected"
fi
if [ "$SPI_LOOPBACK_TYPE" = "auto" ]; then
    SPI_LOOPBACK_TYPE=$(spi_loopback_select_type "$SPI_DEVICE")
    SPI_LOOPBACK_SELECTION_STATUS=$?
    if [ "$SPI_LOOPBACK_SELECTION_STATUS" -ne 0 ] || [ -z "$SPI_LOOPBACK_TYPE" ]; then
        test_result_finish "SKIP" "$TESTNAME SKIP: the loopback type is not observable at runtime, select --loopback internal or --loopback external"
    fi
fi
case "$SPI_LOOPBACK_TYPE" in
    internal|external)
        ;;
    *)
        test_result_finish "FAIL" "$TESTNAME FAIL: unsupported loopback type $SPI_LOOPBACK_TYPE"
        ;;
esac
if [ "$SPI_LOOPBACK_TYPE" = "external" ] && ! bus_validation_bool_true "$SPI_LOOPBACK_FIXTURE"; then
    test_result_finish "SKIP" "$TESTNAME SKIP: external SPI loopback fixture was not explicitly enabled, use --fixture or SPI_LOOPBACK_FIXTURE=1"
fi
log_info "Configuration: device=$SPI_DEVICE selection=$SPI_SELECTION_SOURCE speed_hz=$SPI_SPEED_HZ bits=$SPI_BITS_PER_WORD modes=$SPI_MODES loopback=$SPI_LOOPBACK_TYPE timeout=${SPI_LOOPBACK_TIMEOUT}s"

log_info "SPI loopback: validating exact transfers across the requested CPOL and CPHA mode matrix"
SPI_REMAINING_MODES=$SPI_MODES
while [ -n "$SPI_REMAINING_MODES" ]; do
    case "$SPI_REMAINING_MODES" in
        *,*)
            SPI_MODE=${SPI_REMAINING_MODES%%,*}
            SPI_REMAINING_MODES=${SPI_REMAINING_MODES#*,}
            ;;
        *)
            SPI_MODE=$SPI_REMAINING_MODES
            SPI_REMAINING_MODES=""
            ;;
    esac
    log_info "---- SPI functional case: device=$SPI_DEVICE mode=$SPI_MODE loopback=$SPI_LOOPBACK_TYPE ----"
    spi_loopback_validate \
        "$SPI_DEVICE" \
        "$SPI_SPEED_HZ" \
        "$SPI_BITS_PER_WORD" \
        "$SPI_LOOPBACK_PAYLOAD" \
        "$SPI_LOOPBACK_TIMEOUT" \
        "$RESULT_DIR" \
        "$SPI_MODE" \
        "$SPI_LOOPBACK_TYPE"
    loopback_status=$?
    case "$loopback_status" in
        0)
            test_result_record "PASS" "SPI exact transfer passed on $SPI_DEVICE in mode $SPI_MODE with $SPI_LOOPBACK_TYPE loopback"
            ;;
        1)
            test_result_record "FAIL" "SPI loopback failed on $SPI_DEVICE in mode $SPI_MODE, see $RESULT_DIR/spi_loopback_mode${SPI_MODE}_${SPI_LOOPBACK_TYPE}.log"
            ;;
        2)
            test_result_finish "SKIP" "$TESTNAME SKIP: spidev_test is not provided by the image"
            ;;
        *)
            test_result_record "FAIL" "SPI loopback helper returned unexpected status $loopback_status in mode $SPI_MODE"
            ;;
    esac
done

test_result_finish
