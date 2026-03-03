#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Sysbench_Performance"
RES_FILE="./${TESTNAME}.res"

# Defaults (env overrides; CLI can override further)
OUT_DIR="${OUT_DIR:-./sysbench_out}"
ITERATIONS="${ITERATIONS:-1}"
TIME="${TIME:-30}"
RAND_SEED="${RAND_SEED:-1234}"
# Default should cover both single-thread and multi-thread baselines
THREADS_LIST="${THREADS_LIST:-1 4}"

CPU_MAX_PRIME="${CPU_MAX_PRIME:-20000}"

THREAD_LOCKS="${THREAD_LOCKS:-20}"
THREAD_YIELDS="${THREAD_YIELDS:-}"

MEMORY_OPER="${MEMORY_OPER:-write}"
MEMORY_ACCESS_MODE="${MEMORY_ACCESS_MODE:-rnd}"
MEMORY_BLOCK_SIZE="${MEMORY_BLOCK_SIZE:-1M}"
MEMORY_TOTAL_SIZE="${MEMORY_TOTAL_SIZE:-100G}"

MUTEX_NUM="${MUTEX_NUM:-}"
MUTEX_LOCKS="${MUTEX_LOCKS:-}"
MUTEX_LOOPS="${MUTEX_LOOPS:-}"

TASKSET_CPU_LIST="${TASKSET_CPU_LIST:-}"

BASELINE_FILE="${BASELINE_FILE:-}"
ALLOWED_DEVIATION="${ALLOWED_DEVIATION:-0.10}"

CSV_FILE="${CSV_FILE:-}"
VERBOSE="${VERBOSE:-0}"

# FileIO defaults (env overrides; CLI can override)
# If not explicitly set, prefer a real-disk location (not /tmp tmpfs).
FILEIO_DIR="${FILEIO_DIR:-}"
FILEIO_TOTAL_SIZE="${FILEIO_TOTAL_SIZE:-1G}"
FILEIO_BLOCK_SIZE="${FILEIO_BLOCK_SIZE:-4K}"
FILEIO_NUM="${FILEIO_NUM:-128}"
FILEIO_IO_MODE="${FILEIO_IO_MODE:-sync}"
FILEIO_FSYNC_FREQ="${FILEIO_FSYNC_FREQ:-0}"
FILEIO_EXTRA_FLAGS="${FILEIO_EXTRA_FLAGS:-none}"

# Optional: run without init_env (minimal)
STANDALONE="${STANDALONE:-0}"

usage() {
  cat <<EOF
$TESTNAME

Runs sysbench CPU/Memory/Threads/Mutex + FileIO (seqwr/seqrd/rndwr/rndrd)
for one or more thread counts, for N iterations.

ENV (defaults shown):
  OUT_DIR=$OUT_DIR
  ITERATIONS=$ITERATIONS
  TIME=$TIME
  RAND_SEED=$RAND_SEED
  THREADS_LIST=$THREADS_LIST
  TASKSET_CPU_LIST=$TASKSET_CPU_LIST
  CSV_FILE=$CSV_FILE
  CPU_MAX_PRIME=$CPU_MAX_PRIME
  THREAD_LOCKS=$THREAD_LOCKS
  THREAD_YIELDS=$THREAD_YIELDS
  MEMORY_OPER=$MEMORY_OPER
  MEMORY_ACCESS_MODE=$MEMORY_ACCESS_MODE
  MEMORY_BLOCK_SIZE=$MEMORY_BLOCK_SIZE
  MEMORY_TOTAL_SIZE=$MEMORY_TOTAL_SIZE
  MUTEX_NUM=$MUTEX_NUM
  MUTEX_LOCKS=$MUTEX_LOCKS
  MUTEX_LOOPS=$MUTEX_LOOPS
  BASELINE_FILE=$BASELINE_FILE
  ALLOWED_DEVIATION=$ALLOWED_DEVIATION
  VERBOSE=$VERBOSE
  FILEIO_DIR=${FILEIO_DIR:-"(auto)"}
  FILEIO_TOTAL_SIZE=$FILEIO_TOTAL_SIZE
  FILEIO_BLOCK_SIZE=$FILEIO_BLOCK_SIZE
  FILEIO_NUM=$FILEIO_NUM
  FILEIO_IO_MODE=$FILEIO_IO_MODE
  FILEIO_FSYNC_FREQ=$FILEIO_FSYNC_FREQ
  FILEIO_EXTRA_FLAGS=$FILEIO_EXTRA_FLAGS
  STANDALONE=$STANDALONE

CLI options:
  --out-dir DIR
  --iterations N
  --time SEC
  --seed N
  --threads-list "1 4 8"
  --taskset-cpu-list "6-7"
  --csv FILE
  --cpu-max-prime N
  --thread-locks N
  --thread-yields N
  --mem-oper read|write
  --mem-access-mode seq|rnd
  --mem-block-size SIZE
  --mem-total-size SIZE
  --mutex-num N
  --mutex-locks N
  --mutex-loops N
  --baseline FILE
  --delta FLOAT
  --fileio-dir DIR
  --fileio-total-size SIZE
  --fileio-block-size SIZE
  --fileio-num N
  --fileio-io-mode MODE
  --fileio-fsync-freq N
  --fileio-extra-flags FLAGS|none
  --standalone 0|1
  --verbose 0|1
  -h, --help
EOF
}

