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

TESTNAME="EFI_Variable_Validation"
test_path="$(find_test_case_by_name "$TESTNAME")" || {
    log_fail "$TESTNAME, test directory not found"
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}

cd "$test_path" || exit 1

RES_FILE="./${TESTNAME}.res"
EFI_LIST_LOG="./efi_vars.list"
EFI_WRITE_LOG="./efi_var_write.log"
EFI_TRIAL_PRINT_LOG="./efi_trial_boot_status_print.log"
EFI_IND_PRINT_LOG="./efi_os_indications_supported_print.log"
EFI_DATA_FILE="./efi_trial_boot_status.bin"

rm -f "$RES_FILE" \
      "$EFI_LIST_LOG" \
      "$EFI_WRITE_LOG" \
      "$EFI_TRIAL_PRINT_LOG" \
      "$EFI_IND_PRINT_LOG" \
      "$EFI_DATA_FILE"

CONFIGS="
CONFIG_EFI=y
CONFIG_EFI_ESRT=y
CONFIG_EFIVAR_FS=y
"

EFI_GLOBAL_GUID="8be4df61-93ca-11d2-aa0d-00e098032b8c"
OS_TRIAL_BOOT_STATUS_VAR="${EFI_GLOBAL_GUID}-OsTrialBootStatus"
OS_INDICATIONS_SUPPORTED_VAR="${EFI_GLOBAL_GUID}-OsIndicationsSupported"

write_trial_boot_status_payload() {
    # 01 77 01 00 00 00 00 00
    : > "$EFI_DATA_FILE" || return 1
    printf '\001\167\001\000\000\000\000\000' > "$EFI_DATA_FILE" || return 1
    return 0
}

log_file_excerpt() {
    log_prefix="$1"
    log_file="$2"
    log_lines="${3:-40}"

    sed -n "1,${log_lines}p" "$log_file" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        log_info "[${log_prefix}] $line"
    done
}

require_grep_in_file() {
    pattern="$1"
    file_path="$2"
    fail_msg="$3"

    if grep -Fq "$pattern" "$file_path"; then
        return 0
    fi

    log_fail "$fail_msg"
    return 1
}

require_hex_payload_in_file() {
    file_path="$1"
    expected_desc="$2"

    if grep -Eq '01[[:space:]]+77[[:space:]]+01[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00' "$file_path"; then
        return 0
    fi

    log_fail "EFI variable payload does not match expected value, required ${expected_desc}"
    return 1
}

require_os_indications_supported_value() {
    file_path="$1"

    if grep -Eq '04[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00' "$file_path"; then
        return 0
    fi

    log_fail "OsIndicationsSupported value does not match expected value, required 04 00 00 00 00 00 00 00"
    return 1
}

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase ----------------------------"
log_info "==== Test Initialization ===="

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies efivar grep sed awk printf; then
    log_skip "$TESTNAME SKIP, missing required dependencies"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

log_info "Checking required EFI kernel configs"
if ! check_kernel_config "$CONFIGS"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

log_info "Checking EFI runtime directory"
if [ ! -d /sys/firmware/efi ]; then
    log_fail "/sys/firmware/efi is not present"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
log_pass "/sys/firmware/efi is present"

log_info "Checking efivarfs directory"
if [ ! -d /sys/firmware/efi/efivars ]; then
    log_fail "/sys/firmware/efi/efivars is not present"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
log_pass "/sys/firmware/efi/efivars is present"

log_info "Checking ESRT runtime directory"
if [ -d /sys/firmware/efi/esrt ]; then
    log_pass "/sys/firmware/efi/esrt is present"
else
    log_warn "/sys/firmware/efi/esrt is not present, CONFIG_EFI_ESRT is enabled but firmware ESRT table is not exposed"
fi

log_info "Listing EFI variables with efivar -l"
if ! efivar -l > "$EFI_LIST_LOG" 2>&1; then
    log_fail "efivar -l failed"
    log_file_excerpt "efivar-list" "$EFI_LIST_LOG" 40
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

efi_var_count="$(grep -c '.' "$EFI_LIST_LOG" 2>/dev/null || echo 0)"
if [ "$efi_var_count" -le 0 ]; then
    log_fail "efivar -l returned no EFI variables"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
log_pass "efivar -l returned ${efi_var_count} EFI variables"

log_info "Showing first EFI variables, capped at 20 lines"
log_file_excerpt "efi-var" "$EFI_LIST_LOG" 20

