#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Helpers for validating one suspend/resume cycle. Users: Pre_Suspend_Check
# and Resume_Check. Requires functestlib.sh and lib_system.sh.

# suspend_mode_is_valid MODE
# Returns 0 for a suspend-to-RAM variant the tests know: default, s2idle,
# shallow or deep.
suspend_mode_is_valid() {
    case "$1" in
        default|s2idle|shallow|deep)
            return 0
            ;;
    esac
    return 1
}

# suspend_state_mode_conflict STATE MODE
# Returns 0, and prints the reason, when a write of STATE to /sys/power/state
# cannot produce a cycle in MODE. "mem" uses whatever /sys/power/mem_sleep
# selects, so it matches every MODE; "freeze" is always s2idle and "standby"
# always shallow; "disk" is hibernation, not suspend to RAM.
suspend_state_mode_conflict() {
    ssmc_state="$1"
    ssmc_mode="$2"

    [ -n "$ssmc_state" ] && [ -n "$ssmc_mode" ] || return 1
    [ "$ssmc_mode" = "default" ] && [ "$ssmc_state" != "disk" ] && return 1

    case "$ssmc_state" in
        mem)
            return 1
            ;;
        freeze)
            [ "$ssmc_mode" = "s2idle" ] && return 1
            ;;
        standby)
            [ "$ssmc_mode" = "shallow" ] && return 1
            ;;
    esac
    printf '%s\n' "sleep state $ssmc_state cannot run a $ssmc_mode suspend"
    return 0
}

# suspend_uint VALUE
# Prints VALUE as a decimal number without leading zeros, so that shell
# arithmetic does not read it as octal. Returns 1, printing nothing, when
# VALUE is not a non-negative integer.
suspend_uint() {
    system_is_uint "$1" || return 1
    su_value=$(printf '%s\n' "$1" | sed 's/^0*//')
    printf '%s\n' "${su_value:-0}"
}

# suspend_regex_is_valid REGEX
# Returns 0 when grep -E accepts REGEX.
suspend_regex_is_valid() {
    printf '\n' | grep -qE -- "$1" 2>/dev/null
    [ "$?" -le 1 ]
}

# suspend_log_boundary SNAPSHOT
# Prints the printk timestamp of the newest record in SNAPSHOT, e.g.
# "40.126218". Records stamped later were logged after the snapshot was
# taken. Returns 1, printing nothing, when SNAPSHOT has no timestamps
# (CONFIG_PRINTK_TIME disabled, or a journal capture).
suspend_log_boundary() {
    slb_ts=$(sed -n 's/^\[ *\([0-9][0-9]*\.[0-9][0-9]*\)\].*/\1/p' "$1" 2>/dev/null | tail -n 1)
    [ -n "$slb_ts" ] || return 1
    printf '%s\n' "$slb_ts"
}

# suspend_log_slice SNAPSHOT BOUNDARY OUTPUT
# Writes the records of SNAPSHOT logged after BOUNDARY (a timestamp from
# suspend_log_boundary) to OUTPUT. Lines without a timestamp belong to the
# record above them. Returns:
#   0 - OUTPUT holds every record logged after BOUNDARY
#   2 - the oldest retained record is newer than BOUNDARY: the ring buffer
#       dropped records after the boundary, so OUTPUT may be incomplete
#   3 - SNAPSHOT has no timestamps; OUTPUT is empty
suspend_log_slice() {
    sls_snapshot="$1"
    sls_boundary="$2"
    sls_output="$3"

    : >"$sls_output"
    awk -v boundary="$sls_boundary" -v out="$sls_output" '
        match($0, /^\[ *[0-9]+\.[0-9]+\]/) {
            ts = substr($0, 2, RLENGTH - 2) + 0
            if (!seen) { first = ts; seen = 1 }
            after = (ts > boundary + 0)
        }
        seen && after { print > out }
        END {
            if (!seen) exit 3
            if (first > boundary + 0) exit 2
            exit 0
        }
    ' "$sls_snapshot"
}

# suspend_entry_mode LOG
# Prints the variant named by the last "PM: suspend entry (<mode>)" record in
# LOG: s2idle, shallow or deep. Returns 1 when LOG has no such record, e.g.
# on kernels older than v4.15, which do not log it.
suspend_entry_mode() {
    sem_mode=$(sed -n 's/.*PM: suspend entry (\([a-z0-9]*\)).*/\1/p' "$1" 2>/dev/null | tail -n 1)
    [ -n "$sem_mode" ] || return 1
    printf '%s\n' "$sem_mode"
}

# suspend_selected_mem_sleep
# Prints the variant /sys/power/mem_sleep selects, shown there in brackets,
# e.g. "deep" for "s2idle [deep]". Returns 1 when it cannot be read.
suspend_selected_mem_sleep() {
    ssms_mode=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/power/mem_sleep 2>/dev/null)
    [ -n "$ssms_mode" ] || return 1
    printf '%s\n' "$ssms_mode"
}

# suspend_mem_sleep_offers MODE
# Returns 0 when /sys/power/mem_sleep lists MODE, selected or not.
suspend_mem_sleep_offers() {
    tr -d '[]' </sys/power/mem_sleep 2>/dev/null | grep -qw -- "$1"
}
