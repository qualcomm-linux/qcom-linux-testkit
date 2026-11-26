#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# usage
# Print the supported command-line options.
usage() {
    cat <<EOF
Usage: ${0##*/} [--bin-path PATH] [--subtest NAME] [--timeout SECONDS] [--help]

Run the IGT msm_recovery test. Results and logs are written to the current directory.

Options:
  --bin-path PATH    IGT binary, default: /usr/libexec/igt-gpu-tools/msm_recovery
  --subtest NAME     Run only this subtest
  --timeout SECONDS  IGT runtime limit, default: IGT_TIMEOUT or 600
  -h, --help         Show this help text and exit

Environment:
  IGT_DEVICE         drm:/dev/dri/<node> filter selecting the msm device
EOF
}

# parse_args ARG...
# Parse options into runner globals, setting PARSE_ERROR on invalid input.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --bin-path|--subtest|--timeout)
                if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                    PARSE_ERROR="$1 requires a value"
                    return 1
                fi
                case "$1" in
                    --bin-path)
                        IGT_BIN="$2"
                        ;;
                    --subtest)
                        IGT_SUBTEST="$2"
                        ;;
                    *)
                        IGT_RUN_TIMEOUT="$2"
                        ;;
                esac
                shift 2
                ;;
            -h|--help)
                SHOW_HELP=1
                shift
                ;;
            *)
                PARSE_ERROR="unknown argument: $1"
                return 1
                ;;
        esac
    done
    return 0
}

WORK_DIR="$(pwd -P)"
IGT_BIN="/usr/libexec/igt-gpu-tools/msm_recovery"
IGT_SUBTEST=""
IGT_RUN_TIMEOUT="${IGT_TIMEOUT:-600}"
SHOW_HELP=0
PARSE_ERROR=""

parse_args "$@"
PARSE_RC=$?

if [ "$SHOW_HELP" -eq 1 ]; then
    usage
    exit 0
fi

if [ ! -w "$WORK_DIR" ]; then
    echo "[ERROR] Current directory is not writable for results: $WORK_DIR" >&2
    exit 1
