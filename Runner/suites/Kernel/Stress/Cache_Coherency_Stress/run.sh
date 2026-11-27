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
# shellcheck disable=SC1091
. "$TOOLS/lib_pkg_provider.sh"

TESTNAME="Cache_Coherency_Stress"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
test_result_init "$TESTNAME" "$RES_FILE"
BINARY_PATH=""
DURATION=300
CPU_LIST=""
MEM_PERCENT=15
MEM_CAP=32
HEADROOM=256
REPEAT=1
TIMEOUT_MARGIN=120

usage() {
    cat <<EOF
Usage: $0 [--duration SECONDS] [--repeat COUNT] [--cpu-list LIST]
  --binary PATH, explicit stressapptest file, also in image-only mode
  --mem-frac PERCENT --mem-cap-mb MIB --mem-headroom-mb MIB
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
            --binary)
                [ -n "$2" ] || return 1
                BINARY_PATH=$2
                ;;
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
            --mem-frac)
                MEM_PERCENT=$2
                ;;
            --mem-cap-mb)
                MEM_CAP=$2
                ;;
            --mem-headroom-mb)
                HEADROOM=$2
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
for tool in awk grep sort taskset setsid; do
    command -v "$tool" >/dev/null 2>&1 || test_result_finish SKIP "Image-provided $tool is required"
done
STRESS_BIN=$(perf_resolve_binary stressapptest "$BINARY_PATH")
case $? in
    0)
        log_info "Using stressapptest: $STRESS_BIN"
        ;;
    2)
        test_result_finish SKIP "stressapptest is unavailable, see dependency diagnostics or provide --binary PATH"
        ;;
    *)
        test_result_finish FAIL "Cannot prepare stressapptest, see binary or package diagnostics"
        ;;
esac
CPUS=$(perf_allowed_cpus "$CPU_LIST") || test_result_finish FAIL "Cannot select allowed online CPUs"
taskset -c "$CPUS" true || test_result_finish FAIL "Cannot apply CPU affinity $CPUS"
CPU_COUNT=$(printf '%s\n' "$CPUS" | awk -F, '{print NF}')
RUN_DIR=$(test_create_run_directory "$SCRIPT_DIR/logs") || test_result_finish FAIL "Cannot create evidence directory"
START_UPTIME=$(awk '{print $1}' /proc/uptime)
ITERATION=1

[ "$CPU_COUNT" -ge 2 ] || test_result_finish SKIP "Cross-CPU coherency requires two allowed online CPUs"
perf_uint_in_range "$MEM_PERCENT" 1 99 || test_result_finish FAIL "Memory percentage must be 1 through 99"
perf_uint_in_range "$HEADROOM" 0 2147483647 || test_result_finish FAIL "Invalid memory headroom"
if [ -n "$MEM_CAP" ]; then
    perf_uint_in_range "$MEM_CAP" 1 2147483647 || test_result_finish FAIL "Invalid memory cap"
fi
if ! run_with_managed_timeout 10 "$RUN_DIR" tool-help "$STRESS_BIN" --help >"$RUN_DIR/help.log" 2>&1; then
    cat "$RUN_DIR/help.log"
    test_result_finish FAIL "Selected binary $STRESS_BIN could not report capabilities, check architecture, loader and permissions"
fi
if ! grep -q 'SAT revision' "$RUN_DIR/help.log"; then
    test_result_finish FAIL "$STRESS_BIN did not identify itself as stressapptest, see $RUN_DIR/help.log"
fi
for option in --cc_test --no_affinity; do
    grep -q -- "$option" "$RUN_DIR/help.log" || test_result_finish SKIP "Installed stressapptest lacks $option"
done
while [ "$ITERATION" -le "$REPEAT" ]; do
    AVAILABLE=$(perf_available_memory_kb) || test_result_finish FAIL "Cannot determine effective available memory"
    MEMORY=$(perf_memory_budget_mib "$AVAILABLE" "$MEM_PERCENT" "$HEADROOM" "$MEM_CAP") ||
        test_result_finish FAIL "No memory budget remains after headroom"
    [ "$MEMORY" -ge 16 ] || test_result_finish FAIL "Coherency initialization needs at least 16 MiB"
    LOG="$RUN_DIR/iteration-$ITERATION.log"
    log_info "Iteration=$ITERATION/$REPEAT duration=${DURATION}s CPUs=$CPUS memory=${MEMORY}MiB"
    perf_run_stress_load "$((DURATION + TIMEOUT_MARGIN))" "$RUN_DIR" "$LOG" \
        taskset -c "$CPUS" "$STRESS_BIN" -s "$DURATION" -M "$MEMORY" -m 0 \
        --cc_test --no_affinity -v 12
    RET=$?
    if [ "$RET" -ne 0 ] || ! grep -q 'Status: PASS' "$LOG" ||
       grep -Eq 'Status: FAIL|Process Error:|Hardware Error:' "$LOG"; then
        test_result_finish FAIL "Native cache coherency validation failed, rc=$RET log=$LOG"
    fi
    # Require completed counter checks, not just thread initialization.
    awk -v minimum="$CPU_COUNT" '
        /Stats: CC Thread\([0-9]+\):/ {
            value=$0
            sub(/.* Increments=/, "", value)
            if (value+0<=0) bad=1
            count++
        }
        END {exit (bad || count<minimum)}' "$LOG" ||
        test_result_finish FAIL "Missing completed coherency counter checks in $LOG"
    perf_stress_kernel_errors "$RUN_DIR/kernel-$ITERATION" "$START_UPTIME"
    KERNEL_RC=$?
    case "$KERNEL_RC" in
        0)
            test_result_finish FAIL "Kernel fault during coherency stress, inspect $RUN_DIR/kernel-$ITERATION"
            ;;
        2)
            test_result_finish FAIL "Kernel log unavailable for coherency health validation"
            ;;
    esac
    test_result_record PASS "Completed cache coherency iteration $ITERATION"
    ITERATION=$((ITERATION + 1))
done
test_result_finish
