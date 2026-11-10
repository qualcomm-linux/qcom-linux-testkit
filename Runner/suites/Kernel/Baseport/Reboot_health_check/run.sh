#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# ---------- Repo env + helpers ----------
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
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Reboot_health_check"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

log_info "Boot context: kernel=$(uname -r), architecture=$(uname -m)"
if [ -r /proc/1/comm ]; then
    log_info "PID 1: $(cat /proc/1/comm)"
fi
if [ -r /proc/mounts ]; then
    awk '$2 == "/" {print "[BOOT] root source=" $1 " type=" $3 " options=" $4}' /proc/mounts
fi
if [ "$(id -u)" = 0 ]; then
    test_result_record PASS "System booted and provided a root shell"
else
    test_result_record FAIL "Root shell unavailable, configure the LAVA login action to obtain root"
fi
# Reboot and boot retry policy belongs to the LAVA job, never to this check.
test_result_finish
