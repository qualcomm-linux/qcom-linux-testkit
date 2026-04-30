#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# SVSematest wrapper for qcom-linux-testkit
# - Runs rt-tests svsematest ITERATIONS times (JSON output)
# - Parses KPI using lib_rt.sh (no python required)
# - Emits KPI lines to result.txt and summary PASS/FAIL/SKIP to SVSematest.res
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use SVSematest.res for gating.
# - Ctrl-C/user interrupt is treated as SKIP and partial results are preserved.
# - Streaming progress from svsematest is shown live on stdout.
# - Heartbeat is shown by default while the test is running.

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

TESTNAME="SVSematest"
RT_CUR_TESTNAME="$TESTNAME"
export RT_CUR_TESTNAME

test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ]; then
  test_path="$SCRIPT_DIR"
fi

RES_FILE="$test_path/${TESTNAME}.res"
OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
RESULT_TXT="${RESULT_TXT:-$OUT_DIR/result.txt}"

DURATION="${DURATION:-5m}"
BACKGROUND_CMD="${BACKGROUND_CMD:-}"
ITERATIONS="${ITERATIONS:-1}"
PRIO="${PRIO:-98}"
QUIET="${QUIET:-true}"
THREADS="${THREADS:-true}"
THREADS_NUM="${THREADS_NUM:-}"
AFFINITY="${AFFINITY:-true}"
AFFINITY_CPU="${AFFINITY_CPU:-}"
BREAKTRACE_US="${BREAKTRACE_US:-}"
DISTANCE_US="${DISTANCE_US:-}"
FORK_MODE="${FORK_MODE:-false}"
FORK_OPT="${FORK_OPT:-}"
INTERVAL_US="${INTERVAL_US:-}"
LOOPS="${LOOPS:-}"
SMP="${SMP:-false}"
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
  --prio N
  --quiet BOOL
  --threads BOOL
  --threads-num NUM
  --affinity BOOL
  --affinity-cpu NUM
  --breaktrace-us USEC
  --distance-us USEC
  --fork BOOL
  --fork-opt OPT
  --interval-us USEC
  --loops N
  --smp BOOL
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
    --threads)
      shift
      THREADS="$1"
      ;;
    --threads-num)
      shift
      THREADS_NUM="$1"
      ;;
    --affinity)
      shift
      AFFINITY="$1"
      ;;
    --affinity-cpu)
      shift
      AFFINITY_CPU="$1"
      ;;
    --breaktrace-us)
      shift
      BREAKTRACE_US="$1"
      ;;
    --distance-us)
      shift
      DISTANCE_US="$1"
      ;;
    --fork)
      shift
      FORK_MODE="$1"
      ;;
    --fork-opt)
      shift
      FORK_OPT="$1"
      ;;
    --interval-us)
      shift
      INTERVAL_US="$1"
      ;;
    --loops)
      shift
      LOOPS="$1"
      ;;
    --smp)
      shift
      SMP="$1"
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

LOG_PREFIX="$OUT_DIR/svsematest"
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
log_info "$TESTNAME: Checking for the tools required to run svsematest"

if ! rt_require_common_tools uname awk sed grep tr head tail mkdir cat sh tee sleep kill date mkfifo rm sort wc; then
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

case "$PRIO" in ''|*[!0-9]*) PRIO=98 ;; esac
case "$THREADS_NUM" in ''|*[!0-9]*) THREADS_NUM="" ;; esac
case "$AFFINITY_CPU" in ''|*[!0-9]*) AFFINITY_CPU="" ;; esac
case "$BREAKTRACE_US" in ''|*[!0-9]*) BREAKTRACE_US="" ;; esac
case "$DISTANCE_US" in ''|*[!0-9]*) DISTANCE_US="" ;; esac
case "$INTERVAL_US" in ''|*[!0-9]*) INTERVAL_US="" ;; esac
case "$LOOPS" in ''|*[!0-9]*) LOOPS="" ;; esac

SVSEMA_BIN=$(rt_resolve_binary svsematest "$BINARY" 2>/dev/null || echo "")
if [ -z "$SVSEMA_BIN" ] || [ ! -x "$SVSEMA_BIN" ]; then
  log_skip "$TESTNAME: svsematest binary not found/executable (${SVSEMA_BIN:-none})"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

rt_log_common_runtime_env "$TESTNAME" "$SVSEMA_BIN"
log_info "$TESTNAME: iterations=$ITERATIONS duration=$DURATION prio=$PRIO"
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
  stdoutlog="${OUT_DIR}/svsematest_stdout_iter${i}.log"

  set -- "$SVSEMA_BIN"

  case "$QUIET" in
    true|TRUE|1|yes|YES)
      set -- "$@" -q
      ;;
  esac

  case "$SMP" in
    true|TRUE|1|yes|YES)
      set -- "$@" -S
      ;;
  esac

  case "$AFFINITY" in
    true|TRUE|1|yes|YES)
      if [ -n "$AFFINITY_CPU" ]; then
        set -- "$@" -a "$AFFINITY_CPU"
      else
        set -- "$@" -a
      fi
      ;;
  esac

  case "$THREADS" in
    true|TRUE|1|yes|YES)
      if [ -n "$THREADS_NUM" ]; then
        set -- "$@" -t "$THREADS_NUM"
      else
        set -- "$@" -t
      fi
      ;;
  esac

  case "$FORK_MODE" in
    true|TRUE|1|yes|YES)
      if [ -n "$FORK_OPT" ]; then
        set -- "$@" -f "$FORK_OPT"
      else
        set -- "$@" -f
      fi
      ;;
  esac

  if [ -n "$BREAKTRACE_US" ]; then
    set -- "$@" -b "$BREAKTRACE_US"
  fi

  if [ -n "$DISTANCE_US" ]; then
    set -- "$@" -d "$DISTANCE_US"
  fi

  if [ -n "$INTERVAL_US" ]; then
    set -- "$@" -i "$INTERVAL_US"
  fi

  if [ -n "$LOOPS" ]; then
    set -- "$@" -l "$LOOPS"
  fi

  set -- "$@" -p "$PRIO" -D "$DURATION" --json="$jsonfile"

  if rt_run_streaming_iteration "$TESTNAME" "$HEARTBEAT_SEC" "$stdoutlog" "$jsonfile" "$@"; then
    rc=$RT_RUN_RC
  else
    rc=$RT_RUN_RC
  fi

  if [ "$rc" -ne 0 ] 2>/dev/null; then
    if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null && [ "$rc" -eq 130 ] 2>/dev/null; then
      log_warn "$TESTNAME: svsematest interrupted by user (rc=$rc); reporting partial results"
    else
      log_fail "$TESTNAME: svsematest exited rc=$rc (iter $i/$ITERATIONS)"
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

  if ! rt_parse_and_append_iteration_kpi "svsematest" "$jsonfile" "$TMP_ONE" "$ITER_KPI" "$RESULT_TXT" "$i"; then
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
rt_emit_aggregate_kpi "$TESTNAME" "svsematest" "$ITER_KPI" "$AGG_KPI" "$RESULT_TXT" || true
rt_emit_thread_aggregate_kpi "$TESTNAME" "svsematest" "$ITER_KPI" "$THREAD_AGG_KPI" "$RESULT_TXT" || true

if rt_kpi_file_has_fail "svsematest" "$ITER_KPI"; then
  overall_fail=1
fi

rt_emit_interrupt_aware_result "$TESTNAME" "$RES_FILE" "$RESULT_TXT" "$OUT_DIR" "${RT_INTERRUPTED:-0}" "$overall_fail"
exit 0
