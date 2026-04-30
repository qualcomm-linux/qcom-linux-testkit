#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# RTMigrateTest wrapper for qcom-linux-testkit
# - Runs rt-tests rt-migrate-test ITERATIONS times (JSON output)
# - Parses KPI using lib_rt.sh (no python required)
# - Emits KPI lines to result.txt and summary PASS/FAIL/SKIP to RTMigrateTest.res
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use RTMigrateTest.res for gating.

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

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_rt.sh"

TESTNAME="RTMigrateTest"
test_path=$(find_test_case_by_name "$TESTNAME")
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

RES_FILE="$test_path/${TESTNAME}.res"
OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
RESULT_TXT="${RESULT_TXT:-$OUT_DIR/result.txt}"

DURATION="${DURATION:-1m}"
BACKGROUND_CMD="${BACKGROUND_CMD:-}"
ITERATIONS="${ITERATIONS:-1}"
PRIO="${PRIO:-51}"
QUIET="${QUIET:-true}"
CHECK="${CHECK:-false}"
EQUAL="${EQUAL:-false}"
LOOPS="${LOOPS:-}"
MAXERR_US="${MAXERR_US:-}"
RUN_TIME_MS="${RUN_TIME_MS:-}"
SLEEP_TIME_MS="${SLEEP_TIME_MS:-}"
NR_TASKS="${NR_TASKS:-}"
BINARY="${BINARY:-}"
VERBOSE="${VERBOSE:-0}"
PROGRESS_EVERY="${PROGRESS_EVERY:-1}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-10}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out DIR
  --result FILE
  --duration STR
  --iterations N
  --background-cmd CMD
  --binary PATH
  --progress-every N
  --heartbeat-sec N
  --verbose
  --prio N
  --quiet BOOL
  --check BOOL
  --equal BOOL
  --loops N
  --maxerr-us N
  --run-time-ms N
  --sleep-time-ms N
  --nr-tasks N
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --out)
      shift
      OUT_DIR="$1"
      ;;
    --result)
      shift
      RESULT_TXT="$1"
      ;;
    --duration)
      shift
      DURATION="$1"
      ;;
    --iterations)
      shift
      ITERATIONS="$1"
      ;;
    --background-cmd)
      shift
      BACKGROUND_CMD="$1"
      ;;
    --binary)
      shift
      BINARY="$1"
      ;;
    --progress-every)
      shift
      PROGRESS_EVERY="$1"
      ;;
    --heartbeat-sec)
      shift
      HEARTBEAT_SEC="$1"
      ;;
    --verbose)
      VERBOSE=1
      ;;
    --prio)
      shift
      PRIO="$1"
      ;;
    --quiet)
      shift
      QUIET="$1"
      ;;
    --check)
      shift
      CHECK="$1"
      ;;
    --equal)
      shift
      EQUAL="$1"
      ;;
    --loops)
      shift
      LOOPS="$1"
      ;;
    --maxerr-us)
      shift
      MAXERR_US="$1"
      ;;
    --run-time-ms)
      shift
      RUN_TIME_MS="$1"
      ;;
    --sleep-time-ms)
      shift
      SLEEP_TIME_MS="$1"
      ;;
    --nr-tasks)
      shift
      NR_TASKS="$1"
      ;;
    *)
      log_warn "Unknown option: $1"
      usage
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
      ;;
  esac
  shift
done

LOG_PREFIX="$OUT_DIR/rt-migrate-test"
TMP_ONE="$OUT_DIR/tmp_result_one.txt"
ITER_KPI="$OUT_DIR/iter_kpi.txt"
AGG_KPI="$OUT_DIR/agg_kpi.txt"
THREAD_AGG_KPI="$OUT_DIR/thread_agg_kpi.txt"

rt_prepare_output_layout \
  "$OUT_DIR" \
  "$RESULT_TXT" \
  "$TMP_ONE" \
  "$ITER_KPI" \
  "$AGG_KPI" \
  "$THREAD_AGG_KPI"

rt_check_clock_sanity "$TESTNAME" || true

log_info "------------------- Starting $TESTNAME -------------------"
log_info "$TESTNAME: Checking for the tools required to run rt-migrate-test"

if ! rt_require_common_tools uname awk sed grep tr head tail mkdir cat sh sleep kill date sort wc; then
  log_skip "$TESTNAME: basic tools missing"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if ! rt_require_json_helpers; then
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

rt_normalize_common_params

case "$PRIO" in ''|*[!0-9]*) PRIO=51 ;; esac
case "$LOOPS" in ''|*[!0-9]*) LOOPS="" ;; esac
case "$MAXERR_US" in ''|*[!0-9]*) MAXERR_US="" ;; esac
case "$RUN_TIME_MS" in ''|*[!0-9]*) RUN_TIME_MS="" ;; esac
case "$SLEEP_TIME_MS" in ''|*[!0-9]*) SLEEP_TIME_MS="" ;; esac
case "$NR_TASKS" in ''|*[!0-9]*) NR_TASKS="" ;; esac

