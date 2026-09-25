#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Emit LAVA testcase signals from a result file.
#
# LAVA parses TESTCASE signals from the serial console. On noisy systems,
# asynchronous kernel printk messages can be interleaved into userspace stdout
# and corrupt the signal line, for example:
#
# <<<LAVA_SIGNAL_TESTCASE TEST_CASE_ID=OpenCV [ 192.9] qcom,... RESULT=PASS>>>
#
# This script minimizes that risk by:
# - validating/sanitizing result-file content before emitting signals
# - lowering kernel console_loglevel for the critical section where the LAVA
# signal lines are printed, when /proc/sys/kernel/printk is writable
# - emitting each LAVA signal as one userspace printf operation
# - holding the quiet window open until the bytes have left the serial link
# - restoring the exact original printk settings afterwards
# - removing the temporary signal buffer explicitly after emission
#
# The drain delay matters: printf returns when the line reaches the tty
# buffer, not when the UART has sent it, so the quiet window must stay open
# until the signal has cleared the wire. The same delay before the first
# printf lets kernel output already queued on the UART finish first.
#
# Important: this does not suppress kernel logs during test execution. The
# printk loglevel is changed only around the LAVA signal emission, after the
# test has already completed and is reporting the result. Kernel messages
# generated during that short window remain available in the kernel ring buffer
# via dmesg.
#
# If /proc/sys/kernel/printk is not writable, the script does not change printk
# settings and falls back to the existing safe printf behavior. It intentionally
# does not use "dmesg -n" as a fallback because that cannot restore the exact
# original console loglevel.
#
# Tunables:
#   LAVA_SIGNAL_DRAIN_SECONDS - console drain delay, default 0.3, "0" disables

RESULT_FILE="${1:-}"
SIGNAL_FILE="${TMPDIR:-/tmp}/lava_signals_$$.log"
PRINTK_SAVED=""
PRINTK_CHANGED=0
LAVA_SIGNAL_DRAIN_SECONDS="${LAVA_SIGNAL_DRAIN_SECONDS:-0.3}"
# Reject anything but a plain, optionally fractional, number.
case "$LAVA_SIGNAL_DRAIN_SECONDS" in
    ''|.|*[!0-9.]*|*.*.*) LAVA_SIGNAL_DRAIN_SECONDS=0.3 ;;
esac

valid_result() {
    case "$1" in
        PASS|FAIL|SKIP|UNKNOWN)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

sanitize_testcase_id() {
    # LAVA testcase IDs should be token-safe. Keep only characters that do not
    # interfere with signal parsing.
    printf '%s' "$1" | tr -dc '[:alnum:]_.:-'
}

save_and_quiet_kernel_console() {
    PRINTK_SAVED=""
    PRINTK_CHANGED=0

    # /proc/sys/kernel/printk format:
    # console_loglevel default_message_loglevel minimum_console_loglevel default_console_loglevel
    #
    # Set only console_loglevel to 1 while preserving the remaining fields.
    # This keeps only KERN_EMERG on the console during the LAVA signal printf.
    if [ -r /proc/sys/kernel/printk ] && [ -w /proc/sys/kernel/printk ]; then
        PRINTK_SAVED="$(cat /proc/sys/kernel/printk 2>/dev/null || true)"

        if [ -n "$PRINTK_SAVED" ]; then
            quiet_printk="$(
                printf '%s\n' "$PRINTK_SAVED" |
                awk 'NF >= 4 { $1 = 1; print }'
            )"

            if [ -n "$quiet_printk" ]; then
                if printf '%s\n' "$quiet_printk" > /proc/sys/kernel/printk 2>/dev/null; then
                    PRINTK_CHANGED=1
                fi
            fi
        fi
    fi

    return 0
}

# Sleep so the quiet window covers the bytes still leaving the UART.
drain_kernel_console() {
    # No quiet window, nothing to protect.
    [ "$PRINTK_CHANGED" = "1" ] || return 0

    # Zero in any spelling (0, 0.0, 00, ...) disables the drain.
    case "$(printf '%s' "$LAVA_SIGNAL_DRAIN_SECONDS" | tr -d '0.')" in
        '') return 0 ;;
    esac

    # Whole-second fallback for shells without fractional sleep.
    sleep "$LAVA_SIGNAL_DRAIN_SECONDS" 2>/dev/null || sleep 1
}

restore_kernel_console() {
    if [ "$PRINTK_CHANGED" = "1" ] &&
       [ -n "$PRINTK_SAVED" ] &&
       [ -w /proc/sys/kernel/printk ]; then
        printf '%s\n' "$PRINTK_SAVED" > /proc/sys/kernel/printk 2>/dev/null || true
    fi

    PRINTK_SAVED=""
    PRINTK_CHANGED=0
}

cleanup() {
    restore_kernel_console
    rm -f "$SIGNAL_FILE"
}

trap cleanup EXIT HUP INT TERM

# Remove any stale same-PID file before use. The EXIT trap is kept as backup,
# and the file is also removed explicitly after signal emission.
rm -f "$SIGNAL_FILE"

if [ -z "$RESULT_FILE" ]; then
    echo "[WARNING] Result file argument missing" >&2
    exit 0
fi

# Collect validated signals in a buffer first.
#
# Expected result-file formats:
# <testcase> <result>
# <testcase> ... <result>
#
# The first field is testcase id and the last field is result.
if [ -f "$RESULT_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # Result files are token-based:
        # first token = testcase id
        # last token = result
        #
        # Intentional word splitting is used here to parse token fields.
        # shellcheck disable=SC2086
        set -- $line

        [ "$#" -gt 0 ] || continue

        case "$1" in
            \#*)
                continue
                ;;
        esac

        if [ "$#" -lt 2 ]; then
            echo "[WARNING] Ignoring malformed result line: $line" >&2
            continue
        fi

        testcase="$1"

        result=""
        for token in "$@"; do
            result="$token"
        done

        result="$(printf '%s' "$result" | tr '[:lower:]' '[:upper:]')"
        testcase_clean="$(sanitize_testcase_id "$testcase")"

        if [ -z "$testcase_clean" ]; then
            echo "[WARNING] Ignoring result line with invalid testcase id: $line" >&2
            continue
        fi

        if valid_result "$result"; then
            printf '<<<LAVA_SIGNAL_TESTCASE TEST_CASE_ID=%s RESULT=%s>>>\n' \
                "$testcase_clean" "$result" >> "$SIGNAL_FILE"
        else
            echo "[WARNING] Ignoring result line with invalid result: $line" >&2
        fi
    done < "$RESULT_FILE"
else
    echo "[WARNING] Result file missing: $RESULT_FILE" >&2
fi

# Quiet printk across the whole emission for one result file, draining
# before the first signal and after each one, so printk only resumes once
# the last signal has cleared the wire however many lines the file holds.
if [ -s "$SIGNAL_FILE" ]; then
    # Read first: the INT/TERM trap deletes SIGNAL_FILE without exiting,
    # and the emission must survive that.
    signal_lines="$(cat "$SIGNAL_FILE")"

    save_and_quiet_kernel_console
    drain_kernel_console

    printf '%s\n' "$signal_lines" | while IFS= read -r signal_line; do
        [ -n "$signal_line" ] || continue

        printf '\n%s\n\n' "$signal_line"
        drain_kernel_console
    done

    restore_kernel_console
fi

# Explicit cleanup after signal emission. The trap remains as backup for early
# exits or interruptions.
rm -f "$SIGNAL_FILE"
