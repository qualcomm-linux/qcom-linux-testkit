#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Geekbench runner with live console progress + CSV dump (summary + workloads)
# POSIX + LAVA-friendly, always exits 0, writes PASS/FAIL/SKIP to .res

TESTNAME="Geekbench"

# -----------------------------------------------------------------------------
# Robust init_env discovery + load
# -----------------------------------------------------------------------------
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

if [ -z "${INIT_ENV:-}" ]; then
  echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
  echo "$TESTNAME SKIP" >"$SCRIPT_DIR/${TESTNAME}.res" 2>/dev/null || true
  exit 0
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
  # shellcheck disable=SC1090
  . "$INIT_ENV"
  __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_performance.sh"

# -----------------------------------------------------------------------------
# Defaults (env vars first, CLI overrides)
# -----------------------------------------------------------------------------
OUTDIR_DEFAULT="$SCRIPT_DIR/geekbench_out"
RES_FILE_DEFAULT="$SCRIPT_DIR/${TESTNAME}.res"

RUNS="${GEEKBENCH_RUNS:-1}"
OUTDIR="${GEEKBENCH_OUTDIR:-$OUTDIR_DEFAULT}"
RES_FILE="${GEEKBENCH_RES_FILE:-$RES_FILE_DEFAULT}"
CORE_LIST="${GEEKBENCH_CORE_LIST:-}"
SET_PERF_GOV="${GEEKBENCH_SET_PERF_GOV:-1}"
GB_BIN="${GEEKBENCH_BIN:-geekbench_aarch64}"
PROGRESS_HEARTBEAT_SECS="${GEEKBENCH_PROGRESS_HEARTBEAT_SECS:-15}"

UNLOCK_EMAIL="${GEEKBENCH_UNLOCK_EMAIL:-}"
UNLOCK_KEY="${GEEKBENCH_UNLOCK_KEY:-}"

GB_LOAD_FILE="${GEEKBENCH_LOAD_FILE:-}"
GB_SAVE_FILE="${GEEKBENCH_SAVE_FILE:-}"
GB_EXPORT_CSV_FILE="${GEEKBENCH_EXPORT_CSV_FILE:-}"
GB_EXPORT_HTML_FILE="${GEEKBENCH_EXPORT_HTML_FILE:-}"
GB_EXPORT_JSON_FILE="${GEEKBENCH_EXPORT_JSON_FILE:-}"
GB_EXPORT_XML_FILE="${GEEKBENCH_EXPORT_XML_FILE:-}"
GB_EXPORT_TEXT_FILE="${GEEKBENCH_EXPORT_TEXT_FILE:-}"
GB_EXPORT_LICENSE_DIR="${GEEKBENCH_EXPORT_LICENSE_DIR:-}"
GB_UPLOAD="${GEEKBENCH_UPLOAD:-}"
GB_NO_UPLOAD="${GEEKBENCH_NO_UPLOAD:-1}"

GB_CPU="${GEEKBENCH_CPU:-}"
GB_SYSINFO="${GEEKBENCH_SYSINFO:-}"

GB_GPU="${GEEKBENCH_GPU:-}"
GB_GPU_LIST="${GEEKBENCH_GPU_LIST:-}"
GB_GPU_PLATFORM_ID="${GEEKBENCH_GPU_PLATFORM_ID:-}"
GB_GPU_DEVICE_ID="${GEEKBENCH_GPU_DEVICE_ID:-}"

GB_SECTION="${GEEKBENCH_SECTION:-}"
GB_WORKLOAD="${GEEKBENCH_WORKLOAD:-}"
GB_WORKLOAD_LIST="${GEEKBENCH_WORKLOAD_LIST:-}"
GB_SINGLE_CORE="${GEEKBENCH_SINGLE_CORE:-}"
GB_MULTI_CORE="${GEEKBENCH_MULTI_CORE:-}"
GB_CPU_WORKERS="${GEEKBENCH_CPU_WORKERS:-}"
GB_ITERATIONS="${GEEKBENCH_ITERATIONS:-}"
GB_WORKLOAD_GAP="${GEEKBENCH_WORKLOAD_GAP:-}"

GEEKBENCH_ARGS="${GEEKBENCH_ARGS:-}"