fi

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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_display.sh"
if [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_pkg_provider.sh"
fi
if [ -r "$TOOLS/lib_module_reload.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_module_reload.sh"
fi
# shellcheck disable=SC1091
. "$TOOLS/lib_igt.sh"

TESTNAME="msm_recovery"
RES_FILE="$WORK_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if [ "$PARSE_RC" -ne 0 ]; then
    usage >&2
    test_result_finish FAIL "$TESTNAME FAIL - $PARSE_ERROR"
fi

case "$IGT_RUN_TIMEOUT" in
    ''|*[!0-9]*|0*)
        test_result_finish FAIL "$TESTNAME FAIL - timeout must be a positive integer, value=$IGT_RUN_TIMEOUT"
        ;;
esac
if [ "${#IGT_RUN_TIMEOUT}" -gt 9 ]; then
    test_result_finish FAIL "$TESTNAME FAIL - timeout exceeds the supported seconds range"
fi

OUT_DIR=$(test_create_run_directory "$WORK_DIR/results/$TESTNAME") ||
    test_result_finish FAIL "$TESTNAME FAIL - cannot create a run directory in $WORK_DIR/results/$TESTNAME"
IGT_LOG="$OUT_DIR/${TESTNAME}_log.txt"
KLOG_DIR="$OUT_DIR/dmesg"
ERR_IRQ_STATE="$WORK_DIR/.${TESTNAME}-err-irq.state"
mkdir -p "$KLOG_DIR" || test_result_finish FAIL "$TESTNAME FAIL - cannot create $KLOG_DIR"

# cleanup
# Stop the owned IGT process group, then restore the GPU error-interrupt state.
# The saved state is kept when owned processes survive, so they cannot
# change the GPU again after a restore.
cleanup() {
    if ! managed_timeout_cancel_bounded 5; then
        log_fail "$TESTNAME IGT processes are still running, GPU error-interrupt state kept in $ERR_IRQ_STATE"
        return 1
    fi
    display_gpu_err_irq_restore "$ERR_IRQ_STATE"
}

# interrupt_test <exit-status>
# Clean up, publish FAIL and preserve the signal exit status.
interrupt_test() {
    # A repeated signal must not re-enter cleanup or the state restore.
    trap '' HUP INT TERM
    if ! cleanup; then
        test_result_record FAIL "$TESTNAME cleanup failed during interruption"
    fi
    (
        TEST_RESULT_CLEANUP=""
        test_result_finish FAIL "$TESTNAME FAIL - interrupted"
    )
    exit "$1"
}

# exit_test
# Clean up on every exit, publish FAIL if that fails, then hand over to the
# init_env stdout handler.
exit_test() {
    exit_status=$?
    if ! cleanup; then
        log_fail "$TESTNAME cleanup failed at exit"
        printf '%s FAIL\n' "$TESTNAME" >"$RES_FILE" 2>/dev/null || true
    fi
    if [ -n "${__RUN_STDOUT_ACTIVE:-}" ] &&
       command -v _runner_stdout_cleanup >/dev/null 2>&1; then
        _runner_stdout_cleanup "$exit_status"
    fi
    exit "$exit_status"
}

# shellcheck disable=SC2034 # Consumed by the shared managed timeout helpers.
MANAGED_TIMEOUT_USE_SESSION=1
# shellcheck disable=SC2034 # Consumed by the shared result finalizer.
TEST_RESULT_CLEANUP=cleanup
trap exit_test EXIT
trap 'interrupt_test 129' HUP
trap 'interrupt_test 130' INT
trap 'interrupt_test 143' TERM

OS_ID="unknown"
if command -v pkg_detect_os_id >/dev/null 2>&1; then
    OS_ID="$(pkg_detect_os_id 2>/dev/null || true)"
fi
[ -n "$OS_ID" ] || OS_ID="unknown"
GPU_OWNER="$(igt_gpu_owner)"

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Detected OS, $OS_ID"
log_info "Kernel, $(uname -r)"
log_info "GPU boot mode, $GPU_OWNER"
log_info "Config, BIN=$IGT_BIN SUBTEST=${IGT_SUBTEST:-all} TIMEOUT=${IGT_RUN_TIMEOUT}s"
log_info "Evidence, $OUT_DIR"

if [ ! -x "$IGT_BIN" ]; then
    test_result_finish SKIP "$TESTNAME SKIP - IGT binary is unavailable: $IGT_BIN"
fi

if [ "$(basename "$IGT_BIN")" != "$TESTNAME" ]; then
    test_result_finish FAIL "$TESTNAME FAIL - binary $(basename "$IGT_BIN") does not match testcase $TESTNAME"
fi

if [ "$GPU_OWNER" = "kgsl" ]; then
    test_result_finish SKIP "$TESTNAME SKIP - GPU is owned by KGSL, msm GPU driver is required"
fi

if ! command -v setsid >/dev/null 2>&1; then
    test_result_finish SKIP "$TESTNAME SKIP - image-provided setsid is required for owned IGT process cleanup"
fi

# Owned-session timeouts and fault attribution come from the current functestlib.sh.
for required_helper in bounded_timeout_pid_running kernel_log_filter_faults; do
    if ! command -v "$required_helper" >/dev/null 2>&1; then
        test_result_finish FAIL "$TESTNAME FAIL - required helper is unavailable: $required_helper, functestlib.sh is older than this suite"
    fi
done
IGT_DEVICE_NODE="$(igt_select_msm_device)"
case "$?" in
    0)
        ;;
    1)
        test_result_finish SKIP "$TESTNAME SKIP - no msm DRM render node is available"
        ;;
    *)
        test_result_finish FAIL "$TESTNAME FAIL - IGT_DEVICE=$IGT_DEVICE is not a drm:/dev/dri/<node> filter for an msm device"
        ;;
