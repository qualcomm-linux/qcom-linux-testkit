#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# PI_Stress wrapper for qcom-linux-testkit
# - Runs rt-tests pi_stress ITERATIONS times (JSON output)
# - Parses inversion count + pass/fail using lib_rt.sh (no python required)
# - Emits KPI lines to result.txt and summary PASS/FAIL/SKIP to PI_Stress.res
#
# Notes:
# - pi_stress may send SIGTERM when it detects failures; we ignore TERM so the
# wrapper can continue and still collect logs.
# - Always exits 0 (LAVA-friendly). Use PI_Stress.res for gating.

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

TESTNAME="PI_Stress"
test_path=$(find_test_case_by_name "$TESTNAME")
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

RES_FILE="$test_path/${TESTNAME}.res"
OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
RESULT_TXT="${RESULT_TXT:-$OUT_DIR/result.txt}"

# params (env/LAVA can override)
DURATION="${DURATION:-5m}"
MLOCKALL="${MLOCKALL:-false}"
RR="${RR:-false}"
BACKGROUND_CMD="${BACKGROUND_CMD:-}"
ITERATIONS="${ITERATIONS:-1}"
USER_BASELINE="${USER_BASELINE:-}"

# Optional extras
BINARY="${BINARY:-}"
VERBOSE="${VERBOSE:-0}"
PROGRESS_EVERY="${PROGRESS_EVERY:-1}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-10}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --out DIR Output directory (default: $OUT_DIR)
  --result FILE Result file path (default: $RESULT_TXT)

  --duration STR Requested duration (e.g. 10, 1m, 2m30s)
  --mlockall BOOL true|false -> add --mlockall (default: $MLOCKALL)
  --rr BOOL true|false -> add --rr (default: $RR)
  --iterations N Number of iterations (default: $ITERATIONS)
  --user-baseline N Optional inversion baseline (count). If set, FAIL when
                          a majority of iterations exceed this baseline
                          (requires ITERATIONS >= 3)

  --background-cmd CMD Optional background workload
  --binary PATH Explicit pi_stress binary path
  --progress-every N Log progress every N iterations (default: $PROGRESS_EVERY)
  --heartbeat-sec N Heartbeat interval in seconds (default: $HEARTBEAT_SEC)
  --verbose Extra logs
  -h, --help Help

Examples:
  $0 --binary /tmp/pi_stress --duration 1m --mlockall true --rr false --iterations 3
  $0 --duration 10 --iterations 3 --heartbeat-sec 1
  $0 --iterations 5 --user-baseline 10
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
    --mlockall)
      shift
      MLOCKALL="$1"
      ;;
    --rr)
      shift
      RR="$1"
      ;;
    --iterations)
      shift
      ITERATIONS="$1"
      ;;
    --user-baseline)
      shift
      USER_BASELINE="$1"
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
      exit 1
      ;;
  esac
  shift
done

LOG_PREFIX="$OUT_DIR/pi-stress"
TMP_ONE="$OUT_DIR/tmp_result_one.txt"
ITER_KPI="$OUT_DIR/iter_kpi.txt"
INV_VALUES="$OUT_DIR/inversion_values.txt"
GATE_KPI="$OUT_DIR/gate_kpi.txt"

rt_prepare_output_layout \
  "$OUT_DIR" \
  "$RESULT_TXT" \
  "$TMP_ONE" \
  "$ITER_KPI" \
  "$INV_VALUES" \
  "$GATE_KPI"

rt_check_clock_sanity "$TESTNAME" || true

log_info "------------------- Starting $TESTNAME -------------------"
log_info "$TESTNAME: Checking for the tools required to run pi_stress"

if ! rt_require_common_tools uname awk sed grep tr head tail mkdir cat sh tee sleep kill date sort wc; then
  log_skip "$TESTNAME: basic tools missing"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if ! command -v perf_parse_rt_tests_json >/dev/null 2>&1; then
  log_skip "$TESTNAME: perf_parse_rt_tests_json missing (lib_rt.sh not loaded?)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if ! command -v rt_require_duration_seconds >/dev/null 2>&1; then
  log_skip "$TESTNAME: rt_require_duration_seconds missing (lib_rt.sh not updated/loaded?)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

case "$ITERATIONS" in
  ''|*[!0-9]*|0)
    ITERATIONS=1
    ;;
esac

case "$PROGRESS_EVERY" in
  ''|*[!0-9]*|0)
    PROGRESS_EVERY=1
    ;;
esac

case "$HEARTBEAT_SEC" in
  ''|*[!0-9]*|0)
    HEARTBEAT_SEC=10
    ;;
esac

