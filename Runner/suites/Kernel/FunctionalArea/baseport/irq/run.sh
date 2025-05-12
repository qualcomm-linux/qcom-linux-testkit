# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="irq"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
# Function to get the timer count
get_timer_count() {
    cat /proc/interrupts | grep arch_timer
}

# Get the initial timer count
log_info "Initial timer count:"
initial_count=$(get_timer_count)
log_info "$initial_count"

# Wait for 20 seconds
sleep 20

# Get the timer count after 20 secs
log_info "Timer count after 20 secs:"
final_count=$(get_timer_count)
log_info "$final_count"

# Compare the initial and final counts
log_info "Comparing timer counts:"
echo "$initial_count" | while read -r line; do
    cpu=$(echo "$line" | awk '{print $1}')
    initial_values=$(echo "$line" | awk '{for(i=2;i<=9;i++) print $i}')
    final_values=$(echo "$final_count" | grep "$cpu" | awk '{for(i=2;i<=9;i++) print $i}')
    
    fail_test=false
    initial_values_list=$(echo "$initial_values" | tr ' ' '\n')
    final_values_list=$(echo "$final_values" | tr ' ' '\n')
    
    i=0
    echo "$initial_values_list" | while read -r initial_value; do
        final_value=$(echo "$final_values_list" | sed -n "$((i+1))p")
        if [ "$initial_value" -lt "$final_value" ]; then
            log_pass "CPU $i: Timer count has incremented. Test PASSED"
        else
            log_fail "CPU $i: Timer count has not incremented. Test FAILED"
            fail_test=true
        fi
        i=$((i+1))
    done

    if [ "$fail_test" = false ]; then
        log_pass "$TESTNAME : Test Passed"
        echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
    else
        log_fail "$TESTNAME : Test Failed"
        echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    fi
done
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
