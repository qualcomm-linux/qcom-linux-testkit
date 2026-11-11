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

# usage
# Show the suite options and safe defaults.
usage() {
    cat <<EOF
Usage: $0 [options]
Repeated explicit remoteproc stop/start, RPMsg disappearance and complete driver/channel restoration.
  --timeout <value> (default: 60)
  --exercise <value> (default: 0)
  --processors <value> (default: auto)
  --subsystem <family|dsp> (default: unset, dsp selects all identified DSP families)
  --rounds <value> (default: 3)
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
}

parse_args "$@"
test_run_start
log_info "Restart selection processors=$TEST_RUN_PROCESSORS subsystem=${TEST_RUN_SUBSYSTEM:-unset} exercise=$TEST_RUN_EXERCISE"

# ---------- Runtime validation ----------
if [ "$TEST_RUN_EXERCISE" != 1 ] || {
    [ "$TEST_RUN_PROCESSORS" = auto ] && [ -z "${TEST_RUN_SUBSYSTEM:-}" ]
}; then
    test_result_record SKIP "DSP lifecycle changes require --exercise 1 and --subsystem or explicit --processors runtime names or owner IDs"
    test_run_finish
fi
test_require_commands sort cmp readlink awk cat tr find || test_run_finish
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
    if [ -z "$owner" ] || [ ! -d "$owner" ] || [ ! -w "$path/state" ]; then
        test_result_record FAIL "Selected processor=$name lacks a resolved owner or writable lifecycle control, check sysfs access"
        continue
    fi
    if ! wait_remoteproc_boot_ready "$path" "$TEST_RUN_TIMEOUT" 1 \
        "$TEST_RUN_DIR/${path##*/}-boot-ready" "$state"; then
        test_result_record FAIL "Selected processor=$name is not healthy/running within ${TEST_RUN_TIMEOUT}s, inspect boot-readiness artifacts"
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
    state=$(get_remoteproc_state "$path")
    if [ "$state" != running ]; then
        test_result_record FAIL "Selected processor=$name lost running state before restart, state=$state"
        test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
    fi
    remoteproc_channels "$path" >"$TEST_RUN_DIR/${path##*/}-initial-channels" || test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
    remoteproc_children "$path" "$TEST_RUN_DIR/${path##*/}-initial-child-identities" \
        >"$TEST_RUN_DIR/${path##*/}-initial-children" || test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
    printf '%s|%s|%s|%s|%s\n' "$path" "$name" "$firmware" "$state" "$owner" \
        >>"$TEST_RUN_DIR/remoteprocs.changed"
    round=1
    while [ "$round" -le "$TEST_RUN_ROUNDS" ]; do
        label="${path##*/}-round$round"
        before="$TEST_RUN_DIR/$label.channels-before"
        after="$TEST_RUN_DIR/$label.channels-after"
        children="$TEST_RUN_DIR/$label.children-before"
        remoteproc_channels "$path" >"$before" || test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
        remoteproc_children "$path" "$TEST_RUN_DIR/$label.child-identities-before" \
            >"$children" || test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
        test_capture_kernel_log "$label-before" || true
        # shellcheck disable=SC2016 # Child positional arguments expand in the bounded shell.
        if ! test_run_command "$label-stop" sh -c \
            '
                . "$1"
                stop_remoteproc "$2" "$3"
            ' sh "$TOOLS/functestlib.sh" "$path" "$TEST_RUN_TIMEOUT"; then
            test_result_record FAIL "Processor=$name stop/offline failed, round=$round"
            test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
        fi
        remoteproc_channels "$path" >"$after" || test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
        if [ -s "$after" ]; then
            test_result_record FAIL "Processor=$name RPMsg channels remained while offline, artifact=$after"
        else
            test_result_record PASS "Processor=$name offline and channels removed, round=$round"
        fi
        # shellcheck disable=SC2016 # Child positional arguments expand in the bounded shell.
        if ! test_run_command "$label-start" sh -c \
            '
                . "$1"
                start_remoteproc "$2" "$3"
            ' sh "$TOOLS/functestlib.sh" "$path" "$TEST_RUN_TIMEOUT"; then
            test_result_record FAIL "Processor=$name start/running failed, round=$round"
            test_run_finish FAIL "Remoteproc_Restart_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
        fi
        recovered=0
        if remoteproc_wait_restored "$path" "$before" "$children" "$label" 1; then
            recovered=1
        fi
        if [ "$recovered" = 1 ]; then
            if [ -s "$before" ]; then
                test_result_record PASS "Processor=$name channel names, counts and drivers restored, round=$round"
            else
                test_result_record SKIP "Processor=$name exposed no baseline RPMsg channels, channel restoration not exercised"
            fi
            test_result_record PASS "Processor=$name running after restart, round=$round"
            if [ -s "$children" ]; then
                test_result_record PASS "Processor=$name descendant bindings and registered endpoints restored, round=$round"
            else
                test_result_record SKIP "Processor=$name exposed no baseline descendant bindings/registered endpoints, child restoration not exercised"
            fi
            # shellcheck disable=SC2034 # Required by test_run_finish.
            TEST_RUN_VALIDATED=1
        else
            test_result_record FAIL "Processor=$name running state or channel/child restoration failed, round=$round artifacts=$TEST_RUN_DIR/$label.recovery.log"
        fi
        test_capture_kernel_log "$label-after" || true
        test_check_kernel_delta "$label-before" "$label-after" \
            'crash detected|BUG:|WARNING:|Oops:|panic|Call trace:|watchdog (bite|received|interrupt)' || true
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
        round=$((round + 1))
    done
done <"$TEST_RUN_DIR/remoteprocs.selected"
test_run_finish