usage() {
  cat <<EOF
Usage: $0 [script options] [-- geekbench options...]
 
Script options (handled by this wrapper):
  -h|--help|-help                 Show this help and exit (does NOT run Geekbench)
  --outdir DIR                    Output directory (default: $OUTDIR_DEFAULT)
  --res-file FILE                 Result file (default: $RES_FILE_DEFAULT)
  --runs N                        Number of benchmark runs (default: ${RUNS})
  --core-list LIST                Pin Geekbench using taskset -c LIST
  --bin|-bin PATH                 Geekbench binary (file/dir/command)
  --unlock EMAIL KEY              Unlock Geekbench (if supported)
  --no-perf-gov                   Do not force CPU governor to performance
  --progress-heartbeat N          Progress heartbeat seconds (default: ${PROGRESS_HEARTBEAT_SECS})
 
Geekbench convenience options (parsed/validated by this wrapper, then passed to Geekbench if supported):
  --no-upload                     Default behavior (if supported)
  --upload
  --cpu
  --sysinfo
  --load FILE
  --save FILE
  --export-csv FILE
  --export-html FILE
  --export-json FILE
  --export-xml FILE
  --export-text FILE
  --export-license DIR
  --gpu [API]
  --gpu-list
  --gpu-platform-id ID
  --gpu-device-id ID
  --section NAME
  --workload NAME
  --workload-list
  --single-core
  --multi-core
  --cpu-workers N
  --iterations N
  --workload-gap N
 
Forwarding rules:
  - Unknown options are forwarded to Geekbench.
  - Use "--" to pass raw Geekbench args without wrapper parsing.
 
Examples:
  $0 --bin /var/Geekbench/geekbench_aarch64 --single-core
  $0 --runs 3 --core-list 0-3 -- --no-upload --single-core
  $0 -- --help        # show Geekbench's own help
 
Notes:
  - Script always exits 0 and writes PASS/FAIL/SKIP to .res
EOF
}

# -----------------------------------------------------------------------------
# CLI parsing
# -----------------------------------------------------------------------------
FORWARD_ARGS=""
IN_FORWARD=0

append_forward() {
  if [ -n "$FORWARD_ARGS" ]; then
    FORWARD_ARGS="$FORWARD_ARGS $1"
  else
    FORWARD_ARGS="$1"
  fi
}

while [ $# -gt 0 ]; do
  if [ "$IN_FORWARD" = "1" ]; then
    append_forward "$1"
    shift
    continue
  fi

  case "$1" in
    -h|--help|-help)
      # Usage should always be short; never forward help flags by accident.
      # To get Geekbench's full help, user must pass: $0 -- --help
      usage
      echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
      exit 0
      ;;
    --) IN_FORWARD=1; shift ;;

    --outdir) shift; OUTDIR=${1:-}; shift ;;
    --res-file) shift; RES_FILE=${1:-}; shift ;;
    --runs) shift; RUNS=${1:-}; shift ;;
    --core-list) shift; CORE_LIST=${1:-}; shift ;;
    --bin|-bin) shift; GB_BIN=${1:-}; shift ;;

    --unlock) shift; UNLOCK_EMAIL=${1:-}; shift; UNLOCK_KEY=${1:-}; shift ;;
    --no-perf-gov) SET_PERF_GOV="0"; shift ;;
    --progress-heartbeat) shift; PROGRESS_HEARTBEAT_SECS=${1:-}; shift ;;

    --load) shift; GB_LOAD_FILE=${1:-}; shift ;;
    --save) shift; GB_SAVE_FILE=${1:-}; shift ;;
    --export-csv) shift; GB_EXPORT_CSV_FILE=${1:-}; shift ;;
    --export-html) shift; GB_EXPORT_HTML_FILE=${1:-}; shift ;;
    --export-json) shift; GB_EXPORT_JSON_FILE=${1:-}; shift ;;
    --export-xml) shift; GB_EXPORT_XML_FILE=${1:-}; shift ;;
    --export-text) shift; GB_EXPORT_TEXT_FILE=${1:-}; shift ;;
    --export-license) shift; GB_EXPORT_LICENSE_DIR=${1:-}; shift ;;
    --upload) GB_UPLOAD=1; GB_NO_UPLOAD=""; shift ;;
    --no-upload) GB_NO_UPLOAD=1; GB_UPLOAD=""; shift ;;
    --cpu) GB_CPU=1; shift ;;
    --sysinfo) GB_SYSINFO=1; shift ;;

    --gpu)
      shift
      case "${1:-}" in
        ""|--*) GB_GPU=1 ;;
        *) GB_GPU=$1; shift ;;
      esac
      ;;
    --gpu-list) GB_GPU_LIST=1; shift ;;
    --gpu-platform-id) shift; GB_GPU_PLATFORM_ID=${1:-}; shift ;;
    --gpu-device-id) shift; GB_GPU_DEVICE_ID=${1:-}; shift ;;

    --section) shift; GB_SECTION=${1:-}; shift ;;
    --workload) shift; GB_WORKLOAD=${1:-}; shift ;;
    --workload-list) GB_WORKLOAD_LIST=1; shift ;;
    --single-core) GB_SINGLE_CORE=1; shift ;;
    --multi-core) GB_MULTI_CORE=1; shift ;;
    --cpu-workers) shift; GB_CPU_WORKERS=${1:-}; shift ;;
    --iterations) shift; GB_ITERATIONS=${1:-}; shift ;;
    --workload-gap) shift; GB_WORKLOAD_GAP=${1:-}; shift ;;

    *) append_forward "$1"; shift ;;
  esac
