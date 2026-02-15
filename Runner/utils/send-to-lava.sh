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

# Emit signals in one clean atomic flush
if [ -s "$SIGNAL_FILE" ]; then
    sleep 1  # small delay to let dmesg calm
    cat "$SIGNAL_FILE"
fi

# Cleanup
rm -f "$SIGNAL_FILE"
