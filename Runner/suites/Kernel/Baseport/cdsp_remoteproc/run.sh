#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
INVOCATION_CWD="$PWD"

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
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

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="cdsp_remoteproc"
RES_FILE="./$TESTNAME.res"
FW="cdsp"

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"
log_info "=== Test Initialization ==="

# Timeouts (can be overridden via env)
STOP_TO="${STOP_TO:-10}"
START_TO="${START_TO:-10}"
BOOT_TO=10 # Passive boot-readiness deadline per instance (s)
POLL_I="${POLL_I:-1}"

# --- CLI ----------------------------------------------------------------------
# Default: do NOT do SSR (stop/start). Enable explicitly with --ssr
DO_SSR=0

usage() {
    echo "Usage: $0 [--boot-to SEC] [--ssr] [--stop-to SEC] [--start-to SEC] [--poll-i SEC]" >&2
    echo " --boot-to SEC Passive boot-readiness timeout (default: $BOOT_TO, 0 samples immediately)" >&2
    echo " --ssr Perform CDSP stop/start (SSR). Default: OFF" >&2
    echo " --stop-to SEC Stop timeout (default: $STOP_TO)" >&2
    echo " --start-to SEC Start timeout (default: $START_TO)" >&2
    echo " --poll-i SEC Poll interval (default: $POLL_I)" >&2
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --boot-to)
                if [ $# -lt 2 ]; then
                    test_result_finish FAIL "Missing value for --boot-to"
                fi
                BOOT_TO="$2"
                shift 2
                ;;
            --ssr)
                DO_SSR=1
                shift
                ;;
            --stop-to)
                if [ $# -lt 2 ]; then
                    log_fail "Missing value for --stop-to"
                    usage
                    test_result_finish FAIL "Invalid or incomplete argument, see usage"
                fi
                STOP_TO="$2"
                shift 2
                ;;
            --start-to)
                if [ $# -lt 2 ]; then
                    log_fail "Missing value for --start-to"
                    usage
                    test_result_finish FAIL "Invalid or incomplete argument, see usage"
                fi
                START_TO="$2"
                shift 2
                ;;
            --poll-i)
                if [ $# -lt 2 ]; then
                    log_fail "Missing value for --poll-i"
                    usage
                    test_result_finish FAIL "Invalid or incomplete argument, see usage"
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
                test_result_finish FAIL "Invalid or incomplete argument, see usage"
                ;;
        esac
    done
    case "$BOOT_TO" in
        ''|*[!0-9]*|0[0-9]*)
            test_result_finish FAIL "--boot-to requires whole decimal seconds without leading zeros"
            ;;
    esac
    if [ "${#BOOT_TO}" -gt 5 ] || [ "$BOOT_TO" -gt 86400 ]; then
        test_result_finish FAIL "--boot-to must not exceed 86400 seconds"
    fi
    if ! command -v awk >/dev/null 2>&1; then
        test_result_finish SKIP "DSP poll validation requires image-provided awk"
    fi
    if ! awk -v poll="$POLL_I" 'BEGIN {
        exit !(length(poll) <= 16 && poll ~ /^[0-9]+([.][0-9]+)?$/ && poll > 0 && poll <= 86400)
    }'; then
        test_result_finish FAIL "--poll-i requires positive decimal seconds up to 86400"
    fi
}

parse_args "$@"

log_info "Tunables: BOOT_TO=$BOOT_TO STOP_TO=$STOP_TO START_TO=$START_TO POLL_I=$POLL_I"
log_info "SSR control: DO_SSR=$DO_SSR (0=no stop/start, 1=do stop/start)"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies awk sleep readlink basename mkdir mktemp date grep sed wc tr cat cp; then
    test_result_finish SKIP "DSP readiness requires image-provided shell and sysfs diagnostic tools"
