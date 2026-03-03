#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Boot KPI multi-boot aggregator / auto-reboot wrapper around Boot_Systemd_Validate.

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Boot_Systemd_KPI_Loop"
RES_FILE="./${TESTNAME}.res"

# Default KPI script + base out dir (for iteration subfolders)
KPI_SCRIPT_DEFAULT="$SCRIPT_DIR/../Boot_Systemd_Validate/run.sh"
KPI_OUT_DIR_DEFAULT="$SCRIPT_DIR/../Boot_Systemd_Validate/logs_Boot_Systemd_Validate"

# Defaults (env may override; CLI parsing later overrides again)
KPI_SCRIPT="${KPI_SCRIPT:-$KPI_SCRIPT_DEFAULT}"
KPI_OUT_DIR="${KPI_OUT_DIR:-$KPI_OUT_DIR_DEFAULT}"
ITERATIONS="${ITERATIONS:-1}"
BOOT_TYPE="${BOOT_TYPE:-unknown}"

DISABLE_GETTY="${DISABLE_GETTY:-0}"
DISABLE_SSHD="${DISABLE_SSHD:-0}"
EXCLUDE_NETWORKD_WAIT_ONLINE="${EXCLUDE_NETWORKD_WAIT_ONLINE:-0}"
EXCLUDE_SERVICES="${EXCLUDE_SERVICES:-}"
NO_SVG="${NO_SVG:-0}"
AUTO_REBOOT="${AUTO_REBOOT:-0}"
VERBOSE="${VERBOSE:-0}"

STATE_FILE="$SCRIPT_DIR/Boot_Systemd_KPI_Loop.state"
KPI_REBOOT_STATE_FILE="$SCRIPT_DIR/Boot_Systemd_KPI_reboot.state"
SERVICE_NAME="${SERVICE_NAME:-boot-systemd-kpi-loop}"
STATS_CSV="$SCRIPT_DIR/Boot_Systemd_KPI_stats.csv"
SUMMARY_FILE="$SCRIPT_DIR/Boot_Systemd_KPI_summary.txt"

# Optional: allow caller to choose whether to treat reboot as PASS/SKIP in LAVA
# (default PASS so LAVA won't fail the run during reboot)
REBOOT_RESULT_MODE="${REBOOT_RESULT_MODE:-PASS}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

This wrapper:
  * Runs Boot_Systemd_Validate once for the *current boot*
  * Uses a per-iteration KPI out dir when --iterations > 1:
      base: $KPI_OUT_DIR_DEFAULT
      iter: <base>/iter_<N>
  * Parses boot_kpi_this_run.txt from that test
  * Appends a row into ${STATS_CSV##*/}
  * Computes averages over the last N boots (per boot_type) and prints summary.

Options:
  --kpi-script PATH Override Boot_Systemd_Validate script path
                                 (default: $KPI_SCRIPT_DEFAULT)
  --kpi-out-dir DIR Override base KPI output dir
                                 (default: $KPI_OUT_DIR_DEFAULT)
  --iterations N Number of boots to average over (default: 1)
  --boot-type TYPE Tag for this run (e.g. cold, warm, unknown)

  # Options forwarded to Boot_Systemd_Validate:
  --disable-getty Disable serial-getty@ttyS0.service
  --disable-sshd Disable sshd.service
  --exclude-networkd-wait-online Exclude systemd-networkd-wait-online.service
  --exclude-services "A B" Exclude these services from userspace/total
  --no-svg Disable SVG plot generation
  --verbose Print KPI .txt artifacts to console for debug

  # Auto-reboot orchestration:
  --auto-reboot Install systemd hook and auto-reboot until
                                 --iterations boots are collected. State is
                                 stored in: $STATE_FILE

  -h, --help Show this help and exit

Example (single run, average over last 5 boots of this type):
  ./run.sh --iterations 5 --boot-type cold --disable-getty --exclude-networkd-wait-online

Auto-reboot mode (script installs systemd hook + reboots until N boots done):
  ./run.sh --iterations 5 --boot-type cold --disable-getty \\
           --exclude-networkd-wait-online --auto-reboot
EOF
}

write_skip_and_exit0() {
  # Best-effort: logs may not be available before functestlib, so keep it simple.
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
}

# EARLY help handling: do this BEFORE init_env/functestlib stdout capture
case "${1:-}" in
  -h|--help)
    usage >&2
    exit 0
    ;;
esac

# --- locate and source init_env → functestlib.sh + lib_performance.sh ---
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

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
  # shellcheck disable=SC1090
  . "$INIT_ENV"
  __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_performance.sh"

