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

TESTNAME="ToggleSetenforce"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034

RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies getenforce setenforce; then
  log_skip "$TESTNAME SKIP: missing dependencies"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

default_mode=$(getenforce)
log_info "Default selinux mode: $default_mode"

# Set SELinux to permissive
setenforce 0
mode1=$(getenforce)

if [ "$mode1" != "permissive" ] && [ "$mode1" != "Permissive" ]; then
  log_info "setenforce 0 failed. Expected Permissive, got $mode1"
  log_fail "$TESTNAME : FAIL"
  echo "$TESTNAME FAIL" > "$RES_FILE"
  exit 1
fi
log_info "setenforce 0 successful: $mode1"

# Set SELinux back to enforcing
setenforce 1
mode2=$(getenforce)

if [ "$mode2" != "enforcing" ] && [ "$mode2" != "Enforcing" ]; then
  log_info "setenforce 1 failed. Expected Enforcing, got $mode2"
  log_fail "$TESTNAME : FAIL"
  echo "$TESTNAME FAIL" > "$RES_FILE"
  exit 1
fi
log_info "setenforce 1 successful: $mode2"

log_pass "$TESTNAME : PASS"
echo "$TESTNAME PASS" > "$RES_FILE"

# Set back to default
if echo "$default_mode" | grep -iq "^permissive$"; then
  setenforce 0
else
  setenforce 1
fi









