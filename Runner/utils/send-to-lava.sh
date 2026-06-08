#!/bin/sh

#Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#SPDX-License-Identifier: BSD-3-Clause
RESULT_FILE="$1"
SIGNAL_FILE="/tmp/lava_signals_$$.log"

valid_result() {
    case "$1" in
        PASS|FAIL|SKIP|UNKNOWN) return 0 ;;
        *) return 1 ;;
    esac
}

# Collect signals in buffer
if [ -f "$RESULT_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        testcase=$(echo "$line" | awk '{print $1}')
        result=$(echo "$line" | awk '{print $NF}' | tr '[:lower:]' '[:upper:]')
        testcase_clean=$(echo "$testcase" | tr -dc '[:alnum:]_-')

        if valid_result "$result"; then
            printf '<<<LAVA_SIGNAL_TESTCASE TEST_CASE_ID=%s RESULT=%s>>>\n' \
                "$testcase_clean" "$result" >> "$SIGNAL_FILE"
        fi
    done < "$RESULT_FILE"
else
    echo "[WARNING] Result file missing: $RESULT_FILE" >&2
fi

# Emit signals using shell builtin printf.
# Do not use cat. Do not touch printk/dmesg.
if [ -s "$SIGNAL_FILE" ]; then
    while IFS= read -r signal_line || [ -n "$signal_line" ]; do
        [ -n "$signal_line" ] || continue

        # Blank lines help if previous console output did not end cleanly.
        # The signal itself is still emitted only once.
        printf '\n%s\n\n' "$signal_line"
    done < "$SIGNAL_FILE"
fi

# Cleanup
rm -f "$SIGNAL_FILE"
