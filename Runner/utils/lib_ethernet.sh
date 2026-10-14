#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Shared helpers for Ethernet functional validation.

QPS615_OVERLAY_NAME="VendorDtbOverlays"
QPS615_OVERLAY_VALUE="staging"
# QPS615 bring-up firmware namespace, used only for explicit first-time setup.
QPS615_OVERLAY_DEFAULT_GUID="882f8c2b-9646-435f-8de5-f208ff80c1bd"

# ethv_failure_diagnostics_init <artifact-directory>
#   Opt this process into Ethernet failure evidence without creating files.
#   stdout: none. return: 0. Side effects: resets private diagnostic state.
ethv_failure_diagnostics_init() {
    ETHV_FAILURE_DIR="$1"
    ETHV_FAILURE_INTERFACES=""
}

# ethv_failure_diagnostics_watch <interface>...
#   Register selected runtime interfaces, not unrelated management interfaces.
#   stdout: none. return: 0. Side effects: accumulates safe netdev names.
ethv_failure_diagnostics_watch() {
    for ethv_fdw_iface in "$@"; do
        case "$ethv_fdw_iface" in
            ""|.|..|-*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-]*)
                continue
                ;;
        esac
        case " ${ETHV_FAILURE_INTERFACES:-} " in
            *" $ethv_fdw_iface "*)
                ;;
            *)
                ETHV_FAILURE_INTERFACES="${ETHV_FAILURE_INTERFACES:+$ETHV_FAILURE_INTERFACES }$ethv_fdw_iface"
                ;;
        esac
    done
}

# ethv_failure_diagnostics [reason]
#   Save read-only ethtool failure evidence once per watched interface and print
#   bounded excerpts. Three-second query deadlines, a 60-second cumulative
#   command-time budget per suite, and no further queries after a device timeout.
#   stdout: diagnostic output. return: always 0, never changes a test verdict.
#   Side effects: retained per-query logs and status.tsv under ETHV_FAILURE_DIR.
#   Subshell isolation preserves caller variables, umask and cleanup traps.
ethv_failure_diagnostics() (
    [ -n "${ETHV_FAILURE_DIR:-}" ] || exit 0
    umask 077
    if ! mkdir -p "$ETHV_FAILURE_DIR"; then
        log_warn "[ETH-DIAG] Cannot create $ETHV_FAILURE_DIR, original failure is unchanged"
        exit 0
    fi
    if [ ! -f "$ETHV_FAILURE_DIR/context.log" ]; then
        printf 'reason=%s\ninterfaces=%s\n' "${1:-Ethernet test failure}" \
            "${ETHV_FAILURE_INTERFACES:-none selected}" >"$ETHV_FAILURE_DIR/context.log"
        log_info "[ETH-DIAG] Failure evidence: $ETHV_FAILURE_DIR"
        log_file_with_label ETH-DIAG "$ETHV_FAILURE_DIR/context.log" 10
    fi
    if [ -z "${ETHV_FAILURE_INTERFACES:-}" ]; then
        if [ ! -f "$ETHV_FAILURE_DIR/no-interface.log" ]; then
            printf '%s\n' 'No tested interface was selected before failure, no ethtool queries were run.' \
                >"$ETHV_FAILURE_DIR/no-interface.log"
            log_file_with_label ETH-DIAG "$ETHV_FAILURE_DIR/no-interface.log" 10
        fi
        exit 0
    fi
    if ! command -v ethtool >/dev/null 2>&1; then
        if [ ! -f "$ETHV_FAILURE_DIR/unavailable.log" ]; then
            printf '%s\n' 'ethtool is not image-provided, provision it in the image for Ethernet failure diagnostics.' \
                >"$ETHV_FAILURE_DIR/unavailable.log"
            log_file_with_label ETH-DIAG "$ETHV_FAILURE_DIR/unavailable.log" 10
        fi
        exit 0
    fi

    ethv_fd_spent=0
    if [ -r "$ETHV_FAILURE_DIR/command-seconds" ]; then
        read -r ethv_fd_spent <"$ETHV_FAILURE_DIR/command-seconds"
    fi
    case "$ethv_fd_spent" in
        ''|*[!0-9]*)
            log_warn "[ETH-DIAG] Invalid diagnostic budget state, no additional queries will run"
            exit 0
            ;;
    esac
    for ethv_fd_iface in $ETHV_FAILURE_INTERFACES; do
        ethv_fd_dir="$ETHV_FAILURE_DIR/$ethv_fd_iface"
        [ ! -f "$ethv_fd_dir/complete" ] || continue
        if ! mkdir -p "$ethv_fd_dir"; then
            log_warn "[ETH-DIAG] Cannot create interface evidence directory $ethv_fd_dir"
            continue
        fi
        printf 'query\tstatus\texit_status\tartifact\n' >"$ethv_fd_dir/status.tsv"
        ethv_fd_stopped=0
        for ethv_fd_query in link driver statistics phy-statistics features rings channels coalesce pause timestamping eee fec private-flags; do
            case "$ethv_fd_query" in
                link)
                    set -- ethtool "$ethv_fd_iface"
                    ;;
                driver)
                    set -- ethtool -i "$ethv_fd_iface"
                    ;;
                statistics)
                    set -- ethtool -S "$ethv_fd_iface"
                    ;;
                phy-statistics)
                    set -- ethtool --phy-statistics "$ethv_fd_iface"
                    ;;
                features)
                    set -- ethtool -k "$ethv_fd_iface"
                    ;;
                rings)
                    set -- ethtool -g "$ethv_fd_iface"
                    ;;
                channels)
                    set -- ethtool -l "$ethv_fd_iface"
                    ;;
                coalesce)
                    set -- ethtool -c "$ethv_fd_iface"
                    ;;
                pause)
                    set -- ethtool -a "$ethv_fd_iface"
                    ;;
                timestamping)
                    set -- ethtool -T "$ethv_fd_iface"
                    ;;
                eee)
                    set -- ethtool --show-eee "$ethv_fd_iface"
                    ;;
                fec)
                    set -- ethtool --show-fec "$ethv_fd_iface"
                    ;;
                private-flags)
                    set -- ethtool --show-priv-flags "$ethv_fd_iface"
                    ;;
            esac
            ethv_fd_log="$ethv_fd_dir/$ethv_fd_query.log"
            if [ "$ethv_fd_stopped" -eq 1 ] || [ "$ethv_fd_spent" -ge 60 ]; then
                printf '%s\n' 'Not queried because the device timed out or the suite diagnostic command-time budget was exhausted.' >"$ethv_fd_log"
                printf '%s\tskipped\t-\t%s\n' "$ethv_fd_query" "$ethv_fd_log" >>"$ethv_fd_dir/status.tsv"
                continue
            fi
            ethv_fd_start=$(date +%s) || break
            ethv_fd_rc=0
            ethv_fd_output=$(LC_ALL=C run_with_managed_timeout 3 "$ethv_fd_dir" ethtool-diagnostic "$@" 2>&1) || ethv_fd_rc=$?
            ethv_fd_end=$(date +%s) || ethv_fd_end=$((ethv_fd_start + 5))
            ethv_fd_elapsed=$((ethv_fd_end - ethv_fd_start))
            [ "$ethv_fd_elapsed" -ge 0 ] || ethv_fd_elapsed=5
            ethv_fd_spent=$((ethv_fd_spent + ethv_fd_elapsed))
            printf '%s\n' "$ethv_fd_spent" >"$ETHV_FAILURE_DIR/command-seconds"
            # Never persist or print the SecureOn password returned by a base
            # ethtool query. Raw output is held only in this subshell variable.
            if ! printf '%s\n' "$ethv_fd_output" | sed \
                -e 's/[Ss]ecure[Oo]n password:.*/SecureOn password: [redacted]/' \
                -e 's/sopass .*/sopass [redacted]/' >"$ethv_fd_log"; then
                log_warn "[ETH-DIAG] Could not save redacted $ethv_fd_query output for $ethv_fd_iface"
                continue
            fi
            ethv_fd_status=collected
            if [ "$ethv_fd_rc" -eq 124 ]; then
                ethv_fd_status=timeout
                ethv_fd_stopped=1
            elif [ "$ethv_fd_rc" -ne 0 ]; then
                ethv_fd_status=unavailable-or-error
            fi
            printf '%s\t%s\t%s\t%s\n' "$ethv_fd_query" "$ethv_fd_status" "$ethv_fd_rc" "$ethv_fd_log" >>"$ethv_fd_dir/status.tsv"
            log_info "[ETH-DIAG] interface=$ethv_fd_iface query=$ethv_fd_query command=$* status=$ethv_fd_status rc=$ethv_fd_rc artifact=$ethv_fd_log"
            log_file_with_label "ETH-DIAG-$ethv_fd_iface-$ethv_fd_query" "$ethv_fd_log" 80
        done
        log_file_with_label "ETH-DIAG-$ethv_fd_iface-SUMMARY" "$ethv_fd_dir/status.tsv" 20
        : >"$ethv_fd_dir/complete"
    done
    exit 0
)

# ethv_sanitize_text <text>
#   Normalize text for a single-line, pipe-delimited result record.
#   stdout: sanitized text with repeated whitespace collapsed.
#   return: 0 on successful filtering, nonzero if a filter command fails.
ethv_sanitize_text() {
    printf '%s' "${1:-}" \
        | tr '\n\r\t|' '    ' \
        | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

# ethv_record_result <result-file> <check-name> <PASS|FAIL|SKIP> [details]
#   Append one result record and emit the matching functest log message.
#   stdout: logging output from log_pass, log_fail, or log_skip.
#   return: 1 when result-file is empty, otherwise the logging helper status.
ethv_record_result() {
    ethv_rr_file="${1:-}"
    ethv_rr_check="$(ethv_sanitize_text "${2:-unknown}")"
    ethv_rr_result="${3:-SKIP}"
    ethv_rr_details="$(ethv_sanitize_text "${4:-}")"

    [ -n "$ethv_rr_file" ] || return 1

    case "$ethv_rr_result" in
        PASS|FAIL|SKIP)
            ;;
        *)
            ethv_rr_result="FAIL"
            ;;
    esac

    printf '%s|%s|%s\n' \
        "$ethv_rr_check" \
        "$ethv_rr_result" \
        "$ethv_rr_details" >>"$ethv_rr_file"

    case "$ethv_rr_result" in
        PASS)
            log_pass "$ethv_rr_check: $ethv_rr_details"
            ;;
        FAIL)
            log_fail "$ethv_rr_check: $ethv_rr_details"
            ethv_rr_log_status=$?
            ethv_failure_diagnostics "$ethv_rr_check: $ethv_rr_details"
            return "$ethv_rr_log_status"
            ;;
        SKIP)
            log_skip "$ethv_rr_check: $ethv_rr_details"
            ;;
    esac
}

# ethv_result_count <result-file> <PASS|FAIL|SKIP>
#   Count records whose second pipe-delimited field matches the requested state.
#   stdout: unsigned decimal count, including zero.
#   return: awk status, nonzero when the result file cannot be processed.
ethv_result_count() {
    ethv_rc_file="${1:-}"
    ethv_rc_status="${2:-}"

    awk -F '|' -v wanted="$ethv_rc_status" '
        $2 == wanted {
            count++
        }
        END {
            print count + 0
        }
    ' "$ethv_rc_file" 2>/dev/null
}

# ethv_print_summary <result-file> [title]
#   Print a formatted table and PASS, FAIL, and SKIP totals for a result file.
#   stdout: summary title, table, and totals.
#   return: status of the final printf operation.
ethv_print_summary() {
    ethv_ps_file="${1:-}"
    ethv_ps_title="${2:-Ethernet Validation Summary}"
    ethv_ps_passed="$(ethv_result_count "$ethv_ps_file" PASS)"
    ethv_ps_failed="$(ethv_result_count "$ethv_ps_file" FAIL)"
    ethv_ps_skipped="$(ethv_result_count "$ethv_ps_file" SKIP)"

    log_info "$ethv_ps_title"
    printf '%s\n' "----------------------------------------------------------------------------------------------------"
    printf '%-38s %-7s %s\n' "Check" "Result" "Details"
    printf '%s\n' "----------------------------------------------------------------------------------------------------"

    while IFS='|' read -r ethv_ps_check ethv_ps_result ethv_ps_details; do
        [ -n "$ethv_ps_check" ] || continue
        printf '%-38s %-7s %s\n' \
            "$ethv_ps_check" \
            "$ethv_ps_result" \
            "$ethv_ps_details"
    done <"$ethv_ps_file"

    printf '%s\n' "----------------------------------------------------------------------------------------------------"
    printf 'Passed: %s  Failed: %s  Skipped: %s\n' \
        "$ethv_ps_passed" \
        "$ethv_ps_failed" \
        "$ethv_ps_skipped"
}

# ethv_compute_overall_result <result-file>
#   Resolve the aggregate state, prioritizing FAIL, then PASS, then SKIP.
#   stdout: exactly one of PASS, FAIL, or SKIP.
#   return: 0 after printing the aggregate state.
ethv_compute_overall_result() {
    ethv_cor_file="${1:-}"
    ethv_cor_passed="$(ethv_result_count "$ethv_cor_file" PASS)"
    ethv_cor_failed="$(ethv_result_count "$ethv_cor_file" FAIL)"

    if [ "$ethv_cor_failed" -gt 0 ]; then
        printf '%s\n' "FAIL"
    elif [ "$ethv_cor_passed" -gt 0 ]; then
        printf '%s\n' "PASS"
    else
        printf '%s\n' "SKIP"
    fi
}

# ethv_is_uint <value>
#   Test whether value contains one or more decimal digits and no sign.
#   stdout: none.
#   return: 0 for an unsigned integer, 1 otherwise.
ethv_is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ethv_is_positive_integer <value>
#   Test whether value is an unsigned decimal integer greater than zero.
#   stdout: none.
#   return: 0 for a positive integer, 1 otherwise.
ethv_is_positive_integer() {
    ethv_ipi_value="${1:-}"

    ethv_is_uint "$ethv_ipi_value" || return 1
    [ "$ethv_ipi_value" -gt 0 ]
}

# ethv_is_nonnegative_decimal <value>
#   Accept an unsigned integer or decimal with digits on both sides of the dot.
#   stdout: none.
#   return: 0 for a valid nonnegative decimal, 1 otherwise.
ethv_is_nonnegative_decimal() {
    ethv_ind_value="${1:-}"

    case "$ethv_ind_value" in
        ''|*[!0-9.]*|.*|*.|*.*.*)
            return 1
            ;;
        *.*)
            ethv_ind_whole="${ethv_ind_value%%.*}"
            ethv_ind_fraction="${ethv_ind_value#*.}"
            [ -n "$ethv_ind_whole" ] || return 1
            [ -n "$ethv_ind_fraction" ] || return 1
            ;;
    esac

    return 0
}

