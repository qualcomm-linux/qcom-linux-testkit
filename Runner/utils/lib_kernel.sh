#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Shared helpers for kernel sysfs/proc validation suites.
# POSIX sh only. Reuses functestlib.sh: is_unsigned_number, isroot,
# read_first_line, kernel_config_value, test_create_run_directory,
# scan_dmesg_errors, test_result_record.

# k_sysfs_read <path>
# Prints a trimmed first-line sysfs/proc value. Returns 1 if unreadable.
k_sysfs_read() {
    k_path="$1"
    if [ -z "$k_path" ] || [ ! -r "$k_path" ]; then
        return 1
    fi
    k_val="$(read_first_line "$k_path")"
    if [ -z "$k_val" ] && [ ! -s "$k_path" ]; then
        printf '%s\n' ""
        return 0
    fi
    printf '%s\n' "$k_val" | tr -d '\r' | sed 's/[[:space:]]*$//'
}

# k_count_lines
# Counts non-empty lines on stdin.
k_count_lines() {
    awk 'NF { n++ } END { print n + 0 }'
}

# k_config_state <CONFIG_NAME>
# Prints y, m, n, or missing. Returns 0 when a definite state is known.
k_config_state() {
    k_cfg="$1"
    [ -n "$k_cfg" ] || return 3
    k_line="$(kernel_config_value "$k_cfg" 2>/dev/null || true)"
    if [ -z "$k_line" ]; then
        printf '%s\n' "missing"
        return 1
    fi
    printf '%s\n' "${k_line#*=}"
    return 0
}

# k_config_enabled <CONFIG_NAME>
# Returns 0 if the option is y or m.
k_config_enabled() {
    k_state="$(k_config_state "$1")" || return 1
    case "$k_state" in
        y|m)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# k_record_readable <status-label> <path> [expect-uint]
# Records PASS/FAIL/SKIP for a readable sysfs node.
k_record_readable() {
    k_label="$1"
    k_node="$2"
    k_expect_uint="${3:-0}"

    if [ ! -e "$k_node" ]; then
        test_result_record "SKIP" "$k_label missing: $k_node"
        return 2
    fi
    if [ ! -r "$k_node" ]; then
        test_result_record "FAIL" "$k_label not readable: $k_node"
        return 1
    fi
    k_val="$(k_sysfs_read "$k_node")" || {
        test_result_record "FAIL" "$k_label read failed: $k_node"
        return 1
    }
    if [ "$k_expect_uint" = "1" ] && ! is_unsigned_number "$k_val"; then
        test_result_record "FAIL" "$k_label not an unsigned integer: $k_node='$k_val'"
        return 1
    fi
    test_result_record "PASS" "$k_label ok: $k_node='$k_val'"
    return 0
}

# k_watchdog_sysfs_dirs
# Prints /sys/class/watchdog/watchdogN directories, one per line.
k_watchdog_sysfs_dirs() {
    if [ ! -d /sys/class/watchdog ]; then
        return 1
    fi
    for k_wd in /sys/class/watchdog/watchdog*; do
        [ -d "$k_wd" ] || continue
        printf '%s\n' "$k_wd"
    done
}

# k_first_watchdog_sysfs
# Prints the first watchdog sysfs directory.
k_first_watchdog_sysfs() {
    k_watchdog_sysfs_dirs | awk 'NR==1 { print; exit }'
}

# k_watchdog_dev_for_sysfs <sysfs-dir>
# Prints the matching watchdog character device path.
k_watchdog_dev_for_sysfs() {
    k_dir="$1"
    k_name="$(basename "$k_dir")"
    if [ -e "/dev/$k_name" ]; then
        printf '%s\n' "/dev/$k_name"
        return 0
    fi
    if [ "$k_name" = "watchdog0" ] && [ -e /dev/watchdog ]; then
        printf '%s\n' "/dev/watchdog"
        return 0
    fi
    return 1
}

# k_cpu_sysfs_list
# Prints cpuN directory names under /sys/devices/system/cpu.
k_cpu_sysfs_list() {
    for k_cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$k_cpu_dir" ] || continue
        k_base="$(basename "$k_cpu_dir")"
        case "$k_base" in
            cpu*[!0-9]*)
                continue
                ;;
        esac
        printf '%s\n' "$k_base"
    done
}

# k_kernel_evidence_init [module-regex] [exclude-regex]
# Captures kernel logs with scan_dmesg_errors under results/<TESTNAME>/.
k_kernel_evidence_init() {
    k_mod="${1:-.}"
    k_excl="${2:-dummy regulator|supply [^ ]+ not found|using dummy regulator}"

    KERNEL_EVIDENCE_DIR=$(test_create_run_directory "$SCRIPT_DIR/results/$TESTNAME") || return 1
    export KERNEL_LOG_JOURNAL_FALLBACK=1
    scan_dmesg_errors "$KERNEL_EVIDENCE_DIR/kernel" "$k_mod" "$k_excl" || true
    KERNEL_DMESG_SNAPSHOT="$KERNEL_EVIDENCE_DIR/kernel/dmesg_snapshot.log"
    KERNEL_DMESG_ERRORS="$KERNEL_EVIDENCE_DIR/kernel/dmesg_errors.log"
    export KERNEL_EVIDENCE_DIR KERNEL_DMESG_SNAPSHOT KERNEL_DMESG_ERRORS
    log_info "Evidence: $KERNEL_EVIDENCE_DIR"
}

# k_dmesg_snapshot_match <extended-regex>
# Returns 0 if the captured dmesg snapshot matches the pattern.
k_dmesg_snapshot_match() {
    k_pat="$1"
    if [ -z "${KERNEL_DMESG_SNAPSHOT:-}" ] || [ ! -r "$KERNEL_DMESG_SNAPSHOT" ]; then
        return 1
    fi
    grep -Eiq "$k_pat" "$KERNEL_DMESG_SNAPSHOT"
}
