#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Hackbench wrapper for qcom-linux-testkit
# - Runs hackbench ITERATIONS times
# - Captures output to a log file
# - Parses Time lines -> min/mean/max via lib_rt.sh
# - Adds worst-sample Time for quick debug visibility
# - Emits Hackbench.res PASS/FAIL/SKIP
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Hackbench.res for gating.
# - --iteration is kept as a compatibility alias for --iterations.

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

TESTNAME="Hackbench"
test_path=$(find_test_case_by_name "$TESTNAME")
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

RES_FILE="$test_path/${TESTNAME}.res"
OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
RESULT_TXT="${RESULT_TXT:-$OUT_DIR/result.txt}"
TEST_LOG="${TEST_LOG:-$OUT_DIR/hackbench-output-host.txt}"

ITERATIONS="${ITERATIONS:-1000}"
TARGET="${TARGET:-host}"
DATASIZE="${DATASIZE:-100}"
LOOPS="${LOOPS:-100}"
GRPS="${GRPS:-10}"
FDS="${FDS:-20}"
PIPE="${PIPE:-false}"
THREADS="${THREADS:-false}"
BACKGROUND_CMD="${BACKGROUND_CMD:-}"
BINARY="${BINARY:-}"
VERBOSE="${VERBOSE:-0}"
PROGRESS_EVERY="${PROGRESS_EVERY:-50}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-10}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out DIR
  --result FILE
  --log FILE
  --iterations N
  --iteration N Deprecated compatibility alias for --iterations
  --target host|kvm
  --datasize BYTES
  --loops N
  --grps N
  --fds N
  --pipe true|false
  --threads true|false
  --background-cmd CMD
  --binary PATH
  --progress-every N
  --heartbeat-sec N
  --verbose
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
    --log)
      shift
      TEST_LOG="$1"
      ;;
    --iterations|--iteration)
      shift
      ITERATIONS="$1"
      ;;
    --target)
      shift
      TARGET="$1"
      ;;
    --datasize)
      shift
      DATASIZE="$1"
      ;;
    --loops)
      shift
      LOOPS="$1"
      ;;
    --grps)
      shift
      GRPS="$1"
      ;;
    --fds)
      shift
      FDS="$1"
      ;;
    --pipe)
      shift
      PIPE="$1"
      ;;
    --threads)
      shift
      THREADS="$1"
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
    *)
      log_warn "Unknown option: $1"
      usage
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
      ;;
  esac
  shift
done

case "$ITERATIONS" in ''|*[!0-9]*|0) ITERATIONS=1 ;; esac
case "$PROGRESS_EVERY" in ''|*[!0-9]*|0) PROGRESS_EVERY=50 ;; esac
case "$HEARTBEAT_SEC" in ''|*[!0-9]*|0) HEARTBEAT_SEC=10 ;; esac
case "$DATASIZE" in ''|*[!0-9]*) DATASIZE=100 ;; esac
case "$LOOPS" in ''|*[!0-9]*) LOOPS=100 ;; esac
case "$GRPS" in ''|*[!0-9]*) GRPS=10 ;; esac
case "$FDS" in ''|*[!0-9]*) FDS=20 ;; esac

PARSED="$OUT_DIR/parsed_hackbench.txt"

rt_prepare_output_layout \
  "$OUT_DIR" \
  "$RESULT_TXT" \
  "$TEST_LOG" \
  "$PARSED"

rt_check_clock_sanity "$TESTNAME" || true

log_info "------------------- Starting $TESTNAME -------------------"
log_info "$TESTNAME: Checking for the tools required to run hackbench"

if ! rt_require_common_tools uname awk sed grep tr head tail mkdir cat sh sleep kill date sort wc; then
  log_skip "$TESTNAME: basic tools missing"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if ! command -v rt_parse_token_numeric_samples >/dev/null 2>&1; then
  log_skip "$TESTNAME: rt_parse_token_numeric_samples missing (lib_rt.sh not loaded?)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

