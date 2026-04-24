# shellcheck disable=SC2148
# Intentionally not defining shell.

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Detect Android userland
ANDROID_PATH=/system/build.prop
if [ -f $ANDROID_PATH ]; then
    # shellcheck disable=SC2209,SC2034
    SHELL_CMD=sh
else
    # shellcheck disable=SC2209,SC2034
    SHELL_CMD=bash
fi

pidkiller()
{
  kill -9 "$1" >/dev/null 2>&1
}
