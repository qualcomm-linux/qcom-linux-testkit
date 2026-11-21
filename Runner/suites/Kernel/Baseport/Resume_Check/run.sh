#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Verify that the system resumed from suspend without errors.
#
# Suspending the system and providing the wakeup source are out of scope:
# this script runs after the system is back up and only inspects what the
# kernel recorded about the cycle that already happened.
#
# Run Pre_Suspend_Check before the suspend to get a baseline. Without it
# this script still runs, but it cannot tell a resume from a reboot and falls
# back to the counter baselines given on the command line.
#
# All checks are folded into a single result:
#   FAIL - any check failed, or the input was invalid
#   PASS - no check failed and the resume was confirmed by the kernel
#   SKIP - no check failed but nothing could confirm the resume

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

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck source=../../../../utils/lib_system.sh
# shellcheck disable=SC1091
. "$TOOLS/lib_system.sh"
# shellcheck source=../../../../utils/lib_suspend.sh
# shellcheck disable=SC1091
. "$TOOLS/lib_suspend.sh"

TESTNAME="Resume_Check"
RES_FILE="./$TESTNAME.res"

test_path="$(find_test_case_by_name "$TESTNAME")"

if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

# Remove the result of an earlier run before anything can fail, so that the
# test definition never publishes a stale result.
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

# State recorded by Pre_Suspend_Check. When it is present, its values are the
# baselines and the ones below are ignored.
STATE_FILE="${STATE_FILE:-/tmp/pre-suspend-state.txt}"
# Number of successful cycles recorded before the suspend under test, used
# only without a state file. Cycles accumulate for the whole boot, so leave
# it at 0 for the first suspend after boot and pass the value read from
# /sys/power/suspend_stats/success beforehand otherwise.
BASELINE_SUCCESS="${BASELINE_SUCCESS:-0}"
# Number of failed cycles recorded before the suspend under test, used only
# without a state file.
BASELINE_FAIL="${BASELINE_FAIL:-0}"
# Suspend-to-RAM variant the cycle used (default, s2idle, shallow or deep).
# When set, it is appended to the result name, and a mode other than default
# must be the one the cycle ran in.
SUSPEND_MODE="${SUSPEND_MODE:-}"
# Extended regexp of kernel messages treated as suspend/resume failures.
ERROR_PATTERN="${ERROR_PATTERN:-PM: [Ss]uspend[- ].*(fail|abort)|Freezing of tasks failed|did not resume|failed to suspend|Call Trace|BUG:|WARNING:|Oops|kernel panic}"

STATS_DIR="/sys/power/suspend_stats"
# Phases with a failed_<phase> counter in $STATS_DIR.
PHASES="freeze prepare suspend suspend_late suspend_noirq resume resume_early resume_noirq"
# Markers written by the kernel when a cycle starts and finishes. The second
# alternative in each covers kernels older than v4.15.
ENTRY_PATTERN="PM: suspend entry|PM: Syncing filesystems"
EXIT_PATTERN="PM: suspend exit|PM: Finishing wakeup|Restarting tasks.*done"

LOG_DIR="./kernel-log"
DMESG_RESUME_LOG="./dmesg-resume.log"

usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --state-file PATH     state file written by Pre_Suspend_Check (default: /tmp/pre-suspend-state.txt)" \
        "  --baseline-success N  successful cycles before suspend, used without a state file (default: 0)" \
        "  --baseline-fail N     failed cycles before suspend, used without a state file (default: 0)" \
        "  --error-pattern RE    extended regexp of kernel messages treated as failures" \
        "  --suspend-mode MODE   suspend-to-RAM variant (default|s2idle|shallow|deep), appended to the result name" \
        "  -h, --help" \
        "CLI options override environment variables."
}

# Argument errors are collected rather than fatal, so that the result can
# still carry the requested mode in its name.
arg_error=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --state-file | --baseline-success | --baseline-fail | --error-pattern | --suspend-mode)
        if [ "$#" -lt 2 ]; then
            arg_error="option $1 requires a value"
            break
        fi
        case "$1" in
        --state-file) STATE_FILE="$2" ;;
        --baseline-success) BASELINE_SUCCESS="$2" ;;
        --baseline-fail) BASELINE_FAIL="$2" ;;
        --error-pattern) ERROR_PATTERN="$2" ;;
        --suspend-mode) SUSPEND_MODE="$2" ;;
        esac
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        arg_error="unknown option: $1"
        break
        ;;
    esac