# ethv_is_boolean <value>
#   Validate the numeric boolean representation used by suite parameters.
#   stdout: none.
#   return: 0 for 0 or 1, 1 otherwise.
ethv_is_boolean() {
    case "${1:-}" in
        0|1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ethv_require_option_value <option-name> <remaining-argument-count>
#   Check that a CLI option has at least one following argument available.
#   stderr: an error identifying the option when its value is missing.
#   return: 0 when a value can follow, 1 when fewer than two arguments remain.
ethv_require_option_value() {
    ethv_rov_option="${1:-option}"
    ethv_rov_count="${2:-0}"

    if [ "$ethv_rov_count" -ge 2 ]; then
        return 0
    fi

    printf '[ERROR] %s requires a value\n' "$ethv_rov_option" >&2
    return 1
}

# ethv_read_first_line <file>
#   Read the first line from a readable sysfs, procfs, or regular file.
#   stdout: first line, followed by a newline.
#   return: 0 when the file is readable, 1 when it is not readable.
ethv_read_first_line() {
    ethv_rfl_file="${1:-}"

    [ -r "$ethv_rfl_file" ] || return 1
    IFS= read -r ethv_rfl_value <"$ethv_rfl_file" || true
    printf '%s\n' "$ethv_rfl_value"
}

# ethv_get_interfaces
#   Discover non-loopback, non-wireless Ethernet interfaces using the shared
#   repository helper first and a sysfs fallback when needed.
#   stdout: one unique interface name per line.
#   return: pipeline status, normally 0 even when no interface is found.
ethv_get_interfaces() {
    ethv_gi_interfaces=""

    if command -v get_ethernet_interfaces >/dev/null 2>&1; then
        ethv_gi_interfaces="$(get_ethernet_interfaces 2>/dev/null || true)"
    fi

    if [ -z "$ethv_gi_interfaces" ]; then
        for ethv_gi_path in /sys/class/net/*; do
            [ -e "$ethv_gi_path" ] || continue

            ethv_gi_iface="${ethv_gi_path##*/}"
            [ "$ethv_gi_iface" != "lo" ] || continue
            [ ! -d "$ethv_gi_path/wireless" ] || continue

            ethv_gi_type="$(ethv_read_first_line "$ethv_gi_path/type" 2>/dev/null || true)"
            [ "$ethv_gi_type" = "1" ] || continue
            [ -e "$ethv_gi_path/device" ] || continue

            ethv_gi_interfaces="$ethv_gi_interfaces $ethv_gi_iface"
        done
    fi

    for ethv_gi_iface in $ethv_gi_interfaces; do
        [ -d "/sys/class/net/$ethv_gi_iface" ] || continue
        [ "$ethv_gi_iface" != "lo" ] || continue
        [ ! -d "/sys/class/net/$ethv_gi_iface/wireless" ] || continue
        printf '%s\n' "$ethv_gi_iface"
    done | awk '!seen[$0]++'
}

# ethv_get_physical_interfaces
#   Restrict discovered Ethernet interfaces to entries backed by a sysfs device.
#   stdout: one physical interface name per line.
#   return: status of the discovery and filtering pipeline.
ethv_get_physical_interfaces() {
    ethv_get_interfaces |
    while IFS= read -r ethv_gpi_iface; do
        [ -n "$ethv_gpi_iface" ] || continue
        [ -e "/sys/class/net/$ethv_gpi_iface/device" ] || continue
        printf '%s\n' "$ethv_gpi_iface"
    done
}

# ethv_qps615_collect_overlay_state <result-dir>
#   Inspect the dynamically discovered VendorDtbOverlays EFI variable for the
#   QPS615 FIT compatibility value without changing target state. stdout:
#   diagnostics, returned state is exported through QPS615_OVERLAY_*.
#   return: 0 when staging is selected, 1 when absent or set to another value,
#   2 when EFI inspection is unavailable, and 3 for invalid arguments. Side
#   effects: exports QPS615_OVERLAY_* state and refreshes retained evidence.
ethv_qps615_collect_overlay_state() {
    ethv_qos_result_dir="${1:-}"
    ethv_qos_list_log="$ethv_qos_result_dir/qps615_efi_variables.log"
    ethv_qos_print_log="$ethv_qos_result_dir/qps615_overlay_print.log"
    ethv_qos_diag_log="$ethv_qos_result_dir/qps615_overlay_diagnostics.log"
    ethv_qos_state_file="$ethv_qos_result_dir/qps615_overlay.tsv"

    [ -n "$ethv_qos_result_dir" ] || return 3
    mkdir -p "$ethv_qos_result_dir" || return 3
    : >"$ethv_qos_list_log" || return 3
    : >"$ethv_qos_print_log" || return 3
    : >"$ethv_qos_diag_log" || return 3
    : >"$ethv_qos_state_file" || return 3

    QPS615_OVERLAY_VARIABLE=""
    QPS615_OVERLAY_STATE="unavailable"
    QPS615_OVERLAY_REASON="EFI FIT overlay inspection is unavailable"

    for ethv_qos_helper in \
        efi_find_variable_by_name \
        efi_text_variable_matches \
        efi_mount_exists; do
        if ! command -v "$ethv_qos_helper" >/dev/null 2>&1; then
            QPS615_OVERLAY_REASON="required EFI helper is unavailable: $ethv_qos_helper"
            break
        fi
    done

    if [ "$QPS615_OVERLAY_REASON" = "EFI FIT overlay inspection is unavailable" ]; then
        for ethv_qos_command in efivar awk dirname grep mktemp od sed tr; do
            if ! command -v "$ethv_qos_command" >/dev/null 2>&1; then
                QPS615_OVERLAY_REASON="image-provided EFI inspection command is unavailable: $ethv_qos_command"
                break
            fi
        done
    fi

    if [ "$QPS615_OVERLAY_REASON" = "EFI FIT overlay inspection is unavailable" ]; then
        if ! efi_mount_exists; then
            QPS615_OVERLAY_REASON="efivarfs is not mounted at ${EFIVARFS_PATH:-/sys/firmware/efi/efivars}"
        else
            ethv_qos_lookup_status=0
            QPS615_OVERLAY_VARIABLE="$(
                efi_find_variable_by_name \
                    "$QPS615_OVERLAY_NAME" \
                    "$ethv_qos_list_log" \
                    2>"$ethv_qos_diag_log"
            )" || ethv_qos_lookup_status=$?

            if [ "$ethv_qos_lookup_status" -eq 2 ]; then
                QPS615_OVERLAY_REASON="EFI variable listing failed, inspect $ethv_qos_list_log and EFI runtime permissions"
            elif [ "$ethv_qos_lookup_status" -eq 1 ] &&
                 ! grep -Eq -- "-$QPS615_OVERLAY_NAME$" "$ethv_qos_list_log"; then
                QPS615_OVERLAY_STATE="absent"
                QPS615_OVERLAY_REASON="$QPS615_OVERLAY_NAME is absent from the successfully read EFI inventory"
            elif [ -z "$QPS615_OVERLAY_VARIABLE" ]; then
                QPS615_OVERLAY_REASON="$QPS615_OVERLAY_NAME was not uniquely discovered in the EFI variable inventory"
            else
                ethv_qos_read_status=0
                efi_text_variable_matches \
                    "$QPS615_OVERLAY_VARIABLE" \
                    "$QPS615_OVERLAY_VALUE" \
                    "$ethv_qos_print_log" || ethv_qos_read_status=$?
                case "$ethv_qos_read_status" in
                    0)
                        QPS615_OVERLAY_STATE="configured"
                        QPS615_OVERLAY_REASON="$QPS615_OVERLAY_VARIABLE contains $QPS615_OVERLAY_VALUE"
                        ;;
                    1)
                        QPS615_OVERLAY_STATE="value-mismatch"
                        QPS615_OVERLAY_REASON="$QPS615_OVERLAY_VARIABLE does not contain the required QPS615 FIT value $QPS615_OVERLAY_VALUE"
                        ;;
                    *)
                        QPS615_OVERLAY_REASON="EFI variable $QPS615_OVERLAY_VARIABLE could not be inspected, see $ethv_qos_print_log"
                        ;;
                esac
            fi
        fi
    fi

    printf 'variable\t%s\nexpected_value\t%s\nstate\t%s\nreason\t%s\n' \
        "${QPS615_OVERLAY_VARIABLE:-unavailable}" \
        "$QPS615_OVERLAY_VALUE" \
        "$QPS615_OVERLAY_STATE" \
        "$QPS615_OVERLAY_REASON" >"$ethv_qos_state_file"

    export QPS615_OVERLAY_VARIABLE QPS615_OVERLAY_STATE
    export QPS615_OVERLAY_REASON
    log_info "[QPS615-FIT] state=$QPS615_OVERLAY_STATE variable=${QPS615_OVERLAY_VARIABLE:-unavailable} expected_value=$QPS615_OVERLAY_VALUE reason=$QPS615_OVERLAY_REASON"

    case "$QPS615_OVERLAY_STATE" in
        configured)
            return 0
            ;;
        absent|value-mismatch)
            return 1
            ;;
        *)
            return 2
            ;;
    esac
}

# ethv_qps615_prepare_overlay <result-dir>
#   Explicitly select staging, mounting efivarfs when necessary and retaining it.
#   Callers must arrange efi_restore_efivarfs_ro on exit and signals first.
#   stdout: diagnostics.
#   return: 0 when already selected, 1 on write or verification failure,
#   2 when EFI mutation is unavailable, 3 for invalid arguments, and 4 after a
#   verified update requiring reboot. Side effects: retains new mounts, restores
#   initially read-only mounts, and writes one EFI variable after operator opt-in.
ethv_qps615_prepare_overlay() {
    ethv_qpo_result_dir="${1:-}"

    [ -n "$ethv_qpo_result_dir" ] || return 3
    mkdir -p "$ethv_qpo_result_dir" || return 3
    EFI_REMOUNT_LOG="$ethv_qpo_result_dir/qps615_efi_remount.log"
    export EFI_REMOUNT_LOG

    for ethv_qpo_helper in \
        efi_ensure_mounted \
        efi_restore_efivarfs_ro \
        efi_write_text_variable; do
        if ! command -v "$ethv_qpo_helper" >/dev/null 2>&1; then
            QPS615_OVERLAY_REASON="required EFI mutation helper is unavailable: $ethv_qpo_helper"
            export QPS615_OVERLAY_REASON
            return 2
        fi
    done

    for ethv_qpo_command in efivar awk cp dirname grep mktemp mount od sed sync tr; do
        if ! command -v "$ethv_qpo_command" >/dev/null 2>&1; then
            QPS615_OVERLAY_REASON="image-provided EFI mutation command is unavailable: $ethv_qpo_command"
            export QPS615_OVERLAY_REASON
            return 2
        fi
    done

    ethv_qpo_status=0
    if efi_ensure_mounted "$ethv_qpo_result_dir/qps615_efi_mount.log"; then
        ethv_qps615_update_overlay "$ethv_qpo_result_dir" || ethv_qpo_status=$?
    else
        QPS615_OVERLAY_REASON="Could not mount EFI variable storage at $EFIVARFS_PATH, check EFI runtime support and mount permissions"
        ethv_qpo_status=1
    fi
    if ! efi_restore_efivarfs_ro >>"$ethv_qpo_result_dir/qps615_efi_cleanup.log" 2>&1; then
        QPS615_OVERLAY_REASON="${QPS615_OVERLAY_REASON:-Overlay preparation completed}, restoring EFI mount to read-only failed at $EFIVARFS_PATH, inspect qps615_efi_cleanup.log"
        ethv_qpo_status=1
    fi
    export QPS615_OVERLAY_REASON
    return "$ethv_qpo_status"
}

# ethv_qps615_update_overlay <result-dir>
#   Update an accessible EFI overlay selection. Only the explicit preparation
#   wrapper may call this helper. A successfully listed absent variable uses
#   the documented QPS615 GUID. stdout: diagnostics. return: 0 already set,
#   4 written, 1 write failure, 2 inspection unavailable. Side effects: retains
#   before/after evidence and persists staging without a newline.
ethv_qps615_update_overlay() {
    ethv_qu_result_dir="$1"
    ethv_qpo_state_status=0
    ethv_qps615_collect_overlay_state "$ethv_qu_result_dir" || ethv_qpo_state_status=$?
    case "$ethv_qpo_state_status" in
        0)
            return 0
            ;;
        2|3)
            return 2
            ;;
    esac

    for ethv_qu_before in qps615_overlay.tsv qps615_efi_variables.log qps615_overlay_print.log; do
        if ! cp "$ethv_qu_result_dir/$ethv_qu_before" \
            "$ethv_qu_result_dir/before_$ethv_qu_before"; then
            QPS615_OVERLAY_REASON="Could not preserve EFI state before updating $QPS615_OVERLAY_NAME"
            return 1
        fi
    done
    if [ "$QPS615_OVERLAY_STATE" = "absent" ]; then
        QPS615_OVERLAY_VARIABLE="$QPS615_OVERLAY_DEFAULT_GUID-$QPS615_OVERLAY_NAME"
        log_info "Creating $QPS615_OVERLAY_VARIABLE using the QPS615 bring-up firmware namespace"
    fi

    if ! efi_write_text_variable \
        "$QPS615_OVERLAY_VARIABLE" \
        "$QPS615_OVERLAY_VALUE" \
        "$ethv_qu_result_dir/qps615_overlay_write.log"; then
        QPS615_OVERLAY_REASON="could not write $QPS615_OVERLAY_VALUE to $QPS615_OVERLAY_VARIABLE"
        export QPS615_OVERLAY_REASON
        return 1
    fi

    if ! ethv_qps615_collect_overlay_state "$ethv_qu_result_dir"; then
        QPS615_OVERLAY_REASON="QPS615 FIT selection was written but EFI verification did not find $QPS615_OVERLAY_VALUE"
        export QPS615_OVERLAY_REASON
        return 1
    fi

    QPS615_OVERLAY_REASON="$QPS615_OVERLAY_VARIABLE was updated to $QPS615_OVERLAY_VALUE, reboot the target to load the QPS615 FIT device tree"
    export QPS615_OVERLAY_REASON
    return 4
}

