#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# scenario_positive_integer <value> <maximum>
# Validate bounded positive CLI values before arithmetic or hardware access.
scenario_positive_integer() {
    case "$1" in
        ''|*[!0-9]*|0|0*)
            return 1
            ;;
    esac
    awk -v value="$1" -v maximum="$2" 'BEGIN { exit !(value <= maximum) }'
}

# scenario_require <command>...
# Report absent image tools without installing packages or changing services.
scenario_require() {
    local tool missing=0
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            test_result_record SKIP "Image-provided utility is missing: $tool"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

# scenario_command <label> <command>...
# Bound a command using shared process cleanup and retain output under CWD.
scenario_command() {
    local label="$1" status
    shift
    test_result_valid_name "$label" || return 3
    log_info "[$label] command=$* timeout=${SCENARIO_TIMEOUT}s"
    run_with_managed_timeout "$SCENARIO_TIMEOUT" "$SCENARIO_DIR" "$label" \
        "$@" >"$SCENARIO_DIR/$label.log" 2>&1
    status=$?
    log_file_with_label "$label" "$SCENARIO_DIR/$label.log" 40
    return "$status"
}

# scenario_start
# Create fresh evidence and preserve bootstrap stdout cleanup on all exits.
scenario_start() {
    SCENARIO_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || {
        test_result_record FAIL "Cannot create results under CWD=$PWD"
        test_result_finish
    }
    SCENARIO_CLEANUP=""
    SCENARIO_LOAD_PIDS=""
    SCENARIO_FINISHED=0
    SCENARIO_VALIDATED=0
    trap 'scenario_exit "$?"' EXIT
    trap 'scenario_interrupt' INT TERM
    log_info "Scenario=$TESTNAME kernel=$(uname -r) arch=$(uname -m) artifacts=$SCENARIO_DIR"
}

# scenario_cleanup
# Run only test-owned restoration and propagate a restoration failure.
scenario_cleanup() {
    local cleanup="$SCENARIO_CLEANUP"
    local pid
    SCENARIO_CLEANUP=""
    managed_timeout_cancel_bounded 2
    for pid in $SCENARIO_LOAD_PIDS; do
        if ! kill_process "$pid"; then
            test_result_record FAIL "Owned workload PID=$pid could not be stopped before restoration"
        fi
    done
    SCENARIO_LOAD_PIDS=""
    if [ -n "$cleanup" ]; then
        if ! "$cleanup"; then
            test_result_record FAIL "State restoration failed, artifacts=$SCENARIO_DIR"
        fi
    fi
}

# scenario_finish
# Restore state before choosing the final shared PASS/FAIL/SKIP result.
scenario_finish() {
    scenario_cleanup
    SCENARIO_FINISHED=1
    if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$SCENARIO_VALIDATED" -eq 0 ]; then
        test_result_finish SKIP "$TESTNAME SKIP: no selected functional scenario completed, see prerequisite messages"
    fi
    test_result_finish
}

# scenario_interrupt
# Mark interruptions as failures, restore owned state, and publish the result.
scenario_interrupt() {
    trap '' INT TERM
    test_result_record FAIL "Scenario interrupted before validation completed"
    scenario_finish
}

# scenario_exit <exit-status>
# Preserve failed early exits and the repository's stdout capture cleanup.
scenario_exit() {
    local status="$1"
    trap - EXIT
    if [ "$SCENARIO_FINISHED" -ne 1 ]; then
        scenario_cleanup
        test_result_record FAIL "Unexpected exit before validation completed, status=$status"
        SCENARIO_FINISHED=1
        trap 'scenario_exit 0' EXIT
        test_result_finish
    fi
    if [ "${__RUN_STDOUT_ACTIVE:-0}" = 1 ]; then
        # Repository bootstrap API, retain its externally defined name.
        _runner_stdout_cleanup
    fi
}

# scenario_capture_kernel <label>
# Keep snapshots through the shared provider, never directly invoke dmesg.
scenario_capture_kernel() {
    # Existing provider policy, do not require systemd when dmesg is readable.
    # shellcheck disable=SC2034 # Consumed dynamically by scan_dmesg_errors.
    local KERNEL_LOG_JOURNAL_FALLBACK=1
    scan_dmesg_errors "$SCENARIO_DIR/$1" '.*' '^$' || true
    [ "${DMESG_ACCESS_STATUS:-unavailable}" = available ]
}

# scenario_kernel_delta <before-label> <after-label> <pattern>
# Match only appended log lines, refusing to pass when the ring lost baseline.
scenario_kernel_delta() {
    local before="$SCENARIO_DIR/$1/dmesg_snapshot.log"
    local after="$SCENARIO_DIR/$2/dmesg_snapshot.log"
    if [ ! -s "$before" ] || [ ! -s "$after" ]; then
        test_result_record SKIP "Kernel health evidence unavailable, artifacts=$SCENARIO_DIR/$2"
        return 2
    fi
    if ! awk '
        NR == FNR { baseline[FNR] = $0; count++; next }
        FNR <= count { if ($0 != baseline[FNR]) mismatch = 1; next }
        { print }
        END { if (mismatch || FNR < count) exit 2 }
    ' "$before" "$after" >"$SCENARIO_DIR/$2/kernel_delta.log"; then
        test_result_record SKIP "Kernel log baseline changed or was overwritten, scenario health is unverified"
        return 2
    fi
    if grep -Ei "$3" "$SCENARIO_DIR/$2/kernel_delta.log" \
        >"$SCENARIO_DIR/$2/scenario_errors.log"; then
        log_file_with_label KERNEL-ERROR "$SCENARIO_DIR/$2/scenario_errors.log" 30
        test_result_record FAIL "New kernel errors during scenario, artifact=$SCENARIO_DIR/$2/scenario_errors.log"
        return 1
    fi
    test_result_record PASS "No new scenario kernel errors"
}