# ---------------- CLI parsing ----------------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR=$2; shift 2 ;;
    --iterations) ITERATIONS=$2; shift 2 ;;
    --time) TIME=$2; shift 2 ;;
    --seed) RAND_SEED=$2; shift 2 ;;
    --threads-list) THREADS_LIST=$2; shift 2 ;;
    --taskset-cpu-list) TASKSET_CPU_LIST=$2; shift 2 ;;
    --csv) CSV_FILE=$2; shift 2 ;;
    --cpu-max-prime) CPU_MAX_PRIME=$2; shift 2 ;;
    --thread-locks) THREAD_LOCKS=$2; shift 2 ;;
    --thread-yields) THREAD_YIELDS=$2; shift 2 ;;
    --mem-oper) MEMORY_OPER=$2; shift 2 ;;
    --mem-access-mode) MEMORY_ACCESS_MODE=$2; shift 2 ;;
    --mem-block-size) MEMORY_BLOCK_SIZE=$2; shift 2 ;;
    --mem-total-size) MEMORY_TOTAL_SIZE=$2; shift 2 ;;
    --mutex-num) MUTEX_NUM=$2; shift 2 ;;
    --mutex-locks) MUTEX_LOCKS=$2; shift 2 ;;
    --mutex-loops) MUTEX_LOOPS=$2; shift 2 ;;
    --baseline) BASELINE_FILE=$2; shift 2 ;;
    --delta) ALLOWED_DEVIATION=$2; shift 2 ;;
    --fileio-dir) FILEIO_DIR=$2; shift 2 ;;
    --fileio-total-size) FILEIO_TOTAL_SIZE=$2; shift 2 ;;
    --fileio-block-size) FILEIO_BLOCK_SIZE=$2; shift 2 ;;
    --fileio-num) FILEIO_NUM=$2; shift 2 ;;
    --fileio-io-mode) FILEIO_IO_MODE=$2; shift 2 ;;
    --fileio-fsync-freq) FILEIO_FSYNC_FREQ=$2; shift 2 ;;
    --fileio-extra-flags) FILEIO_EXTRA_FLAGS=$2; shift 2 ;;
    --standalone) STANDALONE=$2; shift 2 ;;
    --verbose) VERBOSE=$2; shift 2 ;;
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

# Baseline auto-detect from same folder as run.sh
if [ -z "$BASELINE_FILE" ] && [ -f "$SCRIPT_DIR/sysbench_baseline.conf" ]; then
  BASELINE_FILE="$SCRIPT_DIR/sysbench_baseline.conf"
fi

