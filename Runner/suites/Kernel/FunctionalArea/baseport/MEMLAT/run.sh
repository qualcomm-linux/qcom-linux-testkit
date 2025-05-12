#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env
TESTNAME="MEMLAT"
#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
test_bin_path=$(find_test_case_bin_by_name "lat_mem_rd")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

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
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"