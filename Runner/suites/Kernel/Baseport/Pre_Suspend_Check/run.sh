#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Record the state of the machine before it is suspended, so that
# Resume_Check can tell afterwards whether a suspend/resume cycle really
# happened and whether it introduced any errors.
#
# This script does not suspend the machine. Run it, then trigger the suspend
# by whatever means the job uses, then run Resume_Check once the machine is
# back up.

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

TESTNAME="Pre_Suspend_Check"
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

# Kept out of the test directory so that Resume_Check can read it even when
# it runs from a different action. /tmp is tmpfs on most images, so the file
# does not survive a reboot, which is what we want: state from a previous boot
# must never look like a valid baseline.
STATE_FILE="${STATE_FILE:-/tmp/pre-suspend-state.txt}"
# When set, check that this sleep state is offered by /sys/power/state.
SLEEP_MODE="${SLEEP_MODE:-}"
# Suspend-to-RAM variant the job is about to use (default, s2idle, shallow or
# deep). When set, it is appended to the result name, and a mode other than
# default must be offered by /sys/power/mem_sleep.
SUSPEND_MODE="${SUSPEND_MODE:-}"

STATS_DIR="/sys/power/suspend_stats"
# Phases with a failed_<phase> counter in $STATS_DIR.
PHASES="freeze prepare suspend suspend_late suspend_noirq resume resume_early resume_noirq"
LOG_DIR="./kernel-log"

usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --state-file PATH     where to save the recorded state (default: /tmp/pre-suspend-state.txt)" \
        "  --sleep-mode STATE    check that STATE (mem|freeze|standby|disk) is offered by /sys/power/state" \
        "  --suspend-mode MODE   suspend-to-RAM variant (default|s2idle|shallow|deep), appended to the result name" \
        "  -h, --help" \
        "CLI options override environment variables."
}

# Argument errors are collected rather than fatal, so that the result can
# still carry the requested mode in its name.
arg_error=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --state-file | --sleep-mode | --suspend-mode)
        if [ "$#" -lt 2 ]; then
            arg_error="option $1 requires a value"
            break
        fi
        case "$1" in
        --state-file) STATE_FILE="$2" ;;
        --sleep-mode) SLEEP_MODE="$2" ;;
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

case "$SLEEP_MODE" in
"" | mem | freeze | standby | disk) ;;
*) arg_error="${arg_error:-unknown sleep state: $SLEEP_MODE}" ;;
esac

[ -n "$STATE_FILE" ] || arg_error="${arg_error:-the state file path is empty}"

if [ -n "$arg_error" ]; then
    usage
    test_result_finish "FAIL" "$TEST_RESULT_NAME FAIL: $arg_error"
fi

if conflict=$(suspend_state_mode_conflict "$SLEEP_MODE" "$SUSPEND_MODE"); then
    test_result_finish "FAIL" "$TEST_RESULT_NAME FAIL: $conflict"
fi

log_info "----------------------------------------------------------------------------"
log_info "------------------- Starting $TEST_RESULT_NAME Testcase ----------------------------"

# Failed prerequisites fail the test. Missing baselines only weaken what
# Resume_Check can verify, so they are reported as warnings.

# ---------------------------------------------------------------------------
# Is the machine in a state where a suspend can be expected to work?
# ---------------------------------------------------------------------------
if [ -r "/sys/power/state" ]; then
    test_result_record "PASS" "kernel-supports-suspend: sleep states offered: $(cat /sys/power/state)"
else
    test_result_record "FAIL" "kernel-supports-suspend: /sys/power/state is missing, kernel has no suspend support"
fi

if [ -n "$SLEEP_MODE" ]; then
    if grep -qw -- "$SLEEP_MODE" /sys/power/state 2>/dev/null; then
        test_result_record "PASS" "sleep-mode-supported: $SLEEP_MODE"
    else
        test_result_record "FAIL" "sleep-mode-supported: $SLEEP_MODE not offered by /sys/power/state"
    fi
fi