done

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------
mkdir -p "$OUTDIR" 2>/dev/null || true
: >"$RES_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Clock sanity (avoid epoch time breaking logs / gating)
# ---------------------------------------------------------------------------
if command -v ensure_reasonable_clock >/dev/null 2>&1; then
  log_info "Ensuring system clock is reasonable before Geekbench..."
  if ! ensure_reasonable_clock; then
    log_error "Clock is not reasonable, Running Geekbench benchmark may lead to invalid results."
  fi
else
  log_info "ensure_reasonable_clock() not available, continuing without clock sanity check."
fi

# Warn if RTC is broken (epoch timestamps)
perf_clock_sanity_warn 2>/dev/null || true

case "${RUNS:-}" in ""|*[!0-9]*) RUNS=1 ;; esac
if [ "$RUNS" -lt 1 ] 2>/dev/null; then RUNS=1; fi

case "${PROGRESS_HEARTBEAT_SECS:-}" in ""|*[!0-9]*) PROGRESS_HEARTBEAT_SECS=15 ;; esac
if [ "$PROGRESS_HEARTBEAT_SECS" -lt 1 ] 2>/dev/null; then PROGRESS_HEARTBEAT_SECS=15; fi

SUMMARY_CSV="$OUTDIR/geekbench_summary.csv"
WORKLOADS_CSV="$OUTDIR/geekbench_workloads.csv"
FINAL_SUMMARY_TXT="$OUTDIR/geekbench_final_summary.txt"
HELP_FILE="$OUTDIR/geekbench_help.txt"
UNLOCK_LOG="$OUTDIR/geekbench_unlock.log"

log_info "Geekbench runner:"
log_info " OUTDIR : $OUTDIR"
log_info " RUNS : $RUNS"
log_info " CORE_LIST : ${CORE_LIST:-none}"
log_info " Requested : $GB_BIN"

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------
if [ -n "${CORE_LIST:-}" ]; then
  if ! check_dependencies awk sed grep date mkfifo tee sleep taskset; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
    exit 0
  fi
else
  if ! check_dependencies awk sed grep date mkfifo tee sleep; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Resolve Geekbench binary
# -----------------------------------------------------------------------------
GB_REAL_BIN=$(perf_geekbench_resolve_bin_and_fix_perms "$GB_BIN" 2>/dev/null || true)
if [ -z "${GB_REAL_BIN:-}" ] || [ ! -x "$GB_REAL_BIN" ]; then
  log_skip "$TESTNAME SKIP - geekbench binary not found or not executable"
  log_skip " Requested : $GB_BIN"
  echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
  exit 0
fi

log_info "Geekbench:"
log_info " Resolved : $GB_REAL_BIN"

# -----------------------------------------------------------------------------
# Optional CPU governor to performance
# -----------------------------------------------------------------------------
if [ "$SET_PERF_GOV" = "1" ]; then
  set_performance_governor || true
fi