# Auto-pick FILEIO_DIR if not set: prefer non-tmpfs on real disk
if [ -z "$FILEIO_DIR" ]; then
  if [ -d /var/tmp ] && [ -w /var/tmp ]; then
    FILEIO_DIR="/var/tmp/sysbench_fileio"
  else
    FILEIO_DIR="/tmp/sysbench_fileio"
  fi
fi

# ---------------- baseline presence check (non-fatal) ----------------
if [ -n "$BASELINE_FILE" ] && [ ! -f "$BASELINE_FILE" ]; then
  log_warn "Baseline file set but not found: $BASELINE_FILE (will run report-only)"
  BASELINE_FILE=""
fi

cleanup() {
  restore_governor 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Clock sanity (avoid epoch time breaking logs / gating)
# ---------------------------------------------------------------------------
if command -v ensure_reasonable_clock >/dev/null 2>&1; then
  log_info "Ensuring system clock is reasonable before sysbench..."
  if ! ensure_reasonable_clock; then
    log_error "Clock is not reasonable, Running sysbench_Performance benchmark may lead to invalid results."
  fi
else
  log_info "ensure_reasonable_clock() not available, continuing without clock sanity check."
fi

log_info "Sysbench runner starting"
log_info "OUTDIR=$OUT_DIR BASELINE=${BASELINE_FILE:-none} DELTA=$ALLOWED_DEVIATION ITERATIONS=$ITERATIONS CORE_LIST=${TASKSET_CPU_LIST:-none}"
log_info "TIME=$TIME SEED=$RAND_SEED THREADS_LIST=$THREADS_LIST"
log_info "CPU_MAX_PRIME=$CPU_MAX_PRIME MEM=${MEMORY_OPER}/${MEMORY_ACCESS_MODE} blk=$MEMORY_BLOCK_SIZE total=$MEMORY_TOTAL_SIZE THREAD_LOCKS=$THREAD_LOCKS"
log_info "FILEIO dir=$FILEIO_DIR total=$FILEIO_TOTAL_SIZE blk=$FILEIO_BLOCK_SIZE num=$FILEIO_NUM io_mode=$FILEIO_IO_MODE fsync_freq=$FILEIO_FSYNC_FREQ extra_flags=$FILEIO_EXTRA_FLAGS"

# Warn if RTC is broken (epoch timestamps)
perf_clock_sanity_warn 2>/dev/null || true

# ---------------- deps check ----------------
if [ -n "${TASKSET_CPU_LIST:-}" ]; then
  if ! check_dependencies sysbench awk sed grep date mkfifo tee taskset; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
else
  if ! check_dependencies sysbench awk sed grep date mkfifo tee; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
fi

set_performance_governor 2>/dev/null || true

# --------- FileIO prepare (safety warning + prepare) ----------
case "$FILEIO_DIR" in
  /tmp/*|/var/tmp/*) : ;;
  *)
    log_warn "FILEIO_DIR=$FILEIO_DIR is not under /tmp or /var/tmp. This can stress rootfs if it is on /. Use --fileio-dir to point to a dedicated mount if needed."
    ;;
esac

# Ensure FILEIO_DIR is usable (addresses /tmp missing / not writable)
if ! mkdir -p "$FILEIO_DIR" 2>/dev/null; then
  log_skip "$TESTNAME SKIP - FILEIO_DIR not creatable: $FILEIO_DIR (set FILEIO_DIR to a writable path)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
if [ ! -w "$FILEIO_DIR" ]; then
  log_skip "$TESTNAME SKIP - FILEIO_DIR not writable: $FILEIO_DIR (set FILEIO_DIR to a writable path)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

log_info "Preparing sysbench fileio dataset in $FILEIO_DIR"
fileio_prepare_log="$OUT_DIR/fileio_prepare.log"
set -- sysbench fileio \
  --file-total-size="$FILEIO_TOTAL_SIZE" \
  --file-num="$FILEIO_NUM" \
  --file-block-size="$FILEIO_BLOCK_SIZE" \
  --file-io-mode="$FILEIO_IO_MODE" \
  --file-fsync-freq="$FILEIO_FSYNC_FREQ"
[ "$FILEIO_EXTRA_FLAGS" != "none" ] && set -- "$@" --file-extra-flags="$FILEIO_EXTRA_FLAGS"
set -- "$@" prepare
run_sysbench_case "FileIO prepare" "$fileio_prepare_log" "$@" || true

suite_rc=0
gate_fail=0

summary="$OUT_DIR/sysbench_summary.txt"
: >"$summary"

ITER_LIST=$(awk -v n="$ITERATIONS" 'BEGIN{for (k=1; k<=n; k++) printf "%d ", k}')

for sb_threads in $THREADS_LIST; do
  cpu_vals="$OUT_DIR/cpu_t${sb_threads}.values"
  mem_vals="$OUT_DIR/mem_t${sb_threads}.values"
  thr_vals="$OUT_DIR/threads_t${sb_threads}.values"
  mtx_vals="$OUT_DIR/mutex_t${sb_threads}.values"

  fio_seqwr_vals="$OUT_DIR/fileio_seqwr_t${sb_threads}.values"
  fio_seqrd_vals="$OUT_DIR/fileio_seqrd_t${sb_threads}.values"
  fio_rndwr_vals="$OUT_DIR/fileio_rndwr_t${sb_threads}.values"
  fio_rndrd_vals="$OUT_DIR/fileio_rndrd_t${sb_threads}.values"

  : >"$cpu_vals" 2>/dev/null || true
  : >"$mem_vals" 2>/dev/null || true
  : >"$thr_vals" 2>/dev/null || true
  : >"$mtx_vals" 2>/dev/null || true
  : >"$fio_seqwr_vals" 2>/dev/null || true
  : >"$fio_seqrd_vals" 2>/dev/null || true
  : >"$fio_rndwr_vals" 2>/dev/null || true
  : >"$fio_rndrd_vals" 2>/dev/null || true

  thr_opt=$(sysbench_threads_opt "$sb_threads")

  for sb_iter in $ITER_LIST; do
    cpu_time=""
    mem_mbps=""
    thr_time=""
    mtx_time=""

    seqwr_mbps=""
    seqrd_mbps=""
    rndwr_mbps=""
    rndrd_mbps=""

    # CPU (NOTE: total time is meaningful only if NOT forced by --time)
    cpu_log="$OUT_DIR/cpu_t${sb_threads}_iter${sb_iter}.log"
    set -- sysbench --rand-seed="$RAND_SEED"
    [ -n "$thr_opt" ] && set -- "$@" "$thr_opt"
    set -- "$@" cpu --cpu-max-prime="$CPU_MAX_PRIME" run
    if [ -n "$TASKSET_CPU_LIST" ]; then
      set -- taskset -c "$TASKSET_CPU_LIST" "$@"
    fi
    run_sysbench_case "CPU (threads=$sb_threads iteration $sb_iter/$ITERATIONS)" "$cpu_log" "$@" || true
    cpu_time=$(perf_sysbench_parse_time_sec "$cpu_log" 2>/dev/null || true)
    if [ -n "$cpu_time" ]; then
      log_info "CPU: iteration $sb_iter time_sec=$cpu_time"
      perf_values_append "$cpu_vals" "$cpu_time"
      [ -n "$CSV_FILE" ] && perf_sysbench_csv_append "$CSV_FILE" "cpu" "$sb_threads" "time_sec" "$sb_iter" "$cpu_time"
    else
      log_warn "CPU: iteration $sb_iter could not parse time from $cpu_log"
      suite_rc=1
    fi

    # Memory
    mem_log="$OUT_DIR/mem_t${sb_threads}_iter${sb_iter}.log"
    set -- sysbench --time="$TIME" --rand-seed="$RAND_SEED"
    [ -n "$thr_opt" ] && set -- "$@" "$thr_opt"
    set -- "$@" memory \
      --memory-oper="$MEMORY_OPER" \
      --memory-access-mode="$MEMORY_ACCESS_MODE" \
      --memory-block-size="$MEMORY_BLOCK_SIZE" \
      --memory-total-size="$MEMORY_TOTAL_SIZE" run
    if [ -n "$TASKSET_CPU_LIST" ]; then
      set -- taskset -c "$TASKSET_CPU_LIST" "$@"
    fi
    run_sysbench_case "Memory (threads=$sb_threads iteration $sb_iter/$ITERATIONS)" "$mem_log" "$@" || true
    mem_mbps=$(perf_sysbench_parse_mem_mbps "$mem_log" 2>/dev/null || true)
    if [ -n "$mem_mbps" ]; then
      log_info "Memory: iteration $sb_iter mem_mbps=$mem_mbps"
      perf_values_append "$mem_vals" "$mem_mbps"
      [ -n "$CSV_FILE" ] && perf_sysbench_csv_append "$CSV_FILE" "memory" "$sb_threads" "mem_mbps" "$sb_iter" "$mem_mbps"
    else
      log_warn "Memory: iteration $sb_iter could not parse MB/sec from $mem_log"
      suite_rc=1
    fi

    # Threads (same note as CPU: do NOT force --time if you want “total time” as KPI)
    thr_log="$OUT_DIR/threads_t${sb_threads}_iter${sb_iter}.log"
    set -- sysbench --rand-seed="$RAND_SEED"
    [ -n "$thr_opt" ] && set -- "$@" "$thr_opt"
    set -- "$@" threads --thread-locks="$THREAD_LOCKS"
    if [ -n "$THREAD_YIELDS" ]; then
      set -- "$@" --thread-yields="$THREAD_YIELDS"
    fi
    set -- "$@" run
    if [ -n "$TASKSET_CPU_LIST" ]; then
      set -- taskset -c "$TASKSET_CPU_LIST" "$@"
    fi
    run_sysbench_case "Threads (threads=$sb_threads iteration $sb_iter/$ITERATIONS)" "$thr_log" "$@" || true
    thr_time=$(perf_sysbench_parse_time_sec "$thr_log" 2>/dev/null || true)
    if [ -n "$thr_time" ]; then
      log_info "Threads: iteration $sb_iter time_sec=$thr_time"
      perf_values_append "$thr_vals" "$thr_time"
      [ -n "$CSV_FILE" ] && perf_sysbench_csv_append "$CSV_FILE" "threads" "$sb_threads" "time_sec" "$sb_iter" "$thr_time"
    else
      log_warn "Threads: iteration $sb_iter could not parse time from $thr_log"
      suite_rc=1
    fi

    # Mutex
    mtx_log="$OUT_DIR/mutex_t${sb_threads}_iter${sb_iter}.log"
    set -- sysbench --rand-seed="$RAND_SEED"
    [ -n "$thr_opt" ] && set -- "$@" "$thr_opt"
    set -- "$@" mutex
    [ -n "$MUTEX_NUM" ] && set -- "$@" --mutex-num="$MUTEX_NUM"
    [ -n "$MUTEX_LOCKS" ] && set -- "$@" --mutex-locks="$MUTEX_LOCKS"
    [ -n "$MUTEX_LOOPS" ] && set -- "$@" --mutex-loops="$MUTEX_LOOPS"
    set -- "$@" run
    if [ -n "$TASKSET_CPU_LIST" ]; then
      set -- taskset -c "$TASKSET_CPU_LIST" "$@"
    fi
    run_sysbench_case "Mutex (threads=$sb_threads iteration $sb_iter/$ITERATIONS)" "$mtx_log" "$@" || true
    mtx_time=$(perf_sysbench_parse_time_sec "$mtx_log" 2>/dev/null || true)
    if [ -n "$mtx_time" ]; then
      log_info "Mutex: iteration $sb_iter time_sec=$mtx_time"
      perf_values_append "$mtx_vals" "$mtx_time"
      [ -n "$CSV_FILE" ] && perf_sysbench_csv_append "$CSV_FILE" "mutex" "$sb_threads" "time_sec" "$sb_iter" "$mtx_time"
    else
      log_warn "Mutex: iteration $sb_iter could not parse time from $mtx_log"
      suite_rc=1
    fi

    # -------- FileIO modes (MiB/s -> MB/s; store as *_mbps) --------
    for mode in seqwr seqrd rndwr rndrd; do
      fio_log="$OUT_DIR/fileio_${mode}_t${sb_threads}_iter${sb_iter}.log"
      set -- sysbench --time="$TIME" --rand-seed="$RAND_SEED"
      [ -n "$thr_opt" ] && set -- "$@" "$thr_opt"
      set -- "$@" fileio \
        --file-total-size="$FILEIO_TOTAL_SIZE" \
        --file-num="$FILEIO_NUM" \
        --file-block-size="$FILEIO_BLOCK_SIZE" \
        --file-io-mode="$FILEIO_IO_MODE" \
        --file-test-mode="$mode" \
        --file-fsync-freq="$FILEIO_FSYNC_FREQ"
      [ "$FILEIO_EXTRA_FLAGS" != "none" ] && set -- "$@" --file-extra-flags="$FILEIO_EXTRA_FLAGS"
      set -- "$@" run
      run_sysbench_case "FileIO $mode (threads=$sb_threads iteration $sb_iter/$ITERATIONS)" "$fio_log" "$@" || true

      case "$mode" in
        seqwr)
          raw=$(perf_sysbench_parse_fileio_written_mibps "$fio_log" 2>/dev/null || true)
          seqwr_mbps=$(sysbench_mib_to_mb "$raw" 2>/dev/null || true)
          [ -n "$seqwr_mbps" ] && perf_values_append "$fio_seqwr_vals" "$seqwr_mbps"
          [ -n "$CSV_FILE" ] && perf_sysbench_csv_append "$CSV_FILE" "fileio" "$sb_threads" "seqwr_mbps" "$sb_iter" "$seqwr_mbps"
          ;;
        seqrd)
          raw=$(perf_sysbench_parse_fileio_read_mibps "$fio_log" 2>/dev/null || true)
          seqrd_mbps=$(sysbench_mib_to_mb "$raw" 2>/dev/null || true)
          [ -n "$seqrd_mbps" ] && perf_values_append "$fio_seqrd_vals" "$seqrd_mbps"
          [ -n "$CSV_FILE" ] && perf_sysbench_csv_append "$CSV_FILE" "fileio" "$sb_threads" "seqrd_mbps" "$sb_iter" "$seqrd_mbps"
          ;;
        rndwr)
          raw=$(perf_sysbench_parse_fileio_written_mibps "$fio_log" 2>/dev/null || true)
          rndwr_mbps=$(sysbench_mib_to_mb "$raw" 2>/dev/null || true)
          [ -n "$rndwr_mbps" ] && perf_values_append "$fio_rndwr_vals" "$rndwr_mbps"
          [ -n "$CSV_FILE" ] && perf_sysbench_csv_append "$CSV_FILE" "fileio" "$sb_threads" "rndwr_mbps" "$sb_iter" "$rndwr_mbps"
          ;;
        rndrd)
          raw=$(perf_sysbench_parse_fileio_read_mibps "$fio_log" 2>/dev/null || true)
          rndrd_mbps=$(sysbench_mib_to_mb "$raw" 2>/dev/null || true)
          [ -n "$rndrd_mbps" ] && perf_values_append "$fio_rndrd_vals" "$rndrd_mbps"
          [ -n "$CSV_FILE" ] && perf_sysbench_csv_append "$CSV_FILE" "fileio" "$sb_threads" "rndrd_mbps" "$sb_iter" "$rndrd_mbps"
          ;;
      esac
    done

    log_info "ITER_SUMMARY threads=$sb_threads iter=$sb_iter/$ITERATIONS cpu_time_sec=${cpu_time:-NA} mem_mbps=${mem_mbps:-NA} threads_time_sec=${thr_time:-NA} mutex_time_sec=${mtx_time:-NA} seqwr_mbps=${seqwr_mbps:-NA} seqrd_mbps=${seqrd_mbps:-NA} rndwr_mbps=${rndwr_mbps:-NA} rndrd_mbps=${rndrd_mbps:-NA}"
  done

  cpu_avg=$(perf_values_avg "$cpu_vals")
  mem_avg=$(perf_values_avg "$mem_vals")
  thr_avg=$(perf_values_avg "$thr_vals")
  mtx_avg=$(perf_values_avg "$mtx_vals")

  seqwr_avg=$(perf_values_avg "$fio_seqwr_vals")
  seqrd_avg=$(perf_values_avg "$fio_seqrd_vals")
  rndwr_avg=$(perf_values_avg "$fio_rndwr_vals")
  rndrd_avg=$(perf_values_avg "$fio_rndrd_vals")

  {
    echo "Threads=$sb_threads"
    [ -n "$cpu_avg" ] && echo " cpu_avg_time_sec : $cpu_avg" || echo " cpu_avg_time_sec : unknown"
    [ -n "$mem_avg" ] && echo " mem_avg_mbps : $mem_avg" || echo " mem_avg_mbps : unknown"
    [ -n "$thr_avg" ] && echo " threads_avg_time_sec : $thr_avg" || echo " threads_avg_time_sec : unknown"
    [ -n "$mtx_avg" ] && echo " mutex_avg_time_sec : $mtx_avg" || echo " mutex_avg_time_sec : unknown"
    [ -n "$seqwr_avg" ] && echo " fileio_seqwr_avg_mbps : $seqwr_avg" || echo " fileio_seqwr_avg_mbps : unknown"
    [ -n "$seqrd_avg" ] && echo " fileio_seqrd_avg_mbps : $seqrd_avg" || echo " fileio_seqrd_avg_mbps : unknown"
    [ -n "$rndwr_avg" ] && echo " fileio_rndwr_avg_mbps : $rndwr_avg" || echo " fileio_rndwr_avg_mbps : unknown"
    [ -n "$rndrd_avg" ] && echo " fileio_rndrd_avg_mbps : $rndrd_avg" || echo " fileio_rndrd_avg_mbps : unknown"
  } >>"$summary"

  # ---------------- Baseline gating per AVG ----------------
  if [ -n "$BASELINE_FILE" ] && command -v perf_sysbench_gate_eval_line >/dev/null 2>&1; then
    # cpu time_sec
    if [ -n "$cpu_avg" ]; then
      line=$(perf_sysbench_gate_eval_line_safe "$BASELINE_FILE" "cpu" "$sb_threads" "time_sec" "$cpu_avg" "$ALLOWED_DEVIATION")
      rc=$?
      base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
      log_info "GATE cpu threads=$sb_threads avg=$cpu_avg baseline=${base:-NA} goal${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
      echo " gate_cpu_time_sec : status=${status:-NA} baseline=${base:-NA} goal${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
      [ "$rc" -eq 1 ] && gate_fail=1
    fi

    # memory mem_mbps
    if [ -n "$mem_avg" ]; then
      line=$(perf_sysbench_gate_eval_line_safe "$BASELINE_FILE" "memory" "$sb_threads" "mem_mbps" "$mem_avg" "$ALLOWED_DEVIATION")
      rc=$?
      base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
      log_info "GATE memory threads=$sb_threads avg=$mem_avg baseline=${base:-NA} goal${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
      echo " gate_memory_mem_mbps : status=${status:-NA} baseline=${base:-NA} goal${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
      [ "$rc" -eq 1 ] && gate_fail=1
    fi

    # threads time_sec
    if [ -n "$thr_avg" ]; then
      line=$(perf_sysbench_gate_eval_line_safe "$BASELINE_FILE" "threads" "$sb_threads" "time_sec" "$thr_avg" "$ALLOWED_DEVIATION")
      rc=$?
      base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
      log_info "GATE threads threads=$sb_threads avg=$thr_avg baseline=${base:-NA} goal${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
      echo " gate_threads_time_sec : status=${status:-NA} baseline=${base:-NA} goal${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
      [ "$rc" -eq 1 ] && gate_fail=1
    fi

    # mutex time_sec
    if [ -n "$mtx_avg" ]; then
      line=$(perf_sysbench_gate_eval_line_safe "$BASELINE_FILE" "mutex" "$sb_threads" "time_sec" "$mtx_avg" "$ALLOWED_DEVIATION")
      rc=$?
      base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
      log_info "GATE mutex threads=$sb_threads avg=$mtx_avg baseline=${base:-NA} goal${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
      echo " gate_mutex_time_sec : status=${status:-NA} baseline=${base:-NA} goal${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
      [ "$rc" -eq 1 ] && gate_fail=1
    fi

    # -------- FileIO gating in MB/s (mbps) --------
    if [ -n "$seqwr_avg" ]; then
      line=$(perf_sysbench_gate_eval_line_safe "$BASELINE_FILE" "fileio" "$sb_threads" "seqwr_mbps" "$seqwr_avg" "$ALLOWED_DEVIATION")
      rc=$?
      base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
      log_info "GATE fileio seqwr threads=$sb_threads avg=$seqwr_avg baseline=${base:-NA} goal${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
      echo " gate_fileio_seqwr_mbps : status=${status:-NA} baseline=${base:-NA} goal${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
      [ "$rc" -eq 1 ] && gate_fail=1
    fi

    if [ -n "$seqrd_avg" ]; then
      line=$(perf_sysbench_gate_eval_line_safe "$BASELINE_FILE" "fileio" "$sb_threads" "seqrd_mbps" "$seqrd_avg" "$ALLOWED_DEVIATION")
      rc=$?
      base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
      log_info "GATE fileio seqrd threads=$sb_threads avg=$seqrd_avg baseline=${base:-NA} goal${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
      echo " gate_fileio_seqrd_mbps : status=${status:-NA} baseline=${base:-NA} goal${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
      [ "$rc" -eq 1 ] && gate_fail=1
    fi

    if [ -n "$rndwr_avg" ]; then
      line=$(perf_sysbench_gate_eval_line_safe "$BASELINE_FILE" "fileio" "$sb_threads" "rndwr_mbps" "$rndwr_avg" "$ALLOWED_DEVIATION")
      rc=$?
      base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
      log_info "GATE fileio rndwr threads=$sb_threads avg=$rndwr_avg baseline=${base:-NA} goal${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
      echo " gate_fileio_rndwr_mbps : status=${status:-NA} baseline=${base:-NA} goal${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
      [ "$rc" -eq 1 ] && gate_fail=1
    fi

    if [ -n "$rndrd_avg" ]; then
      line=$(perf_sysbench_gate_eval_line_safe "$BASELINE_FILE" "fileio" "$sb_threads" "rndrd_mbps" "$rndrd_avg" "$ALLOWED_DEVIATION")
      rc=$?
      base=$(kv "$line" "baseline"); goal=$(kv "$line" "goal"); op=$(kv "$line" "op"); score=$(kv "$line" "score_pct"); status=$(kv "$line" "status")
      log_info "GATE fileio rndrd threads=$sb_threads avg=$rndrd_avg baseline=${base:-NA} goal${op}${goal:-NA} delta=$ALLOWED_DEVIATION score_pct=${score:-NA} status=${status:-NA}"
      echo " gate_fileio_rndrd_mbps : status=${status:-NA} baseline=${base:-NA} goal${op}${goal:-NA} score_pct=${score:-NA} delta=$ALLOWED_DEVIATION" >>"$summary"
      [ "$rc" -eq 1 ] && gate_fail=1
    fi
  fi

  echo >>"$summary"
done

log_info "Final summary written → $summary"
log_info "----- SYSBENCH SUMMARY (stdout) -----"
cat "$summary" || true
log_info "----- END SUMMARY -----"

if [ -n "$BASELINE_FILE" ] && [ "$gate_fail" -ne 0 ]; then
  log_fail "$TESTNAME FAIL - one or more KPIs did not meet baseline thresholds"
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 1
fi

log_pass "$TESTNAME PASS"
echo "$TESTNAME PASS" >"$RES_FILE"
exit "$suite_rc"
