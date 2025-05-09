#!/bin/sh

# GLMark2 Validator Script (Yocto-Compatible)
# No arguments expected. This script auto-detects and validates onscreen/offscreen rendering

. $(pwd)/init_env
TESTNAME="GLMark2"

# Import test functions
. $TOOLS/functestlib.sh

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Color codes
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
NC="\e[0m" # No Color

# Validate if glmark2 binary is available
if ! command -v /usr/bin/glmark2-es2-wayland &> /dev/null; then
    echo -e "${RED}[ERROR]${NC} glmark2-es2-wayland not found in system path."
    log_fail "$TESTNAME : glmark2-es2-wayland binary not found"
    echo "$TESTNAME SKIP " > "$test_path/$TESTNAME.res"
    exit 1
fi

# Prepare environment
. /etc/profile
export XDG_RUNTIME_DIR=/dev/socket/weston
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
export WAYLAND_DISPLAY=wayland-1

mkdir -p results/glmark2
chmod -R 755 results/glmark2

# Start logs
dmesg -C
tail -f /var/log/syslog > results/glmark2/syslog_log.txt &
SYSLOG_PID=$!
dmesg -w > results/glmark2/dmesg_log.txt &
DMESG_PID=$!

overall_pass=true
run_glmark2_test() {
    local mode="$1"
    local result_file="results/glmark2/${mode}.txt"

    echo -e "${YELLOW}Running $mode...${NC}"
    if [[ "$mode" == "onscreen" ]]; then
        /usr/bin/glmark2-es2-wayland --data-path /usr/bin/glmark2 2>&1 | tee "$result_file"
    else
        /usr/bin/glmark2-es2-wayland --off-screen --data-path /usr/bin/glmark2 2>&1 | tee "$result_file"
    fi

    if grep -q 'glmark2 Score' "$result_file"; then
        echo -e "${GREEN}[PASS]${NC} $mode score detected."
    else
        echo -e "${RED}[FAIL]${NC} $mode did not produce a score."
        overall_pass=false
    fi
}

# Execute all variants
run_glmark2_test "onscreen" "onscreen_default"
run_glmark2_test "offscreen" "offscreen_default"

# Cleanup
kill $DMESG_PID
kill $SYSLOG_PID

# Final status
log_info ""
log_info "=== Overall GLMark2 Validation Result ==="
if $overall_pass; then
    echo -e "${GREEN}[OVERALL PASS]${NC} GLMark2 rendering validated."
    log_pass "$TESTNAME PASS"
    echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
    exit 0
else
    echo -e "${RED}[OVERALL FAIL]${NC} One or more GLMark2 tests failed."
    log_fail "$TESTNAME  FAIL"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"