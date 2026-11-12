#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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

TESTNAME="Remoteproc_Restart_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

TEST_RUN_TIMEOUT="60"
TEST_RUN_EXERCISE="0"
TEST_RUN_PROCESSORS="auto"
TEST_RUN_SUBSYSTEM=""
TEST_RUN_ROUNDS="3"
TEST_RUN_MODE="stop-start"
TEST_RUN_STABLE_SECONDS="2"

# usage
# Show the suite options and safe defaults.
usage() {
    cat <<EOF
Usage: $0 [options]
Repeated explicit remoteproc stop/start, RPMsg disappearance and complete driver/channel restoration.
Crash mode injects a synthetic watchdog report and validates automatic recovery.
  --timeout <value> (default: 60)
  --exercise <value> (default: 0)
  --processors <value> (default: auto)
  --subsystem <family|dsp> (default: unset, dsp selects all identified DSP families)
  --rounds <value> (default: 3)
  --mode <stop-start|crash> (default: stop-start)
  --stable-seconds <value> (default: 2, 0 disables the added stability interval)
  --help
EOF
}

# parse_args <arguments>...
# Reject malformed overrides before runtime discovery or state changes.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_record FAIL "Missing value for $1"
            test_result_finish
        fi
        case "$2" in
            --*)
                test_result_record FAIL "Missing value for $1 before option=$2"
                test_result_finish
                ;;
        esac
        case "$1" in
            --timeout)
                TEST_RUN_TIMEOUT="$2"
                ;;
            --exercise)
                TEST_RUN_EXERCISE="$2"
                ;;
            --processors)
                TEST_RUN_PROCESSORS="$2"
                ;;
            --subsystem)
                TEST_RUN_SUBSYSTEM="$2"
                ;;
            --rounds)
                TEST_RUN_ROUNDS="$2"
                ;;
            --stable-seconds)
                TEST_RUN_STABLE_SECONDS="$2"
                ;;
            --mode)
                TEST_RUN_MODE="$2"
                ;;
            *)
                test_result_record FAIL "Unknown option: $1"
                test_result_finish
                ;;
        esac
        shift 2
    done
    if ! {
        is_bounded_positive_integer "$TEST_RUN_TIMEOUT" 600
    }; then
        test_result_record FAIL "Invalid value for --timeout: $TEST_RUN_TIMEOUT"
        test_result_finish
    fi
    if ! {
        [ "$TEST_RUN_EXERCISE" = 0 ] || [ "$TEST_RUN_EXERCISE" = 1 ]
    }; then
        test_result_record FAIL "Invalid value for --exercise: $TEST_RUN_EXERCISE"
        test_result_finish
    fi
    if ! {
        printf '%s\n' "$TEST_RUN_PROCESSORS" | awk '/^[A-Za-z0-9_.:@-]+(,[A-Za-z0-9_.:@-]+)*$/ {ok=1} END {exit !ok}'
    }; then
        test_result_record FAIL "Invalid value for --processors: $TEST_RUN_PROCESSORS"
        test_result_finish
    fi
    if ! {
        is_bounded_positive_integer "$TEST_RUN_ROUNDS" 10
    }; then
        test_result_record FAIL "Invalid value for --rounds: $TEST_RUN_ROUNDS"
        test_result_finish
    fi
    if [ -n "$TEST_RUN_SUBSYSTEM" ] && ! printf '%s\n' "$TEST_RUN_SUBSYSTEM" | \
        awk '/^[a-z]*dsp$/ {ok=1} END {exit !ok}'; then
        test_result_record FAIL "Invalid value for --subsystem: $TEST_RUN_SUBSYSTEM, use dsp or a DSP family such as adsp"
        test_result_finish
    fi
    if [ "$TEST_RUN_STABLE_SECONDS" != 0 ] &&
        ! is_bounded_positive_integer "$TEST_RUN_STABLE_SECONDS" "$TEST_RUN_TIMEOUT"; then
        test_result_record FAIL "Invalid value for --stable-seconds: $TEST_RUN_STABLE_SECONDS, use 0 or an integer not exceeding --timeout"
        test_result_finish
    fi
    case "$TEST_RUN_MODE" in
        stop-start|crash)
            ;;
        *)
            test_result_record FAIL "Invalid value for --mode: $TEST_RUN_MODE"
            test_result_finish
            ;;
    esac
}

