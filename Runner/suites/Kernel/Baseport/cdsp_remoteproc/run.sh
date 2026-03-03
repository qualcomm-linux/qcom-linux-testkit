#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
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

TESTNAME="cdsp_remoteproc"
RES_FILE="./$TESTNAME.res"
FW="cdsp"

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"
log_info "=== Test Initialization ==="

# Timeouts (can be overridden via env)
STOP_TO="${STOP_TO:-10}"
START_TO="${START_TO:-10}"
POLL_I="${POLL_I:-1}"

# --- CLI ----------------------------------------------------------------------
# Default: do NOT do SSR (stop/start). Enable explicitly with --ssr
DO_SSR=0

usage() {
    echo "Usage: $0 [--ssr] [--stop-to SEC] [--start-to SEC] [--poll-i SEC]" >&2
    echo " --ssr Perform CDSP stop/start (SSR). Default: OFF" >&2
    echo " --stop-to SEC Stop timeout (default: $STOP_TO)" >&2
    echo " --start-to SEC Start timeout (default: $START_TO)" >&2
    echo " --poll-i SEC Poll interval (default: $POLL_I)" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ssr)
            DO_SSR=1
            shift
            ;;
        --stop-to)
            if [ $# -lt 2 ]; then
                log_fail "Missing value for --stop-to"
                usage
                exit 2
            fi
            STOP_TO="$2"
            shift 2
            ;;
        --start-to)
            if [ $# -lt 2 ]; then
                log_fail "Missing value for --start-to"
                usage
                exit 2
            fi
            START_TO="$2"
            shift 2
            ;;
        --poll-i)
            if [ $# -lt 2 ]; then
                log_fail "Missing value for --poll-i"
                usage
                exit 2
            fi
            POLL_I="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
done

log_info "Tunables: STOP_TO=$STOP_TO START_TO=$START_TO POLL_I=$POLL_I"
log_info "SSR control: DO_SSR=$DO_SSR (0=no stop/start, 1=do stop/start)"

# --- Device Tree gate ----------------------------------------------------
if dt_has_remoteproc_fw "$FW"; then
    log_info "DT indicates $FW is present"
else
    log_skip "$TESTNAME SKIP – $FW not described in DT"
    log_info "Writing to $RES_FILE"
    echo "${TESTNAME} SKIP" > "$RES_FILE"
    exit 0
fi

# ---------- Discover all matching remoteproc entries ----------
# get_remoteproc_by_firmware prints: "path|state|firmware|name"
entries="$(get_remoteproc_by_firmware "$FW" "" all 2>/dev/null)" || entries=""
if [ -z "$entries" ]; then
    log_fail "$FW present in DT but no /sys/class/remoteproc entry found"
    log_info "Writing to $RES_FILE"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

count_instances=$(printf '%s\n' "$entries" | wc -l)
log_info "Found $count_instances $FW instance(s)"

inst_fail=0
RESULT_LINES=""

# Avoid subshell var-scope issues: feed loop from a temp file
tmp_list="$(mktemp)"
printf '%s\n' "$entries" >"$tmp_list"

while IFS='|' read -r rpath rstate rfirm rname; do
    [ -n "$rpath" ] || continue # safety

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

    if [ "$DO_SSR" -eq 1 ]; then
        # Stop
        dump_rproc_logs "$rpath" before-stop
        t0=$(date +%s)
        log_info "$inst_id: stopping"
	log_info "$inst_id: waiting for state=offline with timeout=${STOP_TO}s poll=${POLL_I}s"
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
	log_info "$inst_id: waiting for state=running with timeout=${START_TO}s poll=${POLL_I}s"
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
    else
        log_info "$inst_id: SSR disabled (--ssr not set). Skipping stop/start."
        stop_res="SKIPPED"
        start_res="SKIPPED"
    fi

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

# ---------- Summary ----------
log_info "Instance results:$RESULT_LINES"

if [ "$inst_fail" -gt 0 ]; then
    log_fail "One or more $FW instance(s) failed ($inst_fail/$count_instances)"
    log_info "Writing to $RES_FILE"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

log_pass "All $count_instances $FW instance(s) passed"
log_info "Writing to $RES_FILE"
echo "$TESTNAME PASS" > "$RES_FILE"
exit 0
