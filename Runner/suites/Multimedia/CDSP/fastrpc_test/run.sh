#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# --------- Robustly source init_env and functestlib.sh ----------
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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# ---------------------------------------------------------------

TESTNAME="fastrpc_test"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

RESULT_FILE="$TESTNAME.res"
log_info "Checking if dependency binary is available"
export PATH=$PATH:/usr/share/bin
check_dependencies fastrpc_test grep stdbuf

# Step 1: Read the SoC ID
soc=$(cat /sys/devices/soc0/soc_id)

# Step 2: Determine the architecture based on SoC ID
case "$soc" in
  498)
    architecture="v68"
    ;;
  676|534)
    architecture="v73"
    ;;
  606)
    architecture="v75"
    ;;
  *)
    echo "Unknown SoC ID: $soc"
    exit 1
    ;;
esac

# Step 3: Execute the command with the architecture
output=$(stdbuf -oL -eL sh -c "cd /usr/share/bin && ./fastrpc_test -d 3 -U 1 -t linux -a \"$architecture\"")

echo $output

# Check if the output contains the desired string
if echo "$output" | grep -q "All tests completed successfully"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : PASS" > "$RESULT_FILE"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME : FAIL" > "$RESULT_FILE"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"