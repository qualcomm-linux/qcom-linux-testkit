#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTNAME="core_auth"
# ---- Source init_env & tools ----
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then INIT_ENV="$SEARCH/init_env"; break; fi
  SEARCH=$(dirname "$SEARCH")
done
[ -z "$INIT_ENV" ] && echo "[ERROR] init_env not found" >&2 && exit 1
# shellcheck disable=SC1090
[ -z "$__INIT_ENV_LOADED" ] && . "$INIT_ENV"
# shellcheck disable=SC1090,SC1091
. $TOOLS/functestlib.sh

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Found $TESTNAME Testcase----------------------------"


# Print the start of the test case
echo "-----------------------------------------------------------------------------------------"
echo "-------------------Starting $TESTNAME Testcase----------------------------"

# Print a message to indicate checking for dependency binary
echo "Checking if dependency binary is available"

# Check if core_auth is available in system PATH first
if command -v core_auth >/dev/null 2>&1; then
	echo "Found core_auth in system PATH"
	CORE_AUTH_CMD="core_auth"
else
	# Search for core_auth binary using find 
	echo "Searching for core_auth binary..."
	CORE_AUTH_CMD=""
	
	# Search in /usr directory tree for core_auth binary
	if command -v find >/dev/null 2>&1; then
		CORE_AUTH_CMD=$(find /usr -type f -name "core_auth" -executable 2>/dev/null | head -n1)
	fi
	
	if [ -n "$CORE_AUTH_CMD" ] && [ -x "$CORE_AUTH_CMD" ]; then
		echo "Found core_auth at: $CORE_AUTH_CMD"
	else
		echo "core_auth binary not found"
		log_fail "$TESTNAME : core_auth binary not available"
		log_info "Please install IGT (Intel Graphics Tools) package"
		echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
		exit 1
	fi
fi

#kill weston 
echo "killing Weston before running core_auth"
pkill weston
sleep 5 
echo "-----------------------------------------------------------------------------------------"


# Run the core_auth test and log the output to a file (using relative path for log)
$CORE_AUTH_CMD 2>&1 | tee $test_path/core_auth_log.txt

# Check the log file for the string "SUCCESS" to determine if the test passed
if grep -q "SUCCESS" $test_path/core_auth_log.txt; then
# If "SUCCESS" is found, print that the test passe
	log_pass "$TESTNAME : Test Passed"
	echo "$TESTNAME PASS" > $test_path/$TESTNAME.res

else
	# If "SUCCESS" is not found, print that the test failed
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi

# Print the completion of the test case
echo "-------------------Completed $TESTNAME Testcase----------------------------"