cleanup() {
  if [ "$SET_PERF_GOV" = "1" ]; then
    restore_governor || true
  fi
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Unlock (if requested) then capture --help
# -----------------------------------------------------------------------------
: >"$HELP_FILE" 2>/dev/null || true

if [ -n "${UNLOCK_EMAIL:-}" ] && [ -n "${UNLOCK_KEY:-}" ]; then
  log_info "Geekbench unlock:"
  log_info " Email : (provided)"
  log_info " Log : $UNLOCK_LOG"
  perf_geekbench_unlock_if_requested "$GB_REAL_BIN" "$UNLOCK_EMAIL" "$UNLOCK_KEY" "$UNLOCK_LOG" || true
fi

"$GB_REAL_BIN" --help >"$HELP_FILE" 2>&1 || true

# -----------------------------------------------------------------------------
# Build Geekbench args (consumes all parsed vars)
# -----------------------------------------------------------------------------
GB_ARGS_BUILT=""

# default no-upload
if [ -n "${GB_NO_UPLOAD:-}" ] && [ -z "${GB_UPLOAD:-}" ]; then
  if grep -q -- '--no-upload' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --no-upload"
  fi
fi

# cpu/sysinfo
if [ "${GB_CPU:-}" = "1" ] && grep -q -- '--cpu' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --cpu"
fi
if [ "${GB_SYSINFO:-}" = "1" ] && grep -q -- '--sysinfo' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --sysinfo"
fi

# load/save/export
if [ -n "${GB_LOAD_FILE:-}" ] && grep -q -- '--load' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --load ${GB_LOAD_FILE}"
elif [ -n "${GB_LOAD_FILE:-}" ]; then
  log_warn "Geekbench: ignoring unsupported option --load (unlock may be required)"
fi

if [ -n "${GB_SAVE_FILE:-}" ] && grep -q -- '--save' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --save ${GB_SAVE_FILE}"
elif [ -n "${GB_SAVE_FILE:-}" ]; then
  log_warn "Geekbench: ignoring unsupported option --save (unlock may be required)"
fi

if [ -n "${GB_EXPORT_CSV_FILE:-}" ] && grep -q -- '--export-csv' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --export-csv ${GB_EXPORT_CSV_FILE}"
elif [ -n "${GB_EXPORT_CSV_FILE:-}" ]; then
  log_warn "Geekbench: ignoring unsupported option --export-csv (unlock may be required)"
fi

if [ -n "${GB_EXPORT_HTML_FILE:-}" ] && grep -q -- '--export-html' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --export-html ${GB_EXPORT_HTML_FILE}"
elif [ -n "${GB_EXPORT_HTML_FILE:-}" ]; then
  log_warn "Geekbench: ignoring unsupported option --export-html (unlock may be required)"
fi

if [ -n "${GB_EXPORT_JSON_FILE:-}" ] && grep -q -- '--export-json' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --export-json ${GB_EXPORT_JSON_FILE}"
elif [ -n "${GB_EXPORT_JSON_FILE:-}" ]; then
  log_warn "Geekbench: ignoring unsupported option --export-json (unlock may be required)"
fi

if [ -n "${GB_EXPORT_XML_FILE:-}" ] && grep -q -- '--export-xml' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --export-xml ${GB_EXPORT_XML_FILE}"
elif [ -n "${GB_EXPORT_XML_FILE:-}" ]; then
  log_warn "Geekbench: ignoring unsupported option --export-xml (unlock may be required)"
fi

if [ -n "${GB_EXPORT_TEXT_FILE:-}" ] && grep -q -- '--export-text' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --export-text ${GB_EXPORT_TEXT_FILE}"
elif [ -n "${GB_EXPORT_TEXT_FILE:-}" ]; then
  log_warn "Geekbench: ignoring unsupported option --export-text (unlock may be required)"
fi

if [ -n "${GB_EXPORT_LICENSE_DIR:-}" ] && grep -q -- '--export-license' "$HELP_FILE" 2>/dev/null; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} --export-license ${GB_EXPORT_LICENSE_DIR}"
elif [ -n "${GB_EXPORT_LICENSE_DIR:-}" ]; then
  log_warn "Geekbench: ignoring unsupported option --export-license (unlock may be required)"
fi

# upload/no-upload
if [ "${GB_UPLOAD:-}" = "1" ]; then
  if grep -q -- '--upload' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --upload"
  else
    log_warn "Geekbench: ignoring unsupported option --upload"
  fi
