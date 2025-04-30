#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="qcrypto"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

cp -r /kcapi/kcapi-convience /usr/bin/

chmod 777 /usr/bin/kcapi-convience

/usr/bin/kcapi-convience

echo $?


if [ $? -eq 0 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"