fi
OUT_DIR=$(test_create_run_directory "$INVOCATION_CWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create DSP diagnostics under CWD=$INVOCATION_CWD"
log_info "DSP diagnostics: $OUT_DIR"

# --- Device Tree gate ----------------------------------------------------
if dt_has_remoteproc_fw "$FW"; then
    log_info "DT indicates $FW is present"
else
    log_skip "$TESTNAME SKIP – $FW not described in DT"
    log_info "Writing to $RES_FILE"
    test_result_finish SKIP
fi

# ---------- Discover all matching remoteproc entries ----------
# get_remoteproc_by_firmware prints: "path|state|firmware|name"
entries="$(get_remoteproc_by_firmware "$FW" "" all 2>/dev/null)" || entries=""
if [ -z "$entries" ]; then
    log_fail "$FW present in DT but no /sys/class/remoteproc entry found"
    log_info "Writing to $RES_FILE"
    test_result_finish FAIL
fi

count_instances=$(printf '%s\n' "$entries" | wc -l)
log_info "Found $count_instances $FW instance(s)"

inst_fail=0
RESULT_LINES=""


while IFS='|' read -r rpath rstate rfirm rname; do
    [ -n "$rpath" ] || continue # safety

    inst_id="$(basename "$rpath")"
    log_info "---- $inst_id: path=$rpath state=$rstate firmware=$rfirm name=$rname ----"

    boot_res="PASS"
    stop_res="NA"
    start_res="NA"
    ping_res="SKIPPED"

    # Boot check
    if wait_remoteproc_boot_ready "$rpath" "$BOOT_TO" "$POLL_I" "$OUT_DIR/$inst_id/boot" "$rstate"; then
        test_result_record PASS "$inst_id: boot readiness passed"
    else
        test_result_record FAIL "$inst_id: boot readiness failed, see $OUT_DIR/$inst_id/boot/readiness.log and fatal_errors.log"
        boot_res="FAIL"
        inst_fail=$((inst_fail + 1))
        RESULT_LINES="$RESULT_LINES
 $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
        continue
    fi

    if [ "$DO_SSR" -eq 1 ]; then
        # Stop
        (
            cd "$OUT_DIR" || exit 1
            dump_rproc_logs "$rpath" before-stop
        )
        t0=$(date +%s)
        log_info "$inst_id: stopping"
	log_info "$inst_id: waiting for state=offline with timeout=${STOP_TO}s poll=${POLL_I}s"
        if stop_remoteproc "$rpath" && wait_remoteproc_state "$rpath" offline "$STOP_TO" "$POLL_I"; then
            t1=$(date +%s)
            log_pass "$inst_id: stop PASS ($((t1 - t0))s)"
            stop_res="PASS"
        else
            (
                cd "$OUT_DIR" || exit 1
                dump_rproc_logs "$rpath" after-stop-fail
            )
            log_fail "$inst_id: stop FAIL"
            stop_res="FAIL"
            inst_fail=$((inst_fail + 1))
            RESULT_LINES="$RESULT_LINES
 $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
            continue
        fi
        (
            cd "$OUT_DIR" || exit 1
            dump_rproc_logs "$rpath" after-stop
        )

        # Start
        (
            cd "$OUT_DIR" || exit 1
            dump_rproc_logs "$rpath" before-start
        )
        t2=$(date +%s)
        log_info "$inst_id: starting"
	log_info "$inst_id: waiting for state=running with timeout=${START_TO}s poll=${POLL_I}s"
        if start_remoteproc "$rpath" && wait_remoteproc_state "$rpath" running "$START_TO" "$POLL_I"; then
            t3=$(date +%s)
            log_pass "$inst_id: start PASS ($((t3 - t2))s)"
            start_res="PASS"
        else
            (
                cd "$OUT_DIR" || exit 1
                dump_rproc_logs "$rpath" after-start-fail
            )
            log_fail "$inst_id: start FAIL"
            start_res="FAIL"
            inst_fail=$((inst_fail + 1))
            RESULT_LINES="$RESULT_LINES
 $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
            continue
        fi
        (
            cd "$OUT_DIR" || exit 1
            dump_rproc_logs "$rpath" after-start
        )
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

done <<__RPROC_LIST__
$entries
__RPROC_LIST__

# ---------- Summary ----------
log_info "Instance results:$RESULT_LINES"

if [ "$inst_fail" -gt 0 ]; then
    log_fail "One or more $FW instance(s) failed ($inst_fail/$count_instances)"
    log_info "Writing to $RES_FILE"
    test_result_finish FAIL
fi

log_pass "All $count_instances $FW instance(s) passed"
log_info "Writing to $RES_FILE"
test_result_finish PASS
