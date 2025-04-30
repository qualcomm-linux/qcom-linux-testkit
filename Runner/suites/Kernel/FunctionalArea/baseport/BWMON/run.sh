#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="BWMON"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Fetching te interconnect summary"
extract_votes() {
  cat /sys/kernel/debug/interconnect/interconnect_summary | grep -i pmu | awk '{print $NF}'
}
log_info "Initial vote check:"
sleep 5
log_info "Initial vote check:"
initial_votes=$(extract_votes)
log_info "$initial_votes"
log_info "$initial_votes"

log_info "Running bw_mem tool..." 
/var/common/bins/bw_mem 4000000000 frd &

sleep 2

log_info "Vote check while bw_mem tool is running:" 
final_votes=$(extract_votes)
log_info "$final_votes"

wait

log_info "Comparing votes"


incremented=true
for i in $(seq 2 $(echo "$initial_votes" | wc -l)); do
  initial_vote=$(echo "$initial_votes" | sed -n "${i}p")
  final_vote=$(echo "$final_votes" | sed -n "${i}p")
  if [ "$final_vote" -le "$initial_vote" ]; then
    incremented=false
    log_pass "Vote did not increment for row $i: initial=$initial_vote, final=$final_vote"
  else
    log_pass "Vote incremented for row $i: initial=$initial_vote, final=$final_vote"
  fi
done

if $incremented; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
