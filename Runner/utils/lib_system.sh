#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Common helpers for System/Yocto userspace validation tests.
#
# This library intentionally keeps framework-level helpers in functestlib.sh
# and provides System-suite specific helpers here. Current users include
# EFI_Variable_Validation.

# ---------------------------------------------------------------------------
# Default EFI constants
# ---------------------------------------------------------------------------

: "${EFI_GLOBAL_GUID:=8be4df61-93ca-11d2-aa0d-00e098032b8c}"
: "${OS_TRIAL_BOOT_STATUS_VAR:=${EFI_GLOBAL_GUID}-OsTrialBootStatus}"
: "${OS_INDICATIONS_SUPPORTED_VAR:=${EFI_GLOBAL_GUID}-OsIndicationsSupported}"
: "${EFIVARFS_PATH:=/sys/firmware/efi/efivars}"
: "${EFIVARFS_RESTORE_RO:=0}"

# ---------------------------------------------------------------------------
# Generic System-suite result helpers
# ---------------------------------------------------------------------------

# Return the active result file path.
# Prefer RES_FILE from the testcase; fallback to TESTNAME.res when available.
system_result_file() {
    if [ -n "${RES_FILE:-}" ]; then
        printf '%s\n' "$RES_FILE"
        return 0
    fi

    if [ -n "${TESTNAME:-}" ]; then
        printf './%s.res\n' "$TESTNAME"
        return 0
    fi

    printf './UnknownTest.res\n'
    return 0
}

# Write the final testcase result and exit cleanly.
# This keeps PASS/FAIL/SKIP exits consistent across System-suite tests.
system_write_result_and_exit() {
    result="$1"
    message="$2"
    result_file="$(system_result_file)"

    case "$result" in
        PASS)
            log_pass "$message"
            ;;
        FAIL)
            log_fail "$message"
            ;;
        SKIP)
            log_skip "$message"
            ;;
        *)
            log_fail "${TESTNAME:-UnknownTest}, invalid result requested: $result"
            result="FAIL"
            ;;
    esac

    echo "${TESTNAME:-UnknownTest} $result" > "$result_file"
    exit 0
}

# Complete the test as PASS with the common completion log.
# Used when mandatory validation passed and only optional platform-specific
# checks are unavailable.
system_finish_pass() {
    message="$1"
    result_file="$(system_result_file)"

    log_pass "$message"
    echo "${TESTNAME:-UnknownTest} PASS" > "$result_file"

    if [ -n "${TESTNAME:-}" ]; then
        log_info "------------------- Completed ${TESTNAME} Testcase ----------------------------"
    fi

    exit 0
}

# ---------------------------------------------------------------------------
# Generic System-suite log helpers
# ---------------------------------------------------------------------------