# ethv_qps615_collect_dt_state <result-dir> <runtime-tsv>
#   Discover enabled QPS615-compatible runtime DT nodes and validate the
#   supply-backed public pwrctrl-tc9563 contract when declared. Nodes without
#   supplies remain valid for integration forms that do not use the platform
#   power-control driver. stdout: diagnostics. return: 0 when DT evidence is healthy,
#   1 when a declared contract is malformed or unbound, 2 on discovery failure,
#   and 3 for invalid arguments. Side effects: exports QPS615_DT_* and
#   QPS615_PWRCTRL_* state. Scratch files use result-dir without changing TMPDIR
#   outside the discovery call. Diagnostics are retained in qps615_dt_scan.log.
ethv_qps615_collect_dt_state() {
    ethv_qds_result_dir="${1:-}"
    ethv_qds_inventory="${2:-}"
    ethv_qds_nodes="$ethv_qds_result_dir/qps615_dt_nodes.log"
    ethv_qds_evidence="$ethv_qds_result_dir/qps615_dt_platform.tsv"

    [ -n "$ethv_qds_result_dir" ] && [ -n "$ethv_qds_inventory" ] || return 3
    mkdir -p "$ethv_qds_result_dir" || return 3
    : >"$ethv_qds_nodes" || return 3
    : >"$ethv_qds_evidence" || return 3

    QPS615_DT_NODE_COUNT=0
    QPS615_DT_FAILURE_REASON=""
    export QPS615_DT_FAILURE_REASON
    QPS615_PWRCTRL_EXPECTED_COUNT=0
    QPS615_PWRCTRL_BOUND_COUNT=0
    QPS615_PWRCTRL_FAILURE_REASON=""

    ethv_qds_scan_status=0
    if command -v dt_list_compatible_nodes >/dev/null 2>&1; then
        TMPDIR="$ethv_qds_result_dir" dt_list_compatible_nodes \
            '(^|[[:space:]])pci1179,0623([[:space:]]|$)' regex \
            >"$ethv_qds_nodes" 2>"$ethv_qds_result_dir/qps615_dt_scan.log" || ethv_qds_scan_status=$?
    else
        ethv_qds_scan_status=2
    fi
    if [ "$ethv_qds_scan_status" -gt 1 ]; then
        QPS615_DT_FAILURE_REASON="QPS615 runtime DT discovery failed with status $ethv_qds_scan_status, check DT access, image-provided discovery utilities, writable evidence storage and $ethv_qds_result_dir/qps615_dt_scan.log"
        log_warn "$QPS615_DT_FAILURE_REASON"
        return 2
    fi

    while IFS= read -r ethv_qds_node; do
        [ -n "$ethv_qds_node" ] || continue
        QPS615_DT_NODE_COUNT=$((QPS615_DT_NODE_COUNT + 1))
        ethv_qds_compatible="$(
            dt_property_text "$ethv_qds_node" compatible 2>/dev/null || true
        )"
        ethv_qds_status="$(
            dt_property_text "$ethv_qds_node" status 2>/dev/null || true
        )"
        [ -n "$ethv_qds_status" ] || ethv_qds_status="okay"
        ethv_qds_supply_count=0

        for ethv_qds_property in \
            vddc-supply \
            vdd18-supply \
            vdd09-supply \
            vddio1-supply \
            vddio2-supply \
            vddio18-supply; do
            if [ -e "$ethv_qds_node/$ethv_qds_property" ]; then
                ethv_qds_supply_count=$((ethv_qds_supply_count + 1))
            fi
        done

        ethv_qds_i2c="absent"
        ethv_qds_resx="absent"
        ethv_qds_platform="unavailable"
        ethv_qds_driver="unbound"
        [ -e "$ethv_qds_node/i2c-parent" ] && ethv_qds_i2c="present"
        [ -e "$ethv_qds_node/resx-gpios" ] && ethv_qds_resx="present"

        if [ "$ethv_qds_supply_count" -gt 0 ]; then
            QPS615_PWRCTRL_EXPECTED_COUNT=$((QPS615_PWRCTRL_EXPECTED_COUNT + 1))
            if [ "$ethv_qds_supply_count" -ne 6 ]; then
                ethv_qds_reason="QPS615 DT node $ethv_qds_node declares $ethv_qds_supply_count of 6 required power supplies, provide vddc, vdd18, vdd09, vddio1, vddio2, and vddio18 supplies"
                if [ -n "$QPS615_PWRCTRL_FAILURE_REASON" ]; then
                    QPS615_PWRCTRL_FAILURE_REASON="$QPS615_PWRCTRL_FAILURE_REASON, $ethv_qds_reason"
                else
                    QPS615_PWRCTRL_FAILURE_REASON="$ethv_qds_reason"
                fi
            elif [ "$ethv_qds_i2c" != "present" ] || \
                 [ "$ethv_qds_resx" != "present" ]; then
                ethv_qds_reason="QPS615 DT node $ethv_qds_node declares all supplies but the power-control contract requires i2c-parent and resx-gpios, observed i2c_parent=$ethv_qds_i2c resx_gpios=$ethv_qds_resx"
                if [ -n "$QPS615_PWRCTRL_FAILURE_REASON" ]; then
                    QPS615_PWRCTRL_FAILURE_REASON="$QPS615_PWRCTRL_FAILURE_REASON, $ethv_qds_reason"
                else
                    QPS615_PWRCTRL_FAILURE_REASON="$ethv_qds_reason"
                fi
            else
                ethv_qds_platform="$(
                    find_platform_device_for_dt_node "$ethv_qds_node" \
                        2>/dev/null || true
                )"
                if [ -n "$ethv_qds_platform" ]; then
                    ethv_qds_driver="$(
                        platform_device_driver_name "$ethv_qds_platform" \
                            2>/dev/null || true
                    )"
                    [ -n "$ethv_qds_driver" ] || ethv_qds_driver="unbound"
                fi

                if [ "$ethv_qds_driver" = "pwrctrl-tc9563" ]; then
                    QPS615_PWRCTRL_BOUND_COUNT=$((QPS615_PWRCTRL_BOUND_COUNT + 1))
                else
                    ethv_qds_reason="QPS615 DT node $ethv_qds_node requires pwrctrl-tc9563 but platform device ${ethv_qds_platform:-unavailable} is bound to $ethv_qds_driver"
                    if [ -n "$QPS615_PWRCTRL_FAILURE_REASON" ]; then
                        QPS615_PWRCTRL_FAILURE_REASON="$QPS615_PWRCTRL_FAILURE_REASON, $ethv_qds_reason"
                    else
                        QPS615_PWRCTRL_FAILURE_REASON="$ethv_qds_reason"
                    fi
                fi
            fi
        fi

        printf 'dt-node\t%s\tcompatible=%s\tstatus=%s\tsupplies=%s/6\ti2c_parent=%s\tresx_gpios=%s\tplatform_device=%s\tplatform_driver=%s\n' \
            "$ethv_qds_node" \
            "${ethv_qds_compatible:-unavailable}" \
            "$ethv_qds_status" \
            "$ethv_qds_supply_count" \
            "$ethv_qds_i2c" \
            "$ethv_qds_resx" \
            "$ethv_qds_platform" \
            "$ethv_qds_driver" >>"$ethv_qds_evidence"
        printf 'dt-node\t%s\tcompatible=%s\tstatus=%s\tsupplies=%s/6\ti2c_parent=%s\tresx_gpios=%s\tplatform_device=%s\tplatform_driver=%s\n' \
            "$ethv_qds_node" \
            "${ethv_qds_compatible:-unavailable}" \
            "$ethv_qds_status" \
            "$ethv_qds_supply_count" \
            "$ethv_qds_i2c" \
            "$ethv_qds_resx" \
            "$ethv_qds_platform" \
            "$ethv_qds_driver" >>"$ethv_qds_inventory"
        log_info "[QPS615-DT] node=$ethv_qds_node compatible=${ethv_qds_compatible:-unavailable} status=$ethv_qds_status supplies=$ethv_qds_supply_count/6 i2c_parent=$ethv_qds_i2c resx_gpios=$ethv_qds_resx platform_device=$ethv_qds_platform platform_driver=$ethv_qds_driver"
    done <"$ethv_qds_nodes"

    printf 'dt-summary\tnodes=%s\tpwrctrl_expected=%s\tpwrctrl_bound=%s\tfailure=%s\n' \
        "$QPS615_DT_NODE_COUNT" \
        "$QPS615_PWRCTRL_EXPECTED_COUNT" \
        "$QPS615_PWRCTRL_BOUND_COUNT" \
        "${QPS615_PWRCTRL_FAILURE_REASON:-none}" >>"$ethv_qds_inventory"

    export QPS615_DT_NODE_COUNT QPS615_PWRCTRL_EXPECTED_COUNT
    export QPS615_PWRCTRL_BOUND_COUNT QPS615_PWRCTRL_FAILURE_REASON
    [ -z "$QPS615_PWRCTRL_FAILURE_REASON" ]
}

