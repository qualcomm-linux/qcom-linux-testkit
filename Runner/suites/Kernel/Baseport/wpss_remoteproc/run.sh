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

TESTNAME="wpss_remoteproc"
RES_FILE="./$TESTNAME.res"
FW="wpss"

# Run from the testcase directory so relative outputs (like .res) land next to run.sh
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || {
    echo "[ERROR] Could not cd to testcase path: $test_path" >&2
    exit 1
}
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"
log_info "=== Test Initialization ==="

# Tunables
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
    echo " --ssr Perform WPSS stop/start (SSR). Default: OFF" >&2
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
    for ssr_seconds in "$STOP_TO" "$START_TO"; do
        case "$ssr_seconds" in
            ''|*[!0-9]*|0|0[0-9]*)
                test_result_finish FAIL "SSR timeouts require positive decimal seconds without leading zeros"
                ;;
        esac
        if [ "${#ssr_seconds}" -gt 5 ] || [ "$ssr_seconds" -gt 86400 ]; then
            test_result_finish FAIL "SSR timeouts must not exceed 86400 seconds"
        fi
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

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies awk sleep readlink basename mkdir mktemp date grep sed wc tr cat cp find rm; then
    test_result_finish SKIP "DSP readiness requires image-provided shell and sysfs diagnostic tools"
fi
OUT_DIR=$(test_create_run_directory "$INVOCATION_CWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create DSP diagnostics under CWD=$INVOCATION_CWD"
log_info "DSP diagnostics: $OUT_DIR"

SSR_OWNED_PATH=""

# cleanup_ssr
# Restore only the running instance stopped by this explicit SSR invocation.
cleanup_ssr() {
    if [ -n "$SSR_OWNED_PATH" ]; then
        if remoteproc_restore_running "$SSR_OWNED_PATH" "$START_TO" "$POLL_I"; then
            SSR_OWNED_PATH=""
        else
            log_fail "DSP state restoration failed: $SSR_OWNED_PATH"
            return 1
        fi
    fi
}
# shellcheck disable=SC2034 # Consumed by shared finalization.
TEST_RESULT_CLEANUP=cleanup_ssr
trap cleanup_ssr 0
trap 'test_result_finish FAIL "DSP validation interrupted"' HUP INT TERM


# ---------- Try remoteproc path ----------
rp_entries="$(get_remoteproc_by_firmware "$FW" "" all)" || rp_entries=""
dt_says_present=0

if dt_has_remoteproc_fw "$FW"; then
    dt_says_present=1
    log_info "DT indicates $FW is present"
    # prints: path|state|firmware|name (multiple lines)
else
    log_info "DT does NOT list $FW – may be driver-loaded (ath11k) on this platform"
fi

if [ -n "$rp_entries" ]; then
    log_info "Remoteproc mode selected (found $(printf '%s\n' "$rp_entries" | wc -l) instance(s))"

    inst_fail=0
    RESULT_LINES=""

    while IFS='|' read -r rpath rstate rfirm rname; do
        [ -n "$rpath" ] || continue
        inst="$(basename "$rpath")"

        log_info "---- $inst: path=$rpath state=$rstate firmware=$rfirm name=$rname ----"

        boot_res="PASS"
        stop_res="NA"
        start_res="NA"
        ping_res="SKIPPED"

        # Boot check
        if wait_remoteproc_boot_ready "$rpath" "$BOOT_TO" "$POLL_I" "$OUT_DIR/$inst/boot" "$rstate"; then
            test_result_record PASS "$inst: boot readiness passed"
        else
            test_result_record FAIL "$inst: boot readiness failed, see $OUT_DIR/$inst/boot/readiness.log and fatal_errors.log"
            boot_res="FAIL"
            inst_fail=$((inst_fail + 1))
            RESULT_LINES="$RESULT_LINES
 $inst: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
            cleanup_ssr || test_result_finish FAIL "DSP restoration failed"
            continue
        fi

        if [ "$DO_SSR" -eq 1 ]; then
            # Stop
            (
                cd "$OUT_DIR" || exit 1
                dump_rproc_logs "$rpath" before-stop "$OUT_DIR/$inst/before-stop/dmesg_snapshot.log"
            )
            t0=$(date +%s)
            log_info "$inst: stopping"
            SSR_OWNED_PATH="$rpath"
        if stop_remoteproc "$rpath" "$STOP_TO" "$POLL_I"; then
                t1=$(date +%s)
                log_pass "$inst: stop PASS ($((t1 - t0))s)"
                stop_res="PASS"
            else
                (
                    cd "$OUT_DIR" || exit 1
                    dump_rproc_logs "$rpath" after-stop-fail
                )
                log_fail "$inst: stop FAIL"
                stop_res="FAIL"
                inst_fail=$((inst_fail + 1))
                RESULT_LINES="$RESULT_LINES
 $inst: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
                cleanup_ssr || test_result_finish FAIL "DSP restoration failed"
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
            log_info "$inst: starting"
            if start_remoteproc "$rpath" "$START_TO" "$POLL_I"; then
                t3=$(date +%s)
                log_pass "$inst: start PASS ($((t3 - t2))s)"
                start_res="PASS"
                SSR_OWNED_PATH=""
                if ! wait_remoteproc_boot_ready "$rpath" "$START_TO" "$POLL_I" "$OUT_DIR/$inst/restart-health" running; then
                    start_res="FAIL"
                    inst_fail=$((inst_fail + 1))
                    test_result_record FAIL "$inst: fatal or incomplete post-restart health"
                fi
            else
                (
                    cd "$OUT_DIR" || exit 1
                    dump_rproc_logs "$rpath" after-start-fail
                )
                log_fail "$inst: start FAIL"
                start_res="FAIL"
                inst_fail=$((inst_fail + 1))
                RESULT_LINES="$RESULT_LINES
 $inst: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
                cleanup_ssr || test_result_finish FAIL "DSP restoration failed"
                continue
            fi
            (
                cd "$OUT_DIR" || exit 1
                dump_rproc_logs "$rpath" after-start
            )
        else
            log_info "$inst: SSR disabled (--ssr not set). Skipping stop/start."
            stop_res="SKIPPED"
            start_res="SKIPPED"
        fi

        # RPMsg ping (optional)
    rpmsg_validate_echo "$rpath" "$OUT_DIR/$inst/rpmsg"
    ping_rc=$?
    case "$ping_rc" in
        0)
            ping_res="PASS"
            test_result_record PASS "$inst: configured RPMsg echo validated"
            ;;
        2)
            ping_res="SKIPPED"
            test_result_record SKIP "$inst: optional named RPMsg echo service/client unavailable"
            ;;
        *)
            ping_res="FAIL"
            inst_fail=$((inst_fail + 1))
            test_result_record FAIL "$inst: RPMsg echo execution failed"
            ;;
    esac

        RESULT_LINES="$RESULT_LINES
 $inst: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"

    done <<__RPROC_LIST__
