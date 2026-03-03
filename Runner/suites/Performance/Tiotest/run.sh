#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Tiotest"
RES_FILE="./${TESTNAME}.res"

# ---------------- Defaults (env overrides; CLI can override further) ----------------
OUT_DIR="${OUT_DIR:-./tiotest_out}"

ITERATIONS="${ITERATIONS:-1}"
THREADS_LIST="${THREADS_LIST:-1 4}"

TIOTEST_DIR="${TIOTEST_DIR:-}"
USE_RAW="${USE_RAW:-0}"
OFFSET_MB="${OFFSET_MB:-}"
OFFSET_FIRST="${OFFSET_FIRST:-0}"

SEQ_BLOCK_SIZE="${SEQ_BLOCK_SIZE:-524288}"
SEQ_FILE_SIZE_MB="${SEQ_FILE_SIZE_MB:-1024}"

RND_BLOCK_SIZE="${RND_BLOCK_SIZE:-4096}"
RND_FILE_SIZE_MB="${RND_FILE_SIZE_MB:-1}"
RND_OPS="${RND_OPS:-12500}"

MODE_LIST="${MODE_LIST:-seqwr seqrd rndwr rndrd}"

HIDE_LATENCY="${HIDE_LATENCY:-1}"
TERSE="${TERSE:-0}"
SEQ_WRITE_PHASE="${SEQ_WRITE_PHASE:-0}"
SYNC_WRITES="${SYNC_WRITES:-0}"
CONSISTENCY="${CONSISTENCY:-0}"
DEBUG_LEVEL="${DEBUG_LEVEL:-}"

DROP_CACHES="${DROP_CACHES:-0}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
REQUIRE_NON_TMPFS="${REQUIRE_NON_TMPFS:-1}"

BASELINE_FILE="${BASELINE_FILE:-}"
ALLOWED_DEVIATION="${ALLOWED_DEVIATION:-0.10}"

STANDALONE="${STANDALONE:-0}"

TIOTEST_BIN="${TIOTEST_BIN:-tiotest}"

usage() {
  cat <<EOF
$TESTNAME

Runs tiotest sequential + random tests for one or more thread counts, for N iterations.

ENV (defaults shown):
  OUT_DIR=$OUT_DIR
  ITERATIONS=$ITERATIONS
  THREADS_LIST=$THREADS_LIST
  TIOTEST_BIN=$TIOTEST_BIN
  TIOTEST_DIR=${TIOTEST_DIR:-"(auto)"}
  USE_RAW=$USE_RAW
  OFFSET_MB=$OFFSET_MB
  OFFSET_FIRST=$OFFSET_FIRST
  MODE_LIST=$MODE_LIST
  SEQ_BLOCK_SIZE=$SEQ_BLOCK_SIZE
  SEQ_FILE_SIZE_MB=$SEQ_FILE_SIZE_MB
  RND_BLOCK_SIZE=$RND_BLOCK_SIZE
  RND_FILE_SIZE_MB=$RND_FILE_SIZE_MB
  RND_OPS=$RND_OPS
  HIDE_LATENCY=$HIDE_LATENCY
  TERSE=$TERSE
  SEQ_WRITE_PHASE=$SEQ_WRITE_PHASE
  SYNC_WRITES=$SYNC_WRITES
  CONSISTENCY=$CONSISTENCY
  DEBUG_LEVEL=$DEBUG_LEVEL
  DROP_CACHES=$DROP_CACHES
  SET_PERF_GOV=$SET_PERF_GOV
  REQUIRE_NON_TMPFS=$REQUIRE_NON_TMPFS
  BASELINE_FILE=$BASELINE_FILE
  ALLOWED_DEVIATION=$ALLOWED_DEVIATION
  STANDALONE=$STANDALONE

CLI options:
  --out-dir DIR
  --iterations N
  --threads-list "1 4 8"
  --tiotest-bin PATH
  --tiotest-dir DIR_OR_DEV
  --use-raw 0|1
  --offset-mb N
  --offset-first 0|1
  --mode-list "seqwr seqrd rndwr rndrd"
  --seq-block BYTES
  --seq-file-mb MB
  --rnd-block BYTES
  --rnd-file-mb MB
  --rnd-ops N
  --hide-latency 0|1
  --terse 0|1
  --seq-write-phase 0|1
  --sync-writes 0|1
  --consistency 0|1
  --debug-level N
  --drop-caches 0|1
  --set-perf-gov 0|1
  --require-non-tmpfs 0|1
  --baseline FILE
  --delta FLOAT
  --standalone 0|1
  -h, --help
EOF
}