# ethv_qps615_is_switch_root <resolved-pci-device-path>
#   Identify an outermost 1179:0623 bridge by its sysfs ancestry. The caller
#   has already verified this device's PCI ID. stdout: none. return: 0 for
#   a root, 1 for a descendant bridge, 3 for invalid input. Side effects: none.
ethv_qps615_is_switch_root() {
    ethv_qsr_path="${1:-}"
    case "$ethv_qsr_path" in
        /*)
            ;;
        *)
            return 3
            ;;
    esac
    ethv_qsr_parent="${ethv_qsr_path%/*}"
    while [ -n "$ethv_qsr_parent" ] && [ "$ethv_qsr_parent" != "/" ]; do
        ethv_qsr_vendor=$(ethv_read_first_line "$ethv_qsr_parent/vendor" 2>/dev/null || true)
        ethv_qsr_device=$(ethv_read_first_line "$ethv_qsr_parent/device" 2>/dev/null || true)
        if [ "$ethv_qsr_vendor" = "0x1179" ] && [ "$ethv_qsr_device" = "0x0623" ]; then
            return 1
        fi
        ethv_qsr_parent="${ethv_qsr_parent%/*}"
    done
    return 0
}

# ethv_qps615_collect_runtime <result-dir> [pci-devices-root]
#   Collect and validate the runtime QPS615/TC956x PCIe Ethernet topology.
#   Applicability comes from enabled pci1179,0623 runtime DT nodes or an
#   enumerated Toshiba 1179:0623 switch, never an installed package or module
#   alone. Exported QPS615_* values summarize the result for PCIe and Ethernet
#   suite orchestration.
#   return: 0 when applicable and healthy, 1 when declared hardware is broken,
#   2 when QPS615 is not present, and 3 for invalid arguments.
ethv_qps615_collect_runtime() {
    ethv_qcr_result_dir="${1:-}"
    ethv_qcr_pci_root="${2:-/sys/bus/pci/devices}"
    ethv_qcr_inventory="$ethv_qcr_result_dir/qps615_runtime.tsv"
    ethv_qcr_switches="$ethv_qcr_result_dir/qps615_switches.log"

    [ -n "$ethv_qcr_result_dir" ] || return 3
    mkdir -p "$ethv_qcr_result_dir" || return 1
    : >"$ethv_qcr_inventory" || return 1
    : >"$ethv_qcr_switches" || return 1

    QPS615_SWITCH_COUNT=0
    QPS615_BRIDGE_COUNT=0
    export QPS615_BRIDGE_COUNT
    QPS615_DOWNSTREAM_COUNT=0
    QPS615_ETHERNET_DEVICE_COUNT=0
    QPS615_ETHERNET_DECLARED_COUNT=0
    QPS615_DRIVER_DEVICE_COUNT=0
    QPS615_DECLARED_DRIVER_DEVICE_COUNT=0
    QPS615_UNBOUND_ETHERNET_COUNT=0
    QPS615_NETDEV_COUNT=0
    QPS615_DECLARED_NETDEV_COUNT=0
    QPS615_ETHERNET_OF_NODE_COUNT=0
    QPS615_ETHERNET_OVERRIDE_COUNT=0
    QPS615_FIRMWARE_PATH=""
    QPS615_MODULE_PATH=""
    QPS615_MODULE_STATE="absent"
    QPS615_MODULE_PORT_BDFS=""
    QPS615_MODULE_PORT_CONFIG="unavailable"
    QPS615_PCI_DRIVER_PATH=""
    QPS615_PCI_DRIVER_STATE="absent"
    QPS615_PCI_AUTOPROBE="unknown"
    QPS615_DT_NODE_COUNT=0
    QPS615_DT_FAILURE_REASON=""
    QPS615_PWRCTRL_EXPECTED_COUNT=0
    QPS615_PWRCTRL_BOUND_COUNT=0
    QPS615_PWRCTRL_FAILURE_REASON=""
    QPS615_TOPOLOGY_FAILURE_REASON=""
    QPS615_ETHERNET_FAILURE_REASON=""
    QPS615_ETHERNET_SKIP_REASON=""
    QPS615_READINESS_SUMMARY=""
    QPS615_FAILURE_REASON=""

    ethv_qcr_dt_status=0
    ethv_qps615_collect_dt_state \
        "$ethv_qcr_result_dir" \
        "$ethv_qcr_inventory" || ethv_qcr_dt_status=$?
    if [ "$ethv_qcr_dt_status" -gt 1 ]; then
        QPS615_FAILURE_REASON="${QPS615_DT_FAILURE_REASON:-Could not collect QPS615 DT evidence in $ethv_qcr_result_dir}"
        QPS615_TOPOLOGY_FAILURE_REASON="$QPS615_FAILURE_REASON"
        export QPS615_FAILURE_REASON QPS615_TOPOLOGY_FAILURE_REASON
        return 1
    fi

    log_info "QPS615 validation: scanning PCI devices under $ethv_qcr_pci_root for switch 1179:0623"

    if [ ! -d "$ethv_qcr_pci_root" ]; then
        if [ "$QPS615_DT_NODE_COUNT" -gt 0 ]; then
            QPS615_TOPOLOGY_FAILURE_REASON="$QPS615_DT_NODE_COUNT enabled QPS615 DT node(s) were found but PCI sysfs is not exposed at $ethv_qcr_pci_root"
            QPS615_FAILURE_REASON="$QPS615_TOPOLOGY_FAILURE_REASON"
            if [ -n "$QPS615_PWRCTRL_FAILURE_REASON" ]; then
                QPS615_FAILURE_REASON="$QPS615_FAILURE_REASON, power-control failure: $QPS615_PWRCTRL_FAILURE_REASON"
            fi
            ethv_qcr_pci_missing_status=1
        else
            log_info "QPS615 validation is not applicable because the PCI sysfs inventory is not exposed and no enabled QPS615 DT node was found"
            ethv_qcr_pci_missing_status=2
        fi
        export QPS615_SWITCH_COUNT QPS615_DOWNSTREAM_COUNT QPS615_ETHERNET_DEVICE_COUNT
        export QPS615_ETHERNET_DECLARED_COUNT QPS615_DRIVER_DEVICE_COUNT
        export QPS615_DECLARED_DRIVER_DEVICE_COUNT QPS615_UNBOUND_ETHERNET_COUNT QPS615_NETDEV_COUNT
        export QPS615_DECLARED_NETDEV_COUNT
        export QPS615_ETHERNET_OF_NODE_COUNT QPS615_ETHERNET_OVERRIDE_COUNT
        export QPS615_FIRMWARE_PATH QPS615_MODULE_PATH QPS615_MODULE_STATE
        export QPS615_MODULE_PORT_BDFS QPS615_MODULE_PORT_CONFIG
        export QPS615_PCI_DRIVER_PATH QPS615_PCI_DRIVER_STATE
        export QPS615_PCI_AUTOPROBE
        export QPS615_DT_NODE_COUNT QPS615_PWRCTRL_EXPECTED_COUNT
        export QPS615_PWRCTRL_BOUND_COUNT QPS615_PWRCTRL_FAILURE_REASON
        export QPS615_TOPOLOGY_FAILURE_REASON QPS615_ETHERNET_FAILURE_REASON
        export QPS615_ETHERNET_SKIP_REASON QPS615_READINESS_SUMMARY
        export QPS615_FAILURE_REASON
        return "$ethv_qcr_pci_missing_status"
    fi

    for ethv_qcr_device in "$ethv_qcr_pci_root"/*; do
        [ -d "$ethv_qcr_device" ] || continue
        ethv_qcr_vendor="$(ethv_read_first_line "$ethv_qcr_device/vendor" 2>/dev/null || true)"
        ethv_qcr_id="$(ethv_read_first_line "$ethv_qcr_device/device" 2>/dev/null || true)"

        if [ "$ethv_qcr_vendor" = "0x1179" ] && \
           [ "$ethv_qcr_id" = "0x0623" ]; then
            ethv_qcr_resolved="$(readlink -f "$ethv_qcr_device" 2>/dev/null || true)"
            QPS615_BRIDGE_COUNT=$((QPS615_BRIDGE_COUNT + 1))
            if [ -z "$ethv_qcr_resolved" ]; then
                QPS615_TOPOLOGY_FAILURE_REASON="Cannot resolve QPS615 PCI sysfs path $ethv_qcr_device, rerun with readable PCI topology"
                continue
            fi
            printf 'bridge-function\t%s\t%s\t%s\t%s\n' \
                "${ethv_qcr_device##*/}" \
                "$ethv_qcr_vendor" \
                "$ethv_qcr_id" \
                "$ethv_qcr_resolved" >>"$ethv_qcr_inventory"
            ethv_qps615_is_switch_root "$ethv_qcr_resolved" || continue
            QPS615_SWITCH_COUNT=$((QPS615_SWITCH_COUNT + 1))
            printf '%s\n' "$ethv_qcr_resolved" >>"$ethv_qcr_switches"
            printf 'switch\t%s\t%s\t%s\t%s\n' \
                "${ethv_qcr_device##*/}" \
                "$ethv_qcr_vendor" \
                "$ethv_qcr_id" \
                "${ethv_qcr_resolved:-unresolved}" >>"$ethv_qcr_inventory"
            log_info "[QPS615] switch=${ethv_qcr_device##*/} vendor=$ethv_qcr_vendor device=$ethv_qcr_id path=${ethv_qcr_resolved:-unresolved}"
        fi
    done

    printf 'topology-summary\tswitches=%s\tbridge_functions=%s\n' \
        "$QPS615_SWITCH_COUNT" "$QPS615_BRIDGE_COUNT" >>"$ethv_qcr_inventory"

    if [ "$QPS615_SWITCH_COUNT" -eq 0 ] && [ "$QPS615_BRIDGE_COUNT" -eq 0 ]; then
        if [ "$QPS615_DT_NODE_COUNT" -gt 0 ]; then
            QPS615_TOPOLOGY_FAILURE_REASON="$QPS615_DT_NODE_COUNT enabled QPS615 DT node(s) were found but switch 1179:0623 was not enumerated"
            QPS615_FAILURE_REASON="$QPS615_TOPOLOGY_FAILURE_REASON"
            if [ -n "$QPS615_PWRCTRL_FAILURE_REASON" ]; then
                QPS615_FAILURE_REASON="$QPS615_FAILURE_REASON, power-control failure: $QPS615_PWRCTRL_FAILURE_REASON"
            fi
            ethv_qcr_absent_status=1
        else
            log_info "QPS615 validation is not applicable because switch 1179:0623 was not enumerated and no enabled QPS615 DT node was found"
            ethv_qcr_absent_status=2
        fi
        export QPS615_SWITCH_COUNT QPS615_DOWNSTREAM_COUNT QPS615_ETHERNET_DEVICE_COUNT
        export QPS615_ETHERNET_DECLARED_COUNT QPS615_DRIVER_DEVICE_COUNT
        export QPS615_DECLARED_DRIVER_DEVICE_COUNT QPS615_UNBOUND_ETHERNET_COUNT QPS615_NETDEV_COUNT
        export QPS615_DECLARED_NETDEV_COUNT
        export QPS615_ETHERNET_OF_NODE_COUNT QPS615_ETHERNET_OVERRIDE_COUNT
        export QPS615_FIRMWARE_PATH QPS615_MODULE_PATH QPS615_MODULE_STATE
        export QPS615_MODULE_PORT_BDFS QPS615_MODULE_PORT_CONFIG
        export QPS615_PCI_DRIVER_PATH QPS615_PCI_DRIVER_STATE
        export QPS615_PCI_AUTOPROBE
        export QPS615_DT_NODE_COUNT QPS615_PWRCTRL_EXPECTED_COUNT
        export QPS615_PWRCTRL_BOUND_COUNT QPS615_PWRCTRL_FAILURE_REASON
        export QPS615_TOPOLOGY_FAILURE_REASON QPS615_ETHERNET_FAILURE_REASON
        export QPS615_ETHERNET_SKIP_REASON QPS615_READINESS_SUMMARY
        export QPS615_FAILURE_REASON
        return "$ethv_qcr_absent_status"
    fi

    for ethv_qcr_device in "$ethv_qcr_pci_root"/*; do
        [ -d "$ethv_qcr_device" ] || continue
        ethv_qcr_resolved="$(readlink -f "$ethv_qcr_device" 2>/dev/null || true)"
        ethv_qcr_is_downstream=0

        while IFS= read -r ethv_qcr_switch_path; do
            [ -n "$ethv_qcr_switch_path" ] || continue
            case "$ethv_qcr_resolved" in
                "$ethv_qcr_switch_path"/*)
                    ethv_qcr_is_downstream=1
                    break
                    ;;
            esac
        done <"$ethv_qcr_switches"

        [ "$ethv_qcr_is_downstream" -eq 1 ] || continue
        QPS615_DOWNSTREAM_COUNT=$((QPS615_DOWNSTREAM_COUNT + 1))

        ethv_qcr_driver=""
        if [ -L "$ethv_qcr_device/driver" ]; then
            ethv_qcr_driver="$(basename "$(readlink -f "$ethv_qcr_device/driver" 2>/dev/null)" 2>/dev/null || true)"
        fi
        ethv_qcr_vendor="$(ethv_read_first_line "$ethv_qcr_device/vendor" 2>/dev/null || true)"
        ethv_qcr_id="$(ethv_read_first_line "$ethv_qcr_device/device" 2>/dev/null || true)"
        printf 'downstream\t%s\t%s\t%s\t%s\t%s\n' \
            "${ethv_qcr_device##*/}" \
            "${ethv_qcr_vendor:-unknown}" \
            "${ethv_qcr_id:-unknown}" \
            "${ethv_qcr_driver:-unbound}" \
            "${ethv_qcr_resolved:-unknown}" >>"$ethv_qcr_inventory"
        log_info "[QPS615] downstream=${ethv_qcr_device##*/} vendor=${ethv_qcr_vendor:-unknown} device=${ethv_qcr_id:-unknown} driver=${ethv_qcr_driver:-unbound}"

        if [ "$ethv_qcr_vendor" = "0x1179" ] && \
           [ "$ethv_qcr_id" = "0x0220" ]; then
            QPS615_ETHERNET_DEVICE_COUNT=$((QPS615_ETHERNET_DEVICE_COUNT + 1))
            ethv_qcr_modalias="$(ethv_read_first_line "$ethv_qcr_device/modalias" 2>/dev/null || true)"
            ethv_qcr_driver_override="$(ethv_read_first_line "$ethv_qcr_device/driver_override" 2>/dev/null || true)"
            ethv_qcr_of_node="$(readlink -f "$ethv_qcr_device/of_node" 2>/dev/null || true)"
            ethv_qcr_runtime_status="$(ethv_read_first_line "$ethv_qcr_device/power/runtime_status" 2>/dev/null || true)"
            ethv_qcr_port_declaration="absent"
            case "$ethv_qcr_driver_override" in
                ''|'(null)')
                    ethv_qcr_driver_override="none"
                    ;;
                *)
                    QPS615_ETHERNET_OVERRIDE_COUNT=$((QPS615_ETHERNET_OVERRIDE_COUNT + 1))
                    ;;
            esac
            if [ -n "$ethv_qcr_of_node" ]; then
                QPS615_ETHERNET_OF_NODE_COUNT=$((QPS615_ETHERNET_OF_NODE_COUNT + 1))
                if [ -e "$ethv_qcr_of_node/phy-reset-gpios" ] || \
                   [ -e "$ethv_qcr_of_node/qcom,phy-rst-gpio" ]; then
                    ethv_qcr_port_declaration="declared"
                    QPS615_ETHERNET_DECLARED_COUNT=$((QPS615_ETHERNET_DECLARED_COUNT + 1))
                fi
            fi
            printf 'ethernet-function\t%s\tdriver=%s\tmodalias=%s\tdriver_override=%s\tof_node=%s\tport_configuration=%s\truntime_status=%s\n' \
                "${ethv_qcr_device##*/}" \
                "${ethv_qcr_driver:-unbound}" \
                "${ethv_qcr_modalias:-unavailable}" \
                "$ethv_qcr_driver_override" \
                "${ethv_qcr_of_node:-unavailable}" \
                "$ethv_qcr_port_declaration" \
                "${ethv_qcr_runtime_status:-unknown}" >>"$ethv_qcr_inventory"
            log_info "[QPS615-ETH] function=${ethv_qcr_device##*/} driver=${ethv_qcr_driver:-unbound} port_configuration=$ethv_qcr_port_declaration driver_override=$ethv_qcr_driver_override of_node=${ethv_qcr_of_node:-unavailable} runtime_status=${ethv_qcr_runtime_status:-unknown} modalias=${ethv_qcr_modalias:-unavailable}"

            case "$ethv_qcr_driver" in
                tc956x*)
                QPS615_DRIVER_DEVICE_COUNT=$((QPS615_DRIVER_DEVICE_COUNT + 1))
                if [ "$ethv_qcr_port_declaration" = "declared" ]; then
                    QPS615_DECLARED_DRIVER_DEVICE_COUNT=$((QPS615_DECLARED_DRIVER_DEVICE_COUNT + 1))
                fi
                for ethv_qcr_netdev in "$ethv_qcr_device"/net/*; do
                    [ -d "$ethv_qcr_netdev" ] || continue
                    QPS615_NETDEV_COUNT=$((QPS615_NETDEV_COUNT + 1))
                    if [ "$ethv_qcr_port_declaration" = "declared" ]; then
                        QPS615_DECLARED_NETDEV_COUNT=$((QPS615_DECLARED_NETDEV_COUNT + 1))
                    fi
                    printf 'netdev\t%s\t%s\n' \
                        "${ethv_qcr_device##*/}" \
                        "${ethv_qcr_netdev##*/}" >>"$ethv_qcr_inventory"
                    log_info "[QPS615] ethernet_function=${ethv_qcr_device##*/} netdev=${ethv_qcr_netdev##*/}"
                done
                    ;;
                "")
                    QPS615_UNBOUND_ETHERNET_COUNT=$((QPS615_UNBOUND_ETHERNET_COUNT + 1))
                    ;;
                *)
                    QPS615_UNBOUND_ETHERNET_COUNT=$((QPS615_UNBOUND_ETHERNET_COUNT + 1))
                    log_warn "[QPS615-ETH] function=${ethv_qcr_device##*/} is bound to unexpected driver=$ethv_qcr_driver"
                    ;;
            esac
        fi
    done

    QPS615_FIRMWARE_PATH="$(find_image_firmware TC956X_Firmware_PCIeBridge.bin 2>/dev/null || true)"
    if [ -n "$QPS615_FIRMWARE_PATH" ]; then
        log_info "[QPS615] firmware=$QPS615_FIRMWARE_PATH"
    else
        log_warn "[QPS615] firmware TC956X_Firmware_PCIeBridge.bin was not found"
    fi

    ethv_qcr_module_candidate="$(find_kernel_module tc956x_pcie_eth 2>/dev/null | awk '/^\// { print; exit }' || true)"
    ethv_qcr_running_kernel="$(uname -r 2>/dev/null || true)"
    case "$ethv_qcr_module_candidate" in
        "/lib/modules/$ethv_qcr_running_kernel/"*)
            QPS615_MODULE_PATH="$ethv_qcr_module_candidate"
            QPS615_MODULE_STATE="available"
            ;;
        "")
            ;;
        *)
            log_warn "[QPS615-ETH] tc956x_pcie_eth exists only outside the running-kernel module tree: $ethv_qcr_module_candidate"
            ;;
    esac

    if [ -d /sys/module/tc956x_pcie_eth ]; then
        QPS615_MODULE_STATE="loaded-or-built-in"
    fi

    if [ -r /sys/module/tc956x_pcie_eth/parameters/tc956x_eth_ports_bdf ]; then
        QPS615_MODULE_PORT_BDFS="$(
            ethv_read_first_line \
                /sys/module/tc956x_pcie_eth/parameters/tc956x_eth_ports_bdf \
                2>/dev/null || true
        )"
        ethv_qcr_nonzero_bdfs="$(
            printf '%s' "$QPS615_MODULE_PORT_BDFS" |
                tr -d '0,[:space:]'
        )"
        if [ -n "$QPS615_MODULE_PORT_BDFS" ] && \
           [ -z "$ethv_qcr_nonzero_bdfs" ]; then
            QPS615_MODULE_PORT_CONFIG="driver-defaults"
        elif [ -n "$QPS615_MODULE_PORT_BDFS" ]; then
            QPS615_MODULE_PORT_CONFIG="configured"
        fi
        printf 'module-configuration\ttc956x_eth_ports_bdf=%s\tstate=%s\n' \
            "${QPS615_MODULE_PORT_BDFS:-unreadable}" \
            "$QPS615_MODULE_PORT_CONFIG" >>"$ethv_qcr_inventory"
        log_info "[QPS615-ETH] module_parameter=tc956x_eth_ports_bdf value=${QPS615_MODULE_PORT_BDFS:-unreadable} state=$QPS615_MODULE_PORT_CONFIG"
    fi

    if [ -d /sys/bus/pci/drivers/tc956x_pci-eth ]; then
        QPS615_PCI_DRIVER_PATH="/sys/bus/pci/drivers/tc956x_pci-eth"
        QPS615_PCI_DRIVER_STATE="registered"
        log_info "[QPS615-ETH] pci_driver=tc956x_pci-eth state=registered path=$QPS615_PCI_DRIVER_PATH"
    elif [ "$QPS615_MODULE_STATE" = "loaded-or-built-in" ]; then
        log_warn "[QPS615-ETH] module is loaded but PCI driver tc956x_pci-eth is not registered"
    fi
    printf 'pci-driver\tname=tc956x_pci-eth\tstate=%s\tpath=%s\n' \
        "$QPS615_PCI_DRIVER_STATE" \
        "${QPS615_PCI_DRIVER_PATH:-unavailable}" >>"$ethv_qcr_inventory"

    QPS615_PCI_AUTOPROBE="$(
        ethv_read_first_line /sys/bus/pci/drivers_autoprobe 2>/dev/null || true
    )"
    [ -n "$QPS615_PCI_AUTOPROBE" ] || QPS615_PCI_AUTOPROBE="unknown"
    printf 'pci-autoprobe\tstate=%s\n' \
        "$QPS615_PCI_AUTOPROBE" >>"$ethv_qcr_inventory"
    log_info "[QPS615-ETH] pci_drivers_autoprobe=$QPS615_PCI_AUTOPROBE"

    if [ -n "$QPS615_MODULE_PATH" ]; then
        log_info "[QPS615-ETH] module=tc956x_pcie_eth state=$QPS615_MODULE_STATE path=$QPS615_MODULE_PATH"
    elif [ "$QPS615_MODULE_STATE" = "loaded-or-built-in" ]; then
        log_info "[QPS615-ETH] module=tc956x_pcie_eth state=$QPS615_MODULE_STATE path=built-in-or-unexposed"
    else
        log_warn "[QPS615-ETH] module=tc956x_pcie_eth was not found for the running kernel"
    fi

    log_info "[QPS615] summary switches=$QPS615_SWITCH_COUNT bridge_functions=$QPS615_BRIDGE_COUNT downstream=$QPS615_DOWNSTREAM_COUNT ethernet_devices=$QPS615_ETHERNET_DEVICE_COUNT declared_ethernet_ports=$QPS615_ETHERNET_DECLARED_COUNT bound_ethernet_devices=$QPS615_DRIVER_DEVICE_COUNT bound_declared_ports=$QPS615_DECLARED_DRIVER_DEVICE_COUNT unbound_ethernet_devices=$QPS615_UNBOUND_ETHERNET_COUNT of_nodes=$QPS615_ETHERNET_OF_NODE_COUNT driver_overrides=$QPS615_ETHERNET_OVERRIDE_COUNT netdevs=$QPS615_NETDEV_COUNT declared_port_netdevs=$QPS615_DECLARED_NETDEV_COUNT artifact=$ethv_qcr_inventory"

    if [ -n "$QPS615_TOPOLOGY_FAILURE_REASON" ]; then
        log_warn "$QPS615_TOPOLOGY_FAILURE_REASON"
    elif [ "$QPS615_DOWNSTREAM_COUNT" -eq 0 ]; then
        QPS615_TOPOLOGY_FAILURE_REASON="QPS615 bridge is enumerated but exposes no downstream PCIe functions"
    elif [ "$QPS615_DT_NODE_COUNT" -gt "$QPS615_SWITCH_COUNT" ]; then
        QPS615_TOPOLOGY_FAILURE_REASON="$QPS615_DT_NODE_COUNT enabled QPS615 DT node(s) were found but only $QPS615_SWITCH_COUNT switch instance(s) enumerated"
    elif [ -z "$QPS615_FIRMWARE_PATH" ]; then
        QPS615_TOPOLOGY_FAILURE_REASON="required TC956X_Firmware_PCIeBridge.bin is not readable in a standard firmware root"
    fi

    if [ "$QPS615_ETHERNET_DEVICE_COUNT" -eq 0 ]; then
        QPS615_ETHERNET_SKIP_REASON="QPS615 is enumerated but exposes no Toshiba 1179:0220 Ethernet functions"
    elif [ "$QPS615_ETHERNET_DECLARED_COUNT" -eq 0 ] && \
         [ "$QPS615_DRIVER_DEVICE_COUNT" -eq 0 ]; then
        QPS615_ETHERNET_SKIP_REASON="$QPS615_ETHERNET_DEVICE_COUNT embedded Ethernet function(s) are enumerated, but no runtime DT port configuration declares them for Ethernet use"
    elif [ "$QPS615_DECLARED_DRIVER_DEVICE_COUNT" -lt "$QPS615_ETHERNET_DECLARED_COUNT" ]; then
        if [ "$QPS615_PCI_AUTOPROBE" = "0" ]; then
            QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not ready because PCI driver autoprobe is disabled"
        elif [ "$QPS615_ETHERNET_OVERRIDE_COUNT" -gt 0 ]; then
            QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not ready and $QPS615_ETHERNET_OVERRIDE_COUNT function(s) have a driver override"
        elif [ "$QPS615_MODULE_STATE" = "loaded-or-built-in" ]; then
            if [ "$QPS615_PCI_DRIVER_STATE" != "registered" ]; then
                QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not bound, tc956x_pcie_eth is loaded but PCI driver tc956x_pci-eth is not registered"
            else
                QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) did not bind after automatic matching, PCI driver tc956x_pci-eth is registered and endpoint probe did not complete"
            fi
        elif [ -n "$QPS615_MODULE_PATH" ]; then
            QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not bound although module $QPS615_MODULE_PATH is available"
        else
            QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not bound and tc956x_pcie_eth is not available for the running kernel"
        fi
    elif [ "$QPS615_DECLARED_NETDEV_COUNT" -lt "$QPS615_DECLARED_DRIVER_DEVICE_COUNT" ]; then
        QPS615_ETHERNET_FAILURE_REASON="$QPS615_DECLARED_DRIVER_DEVICE_COUNT declared TC956x Ethernet port(s) are bound but only $QPS615_DECLARED_NETDEV_COUNT netdev(s) are exposed"
    elif [ "$QPS615_ETHERNET_DECLARED_COUNT" -eq 0 ] && \
         [ "$QPS615_NETDEV_COUNT" -lt "$QPS615_DRIVER_DEVICE_COUNT" ]; then
        QPS615_ETHERNET_FAILURE_REASON="$QPS615_DRIVER_DEVICE_COUNT TC956x Ethernet function(s) are bound without an explicit runtime DT port declaration, but only $QPS615_NETDEV_COUNT netdev(s) are exposed"
    fi

    QPS615_READINESS_SUMMARY="dt_nodes=$QPS615_DT_NODE_COUNT pwrctrl_expected=$QPS615_PWRCTRL_EXPECTED_COUNT pwrctrl_bound=$QPS615_PWRCTRL_BOUND_COUNT switches=$QPS615_SWITCH_COUNT ethernet_devices=$QPS615_ETHERNET_DEVICE_COUNT declared_ports=$QPS615_ETHERNET_DECLARED_COUNT bound_devices=$QPS615_DRIVER_DEVICE_COUNT bound_declared_ports=$QPS615_DECLARED_DRIVER_DEVICE_COUNT netdevs=$QPS615_NETDEV_COUNT module_state=$QPS615_MODULE_STATE pci_driver_state=$QPS615_PCI_DRIVER_STATE pci_autoprobe=$QPS615_PCI_AUTOPROBE"

    if [ -n "$QPS615_TOPOLOGY_FAILURE_REASON" ]; then
        QPS615_FAILURE_REASON="$QPS615_TOPOLOGY_FAILURE_REASON"
        if [ -n "$QPS615_ETHERNET_FAILURE_REASON" ]; then
            QPS615_FAILURE_REASON="$QPS615_FAILURE_REASON, Ethernet readiness failure: $QPS615_ETHERNET_FAILURE_REASON"
        elif [ -n "$QPS615_ETHERNET_SKIP_REASON" ]; then
            QPS615_FAILURE_REASON="$QPS615_FAILURE_REASON, Ethernet provisioning note: $QPS615_ETHERNET_SKIP_REASON"
        fi
    elif [ -n "$QPS615_PWRCTRL_FAILURE_REASON" ]; then
        QPS615_FAILURE_REASON="$QPS615_PWRCTRL_FAILURE_REASON"
    elif [ -n "$QPS615_ETHERNET_FAILURE_REASON" ]; then
        QPS615_FAILURE_REASON="$QPS615_ETHERNET_FAILURE_REASON"
    fi

    if [ -n "$QPS615_FAILURE_REASON" ] && \
       [ -n "$QPS615_PWRCTRL_FAILURE_REASON" ] && \
       [ "$QPS615_FAILURE_REASON" != "$QPS615_PWRCTRL_FAILURE_REASON" ]; then
        QPS615_FAILURE_REASON="$QPS615_FAILURE_REASON, power-control failure: $QPS615_PWRCTRL_FAILURE_REASON"
    fi

    if [ -n "$QPS615_FAILURE_REASON" ]; then
        QPS615_FAILURE_REASON="$QPS615_FAILURE_REASON, $QPS615_READINESS_SUMMARY"
    fi

    export QPS615_SWITCH_COUNT QPS615_DOWNSTREAM_COUNT QPS615_ETHERNET_DEVICE_COUNT
    export QPS615_ETHERNET_DECLARED_COUNT QPS615_DRIVER_DEVICE_COUNT
    export QPS615_DECLARED_DRIVER_DEVICE_COUNT QPS615_UNBOUND_ETHERNET_COUNT QPS615_NETDEV_COUNT
    export QPS615_DECLARED_NETDEV_COUNT
    export QPS615_ETHERNET_OF_NODE_COUNT QPS615_ETHERNET_OVERRIDE_COUNT
    export QPS615_FIRMWARE_PATH QPS615_MODULE_PATH QPS615_MODULE_STATE
    export QPS615_MODULE_PORT_BDFS QPS615_MODULE_PORT_CONFIG
    export QPS615_PCI_DRIVER_PATH QPS615_PCI_DRIVER_STATE
    export QPS615_PCI_AUTOPROBE
    export QPS615_DT_NODE_COUNT QPS615_PWRCTRL_EXPECTED_COUNT
    export QPS615_PWRCTRL_BOUND_COUNT QPS615_PWRCTRL_FAILURE_REASON
    export QPS615_TOPOLOGY_FAILURE_REASON QPS615_ETHERNET_FAILURE_REASON
    export QPS615_ETHERNET_SKIP_REASON QPS615_READINESS_SUMMARY
    export QPS615_FAILURE_REASON

    [ -z "$QPS615_FAILURE_REASON" ]
}