PI_BIN=$(rt_resolve_binary pi_stress "$BINARY" 2>/dev/null || echo "")
if [ -z "$PI_BIN" ] || [ ! -x "$PI_BIN" ]; then
  log_skip "$TESTNAME: pi_stress binary not found/executable (${PI_BIN:-none})"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

PI_DURATION_SECS=$(rt_require_duration_seconds "$TESTNAME" "$DURATION") || {
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 0
}

rt_log_common_runtime_env "$TESTNAME" "$PI_BIN"
log_info "$TESTNAME: iterations=$ITERATIONS duration=$DURATION (${PI_DURATION_SECS}s) mlockall=$MLOCKALL rr=$RR"
log_info "$TESTNAME: heartbeat=$HEARTBEAT_SEC seconds"

if [ "$VERBOSE" -eq 1 ] 2>/dev/null; then
  log_info "$TESTNAME: OUT_DIR=$OUT_DIR"
  log_info "$TESTNAME: RESULT_TXT=$RESULT_TXT"
  log_info "$TESTNAME: BACKGROUND_CMD=${BACKGROUND_CMD:-none}"
  log_info "$TESTNAME: USER_BASELINE=${USER_BASELINE:-none}"
fi

RT_INTERRUPTED=0
export RT_INTERRUPTED

trap '' TERM
trap 'rt_handle_int; perf_rt_bg_stop >/dev/null 2>&1 || true' INT
trap 'perf_rt_bg_stop >/dev/null 2>&1 || true' EXIT

perf_rt_bg_start "$TESTNAME" "$BACKGROUND_CMD"

overall_fail=0
fail_count=0

baseline_ok=0
case "$USER_BASELINE" in
  '')
    baseline_ok=0
    ;;
  *[!0-9]*)
    baseline_ok=0
    ;;
  *)
    baseline_ok=1
    ;;
esac

RT_RUN_TARGET_DURATION_SECS="$PI_DURATION_SECS"
export RT_RUN_TARGET_DURATION_SECS

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  rt_log_iteration_progress "$TESTNAME" "$i" "$ITERATIONS" "$PROGRESS_EVERY"

  jsonfile="${LOG_PREFIX}-${i}.json"
  stdoutlog="${OUT_DIR}/pi_stress_stdout_iter${i}.log"

  set -- "$PI_BIN" "-q" "-D" "$PI_DURATION_SECS"

  case "$MLOCKALL" in
    true|TRUE|1|yes|YES)
      set -- "$@" "--mlockall"
      ;;
  esac

  case "$RR" in
    true|TRUE|1|yes|YES)
      set -- "$@" "--rr"
      ;;
  esac

  set -- "$@" "--json=$jsonfile"

  if rt_run_json_iteration "$TESTNAME" "$HEARTBEAT_SEC" "$stdoutlog" "$jsonfile" "$@"; then
    rc=$RT_RUN_RC
  else
    rc=$RT_RUN_RC
  fi

  if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null; then
    if [ -r "$jsonfile" ]; then
      : >"$TMP_ONE" 2>/dev/null || true
      if perf_parse_rt_tests_json "pi-stress" "$jsonfile" >"$TMP_ONE" 2>/dev/null; then
        rt_append_iteration_kpi "$i" "$TMP_ONE" "$ITER_KPI" "$RESULT_TXT" || true

        inv=$(awk '/^inversion[[:space:]]+pass[[:space:]]+[0-9]+/ { print $3; exit }' "$TMP_ONE" 2>/dev/null)
        if [ -n "$inv" ]; then
          printf '%s\n' "$inv" >>"$INV_VALUES" 2>/dev/null || true
        fi
      fi
    fi

    log_warn "$TESTNAME: interrupted by user during iteration $i/$ITERATIONS"
    break
  fi

  if [ "$rc" -ne 0 ] 2>/dev/null; then
    log_fail "$TESTNAME: pi_stress exited rc=$rc (iter $i/$ITERATIONS)"
    overall_fail=1
  fi

  if [ ! -r "$jsonfile" ]; then
    log_fail "$TESTNAME: missing json output: $jsonfile"
    overall_fail=1
    i=$((i + 1))
    continue
  fi

  : >"$TMP_ONE" 2>/dev/null || true
  if perf_parse_rt_tests_json "pi-stress" "$jsonfile" >"$TMP_ONE" 2>/dev/null; then
    rt_append_iteration_kpi "$i" "$TMP_ONE" "$ITER_KPI" "$RESULT_TXT" || true

    inv=$(awk '/^inversion[[:space:]]+pass[[:space:]]+[0-9]+/ { print $3; exit }' "$TMP_ONE" 2>/dev/null)
    if [ -n "$inv" ]; then
      printf '%s\n' "$inv" >>"$INV_VALUES" 2>/dev/null || true
    fi

    if [ "$baseline_ok" -eq 1 ] 2>/dev/null && [ -n "$inv" ]; then
      if [ "$inv" -gt "$USER_BASELINE" ] 2>/dev/null; then
        fail_count=$((fail_count + 1))
      fi
    fi
  else
    log_fail "$TESTNAME: failed to parse json (iter $i/$ITERATIONS): $jsonfile"
    overall_fail=1
  fi

  i=$((i + 1))