# ---------------- CLI parsing ----------------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;

    --out-dir) OUT_DIR=$2; shift 2 ;;
    --iterations) ITERATIONS=$2; shift 2 ;;
    --threads-list) THREADS_LIST=$2; shift 2 ;;
    --tiotest-bin) TIOTEST_BIN=$2; shift 2 ;;

    --tiotest-dir) TIOTEST_DIR=$2; shift 2 ;;
    --use-raw) USE_RAW=$2; shift 2 ;;
    --offset-mb) OFFSET_MB=$2; shift 2 ;;
    --offset-first) OFFSET_FIRST=$2; shift 2 ;;

    --mode-list) MODE_LIST=$2; shift 2 ;;

    --seq-block) SEQ_BLOCK_SIZE=$2; shift 2 ;;
    --seq-file-mb) SEQ_FILE_SIZE_MB=$2; shift 2 ;;
    --rnd-block) RND_BLOCK_SIZE=$2; shift 2 ;;
    --rnd-file-mb) RND_FILE_SIZE_MB=$2; shift 2 ;;
    --rnd-ops) RND_OPS=$2; shift 2 ;;

    --hide-latency) HIDE_LATENCY=$2; shift 2 ;;
    --terse) TERSE=$2; shift 2 ;;
    --seq-write-phase) SEQ_WRITE_PHASE=$2; shift 2 ;;
    --sync-writes) SYNC_WRITES=$2; shift 2 ;;
    --consistency) CONSISTENCY=$2; shift 2 ;;
    --debug-level) DEBUG_LEVEL=$2; shift 2 ;;

    --drop-caches) DROP_CACHES=$2; shift 2 ;;
    --set-perf-gov) SET_PERF_GOV=$2; shift 2 ;;
    --require-non-tmpfs) REQUIRE_NON_TMPFS=$2; shift 2 ;;

    --baseline) BASELINE_FILE=$2; shift 2 ;;
    --delta) ALLOWED_DEVIATION=$2; shift 2 ;;
    --standalone) STANDALONE=$2; shift 2 ;;
    --) shift; break ;;
    -*)
      echo "[ERROR] Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      echo "[ERROR] Unexpected argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# ---------------- locate and source init_env → functestlib.sh + lib_performance.sh ----------------
if [ "$STANDALONE" = "1" ]; then
  : "${TOOLS:=}"
else
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
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR). Use --standalone 1 to bypass." >&2
    exit 1
  fi

  if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
  fi
fi

if [ -z "${TOOLS:-}" ] || [ ! -f "$TOOLS/functestlib.sh" ] || [ ! -f "$TOOLS/lib_performance.sh" ]; then
  echo "[ERROR] Missing TOOLS/functestlib.sh or TOOLS/lib_performance.sh. (TOOLS=$TOOLS)" >&2
  exit 1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_performance.sh"

: >"$RES_FILE"
mkdir -p "$OUT_DIR" 2>/dev/null || true

# Baseline auto-detect
if [ -z "$BASELINE_FILE" ] && [ -f "$SCRIPT_DIR/tiotest_baseline.conf" ]; then
  BASELINE_FILE="$SCRIPT_DIR/tiotest_baseline.conf"
fi

# Auto-pick TIOTEST_DIR if not set
if [ -z "$TIOTEST_DIR" ]; then
  if [ "$USE_RAW" = "1" ]; then
    TIOTEST_DIR="/dev/sda"
  else
    if [ -d /var/tmp ] && [ -w /var/tmp ]; then
      TIOTEST_DIR="/var/tmp/tiotest_fileio"
    else
      TIOTEST_DIR="/tmp/tiotest_fileio"
    fi
  fi
fi

if [ -n "$BASELINE_FILE" ] && [ ! -f "$BASELINE_FILE" ]; then
  log_warn "Baseline file set but not found: $BASELINE_FILE (will run report-only)"
  BASELINE_FILE=""
fi

cleanup() {
  restore_governor 2>/dev/null || true
}
trap cleanup EXIT