# Return success when the given value is an unsigned integer.
system_is_uint() {
    case "$1" in
        ""|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Log the first N lines from a file with a stable prefix.
# Usage:
# system_log_file_excerpt "efivar-list" "./efi_vars.list" 40
system_log_file_excerpt() {
    log_prefix="$1"
    log_file="$2"
    log_lines="${3:-40}"

    if ! system_is_uint "$log_lines"; then
        log_lines=40
    fi

    if [ ! -f "$log_file" ]; then
        log_warn "Log file not found for excerpt: $log_file"
        return 1
    fi

    sed -n "1,${log_lines}p" "$log_file" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        log_info "[${log_prefix}] $line"
    done

    return 0
}

# Require a fixed string to be present in a file.
system_require_grep_in_file() {
    pattern="$1"
    file_path="$2"
    fail_msg="$3"

    if grep -Fq "$pattern" "$file_path"; then
        return 0
    fi

    log_fail "$fail_msg"
    return 1
}

# ---------------------------------------------------------------------------
# EFI variable validation helpers
# ---------------------------------------------------------------------------

# Prepare OsTrialBootStatus payload.
# Expected payload:
# 01 77 01 00 00 00 00 00
#
# Caller must define:
# EFI_DATA_FILE
efi_write_trial_boot_status_payload() {
    if [ -z "${EFI_DATA_FILE:-}" ]; then
        log_fail "EFI_DATA_FILE is not set"
        return 1
    fi

    : > "$EFI_DATA_FILE" || return 1
    printf '\001\167\001\000\000\000\000\000' > "$EFI_DATA_FILE" || return 1

    return 0
}

# Require OsTrialBootStatus payload bytes in efivar print output.
efi_require_trial_boot_status_payload() {
    file_path="$1"
    expected_desc="$2"

    if grep -Eq '01[[:space:]]+77[[:space:]]+01[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00' "$file_path"; then
        return 0
    fi

    log_fail "EFI variable payload does not match expected value, required ${expected_desc}"
    return 1
}

# Require OsIndicationsSupported expected value.
# Current expected value:
# 04 00 00 00 00 00 00 00
#
# This helper returns failure but does not write testcase result. Callers can
# decide whether a mismatch is fatal or only a warning.
efi_require_os_indications_supported_value() {
    file_path="$1"

    if grep -Eq '04[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00' "$file_path"; then
        return 0
    fi

    log_fail "OsIndicationsSupported value does not match expected value, required 04 00 00 00 00 00 00 00"
    return 1
}

# Detect efivar command failures that indicate firmware/runtime EFI variable
# services are not implemented or not supported on this platform.
efi_error_is_unsupported() {
    log_file="$1"

    grep -Eiq \
        'Function not implemented|Operation not supported|not supported|Invalid argument' \
        "$log_file"
}

# Detect efivar write failures that indicate the platform exposes EFI variables
# in read-only or write-restricted mode.
efi_error_is_write_restricted() {
    log_file="$1"

    grep -Eiq \
        'Read-only file system|Permission denied|Operation not permitted|write protected' \
        "$log_file"
}

# Check whether efivarfs is currently mounted.
# Prefer partition_mount_exists from functestlib.sh when available, with a
# /proc/mounts fallback.
efi_mount_exists() {
    if command -v partition_mount_exists >/dev/null 2>&1; then
        partition_mount_exists "$EFIVARFS_PATH"
        return $?
    fi

    awk -v p="$EFIVARFS_PATH" '
        $2 == p { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' /proc/mounts 2>/dev/null
}

# efi_ensure_mounted log_file
# Mount efivarfs on an EFI boot when absent, preserving an existing ro/rw
# mount. A mount created for overlay preparation is intentionally left mounted.
# Do not call from read-only setup validation. Return 0 when mounted as
# efivarfs, 2 when EFI runtime is absent, 1 on mount/type/verification failure.
efi_ensure_mounted() {
    eem_log="$1"
    if [ ! -d "$EFIVARFS_PATH" ]; then
        log_warn "EFI runtime directory is unavailable: $EFIVARFS_PATH"
        return 2
    fi
    if ! efi_mount_exists; then
        log_info "Mounting efivarfs at $EFIVARFS_PATH for overlay preparation"
        if ! mount -t efivarfs none "$EFIVARFS_PATH" >"$eem_log" 2>&1; then
            system_log_file_excerpt efivarfs-mount "$eem_log" 40
            log_fail "Could not mount efivarfs, check EFI runtime support and mount permissions"
            return 1
        fi
    fi
    if command -v partition_get_mount_fstype >/dev/null 2>&1; then
        eem_type=$(partition_get_mount_fstype "$EFIVARFS_PATH")
    else
        eem_type=$(awk -v p="$EFIVARFS_PATH" '$2 == p { print $3; exit }' /proc/mounts)
    fi
    if [ "$eem_type" != efivarfs ]; then
        log_fail "Expected efivarfs at $EFIVARFS_PATH, detected ${eem_type:-no mounted filesystem}"
        return 1
    fi
    log_info "EFI runtime filesystem is ready at $EFIVARFS_PATH"
    return 0
}

# Return efivarfs mount options.
# Prefer partition_get_mount_options from functestlib.sh when available.
efi_mount_options() {
    opts=""

    if command -v partition_get_mount_options >/dev/null 2>&1; then
        opts="$(partition_get_mount_options "$EFIVARFS_PATH" 2>/dev/null || true)"
    fi

    if [ -z "$opts" ]; then
        opts="$(
            awk -v p="$EFIVARFS_PATH" '$2 == p { print $4; exit }' /proc/mounts 2>/dev/null
        )"
    fi

    printf '%s\n' "$opts"
}

# Check whether efivarfs is mounted read-write.
efi_mount_is_rw() {
    opts="$(efi_mount_options)"

    printf '%s\n' "$opts" | grep -Eq '(^|,)rw(,|$)'
}

# Restore efivarfs to read-only when this test temporarily remounted it
# read-write. This prevents leaving the target in a different mount state.
efi_restore_efivarfs_ro() {
    if [ "$EFIVARFS_RESTORE_RO" != "1" ]; then
        return 0
    fi

    log_info "Restoring efivarfs mount to read-only"

    if mount -o remount,ro "$EFIVARFS_PATH" >/dev/null 2>&1; then
        log_info "efivarfs restored to read-only"
        EFIVARFS_RESTORE_RO=0
        return 0
    fi

    if mount -t efivarfs -o remount,ro efivarfs "$EFIVARFS_PATH" >/dev/null 2>&1; then
        log_info "efivarfs restored to read-only"
        EFIVARFS_RESTORE_RO=0
        return 0
    fi

    log_warn "Could not restore efivarfs to read-only"
    return 1
}

# Install cleanup trap for efivarfs remount restore.
# Call this from EFI tests before attempting temporary remount,rw.
efi_install_restore_trap() {
    trap efi_restore_efivarfs_ro EXIT HUP INT TERM
}

# Try to temporarily remount efivarfs read-write.
#
# Return 0 only if efivarfs becomes read-write.
# If this function changes efivarfs from ro to rw, it sets EFIVARFS_RESTORE_RO=1
# so efi_restore_efivarfs_ro can restore the original read-only state.
#
# Caller may define:
# EFI_REMOUNT_LOG
efi_try_remount_rw() {
    remount_log="${EFI_REMOUNT_LOG:-./efi_efivarfs_remount.log}"

    : > "$remount_log" 2>/dev/null || true

    if efi_mount_is_rw; then
        log_info "efivarfs is already mounted read-write"
        return 0
    fi

    if ! efi_mount_exists; then
        log_warn "efivarfs is not listed as a mounted filesystem"
        return 1
    fi

    log_warn "efivarfs is mounted read-only, attempting temporary remount as read-write"

    if mount -o remount,rw "$EFIVARFS_PATH" > "$remount_log" 2>&1; then
        if efi_mount_is_rw; then
            EFIVARFS_RESTORE_RO=1
            log_pass "efivarfs remounted read-write"
            return 0
        fi
    fi

    if mount -t efivarfs -o remount,rw efivarfs "$EFIVARFS_PATH" >> "$remount_log" 2>&1; then
        if efi_mount_is_rw; then
            EFIVARFS_RESTORE_RO=1
            log_pass "efivarfs remounted read-write"
            return 0
        fi
    fi

    log_warn "efivarfs remount read-write failed"
    system_log_file_excerpt "efivarfs-remount" "$remount_log" 40
    return 1
}

# Check whether an EFI variable was reported by efivar -l.
#
# Caller must define:
# EFI_LIST_LOG
efi_variable_list_contains() {
    var_name="$1"

    if [ -z "${EFI_LIST_LOG:-}" ]; then
        log_warn "EFI_LIST_LOG is not set"
        return 1
    fi

    grep -Fxq "$var_name" "$EFI_LIST_LOG" 2>/dev/null
}

# Find one EFI variable by its name suffix and print its GUID-qualified name.
# Args:
#   $1 - EFI variable name without the GUID, for example VendorDtbOverlays
#   $2 - file that receives efivar list output
# Diagnostic output is written to stderr so command-substitution callers only
# receive the variable name.
# Return 0 for exactly one match, 2 for absence after a successful query,
# or 1 for command failure, invalid arguments or ambiguous matches.
efi_find_variable_by_name() {
    efvbn_name="$1"
    efvbn_log_file="$2"
    efvbn_matches=""
    efvbn_count=0

    if [ -z "$efvbn_name" ] || [ -z "$efvbn_log_file" ]; then
        printf '%s\n' "efi_find_variable_by_name requires variable name and log file" >&2
        return 1
    fi

    if ! command -v efivar >/dev/null 2>&1; then
        printf '%s\n' "efivar command is unavailable" >&2
        return 1
    fi

    if ! efivar -l > "$efvbn_log_file" 2>&1; then
        printf '%s\n' "efivar could not list EFI variables" >&2
        return 1
    fi

    efvbn_matches="$(awk -v suffix="-$efvbn_name" '
        length($0) > length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix {
            print
        }
    ' "$efvbn_log_file")"
    efvbn_count="$(printf '%s\n' "$efvbn_matches" | awk 'NF { count++ } END { print count + 0 }')"

    if [ "$efvbn_count" -eq 0 ]; then
        printf '%s\n' "EFI variable $efvbn_name is absent" >&2
        return 2
    fi
    if [ "$efvbn_count" -ne 1 ]; then
        printf '%s\n' "Expected one EFI variable named $efvbn_name, found $efvbn_count" >&2
        return 1
    fi

    printf '%s\n' "$efvbn_matches"
    return 0
}

# Compare a bounded EFI read with exact ASCII text or a complete overlay entry.
# Args:
#   $1 - EFI variable name in GUID-Name form
#   $2 - expected text payload, without a trailing newline
#   $3 - file that receives efivar print output
#   $4 - optional exact (default) or csv-token comparison mode
# Return 0 for a match (optional trailing NULs), 2 for a readable different
# payload, or 1 for read/parse failure. Retain raw diagnostics, never write EFI.
# csv-token validates a comma-separated overlay-name list and prints that list
# on both match and mismatch. Exact mode prints no data. Diagnostics use stderr.
efi_text_variable_matches() {
    etvm_var_name="$1"
    etvm_value="$2"
    etvm_log_file="$3"
    etvm_mode="${4:-exact}"
    etvm_data_file=""
    etvm_expected_bytes=""
    etvm_actual_bytes=""

    if [ -z "$etvm_var_name" ] || [ -z "$etvm_value" ] || [ -z "$etvm_log_file" ]; then
        log_warn "efi_text_variable_matches requires variable name, value, and log file" >&2
        return 1
    fi
    case "$etvm_mode" in
        exact)
            ;;
        csv-token)
            case "$etvm_value" in
                *,*)
                    log_warn "Invalid requested EFI overlay name: $etvm_value" >&2
                    return 1
                    ;;
            esac
            if ! printf '%s\n' "$etvm_value" | LC_ALL=C awk '
                NR != 1 || $0 !~ /^[!-~]+$/ { bad=1 }
                END { exit (bad || NR != 1) }
            '; then
                log_warn "Invalid requested EFI overlay name: $etvm_value" >&2
                return 1
            fi
            ;;
        *)
            log_warn "Unsupported EFI comparison mode: $etvm_mode" >&2
            return 1
            ;;
    esac

    if ! command -v efivar >/dev/null 2>&1; then
        log_warn "efivar command is unavailable" >&2
        return 1
    fi

    etvm_log_directory=$(dirname "$etvm_log_file")
    if ! run_with_managed_timeout 15 "$etvm_log_directory" efi-text-read \
        efivar -n "$etvm_var_name" -p > "$etvm_log_file" 2>&1; then
        log_warn "EFI variable read failed, inspect $etvm_log_file" >&2
        return 1
    fi

    etvm_data_file="$(mktemp "${TMPDIR:-/tmp}/efivar_payload.XXXXXX" 2>/dev/null || true)"
    if [ -z "$etvm_data_file" ]; then
        log_warn "Could not create temporary EFI variable payload" >&2
        return 1
    fi

    if ! printf '%s' "$etvm_value" > "$etvm_data_file"; then
        log_warn "Could not write temporary EFI variable payload" >&2
        rm -f "$etvm_data_file"
        return 1
    fi

    etvm_expected_bytes="$(od -An -tx1 -v "$etvm_data_file" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
    rm -f "$etvm_data_file"

    if [ -z "$etvm_expected_bytes" ]; then
        log_warn "Could not derive EFI variable payload bytes" >&2
        return 1
    fi

    etvm_expected_bytes=$(printf '%s' "$etvm_expected_bytes" | tr -d ' ')
    etvm_actual_bytes=$(awk '
        {
            sub(/\r$/, "")
        }
        /^[[:space:]]*Value:[[:space:]]*$/ {
            values++
            next
        }
        values && NF {
            if (length($1) != 8 || $1 !~ /^[[:xdigit:]]+$/) {
                bad=1
                next
            }
            rows++
            for (field=2; field<=NF; field++) {
                if (substr($field, 1, 1) == "|") {
                    break
                }
                if (length($field) != 2 || $field !~ /^[[:xdigit:]]+$/) {
                    bad=1
                    break
                }
                bytes=bytes tolower($field)
            }
        }
        END {
            if (values != 1 || !rows || bytes == "" || bad) {
                exit 1
            }
            print bytes
        }
    ' "$etvm_log_file") || {
        log_warn "EFI variable payload could not be parsed, inspect $etvm_log_file" >&2
        return 1
    }
    if [ "$etvm_mode" = csv-token ]; then
        etvm_list=$(printf '%s\n' "$etvm_actual_bytes" | awk '
            {
                digits="0123456789abcdef"
                for (offset=1; offset<=length($0); offset+=2) {
                    pair=substr($0, offset, 2)
                    if (pair == "00") {
                        padding=1
                        continue
                    }
                    if (padding) {
                        exit 1
                    }
                    byte=(index(digits, substr(pair, 1, 1))-1)*16 + \
                        index(digits, substr(pair, 2, 1))-1
                    if (byte < 33 || byte > 126) {
                        exit 1
                    }
                    character=sprintf("%c", byte)
                    value=value character
                }
                if (value == "" || value ~ /^,|,$|,,/) {
                    exit 1
                }
                print value
            }
        ') || {
            log_warn "Invalid EFI overlay list, inspect $etvm_log_file" >&2
            return 1
        }
        printf '%s\n' "$etvm_list"
        case ",$etvm_list," in
            *,"$etvm_value",*)
                return 0
                ;;
        esac
        return 2
    fi
    case "$etvm_actual_bytes" in
        "$etvm_expected_bytes"*)
            etvm_padding=${etvm_actual_bytes#"$etvm_expected_bytes"}
            while [ "${etvm_padding#00}" != "$etvm_padding" ]; do
                etvm_padding=${etvm_padding#00}
            done
            [ -z "$etvm_padding" ] && return 0
            ;;
    esac
    return 2
}

# Write a text payload to an EFI variable and verify its printed byte value.
# Args:
#   $1 - EFI variable name in GUID-Name form
#   $2 - text payload, written without a trailing newline
#   $3 - write log, with separate .readback log for verification
# The caller is responsible for arranging efi_restore_efivarfs_ro during
# cleanup when efi_try_remount_rw changes the mount state.
efi_write_text_variable() {
    ewtv_var_name="$1"
    ewtv_value="$2"
    ewtv_log_file="$3"
    ewtv_data_file=""

    if [ -z "$ewtv_var_name" ] || [ -z "$ewtv_value" ] || [ -z "$ewtv_log_file" ]; then
        log_warn "efi_write_text_variable requires variable name, value, and log file"
        return 1
    fi

    if ! command -v efivar >/dev/null 2>&1; then
        log_warn "efivar command is unavailable"
        return 1
    fi

    if ! efi_mount_is_rw && ! efi_try_remount_rw; then
        log_warn "efivarfs is not writable"
        return 1
    fi

    ewtv_data_file="$(mktemp "${TMPDIR:-/tmp}/efivar_payload.XXXXXX" 2>/dev/null || true)"
    if [ -z "$ewtv_data_file" ]; then
        log_warn "Could not create temporary EFI variable payload"
        return 1
    fi

    if ! printf '%s' "$ewtv_value" > "$ewtv_data_file"; then
        log_warn "Could not write temporary EFI variable payload"
        rm -f "$ewtv_data_file"
        return 1
    fi

    ewtv_log_directory=$(dirname "$ewtv_log_file")
    if ! run_with_managed_timeout 15 "$ewtv_log_directory" efi-text-write \
        efivar -n "$ewtv_var_name" -w -f "$ewtv_data_file" > "$ewtv_log_file" 2>&1; then
        log_warn "efivar write failed for $ewtv_var_name"
        rm -f "$ewtv_data_file"
        return 1
    fi

    rm -f "$ewtv_data_file"

    if ! efi_text_variable_matches \
        "$ewtv_var_name" \
        "$ewtv_value" \
        "$ewtv_log_file.readback"; then
        log_warn "EFI variable printout does not contain the requested payload"
        return 1
    fi

    sync
    log_info "EFI variable updated and verified: $ewtv_var_name"
    return 0
}

# ---------------------------------------------------------------------------
# Compatibility wrappers for existing EFI_Variable_Validation/run.sh names
# ---------------------------------------------------------------------------
# These wrappers let existing tests move helpers to lib_system.sh with minimal
# run.sh churn. New callers should prefer the prefixed function names above.

write_trial_boot_status_payload() {
    efi_write_trial_boot_status_payload "$@"
}

log_file_excerpt() {
    system_log_file_excerpt "$@"
}

require_grep_in_file() {
    system_require_grep_in_file "$@"
}

require_hex_payload_in_file() {
    efi_require_trial_boot_status_payload "$@"
}

require_os_indications_supported_value() {
    efi_require_os_indications_supported_value "$@"
}
