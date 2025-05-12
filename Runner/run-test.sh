#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env

#import test functions library
. $TOOLS/functestlib.sh


# Find test case path by name
find_test_case_by_name() {
    # local test_name="$1"
    # dir= "."
    # Check if the file is a directory
  if [ -d "$1" ]; then
    # Get the directory name
    dir_name_in_dir=${1##*/}

    # Check if the directory name matches the user input (ignoring case)
    if [ "${dir_name_in_dir,,}" = "$test_name" ]; then
      # Get the absolute path of the directory
      abs_path=$(readlink -f "$1")
      echo "$abs_path"  
      # Check if the run.sh file is present in the absolute path (ignoring case)
      # if [ -f "$abs_path/run.sh" ]; then
        # Print the absolute path of run.sh
        # echo "Absolute path of run.sh: $abs_path/run.sh"
      # fi
    fi
  fi

  # Recursively search for the directory in the subdirectory
  for file in "$1"/*; do
    # Check if the file is a directory
    if [ -d "$file" ]; then
      # Recursively search for the directory in the subdirectory
      find_test_case_by_name "$file"
    fi
  done
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
    test_name="$1"
    test_name=${test_name,,}
    test_path=$(find_test_case_by_name ".")
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