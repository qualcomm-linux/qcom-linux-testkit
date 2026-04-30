#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# SSDD wrapper for qcom-linux-testkit
# - Runs rt-tests ssdd ITERATIONS times (JSON output)
# - Parses KPI using lib_rt.sh (no python required)
# - Emits KPI lines to result.txt and summary PASS/FAIL/SKIP to SSDD.res
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use SSDD.res for gating.
# - Ctrl-C/user interrupt is treated as SKIP and partial results are preserved.

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

TESTNAME="SSDD"
RT_CUR_TESTNAME="$TESTNAME"
export RT_CUR_TESTNAME

test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ]; then
  test_path="$SCRIPT_DIR"
fi

RES_FILE="$test_path/${TESTNAME}.res"
OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
RESULT_TXT="${RESULT_TXT:-$OUT_DIR/result.txt}"

BACKGROUND_CMD="${BACKGROUND_CMD:-}"
ITERATIONS="${ITERATIONS:-1}"
FORKS="${FORKS:-10}"
SSDD_ITERS="${SSDD_ITERS:-10000}"
BINARY="${BINARY:-}"
QUIET="${QUIET:-true}"
VERBOSE="${VERBOSE:-0}"
PROGRESS_EVERY="${PROGRESS_EVERY:-1}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-10}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out DIR
  --result FILE
  --iterations N
  --background-cmd CMD
  --binary PATH
  --progress-every N
  --heartbeat-sec N
  --verbose
  --forks NUM
  --ssdd-iters NUM
  --quiet BOOL
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
    --forks)
      shift
      FORKS="$1"
      ;;
    --ssdd-iters)
      shift
      SSDD_ITERS="$1"
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

LOG_PREFIX="$OUT_DIR/ssdd"
TMP_ONE="$OUT_DIR/tmp_result_one.txt"
ITER_KPI="$OUT_DIR/iter_kpi.txt"

rt_prepare_output_layout \
  "$OUT_DIR" \
  "$RESULT_TXT" \
  "$TMP_ONE" \
  "$ITER_KPI"

rt_check_clock_sanity "$TESTNAME" || true

log_info "------------------- Starting $TESTNAME -------------------"
log_info "$TESTNAME: Checking for the tools required to run ssdd"

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

case "$FORKS" in
  ''|*[!0-9]*|0)
    FORKS=10
    ;;
esac

case "$SSDD_ITERS" in
  ''|*[!0-9]*|0)
    SSDD_ITERS=10000
    ;;
esac

SSDD_BIN=$(rt_resolve_binary ssdd "$BINARY" 2>/dev/null || echo "")
if [ -z "$SSDD_BIN" ] || [ ! -x "$SSDD_BIN" ]; then
  log_skip "$TESTNAME: ssdd binary not found/executable (${SSDD_BIN:-none})"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

rt_log_common_runtime_env "$TESTNAME" "$SSDD_BIN"
log_info "$TESTNAME: iterations=$ITERATIONS forks=$FORKS ssdd-iters=$SSDD_ITERS"
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
  stdoutlog="${OUT_DIR}/ssdd_stdout_iter${i}.log"

  set -- "$SSDD_BIN" "--forks=$FORKS" "--iters=$SSDD_ITERS" "--json=$jsonfile"

  if rt_run_streaming_iteration "$TESTNAME" "$HEARTBEAT_SEC" "$stdoutlog" "$jsonfile" "$@"; then
    rc=$RT_RUN_RC
  else
    rc=$RT_RUN_RC
  fi

  if [ "$rc" -ne 0 ] 2>/dev/null; then
    if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null && [ "$rc" -eq 130 ] 2>/dev/null; then
      log_warn "$TESTNAME: ssdd interrupted by user (rc=$rc); reporting partial results"
    else
      log_fail "$TESTNAME: ssdd exited rc=$rc (iter $i/$ITERATIONS)"
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

  if ! rt_parse_and_append_iteration_kpi "ssdd" "$jsonfile" "$TMP_ONE" "$ITER_KPI" "$RESULT_TXT" "$i"; then
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

if rt_kpi_file_has_fail "ssdd" "$ITER_KPI"; then
  overall_fail=1
fi

rt_emit_interrupt_aware_result "$TESTNAME" "$RES_FILE" "$RESULT_TXT" "$OUT_DIR" "${RT_INTERRUPTED:-0}" "$overall_fail"
exit 0
