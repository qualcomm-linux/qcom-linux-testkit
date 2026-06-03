#!/bin/sh
# =============================================================================
# Test Script : hello_world.sh
# Description : A minimal LAVA test case that prints "Hello World"
#               and reports a PASS result back to LAVA.
#
# HOW LAVA READS RESULTS:
#   LAVA watches stdout for lines in the format:
#       <result> <test-case-id>
#   Where <result> is one of: pass | fail | skip | unknown
# =============================================================================

# ---------------------------------------------------------
# STEP 1: Print Hello World
#   This is the actual "work" the test does on the DUT.
#   In real tests, this would be replaced with driver probes,
#   kernel module checks, dmesg parsing, etc.
# ---------------------------------------------------------
echo "Hello World from LAVA!"

# ---------------------------------------------------------
# STEP 2: Capture the exit status of the last command
#   $? holds the exit code of the previous command.
#   0 = success, non-zero = failure.
# ---------------------------------------------------------
RESULT=$?

# ---------------------------------------------------------
# STEP 3: Report result back to LAVA
#   LAVA's test runner (lava-test-shell) monitors stdout
#   for lines matching: <pass|fail> <test-case-name>
#   This is how LAVA knows whether your test passed or failed.
# ---------------------------------------------------------
if [ $RESULT -eq 0 ]; then
    echo "pass hello-world-print"
else
    echo "fail hello-world-print"
fi

# ---------------------------------------------------------
# STEP 4: Exit with the same code
#   Good practice — ensures the shell exits cleanly,
#   and LAVA can detect abnormal script termination.
# ---------------------------------------------------------
exit $RESULT