# --- CLI parsing ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kpi-script)
      if [ "$#" -lt 2 ]; then
        log_error "--kpi-script requires a PATH argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--kpi-script requires a PATH argument"
        usage >&2
        write_skip_and_exit0
      fi
      KPI_SCRIPT=$1
      ;;
    --kpi-out-dir)
      if [ "$#" -lt 2 ]; then
        log_error "--kpi-out-dir requires a DIR argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--kpi-out-dir requires a DIR argument"
        usage >&2
        write_skip_and_exit0
      fi
      KPI_OUT_DIR=$1
      ;;
    --iterations)
      if [ "$#" -lt 2 ]; then
        log_error "--iterations requires a numeric argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--iterations requires a numeric argument"
        usage >&2
        write_skip_and_exit0
      fi
      ITERATIONS=$1
      ;;
    --boot-type)
      if [ "$#" -lt 2 ]; then
        log_error "--boot-type requires a TYPE argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--boot-type requires a TYPE argument"
        usage >&2
        write_skip_and_exit0
      fi
      BOOT_TYPE=$1
      ;;
    --disable-getty)
      DISABLE_GETTY=1
      ;;
    --disable-sshd)
      DISABLE_SSHD=1
      ;;
    --exclude-networkd-wait-online)
      EXCLUDE_NETWORKD_WAIT_ONLINE=1
      ;;
    --exclude-services)
      if [ "$#" -lt 2 ]; then
        log_error "--exclude-services requires a quoted service list argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--exclude-services requires a quoted service list argument"
        usage >&2
        write_skip_and_exit0
      fi
      EXCLUDE_SERVICES=$1
      ;;
    --no-svg)
      NO_SVG=1
      ;;
    --auto-reboot)
      AUTO_REBOOT=1
      ;;
    --verbose)
      VERBOSE=1
      ;;
    -h|--help)
      usage >&2
      exit 0
      ;;
    *)
      log_warn "Unknown option: $1"
      usage >&2
      write_skip_and_exit0
      ;;
  esac
  shift
done

# Validate iterations
case "$ITERATIONS" in
  ''|*[!0-9]*)
    log_warn "Non-numeric --iterations; defaulting to 1"
    ITERATIONS=1
    ;;
esac
if [ "$ITERATIONS" -lt 1 ] 2>/dev/null; then
  ITERATIONS=1
fi

# NEW: auto-enable auto-reboot mode when state exists
if [ "$AUTO_REBOOT" -eq 0 ] && [ -f "$STATE_FILE" ]; then
  AUTO_REBOOT=1
fi

# If we are in auto-reboot mode, first verify whether a previous reboot actually happened.
if [ "$AUTO_REBOOT" -eq 1 ]; then
  perf_kpi_check_previous_reboot "$KPI_REBOOT_STATE_FILE"
fi

# Always log current boot identity for debugging / LAVA traces
perf_kpi_get_boot_identity
log_info "$TESTNAME: boot identity → boot_id=${PERF_KPI_BOOT_ID:-unknown} uptime=${PERF_KPI_UPTIME_SEC:-unknown}s"

# Validate KPI script exists (do not require executable bit; run via sh if needed)
if [ ! -f "$KPI_SCRIPT" ]; then
  log_error "KPI script missing: $KPI_SCRIPT"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
if [ ! -r "$KPI_SCRIPT" ]; then
  log_error "KPI script not readable: $KPI_SCRIPT"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# Create KPI base dir (review: if mkdir fails → exit 0)
if ! mkdir -p "$KPI_OUT_DIR" 2>/dev/null; then
  log_warn "$TESTNAME: failed to create KPI base out dir: $KPI_OUT_DIR"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

CURRENT_DONE=0

