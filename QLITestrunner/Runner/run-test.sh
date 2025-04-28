#!/bin/sh
# Import test suite definitions
source /var/Runner/init_env

#import test functions library
source $TOOLS/functestlib.sh


# Find test case path by name
find_test_case_by_name() {
    local test_name="$1"
    find /var/Runner/suites -type d -iname "$test_name" 2>/dev/null
}

# Execute a test case
execute_test_case() {
    local test_path="$1"
    if [ -d "$test_path" ]; then
        run_script="$test_path/run.sh"
        if [ -f "$run_script" ]; then
            log "Executing test case: $test_path"
            sh "$run_script" 2>&1 
            # if [ $? -eq 0 ]; then
            #     log "Test case $test_path passed."
            # else
            #     log "Test case $test_path failed."
            # fi
        else
            log "No run.sh found in $test_path"
        fi
    else
        log "Test case directory not found: $test_path"
    fi
}

# Function to run a specific test case by name
run_specific_test_by_name() {
    local test_name="$1"
    test_path=$(find_test_case_by_name "$test_name")
    if [ -z "$test_path" ]; then
        log "Test case with name $test_name not found."
    else
        execute_test_case "$test_path"
    fi
}

# Main script logic
if [ "$#" -eq 0 ]; then
    log "Usage: $0 [all | <testcase_name>]"
    exit 1
fi


run_specific_test_by_name "$1"