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

TESTNAME="CPU_affinity"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0

# usage
# Print the supported options without changing hardware.
usage() {
    printf '%s\n' "Usage: $0 [--help]"
}

# parse_args <arguments...>
# Reject unsupported arguments before test setup.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *)
                test_result_finish FAIL "Unsupported option: $1"
                ;;
        esac
    done
}
parse_args "$@"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies taskset chrt awk grep cat sed tr sleep mkdir mktemp date; then
    test_result_finish SKIP "Image-provided CPU_affinity validation utilities are unavailable"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create evidence under CWD=$PWD"
log_info "Evidence: $OUT_DIR"

TASK_PID=""

# cleanup
# Stop only the child created by this affinity test.
cleanup() {
    if [ -n "$TASK_PID" ]; then
        kill "$TASK_PID" 2>/dev/null || true
        wait "$TASK_PID" 2>/dev/null || true
        TASK_PID=""
    fi
}
trap cleanup 0
trap 'test_result_finish FAIL "CPU affinity validation interrupted"' HUP INT TERM

selected_cpu=""
for candidate_cpu in $(get_online_cpus); do
    if cpu_is_schedulable "$candidate_cpu"; then
        selected_cpu="$candidate_cpu"
        break
    fi
done
[ -n "$selected_cpu" ] || test_result_finish SKIP "No online CPU is schedulable in this session"

# cpu_task
# Keep one test-owned process alive, with no descendants to leak on interruption.
cpu_task() {
    while :; do
        :
    done
}
cpu_task &
TASK_PID=$!
if taskset -pc "$selected_cpu" "$TASK_PID" >"$OUT_DIR/taskset.log" 2>&1; then
    if taskset -pc "$TASK_PID" >"$OUT_DIR/effective-affinity.log" 2>&1; then
        actual_cpu=$(awk -F ': ' 'NF > 1 {print $NF}' "$OUT_DIR/effective-affinity.log")
        if [ "$actual_cpu" = "$selected_cpu" ]; then
            test_result_record PASS "Affinity assignment verified on CPU$selected_cpu"
        else
            test_result_record FAIL "Effective affinity '$actual_cpu' differs from CPU$selected_cpu"
        fi
    else
        test_result_record FAIL "Could not read effective affinity"
    fi
else
    test_result_record FAIL "Affinity assignment command failed on CPU$selected_cpu"
fi
log_file_with_label AFFINITY "$OUT_DIR/taskset.log"
log_file_with_label AFFINITY "$OUT_DIR/effective-affinity.log"
if chrt -p "$TASK_PID" >"$OUT_DIR/policy.log" 2>&1 &&
   grep -q 'SCHED_OTHER' "$OUT_DIR/policy.log"; then
    test_result_record PASS "Default scheduling policy is SCHED_OTHER"
else
    test_result_record FAIL "Default scheduling policy was not confirmed"
fi
test_result_finish