esac
log_info "IGT device, $IGT_DEVICE_NODE"

# Only the native hangcheck subtest changes disable_err_irq, and IGT restores it
# only on a clean return. Save the selected device's value before any run that
# can execute hangcheck. A state file left by an interrupted earlier run holds
# the original value and is restored first.
if [ -f "$ERR_IRQ_STATE" ] && ! display_gpu_err_irq_restore "$ERR_IRQ_STATE"; then
    test_result_finish FAIL "$TESTNAME FAIL - cannot restore the GPU error-interrupt state left by an earlier run"
fi
ERR_IRQ_NEEDED=0
case "$IGT_SUBTEST" in
    ''|*hangcheck*|*'*'*|*'?'*|*'['*)
        ERR_IRQ_NEEDED=1
        ;;
esac
if [ "$ERR_IRQ_NEEDED" -eq 0 ]; then
    log_info "Selected subtests do not change disable_err_irq, its state is not saved"
else
    display_gpu_err_irq_snapshot "$ERR_IRQ_STATE" "$IGT_DEVICE_NODE"
    case "$?" in
        0)
            log_info "GPU error-interrupt state saved, $(sed -n 's/^path=//p' "$ERR_IRQ_STATE")=$(sed -n 's/^value=//p' "$ERR_IRQ_STATE")"
            ;;
        1)
            log_info "disable_err_irq is unavailable for $IGT_DEVICE_NODE, IGT skips hangcheck without it"
            ;;
        *)
            test_result_finish FAIL "$TESTNAME FAIL - cannot save the GPU error-interrupt state of $IGT_DEVICE_NODE"
            ;;
    esac
fi

KLOG_PRE_STATUS="unavailable"
if igt_kernel_log_capture "$KLOG_DIR/pre"; then
    KLOG_PRE_STATUS="available"
fi
KLOG_PRE_ACCESS="$IGT_KLOG_ACCESS_LOG"

set -- "$IGT_BIN" --device "drm:$IGT_DEVICE_NODE"
if [ -n "$IGT_SUBTEST" ]; then
    set -- "$@" --run-subtest "$IGT_SUBTEST"
fi

log_info "Using IGT binary, $IGT_BIN"
log_info "Launching $* with timeout ${IGT_RUN_TIMEOUT}s"
igt_run_binary "$IGT_RUN_TIMEOUT" "$IGT_LOG" "$@"
IGT_RC=$?
IGT_TIMED_OUT="${MANAGED_TIMEOUT_EXPIRED:-0}"
IGT_CLEANUP_FAILED=0
if [ -n "${MANAGED_TIMEOUT_CMD_PID:-}${MANAGED_TIMEOUT_WATCHER_PID:-}" ]; then
    IGT_CLEANUP_FAILED=1
fi

log_info "IGT version, $(igt_log_version "$IGT_LOG")"
log_info "IGT log, $IGT_LOG"

DEVICE_MISMATCH=0
igt_opened_devices_match "$IGT_LOG" "$IGT_DEVICE_NODE"
case "$?" in
    0)
        log_info "IGT opened the selected device, $IGT_DEVICE_NODE"
        ;;
    1)
        DEVICE_MISMATCH=1
        ;;
    *)
        log_warn "IGT log does not report the opened device"
        ;;
esac

KLOG_POST_STATUS="unavailable"
if igt_kernel_log_capture "$KLOG_DIR/post"; then
    KLOG_POST_STATUS="available"
fi
KLOG_POST_ACCESS="$IGT_KLOG_ACCESS_LOG"

KLOG_FAULT=0
if [ "$KLOG_PRE_STATUS" != "available" ] || [ "$KLOG_POST_STATUS" != "available" ]; then
    log_warn "Kernel log evidence unavailable, pre=$KLOG_PRE_STATUS post=$KLOG_POST_STATUS, see $KLOG_PRE_ACCESS and $KLOG_POST_ACCESS"