# --- Auto-reboot: load or initialise state ---
if [ "$AUTO_REBOOT" -eq 1 ]; then
  if perf_kpi_load_loop_state "$STATE_FILE"; then
    # Reuse knobs from state
    if [ -n "${KPI_LOOP_ITERATIONS_TOTAL:-}" ]; then
      ITERATIONS=$KPI_LOOP_ITERATIONS_TOTAL
    fi
    if [ -n "${KPI_LOOP_BOOT_TYPE:-}" ]; then
      BOOT_TYPE=$KPI_LOOP_BOOT_TYPE
    fi
    if [ -n "${KPI_LOOP_KPI_SCRIPT:-}" ]; then
      KPI_SCRIPT=$KPI_LOOP_KPI_SCRIPT
    fi
    if [ -n "${KPI_LOOP_KPI_OUT_DIR:-}" ]; then
      KPI_OUT_DIR=$KPI_LOOP_KPI_OUT_DIR
    fi
    DISABLE_GETTY=${KPI_LOOP_DISABLE_GETTY:-0}
    DISABLE_SSHD=${KPI_LOOP_DISABLE_SSHD:-0}
    EXCLUDE_NETWORKD_WAIT_ONLINE=${KPI_LOOP_EXCLUDE_NETWORKD:-0}
    EXCLUDE_SERVICES=${KPI_LOOP_EXCLUDE_SERVICES:-}
    CURRENT_DONE=${KPI_LOOP_ITERATIONS_DONE:-0}
  else
    # First time in auto-reboot mode
    CURRENT_DONE=0
    perf_kpi_write_loop_state "$STATE_FILE" "$ITERATIONS" "$CURRENT_DONE" \
      "$BOOT_TYPE" "$DISABLE_GETTY" "$DISABLE_SSHD" \
      "$EXCLUDE_NETWORKD_WAIT_ONLINE" "$EXCLUDE_SERVICES" \
      "$KPI_SCRIPT" "$KPI_OUT_DIR"
    perf_install_kpi_systemd_hook "$SCRIPT_DIR/run.sh" "$SERVICE_NAME"
  fi
fi

log_info "$TESTNAME: starting KPI aggregation (boot_type=$BOOT_TYPE, iterations_window=$ITERATIONS, auto_reboot=$AUTO_REBOOT, verbose=$VERBOSE)"
log_info "$TESTNAME: KPI script → $KPI_SCRIPT"
log_info "$TESTNAME: KPI base out dir → $KPI_OUT_DIR"
log_info "$TESTNAME: iterations already done (from state) = $CURRENT_DONE"

# --- Determine this iteration index and concrete out-dir ---
THIS_ITER=1
if [ "$AUTO_REBOOT" -eq 1 ]; then
  THIS_ITER=$((CURRENT_DONE + 1))
fi

RUN_OUT_DIR="$KPI_OUT_DIR"
if [ "$ITERATIONS" -gt 1 ] 2>/dev/null; then
  RUN_OUT_DIR="$KPI_OUT_DIR/iter_${THIS_ITER}"
fi

# review: mkdir failure should exit 0
if ! mkdir -p "$RUN_OUT_DIR" 2>/dev/null; then
  log_warn "$TESTNAME: failed to create run out dir: $RUN_OUT_DIR"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "$TESTNAME: this iteration=$THIS_ITER, KPI out dir for this run → $RUN_OUT_DIR"

# --- Build argv for Boot_Systemd_Validate safely ---
# We call via 'sh' if not executable.
KPI_INVOKE="$KPI_SCRIPT"
if [ ! -x "$KPI_SCRIPT" ]; then
  KPI_INVOKE="sh"
fi

set -- --out "$RUN_OUT_DIR" --boot-type "$BOOT_TYPE" --iterations "$ITERATIONS"

if [ "$DISABLE_GETTY" -eq 1 ]; then
  set -- "$@" --disable-getty
fi
if [ "$DISABLE_SSHD" -eq 1 ]; then
  set -- "$@" --disable-sshd
fi
if [ "$EXCLUDE_NETWORKD_WAIT_ONLINE" -eq 1 ]; then
  set -- "$@" --exclude-networkd-wait-online
fi
if [ -n "$EXCLUDE_SERVICES" ]; then
  set -- "$@" --exclude-services "$EXCLUDE_SERVICES"
fi
if [ "$NO_SVG" -eq 1 ]; then
  set -- "$@" --no-svg
fi
if [ "$VERBOSE" -eq 1 ]; then
  set -- "$@" --verbose
fi

# --- Invoke Boot_Systemd_Validate for this boot ---
if [ "$KPI_INVOKE" = "sh" ]; then
  log_info "$TESTNAME: invoking KPI script: sh \"$KPI_SCRIPT\" $*"
  sh "$KPI_SCRIPT" "$@"
else
  log_info "$TESTNAME: invoking KPI script: \"$KPI_SCRIPT\" $*"
  "$KPI_SCRIPT" "$@"
fi
rc=$?

if [ "$rc" -ne 0 ]; then
  log_fail "$TESTNAME: KPI script failed with rc=$rc"
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit "$rc"
fi