parse_args "$@"
test_run_start
log_info "Restart selection processors=$TEST_RUN_PROCESSORS subsystem=${TEST_RUN_SUBSYSTEM:-unset} exercise=$TEST_RUN_EXERCISE mode=$TEST_RUN_MODE stable_seconds=$TEST_RUN_STABLE_SECONDS"

# ---------- Runtime validation ----------
if [ "$TEST_RUN_EXERCISE" != 1 ] || {
    [ "$TEST_RUN_PROCESSORS" = auto ] && [ -z "${TEST_RUN_SUBSYSTEM:-}" ]
}; then
    test_result_record SKIP "DSP lifecycle changes require --exercise 1 and --subsystem or explicit --processors runtime names or owner IDs"
    test_run_finish
fi
test_require_commands sort cmp readlink awk cat tr find sleep sh sed || test_run_finish
if [ "$TEST_RUN_MODE" = crash ]; then
    test_require_commands grep || test_run_finish
fi
remoteproc_inventory || true
if [ "$TEST_RUN_PROCESSORS" = auto ]; then
    test_require_commands find || test_run_finish
    if ! remoteproc_select_subsystem "$TEST_RUN_SUBSYSTEM" &&
        [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$TEST_RESULT_SKIP_COUNT" -eq 0 ]; then
        test_result_record FAIL "Automatic DSP selection could not complete, inspect artifacts=$TEST_RUN_DIR"
    fi
else
    for token in $(printf '%s\n' "$TEST_RUN_PROCESSORS" | tr ',' ' '); do
        matches=$(awk -F '|' -v token="$token" '
            { owner = $5; sub(/^.*\//, "", owner); if ($2 == token || owner == token) count++ }
            END { print count + 0 }
        ' "$TEST_RUN_DIR/remoteprocs.selected")
        if [ "$matches" -gt 1 ]; then
            test_result_record FAIL "Processor selection=$token is ambiguous, use a unique runtime owner ID or --subsystem"
        fi
    done
fi
if [ "$TEST_RESULT_FAIL_COUNT" -ne 0 ]; then
    test_run_finish
fi
# Validate every selected instance before changing any processor.
while IFS='|' read -r path name firmware state owner; do
    if [ "$state" = attached ] || [ "$state" = detached ]; then
        test_result_record SKIP "Processor=$name is externally owned, state=$state cannot exercise Linux stop/start"
        continue
    fi
    if [ -z "$owner" ] || [ ! -d "$owner" ] || {
        [ "$TEST_RUN_MODE" = stop-start ] && [ ! -w "$path/state" ]
    }; then
        test_result_record FAIL "Selected processor=$name lacks a resolved owner or required lifecycle-control access, check sysfs access"
        continue
    fi
    if [ "$TEST_RUN_MODE" = stop-start ] && ! wait_remoteproc_boot_ready "$path" "$TEST_RUN_TIMEOUT" 1 \
        "$TEST_RUN_DIR/${path##*/}-boot-ready" "$state"; then
        test_result_record FAIL "Selected processor=$name is not healthy/running within ${TEST_RUN_TIMEOUT}s, inspect boot-readiness artifacts"
    fi
    if [ "$TEST_RUN_MODE" = crash ]; then
        control=$(remoteproc_debugfs_dir "$path")
        control_status=$?
        if [ "$control_status" = 2 ] || {
            [ "$control_status" = 0 ] && [ ! -e "$control/crash" ]
        }; then
            test_result_record SKIP "Processor=$name has no mounted debugfs crash capability, supply image-provided debugfs for crash coverage"
            continue
        elif [ "$control_status" != 0 ] || [ ! -w "$control/crash" ]; then
            test_result_record FAIL "Processor=$name debugfs identity or crash-control access cannot be validated"
            continue
        fi
        recovery="$path/recovery"
        coredump="$path/coredump"
        [ -e "$recovery" ] || recovery="$control/recovery"
        [ -e "$coredump" ] || coredump="$control/coredump"
        policy=$(cat "$recovery")
        policy_status=$?
        dump=$(cat "$coredump")
        dump_status=$?
        if [ "$policy_status" != 0 ] || [ "$dump_status" != 0 ] || {
            [ "$policy" != enabled ] && [ "$policy" != disabled ]
        } || {
            [ "$dump" != disabled ] && [ "$dump" != enabled ] && [ "$dump" != inline ]
        }; then
            test_result_record FAIL "Processor=$name recovery/coredump policy is unreadable or unknown, no injection allowed"
            continue
        fi
        log_info "Processor=$name crash_control=$control/crash recovery=$policy coredump=$dump"
        if [ "$policy" = disabled ] || [ "$dump" = inline ]; then
            test_result_record SKIP "Processor=$name automatic recovery cannot be exercised with recovery=$policy coredump=$dump, policies retained"
            continue
        fi
        # Recovery testing evaluates new faults, prior deliberate injections stay visible
        # in the baseline without making a healthy rerun fail its boot-history check.
        if ! test_capture_kernel_log "${path##*/}-ready-before"; then
            test_result_record FAIL "Processor=$name crash testing requires readable kernel evidence"
            continue
        fi
        if [ "$state" = crashed ] || ! wait_remoteproc_state "$path" running "$TEST_RUN_TIMEOUT" 1; then
            test_result_record FAIL "Processor=$name is not running before crash testing, no bring-up attempted"
        fi
        test_capture_kernel_log "${path##*/}-ready-after" || true
        if ! test_check_kernel_delta "${path##*/}-ready-before" "${path##*/}-ready-after" \
            'crash detected|BUG:|WARNING:|Oops:|panic|Call trace:|watchdog (bite|received|interrupt)|fatal error|hard lockup|rcu:.*detected.*stalls'; then
            test_result_record FAIL "Processor=$name readiness lacks continuous healthy kernel evidence"
        fi
        printf '%s|%s|%s|%s|%s\n' "$control" "$recovery" "$coredump" "$policy" "$dump" \
            >"$TEST_RUN_DIR/${path##*/}-crash-controls" ||
            test_run_finish FAIL "Cannot retain crash-control baseline under $TEST_RUN_DIR"
    fi
done <"$TEST_RUN_DIR/remoteprocs.selected"
[ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] || test_run_finish
: >"$TEST_RUN_DIR/remoteprocs.changed"
# shellcheck disable=SC2034 # Consumed by test_run_cleanup in functestlib.sh.
TEST_RUN_CLEANUP=remoteproc_restore
while IFS='|' read -r path name firmware state owner; do
    if [ "$state" = attached ] || [ "$state" = detached ]; then
        continue
    fi
    if [ "$TEST_RUN_MODE" = crash ] && [ ! -s "$TEST_RUN_DIR/${path##*/}-crash-controls" ]; then
        continue
    fi
    state=$(get_remoteproc_state "$path")
    if [ "$state" != running ]; then
        test_result_record FAIL "Selected processor=$name lost running state before restart, state=$state"
        test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
    fi
    if [ "$TEST_RUN_MODE" = crash ]; then
        IFS='|' read -r control recovery coredump policy dump \
            <"$TEST_RUN_DIR/${path##*/}-crash-controls" ||
            test_run_finish FAIL "Cannot read recorded crash controls for processor=$name"
        printf '%s|%s|%s|%s\n' "$recovery" "$coredump" "$policy" "$dump" \
            >"$TEST_RUN_DIR/${path##*/}-initial-controls" ||
            test_run_finish FAIL "Cannot retain owned recovery controls for processor=$name"
    fi
    round=1
    while [ "$round" -le "$TEST_RUN_ROUNDS" ]; do
        label="${path##*/}-round$round"
        before="$TEST_RUN_DIR/$label.channels-before"
        children="$TEST_RUN_DIR/$label.children-before"
        baseline_channels=""
        baseline_children=""
        if [ "$round" -gt 1 ]; then
            baseline_channels="$TEST_RUN_DIR/${path##*/}-initial-channels"
            baseline_children="$TEST_RUN_DIR/${path##*/}-initial-children"
        fi
        baseline_ok=1
        if ! test_capture_kernel_log "$label-before" && [ "$TEST_RUN_MODE" = crash ]; then
            test_run_finish FAIL "Crash testing requires readable evidence before baseline stabilization"
        fi
        if ! remoteproc_wait_restored "$path" "$baseline_channels" "$baseline_children" \
            "$label-baseline" 0 0 "$TEST_RUN_STABLE_SECONDS"; then
            baseline_ok=0
            test_result_record FAIL "Processor=$name baseline did not stabilize within ${TEST_RUN_TIMEOUT}s, no mutation allowed"
        fi
        test_capture_kernel_log "$label-baseline-after" || true
        baseline_kernel_status=0
        test_check_kernel_delta "$label-before" "$label-baseline-after" \
            'crash detected|BUG:|WARNING:|Oops:|panic|Call trace:|watchdog (bite|received|interrupt)|fatal error|hard lockup|rcu:.*detected.*stalls' || baseline_kernel_status=$?
        if [ "$TEST_RUN_MODE" = crash ] && [ "$baseline_kernel_status" != 0 ]; then
            test_result_record FAIL "Processor=$name stable baseline lacks continuous healthy kernel evidence"
        fi
        if [ -r "$TEST_RUN_DIR/$label-baseline-after/kernel_delta.log" ]; then
            if ! remoteproc_child_faults "$TEST_RUN_DIR/$label-baseline-after/kernel_delta.log" \
                "$TEST_RUN_DIR/$label-baseline.child-identities" "$TEST_RUN_DIR/$label-baseline.child-diagnostics.log" \
                >"$TEST_RUN_DIR/$label-baseline.child-errors.log"; then
                test_result_record FAIL "Cannot evaluate child-driver evidence during baseline stabilization for processor=$name"
            elif [ -s "$TEST_RUN_DIR/$label-baseline.child-errors.log" ]; then
                log_file_with_label DSP-CHILD-ERROR "$TEST_RUN_DIR/$label-baseline.child-errors.log" 30
                test_result_record FAIL "Processor=$name has terminal child-driver faults before mutation"
            fi
            log_file_with_label DSP-CHILD-DIAGNOSTIC "$TEST_RUN_DIR/$label-baseline.child-diagnostics.log" 20
        fi
        if [ "$baseline_ok" != 1 ] || [ "$TEST_RESULT_FAIL_COUNT" -ne 0 ]; then
            test_run_finish
        fi
        if ! {
            cat "$TEST_RUN_DIR/$label-baseline.channels-after" >"$before" &&
                cat "$TEST_RUN_DIR/$label-baseline.children-after" >"$children" &&
                cat "$TEST_RUN_DIR/$label-baseline.child-identities" >"$TEST_RUN_DIR/$label.child-identities-before"
        }; then
            test_run_finish FAIL "Cannot retain stable baseline for processor=$name"
        fi
        if [ "$round" = 1 ]; then
            if ! {
                cat "$before" >"$TEST_RUN_DIR/${path##*/}-initial-channels" &&
                    cat "$children" >"$TEST_RUN_DIR/${path##*/}-initial-children" &&
                    cat "$TEST_RUN_DIR/$label.child-identities-before" >"$TEST_RUN_DIR/${path##*/}-initial-child-identities"
            }; then
                test_run_finish FAIL "Cannot retain original cleanup baseline for processor=$name"
            fi
        fi
        if [ "$TEST_RUN_MODE" = crash ]; then
            IFS='|' read -r control recovery coredump policy dump \
                <"$TEST_RUN_DIR/${path##*/}-crash-controls" ||
                test_run_finish FAIL "Cannot read recorded crash controls for processor=$name"
            if [ "$(get_remoteproc_state "$path")" != running ] ||
                [ "$(readlink -f "$path/device")" != "$owner" ] ||
                [ ! -L "$owner/driver" ] ||
                [ ! -d "$(readlink -f "$owner/driver")" ] ||
                [ "$(cat "$path/firmware")" != "$firmware" ] ||
                [ "$(cat "$control/name")" != "$name" ] ||
                [ "$(cat "$recovery")" != "$policy" ] || [ "$(cat "$coredump")" != "$dump" ]; then
                test_run_finish FAIL "Processor=$name state, identity, firmware or recovery policy changed before injection"
            fi
            if [ "$round" = 1 ]; then
                printf '%s|%s|%s|%s|%s\n' "$path" "$name" "$firmware" "$state" "$owner" \
                    >>"$TEST_RUN_DIR/remoteprocs.changed" ||
                    test_run_finish FAIL "Cannot retain injection ownership for processor=$name"
                # shellcheck disable=SC2034 # Opt-in consumed by shared test_run_cleanup.
                TEST_RUN_CLEANUP_KERNEL_PATTERN='BUG:|WARNING:|Oops:|panic|Call trace:|Internal error|Unable to handle|external abort|hard lockup|rcu:.*detected.*stalls|fatal error|watchdog (bite|received|interrupt)'
            fi
            # Only one synthetic watchdog report, no firmware or IRQ crash asserted.
            # shellcheck disable=SC2016 # Positional arguments belong to the bounded child.
            if ! test_run_command "$label-crash" sh -c \
                'printf "%s\n" 1 >"$1"' sh "$control/crash"; then
                test_run_finish FAIL "Processor=$name crash injection failed, round=$round"
            fi
        else
            if [ "$round" = 1 ]; then
                printf '%s|%s|%s|%s|%s\n' "$path" "$name" "$firmware" "$state" "$owner" \
                    >>"$TEST_RUN_DIR/remoteprocs.changed" ||
                    test_run_finish FAIL "Cannot retain lifecycle ownership for processor=$name"
            fi
            # shellcheck disable=SC2016 # Child positional arguments expand in the bounded shell.
            if ! test_run_command "$label-stop" sh -c \
                '
                    . "$1"
                    stop_remoteproc "$2" "$3"
                ' sh "$TOOLS/functestlib.sh" "$path" "$TEST_RUN_TIMEOUT"; then
                test_result_record FAIL "Processor=$name stop/offline failed, round=$round"
                test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
            fi
            if ! remoteproc_wait_quiescent "$path" "$label" "$TEST_RUN_STABLE_SECONDS"; then
                test_run_finish FAIL "Processor=$name offline/RPMsg teardown did not stabilize, no functional start allowed, round=$round"
            fi
            test_result_record PASS "Processor=$name offline and channels removed stably, round=$round"
            # shellcheck disable=SC2016 # Child positional arguments expand in the bounded shell.
            if ! test_run_command "$label-start" sh -c \
                '
                    . "$1"
                    start_remoteproc "$2" "$3"
                ' sh "$TOOLS/functestlib.sh" "$path" "$TEST_RUN_TIMEOUT"; then
                test_result_record FAIL "Processor=$name start/running failed, round=$round"
                test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
            fi
        fi
        recovered=0
        wait_running=0
        [ "$TEST_RUN_MODE" != crash ] || wait_running=1
        if remoteproc_wait_restored "$path" "$before" "$children" "$label" 1 "$wait_running" "$TEST_RUN_STABLE_SECONDS"; then
            recovered=1
        fi
        if [ "$recovered" = 1 ]; then
            if [ -s "$before" ]; then
                test_result_record PASS "Processor=$name channel names, counts and drivers restored, round=$round"
            else
                test_result_record SKIP "Processor=$name exposed no baseline RPMsg channels, channel restoration not exercised"
            fi
            test_result_record PASS "Processor=$name running after mode=$TEST_RUN_MODE, round=$round"
            if [ -s "$children" ]; then
                test_result_record PASS "Processor=$name descendant bindings and registered endpoints restored, round=$round"
            else
                test_result_record SKIP "Processor=$name exposed no baseline descendant bindings/registered endpoints, child restoration not exercised"
            fi
            if [ "$TEST_RUN_MODE" = stop-start ]; then
                # shellcheck disable=SC2034 # Required by test_run_finish.
                TEST_RUN_VALIDATED=1
            fi
        else
            test_result_record FAIL "Processor=$name running state or channel/child restoration failed, round=$round artifacts=$TEST_RUN_DIR/$label.recovery.log"
        fi
        test_capture_kernel_log "$label-after" || true
        kernel_status=0
        if [ "$TEST_RUN_MODE" = crash ]; then
            test_check_kernel_delta "$label-before" "$label-after" \
                'BUG:|WARNING:|Oops:|panic|Call trace:|Internal error|Unable to handle|external abort|hard lockup|rcu:.*detected.*stalls' || kernel_status=$?
            if ! remoteproc_check_crash_events "$path" "$name" "$TEST_RUN_DIR/$label-after/kernel_delta.log" \
                "$TEST_RUN_DIR/$label.crash-events.log" "$TEST_RUN_DIR/$label.unexpected-faults.log" "$owner"; then
                test_result_record FAIL "Processor=$name lacks one confirmed crash/recovery/boot sequence or has unexpected faults, round=$round"
            elif [ "$kernel_status" = 0 ] && [ "$recovered" = 1 ]; then
                test_result_record PASS "Processor=$name one injected crash recovered automatically with complete runtime restoration, round=$round"
                # shellcheck disable=SC2034 # Required by test_run_finish.
                TEST_RUN_VALIDATED=1
            elif [ "$kernel_status" != 0 ]; then
                test_result_record FAIL "Processor=$name crash recovery lacks continuous healthy kernel evidence, round=$round"
            fi
            log_file_with_label DSP-CRASH "$TEST_RUN_DIR/$label.crash-events.log" 10
            log_file_with_label DSP-UNEXPECTED-FAULT "$TEST_RUN_DIR/$label.unexpected-faults.log" 30
            if [ "$(cat "$recovery")" != "$policy" ] || [ "$(cat "$coredump")" != "$dump" ] ||
                [ "$(cat "$path/firmware")" != "$firmware" ]; then
                test_result_record FAIL "Processor=$name firmware or policies changed during crash recovery"
            fi
        else
            test_check_kernel_delta "$label-before" "$label-after" \
                'crash detected|BUG:|WARNING:|Oops:|panic|Call trace:|watchdog (bite|received|interrupt)' || true
        fi
        if [ -r "$TEST_RUN_DIR/$label-after/kernel_delta.log" ]; then
            if ! cat "$TEST_RUN_DIR/$label.child-identities-before" \
                "$TEST_RUN_DIR/$label.child-identities" >"$TEST_RUN_DIR/$label.child-identities-all" ||
                ! remoteproc_child_faults "$TEST_RUN_DIR/$label-after/kernel_delta.log" \
                    "$TEST_RUN_DIR/$label.child-identities-all" "$TEST_RUN_DIR/$label.child-diagnostics.log" \
                    >"$TEST_RUN_DIR/$label.child-errors.log"; then
                test_result_record FAIL "Cannot evaluate captured child-driver faults for processor=$name, round=$round"
            elif [ -s "$TEST_RUN_DIR/$label.child-errors.log" ]; then
                log_file_with_label DSP-CHILD-ERROR "$TEST_RUN_DIR/$label.child-errors.log" 30
                test_result_record FAIL "Processor=$name has new terminal child-driver failures, round=$round"
            fi
            if [ -s "$TEST_RUN_DIR/$label.child-diagnostics.log" ]; then
                log_file_with_label DSP-CHILD-DIAGNOSTIC "$TEST_RUN_DIR/$label.child-diagnostics.log" 20
                log_warn "Processor=$name has child command/probe diagnostics, verdict uses terminal faults and endpoint restoration"
            fi
        fi
        if [ "$TEST_RUN_MODE" = crash ] && [ "$TEST_RESULT_FAIL_COUNT" -ne 0 ]; then
            test_run_finish
        fi
        round=$((round + 1))
    done
done <"$TEST_RUN_DIR/remoteprocs.selected"
test_run_finish