RTM_BIN=$(rt_resolve_binary rt-migrate-test "$BINARY" 2>/dev/null || echo "")
if [ -z "$RTM_BIN" ] || [ ! -x "$RTM_BIN" ]; then
  log_skip "$TESTNAME: rt-migrate-test binary not found/executable (${RTM_BIN:-none})"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

rt_log_common_runtime_env "$TESTNAME" "$RTM_BIN"
log_info "$TESTNAME: iterations=$ITERATIONS duration=$DURATION prio=$PRIO"
log_info "$TESTNAME: heartbeat=$HEARTBEAT_SEC seconds"

RT_INTERRUPTED=0
export RT_INTERRUPTED

trap 'rt_handle_int; perf_rt_bg_stop >/dev/null 2>&1 || true' INT TERM
trap 'perf_rt_bg_stop >/dev/null 2>&1 || true' EXIT

perf_rt_bg_start "$TESTNAME" "$BACKGROUND_CMD"

overall_fail=0

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  rt_log_iteration_progress "$TESTNAME" "$i" "$ITERATIONS" "$PROGRESS_EVERY"

  jsonfile="${LOG_PREFIX}-${i}.json"
  stdoutlog="${OUT_DIR}/rt_migrate_test_stdout_iter${i}.log"

  set -- "$RTM_BIN"

  case "$QUIET" in
    true|TRUE|1|yes|YES)
      set -- "$@" -q
      ;;
  esac

  case "$CHECK" in
    true|TRUE|1|yes|YES)
      set -- "$@" -c
      ;;
  esac

  case "$EQUAL" in
    true|TRUE|1|yes|YES)
      set -- "$@" -e
      ;;
  esac

  if [ -n "$LOOPS" ]; then
    set -- "$@" -l "$LOOPS"
  fi

  if [ -n "$MAXERR_US" ]; then
    set -- "$@" -m "$MAXERR_US"
  fi

  if [ -n "$RUN_TIME_MS" ]; then
    set -- "$@" -r "$RUN_TIME_MS"
  fi

  if [ -n "$SLEEP_TIME_MS" ]; then
    set -- "$@" -s "$SLEEP_TIME_MS"
  fi

  set -- "$@" -p "$PRIO" -D "$DURATION"

  if [ -n "$NR_TASKS" ]; then
    set -- "$@" "$NR_TASKS"
  fi

  set -- "$@" --json="$jsonfile"

  if rt_run_json_iteration "$TESTNAME" "$HEARTBEAT_SEC" "$stdoutlog" "$jsonfile" "$@"; then
    rc=$RT_RUN_RC
  else
    rc=$RT_RUN_RC
  fi

  if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null; then
    log_warn "$TESTNAME: interrupted by user during iteration $i/$ITERATIONS"
    break
  fi

  if [ "$rc" -ne 0 ] 2>/dev/null; then
    log_fail "$TESTNAME: rt-migrate-test exited rc=$rc (iter $i/$ITERATIONS)"
    overall_fail=1
  fi

  if [ "${RT_RUN_JSON_OK:-0}" -ne 1 ] 2>/dev/null; then
    log_fail "$TESTNAME: missing json output: $jsonfile"
    overall_fail=1
    i=$((i + 1))
    continue
  fi

  if ! rt_parse_and_append_iteration_kpi "rt-migrate-test" "$jsonfile" "$TMP_ONE" "$ITER_KPI" "$RESULT_TXT" "$i"; then
    log_fail "$TESTNAME: failed to parse/store KPI (iter $i/$ITERATIONS): $jsonfile"
    overall_fail=1
  fi

  i=$((i + 1))
done

perf_rt_bg_stop >/dev/null 2>&1 || true

rt_emit_kpi_block "$TESTNAME" "per-iteration results" "$ITER_KPI"
rt_emit_aggregate_kpi "$TESTNAME" "rt-migrate-test" "$ITER_KPI" "$AGG_KPI" "$RESULT_TXT" || true
rt_emit_thread_aggregate_kpi "$TESTNAME" "rt-migrate-test" "$ITER_KPI" "$THREAD_AGG_KPI" "$RESULT_TXT" || true

if rt_kpi_file_has_fail "rt-migrate-test" "$ITER_KPI"; then
  overall_fail=1
fi

rt_emit_interrupt_aware_result "$TESTNAME" "$RES_FILE" "$RESULT_TXT" "$OUT_DIR" "${RT_INTERRUPTED:-0}" "$overall_fail"
exit 0
