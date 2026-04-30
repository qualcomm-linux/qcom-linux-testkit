#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# CyclicDeadline wrapper for qcom-linux-testkit
# - Runs rt-tests cyclicdeadline ITERATIONS times (JSON output)
# - Parses KPI using lib_rt.sh (no python required)
# - Emits KPI lines to result.txt and summary PASS/FAIL/SKIP to CyclicDeadline.res
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use CyclicDeadline.res for gating.

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

TESTNAME="CyclicDeadline"
test_path=$(find_test_case_by_name "$TESTNAME")
if [ -n "$test_path" ]; then
  :
else
  test_path="$SCRIPT_DIR"
fi

RES_FILE="$test_path/${TESTNAME}.res"
OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
RESULT_TXT="${RESULT_TXT:-$OUT_DIR/result.txt}"

INTERVAL="${INTERVAL:-1000}"
STEP="${STEP:-500}"
THREADS="${THREADS:-1}"
DURATION="${DURATION:-5m}"
BACKGROUND_CMD="${BACKGROUND_CMD:-}"
ITERATIONS="${ITERATIONS:-1}"
USER_BASELINE="${USER_BASELINE:-}"
QUIET="${QUIET:-true}"
BINARY="${BINARY:-}"
VERBOSE="${VERBOSE:-0}"
PROGRESS_EVERY="${PROGRESS_EVERY:-1}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-10}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out DIR
  --result FILE
  --background-cmd CMD
  --binary PATH
  --progress-every N
  --heartbeat-sec N
  --verbose
  --interval N
  --step N
  --threads N
  --duration STR
  --iterations N
  --user-baseline N Max-latency baseline in us for majority gate (optional)
  --quiet BOOL

Notes:
  When --user-baseline is not provided, baseline gating is skipped and
  latency KPIs are reported only.
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
    --interval)
      shift
      INTERVAL="$1"
      ;;
    --step)
      shift
      STEP="$1"
      ;;
    --threads)
      shift
      THREADS="$1"
      ;;
    --duration)
      shift
      DURATION="$1"
      ;;
    --iterations)
      shift
      ITERATIONS="$1"
      ;;
    --user-baseline)
      shift
      USER_BASELINE="$1"
      ;;
    --quiet)
      shift
      QUIET="$1"
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

LOG_PREFIX="$OUT_DIR/cyclicdeadline"
TMP_ONE="$OUT_DIR/tmp_result_one.txt"
ITER_KPI="$OUT_DIR/iter_kpi.txt"
AGG_KPI="$OUT_DIR/agg_kpi.txt"
THREAD_AGG_KPI="$OUT_DIR/thread_agg_kpi.txt"
MAX_LAT_FILE="$OUT_DIR/max_latencies.txt"
GATE_KPI="$OUT_DIR/gate_kpi.txt"

rt_prepare_output_layout \
  "$OUT_DIR" \
  "$RESULT_TXT" \
  "$TMP_ONE" \
  "$ITER_KPI" \
  "$AGG_KPI" \
  "$THREAD_AGG_KPI" \
  "$MAX_LAT_FILE" \
  "$GATE_KPI"

rt_check_clock_sanity "$TESTNAME" || true

log_info "------------------- Starting $TESTNAME -------------------"
log_info "$TESTNAME: Checking for the tools required to run cyclicdeadline"

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

CDL_BIN=$(rt_resolve_binary cyclicdeadline "$BINARY" 2>/dev/null || echo "")
if [ -z "$CDL_BIN" ] || [ ! -x "$CDL_BIN" ]; then
  log_skip "$TESTNAME: cyclicdeadline binary not found/executable (${CDL_BIN:-none})"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

rt_log_common_runtime_env "$TESTNAME" "$CDL_BIN"
log_info "$TESTNAME: iterations=$ITERATIONS duration=$DURATION interval=$INTERVAL step=$STEP threads=$THREADS"
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
  stdoutlog="${OUT_DIR}/cyclicdeadline_stdout_iter${i}.log"

  set -- "$CDL_BIN"
  case "$QUIET" in
    true|TRUE|1|yes|YES)
      set -- "$@" -q
      ;;
  esac
  set -- "$@" -i "$INTERVAL" -s "$STEP" -t "$THREADS" -D "$DURATION" --json="$jsonfile"

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
    log_fail "$TESTNAME: cyclicdeadline exited rc=$rc (iter $i/$ITERATIONS)"
    overall_fail=1
  fi

  if [ "${RT_RUN_JSON_OK:-0}" -ne 1 ] 2>/dev/null; then
    log_fail "$TESTNAME: missing json output: $jsonfile"
    overall_fail=1
    i=$((i + 1))
    continue
  fi

  if ! rt_parse_and_append_iteration_kpi "cyclicdeadline" "$jsonfile" "$TMP_ONE" "$ITER_KPI" "$RESULT_TXT" "$i"; then
    log_fail "$TESTNAME: failed to parse/store KPI (iter $i/$ITERATIONS): $jsonfile"
    overall_fail=1
  fi

  i=$((i + 1))
done

perf_rt_bg_stop >/dev/null 2>&1 || true

rt_emit_kpi_block "$TESTNAME" "per-iteration results" "$ITER_KPI"
rt_emit_aggregate_kpi "$TESTNAME" "cyclicdeadline" "$ITER_KPI" "$AGG_KPI" "$RESULT_TXT" || true
rt_emit_thread_aggregate_kpi "$TESTNAME" "cyclicdeadline" "$ITER_KPI" "$THREAD_AGG_KPI" "$RESULT_TXT" || true

if [ "${RT_INTERRUPTED:-0}" -ne 1 ] 2>/dev/null && [ "$ITERATIONS" -gt 2 ] 2>/dev/null; then
  if rt_collect_named_metric_values "$RESULT_TXT" "max-latency" "$MAX_LAT_FILE"; then
    if [ -n "$USER_BASELINE" ]; then
      if ! rt_evaluate_majority_threshold_gate "$TESTNAME" "$ITERATIONS" "$MAX_LAT_FILE" "$GATE_KPI" "$RESULT_TXT" "$USER_BASELINE" "max-latency" "us"; then
        log_fail "$TESTNAME: baseline gate failed (${RT_BASELINE_FAIL_COUNT} >= ${RT_BASELINE_FAIL_LIMIT})"
        overall_fail=1
      fi
    else
      log_info "$TESTNAME: no user baseline provided; skipping baseline gate"
    fi
  else
    log_warn "$TESTNAME: no max-latency values found for baseline comparison"
    overall_fail=1
  fi
fi

if rt_kpi_file_has_fail "cyclicdeadline" "$ITER_KPI"; then
  overall_fail=1
fi

rt_emit_interrupt_aware_result "$TESTNAME" "$RES_FILE" "$RESULT_TXT" "$OUT_DIR" "${RT_INTERRUPTED:-0}" "$overall_fail"
exit 0