fi
if [ "${GB_NO_UPLOAD:-}" = "1" ] && [ -z "${GB_UPLOAD:-}" ]; then
  if grep -q -- '--no-upload' "$HELP_FILE" 2>/dev/null; then
    case " $GB_ARGS_BUILT " in
      *" --no-upload "*) : ;;
      *) GB_ARGS_BUILT="${GB_ARGS_BUILT} --no-upload" ;;
    esac
  fi
fi

# gpu
if [ -n "${GB_GPU:-}" ]; then
  if grep -q -- '--gpu' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --gpu"
    if [ "$GB_GPU" != "1" ] && [ -n "$GB_GPU" ]; then
      GB_ARGS_BUILT="${GB_ARGS_BUILT} ${GB_GPU}"
    fi
  else
    log_warn "Geekbench: ignoring unsupported option --gpu"
  fi
fi
if [ "${GB_GPU_LIST:-}" = "1" ]; then
  if grep -q -- '--gpu-list' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --gpu-list"
  else
    log_warn "Geekbench: ignoring unsupported option --gpu-list"
  fi
fi
if [ -n "${GB_GPU_PLATFORM_ID:-}" ]; then
  if grep -q -- '--gpu-platform-id' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --gpu-platform-id ${GB_GPU_PLATFORM_ID}"
  else
    log_warn "Geekbench: ignoring unsupported option --gpu-platform-id"
  fi
fi
if [ -n "${GB_GPU_DEVICE_ID:-}" ]; then
  if grep -q -- '--gpu-device-id' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --gpu-device-id ${GB_GPU_DEVICE_ID}"
  else
    log_warn "Geekbench: ignoring unsupported option --gpu-device-id"
  fi
fi

# pro options
if [ -n "${GB_SECTION:-}" ]; then
  if grep -q -- '--section' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --section ${GB_SECTION}"
  else
    log_warn "Geekbench: ignoring unsupported option --section (unlock required)"
  fi
fi
if [ -n "${GB_WORKLOAD:-}" ]; then
  if grep -q -- '--workload' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --workload ${GB_WORKLOAD}"
  else
    log_warn "Geekbench: ignoring unsupported option --workload (unlock required)"
  fi
fi
if [ "${GB_WORKLOAD_LIST:-}" = "1" ]; then
  if grep -q -- '--workload-list' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --workload-list"
  else
    log_warn "Geekbench: ignoring unsupported option --workload-list (unlock required)"
  fi
fi
if [ "${GB_SINGLE_CORE:-}" = "1" ]; then
  if grep -q -- '--single-core' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --single-core"
  else
    log_warn "Geekbench: ignoring unsupported option --single-core (unlock required)"
  fi
fi
if [ "${GB_MULTI_CORE:-}" = "1" ]; then
  if grep -q -- '--multi-core' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --multi-core"
  else
    log_warn "Geekbench: ignoring unsupported option --multi-core (unlock required)"
  fi
fi
if [ -n "${GB_CPU_WORKERS:-}" ]; then
  if grep -q -- '--cpu-workers' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --cpu-workers ${GB_CPU_WORKERS}"
  else
    log_warn "Geekbench: ignoring unsupported option --cpu-workers (unlock required)"
  fi
fi
if [ -n "${GB_ITERATIONS:-}" ]; then
  if grep -q -- '--iterations' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --iterations ${GB_ITERATIONS}"
  else
    log_warn "Geekbench: ignoring unsupported option --iterations (unlock required)"
  fi
fi
if [ -n "${GB_WORKLOAD_GAP:-}" ]; then
  if grep -q -- '--workload-gap' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="${GB_ARGS_BUILT} --workload-gap ${GB_WORKLOAD_GAP}"
  else
    log_warn "Geekbench: ignoring unsupported option --workload-gap (unlock required)"
  fi
fi

# raw args
if [ -n "${GEEKBENCH_ARGS:-}" ]; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} ${GEEKBENCH_ARGS}"
fi
if [ -n "${FORWARD_ARGS:-}" ]; then
  GB_ARGS_BUILT="${GB_ARGS_BUILT} ${FORWARD_ARGS}"
fi

if [ -z "${GB_ARGS_BUILT# }" ]; then
  if grep -q -- '--no-upload' "$HELP_FILE" 2>/dev/null; then
    GB_ARGS_BUILT="--no-upload"
  else
    GB_ARGS_BUILT=""
  fi
fi

log_info "Geekbench args:"
log_info " Built : ${GB_ARGS_BUILT:-<none>}"

