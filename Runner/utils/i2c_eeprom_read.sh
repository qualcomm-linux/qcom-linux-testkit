#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Read-only EEPROM helper for ramdisks, invoked with a bounded suite timeout.
# The caller owns stdout capture. Do not start a second asynchronous tee that
# could drop the machine-readable result marker while exiting.
# shellcheck disable=SC2034 # Consumed by init_env.
RUN_STDOUT_ENABLE=0
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

# parse_args <arguments...>
# Parses the internal read-only helper interface, returns 1 for invalid input.
parse_args() {
    read_mode=""
    read_device=auto
    read_offset=""
    read_length=""
    read_report=""
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || return 1
        case "$1" in
            --mode)
                read_mode="$2"
                ;;
            --device)
                read_device="$2"
                ;;
            --offset)
                read_offset="$2"
                ;;
            --length)
                read_length="$2"
                ;;
            --report)
                read_report="$2"
                ;;
            *)
                return 1
                ;;
        esac
        shift 2
    done
    case "$read_mode" in
        discover|probe|matrix|pm)
            ;;
        *)
            return 1
            ;;
    esac
    [ -n "$read_report" ]
}

parse_args "$@" || exit 3
read_dir=${read_report%/*}
mkdir -p "$read_dir" || exit 1
: >"$read_report" || exit 1

if ! bus_validation_require_commands stat awk grep readlink cat mktemp; then
    printf 'I2C_EEPROM_RESULT status=SKIP reason=missing-image-provided-discovery-tools\n'
    exit 2
fi
if [ "$read_mode" != discover ]; then
    if ! bus_validation_require_commands dd cmp sha256sum wc tr sleep; then
        printf 'I2C_EEPROM_RESULT status=SKIP reason=missing-image-provided-read-tools\n'
        exit 2
    fi
    if ! dd if=/dev/null of=/dev/null count=0 iflag=fullblock 2>/dev/null; then
        printf 'I2C_EEPROM_RESULT status=SKIP reason=dd-fullblock-support-required\n'
        exit 2
    fi
fi
read_dir=$(mktemp -d "$read_dir/eeprom-read.XXXXXX") || exit 1
log_info "[I2C-EEPROM] retained read-only artifacts=$read_dir"

i2c_eeprom_select "$read_device" "$read_dir"
read_status=$?
if [ "$read_status" -ne 0 ]; then
    if [ "$read_status" -eq 2 ]; then
        printf 'I2C_EEPROM_RESULT status=SKIP reason=EEPROM-selection-unavailable\n'
    fi
    exit "$read_status"
fi

if [ -z "$read_offset" ] && [ -z "$read_length" ]; then
    read_offset=0
    read_length=$I2C_EEPROM_SIZE
    if [ "$read_mode" = matrix ] || [ "$read_mode" = pm ]; then
        [ "$read_length" -le 4096 ] || read_length=4096
    fi
else
    [ -n "$read_offset" ] && [ -n "$read_length" ] || exit 3
fi
read_offset=$(i2c_tools_value_decimal "$read_offset") || exit 3
read_length=$(i2c_tools_value_decimal "$read_length") || exit 3
if [ "$read_offset" -lt 0 ] || [ "$read_length" -le 0 ] ||
   [ "$read_offset" -gt "$I2C_EEPROM_SIZE" ] ||
   [ "$read_length" -gt "$((I2C_EEPROM_SIZE - read_offset))" ]; then
    log_error "EEPROM range is invalid: offset=$read_offset length=$read_length size=$I2C_EEPROM_SIZE"
    exit 3
fi
if [ "$read_mode" != discover ] && [ "$read_length" -gt 1048576 ]; then
    log_warn "Read-only shell validation is capped at 1 MiB, provide --eeprom-offset and --eeprom-length"
    printf 'I2C_EEPROM_RESULT status=SKIP reason=bounded-read-range-required\n'
    exit 2
fi

read_client_id=${I2C_EEPROM_CLIENT##*/}
printf 'key\tvalue\ndevice\t%s\nadapter\t%s\nsize_bytes\t%s\noffset\t%s\nlength\t%s\n' \
    "$I2C_EEPROM_SELECTED" "${read_client_id%%-*}" "$I2C_EEPROM_SIZE" \
    "$read_offset" "$read_length" >"$read_report" || exit 1

case "$read_mode" in
    discover)
        read_status=0
        ;;
    probe)
        i2c_eeprom_read_exact "$I2C_EEPROM_SELECTED" "$read_offset" "$read_length" "$read_dir/eeprom-read.bin" "$read_dir"
        read_status=$?
        if [ "$read_status" -eq 0 ]; then
            read_digest=$(sha256sum "$read_dir/eeprom-read.bin") || exit 1
            printf 'original_sha256\t%s\n' "${read_digest%% *}" >>"$read_report"
            log_info "[I2C-EEPROM-READ] bytes=$read_length sha256=${read_digest%% *} artifact=$read_dir/eeprom-read.bin"
        fi
        ;;
    matrix)
        i2c_eeprom_read_matrix "$I2C_EEPROM_SELECTED" "$read_offset" "$read_length" "$read_dir"
        read_status=$?
        ;;
    pm)
        : >"$read_dir/i2c_runtime_pm.tsv" || exit 1
        i2c_eeprom_read_after_idle "$I2C_EEPROM_SELECTED" "$I2C_EEPROM_CLIENT" "$read_offset" "$read_length" "$read_dir"
        read_status=$?
        ;;
esac

case "$read_status" in
    0)
        read_result=PASS
        ;;
    2)
        read_result=SKIP
        ;;
    *)
        read_result=FAIL
        ;;
esac
printf 'status\t%s\nmode\t%s\n' "$read_result" "$read_mode" >>"$read_report" || exit 1
printf 'I2C_EEPROM_RESULT status=%s reason=read-only-%s device=%s length=%s report=%s\n' \
    "$read_result" "$read_mode" "$I2C_EEPROM_SELECTED" "$read_length" "$read_report"
exit "$read_status"