# ethv_qps615_list_netdevs <qps615-runtime-tsv>
#   Read a QPS615 runtime TSV and print unique correlated netdev names.
#   stdout: one netdev name per line in first-observed inventory order.
#   return: 0 when the readable inventory is parsed, 1 when it is unavailable,
#   or a nonzero awk status. Side effects: none.
ethv_qps615_list_netdevs() {
    ethv_qln_inventory="${1:-}"

    [ -r "$ethv_qln_inventory" ] || return 1
    awk -F '\t' '
        $1 == "netdev" && $3 != "" && !seen[$3]++ {
            print $3
        }
    ' "$ethv_qln_inventory"
}

# ethv_qps615_module_candidate <runtime-tsv> [pci-root]
#   Resolve a unique module from QPS615 endpoint driver links or the running
#   image's modalias database. stdout: one module name. return: 0 unique,
#   1 absent/ambiguous/invalid metadata, 3 invalid input. Diagnostics: stderr.
ethv_qps615_module_candidate() {
    ethv_qmc_inventory="${1:-}"
    ethv_qmc_root="${2:-/sys/bus/pci/devices}"
    [ -r "$ethv_qmc_inventory" ] || return 3
    ethv_qmc_modules=""
    ethv_qmc_bdfs=$(awk -F '\t' '$1 == "ethernet-function" { print $2 }' "$ethv_qmc_inventory") || return 1
    for ethv_qmc_bdf in $ethv_qmc_bdfs; do
        case "$ethv_qmc_bdf" in
            ''|*[!0123456789abcdefABCDEF:.]*)
                return 1
                ;;
        esac
        ethv_qmc_device="$ethv_qmc_root/$ethv_qmc_bdf"
        if [ -L "$ethv_qmc_device/driver/module" ]; then
            ethv_qmc_link=$(readlink -f "$ethv_qmc_device/driver/module") || return 1
            ethv_qmc_match="${ethv_qmc_link##*/}"
        else
            ethv_qmc_alias=$(ethv_read_first_line "$ethv_qmc_device/modalias") || return 1
            ethv_qmc_match=$(kernel_modules_for_modalias "$ethv_qmc_alias") || return 1
        fi
        ethv_qmc_modules="$ethv_qmc_modules
$ethv_qmc_match"
    done
    ethv_qmc_unique=$(printf '%s\n' "$ethv_qmc_modules" | awk 'NF && !seen[$0]++')
    case "$ethv_qmc_unique" in
        ''|-*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-]*)
            printf '%s\n' 'QPS615 endpoints did not resolve to one safe module name, inspect driver/module links and modalias metadata' >&2
            return 1
            ;;
    esac
    printf '%s\n' "$ethv_qmc_unique"
}

# ethv_restore_owned_module <module> <owned:0|1> <result-dir> <timeout-seconds>
#   Restore only a target module loaded by this test. Dependencies and initially
#   loaded modules are preserved. stdout: diagnostics. return: 0 restored or
#   untouched, 1 on failure. Side effects: bounded, non-forced target removal.
ethv_restore_owned_module() {
    [ "$2" = 1 ] || return 0
    # Interrupted managed commands must stop before restoring the snapshot.
    # Normal completion clears these PIDs in run_with_managed_timeout.
    if [ -r "${MANAGED_TIMEOUT_SLEEP_PID_FILE:-}" ]; then
        MANAGED_TIMEOUT_WATCHER_SLEEP_PID=$(cat "$MANAGED_TIMEOUT_SLEEP_PID_FILE")
    fi
    for ethv_rom_pid in "${MANAGED_TIMEOUT_CMD_PID:-}" \
        "${MANAGED_TIMEOUT_WATCHER_PID:-}" "${MANAGED_TIMEOUT_WATCHER_SLEEP_PID:-}"; do
        case "$ethv_rom_pid" in
            ''|*[!0-9]*|0|1)
                continue
                ;;
        esac
        kill -KILL "$ethv_rom_pid" 2>/dev/null || true
    done
    is_module_loaded "$1" || return 0
    log_info "Restoring initially unloaded module $1, preserving dependency modules"
    # Do not use the generic unload helper's modprobe -r fallback, which can
    # also remove dependency modules that were already active before the test.
    if ! run_with_managed_timeout "$4" "$3" module-restore \
        rmmod "$1" >"$3/module_restore.log" 2>&1; then
        log_error "Could not restore module $1, inspect $3/module_restore.log"
        return 1
    fi
    mrv_wait_module_state absent "$1" "$4"
}

# ethv_qps615_validate_module_load <result-dir> <load-timeout> <settle-timeout> [pci-root]
#   Validate one runtime-resolved QPS615 module without cycling a module that
#   was already loaded. Reuse shared discovery, module, wait, timeout and kernel
#   log helpers. stdout: diagnostics. return: 0 ready, 1 failed, 2 unavailable.
#   Side effects: load only if absent, restore the target on every exit/signal.
#   Runs in a subshell so ownership and traps cannot affect other profiles.
ethv_qps615_validate_module_load() (
    ethv_qml_dir="${1:-}"
    ethv_qml_timeout="${2:-30}"
    ethv_qml_settle="${3:-20}"
    ethv_qml_pci="${4:-/sys/bus/pci/devices}"
    [ -n "$ethv_qml_dir" ] || exit 1
    ethv_is_uint "$ethv_qml_timeout" && [ "$ethv_qml_timeout" -gt 0 ] || exit 1
    ethv_is_uint "$ethv_qml_settle" && [ "$ethv_qml_settle" -gt 0 ] || exit 1
    mkdir -p "$ethv_qml_dir" || exit 1
    ethv_qml_dir=$(cd "$ethv_qml_dir" && pwd) || exit 1

    ethv_qml_status=0
    ethv_qps615_collect_runtime "$ethv_qml_dir/before" "$ethv_qml_pci" || ethv_qml_status=$?
    if [ "$ethv_qml_status" -eq 2 ]; then
        log_skip "QPS615 module load validation requires runtime DT or PCI hardware, an installed module alone is not applicability evidence"
        exit 2
    fi
    if [ "$ethv_qml_status" -gt 2 ] || [ -n "${QPS615_TOPOLOGY_FAILURE_REASON:-}" ] ||
       [ -n "${QPS615_PWRCTRL_FAILURE_REASON:-}" ]; then
        log_error "Cannot validate module loading before QPS615 topology and power-control are ready: ${QPS615_FAILURE_REASON:-discovery failed}"
        exit 1
    fi
    if [ "${QPS615_ETHERNET_DEVICE_COUNT:-0}" -eq 0 ]; then
        log_skip "QPS615 exposes no Ethernet endpoints for module validation"
        exit 2
    fi
    if [ -n "${QPS615_ETHERNET_SKIP_REASON:-}" ]; then
        log_skip "$QPS615_ETHERNET_SKIP_REASON, provision runtime Ethernet port configuration before testing module loading"
        exit 2
    fi
    if ! ethv_qps615_module_candidate "$ethv_qml_dir/before/qps615_runtime.tsv" "$ethv_qml_pci" \
        >"$ethv_qml_dir/module_candidate.log" 2>"$ethv_qml_dir/module_discovery.log"; then
        log_error "Cannot uniquely resolve the QPS615 module from runtime endpoints, inspect $ethv_qml_dir/module_discovery.log and image modalias metadata"
        exit 1
    fi
    ethv_qml_module=$(ethv_read_first_line "$ethv_qml_dir/module_candidate.log") || exit 1
    ethv_qml_module=$(mrv_module_lsmod_name "$ethv_qml_module") || exit 1
    ethv_qml_origin=$(kernel_module_runtime_origin "$ethv_qml_module") || {
        log_error "Runtime module metadata is unavailable for $ethv_qml_module"
        exit 1
    }
    ethv_qml_owned=0
    ethv_qml_exit=0
    trap '
        ethv_qml_exit=$?
        trap - EXIT HUP INT TERM
        if ! ethv_restore_owned_module "$ethv_qml_module" "$ethv_qml_owned" "$ethv_qml_dir" "$ethv_qml_timeout"; then
            ethv_qml_exit=1
        fi
        exit "$ethv_qml_exit"
    ' EXIT
    trap 'exit 1' HUP INT TERM

    log_info "QPS615 module selection: module=$ethv_qml_module origin=$ethv_qml_origin source=runtime-driver-or-modalias"
    if command -v modinfo >/dev/null 2>&1; then
        if ! run_with_managed_timeout "$ethv_qml_timeout" "$ethv_qml_dir" module-info \
            modinfo "$ethv_qml_module" >"$ethv_qml_dir/modinfo.log" 2>&1; then
            log_error "modinfo failed for $ethv_qml_module, inspect $ethv_qml_dir/modinfo.log"
            exit 1
        fi
    fi
    if [ "$ethv_qml_origin" = builtin ] || is_module_loaded "$ethv_qml_module"; then
        log_info "QPS615 module is already active or built-in, no load or unload will be performed"
    else
        case "$ethv_qml_origin" in
            module:*)
                ethv_qml_path="${ethv_qml_origin#module:}"
                ;;
            *)
                log_error "No image-provided module file was resolved for $ethv_qml_module"
                exit 1
                ;;
        esac
        if ! command -v rmmod >/dev/null 2>&1 ||
           ! command -v modprobe >/dev/null 2>&1 || [ "$(id -u)" != 0 ]; then
            log_skip "Loading $ethv_qml_module requires root and image-provided modprobe and rmmod for target-only restoration"
            exit 2
        fi
        if [ ! -r "$ethv_qml_path" ]; then
            log_error "Running-kernel module $ethv_qml_path is not readable, provision the matching image module"
            exit 1
        fi
        # Record ownership before attempting the load so partial failures clean up.
        ethv_qml_owned=1
        # Match the existing reload profile's modprobe workflow, allowing the
        # running kernel's alias/dependency metadata to resolve prerequisites.
        if ! run_with_managed_timeout "$ethv_qml_timeout" "$ethv_qml_dir" module-load \
            modprobe "$ethv_qml_module" >"$ethv_qml_dir/module_load.log" 2>&1; then
            log_error "Loading $ethv_qml_module failed, inspect $ethv_qml_dir/module_load.log"
            exit 1
        fi
        if ! mrv_wait_module_state present "$ethv_qml_module" "$ethv_qml_settle"; then
            log_error "Module $ethv_qml_module did not become loaded within ${ethv_qml_settle}s"
            exit 1
        fi
    fi

    ethv_qml_elapsed=0
    while :; do
        ethv_qml_status=0
        ethv_qps615_collect_runtime "$ethv_qml_dir/after" "$ethv_qml_pci" || ethv_qml_status=$?
        if [ "$ethv_qml_status" -eq 0 ] && [ "${QPS615_NETDEV_COUNT:-0}" -gt 0 ]; then
            ethv_qml_bound=$(ethv_qps615_module_candidate "$ethv_qml_dir/after/qps615_runtime.tsv" "$ethv_qml_pci") || exit 1
            ethv_qml_bound=$(mrv_module_lsmod_name "$ethv_qml_bound") || exit 1
            if [ "$ethv_qml_bound" != "$ethv_qml_module" ]; then
                log_error "QPS615 bound module changed from $ethv_qml_module to $ethv_qml_bound during validation"
                exit 1
            fi
            break
        fi
        if [ "$ethv_qml_elapsed" -ge "$ethv_qml_settle" ]; then
            log_error "Module $ethv_qml_module is active but QPS615 driver/netdev binding is not ready: ${QPS615_FAILURE_REASON:-no correlated netdev}, inspect $ethv_qml_dir/after"
            exit 1
        fi
        sleep 1
        ethv_qml_elapsed=$((ethv_qml_elapsed + 1))
    done
    ethv_qml_kernel_status=0
    scan_dmesg_errors "$ethv_qml_dir/kernel" 'tc956|qps615' \
        'Link is Down|Link down|carrier lost|no carrier|deferred probe|EPROBE_DEFER' || ethv_qml_kernel_status=$?
    if [ "${DMESG_ACCESS_STATUS:-unavailable}" = available ] && [ "$ethv_qml_kernel_status" -eq 0 ]; then
        log_error "QPS615 kernel errors were captured in $ethv_qml_dir/kernel/dmesg_errors.log"
        exit 1
    fi
    log_info "QPS615 module $ethv_qml_module has runtime-correlated driver binding and netdev readiness, checking restoration before PASS, artifacts=$ethv_qml_dir"
    exit 0
)

