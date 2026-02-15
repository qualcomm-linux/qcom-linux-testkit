#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Probe failure / deferred probe detector using kernel logs + devices_deferred

# ---------- Repo env + helpers ----------
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

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
  # shellcheck disable=SC1090
  . "$INIT_ENV"
  __INIT_ENV_LOADED=1
fi

# Keep combined suppression for consistency across repo
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Probe_Failure_Check"
RESULT_FILE="$TESTNAME.res"
LOG_FILE="probe_failures.log"

# Move into testcase directory (so .res and logs land in the right place)
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "----------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"

rm -f "$RESULT_FILE" "$LOG_FILE"
: >"$LOG_FILE"

# --- Get kernel log snapshot ---
if command -v get_kernel_log >/dev/null 2>&1; then
  KERNEL_LOG="$(get_kernel_log 2>/dev/null)"
else
  log_warn "'get_kernel_log' not found, falling back to 'dmesg -T'"
  KERNEL_LOG="$(dmesg -T 2>/dev/null)"
fi

# --- SKIP when unable to collect kernel logs ---
if [ -z "$KERNEL_LOG" ]; then
  if command -v log_skip >/dev/null 2>&1; then
    log_skip "$TESTNAME : Unable to collect kernel logs, skipping probe failure check"
  else
    log_warn "$TESTNAME : Unable to collect kernel logs, treating as SKIP"
  fi
  echo "$TESTNAME SKIP" >"$RESULT_FILE"
  rm -f "$LOG_FILE"
  exit 0
fi

# --- Probe / firmware / bind failure patterns ---
# Intentionally broad but targeted at realistic driver init / teardown problems.
# Built as a concatenation of single-quoted segments to avoid stray backslashes.
FAIL_PATTERN='(failed to (probe|instantiate)|'\
'probe of .* failed|probe with driver .* failed|deferred probe timeout, ignoring dependency|'\
'Direct firmware load .* failed|tplg firmware loading .* failed|ASoC error|'\
'unprobe failed|failed to remove .* driver|component bind error|component unbind error|'\
'Driver .* failed|cannot register device driver|register_component error|'\
'sound: ASoC: failed|load_firmware failed|request_firmware failed|device_add failed|'\
'platform device_add failed|Cannot register component|bind failed|'\
'lookup_component error|failed to add machine driver)'

# Pull out matched lines
MATCHES=$(printf '%s\n' "$KERNEL_LOG" | grep -Ei "$FAIL_PATTERN" || true)

# --- Optional: report devices still in deferred-probe list (debugfs) ---
DEFERRED_FILE="/sys/kernel/debug/devices_deferred"
if [ -r "$DEFERRED_FILE" ]; then
  DEFERRED_CONTENT=$(cat "$DEFERRED_FILE" 2>/dev/null || true)
  if [ -n "$DEFERRED_CONTENT" ]; then
    log_warn "Devices still listed in $DEFERRED_FILE (deferred probe not resolved):"
    printf '%s\n' "$DEFERRED_CONTENT" >>"$LOG_FILE"
    printf '%s\n' "$DEFERRED_CONTENT" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      log_warn "DEFERRED: $line"
    done
  else
    log_info "No entries in $DEFERRED_FILE (no outstanding deferred probes)."
  fi
else
  log_info "$DEFERRED_FILE not available (no deferred-probe debugfs support)."
fi

# --- Evaluate matches and report to CI ---
if [ -n "$MATCHES" ]; then
  # Save full match set to log file for post-mortem
  printf '%s\n' "$MATCHES" >>"$LOG_FILE"

  MATCH_COUNT=$(printf '%s\n' "$MATCHES" | wc -l | awk '{print $1}')
  # Extract the latest leading [timestamp] if present, e.g. "[ 10.471969]"
  LATEST_TS=$(
    printf '%s\n' "$MATCHES" \
      | sed -n 's/^\(\[[^]]*]\).*/\1/p' \
      | tail -n 1
  )

  log_fail "$TESTNAME : Kernel probe/unprobe/firmware-related errors found (see $LOG_FILE)"
  log_info "Total matched lines: $MATCH_COUNT"
  if [ -n "$LATEST_TS" ]; then
    log_info "Latest timestamp among matches: $LATEST_TS"
  else
    log_info "Latest timestamp among matches: Not Available"
  fi

  # Print a few representative lines to stdout for CI log visibility
  printf '%s\n' "$MATCHES" | head -n 10 | while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "CI-HINT: $line"
  done

  # Dump entire LOG_FILE for easy inspection in LAVA logs
  if [ -s "$LOG_FILE" ]; then
    echo "================ $LOG_FILE (full contents) ================"
    cat "$LOG_FILE"
    echo "================ end of $LOG_FILE ========================="
  fi

  echo "$TESTNAME FAIL" >"$RESULT_FILE"
  # Convention: exit 0, result is driven by .res file
  exit 0
fi

log_pass "$TESTNAME : No probe/firmware/bind errors found in kernel log snapshot"
echo "$TESTNAME PASS" >"$RESULT_FILE"
rm -f "$LOG_FILE"
exit 0