elif ! igt_kernel_log_compare "$KLOG_DIR/pre" "$KLOG_DIR/post" "$KLOG_DIR"; then
    log_warn "Kernel log evidence unavailable, the fault or error comparison failed in $KLOG_DIR"
else
    if [ "$IGT_KLOG_NEW_ERRORS" -gt 0 ]; then
        log_warn "Kernel errors raised during $TESTNAME, count=$IGT_KLOG_NEW_ERRORS (capped at 20 lines), $KLOG_DIR/dmesg_errors.log"
        igt_log_file_lines warn "[dmesg]" "$KLOG_DIR/dmesg_errors.log" 20
    else
        log_info "No new msm/adreno/drm kernel errors"
    fi
    if [ "$IGT_KLOG_NEW_FAULTS" -gt 0 ]; then
        KLOG_FAULT=1
        log_fail "New GPU kernel fault blocks during $TESTNAME, count=$IGT_KLOG_NEW_FAULTS (capped at 40 lines), $KLOG_DIR/dmesg_faults.log"
        igt_log_file_lines fail "[fault]" "$KLOG_DIR/dmesg_faults.log" 40
    fi
fi

PASS_COUNT="$(igt_count_subtests "$IGT_LOG" "SUCCESS")"
FAIL_COUNT="$(igt_count_subtests "$IGT_LOG" "FAIL|CRASH|TIMEOUT")"
SKIP_COUNT="$(igt_count_subtests "$IGT_LOG" "SKIP")"
TOTAL_COUNT=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
log_info "Subtest results, SUCCESS=$PASS_COUNT FAIL=$FAIL_COUNT SKIP=$SKIP_COUNT TOTAL=$TOTAL_COUNT rc=$IGT_RC"

igt_list_subtests "$IGT_LOG" "FAIL|CRASH|TIMEOUT" | while IFS= read -r subtest_line; do
    log_fail "$subtest_line"
done
igt_list_subtests "$IGT_LOG" "SKIP" | while IFS= read -r subtest_line; do
    log_skip "$subtest_line"
done

FINAL="PASS"
REASON="$PASS_COUNT subtest(s) passed, $SKIP_COUNT skipped"
if [ "$IGT_TIMED_OUT" = "1" ]; then
    FINAL="FAIL"
    REASON="timed out after ${IGT_RUN_TIMEOUT}s"
elif [ "$IGT_CLEANUP_FAILED" -eq 1 ]; then
    FINAL="FAIL"
    REASON="owned IGT processes remain after cleanup"
elif [ "$DEVICE_MISMATCH" -eq 1 ]; then
    FINAL="FAIL"
    REASON="IGT opened a device other than $IGT_DEVICE_NODE"
elif [ "$FAIL_COUNT" -gt 0 ]; then
    FINAL="FAIL"
    REASON="$FAIL_COUNT of $TOTAL_COUNT subtest(s) failed"
elif [ "$KLOG_FAULT" -eq 1 ]; then
    FINAL="FAIL"
    REASON="new GPU kernel fault, see $KLOG_DIR/dmesg_faults.log"
elif [ "$IGT_RC" -eq 77 ]; then
    FINAL="SKIP"
    REASON="IGT reported SKIP, exit code 77"
elif [ "$IGT_RC" -ne 0 ]; then
    FINAL="FAIL"
    REASON="IGT exited with code $IGT_RC"
elif [ "$PASS_COUNT" -eq 0 ] && [ "$SKIP_COUNT" -gt 0 ]; then
    FINAL="SKIP"
    REASON="all $SKIP_COUNT subtest(s) skipped"
fi

if [ "$FINAL" = "FAIL" ]; then
    log_info "----- Last 200 IGT log lines -----"
    tail -n 200 "$IGT_LOG" 2>/dev/null | while IFS= read -r igt_line; do
        log_info "[igt] $igt_line"
    done
    log_info "----- End IGT log -----"
fi

log_info "------------------- Completed $TESTNAME Testcase -------------------------"
test_result_finish "$FINAL" "$TESTNAME $FINAL - $REASON"