# ethv_validate_qps615_traffic_config <fixture> <interfaces> <peer> <count> <wait>
#   Validate QPS615 traffic policy before runtime discovery. Empty interface
#   and peer values select dynamic discovery. stdout: none. return: 0 when
#   valid, 1 otherwise, or 3 for missing arguments. Side effects: exports
#   QPS615_CONFIG_ERROR with an actionable reason.
ethv_validate_qps615_traffic_config() {
    [ "$#" -ge 5 ] || return 3
    ethv_vqtc_fixture="$1"
    ethv_vqtc_interfaces="$2"
    ethv_vqtc_peer="$3"
    ethv_vqtc_count="$4"
    ethv_vqtc_wait="$5"
    QPS615_CONFIG_ERROR=""

    if ! ethv_is_boolean "$ethv_vqtc_fixture"; then
        QPS615_CONFIG_ERROR="fixture-must-be-0-or-1"
    elif ! ethv_is_uint "$ethv_vqtc_count" ||
         ! ethv_is_uint "$ethv_vqtc_wait"; then
        QPS615_CONFIG_ERROR="ping-count-and-wait-must-be-unsigned-integers"
    elif ! awk \
        -v count="$ethv_vqtc_count" \
        -v wait_seconds="$ethv_vqtc_wait" '
            BEGIN {
                exit !(count >= 1 && count <= 20 &&
                       wait_seconds >= 1 && wait_seconds <= 5)
            }
        '; then
        QPS615_CONFIG_ERROR="ping-count-or-wait-out-of-range"
    elif [ -n "$ethv_vqtc_peer" ] &&
         ! ethv_valid_peer_spec "$ethv_vqtc_peer"; then
        QPS615_CONFIG_ERROR="peer-must-be-unicast-ipv4-ipv6-or-hostname"
    else
        case "$ethv_vqtc_interfaces" in
            ""|all)
                ;;
            ,*|*,|*,,*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:,-]*)
                QPS615_CONFIG_ERROR="interface-list-is-malformed"
                ;;
        esac
    fi

    export QPS615_CONFIG_ERROR
    [ -z "$QPS615_CONFIG_ERROR" ]
}

# ethv_get_driver <interface>
#   Query the bound network driver through ethtool or the sysfs driver link.
#   stdout: driver name, or an empty line when unavailable.
#   return: 0 after printing the best-effort result.
ethv_get_driver() {
    ethv_gd_iface="${1:-}"
    ethv_gd_driver=""

    if command -v ethtool >/dev/null 2>&1; then
        ethv_gd_driver="$(
            ethtool -i "$ethv_gd_iface" 2>/dev/null \
                | sed -n 's/^driver:[[:space:]]*//p' \
                | head -n 1
        )"
    fi

    if [ -z "$ethv_gd_driver" ] && \
       [ -L "/sys/class/net/$ethv_gd_iface/device/driver" ]; then
        ethv_gd_driver="$(
            readlink "/sys/class/net/$ethv_gd_iface/device/driver" 2>/dev/null \
                | sed 's#/$##; s#.*/##'
        )"
    fi

    printf '%s\n' "$ethv_gd_driver"
}

# ethv_get_driver_module <interface>
#   Resolve the kernel module backing the interface driver through sysfs.
#   stdout: module name, or an empty line when no module link is exposed.
#   return: 0 after printing the best-effort result.
ethv_get_driver_module() {
    ethv_gdm_iface="${1:-}"
    ethv_gdm_module=""

    if [ -L "/sys/class/net/$ethv_gdm_iface/device/driver/module" ]; then
        ethv_gdm_module="$(
            readlink "/sys/class/net/$ethv_gdm_iface/device/driver/module" 2>/dev/null \
                | sed 's#/$##; s#.*/##'
        )"
    fi

    printf '%s\n' "$ethv_gdm_module"
}

# ethv_get_bus_info <interface>
#   Read the ethtool bus-info field for an interface.
#   stdout: bus identifier when ethtool reports one, otherwise no output.
#   return: 0 for best-effort discovery.
ethv_get_bus_info() {
    ethv_gbi_iface="${1:-}"

    if command -v ethtool >/dev/null 2>&1; then
        ethtool -i "$ethv_gbi_iface" 2>/dev/null \
            | sed -n 's/^bus-info:[[:space:]]*//p' \
            | head -n 1
    fi
}

# ethv_get_firmware_version <interface>
#   Read the driver firmware-version field reported by ethtool.
#   stdout: firmware version when available, otherwise no output.
#   return: 0 for best-effort discovery.
ethv_get_firmware_version() {
    ethv_gfv_iface="${1:-}"

    if command -v ethtool >/dev/null 2>&1; then
        ethtool -i "$ethv_gfv_iface" 2>/dev/null \
            | sed -n 's/^firmware-version:[[:space:]]*//p' \
            | head -n 1
    fi
}

# ethv_get_device_path <interface>
#   Resolve the canonical sysfs device path for an interface.
#   stdout: absolute device path when resolvable, otherwise no output.
#   return: 0 for best-effort discovery.
ethv_get_device_path() {
    ethv_gdp_iface="${1:-}"

    if command -v readlink >/dev/null 2>&1; then
        readlink -f "/sys/class/net/$ethv_gdp_iface/device" 2>/dev/null || true
    fi
}

# ethv_get_of_compatible <interface>
#   Read and comma-join NUL-separated device-tree compatible strings.
#   stdout: compatible strings when the interface exposes an OF node.
#   return: 0 for best-effort discovery.
ethv_get_of_compatible() {
    ethv_goc_iface="${1:-}"
    ethv_goc_node="/sys/class/net/$ethv_goc_iface/device/of_node"

    if [ -r "$ethv_goc_node/compatible" ]; then
        tr '\000' ',' <"$ethv_goc_node/compatible" 2>/dev/null \
            | sed 's/,$//'
    fi
}

# ethv_get_phy_id <interface>
#   Read the PHY identifier exported through the interface phydev link.
#   stdout: PHY identifier when exposed, otherwise no output.
#   return: 0 for best-effort discovery, or the file-reader status.
ethv_get_phy_id() {
    ethv_gpi_iface="${1:-}"

    if [ -r "/sys/class/net/$ethv_gpi_iface/phydev/phy_id" ]; then
        ethv_read_first_line "/sys/class/net/$ethv_gpi_iface/phydev/phy_id"
    fi
}

# ethv_get_ipv4 <interface>
#   Return the first global IPv4 address assigned to an interface.
#   stdout: address without CIDR prefix, or no output when none is assigned.
#   return: 0 for best-effort discovery.
ethv_get_ipv4() {
    ethv_gip_iface="${1:-}"

    if command -v get_ip_address >/dev/null 2>&1; then
        get_ip_address "$ethv_gip_iface" 2>/dev/null || true
        return 0
    fi

    ip -4 -o addr show dev "$ethv_gip_iface" scope global 2>/dev/null \
        | awk 'NR == 1 { split($4, a, "/"); print a[1] }'
}

# ethv_get_ipv6 <interface>
#   Discover a ready unicast IPv6 address, preferring global over link scope.
#   stdout: address without prefix, or nothing. return: 0 found, 1 absent or
#   ip unavailable, 2 query/parse failure. Side effects: none.
ethv_get_ipv6() {
    command -v ip >/dev/null 2>&1 || return 1
    ethv_gi6_inventory=$(ip -6 -o addr show dev "$1" 2>/dev/null) || return 2
    ethv_gi6_address=$(printf '%s\n' "$ethv_gi6_inventory" | awk '
        / tentative| dadfailed/ { next }
        $3 == "inet6" {
            split($4, address, "/")
            if ($0 ~ /scope global/) { print address[1]; found = 1; exit }
            if (fallback == "") fallback = address[1]
        }
        END { if (!found && fallback != "") print fallback }
    ')
    [ -n "$ethv_gi6_address" ] || return 1
    ethv_valid_unicast_ipv6 "$ethv_gi6_address" || return 2
    printf '%s\n' "$ethv_gi6_address"
}

# ethv_valid_ipv4 <address>
#   Validate an IPv4 address and reject unspecified and link-local addresses.
#   stdout: none.
#   return: 0 for a usable IPv4 address, nonzero otherwise.
ethv_valid_ipv4() {
    ethv_vi_addr="${1:-}"

    if command -v is_valid_ipv4 >/dev/null 2>&1; then
        is_valid_ipv4 "$ethv_vi_addr"
        return $?
    fi

    case "$ethv_vi_addr" in
        ""|0.0.0.0|169.254.*)
            return 1
            ;;
    esac

    printf '%s\n' "$ethv_vi_addr" |
    awk -F. '
        NF != 4 {
            exit 1
        }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {
                    exit 1
                }
            }
        }
    '
}

# ethv_valid_unicast_ipv4 <address>
#   Validate one dotted-decimal IPv4 peer address suitable for unicast traffic.
#   Rejects unspecified, link-local, loopback, multicast, and 240/4 addresses.
#   stdout: none. return: 0 for a usable unicast peer, nonzero otherwise.
#   Side effects: none.
ethv_valid_unicast_ipv4() {
    ethv_vui_addr="${1:-}"

    # The legacy is_valid_ipv4 helper only rejects empty/link-local values.
    # Validate the actual dotted-decimal structure before numeric comparisons.
    printf '%s\n' "$ethv_vui_addr" | awk -F. '
        NF != 4 { exit 1 }
        { for (i = 1; i <= 4; i++)
            if ($i !~ /^[0-9]+$/ || $i > 255 ||
                (length($i) > 1 && substr($i, 1, 1) == "0")) exit 1 }
        END { if (NR != 1) exit 1 }
    ' || return 1
    case "$ethv_vui_addr" in
        169.254.*)
            return 1
            ;;
    esac
    ethv_vui_first_octet=${ethv_vui_addr%%.*}
    [ "$ethv_vui_first_octet" -ge 1 ] &&
        [ "$ethv_vui_first_octet" -ne 127 ] &&
        [ "$ethv_vui_first_octet" -lt 224 ]
}

# ethv_normalize_ipv6 <address>
#   Expand an unscoped IPv6 literal to eight lowercase zero-padded hex groups.
#   Supports embedded dotted-decimal tails. stdout: normalized IPv6 address.
#   return: 0 valid syntax, 1 invalid. Side effects: none.
ethv_normalize_ipv6() {
    printf '%s\n' "${1:-}" | LC_ALL=C awk '
        {
            value = tolower($0)
            if (value !~ /:/ || value ~ /[^0-9a-f:.]/) exit 1
            if (value ~ /\./) {
                tail = value
                sub(/^.*:/, "", tail)
                if (split(tail, octets, ".") != 4) exit 1
                for (i = 1; i <= 4; i++)
                    if (octets[i] !~ /^[0-9]+$/ || octets[i] > 255 ||
                        (length(octets[i]) > 1 && substr(octets[i], 1, 1) == "0")) exit 1
                sub(/[^:]*$/, "", value)
                value = value sprintf("%x:%x", octets[1] * 256 + octets[2], octets[3] * 256 + octets[4])
            }
            gap = index(value, "::")
            if (gap) {
                left = substr(value, 1, gap - 1)
                right = substr(value, gap + 2)
                if (index(right, "::")) exit 1
                lc = left == "" ? 0 : split(left, lhs, ":")
                rc = right == "" ? 0 : split(right, rhs, ":")
                if (lc + rc >= 8) exit 1
                count = 0
                for (i = 1; i <= lc; i++) groups[++count] = lhs[i]
                for (i = 1; i <= 8 - lc - rc; i++) groups[++count] = "0"
                for (i = 1; i <= rc; i++) groups[++count] = rhs[i]
            } else if (split(value, groups, ":") != 8) exit 1
            result = ""
            for (i = 1; i <= 8; i++) {
                if (length(groups[i]) < 1 || length(groups[i]) > 4 ||
                    groups[i] !~ /^[0-9a-f]+$/) exit 1
                padded = "0000" groups[i]
                result = result (i == 1 ? "" : ":") substr(padded, length(padded) - 3)
            }
            valid = 1
        }
        END { if (NR != 1 || !valid) exit 1; print result }
    '
}

# ethv_valid_unicast_ipv6 <address>
#   Reject unspecified, loopback, multicast and IPv4-mapped IPv6 peers.
#   stdout: none. return: 0 usable unicast, 1 invalid. Side effects: none.
ethv_valid_unicast_ipv6() {
    ethv_vu6_normal=$(ethv_normalize_ipv6 "${1:-}") || return 1
    case "$ethv_vu6_normal" in
        0000:0000:0000:0000:0000:0000:0000:0000|0000:0000:0000:0000:0000:0000:0000:0001|ff*|0000:0000:0000:0000:0000:ffff:*)
            return 1
            ;;
    esac
    return 0
}

# ethv_valid_peer_spec <peer>
#   Accept unicast IPv4/IPv6 or an ASCII DNS hostname, optionally absolute.
#   IPv6 scope is supplied by the selected interface, not a percent suffix.
#   Reject numeric address shorthand, options, URLs and malformed labels.
#   stdout: none. return: 0 valid, 1 invalid. Side effects: none.
ethv_valid_peer_spec() {
    case "${1:-}" in
        *:*)
            ethv_valid_unicast_ipv6 "$1"
            ;;
        ""|*[!0-9.]*)
            printf '%s\n' "${1:-}" | LC_ALL=C awk '
                {
                    sub(/\.$/, "")
                    if (length($0) < 1 || length($0) > 253) exit 1
                    count = split($0, labels, ".")
                    for (i = 1; i <= count; i++) {
                        if (length(labels[i]) < 1 || length(labels[i]) > 63 ||
                            labels[i] !~ /^[A-Za-z0-9-]+$/ ||
                            labels[i] ~ /^-/ || labels[i] ~ /-$/) exit 1
                    }
                }
                END { if (NR != 1) exit 1 }
            '
            ;;
        *)
            ethv_valid_unicast_ipv4 "$1"
            ;;
    esac
}