done

if [ -n "$SUSPEND_MODE" ]; then
    if suspend_mode_is_valid "$SUSPEND_MODE"; then
        test_result_init "${TESTNAME}_$SUSPEND_MODE" "$RES_FILE" || exit 1
    else
        arg_error="${arg_error:-unknown suspend mode: $SUSPEND_MODE}"
    fi
fi

cli_success="$(suspend_uint "$BASELINE_SUCCESS")" ||
    arg_error="${arg_error:-baseline success must be a non-negative integer: $BASELINE_SUCCESS}"
cli_fail="$(suspend_uint "$BASELINE_FAIL")" ||
    arg_error="${arg_error:-baseline fail must be a non-negative integer: $BASELINE_FAIL}"
suspend_regex_is_valid "$ERROR_PATTERN" ||
    arg_error="${arg_error:-invalid error pattern: $ERROR_PATTERN}"
[ -n "$STATE_FILE" ] || arg_error="${arg_error:-the state file path is empty}"

if [ -n "$arg_error" ]; then
    usage
    test_result_finish "FAIL" "$TEST_RESULT_NAME FAIL: $arg_error"
fi

log_info "----------------------------------------------------------------------------"
log_info "------------------- Starting $TEST_RESULT_NAME Testcase ----------------------------"

rm -f "$DMESG_RESUME_LOG"
rm -rf ./suspend_stats

# Set when a source confirmed that a cycle completed.
resumed=0

# ---------------------------------------------------------------------------
# What was recorded before the suspend
# ---------------------------------------------------------------------------

# Read one KEY=VALUE from the state file. The file is parsed rather than
# sourced: it is written by another script and must not be able to run code.
get_state() {
    grep -m1 "^$1=" "$STATE_FILE" | cut -d= -f2-
}

# Read a numeric state field into state_value. An empty field means that
# Pre_Suspend_Check could not measure it, and leaves state_value empty;
# anything else that is not a number is rejected.
read_state_uint() {
    rsu_raw="$(get_state "$1")"
    state_value=""
    [ -n "$rsu_raw" ] || return 0
    state_value="$(suspend_uint "$rsu_raw")" ||
        test_result_finish "FAIL" "$TEST_RESULT_NAME FAIL: malformed $1 in $STATE_FILE: $rsu_raw"
}

# Baselines are empty when unavailable. With a state file, they come only
# from it; without one, from the command line, and the per-phase counters
# are assumed to start from zero.
have_state=0
base_success=""
base_fail=""
pre_boundary=""
if [ -r "$STATE_FILE" ]; then
    have_state=1
    log_info "pre-suspend-state-found: $STATE_FILE"
    cat "$STATE_FILE"
    cp "$STATE_FILE" . 2>/dev/null || true

    read_state_uint SUSPEND_SUCCESS
    base_success="$state_value"
    read_state_uint SUSPEND_FAIL
    base_fail="$state_value"
    read_state_uint UPTIME
    pre_uptime="$state_value"
    pre_boot_id="$(get_state BOOT_ID)"
    pre_boundary="$(get_state DMESG_BOUNDARY)"
    if [ -n "$pre_boundary" ] &&
       ! printf '%s\n' "$pre_boundary" | grep -qE '^[0-9]+\.[0-9]+$'; then
        test_result_finish "FAIL" "$TEST_RESULT_NAME FAIL: malformed DMESG_BOUNDARY in $STATE_FILE: $pre_boundary"
    fi

    # A machine that rebooted is also "back up", and its counters and kernel
    # log start from scratch, which would otherwise read as a clean run.
    boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    if [ -z "$pre_boot_id" ] || [ -z "$boot_id" ]; then
        log_warn "resumed-without-reboot: no boot_id to compare, cannot rule out a reboot"
    elif [ "$pre_boot_id" = "$boot_id" ]; then
        test_result_record "PASS" "resumed-without-reboot"
    else
        log_warn "boot_id changed: $pre_boot_id -> $boot_id"
        test_result_record "FAIL" "resumed-without-reboot: the machine rebooted, it did not resume from suspend"
    fi

    if [ -n "$pre_uptime" ]; then
        now_uptime="$(awk '{printf "%d", $1}' /proc/uptime)"
        log_info "time-since-pre-suspend-check: $((now_uptime - pre_uptime)) seconds"
    fi