# "default" keeps whatever the kernel selected, so only an explicit variant
# has to be offered.
if [ -n "$SUSPEND_MODE" ] && [ "$SUSPEND_MODE" != "default" ]; then
    if suspend_mem_sleep_offers "$SUSPEND_MODE"; then
        test_result_record "PASS" "suspend-mode-supported: $SUSPEND_MODE, mem_sleep: $(cat /sys/power/mem_sleep)"
    else
        test_result_record "FAIL" "suspend-mode-supported: $SUSPEND_MODE not offered by /sys/power/mem_sleep ($(cat /sys/power/mem_sleep 2>/dev/null))"
    fi
fi

# ---------------------------------------------------------------------------
# Collect the baseline
# ---------------------------------------------------------------------------

# Identifies the running kernel instance. If this changes by the time
# Resume_Check runs, the machine rebooted instead of resuming.
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
if [ -n "$boot_id" ]; then
    log_info "boot-id-recorded: $boot_id"
else
    log_warn "boot-id-recorded: cannot read boot_id, a reboot will not be distinguishable from a resume"
fi

# The counters are cumulative for the boot. An empty value tells
# Resume_Check that the baseline is unavailable rather than zero.
read_counter() {
    suspend_uint "$(cat "$STATS_DIR/$1" 2>/dev/null)"
}

suspend_success=""
suspend_fail=""
if [ -d "$STATS_DIR" ]; then
    suspend_success="$(read_counter success)"
    suspend_fail="$(read_counter fail)"
    if [ -n "$suspend_success" ] && [ -n "$suspend_fail" ]; then
        log_info "suspend-stats-available: success=$suspend_success fail=$suspend_fail"
    else
        log_warn "suspend-stats-available: unreadable or malformed counters in $STATS_DIR"
    fi
else
    log_warn "suspend-stats-available: $STATS_DIR not present, no cycle counters to baseline"
fi

# Timestamp of the newest kernel log record. Resume_Check scans only the
# records stamped after it, so nothing logged before the suspend can be
# mistaken for a resume error, and it can tell when the ring buffer has
# dropped records it needs.
dmesg_boundary=""
scan_dmesg_errors "$LOG_DIR" "PM" "dummy regulator|supply [^ ]+ not found|using dummy regulator" >/dev/null || true
if [ "$DMESG_ACCESS_STATUS" != "available" ]; then
    log_warn "kernel-log-readable: cannot read the kernel log, see $DMESG_ACCESS_LOG"
elif dmesg_boundary="$(suspend_log_boundary "$DMESG_SNAPSHOT")"; then
    log_info "kernel-log-boundary: $dmesg_boundary"
else
    log_warn "kernel-log-boundary: kernel log has no timestamps (CONFIG_PRINTK_TIME?), Resume_Check falls back to the last logged cycle"
fi

uptime_seconds="$(awk '{printf "%d", $1}' /proc/uptime)"

# ---------------------------------------------------------------------------
# Save it
# ---------------------------------------------------------------------------
rm -f "$STATE_FILE"
{
    echo "BOOT_ID=$boot_id"
    echo "UPTIME=$uptime_seconds"
    echo "SUSPEND_SUCCESS=$suspend_success"
    echo "SUSPEND_FAIL=$suspend_fail"
    echo "DMESG_BOUNDARY=$dmesg_boundary"
    # Per-phase failure counters are cumulative for the boot too, so
    # Resume_Check needs them to tell new failures from earlier ones.
    if [ -d "$STATS_DIR" ]; then
        for phase in $PHASES; do
            [ -r "$STATS_DIR/failed_$phase" ] || continue
            echo "FAILED_$phase=$(read_counter "failed_$phase")"
        done
    fi
} >"$STATE_FILE" 2>/dev/null

if [ -s "$STATE_FILE" ]; then
    test_result_record "PASS" "pre-suspend-state-saved: $STATE_FILE"
    cat "$STATE_FILE"
    cp "$STATE_FILE" . 2>/dev/null || true
else
    test_result_record "FAIL" "pre-suspend-state-saved: failed to write $STATE_FILE"
fi

test_result_finish
