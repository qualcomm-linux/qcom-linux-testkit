#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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
. "$TOOLS/lib_system.sh"

TESTNAME="EFI_Variable_Validation"

test_path="$(find_test_case_by_name "$TESTNAME")"
if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    log_fail "$TESTNAME, test directory not found"
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
fi

RES_FILE="./${TESTNAME}.res"
EFI_LIST_LOG="./efi_vars.list"
EFI_WRITE_LOG="./efi_var_write.log"
EFI_TRIAL_BEFORE_PRINT_LOG="./efi_trial_boot_status_before_write.log"
EFI_TRIAL_PRINT_LOG="./efi_trial_boot_status_print.log"
EFI_IND_PRINT_LOG="./efi_os_indications_supported_print.log"
EFI_DATA_FILE="./efi_trial_boot_status.bin"
EFI_REMOUNT_LOG="./efi_efivarfs_remount.log"

rm -f "$RES_FILE" \
      "$EFI_LIST_LOG" \
      "$EFI_WRITE_LOG" \
      "$EFI_TRIAL_BEFORE_PRINT_LOG" \
      "$EFI_TRIAL_PRINT_LOG" \
      "$EFI_IND_PRINT_LOG" \
      "$EFI_DATA_FILE" \
      "$EFI_REMOUNT_LOG"

CONFIGS="
CONFIG_EFI=y
CONFIG_EFI_ESRT=y
CONFIG_EFIVAR_FS=y
"

efi_log_efivarfs_mount_state() {
    log_info "efivarfs mount state:"

    if command -v findmnt >/dev/null 2>&1; then
        findmnt "$EFIVARFS_PATH" 2>/dev/null |
            while IFS= read -r line || [ -n "$line" ]; do
                [ -n "$line" ] || continue
                log_info "[efivarfs-findmnt] $line"
            done
    fi

    mount 2>/dev/null |
        grep -E 'efivarfs|/sys/firmware/efi/efivars' |
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            log_info "[efivarfs-mount] $line"
        done

    efi_mount_opts="$(efi_mount_options 2>/dev/null || true)"
    [ -n "$efi_mount_opts" ] || efi_mount_opts="<unavailable>"
    log_info "efivarfs mount options: $efi_mount_opts"
}

efi_log_variable_file_state() {
    efi_var_file="$EFIVARFS_PATH/$OS_TRIAL_BOOT_STATUS_VAR"

    if [ -e "$efi_var_file" ]; then
        log_info "efivarfs node exists: $efi_var_file"

        if command -v print_path_meta >/dev/null 2>&1; then
            print_path_meta "$efi_var_file" 2>/dev/null |
                while IFS= read -r line || [ -n "$line" ]; do
                    [ -n "$line" ] || continue
                    log_info "[efivarfs-node] $line"
                done
        fi

        if command -v lsattr >/dev/null 2>&1; then
            lsattr "$efi_var_file" 2>/dev/null |
                while IFS= read -r line || [ -n "$line" ]; do
                    [ -n "$line" ] || continue
                    log_info "[efivarfs-attr] $line"
                done
        fi
    else
        log_info "efivarfs node does not exist yet: $efi_var_file"
    fi
}

efi_log_recent_kernel_messages() {
    log_info "Recent EFI/efivar kernel messages:"

    get_kernel_log 2>/dev/null |
        grep -Ei 'efi|efivar|efivars|SetVariable|OsTrialBootStatus|firmware|runtime' |
        tail -80 |
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            log_info "[efi-kernel] $line"
        done
}

efi_log_existing_trial_boot_status() {
    log_info "Checking existing EFI variable state, ${OS_TRIAL_BOOT_STATUS_VAR}"

    if efivar -n "$OS_TRIAL_BOOT_STATUS_VAR" -p > "$EFI_TRIAL_BEFORE_PRINT_LOG" 2>&1; then
        log_info "Existing ${OS_TRIAL_BOOT_STATUS_VAR} is readable before write"
        system_log_file_excerpt "efivar-before-write" "$EFI_TRIAL_BEFORE_PRINT_LOG" 60
    else
        log_warn "${OS_TRIAL_BOOT_STATUS_VAR} is not readable before write or does not exist"
        system_log_file_excerpt "efivar-before-write" "$EFI_TRIAL_BEFORE_PRINT_LOG" 60
    fi

    efi_log_variable_file_state
}

efi_install_restore_trap

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase ----------------------------"
log_info "==== Test Initialization ===="

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies efivar grep sed awk printf mount wc tail; then
    system_write_result_and_exit "SKIP" "$TESTNAME SKIP, missing required dependencies"