else
    log_warn "pre-suspend-state-found: $STATE_FILE not found, run Pre_Suspend_Check before the suspend"
    log_warn "Falling back to baselines success=$cli_success fail=$cli_fail"
    base_success="$cli_success"
    base_fail="$cli_fail"
fi

# ---------------------------------------------------------------------------
# What the kernel counted
# ---------------------------------------------------------------------------
read_counter() {
    suspend_uint "$(cat "$STATS_DIR/$1" 2>/dev/null)"
}

if [ -d "$STATS_DIR" ]; then
    cp -r "$STATS_DIR" ./suspend_stats 2>/dev/null || true

    if ! success="$(read_counter success)"; then
        log_warn "suspend-cycle-completed: unreadable $STATS_DIR/success"
    elif [ -z "$base_success" ]; then
        log_warn "suspend-cycle-completed: no success baseline was recorded, relying on the kernel log (success=$success)"
    elif [ "$success" -gt "$base_success" ]; then
        test_result_record "PASS" "suspend-cycle-completed: success=$success, baseline=$base_success"
        resumed=1
    else
        test_result_record "FAIL" "suspend-cycle-completed: no new successful cycle recorded: success=$success, baseline=$base_success"
    fi

    if ! fail="$(read_counter fail)"; then
        log_warn "no-failed-suspend-cycle: unreadable $STATS_DIR/fail"
    elif [ -z "$base_fail" ]; then
        log_warn "no-failed-suspend-cycle: no fail baseline was recorded (fail=$fail)"
    elif [ "$fail" -le "$base_fail" ]; then
        test_result_record "PASS" "no-failed-suspend-cycle"
    else
        log_warn "Last failure: step=$(cat "$STATS_DIR/last_failed_step") dev=$(cat "$STATS_DIR/last_failed_dev") errno=$(cat "$STATS_DIR/last_failed_errno")"
        test_result_record "FAIL" "no-failed-suspend-cycle: failed cycles recorded: fail=$fail, baseline=$base_fail"
    fi

    # Per-phase counters, so a failure points at the phase that broke.
    for phase in $PHASES; do
        [ -r "$STATS_DIR/failed_$phase" ] || continue
        if ! now_failed="$(read_counter "failed_$phase")"; then
            log_warn "no-failures-in-$phase: unreadable $STATS_DIR/failed_$phase"
            continue
        fi
        if [ "$have_state" -eq 1 ]; then
            read_state_uint "FAILED_$phase"
            pre_failed="$state_value"
        else
            pre_failed=0
        fi
        if [ -z "$pre_failed" ]; then
            log_warn "no-failures-in-$phase: no baseline was recorded (failed_$phase=$now_failed)"
        elif [ "$now_failed" -le "$pre_failed" ]; then
            test_result_record "PASS" "no-failures-in-$phase"
        else
            test_result_record "FAIL" "no-failures-in-$phase: failed_$phase=$now_failed, baseline=$pre_failed"
        fi
    done
else
    log_warn "suspend-stats-available: $STATS_DIR not present, kernel built without CONFIG_PM_SLEEP_DEBUG?"
fi

# ---------------------------------------------------------------------------
# What the kernel logged
# ---------------------------------------------------------------------------

# cycle_log is "complete" when it holds every record logged since
# Pre_Suspend_Check, "partial" when the ring buffer dropped some of them, and
# "last-cycle" when it holds the most recent cycle the kernel logged, which is
# all this script can infer without a boundary.
cycle_log=""
scan_dmesg_errors "$LOG_DIR" "PM" "dummy regulator|supply [^ ]+ not found|using dummy regulator" >/dev/null || true
if [ "$DMESG_ACCESS_STATUS" != "available" ]; then
    log_warn "kernel-log-readable: cannot read the kernel log, see $DMESG_ACCESS_LOG"
