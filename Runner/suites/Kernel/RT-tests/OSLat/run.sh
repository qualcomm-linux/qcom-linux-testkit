#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# OSLat wrapper for qcom-linux-testkit
# - Runs rt-tests oslat ITERATIONS times (JSON output)
# - Parses KPI using lib_rt.sh (no python required)
# - Emits KPI lines to result.txt and summary PASS/FAIL/SKIP to OSLat.res
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use OSLat.res for gating.
# - Ctrl-C/user interrupt is treated as SKIP and partial results are preserved.
# - Heartbeat is enabled by default.

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

TESTNAME="OSLat"
RT_CUR_TESTNAME="$TESTNAME"
export RT_CUR_TESTNAME

test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ]; then
  test_path="$SCRIPT_DIR"
fi

RES_FILE="$test_path/${TESTNAME}.res"
OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
RESULT_TXT="${RESULT_TXT:-$OUT_DIR/result.txt}"

DURATION="${DURATION:-1m}"
BACKGROUND_CMD="${BACKGROUND_CMD:-}"
ITERATIONS="${ITERATIONS:-1}"
BUCKET_SIZE="${BUCKET_SIZE:-}"
BIAS="${BIAS:-false}"
CPU_LIST="${CPU_LIST:-}"
CPU_MAIN_THREAD="${CPU_MAIN_THREAD:-}"
RTPRIO="${RTPRIO:-}"
WORKLOAD_MEM="${WORKLOAD_MEM:-}"
QUIET="${QUIET:-true}"
SINGLE_PREHEAT="${SINGLE_PREHEAT:-false}"
TRACE_THRESHOLD_US="${TRACE_THRESHOLD_US:-}"
WORKLOAD="${WORKLOAD:-}"
BUCKET_WIDTH_NS="${BUCKET_WIDTH_NS:-}"
ZERO_OMIT="${ZERO_OMIT:-false}"
BINARY="${BINARY:-}"
VERBOSE="${VERBOSE:-0}"
PROGRESS_EVERY="${PROGRESS_EVERY:-1}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-10}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out DIR
  --result FILE
  --duration TIME
  --iterations N
  --background-cmd CMD
  --binary PATH
  --progress-every N
  --heartbeat-sec N
  --verbose
  --bucket-size N
  --bias BOOL
  --cpu-list LIST
  --cpu-main-thread CPU
  --rtprio N
  --workload-mem SIZE
  --quiet BOOL
  --single-preheat BOOL
  --trace-threshold-us N
  --workload KIND
  --bucket-width-ns N
  --zero-omit BOOL
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
    --bucket-size)
      shift
      BUCKET_SIZE="$1"
      ;;
    --bias)
      shift
      BIAS="$1"
      ;;
    --cpu-list)
      shift
      CPU_LIST="$1"
      ;;
    --cpu-main-thread)
      shift
      CPU_MAIN_THREAD="$1"
      ;;
    --rtprio)
      shift
      RTPRIO="$1"
      ;;
    --workload-mem)
      shift
      WORKLOAD_MEM="$1"
      ;;
    --quiet)
      shift
      QUIET="$1"
      ;;
    --single-preheat)
      shift
      SINGLE_PREHEAT="$1"
      ;;
    --trace-threshold-us)
      shift
      TRACE_THRESHOLD_US="$1"
      ;;
    --workload)
      shift
      WORKLOAD="$1"
      ;;
    --bucket-width-ns)
      shift
      BUCKET_WIDTH_NS="$1"
      ;;
    --zero-omit)
      shift
      ZERO_OMIT="$1"
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

LOG_PREFIX="$OUT_DIR/oslat"
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
log_info "$TESTNAME: Checking for the tools required to run oslat"

if ! rt_require_common_tools uname awk sed grep tr head tail mkdir cat sh sleep kill date mkfifo rm tee sort wc; then
  log_skip "$TESTNAME: basic tools missing"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if ! rt_require_json_helpers; then
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if ! rt_require_stream_helpers; then
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

rt_normalize_common_params

case "$BUCKET_SIZE" in ''|*[!0-9]*) BUCKET_SIZE="" ;; esac
case "$CPU_MAIN_THREAD" in ''|*[!0-9]*) CPU_MAIN_THREAD="" ;; esac
case "$RTPRIO" in ''|*[!0-9]*) RTPRIO="" ;; esac
case "$TRACE_THRESHOLD_US" in ''|*[!0-9]*) TRACE_THRESHOLD_US="" ;; esac
case "$BUCKET_WIDTH_NS" in ''|*[!0-9]*) BUCKET_WIDTH_NS="" ;; esac

OSLAT_BIN=$(rt_resolve_binary oslat "$BINARY" 2>/dev/null || echo "")
if [ -z "$OSLAT_BIN" ] || [ ! -x "$OSLAT_BIN" ]; then
  log_skip "$TESTNAME: oslat binary not found/executable (${OSLAT_BIN:-none})"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