fi

log_info "Checking required EFI kernel configs"
if ! check_kernel_config "$CONFIGS"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, required EFI kernel configs are missing"
fi

log_info "Checking EFI runtime directory"
if [ ! -d /sys/firmware/efi ]; then
    system_write_result_and_exit "FAIL" "/sys/firmware/efi is not present"
fi
log_pass "/sys/firmware/efi is present"

log_info "Checking efivarfs directory"
if [ ! -d "$EFIVARFS_PATH" ]; then
    system_write_result_and_exit "FAIL" "$EFIVARFS_PATH is not present"
fi
log_pass "$EFIVARFS_PATH is present"

log_info "Checking ESRT runtime directory"
if [ -d /sys/firmware/efi/esrt ]; then
    log_pass "/sys/firmware/efi/esrt is present"
else
    log_warn "/sys/firmware/efi/esrt is not present, CONFIG_EFI_ESRT is enabled but firmware ESRT table is not exposed"
fi

log_info "Listing EFI variables with efivar -l"
if ! efivar -l > "$EFI_LIST_LOG" 2>&1; then
    system_log_file_excerpt "efivar-list" "$EFI_LIST_LOG" 40

    if efi_error_is_unsupported "$EFI_LIST_LOG"; then
        system_write_result_and_exit "SKIP" "$TESTNAME SKIP, EFI variable runtime service is not implemented by firmware"
    fi

    system_write_result_and_exit "FAIL" "efivar -l failed"
fi

efi_var_count="$(awk 'NF { count++ } END { print count + 0 }' "$EFI_LIST_LOG" 2>/dev/null)"
if ! system_is_uint "$efi_var_count"; then
    efi_var_count=0
fi

if [ "$efi_var_count" -le 0 ]; then
    log_warn "efivar -l returned no EFI variables; continuing with mandatory OsTrialBootStatus validation"
else
    log_pass "efivar -l returned ${efi_var_count} EFI variables"
fi

log_info "Showing first EFI variables, capped at 20 lines"
system_log_file_excerpt "efi-var" "$EFI_LIST_LOG" 20

log_info "Preparing payload for ${OS_TRIAL_BOOT_STATUS_VAR}"
if ! efi_write_trial_boot_status_payload; then
    system_write_result_and_exit "FAIL" "Could not prepare OsTrialBootStatus payload file"
fi

payload_size="$(wc -c < "$EFI_DATA_FILE" 2>/dev/null | awk '{ print $1 + 0 }')"
if [ "$payload_size" -ne 8 ]; then
    system_write_result_and_exit "FAIL" "OsTrialBootStatus payload size is invalid, expected 8 bytes, got ${payload_size}"
fi
log_pass "OsTrialBootStatus payload prepared, size ${payload_size} bytes"

log_info "Checking efivarfs write access"
efi_log_efivarfs_mount_state

if ! efi_mount_is_rw; then
    if ! efi_try_remount_rw; then
        efi_log_efivarfs_mount_state
        system_write_result_and_exit "FAIL" "$TESTNAME FAIL, efivarfs is read-only and could not be remounted read-write"
    fi
fi

efi_log_existing_trial_boot_status

log_info "Writing EFI variable, ${OS_TRIAL_BOOT_STATUS_VAR}"
if ! efivar -n "$OS_TRIAL_BOOT_STATUS_VAR" -f "$EFI_DATA_FILE" -w > "$EFI_WRITE_LOG" 2>&1; then
    system_log_file_excerpt "efivar-write" "$EFI_WRITE_LOG" 80
    efi_log_efivarfs_mount_state
    efi_log_variable_file_state
    efi_log_recent_kernel_messages

    system_write_result_and_exit "FAIL" "Write failed for ${OS_TRIAL_BOOT_STATUS_VAR}"
fi
log_pass "Write succeeded for ${OS_TRIAL_BOOT_STATUS_VAR}"

log_info "Printing EFI variable, ${OS_TRIAL_BOOT_STATUS_VAR}"
if ! efivar -n "$OS_TRIAL_BOOT_STATUS_VAR" -p > "$EFI_TRIAL_PRINT_LOG" 2>&1; then
    system_log_file_excerpt "efivar-trial-print" "$EFI_TRIAL_PRINT_LOG" 80
    efi_log_variable_file_state
    efi_log_recent_kernel_messages
    system_write_result_and_exit "FAIL" "Print failed for ${OS_TRIAL_BOOT_STATUS_VAR}"
