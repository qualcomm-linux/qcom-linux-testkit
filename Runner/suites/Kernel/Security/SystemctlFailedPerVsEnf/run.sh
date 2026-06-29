#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Robustly find and source init_env
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

TESTNAME="SystemctlFailedPerVsEnf"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034

RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"

FS_Permissive="./failedServices_permissive.txt"
rm -f "$FS_Permissive"
echo 0 > "$FS_Permissive"

FS_Enforcing="./failedServices_enforcing.txt"
rm -f "$FS_Enforcing"
echo 0 > "$FS_Enforcing"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies getenforce setenforce systemctl grep echo awk; then
    log_skip "$TESTNAME SKIP: missing dependencies"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

default_mode=$(getenforce)
log_info "Default Selinux Mode is $default_mode"

if echo "$default_mode" | grep -qiE "disabled"; then
    log_info "SELinux is $default_mode. Testcase Unsupported."
    log_skip "$TESTNAME SKIP: selinux disabled"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 1
fi

# Get results for permissive mode
setenforce 0
failedServices=$(systemctl list-units --state failed)
echo "$failedServices" | awk '/^\*/ {print $2}' > "$FS_Permissive"

# Get failed service count
count=$(echo "$failedServices" | grep "loaded units listed")
echo "Systemctl list-units failed in Permissive mode: "
echo "$count"

# Get results for enforcing mode
setenforce 1
failedServices=$(systemctl list-units --state failed)
echo "$failedServices" | awk '/^\*/ {print $2}' > "$FS_Enforcing"

# Get failed service count
count=$(echo "$failedServices" | grep "loaded units listed")
echo "Systemctl list-units failed in Enforcing mode: "
echo "$count"

# Compare both lists

log_info "Failed for Enforcing but loaded in Permissive:"
diff1=$(grep -Fxv -f "$FS_Permissive" "$FS_Enforcing")
log_info "$diff1"

log_info "Failed for Permissive but loaded in Enforcing:"
diff2=$(grep -Fxv -f "$FS_Enforcing" "$FS_Permissive")
log_info "$diff2"


if [ -z "$diff1" ] && [ -z "$diff2" ]; then
  log_pass "$TESTNAME : PASS"
  echo "$TESTNAME PASS" > "$RES_FILE"
else
  log_fail "$TESTNAME : FAIL"
  echo "$TESTNAME FAIL" > "$RES_FILE"
fi

# Set back to default
if echo "$default_mode" | grep -iq "^permissive$"; then
  setenforce 0
else
  setenforce 1
fi