done

RT_RUN_TARGET_DURATION_SECS=""
export RT_RUN_TARGET_DURATION_SECS

perf_rt_bg_stop >/dev/null 2>&1 || true

if [ -s "$ITER_KPI" ]; then
  rt_emit_kpi_block "$TESTNAME" "per-iteration results" "$ITER_KPI"
else
  if [ "${RT_INTERRUPTED:-0}" -eq 1 ] 2>/dev/null; then
    log_warn "$TESTNAME: no completed iteration data collected before interrupt"
  fi
fi

if [ -s "$INV_VALUES" ]; then
  agg=$(
    awk '
      BEGIN { min=""; max=""; sum=0; n=0 }
      /^[0-9]+$/ {
        v=$1
        if (min=="" || v<min) min=v
        if (max=="" || v>max) max=v
        sum+=v
        n++
      }
      END {
        if (n>0) {
          mean=sum/n
          if (mean==int(mean)) printf("%d|%d|%d|%d\n", min, int(mean), max, n)
          else printf("%d|%.3f|%d|%d\n", min, mean, max, n)
        }
      }
    ' "$INV_VALUES" 2>/dev/null
  )

  if [ -n "$agg" ]; then
    inv_min=$(printf '%s' "$agg" | awk -F'|' '{print $1}')
    inv_mean=$(printf '%s' "$agg" | awk -F'|' '{print $2}')
    inv_max=$(printf '%s' "$agg" | awk -F'|' '{print $3}')
    inv_n=$(printf '%s' "$agg" | awk -F'|' '{print $4}')

    echo "pi-stress-inversion-min pass ${inv_min} count" >>"$RESULT_TXT" 2>/dev/null || true
    echo "pi-stress-inversion-mean pass ${inv_mean} count" >>"$RESULT_TXT" 2>/dev/null || true
    echo "pi-stress-inversion-max pass ${inv_max} count" >>"$RESULT_TXT" 2>/dev/null || true

    log_info "$TESTNAME: pi-stress-inversion-min pass ${inv_min} count"
    log_info "$TESTNAME: pi-stress-inversion-mean pass ${inv_mean} count"
    log_info "$TESTNAME: pi-stress-inversion-max pass ${inv_max} count"

    if [ "$PI_DURATION_SECS" -gt 0 ] 2>/dev/null; then
      inv_rate=$(
        awk -v inv="$inv_mean" -v sec="$PI_DURATION_SECS" 'BEGIN {
          if (sec > 0) printf("%.6f", inv/sec)
          else printf("0.000000")
        }' 2>/dev/null
      )

      echo "pi-stress-inversion-rate pass ${inv_rate} inv/s" >>"$RESULT_TXT" 2>/dev/null || true
      log_info "$TESTNAME: pi-stress-inversion-rate pass ${inv_rate} inv/s"
    fi

    if [ "$baseline_ok" -eq 1 ] 2>/dev/null; then
      log_info "$TESTNAME: USER_BASELINE=$USER_BASELINE (fail_count=$fail_count over $inv_n runs)"
    fi
  fi
fi

if [ "${RT_INTERRUPTED:-0}" -ne 1 ] 2>/dev/null && \
   [ "$baseline_ok" -eq 1 ] 2>/dev/null && \
   [ "$ITERATIONS" -ge 3 ] 2>/dev/null; then
  fail_limit=$(((ITERATIONS + 1) / 2))
  : >"$GATE_KPI" 2>/dev/null || true

  echo "inversion-baseline pass ${USER_BASELINE} count" >"$GATE_KPI"
  echo "inversion-fail-limit pass ${fail_limit} count" >>"$GATE_KPI"
  echo "inversion-fail-count pass ${fail_count} count" >>"$GATE_KPI"

  cat "$GATE_KPI" >>"$RESULT_TXT" 2>/dev/null || true
  rt_emit_kpi_block "$TESTNAME" "baseline comparison results" "$GATE_KPI"

  if [ "$fail_count" -ge "$fail_limit" ] 2>/dev/null; then
    overall_fail=1
  fi
fi

rt_emit_interrupt_aware_result "$TESTNAME" "$RES_FILE" "$RESULT_TXT" "$OUT_DIR" "${RT_INTERRUPTED:-0}" "$overall_fail"
exit 0