$rp_entries
__RPROC_LIST__

    log_info "Instance results:$RESULT_LINES"

    if [ "$inst_fail" -gt 0 ]; then
        log_fail "One or more $FW instance(s) failed ($inst_fail)"
        test_result_finish FAIL
    fi

    log_pass "All $FW remoteproc instance(s) passed"
    test_result_finish PASS
fi

# ---------- Fallback: runtime WiFi driver ownership ----------
# shellcheck disable=SC1091
. "$TOOLS/lib_connectivity.sh"
wifi_families=$(wifi_runtime_families) || test_result_finish FAIL "WiFi ownership discovery failed"
if [ -z "$wifi_families" ]; then
    if [ "$dt_says_present" -eq 1 ]; then
        test_result_finish FAIL "Enabled WPSS DT has neither a remoteproc instance nor a WiFi driver owner"
    fi
    test_result_finish SKIP "No WPSS remoteproc or supported WiFi runtime owner"
fi
for wifi_family in $wifi_families; do
    if wifi_family_has_phy "$wifi_family"; then
        test_result_record PASS "WPSS is owned by a bound $wifi_family wireless PHY"
    else
        test_result_record FAIL "Runtime $wifi_family driver has no bound wireless PHY"
    fi
done
wifi_has_probe_failures "$OUT_DIR/driver" "$TESTNAME"
driver_rc=$?
case "$driver_rc" in
    0)
        test_result_record FAIL "Captured WPSS/WiFi driver faults"
        ;;
    2)
        test_result_record SKIP "Driver kernel health is unverified, see capture diagnostics"
        ;;
esac
if [ "$TEST_RESULT_FAIL_COUNT" -gt 0 ] || [ "$driver_rc" -eq 2 ]; then
    wifi_dump_runtime_info "$OUT_DIR/runtime" || true
fi
if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$driver_rc" -eq 2 ]; then
    test_result_finish SKIP "WPSS driver ownership is present but required kernel or fallback health evidence is unavailable"
fi
test_result_finish