# Clock sanity
if command -v ensure_reasonable_clock >/dev/null 2>&1; then
  log_info "Ensuring system clock is reasonable before tiotest..."
  if ! ensure_reasonable_clock; then
    log_error "Clock is not reasonable; benchmark timestamps/gating may be invalid."
  fi
else
  log_info "ensure_reasonable_clock() not available, continuing."
fi

log_info "Tiotest runner starting"
log_info "OUTDIR=$OUT_DIR BASELINE=${BASELINE_FILE:-none} DELTA=$ALLOWED_DEVIATION ITERATIONS=$ITERATIONS"
log_info "THREADS_LIST=$THREADS_LIST MODE_LIST=$MODE_LIST"
log_info "TIOTEST_BIN=$TIOTEST_BIN USE_RAW=$USE_RAW TIOTEST_DIR=$TIOTEST_DIR offset_mb=${OFFSET_MB:-none} offset_first=$OFFSET_FIRST"
log_info "SEQ blk=$SEQ_BLOCK_SIZE file_mb=$SEQ_FILE_SIZE_MB RND blk=$RND_BLOCK_SIZE file_mb=$RND_FILE_SIZE_MB ops=$RND_OPS"
log_info "FLAGS hide_lat=$HIDE_LATENCY terse=$TERSE W=$SEQ_WRITE_PHASE S=$SYNC_WRITES c=$CONSISTENCY D=${DEBUG_LEVEL:-none}"
log_info "STABILITY drop_caches=$DROP_CACHES set_perf_gov=$SET_PERF_GOV require_non_tmpfs=$REQUIRE_NON_TMPFS"

perf_clock_sanity_warn 2>/dev/null || true

# ---------------- deps check ----------------
if ! check_dependencies awk sed grep date tee "$TIOTEST_BIN"; then
  log_skip "$TESTNAME SKIP - missing one or more dependencies: awk sed grep date tee $TIOTEST_BIN"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if [ "$SET_PERF_GOV" = "1" ]; then
  set_performance_governor 2>/dev/null || true
fi

# Path checks
if [ "$USE_RAW" = "1" ]; then
  if [ ! -b "$TIOTEST_DIR" ]; then
    log_skip "$TESTNAME SKIP - USE_RAW=1 but TIOTEST_DIR not a block device: $TIOTEST_DIR"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
else
  if ! mkdir -p "$TIOTEST_DIR" 2>/dev/null; then
    log_skip "$TESTNAME SKIP - TIOTEST_DIR not creatable: $TIOTEST_DIR"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
  if [ ! -w "$TIOTEST_DIR" ]; then
    log_skip "$TESTNAME SKIP - TIOTEST_DIR not writable: $TIOTEST_DIR"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
  if [ "$REQUIRE_NON_TMPFS" = "1" ] && tiotest_is_tmpfs_path "$TIOTEST_DIR"; then
    log_skip "$TESTNAME SKIP - TIOTEST_DIR appears tmpfs: $TIOTEST_DIR"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
fi

suite_rc=0
gate_fail=0

summary="$OUT_DIR/tiotest_summary.txt"
metrics="$OUT_DIR/tiotest_metrics.tsv"
: >"$summary"
: >"$metrics"

ITER_LIST=$(awk -v n="$ITERATIONS" 'BEGIN{for (k=1;k<=n;k++) printf "%d ", k}')

# Determine if we need seq and/or rnd runs
NEED_SEQ=0
NEED_RND=0
for m in $MODE_LIST; do
  case "$m" in
    seqwr|seqrd) NEED_SEQ=1 ;;
    rndwr|rndrd) NEED_RND=1 ;;
  esac
done

# If latency is hidden, don't track/print latency fields (avoids "unknown")
WANT_LAT=1
if [ "$HIDE_LATENCY" = "1" ]; then
  WANT_LAT=0
fi

# Pre-create per-mode value files only for requested modes
for tt in $THREADS_LIST; do
  for mode in $MODE_LIST; do
    : >"$OUT_DIR/${mode}_mbps_t${tt}.values" 2>/dev/null || true
    : >"$OUT_DIR/${mode}_iops_t${tt}.values" 2>/dev/null || true
    if [ "$WANT_LAT" = "1" ]; then
      : >"$OUT_DIR/${mode}_latavg_t${tt}.values" 2>/dev/null || true
      : >"$OUT_DIR/${mode}_latmax_t${tt}.values" 2>/dev/null || true
      : >"$OUT_DIR/${mode}_pct2s_t${tt}.values" 2>/dev/null || true
      : >"$OUT_DIR/${mode}_pct10s_t${tt}.values" 2>/dev/null || true
    fi
  done