# --- Parse this-run KPI file from this iteration OUT dir ---
KPI_FILE="$RUN_OUT_DIR/boot_kpi_this_run.txt"
if [ ! -f "$KPI_FILE" ]; then
  log_fail "$TESTNAME: KPI file not found for this iteration: $KPI_FILE"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

perf_kpi_extract_from_file "$KPI_FILE"

# If Boot_Systemd_Validate wrote empty boot_type, fall back to CLI boot_type
if [ -z "${PERF_KPI_BOOT_TYPE:-}" ]; then
  PERF_KPI_BOOT_TYPE="$BOOT_TYPE"
fi

log_info "$TESTNAME: parsed KPI for this boot (iter=$THIS_ITER, boot_type=$PERF_KPI_BOOT_TYPE, total_sec=${PERF_KPI_BOOT_TOTAL_SEC:-unknown}, total_eff_sec=${PERF_KPI_BOOT_TOTAL_EFFECTIVE_SEC:-unknown})"

if [ "$VERBOSE" -eq 1 ]; then
  echo "================ boot_kpi_this_run.txt (from $KPI_FILE) ================"
  cat "$KPI_FILE"
  echo "======================================================================="
fi

# --- Append CSV row (global stats CSV under Boot_Systemd_KPI_Loop) ---
perf_kpi_append_csv_row "$STATS_CSV" "$PERF_KPI_BOOT_TYPE"

# --- Compute averages over last N boots for this boot_type ---
if perf_kpi_compute_average "$STATS_CSV" "$PERF_KPI_BOOT_TYPE" "$ITERATIONS" "$SUMMARY_FILE"; then
  if [ -f "$SUMMARY_FILE" ]; then
    echo "================ KPI AVERAGE SUMMARY ================"
    cat "$SUMMARY_FILE"
    echo "====================================================="
  fi
else
  log_warn "$TESTNAME: could not compute KPI averages (maybe not enough entries yet)."
fi

if [ "$VERBOSE" -eq 1 ]; then
  if [ -f "$STATS_CSV" ]; then
    echo "================ Last KPI CSV rows ($STATS_CSV) ======================="
    tail -n 5 "$STATS_CSV" 2>/dev/null || cat "$STATS_CSV"
    echo "======================================================================="
  fi
fi

# --- Auto-reboot decision & cleanup ---
if [ "$AUTO_REBOOT" -eq 1 ]; then
  NEW_DONE=$((CURRENT_DONE + 1))
  perf_kpi_write_loop_state "$STATE_FILE" "$ITERATIONS" "$NEW_DONE" \
    "$BOOT_TYPE" "$DISABLE_GETTY" "$DISABLE_SSHD" \
    "$EXCLUDE_NETWORKD_WAIT_ONLINE" "$EXCLUDE_SERVICES" \
    "$KPI_SCRIPT" "$KPI_OUT_DIR"

  if [ "$NEW_DONE" -lt "$ITERATIONS" ]; then
    # Prepare reboot tracking state so next boot can verify it succeeded
    perf_kpi_get_boot_identity
    perf_kpi_reboot_state_save \
      "$KPI_REBOOT_STATE_FILE" \
      "$PERF_KPI_BOOT_ID" \
      "${PERF_KPI_UPTIME_SEC:-}" \
      "1" \
      "$NEW_DONE"

    log_info "$TESTNAME: completed iteration $NEW_DONE/$ITERATIONS; requesting reboot for next KPI iteration."
    log_info "$TESTNAME: current boot_id=$PERF_KPI_BOOT_ID uptime=${PERF_KPI_UPTIME_SEC:-unknown}s"

    perf_kpi_request_reboot "Boot_Systemd_KPI_Loop auto-reboot for next KPI iteration"

    # If we are still alive here, reboot did not occur immediately; exit and let systemd/LAVA retry.
    if [ "$REBOOT_RESULT_MODE" = "SKIP" ]; then
      log_skip "$TESTNAME: reboot requested for next iteration ($NEW_DONE/$ITERATIONS)"
      echo "$TESTNAME SKIP" >"$RES_FILE"
    else
      echo "$TESTNAME PASS" >"$RES_FILE"
    fi
    exit 0
  else
    log_info "$TESTNAME: all iterations completed ($NEW_DONE/$ITERATIONS); cleaning up auto-reboot hook."
    perf_remove_kpi_systemd_hook "$SERVICE_NAME"
    rm -f "$STATE_FILE" "$KPI_REBOOT_STATE_FILE" 2>/dev/null || true
  fi
fi

log_pass "$TESTNAME: PASS"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