# -----------------------------------------------------------------------------
# CSV init
# -----------------------------------------------------------------------------
perf_geekbench_summary_csv_init "$SUMMARY_CSV"
perf_geekbench_workloads_csv_init "$WORKLOADS_CSV"

# -----------------------------------------------------------------------------
# Run loop
# -----------------------------------------------------------------------------
OK_PARSED=0
any_rc_fail=0

i=1
while [ "$i" -le "$RUNS" ]; do
  run_log="$OUTDIR/geekbench_iter${i}.log"
  subscores_txt="$OUTDIR/geekbench_iter${i}_subscores.txt"
  : >"$run_log" 2>/dev/null || true
  : >"$subscores_txt" 2>/dev/null || true

  ts=$(perf_nowstamp_safe)
  label="Geekbench run ${i}/${RUNS}"

  log_info "Geekbench run:"
  log_info " Run : ${i}/${RUNS}"
  log_info " Timestamp : $ts"
  log_info " Log : $run_log"

  set -- "$GB_REAL_BIN"
  for a in $GB_ARGS_BUILT; do
    set -- "$@" "$a"
  done

  if [ -n "${CORE_LIST:-}" ]; then
    perf_run_cmd_with_progress "$OUTDIR" "$run_log" "$PROGRESS_HEARTBEAT_SECS" "$label" -- \
      taskset -c "$CORE_LIST" "$@"
  else
    perf_run_cmd_with_progress "$OUTDIR" "$run_log" "$PROGRESS_HEARTBEAT_SECS" "$label" -- \
      "$@"
  fi

  rc=$?
  if [ "$rc" -ne 0 ]; then
    any_rc_fail=1
    log_warn "Geekbench run failed: iter, $i, rc, $rc"
  fi

  # workloads -> file + console (lib helper, no awk here)
  perf_geekbench_write_iter_subscores_txt "$run_log" "$subscores_txt" || true
  if [ -s "$subscores_txt" ]; then
    log_info "Geekbench sub-benchmarks:"
    log_info " File : $subscores_txt"
    perf_geekbench_log_subscores_file "$subscores_txt" || true
  else
    log_info "Geekbench sub-benchmarks: Not found (sysinfo/gpu-list/load is ok)"
  fi

  # summary parse
  if perf_geekbench_has_benchmark_summary "$run_log"; then
    scoreline=$(perf_parse_geekbench_summary_scores "$run_log")
    if [ -n "${scoreline:-}" ]; then
      # shellcheck disable=SC2046
      eval "$(perf_geekbench_scores_to_vars "$scoreline")"

      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$ts" "$TESTNAME" "$i" "${st:-}" "${si:-}" "${sf:-}" "${mt:-}" "${mi:-}" "${mf:-}" \
        >>"$SUMMARY_CSV" 2>/dev/null || true

      perf_append_geekbench_workloads_csv "$run_log" "$ts" "$TESTNAME" "$i" "$WORKLOADS_CSV"
      perf_geekbench_log_summary_scores "${st:-}" "${si:-}" "${sf:-}" "${mt:-}" "${mi:-}" "${mf:-}"

      parsed_any=0
      if [ -n "${st:-}" ] && perf_is_number_safe "$st"; then parsed_any=1; fi
      if [ -n "${mt:-}" ] && perf_is_number_safe "$mt"; then parsed_any=1; fi
      if [ "$parsed_any" -eq 1 ]; then OK_PARSED=1; fi
    else
      log_warn "Geekbench summary present but totals not parsed"
    fi
  else
    log_info "Geekbench summary: Not found (sysinfo/gpu-list/load is ok)"
  fi

  i=$((i + 1))
done