done

for tt in $THREADS_LIST; do
  for it in $ITER_LIST; do
    if [ "$DROP_CACHES" = "1" ]; then
      tiotest_drop_caches_best_effort 2>/dev/null || true
    fi

    if [ "$NEED_SEQ" = "1" ]; then
      logf_seq="$OUT_DIR/tiotest_seq_t${tt}_iter${it}.log"
      if ! perf_tiotest_run_seq_pair \
        "$TIOTEST_BIN" "$tt" "$TIOTEST_DIR" "$USE_RAW" \
        "$SEQ_BLOCK_SIZE" "$SEQ_FILE_SIZE_MB" \
        "$HIDE_LATENCY" "$TERSE" "$SEQ_WRITE_PHASE" "$SYNC_WRITES" "$CONSISTENCY" "$DEBUG_LEVEL" \
        "$OFFSET_MB" "$OFFSET_FIRST" \
        "$logf_seq" "$metrics"
      then
        log_warn "tiotest: seq pair metrics missing threads=$tt iter=$it (see $logf_seq)"
        suite_rc=1
      fi
    fi

    if [ "$NEED_RND" = "1" ]; then
      logf_rnd="$OUT_DIR/tiotest_rnd_t${tt}_iter${it}.log"
      if ! perf_tiotest_run_rnd_pair \
        "$TIOTEST_BIN" "$tt" "$TIOTEST_DIR" "$USE_RAW" \
        "$RND_BLOCK_SIZE" "$RND_FILE_SIZE_MB" "$RND_OPS" \
        "$HIDE_LATENCY" "$TERSE" "$SEQ_WRITE_PHASE" "$SYNC_WRITES" "$CONSISTENCY" "$DEBUG_LEVEL" \
        "$OFFSET_MB" "$OFFSET_FIRST" \
        "$logf_rnd" "$metrics"
      then
        log_warn "tiotest: rnd metrics missing threads=$tt iter=$it (see $logf_rnd)"
        suite_rc=1
      fi
    fi

    # Emit per-mode ITER summary + append values
    for mode in $MODE_LIST; do
      mbps=$(awk -v m="$mode" -v t="$tt" '($1==m && $2==t){v=$3} END{print v}' "$metrics" 2>/dev/null)
      iops=$(awk -v m="$mode" -v t="$tt" '($1==m && $2==t){v=$4} END{print v}' "$metrics" 2>/dev/null)

      perf_append_if_number "$OUT_DIR/${mode}_mbps_t${tt}.values" "$mbps"
      perf_append_if_number "$OUT_DIR/${mode}_iops_t${tt}.values" "$iops"

      if [ "$WANT_LAT" = "1" ]; then
        lat_avg=$(awk -v m="$mode" -v t="$tt" '($1==m && $2==t){v=$5} END{print v}' "$metrics" 2>/dev/null)
        lat_max=$(awk -v m="$mode" -v t="$tt" '($1==m && $2==t){v=$6} END{print v}' "$metrics" 2>/dev/null)
        pct2=$(awk -v m="$mode" -v t="$tt" '($1==m && $2==t){v=$7} END{print v}' "$metrics" 2>/dev/null)
        pct10=$(awk -v m="$mode" -v t="$tt" '($1==m && $2==t){v=$8} END{print v}' "$metrics" 2>/dev/null)

        perf_append_if_number "$OUT_DIR/${mode}_latavg_t${tt}.values" "$lat_avg"
        perf_append_if_number "$OUT_DIR/${mode}_latmax_t${tt}.values" "$lat_max"
        perf_append_if_number "$OUT_DIR/${mode}_pct2s_t${tt}.values" "$pct2"
        perf_append_if_number "$OUT_DIR/${mode}_pct10s_t${tt}.values" "$pct10"

        log_info "ITER_SUMMARY threads=$tt iter=$it/$ITERATIONS mode=$mode mbps=$(perf_norm_metric "$mbps") iops=$(perf_norm_metric "$iops") lat_avg_ms=$(perf_norm_metric "$lat_avg") lat_max_ms=$(perf_norm_metric "$lat_max") pct_gt2s=$(perf_norm_metric "$pct2") pct_gt10s=$(perf_norm_metric "$pct10")"
      else
        log_info "ITER_SUMMARY threads=$tt iter=$it/$ITERATIONS mode=$mode mbps=$(perf_norm_metric "$mbps") iops=$(perf_norm_metric "$iops") lat=hidden"
      fi
    done
  done

  # -------- Averages per thread --------
  {
    echo "Threads=$tt"
    for mode in $MODE_LIST; do
      a_mbps=$(perf_values_avg "$OUT_DIR/${mode}_mbps_t${tt}.values")
      a_iops=$(perf_values_avg "$OUT_DIR/${mode}_iops_t${tt}.values")

      echo " ${mode}_avg_mbps : $(perf_norm_metric "$a_mbps")"
      echo " ${mode}_avg_iops : $(perf_norm_metric "$a_iops")"

      if [ "$WANT_LAT" = "1" ]; then
        a_latavg=$(perf_values_avg "$OUT_DIR/${mode}_latavg_t${tt}.values")
        a_latmax=$(perf_values_avg "$OUT_DIR/${mode}_latmax_t${tt}.values")
        a_pct2=$(perf_values_avg "$OUT_DIR/${mode}_pct2s_t${tt}.values")
        a_pct10=$(perf_values_avg "$OUT_DIR/${mode}_pct10s_t${tt}.values")

        echo " ${mode}_avg_lat_avg_ms : $(perf_norm_metric "$a_latavg")"
        echo " ${mode}_avg_lat_max_ms : $(perf_norm_metric "$a_latmax")"
        echo " ${mode}_avg_pct_gt2s : $(perf_norm_metric "$a_pct2")"
        echo " ${mode}_avg_pct_gt10s : $(perf_norm_metric "$a_pct10")"
      fi
    done
  } >>"$summary"

  # -------- Baseline gating (if helper exists) --------
  if [ -n "$BASELINE_FILE" ] && command -v perf_tiotest_gate_eval_line_safe >/dev/null 2>&1; then
    for mode in $MODE_LIST; do
      a_mbps=$(perf_values_avg "$OUT_DIR/${mode}_mbps_t${tt}.values")
      a_iops=$(perf_values_avg "$OUT_DIR/${mode}_iops_t${tt}.values")

      if [ -n "$a_mbps" ]; then
        line=$(perf_tiotest_gate_eval_line_safe "$BASELINE_FILE" "tiotest" "$tt" "${mode}_mbps" "$a_mbps" "$ALLOWED_DEVIATION")
        rc=$?
        base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
        log_info "GATE tiotest ${mode}_mbps threads=$tt avg=$a_mbps baseline=${base:-NA} goal=${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
        echo " gate_${mode}_mbps : status=${status:-NA} baseline=${base:-NA} goal=${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
        [ "$rc" -eq 1 ] && gate_fail=1
      fi

      case "$mode" in
        rndwr|rndrd)
          if [ -n "$a_iops" ]; then
            line=$(perf_tiotest_gate_eval_line_safe "$BASELINE_FILE" "tiotest" "$tt" "${mode}_iops" "$a_iops" "$ALLOWED_DEVIATION")
            rc=$?
            base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
            log_info "GATE tiotest ${mode}_iops threads=$tt avg=$a_iops baseline=${base:-NA} goal=${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
            echo " gate_${mode}_iops : status=${status:-NA} baseline=${base:-NA} goal=${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
            [ "$rc" -eq 1 ] && gate_fail=1
          fi
          ;;
      esac
    done
  fi

  echo >>"$summary"
done

log_info "Final summary written → $summary"
log_info "----- TIOTEST SUMMARY (stdout) -----"
cat "$summary" || true
log_info "----- END SUMMARY -----"

# latency strict check applies only when we actually collected latency
if [ "$HIDE_LATENCY" != "1" ]; then
  if command -v perf_tiotest_latency_strict_check >/dev/null 2>&1; then
    if ! perf_tiotest_latency_strict_check "$summary"; then
      log_fail "$TESTNAME FAIL - latency threshold breach"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 1
    fi
  fi
fi

if [ -n "$BASELINE_FILE" ] && [ "$gate_fail" -ne 0 ]; then
  log_fail "$TESTNAME FAIL - one or more KPIs did not meet baseline thresholds"
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 1
fi

log_pass "$TESTNAME PASS"
echo "$TESTNAME PASS" >"$RES_FILE"
exit "$suite_rc"