fi

system_log_file_excerpt "efivar-trial-print" "$EFI_TRIAL_PRINT_LOG" 80

if ! system_require_grep_in_file "GUID: ${EFI_GLOBAL_GUID}" \
        "$EFI_TRIAL_PRINT_LOG" \
        "OsTrialBootStatus GUID does not match expected value"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsTrialBootStatus GUID validation failed"
fi

if ! system_require_grep_in_file 'Name: "OsTrialBootStatus"' \
        "$EFI_TRIAL_PRINT_LOG" \
        "OsTrialBootStatus name is missing in print output"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsTrialBootStatus name validation failed"
fi

if ! system_require_grep_in_file "Non-Volatile" \
        "$EFI_TRIAL_PRINT_LOG" \
        "OsTrialBootStatus is missing Non-Volatile attribute"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsTrialBootStatus Non-Volatile attribute validation failed"
fi

if ! system_require_grep_in_file "Boot Service Access" \
        "$EFI_TRIAL_PRINT_LOG" \
        "OsTrialBootStatus is missing Boot Service Access attribute"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsTrialBootStatus Boot Service Access attribute validation failed"
fi

if ! system_require_grep_in_file "Runtime Service Access" \
        "$EFI_TRIAL_PRINT_LOG" \
        "OsTrialBootStatus is missing Runtime Service Access attribute"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsTrialBootStatus Runtime Service Access attribute validation failed"
fi

if ! efi_require_trial_boot_status_payload \
        "$EFI_TRIAL_PRINT_LOG" \
        "01 77 01 00 00 00 00 00"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsTrialBootStatus payload validation failed"
fi
log_pass "OsTrialBootStatus attributes and payload match expected values"

if ! efi_variable_list_contains "$OS_INDICATIONS_SUPPORTED_VAR"; then
    log_warn "${OS_INDICATIONS_SUPPORTED_VAR} is not present, skipping optional OsIndicationsSupported validation"
    system_finish_pass "$TESTNAME, EFI kernel config and OsTrialBootStatus write/read validation passed"
fi

log_info "Printing EFI variable, ${OS_INDICATIONS_SUPPORTED_VAR}"
if ! efivar -n "$OS_INDICATIONS_SUPPORTED_VAR" -p > "$EFI_IND_PRINT_LOG" 2>&1; then
    system_log_file_excerpt "efivar-indications-print" "$EFI_IND_PRINT_LOG" 40

    if grep -Eiq 'No such file or directory' "$EFI_IND_PRINT_LOG"; then
        log_warn "${OS_INDICATIONS_SUPPORTED_VAR} is not exposed, skipping optional OsIndicationsSupported validation"
        system_finish_pass "$TESTNAME, EFI kernel config and OsTrialBootStatus write/read validation passed"
    fi

    system_write_result_and_exit "FAIL" "Print failed for ${OS_INDICATIONS_SUPPORTED_VAR}"
fi

system_log_file_excerpt "efivar-indications-print" "$EFI_IND_PRINT_LOG" 40

if ! system_require_grep_in_file "GUID: ${EFI_GLOBAL_GUID}" \
        "$EFI_IND_PRINT_LOG" \
        "OsIndicationsSupported GUID does not match expected value"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsIndicationsSupported GUID validation failed"
fi

if ! system_require_grep_in_file 'Name: "OsIndicationsSupported"' \
        "$EFI_IND_PRINT_LOG" \
        "OsIndicationsSupported name is missing in print output"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsIndicationsSupported name validation failed"
fi

if ! system_require_grep_in_file "Boot Service Access" \
        "$EFI_IND_PRINT_LOG" \
        "OsIndicationsSupported is missing Boot Service Access attribute"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsIndicationsSupported Boot Service Access attribute validation failed"
fi

if ! system_require_grep_in_file "Runtime Service Access" \
        "$EFI_IND_PRINT_LOG" \
        "OsIndicationsSupported is missing Runtime Service Access attribute"; then
    system_write_result_and_exit "FAIL" "$TESTNAME FAIL, OsIndicationsSupported Runtime Service Access attribute validation failed"
fi

if efi_require_os_indications_supported_value "$EFI_IND_PRINT_LOG"; then
    log_pass "OsIndicationsSupported attributes and value match expected values"
else
    log_warn "OsIndicationsSupported value is firmware-specific, continuing without failing"
fi

system_finish_pass "$TESTNAME, EFI kernel config, OsTrialBootStatus write/read validation, and EFI variable attribute checks passed"