rt_log_common_runtime_env "$TESTNAME" "$OSLAT_BIN"
log_info "$TESTNAME: iterations=$ITERATIONS duration=$DURATION"
log_info "$TESTNAME: heartbeat=$HEARTBEAT_SEC seconds"

RT_INTERRUPTED=0
export RT_INTERRUPTED

trap 'rt_handle_int; rt_cleanup_pipes; rt_stop_heartbeat; perf_rt_bg_stop >/dev/null 2>&1 || true' INT TERM
trap 'rt_cleanup_pipes; rt_stop_heartbeat; perf_rt_bg_stop >/dev/null 2>&1 || true' EXIT

perf_rt_bg_start "$TESTNAME" "$BACKGROUND_CMD"

overall_fail=0
i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  rt_log_iteration_progress "$TESTNAME" "$i" "$ITERATIONS" "$PROGRESS_EVERY"

  jsonfile="${LOG_PREFIX}-${i}.json"
  stdoutlog="${OUT_DIR}/oslat_stdout_iter${i}.log"

  set -- "$OSLAT_BIN"

  case "$QUIET" in
    true|TRUE|1|yes|YES)
      set -- "$@" -q
      ;;
  esac

  case "$BIAS" in
    true|TRUE|1|yes|YES)
      set -- "$@" -B
      ;;
  esac

  case "$SINGLE_PREHEAT" in
    true|TRUE|1|yes|YES)
      set -- "$@" -s
      ;;
  esac

  case "$ZERO_OMIT" in
    true|TRUE|1|yes|YES)
      set -- "$@" -z
      ;;
  esac

  if [ -n "$BUCKET_SIZE" ]; then
    set -- "$@" -b "$BUCKET_SIZE"
  fi

  if [ -n "$CPU_LIST" ]; then
    set -- "$@" -c "$CPU_LIST"
  fi

  if [ -n "$CPU_MAIN_THREAD" ]; then
    set -- "$@" -C "$CPU_MAIN_THREAD"
  fi

  if [ -n "$RTPRIO" ]; then
    set -- "$@" -f "$RTPRIO"
  fi

  if [ -n "$WORKLOAD_MEM" ]; then
    set -- "$@" -m "$WORKLOAD_MEM"
  fi

  if [ -n "$TRACE_THRESHOLD_US" ]; then
    set -- "$@" -T "$TRACE_THRESHOLD_US"
  fi

  if [ -n "$WORKLOAD" ]; then
    set -- "$@" -w "$WORKLOAD"
  fi

  if [ -n "$BUCKET_WIDTH_NS" ]; then
    set -- "$@" -W "$BUCKET_WIDTH_NS"
  fi

  set -- "$@" -D "$DURATION" --json="$jsonfile"

  if rt_run_streaming_iteration "$TESTNAME" "$HEARTBEAT_SEC" "$stdoutlog" "$jsonfile" "$@"; then
    rc=$RT_RUN_RC
  else
    rc=$RT_RUN_RC
  fi

  if [ "$rc" -ne 0 ] 2>/dev/null; then
    if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null && [ "$rc" -eq 130 ] 2>/dev/null; then
      log_warn "$TESTNAME: oslat interrupted by user (rc=$rc); reporting partial results"
    else
      log_fail "$TESTNAME: oslat exited rc=$rc (iter $i/$ITERATIONS)"
      overall_fail=1
    fi
  fi

  if [ "${RT_RUN_JSON_OK:-0}" -ne 1 ] 2>/dev/null; then
    if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null; then
      log_warn "$TESTNAME: json output not available after interrupt: $jsonfile"
      break
    fi

    log_fail "$TESTNAME: missing json output: $jsonfile"
    overall_fail=1
    i=$((i + 1))
    continue
  fi

  if ! rt_parse_and_append_iteration_kpi "oslat" "$jsonfile" "$TMP_ONE" "$ITER_KPI" "$RESULT_TXT" "$i"; then
    if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null; then
      log_warn "$TESTNAME: parse incomplete after interrupt (iter $i/$ITERATIONS): $jsonfile"
    else
      log_fail "$TESTNAME: failed to parse/store KPI (iter $i/$ITERATIONS): $jsonfile"
      overall_fail=1
    fi
  fi

  if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null; then
    break
  fi

  i=$((i + 1))
done

perf_rt_bg_stop >/dev/null 2>&1 || true

rt_emit_kpi_block "$TESTNAME" "per-iteration results" "$ITER_KPI"
rt_emit_aggregate_kpi "$TESTNAME" "oslat" "$ITER_KPI" "$AGG_KPI" "$RESULT_TXT" || true
rt_emit_thread_aggregate_kpi "$TESTNAME" "oslat" "$ITER_KPI" "$THREAD_AGG_KPI" "$RESULT_TXT" || true

if rt_kpi_file_has_fail "oslat" "$ITER_KPI"; then
  overall_fail=1
fi

rt_emit_interrupt_aware_result "$TESTNAME" "$RES_FILE" "$RESULT_TXT" "$OUT_DIR" "${RT_INTERRUPTED:-0}" "$overall_fail"
exit 0
