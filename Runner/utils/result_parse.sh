#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
echo "Current working directory is $PWD"

find . -type f -name "*.res" 2>/dev/null | while IFS= read -r res_file; do
    echo "$res_file"
    if [ -f "$res_file" ]; then
        while IFS= read -r line; do
            # Skip empty lines
            [ -z "$line" ] && continue

            # Split line into whitespace-separated fields
            # shellcheck disable=SC2086
            set -- $line
            tc_name=$1
            result=$2

            # Report each test case result to LAVA
            if [ -n "$tc_name" ] && [ -n "$result" ]; then
                if [ "$result" = "FAIL" ]; then
                    exit 1
                fi
            else
                echo "Warning: Skipping malformed line: $line"
            fi
        done < "$res_file"
    fi
done