# ethv_resolve_traffic_peer <interface> <requested-peer-or-empty> <artifact-prefix>
#   Select the interface gateway or resolve an explicit peer through system NSS.
#   Each getent query is bounded to 10 seconds. Never probe other peer targets.
#   stdout: none. return: 0 ready, 1 missing/unsafe peer or discovery failure.
#   Side effects: writes discovery artifacts and sets ETHV_PEER_ADDRESS,
#   ETHV_PEER_SOURCE, ETHV_PEER_FAMILY and ETHV_PEER_REASON. IPv4 is preferred.
#   Does not change network configuration.
ethv_resolve_traffic_peer() {
    ethv_rtp_iface="$1"
    ethv_rtp_requested="$2"
    ethv_rtp_prefix="$3"
    ETHV_PEER_ADDRESS=""
    ETHV_PEER_SOURCE="interface-gateway"
    ETHV_PEER_FAMILY=4
    ETHV_PEER_REASON=""
    export ETHV_PEER_ADDRESS ETHV_PEER_SOURCE ETHV_PEER_FAMILY ETHV_PEER_REASON

    if [ -z "$ethv_rtp_requested" ]; then
        if ! ETHV_PEER_ADDRESS=$(ethv_get_default_gateway "$ethv_rtp_iface" 4); then
            ETHV_PEER_REASON="IPv4 route discovery failed on $ethv_rtp_iface, verify image-provided ip and route access"
            return 1
        fi
        if [ -z "$ETHV_PEER_ADDRESS" ]; then
            if ! ETHV_PEER_ADDRESS=$(ethv_get_default_gateway "$ethv_rtp_iface" 6); then
                ETHV_PEER_REASON="No IPv4 gateway and IPv6 route discovery failed on $ethv_rtp_iface, configure a route or supply --peer"
                return 1
            fi
            ETHV_PEER_FAMILY=6
        fi
        if [ -z "$ETHV_PEER_ADDRESS" ]; then
            ETHV_PEER_REASON="No IPv4 or IPv6 default gateway on $ethv_rtp_iface, provision DHCP/RA/static routing or supply --peer with a reachable hostname or IP address"
            return 1
        fi
    elif ! ethv_valid_peer_spec "$ethv_rtp_requested"; then
        ETHV_PEER_REASON="Invalid peer $ethv_rtp_requested, supply a unicast IPv4/IPv6 address or DNS hostname"
        return 1
    elif ethv_valid_unicast_ipv4 "$ethv_rtp_requested"; then
        ETHV_PEER_SOURCE="explicit-ipv4"
        ETHV_PEER_ADDRESS="$ethv_rtp_requested"
    elif ethv_valid_unicast_ipv6 "$ethv_rtp_requested"; then
        ETHV_PEER_SOURCE="explicit-ipv6"
        ETHV_PEER_FAMILY=6
        ETHV_PEER_ADDRESS="$ethv_rtp_requested"
    else
        ETHV_PEER_SOURCE="explicit-hostname"
        if ! command -v getent >/dev/null 2>&1; then
            ETHV_PEER_REASON="Hostname $ethv_rtp_requested requires image-provided getent and configured DNS/NSS, or supply --peer with an IP address"
            return 1
        fi
        for ethv_rtp_database in ahostsv4 hosts ahostsv6; do
            ethv_rtp_status=0
            LC_ALL=C run_with_managed_timeout 10 "$(dirname "$ethv_rtp_prefix")" peer-resolution \
                getent "$ethv_rtp_database" "$ethv_rtp_requested" \
                >"${ethv_rtp_prefix}_${ethv_rtp_database}.log" \
                2>"${ethv_rtp_prefix}_${ethv_rtp_database}.err" || ethv_rtp_status=$?
            if [ "$ethv_rtp_status" -eq 124 ]; then
                ETHV_PEER_REASON="Resolution of $ethv_rtp_requested timed out, verify DNS/NSS availability, artifact=${ethv_rtp_prefix}_${ethv_rtp_database}.err"
                return 1
            fi
            [ "$ethv_rtp_status" -eq 0 ] || continue
            ETHV_PEER_FAMILY=4
            ETHV_PEER_ADDRESS=$(awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1; exit }' \
                "${ethv_rtp_prefix}_${ethv_rtp_database}.log")
            if [ -z "$ETHV_PEER_ADDRESS" ] && [ "$ethv_rtp_database" != ahostsv4 ]; then
                ETHV_PEER_ADDRESS=$(awk '$1 ~ /:/ { print $1; exit }' \
                    "${ethv_rtp_prefix}_${ethv_rtp_database}.log")
                ETHV_PEER_FAMILY=6
            fi
            [ -z "$ETHV_PEER_ADDRESS" ] || break
        done
        if [ -z "$ETHV_PEER_ADDRESS" ]; then
            ETHV_PEER_REASON="No IP result for $ethv_rtp_requested, verify DHCP DNS registration or configured mDNS/NSS support, artifacts=${ethv_rtp_prefix}_*.log"
            return 1
        fi
    fi

    if [ "$ETHV_PEER_FAMILY" = 6 ]; then
        ethv_rtp_valid=0
        ethv_valid_unicast_ipv6 "$ETHV_PEER_ADDRESS" || ethv_rtp_valid=1
    else
        ethv_rtp_valid=0
        ethv_valid_unicast_ipv4 "$ETHV_PEER_ADDRESS" || ethv_rtp_valid=1
    fi
    if [ "$ethv_rtp_valid" -ne 0 ]; then
        ETHV_PEER_REASON="Peer $ETHV_PEER_ADDRESS is not a usable unicast IPv$ETHV_PEER_FAMILY address, supply a reachable external peer"
        return 1
    fi

    # Enumerate all addresses, including secondary addresses and other ports.
    # A local-address ping must never stand in for traffic through the fixture.
    if command -v ip >/dev/null 2>&1; then
        if ! ip "-$ETHV_PEER_FAMILY" -o addr show >"${ethv_rtp_prefix}_addresses.log" 2>"${ethv_rtp_prefix}_addresses.err"; then
            ETHV_PEER_REASON="Cannot inventory DUT IPv$ETHV_PEER_FAMILY addresses with ip, inspect ${ethv_rtp_prefix}_addresses.err"
            return 1
        fi
        ethv_rtp_local=$(awk '{ for (i = 1; i < NF; i++) if ($i == "inet" || $i == "inet6") { split($(i + 1), address, "/"); print address[1] } }' \
            "${ethv_rtp_prefix}_addresses.log")
        if ! awk -v iface="$ethv_rtp_iface" '
            $2 == iface && $0 !~ / tentative| dadfailed/ { found = 1 }
            END { exit !found }
        ' "${ethv_rtp_prefix}_addresses.log"; then
            ETHV_PEER_REASON="No ready IPv$ETHV_PEER_FAMILY address on $ethv_rtp_iface, configure DHCP/RA/static addressing and allow duplicate-address detection to complete"
            return 1
        fi
    elif [ "$ETHV_PEER_FAMILY" = 4 ] && command -v ifconfig >/dev/null 2>&1; then
        if ! LC_ALL=C ifconfig -a >"${ethv_rtp_prefix}_addresses.log" 2>"${ethv_rtp_prefix}_addresses.err"; then
            ETHV_PEER_REASON="Cannot inventory DUT IPv4 addresses with ifconfig, inspect ${ethv_rtp_prefix}_addresses.err"
            return 1
        fi
        ethv_rtp_local=$(awk '{ for (i = 1; i < NF; i++) if ($i == "inet") { value = $(i + 1); sub(/^addr:/, "", value); print value } }' \
            "${ethv_rtp_prefix}_addresses.log")
    else
        ETHV_PEER_REASON="Cannot inventory IPv$ETHV_PEER_FAMILY addresses, provision ip in the image, IPv4 also supports ifconfig"
        return 1
    fi
    if [ -z "$ethv_rtp_local" ]; then
        ETHV_PEER_REASON="No DUT IP addresses could be parsed, inspect ${ethv_rtp_prefix}_addresses.log and configure the selected interface"
        return 1
    fi
    ethv_rtp_compare="$ETHV_PEER_ADDRESS"
    if [ "$ETHV_PEER_FAMILY" = 6 ]; then
        ethv_rtp_compare=$(ethv_normalize_ipv6 "$ETHV_PEER_ADDRESS") || return 1
        ethv_rtp_local=$(printf '%s\n' "$ethv_rtp_local" | while IFS= read -r ethv_rtp_address; do
            ethv_normalize_ipv6 "$ethv_rtp_address" || exit 1
        done) || {
            ETHV_PEER_REASON="Invalid IPv6 address inventory, inspect ${ethv_rtp_prefix}_addresses.log"
            return 1
        }
    fi
    if printf '%s\n' "$ethv_rtp_local" | grep -Fxq "$ethv_rtp_compare"; then
        ETHV_PEER_REASON="Peer $ETHV_PEER_ADDRESS belongs to the DUT and cannot validate external QPS615 traffic, select a nonlocal peer"
        return 1
    fi
    ETHV_PEER_REASON="Selected $ETHV_PEER_ADDRESS from $ETHV_PEER_SOURCE for $ethv_rtp_iface"
    return 0
}

# ethv_get_carrier <interface>
#   Read the kernel carrier state for an interface.
#   stdout: 1, 0, or unknown when the attribute cannot be read.
#   return: 0 after printing a value.
ethv_get_carrier() {
    ethv_gc_iface="${1:-}"

    ethv_read_first_line "/sys/class/net/$ethv_gc_iface/carrier" 2>/dev/null \
        || printf '%s\n' "unknown"
}

# ethv_get_operstate <interface>
#   Read the kernel operational state for an interface.
#   stdout: sysfs operstate value, or unknown when unavailable.
#   return: 0 after printing a value.
ethv_get_operstate() {
    ethv_go_iface="${1:-}"

    ethv_read_first_line "/sys/class/net/$ethv_go_iface/operstate" 2>/dev/null \
        || printf '%s\n' "unknown"
}

# ethv_get_speed <interface>
#   Read negotiated speed from sysfs, falling back to ethtool.
#   stdout: integer speed in Mbit/s, or an empty line when unavailable.
#   return: 0 after printing the best-effort result.
ethv_get_speed() {
    ethv_gs_iface="${1:-}"
    ethv_gs_speed=""

    if [ -r "/sys/class/net/$ethv_gs_iface/speed" ]; then
        ethv_gs_speed="$(ethv_read_first_line "/sys/class/net/$ethv_gs_iface/speed" 2>/dev/null || true)"
    fi

    if ! ethv_is_uint "$ethv_gs_speed"; then
        ethv_gs_speed="$(
            ethtool "$ethv_gs_iface" 2>/dev/null \
                | sed -n 's/^[[:space:]]*Speed:[[:space:]]*\([0-9][0-9]*\)Mb\/s.*/\1/p' \
                | head -n 1
        )"
    fi

    printf '%s\n' "$ethv_gs_speed"
}

# ethv_get_duplex <interface>
#   Read negotiated duplex from sysfs, falling back to ethtool.
#   stdout: duplex value, or an empty line when unavailable.
#   return: 0 after printing the best-effort result.
ethv_get_duplex() {
    ethv_gdpx_iface="${1:-}"
    ethv_gdpx_duplex=""

    if [ -r "/sys/class/net/$ethv_gdpx_iface/duplex" ]; then
        ethv_gdpx_duplex="$(ethv_read_first_line "/sys/class/net/$ethv_gdpx_iface/duplex" 2>/dev/null || true)"
    fi

    if [ -z "$ethv_gdpx_duplex" ]; then
        ethv_gdpx_duplex="$(
            ethtool "$ethv_gdpx_iface" 2>/dev/null \
                | sed -n 's/^[[:space:]]*Duplex:[[:space:]]*//p' \
                | head -n 1
        )"
    fi

    printf '%s\n' "$ethv_gdpx_duplex"
}

# ethv_get_link_detected <interface>
#   Query ethtool's Link detected field.
#   stdout: normally yes or no, or no output when unsupported.
#   return: status of the ethtool and filtering pipeline.
ethv_get_link_detected() {
    ethv_gld_iface="${1:-}"

    ethtool "$ethv_gld_iface" 2>/dev/null \
        | sed -n 's/^[[:space:]]*Link detected:[[:space:]]*//p' \
        | head -n 1
}

# ethv_network_manager_active
#   Detect an active NetworkManager or systemd-networkd service.
#   stdout: none.
#   return: 0 when either manager is active, 1 otherwise.
ethv_network_manager_active() {
    command -v systemctl >/dev/null 2>&1 || return 1

    systemctl is-active --quiet NetworkManager 2>/dev/null \
        || systemctl is-active --quiet systemd-networkd 2>/dev/null
}

# ethv_wait_for_carrier <interface> [timeout-seconds]
#   Poll sysfs and optional ethtool link state until carrier is detected.
#   stdout: none.
#   return: 0 when carrier appears before timeout, 1 otherwise.
ethv_wait_for_carrier() {
    ethv_wfc_iface="${1:-}"
    ethv_wfc_timeout="${2:-10}"
    ethv_wfc_waited=0

    ethv_is_uint "$ethv_wfc_timeout" || ethv_wfc_timeout=10

    while [ "$ethv_wfc_waited" -le "$ethv_wfc_timeout" ]; do
        if [ "$(ethv_get_carrier "$ethv_wfc_iface")" = "1" ]; then
            return 0
        fi

        if command -v ethtool >/dev/null 2>&1 && \
           [ "$(ethv_get_link_detected "$ethv_wfc_iface")" = "yes" ]; then
            return 0
        fi

        [ "$ethv_wfc_waited" -lt "$ethv_wfc_timeout" ] || break
        sleep 1
        ethv_wfc_waited=$((ethv_wfc_waited + 1))
    done

    return 1
}

# ethv_wait_for_ipv4 <interface> [timeout-seconds]
#   Wait for a usable global IPv4 address using shared helpers and polling.
#   stdout: the first valid IPv4 address when found.
#   return: 0 when an address is found before timeout, 1 otherwise.
ethv_wait_for_ipv4() {
    ethv_wfi_iface="${1:-}"
    ethv_wfi_timeout="${2:-10}"
    ethv_wfi_waited=0

    ethv_is_uint "$ethv_wfi_timeout" || ethv_wfi_timeout=10

    if command -v wait_for_ip_address >/dev/null 2>&1; then
        ethv_wfi_ip="$(wait_for_ip_address "$ethv_wfi_iface" "$ethv_wfi_timeout" 2>/dev/null || true)"
        if ethv_valid_ipv4 "$ethv_wfi_ip"; then
            printf '%s\n' "$ethv_wfi_ip"
            return 0
        fi
    fi

    while [ "$ethv_wfi_waited" -le "$ethv_wfi_timeout" ]; do
        ethv_wfi_ip="$(ethv_get_ipv4 "$ethv_wfi_iface")"

        if ethv_valid_ipv4 "$ethv_wfi_ip"; then
            printf '%s\n' "$ethv_wfi_ip"
            return 0
        fi

        [ "$ethv_wfi_waited" -lt "$ethv_wfi_timeout" ] || break
        sleep 1
        ethv_wfi_waited=$((ethv_wfi_waited + 1))
    done

    return 1
}

