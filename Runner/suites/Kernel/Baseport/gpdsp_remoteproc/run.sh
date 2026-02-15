#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# Robustly find and source init_env
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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="gpdsp_remoteproc"
RES_FILE="./$TESTNAME.res"
FW="gpdsp"

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"
log_info "=== Test Initialization ==="

# Tunables
STOP_TO="${STOP_TO:-10}"
START_TO="${START_TO:-10}"
POLL_I="${POLL_I:-1}"

log_info "DEBUG: STOP_TO=$STOP_TO START_TO=$START_TO POLL_I=$POLL_I"

# DT check for entries
if dt_has_remoteproc_fw "$FW"; then
    log_info "DT indicates $FW is present"
else
    log_skip "$TESTNAME SKIP – $FW not described in DT"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# Enumerate GPDSP remoteproc entries
# get_remoteproc_by_firmware prints lines like: "path|state|firmware|name"
entries="$(get_remoteproc_by_firmware "$FW" "" all)" || entries=""
if [ -z "$entries" ]; then
    log_fail "$FW present in DT but no /sys/class/remoteproc entry found"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

count_instances=$(printf '%s\n' "$entries" | wc -l)
log_info "Found $count_instances $FW instance(s)"

inst_fail=0
RESULT_LINES=""

tmp_list="$(mktemp)"
printf '%s\n' "$entries" >"$tmp_list"

while IFS='|' read -r rpath rstate rfirm rname; do
    [ -n "$rpath" ] || continue

    inst_id="$(basename "$rpath")"
    log_info "---- $inst_id: path=$rpath state=$rstate firmware=$rfirm name=$rname ----"

    boot_res="PASS"
    stop_res="NA"
    start_res="NA"
    ping_res="SKIPPED"

    # Boot check
    if [ "$rstate" = "running" ]; then
        log_pass "$inst_id: boot check PASS"
    else
        log_fail "$inst_id: boot check FAIL (state=$rstate)"
        boot_res="FAIL"
        inst_fail=$((inst_fail + 1))
        RESULT_LINES="$RESULT_LINES
 $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
        continue
    fi

    # Stop
    dump_rproc_logs "$rpath" before-stop
    t0=$(date +%s)
    log_info "$inst_id: stopping"
    if stop_remoteproc "$rpath" && wait_remoteproc_state "$rpath" offline "$STOP_TO" "$POLL_I"; then
        t1=$(date +%s)
        log_pass "$inst_id: stop PASS ($((t1 - t0))s)"
        stop_res="PASS"
    else
        dump_rproc_logs "$rpath" after-stop-fail
        log_fail "$inst_id: stop FAIL"
        stop_res="FAIL"
        inst_fail=$((inst_fail + 1))
        RESULT_LINES="$RESULT_LINES
 $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
        continue
    fi
    dump_rproc_logs "$rpath" after-stop

    # Start
    dump_rproc_logs "$rpath" before-start
    t2=$(date +%s)
    log_info "$inst_id: starting"
    if start_remoteproc "$rpath" && wait_remoteproc_state "$rpath" running "$START_TO" "$POLL_I"; then
        t3=$(date +%s)
        log_pass "$inst_id: start PASS ($((t3 - t2))s)"
        start_res="PASS"
    else
        dump_rproc_logs "$rpath" after-start-fail
        log_fail "$inst_id: start FAIL"
        start_res="FAIL"
        inst_fail=$((inst_fail + 1))
        RESULT_LINES="$RESULT_LINES
 $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
        continue
    fi
    dump_rproc_logs "$rpath" after-start

    # Optional RPMsg ping
    if CTRL_DEV=$(find_rpmsg_ctrl_for "$FW"); then
        log_info "$inst_id: RPMsg ctrl dev: $CTRL_DEV"
        if rpmsg_ping_generic "$CTRL_DEV"; then
            log_pass "$inst_id: rpmsg ping PASS"
            ping_res="PASS"
        else
            log_warn "$inst_id: rpmsg ping FAIL"
            ping_res="FAIL"
            inst_fail=$((inst_fail + 1))
        fi
    else
        log_info "$inst_id: no RPMsg channel, skipping ping"
    fi

    RESULT_LINES="$RESULT_LINES
 $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"

done <"$tmp_list"
rm -f "$tmp_list"

# Summary
log_info "Instance results:$RESULT_LINES"

if [ "$inst_fail" -gt 0 ]; then
    log_fail "One or more $FW instance(s) failed ($inst_fail/$count_instances)"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

log_pass "All $count_instances $FW instance(s) passed"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
