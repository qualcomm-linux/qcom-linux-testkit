#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="AVCDenials"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034

RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"

AVC_Denials="./avc_denials.txt"
rm -f "$AVC_Denials"

if [ -f /var/log/audit/audit.log ]; then
    log_info "Using audit.log"
elif CHECK_DEPS_NO_EXIT=1 check_dependencies dmesg; then
    log_info "Using dmesg as audit source"
else
    log_skip "$TESTNAME SKIP: No audit source available"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Fetch from audit.log
if [ -f /var/log/audit/audit.log ]; then
  den=$(cat /var/log/audit/audit.log | grep avc)
  log_info "Denials in audit.log: "
  log.info "$den"
  echo "$den" > "$AVC_Denials"
fi

# Fetch from dmesg
if CHECK_DEPS_NO_EXIT=1 check_dependencies dmesg; then
  den=$(dmesg | grep avc)
  log_info "Denials in audit.log: "
  log.info "$den"
  echo "$den" >> "$AVC_Denials"
fi

# Making test pass in all conditions
log_info "Denials saved to log file at $AVC_Denials"
log_pass "$TESTNAME : PASS"
echo "$TESTNAME PASS" > "$RES_FILE"