# -----------------------------------------------------------------------------
# Final summary (avg across parsed rows)
# -----------------------------------------------------------------------------
avg_st=$(awk -F',' 'NR>1 && $4 ~ /^[0-9]+$/ {n++; s+=$4} END{if(n>0) printf "%.0f", s/n}' "$SUMMARY_CSV" 2>/dev/null)
avg_si=$(awk -F',' 'NR>1 && $5 ~ /^[0-9]+$/ {n++; s+=$5} END{if(n>0) printf "%.0f", s/n}' "$SUMMARY_CSV" 2>/dev/null)
avg_sf=$(awk -F',' 'NR>1 && $6 ~ /^[0-9]+$/ {n++; s+=$6} END{if(n>0) printf "%.0f", s/n}' "$SUMMARY_CSV" 2>/dev/null)
avg_mt=$(awk -F',' 'NR>1 && $7 ~ /^[0-9]+$/ {n++; s+=$7} END{if(n>0) printf "%.0f", s/n}' "$SUMMARY_CSV" 2>/dev/null)
avg_mi=$(awk -F',' 'NR>1 && $8 ~ /^[0-9]+$/ {n++; s+=$8} END{if(n>0) printf "%.0f", s/n}' "$SUMMARY_CSV" 2>/dev/null)
avg_mf=$(awk -F',' 'NR>1 && $9 ~ /^[0-9]+$/ {n++; s+=$9} END{if(n>0) printf "%.0f", s/n}' "$SUMMARY_CSV" 2>/dev/null)

: >"$FINAL_SUMMARY_TXT" 2>/dev/null || true
perf_write_and_log "$FINAL_SUMMARY_TXT" "Geekbench Summary"
perf_write_and_log "$FINAL_SUMMARY_TXT" " timestamp, $(perf_nowstamp_safe)"
perf_write_and_log "$FINAL_SUMMARY_TXT" " outdir, $OUTDIR"
perf_write_and_log "$FINAL_SUMMARY_TXT" " runs, $RUNS"
perf_write_and_log "$FINAL_SUMMARY_TXT" " core_list, ${CORE_LIST:-none}"
perf_write_and_log "$FINAL_SUMMARY_TXT" " bin, $GB_REAL_BIN"
perf_write_and_log "$FINAL_SUMMARY_TXT" " args, ${GB_ARGS_BUILT:-<none>}"
perf_write_and_log "$FINAL_SUMMARY_TXT" ""
perf_write_and_log "$FINAL_SUMMARY_TXT" "CSV outputs"
perf_write_and_log "$FINAL_SUMMARY_TXT" " summary_csv, $SUMMARY_CSV"
perf_write_and_log "$FINAL_SUMMARY_TXT" " workloads_csv, $WORKLOADS_CSV"
perf_write_and_log "$FINAL_SUMMARY_TXT" ""

if [ -n "${avg_st:-}" ] || [ -n "${avg_mt:-}" ]; then
  perf_write_and_log "$FINAL_SUMMARY_TXT" "Benchmark Summary, average over parsed runs"
  [ -n "${avg_st:-}" ] && perf_write_and_log "$FINAL_SUMMARY_TXT" " Single-Core Score, $avg_st"
  [ -n "${avg_si:-}" ] && perf_write_and_log "$FINAL_SUMMARY_TXT" " Single-Core Integer Score, $avg_si"
  [ -n "${avg_sf:-}" ] && perf_write_and_log "$FINAL_SUMMARY_TXT" " Single-Core Floating Point Score, $avg_sf"
  [ -n "${avg_mt:-}" ] && perf_write_and_log "$FINAL_SUMMARY_TXT" " Multi-Core Score, $avg_mt"
  [ -n "${avg_mi:-}" ] && perf_write_and_log "$FINAL_SUMMARY_TXT" " Multi-Core Integer Score, $avg_mi"
  [ -n "${avg_mf:-}" ] && perf_write_and_log "$FINAL_SUMMARY_TXT" " Multi-Core Floating Point Score, $avg_mf"
else
  perf_write_and_log "$FINAL_SUMMARY_TXT" "Benchmark Summary, not available, no parsed Benchmark Summary across runs"
  perf_write_and_log "$FINAL_SUMMARY_TXT" "This is expected for sysinfo, gpu-list, load"
fi

# -----------------------------------------------------------------------------
# PASS/FAIL
# -----------------------------------------------------------------------------
status="FAIL"
if [ "$OK_PARSED" -eq 1 ]; then
  status="PASS"
else
  if [ "$any_rc_fail" -eq 0 ]; then
    status="PASS"
  fi
fi

if [ "$status" = "PASS" ]; then
  log_pass "$TESTNAME PASS"
  echo "$TESTNAME PASS" >"$RES_FILE" 2>/dev/null || true
else
  log_fail "$TESTNAME FAIL, see logs in, $OUTDIR"
  echo "$TESTNAME FAIL" >"$RES_FILE" 2>/dev/null || true
fi

exit 0
