#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

TESTNAME="MEMLAT"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

test_bin_path=$(find_test_case_bin_by_name "lat_mem_rd")
log_info "Checking if dependency binary is available"
check_dependencies lat_mem_rd

extract_votes() {
  cat /sys/kernel/debug/interconnect/interconnect_summary | grep -i cpu | awk '{print $NF}'
}

log_info "Initial vote check:"
initial_votes=$(extract_votes)
log_info "$initial_votes"


log_info "Running lat_mem_rd tool..."
$test_bin_path -t 128MB 16 &

sleep 30
log_info "Vote check while bw_mem tool is running:"
final_votes=$(extract_votes)
log_info "$final_votes"

wait

log_info "Comparing votes..."

incremented=true
# shellcheck disable=SC2046
for i in $(seq 1 $(echo "$initial_votes" | wc -l)); do
  initial_vote=$(echo "$initial_votes" | sed -n "${i}p")
  final_vote=$(echo "$final_votes" | sed -n "${i}p")
  if [ "$final_vote" -le "$initial_vote" ]; then
    incremented=false
    log_pass "Vote did not increment for row $i: initial=$initial_vote, final=$final_vote"
  else
    log_fail "Vote incremented for row $i: initial=$initial_vote, final=$final_vote"
  fi
done

if $incremented; then
  log_pass "TEST PASSED."
else
  log_fail "TEST FAILED."
fi
if $incremented; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
