#!/bin/sh
 
#Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#SPDX-License-Identifier: BSD-3-Clause-Clear
 
# Source init_env and functestlib.sh
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
 
# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
 
TESTNAME="Ethernet"
test_path=$(find_test_case_by_name "$TESTNAME") || {
    log_fail "$TESTNAME : Test directory not found."
    echo "FAIL $TESTNAME" > "./$TESTNAME.res"
    exit 1
}
 
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"
 
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
 
check_dependencies ip ping
 
IFACE="eth0"
RETRIES=3
SLEEP_SEC=3
 
# Check interface existence
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    log_fail "Ethernet interface $IFACE not found"
    echo "FAIL $TESTNAME" > "$res_file"
    exit 1
fi
 
# Bring up interface with retries
log_info "Ensuring $IFACE is UP..."
i=0
while [ $i -lt $RETRIES ]; do
    ip link set "$IFACE" up
    sleep "$SLEEP_SEC"
    if ip link show "$IFACE" | grep -q "state UP"; then
        log_info "$IFACE is UP"
        break
    fi
    log_warn "$IFACE is still DOWN (attempt $((i + 1))/$RETRIES)..."
    i=$((i + 1))
done
 
if [ $i -eq $RETRIES ]; then
    log_fail "Failed to bring up $IFACE after $RETRIES attempts"
    echo "FAIL $TESTNAME" > "$res_file"
    exit 1
fi
 
# Ping test with retries
log_info "Running ping test to 8.8.8.8 via $IFACE..."
i=0
while [ $i -lt $RETRIES ]; do
    if ping -I "$IFACE" -c 4 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_pass "Ethernet connectivity verified via ping"
        echo "PASS $TESTNAME" > "$res_file"
        exit 0
    fi
    log_warn "Ping failed (attempt $((i + 1))/$RETRIES)... retrying"
    sleep "$SLEEP_SEC"
    i=$((i + 1))
done
 
log_fail "Ping test failed after $RETRIES attempts"
echo "FAIL $TESTNAME" > "$res_file"
exit 1