HB_BIN=$(rt_resolve_binary hackbench "$BINARY" 2>/dev/null || echo "")
if [ -z "$HB_BIN" ] || [ ! -x "$HB_BIN" ]; then
  log_skip "$TESTNAME: hackbench binary not found/executable (${HB_BIN:-none})"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

rt_log_common_runtime_env "$TESTNAME" "$HB_BIN"
log_info "$TESTNAME: iterations=$ITERATIONS target=$TARGET"
log_info "$TESTNAME: datasize=$DATASIZE loops=$LOOPS grps=$GRPS fds=$FDS pipe=$PIPE threads=$THREADS"
log_info "$TESTNAME: heartbeat=$HEARTBEAT_SEC seconds"

RT_INTERRUPTED=0
export RT_INTERRUPTED

trap 'rt_handle_int; perf_rt_bg_stop >/dev/null 2>&1 || true' INT TERM
trap 'perf_rt_bg_stop >/dev/null 2>&1 || true' EXIT

perf_rt_bg_start "$TESTNAME" "$BACKGROUND_CMD"

overall_fail=0

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  rt_log_iteration_progress "$TESTNAME" "$i" "$ITERATIONS" "$PROGRESS_EVERY" "running"

  iter_log="${TEST_LOG}.iter${i}"

  set -- "$HB_BIN" -s "$DATASIZE" -l "$LOOPS" -g "$GRPS" -f "$FDS"
  case "$PIPE" in
    true|TRUE|1|yes|YES)
      set -- "$@" -p
      ;;
  esac
  case "$THREADS" in
    true|TRUE|1|yes|YES)
      set -- "$@" -T
      ;;
  esac

  if rt_run_and_capture "$TESTNAME" "$HEARTBEAT_SEC" "$iter_log" "$@"; then
    rc=$RT_RUN_RC
  else
    rc=$RT_RUN_RC
  fi

  if [ -r "$iter_log" ]; then
    cat "$iter_log" >>"$TEST_LOG" 2>/dev/null || true
    rm -f "$iter_log" 2>/dev/null || true
  fi

  if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null; then
    log_warn "$TESTNAME: interrupted by user during iteration $i/$ITERATIONS"
    break
  fi

  if [ "$rc" -ne 0 ] 2>/dev/null; then
    log_fail "$TESTNAME: hackbench failed rc=$rc (iter $i/$ITERATIONS)"
    overall_fail=1
    break
  fi

  i=$((i + 1))
done

perf_rt_bg_stop >/dev/null 2>&1 || true
: >"$PARSED" 2>/dev/null || true

if [ "$overall_fail" -eq 0 ] 2>/dev/null; then
  if [ -s "$TEST_LOG" ]; then
    if rt_parse_token_numeric_samples "hackbench-time" "$TEST_LOG" "Time:" "s" >"$PARSED" 2>/dev/null; then
      cat "$PARSED" >>"$RESULT_TXT" 2>/dev/null || true
      rt_emit_worst_sample_from_log "hackbench-worst-sample" "$TEST_LOG" "Time:" "s" "$PARSED" "$RESULT_TXT" "$TESTNAME" || true

      while IFS= read -r line; do
        [ -n "$line" ] || continue
        log_info "$TESTNAME: $line"
      done <"$PARSED"
    else
      if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null; then
        log_warn "$TESTNAME: no complete Time samples collected before interrupt"
      else
        log_fail "$TESTNAME: unable to parse any Time lines from $TEST_LOG"
        overall_fail=1
      fi
    fi
  else
    if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null; then
      log_warn "$TESTNAME: no output collected before interrupt"
    else
      log_fail "$TESTNAME: hackbench output log is empty: $TEST_LOG"
      overall_fail=1
    fi
  fi
fi

rt_emit_interrupt_aware_result "$TESTNAME" "$RES_FILE" "$RESULT_TXT" "$OUT_DIR" "${RT_INTERRUPTED:-0}" "$overall_fail"
exit 0