else
    if [ -n "$pre_boundary" ]; then
        suspend_log_slice "$DMESG_SNAPSHOT" "$pre_boundary" "$DMESG_RESUME_LOG"
        case "$?" in
        0)
            cycle_log="complete"
            ;;
        2)
            cycle_log="partial"
            log_warn "Kernel log ring buffer dropped records logged after the pre-suspend check (boundary $pre_boundary), the cycle may be only partly visible"
            ;;
        *)
            log_warn "Kernel log has no timestamps now, ignoring the recorded boundary $pre_boundary"
            ;;
        esac
    fi

    if [ -z "$cycle_log" ]; then
        start_line="$(grep -nE "$ENTRY_PATTERN" "$DMESG_SNAPSHOT" | tail -n 1 | cut -d: -f1)"
        if [ -n "$start_line" ]; then
            tail -n +"$start_line" "$DMESG_SNAPSHOT" >"$DMESG_RESUME_LOG"
            cycle_log="last-cycle"
        else
            log_warn "The system may not have suspended, or the log ring buffer wrapped"
            test_result_record "FAIL" "resume-logged-in-kernel-log: no suspend entry found in the kernel log"
        fi
    fi
fi

entry_mode=""
if [ -n "$cycle_log" ]; then
    if grep -qE "$ENTRY_PATTERN" "$DMESG_RESUME_LOG"; then
        [ "$cycle_log" = "last-cycle" ] ||
            test_result_record "PASS" "suspend-entered-after-pre-suspend-check"
        entry_mode="$(suspend_entry_mode "$DMESG_RESUME_LOG")"

        if grep -qE "$EXIT_PATTERN" "$DMESG_RESUME_LOG"; then
            test_result_record "PASS" "resume-logged-in-kernel-log"
            resumed=1
        else
            test_result_record "FAIL" "resume-logged-in-kernel-log: no suspend exit logged for the cycle under test"
        fi
    elif [ "$cycle_log" = "complete" ]; then
        test_result_record "FAIL" "suspend-entered-after-pre-suspend-check: no suspend entry logged since the pre-suspend check, the machine may never have suspended"
    else
        # The missing records may be the ones that held the entry.
        log_warn "suspend-entered-after-pre-suspend-check: no suspend entry in the retained records, cannot tell whether it was dropped"
    fi

    grep -E -- "$ERROR_PATTERN" "$DMESG_RESUME_LOG" >"$DMESG_RESUME_LOG.errors" 2>&1
    case "$?" in
    0)
        log_warn "Errors found in the kernel log for the last suspend/resume cycle:"
        cat "$DMESG_RESUME_LOG.errors"
        test_result_record "FAIL" "no-errors-during-resume"
        ;;
    1)
        test_result_record "PASS" "no-errors-during-resume"
        ;;
    *)
        cat "$DMESG_RESUME_LOG.errors"
        test_result_record "FAIL" "no-errors-during-resume: cannot scan $DMESG_RESUME_LOG"
        ;;
    esac
fi

# ---------------------------------------------------------------------------
# Which variant was used
# ---------------------------------------------------------------------------

# The kernel names the variant in "PM: suspend entry (<mode>)", which is the
# evidence for this cycle: a write of "freeze" to /sys/power/state runs s2idle
# whatever /sys/power/mem_sleep selects. Kernels that do not name it leave
# only the selected mem_sleep entry, which stays selected after the cycle.
if [ -n "$entry_mode" ]; then
    used_mode="$entry_mode"
    mode_source="suspend entry"
else
    used_mode="$(suspend_selected_mem_sleep)"
    mode_source="mem_sleep selection"
fi

if [ -z "$SUSPEND_MODE" ] || [ "$SUSPEND_MODE" = "default" ]; then
    log_info "suspend-mode: ${used_mode:-unknown} (from $mode_source)"
elif [ "$used_mode" = "$SUSPEND_MODE" ]; then
    test_result_record "PASS" "suspend-mode-used: $SUSPEND_MODE (from $mode_source)"
else
    test_result_record "FAIL" "suspend-mode-used: expected $SUSPEND_MODE, got ${used_mode:-unknown} (from $mode_source)"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
if [ "$TEST_RESULT_FAIL_COUNT" -gt 0 ]; then
    test_result_finish "FAIL" "$TEST_RESULT_NAME : suspend/resume cycle failed, see messages above"
elif [ "$resumed" -eq 1 ]; then
    test_result_finish "PASS" "$TEST_RESULT_NAME : system resumed from suspend without errors"
else
    test_result_finish "SKIP" "$TEST_RESULT_NAME : neither suspend_stats nor the kernel log could confirm the resume"
fi
