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
# shellcheck disable=SC1091
. "$TOOLS/lib_performance.sh"

TESTNAME="Scheduler_IPC_Stress"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
test_result_init "$TESTNAME" "$RES_FILE"
DURATION=300
CPU_LIST=""
WORKERS=""
REPEAT=1
TIMEOUT_MARGIN=120

usage() {
    cat <<EOF
Usage: $0 [--duration SECONDS] [--repeat COUNT] [--cpu-list LIST]
  --workers N, default allowed online CPUs per selected stressor
  --timeout-margin SECONDS, default 120
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
        esac
        [ "$#" -ge 2 ] || return 1
        case "$1" in
            --duration)
                DURATION=$2
                ;;
            --repeat)
                REPEAT=$2
                ;;
            --cpu-list)
                CPU_LIST=$2
                ;;
            --timeout-margin)
                TIMEOUT_MARGIN=$2
                ;;
            --workers)
                WORKERS=$2
                ;;
            *)
                return 1
                ;;
        esac
        shift 2
    done
}

cleanup() {
    managed_timeout_cancel_bounded
}
# shellcheck disable=SC2034  # Shared result finalizer invokes cleanup.
TEST_RESULT_CLEANUP=cleanup
# shellcheck disable=SC2034  # Shared timeout helper configuration.
MANAGED_TIMEOUT_USE_SESSION=1
trap 'test_result_finish FAIL "Stress validation interrupted"' HUP INT TERM
trap cleanup EXIT
parse_args "$@" || test_result_finish FAIL "Invalid argument, use --help"
for value in "$DURATION" "$REPEAT" "$TIMEOUT_MARGIN"; do
    perf_uint_in_range "$value" 1 2147483647 || test_result_finish FAIL "Duration, repeat and timeout must be positive integers"
done
for tool in stress-ng awk grep sort taskset setsid; do
    command -v "$tool" >/dev/null 2>&1 || test_result_finish SKIP "Image-provided $tool is required"
done
CPUS=$(perf_allowed_cpus "$CPU_LIST") || test_result_finish FAIL "Cannot select allowed online CPUs"
taskset -c "$CPUS" true || test_result_finish FAIL "Cannot apply CPU affinity $CPUS"
CPU_COUNT=$(printf '%s\n' "$CPUS" | awk -F, '{print NF}')
RUN_DIR=$(test_create_run_directory "$SCRIPT_DIR/logs") || test_result_finish FAIL "Cannot create evidence directory"
START_UPTIME=$(awk '{print $1}' /proc/uptime)
ITERATION=1

WORKERS=${WORKERS:-$CPU_COUNT}
perf_uint_in_range "$WORKERS" 1 1048576 || test_result_finish FAIL "Invalid worker count"
stress-ng --help >"$RUN_DIR/help.log" 2>&1
for option in switch futex pipe; do
    grep -Eq -- "--${option}[[:space:]]" "$RUN_DIR/help.log" ||
        test_result_finish SKIP "Installed stress-ng lacks the $option stressor"
done
while [ "$ITERATION" -le "$REPEAT" ]; do
    LOG="$RUN_DIR/iteration-$ITERATION.log"
    log_info "Iteration=$ITERATION/$REPEAT duration=${DURATION}s CPUs=$CPUS workers=$WORKERS per stressor"
    perf_run_stress_load "$((DURATION + TIMEOUT_MARGIN))" "$RUN_DIR" "$LOG" \
        taskset -c "$CPUS" stress-ng --switch "$WORKERS" --futex "$WORKERS" \
        --pipe "$WORKERS" --timeout "${DURATION}s" --verify --metrics-brief
    RET=$?
    if [ "$RET" -ne 0 ] || grep -Eq 'fail:|failed:[[:space:]]*[1-9]|skipped:[[:space:]]*[1-9]' "$LOG"; then
        test_result_finish FAIL "IPC stress failed or skipped a selected stressor, rc=$RET log=$LOG"
    fi
    for stressor in switch futex pipe; do
        awk -v stressor="$stressor" '
            /metrc:/ {
                for(i=1;i<NF;i++) if($i==stressor && $(i+1)+0>0) found=1
            }
            END {exit !found}' "$LOG" || test_result_finish FAIL "No verified $stressor work in $LOG"
    done
    perf_stress_kernel_errors "$RUN_DIR/kernel-$ITERATION" "$START_UPTIME"
    KERNEL_RC=$?
    case "$KERNEL_RC" in
        0)
            test_result_finish FAIL "Kernel fault during IPC stress, inspect $RUN_DIR/kernel-$ITERATION"
            ;;
        2)
            test_result_finish FAIL "Kernel log unavailable for IPC health validation"
            ;;
    esac
    test_result_record PASS "Completed scheduler/IPC iteration $ITERATION"
    ITERATION=$((ITERATION + 1))
done
test_result_finish
