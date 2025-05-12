#!/bin/bash
# Import test suite definitions
/var/Runner/init_env
TESTNAME="USBHost"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Running USB Host enumeration test"

# Check if lsusb is installed
if ! command -v lsusb &> /dev/null; then
    echo "Error: 'lsusb' command not found. Please install 'usbutils' package."
    exit 1
fi

# Run lsusb and capture output
usb_output=$(lsusb)
device_count=$(echo "$usb_output" | wc -l)

# Filter out USB hubs
non_hub_count=$(echo "$usb_output" | grep -vi "hub" | wc -l)

echo "Enumerated USB devices..."
echo "$usb_output"

# Check if any USB devices were found
if [ "$device_count" -eq 0 ]; then
    log_fail "$TESTNAME : Test Failed - No USB devices found."
    echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
elif [ "$non_hub_count" -eq 0 ]; then
    log_fail "$TESTNAME : Test Failed - Only USB hubs detected, no functional USB devices."
    echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
else
    log_pass "$TESTNAME : Test Passed - $non_hub_count non-hub USB device(s) found."
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"