log_info "Preparing payload for ${OS_TRIAL_BOOT_STATUS_VAR}"
if ! write_trial_boot_status_payload; then
    log_fail "Could not prepare OsTrialBootStatus payload file"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

payload_size="$(wc -c < "$EFI_DATA_FILE" 2>/dev/null || echo 0)"
if [ "$payload_size" -ne 8 ]; then
    log_fail "OsTrialBootStatus payload size is invalid, expected 8 bytes, got ${payload_size}"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
log_pass "OsTrialBootStatus payload prepared, size ${payload_size} bytes"

log_info "Writing EFI variable, ${OS_TRIAL_BOOT_STATUS_VAR}"
if ! efivar -n "$OS_TRIAL_BOOT_STATUS_VAR" -f "$EFI_DATA_FILE" -w > "$EFI_WRITE_LOG" 2>&1; then
    log_fail "Write failed for ${OS_TRIAL_BOOT_STATUS_VAR}"
    log_file_excerpt "efivar-write" "$EFI_WRITE_LOG" 40
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
log_pass "Write succeeded for ${OS_TRIAL_BOOT_STATUS_VAR}"

log_info "Printing EFI variable, ${OS_TRIAL_BOOT_STATUS_VAR}"
if ! efivar -n "$OS_TRIAL_BOOT_STATUS_VAR" -p > "$EFI_TRIAL_PRINT_LOG" 2>&1; then
    log_fail "Print failed for ${OS_TRIAL_BOOT_STATUS_VAR}"
    log_file_excerpt "efivar-trial-print" "$EFI_TRIAL_PRINT_LOG" 40
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

log_file_excerpt "efivar-trial-print" "$EFI_TRIAL_PRINT_LOG" 40

if ! require_grep_in_file "GUID: ${EFI_GLOBAL_GUID}" "$EFI_TRIAL_PRINT_LOG" "OsTrialBootStatus GUID does not match expected value"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
if ! require_grep_in_file 'Name: "OsTrialBootStatus"' "$EFI_TRIAL_PRINT_LOG" "OsTrialBootStatus name is missing in print output"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
if ! require_grep_in_file "Non-Volatile" "$EFI_TRIAL_PRINT_LOG" "OsTrialBootStatus is missing Non-Volatile attribute"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
if ! require_grep_in_file "Boot Service Access" "$EFI_TRIAL_PRINT_LOG" "OsTrialBootStatus is missing Boot Service Access attribute"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
if ! require_grep_in_file "Runtime Service Access" "$EFI_TRIAL_PRINT_LOG" "OsTrialBootStatus is missing Runtime Service Access attribute"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
if ! require_hex_payload_in_file "$EFI_TRIAL_PRINT_LOG" "01 77 01 00 00 00 00 00"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
log_pass "OsTrialBootStatus attributes and payload match expected values"

log_info "Printing EFI variable, ${OS_INDICATIONS_SUPPORTED_VAR}"
if ! efivar -n "$OS_INDICATIONS_SUPPORTED_VAR" -p > "$EFI_IND_PRINT_LOG" 2>&1; then
    log_fail "Print failed for ${OS_INDICATIONS_SUPPORTED_VAR}"
    log_file_excerpt "efivar-indications-print" "$EFI_IND_PRINT_LOG" 40
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

log_file_excerpt "efivar-indications-print" "$EFI_IND_PRINT_LOG" 40

if ! require_grep_in_file "GUID: ${EFI_GLOBAL_GUID}" "$EFI_IND_PRINT_LOG" "OsIndicationsSupported GUID does not match expected value"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
if ! require_grep_in_file 'Name: "OsIndicationsSupported"' "$EFI_IND_PRINT_LOG" "OsIndicationsSupported name is missing in print output"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
if ! require_grep_in_file "Boot Service Access" "$EFI_IND_PRINT_LOG" "OsIndicationsSupported is missing Boot Service Access attribute"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
if ! require_grep_in_file "Runtime Service Access" "$EFI_IND_PRINT_LOG" "OsIndicationsSupported is missing Runtime Service Access attribute"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
if ! require_os_indications_supported_value "$EFI_IND_PRINT_LOG"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
log_pass "OsIndicationsSupported attributes and value match expected values"

log_pass "$TESTNAME, EFI kernel config, write read validation, and EFI variable attribute checks passed"
echo "$TESTNAME PASS" > "$RES_FILE"
log_info "------------------- Completed ${TESTNAME} Testcase ----------------------------"
exit 0