# ethv_prepare_interface <interface> [link-timeout] [ip-timeout]
#   Bring an interface administratively up, recover link when helpers exist,
#   and obtain or wait for a usable IPv4 without fighting active managers.
#   stdout: none.
#   return: 0 when carrier and IPv4 are ready, 1 on interface bring-up failure,
#   2 when carrier is unavailable, or 3 when no valid IPv4 is obtained.
ethv_prepare_interface() {
    ethv_pi_iface="${1:-}"
    ethv_pi_link_timeout="${2:-10}"
    ethv_pi_ip_timeout="${3:-15}"

    [ -d "/sys/class/net/$ethv_pi_iface" ] || return 1

    ip link set dev "$ethv_pi_iface" up >/dev/null 2>&1 || return 1

    if ! ethv_wait_for_carrier "$ethv_pi_iface" 1; then
        if command -v ethEnsureLinkUpWithFallback >/dev/null 2>&1 && \
           command -v ethtool >/dev/null 2>&1; then
            ethEnsureLinkUpWithFallback "$ethv_pi_iface" "$ethv_pi_link_timeout" >/dev/null 2>&1 || true
        fi
    fi

    ethv_wait_for_carrier "$ethv_pi_iface" "$ethv_pi_link_timeout" || return 2

    ethv_pi_ip="$(ethv_get_ipv4 "$ethv_pi_iface")"
    if ethv_valid_ipv4 "$ethv_pi_ip"; then
        return 0
    fi

    if ethv_network_manager_active; then
        ethv_wait_for_ipv4 "$ethv_pi_iface" "$ethv_pi_ip_timeout" >/dev/null 2>&1 || true
    elif command -v try_dhcp_client_safe >/dev/null 2>&1; then
        try_dhcp_client_safe "$ethv_pi_iface" "$ethv_pi_ip_timeout" >/dev/null 2>&1 || true
    fi

    ethv_pi_ip="$(ethv_get_ipv4 "$ethv_pi_iface")"
    ethv_valid_ipv4 "$ethv_pi_ip" || return 3

    return 0
}

# ethv_get_default_gateway <interface> [4|6]
#   Find the first default gateway routed through an interface, IPv4 by default.
#   stdout: gateway address, or no output when no route exists.
#   return: 0 on successful discovery, nonzero on invalid family or route error.
ethv_get_default_gateway() {
    ethv_gdg_iface="${1:-}"

    ethv_gdg_family="${2:-4}"
    case "$ethv_gdg_family" in
        4|6)
            ;;
        *)
            return 1
            ;;
    esac
    ethv_gdg_routes=$(ip "-$ethv_gdg_family" route show default dev "$ethv_gdg_iface" 2>/dev/null) || return 1
    printf '%s\n' "$ethv_gdg_routes" \
        | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }'
}

# ethv_select_ping_target <interface> [requested-target]
#   Select an explicit target, then the interface gateway, then 8.8.8.8.
#   stdout: selected ping target.
#   return: 0 after printing the target.
ethv_select_ping_target() {
    ethv_spt_iface="${1:-}"
    ethv_spt_requested="${2:-}"
    ethv_spt_gateway=""

    if [ -n "$ethv_spt_requested" ]; then
        printf '%s\n' "$ethv_spt_requested"
        return 0
    fi

    ethv_spt_gateway="$(ethv_get_default_gateway "$ethv_spt_iface")"

    if [ -n "$ethv_spt_gateway" ]; then
        printf '%s\n' "$ethv_spt_gateway"
    else
        printf '%s\n' "8.8.8.8"
    fi
}

# ethv_ping_interface <interface> <target> [count] [wait-seconds] [4|6]
#   Run ping with traffic explicitly bound to the requested interface.
#   stdout/stderr: C-locale ping output for portable result parsing.
#   return: ping command exit status.
ethv_ping_interface() {
    ethv_pi_iface="${1:-}"
    ethv_pi_target="${2:-}"
    ethv_pi_count="${3:-4}"
    ethv_pi_wait="${4:-2}"
    ethv_pi_family="${5:-4}"

    case "$ethv_pi_family" in
        4|6)
            ;;
        *)
            return 2
            ;;
    esac

    if [ "$ethv_pi_family" = 6 ]; then
        if command -v ping6 >/dev/null 2>&1; then
            LC_ALL=C ping6 -n -I "$ethv_pi_iface" -c "$ethv_pi_count" -W "$ethv_pi_wait" "$ethv_pi_target"
        else
            LC_ALL=C ping -6 -n -I "$ethv_pi_iface" -c "$ethv_pi_count" -W "$ethv_pi_wait" "$ethv_pi_target"
        fi
        return $?
    fi

    LC_ALL=C ping -I "$ethv_pi_iface" \
        -c "$ethv_pi_count" \
        -W "$ethv_pi_wait" \
        "$ethv_pi_target"
}

# ethv_capture_driver_statistics <interface> <artifact-prefix>
#   Capture every unsigned counter reported by the DUT's ethtool -S output.
#   stdout: none. return: 0 parsed, 1 command/data failure, 2 optional capability
#   absent, 3 invalid input. Side effects: writes .log/.tsv artifacts and exports
#   ETHV_DRIVER_STATS_REASON. Never treats an unknown driver field as an error.
ethv_capture_driver_statistics() {
    ethv_cds_iface="${1:-}"
    ethv_cds_prefix="${2:-}"
    ETHV_DRIVER_STATS_REASON=""
    export ETHV_DRIVER_STATS_REASON
    if [ -z "$ethv_cds_iface" ] || [ -z "$ethv_cds_prefix" ]; then
        ETHV_DRIVER_STATS_REASON="Driver statistics require an interface and artifact prefix"
        return 3
    fi
    case "$ethv_cds_iface" in
        *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-]*)
            ETHV_DRIVER_STATS_REASON="Invalid interface name for driver-statistics capture"
            return 3
            ;;
    esac
    if ! mkdir -p "$(dirname "$ethv_cds_prefix")" ||
       ! {
           : >"$ethv_cds_prefix.tsv" &&
           : >"$ethv_cds_prefix.log"
       }; then
        ETHV_DRIVER_STATS_REASON="Cannot write driver-statistics artifacts at $ethv_cds_prefix, provide a writable results directory"
        return 1
    fi
    if ! command -v ethtool >/dev/null 2>&1; then
        ETHV_DRIVER_STATS_REASON="ethtool is not image-provided"
        return 2
    fi
    ethv_cds_status=0
    LC_ALL=C run_with_managed_timeout 10 "$(dirname "$ethv_cds_prefix")" driver-statistics \
        ethtool -S "$ethv_cds_iface" >"$ethv_cds_prefix.log" 2>&1 || ethv_cds_status=$?
    if [ "$ethv_cds_status" -ne 0 ]; then
        if [ "$ethv_cds_status" -ne 124 ] &&
           grep -Eiq 'operation not supported|not supported|no stats available' "$ethv_cds_prefix.log"; then
            ETHV_DRIVER_STATS_REASON="Driver statistics are not supported on $ethv_cds_iface"
            return 2
        fi
        ETHV_DRIVER_STATS_REASON="ethtool -S failed on $ethv_cds_iface with status $ethv_cds_status, inspect $ethv_cds_prefix.log"
        return 1
    fi
    ethv_cds_status=0
    awk '
        /^[[:space:]]*NIC statistics:[[:space:]]*$/ || /^[[:space:]]*$/ { next }
        {
            colon = index($0, ":")
            if (!colon) { bad=1; next }
            name = substr($0, 1, colon-1)
            value = substr($0, colon+1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (name == "" || name ~ /[[:cntrl:]]/ || value !~ /^[0-9]+$/ || seen[name]++) {
                bad=1
                next
            }
            printf "%s\t%s\n", name, value
            count++
        }
        END { if (bad) exit 1; if (!count) exit 2 }
    ' "$ethv_cds_prefix.log" >"$ethv_cds_prefix.tsv" || ethv_cds_status=$?
    if [ "$ethv_cds_status" -ne 0 ]; then
        : >"$ethv_cds_prefix.tsv"
        ETHV_DRIVER_STATS_REASON="No usable driver-statistics inventory on $ethv_cds_iface, inspect $ethv_cds_prefix.log"
        return "$ethv_cds_status"
    fi
    ETHV_DRIVER_STATS_REASON="Driver statistics captured from $ethv_cds_iface in $ethv_cds_prefix.tsv"
    return 0
}

# ethv_compare_driver_statistics <before-tsv> <after-tsv> <output-tsv>
#   Compare dynamically discovered counters by name, including additions and
#   removals. Values are compared as strings to preserve full 64-bit precision.
#   stdout: none. return: 0 compared, nonzero on invalid/unreadable evidence.
#   Side effects: writes name, before, after, and change type to output-tsv.
#   Exports ETHV_DRIVER_STATS_REASON when input/output evidence is unavailable.
#   Driver fields can be gauges or reset-on-read, so this is diagnostic only.
ethv_compare_driver_statistics() {
    if [ "$#" -ne 3 ] || [ ! -r "$1" ] || [ ! -r "$2" ]; then
        ETHV_DRIVER_STATS_REASON="Driver-counter comparison requires readable before/after inventories and an output path"
        export ETHV_DRIVER_STATS_REASON
        return 1
    fi
    if ! awk -F '\t' '
        FILENAME == ARGV[1] { before[$1]=$2; order[++count]=$1; next }
        {
            after[$1]=$2
            after_order[++after_count]=$1
        }
        END {
            for (i=1; i<=count; i++) {
                name=order[i]
                state="missing"
                value="unavailable"
                if (name in after) {
                    value=after[name]
                    state=("v" before[name] == "v" value) ? "unchanged" : "changed"
                }
                printf "%s\t%s\t%s\t%s\n", name, before[name], value, state
            }
            for (i=1; i<=after_count; i++) {
                name=after_order[i]
                if (!(name in before)) printf "%s\tunavailable\t%s\tadded\n", name, after[name]
            }
        }
    ' "$1" "$2" >"$3"; then
        ETHV_DRIVER_STATS_REASON="Cannot compare driver-counter inventories $1 and $2 into $3, check the retained files and output permissions"
        export ETHV_DRIVER_STATS_REASON
        return 1
    fi
    return 0
}

# ethv_get_counter <interface> <statistics-counter>
#   Read an unsigned standard network counter from sysfs.
#   stdout: counter value, or 0 when unavailable or malformed.
#   return: 0 after printing a value.
ethv_get_counter() {
    ethv_gc_iface="${1:-}"
    ethv_gc_counter="${2:-}"
    ethv_gc_file="/sys/class/net/$ethv_gc_iface/statistics/$ethv_gc_counter"

    if [ -r "$ethv_gc_file" ]; then
        ethv_gc_value="$(ethv_read_first_line "$ethv_gc_file" 2>/dev/null || true)"
        if ethv_is_uint "$ethv_gc_value"; then
            printf '%s\n' "$ethv_gc_value"
            return 0
        fi
    fi

    printf '%s\n' 0
}

# ethv_counter_available <interface> <statistics-counter>
#   Verify that a standard network counter is readable and contains an
#   unsigned decimal value. stdout: none. return: 0 when usable and 1 when the
#   interface, counter, or value is unavailable. Side effects: none.
ethv_counter_available() {
    ethv_ca_iface="${1:-}"
    ethv_ca_counter="${2:-}"
    ethv_ca_file="/sys/class/net/$ethv_ca_iface/statistics/$ethv_ca_counter"

    [ -n "$ethv_ca_iface" ] && [ -n "$ethv_ca_counter" ] || return 1
    [ -r "$ethv_ca_file" ] || return 1
    if ! ethv_ca_value=$(ethv_read_first_line "$ethv_ca_file" 2>/dev/null); then
        return 1
    fi
    ethv_is_uint "$ethv_ca_value"
}

# ethv_counters_available <interface> <statistics-counter>...
#   Verify a required set of standard network counters without emitting
#   stdout. return: 0 when every counter is usable, 1 when any counter is
#   unavailable, or 3 when no counter is supplied. Side effects: exports
#   ETHV_COUNTER_FAILURE with the first unavailable counter name.
ethv_counters_available() {
    ETHV_COUNTER_FAILURE=""
    export ETHV_COUNTER_FAILURE
    [ "$#" -gt 0 ] || return 3
    ethv_cas_iface="${1:-}"
    shift

    [ -n "$ethv_cas_iface" ] && [ "$#" -gt 0 ] || return 3
    for ethv_cas_counter in "$@"; do
        if ! ethv_counter_available "$ethv_cas_iface" "$ethv_cas_counter"; then
            ETHV_COUNTER_FAILURE="$ethv_cas_counter"
            export ETHV_COUNTER_FAILURE
            return 1
        fi
    done

    export ETHV_COUNTER_FAILURE
    return 0
}

# ethv_counter_delta <before> <after>
#   Calculate a monotonic unsigned counter delta.
#   stdout: after minus before, or -1 for invalid input or counter rollback.
#   return: awk status, normally 0.
ethv_counter_delta() {
    ethv_cd_before="${1:-0}"
    ethv_cd_after="${2:-0}"

    awk -v before="$ethv_cd_before" -v after="$ethv_cd_after" '
        BEGIN {
            if (before !~ /^[0-9]+$/ || after !~ /^[0-9]+$/ || after < before) {
                print -1
            } else {
                print after - before
            }
        }
    '
}

# ethv_get_ptp_clock <interface>
#   Query the PTP hardware clock index advertised by ethtool timestamping data.
#   stdout: clock index, none, -1, or an empty line when unavailable.
#   return: 0 after printing the best-effort result.
ethv_get_ptp_clock() {
    ethv_gpc_iface="${1:-}"
    ethv_gpc_clock=""

    if command -v ethtool >/dev/null 2>&1; then
        ethv_gpc_clock="$(
            ethtool -T "$ethv_gpc_iface" 2>/dev/null \
                | sed -n 's/^[[:space:]]*PTP Hardware Clock:[[:space:]]*//p' \
                | head -n 1
        )"
    fi

    printf '%s\n' "$ethv_gpc_clock"
}

# ethv_command_supports <command> <grep-pattern>
#   Search a command's --help output for a required option or feature pattern.
#   stdout: none.
#   return: 0 when the pattern is present, 1 when inputs or support are absent.
ethv_command_supports() {
    ethv_cs_command="${1:-}"
    ethv_cs_pattern="${2:-}"

    [ -n "$ethv_cs_command" ] || return 1
    [ -n "$ethv_cs_pattern" ] || return 1

    "$ethv_cs_command" --help 2>&1 \
        | grep -q -- "$ethv_cs_pattern"
}

# ethv_parse_iperf_mbps <iperf-log>
#   Parse receiver summary lines, normalize bit-rate units to Mbit/s, and use
#   the minimum aggregate result when SUM lines exist or minimum stream result.
#   stdout: normalized receiver throughput in Mbit/s.
#   return: 0 when a receiver result is parsed, nonzero when none is found.
ethv_parse_iperf_mbps() {
    ethv_pim_file="${1:-}"

    awk '
        function convert_to_mbps(value, unit) {
            if (unit == "bits/sec") {
                return value / 1000000
            }
            if (unit == "Kbits/sec") {
                return value / 1000
            }
            if (unit == "Gbits/sec") {
                return value * 1000
            }
            return value
        }
        $NF == "receiver" {
            value = ""

            for (field = 2; field <= NF; field++) {
                if ($field ~ /^(bits|Kbits|Mbits|Gbits)\/sec$/) {
                    value = convert_to_mbps($(field - 1) + 0, $field)
                    break
                }
            }

            if (value == "") {
                next
            }

            if (index($0, "[SUM]") > 0) {
                if (!sum_found || value < sum_minimum) {
                    sum_minimum = value
                }
                sum_found = 1
            } else {
                if (!stream_found || value < stream_minimum) {
                    stream_minimum = value
                }
                stream_found = 1
            }
        }
        END {
            if (sum_found) {
                print sum_minimum
            } else if (stream_found) {
                print stream_minimum
            } else {
                exit 1
            }
        }
    ' "$ethv_pim_file" 2>/dev/null
}

# ethv_float_ge <left> <right>
#   Compare two validated nonnegative decimal values.
#   stdout: none.
#   return: 0 when left is greater than or equal to right, 1 otherwise or when
#   either operand is malformed.
ethv_float_ge() {
    ethv_fg_left="${1:-0}"
    ethv_fg_right="${2:-0}"

    ethv_is_nonnegative_decimal "$ethv_fg_left" || return 1
    ethv_is_nonnegative_decimal "$ethv_fg_right" || return 1

    awk -v left="$ethv_fg_left" -v right="$ethv_fg_right" '
        BEGIN {
            exit !(left + 0 >= right + 0)
        }
    '
}
