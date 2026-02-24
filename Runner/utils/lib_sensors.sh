#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Sensor helpers (DT-free): discovery via ssc_sensor_info, run see_workhorse/ssc_drva_test, parse PASS/FAIL.

# Global outputs set by sensors_check_adsp_remoteproc()
SENSORS_ADSP_FW=""
SENSORS_ADSP_RPROC_PATH=""
SENSORS_ADSP_STATE=""

sensors__trim_ws() {
  # usage: sensors__trim_ws " abc " -> prints "abc"
  # shellcheck disable=SC2001
  echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Append a line to a newline-separated list if it doesn't already exist.
# usage: new_list="$(sensors_append_unique_line "$list" "accel")"
sensors_append_unique_line() {
  list="$1"
  line="$2"

  [ -z "$line" ] && { printf '%s\n' "$list"; return 0; }

  if [ -z "$list" ]; then
    printf '%s\n' "$line"
    return 0
  fi

  printf '%s\n' "$list" | grep -Fxq "$line" 2>/dev/null && {
    printf '%s\n' "$list"
    return 0
  }

  printf '%s\n%s\n' "$list" "$line"
}

sensors__firmware_exists_quick() {
  fw="$1"
  [ -z "$fw" ] && return 1
  # quick/cheap checks only (avoid heavy find):
  [ -f "/lib/firmware/$fw" ] && return 0
  [ -f "/lib/firmware/qcom/$fw" ] && return 0
  [ -f "/lib/firmware/qcom/qcs6490/$fw" ] && return 0
  [ -f "/vendor/firmware/$fw" ] && return 0
  [ -f "/vendor/firmware_mnt/image/$fw" ] && return 0
  return 1
}

# Return codes:
# 0 = running
# 1 = remoteproc found but not running
# 2 = remoteproc not running and firmware missing
# 3 = remoteproc not found (by firmware mapping)
sensors_check_adsp_remoteproc() {
  fw="${1:-adsp.mbn}"

  # NOTE: these are intentionally "output variables" for the caller (run.sh)
  # shellcheck disable=SC2034
  SENSORS_ADSP_FW="$fw"
  # shellcheck disable=SC2034
  SENSORS_ADSP_RPROC_PATH=""
  SENSORS_ADSP_STATE=""

  if ! command -v get_remoteproc_path_by_firmware >/dev/null 2>&1; then
    return 3
  fi

  rpath="$(get_remoteproc_path_by_firmware "$fw" 2>/dev/null || true)"
  if [ -z "$rpath" ] || [ ! -d "$rpath" ]; then
    return 3
  fi

  # shellcheck disable=SC2034
  SENSORS_ADSP_RPROC_PATH="$rpath"

  if command -v get_remoteproc_state >/dev/null 2>&1; then
    SENSORS_ADSP_STATE="$(get_remoteproc_state "$rpath" 2>/dev/null || true)"
    SENSORS_ADSP_STATE="$(sensors__trim_ws "$SENSORS_ADSP_STATE")"
  else
    if [ -r "$rpath/state" ]; then
      SENSORS_ADSP_STATE="$(cat "$rpath/state" 2>/dev/null || true)"
      SENSORS_ADSP_STATE="$(sensors__trim_ws "$SENSORS_ADSP_STATE")"
    fi
  fi

  [ "$SENSORS_ADSP_STATE" = "running" ] && return 0

  if sensors__firmware_exists_quick "$fw"; then
    return 1
  fi
  return 2
}

sensors_dump_ssc_sensor_info() {
  out_file="$1"
  : >"$out_file" 2>/dev/null || true
  ssc_sensor_info >"$out_file" 2>&1
  return $?
}

sensors_types_from_ssc_file() {
  f="$1"
  [ -r "$f" ] || return 1

  awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    /^TYPE[[:space:]]*=/ {
      type = $0
      sub(/^TYPE[[:space:]]*=[[:space:]]*/, "", type)
      type = trim(type)
    }
    /^AVAILABLE[[:space:]]*=/ {
      avail = $0
      sub(/^AVAILABLE[[:space:]]*=[[:space:]]*/, "", avail)
      avail = trim(avail)
    }
    /^PHYSICAL_SENSOR[[:space:]]*=/ {
      phys = $0
      sub(/^PHYSICAL_SENSOR[[:space:]]*=[[:space:]]*/, "", phys)
      phys = trim(phys)
    }
    /^$/ {
      if (type != "" && avail == "true") {
        if (phys == "" || phys == "true") print type
      }
      type=""; avail=""; phys=""
    }
    END {
      if (type != "" && avail == "true") {
        if (phys == "" || phys == "true") print type
      }
    }
  ' "$f" 2>/dev/null | sort -u
}

sensors_type_present() {
  types_nl="$1"
  needle="$2"
  printf '%s\n' "$types_nl" | grep -Fxq "$needle" 2>/dev/null
}

# Run a command in background, redirect all output to logfile, and print a heartbeat.
# sensors_run_cmd_with_progress <logfile> <label> <duration_sec> <heartbeat_sec> -- <cmd...>
sensors_run_cmd_with_progress() {
  logf="$1"
  label="$2"
  dur="$3"
  hb="$4"
  shift 4

  [ "${1:-}" = "--" ] || return 2
  shift

  : >"$logf" 2>/dev/null || true

  "$@" >"$logf" 2>&1 &
  pid=$!

  elapsed=0
  pad="${SENSORS_TIMEOUT_PAD_SECS:-15}"
  case "$dur" in ""|*[!0-9]*) dur=10 ;; esac
  case "$hb" in ""|*[!0-9]*) hb=5 ;; esac
  timeout=$((dur + pad))

  log_info "$label started (log: $logf)"

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout" ]; then
      log_error "$label TIMEOUT after ${elapsed}s (killing pid $pid). Log: $logf"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      break
    fi

    # Sleep in small steps so we don't oversleep after the cmd already finished
    step=1
    while [ "$step" -le "$hb" ]; do
      sleep 1 2>/dev/null || true
      kill -0 "$pid" 2>/dev/null || break
      step=$((step + 1))
    done

    kill -0 "$pid" 2>/dev/null || break
    elapsed=$((elapsed + hb))
    log_info "$label running... ${elapsed}/${dur}s (log: $logf)"
  done

  wait "$pid" 2>/dev/null
  return $?
}

sensors_see_workhorse_passed() {
  logf="$1"
  [ -r "$logf" ] || return 1
 
  # Decide verdict by the *last* PASS/FAIL marker in the log.
  # This handles duplicate PASS lines and any earlier noise.
  last="$(grep -E '^(PASS|FAIL)[[:space:]]+see_workhorse' "$logf" 2>/dev/null | tail -n 1 | awk '{print $1}')"
 
  if [ "$last" = "PASS" ]; then
    return 0
  fi
  if [ "$last" = "FAIL" ]; then
    return 1
  fi
 
  # Fallback if no explicit markers found:
  # consider non-empty log as "likely ran", but you can make this stricter if needed.
  [ -s "$logf" ] && return 0
  return 1
}

sensors_run_see_workhorse() {
  sensor="$1"
  duration="$2"
  outdir="$3"
  hb="${4:-5}"
  disp="${SENSORS_DISPLAY_EVENTS:-1}"

  logf="$outdir/see_workhorse_${sensor}.log"
  label="see_workhorse(${sensor})"

  sensors_run_cmd_with_progress "$logf" "$label" "$duration" "$hb" -- \
    see_workhorse -sensor="$sensor" -sample_rate=max -duration="$duration" -display_events="$disp"

  sensors_see_workhorse_passed "$logf"
  return $?
}

sensors_run_ssc_drva_test() {
  sensor="$1"
  duration="$2"
  outdir="$3"
  hb="${4:-5}"

  command -v ssc_drva_test >/dev/null 2>&1 || return 2

  logf="$outdir/ssc_drva_test_${sensor}.log"
  label="ssc_drva_test(${sensor})"

  set -- ssc_drva_test -sensor="$sensor" -duration="$duration" -sample_rate=-1
  if [ "$sensor" = "accel" ] && [ -n "${SENSORS_DRVA_NUM_SAMPLES:-}" ]; then
    set -- "$@" -num_samples="${SENSORS_DRVA_NUM_SAMPLES}"
  fi

  sensors_run_cmd_with_progress "$logf" "$label" "$duration" "$hb" -- "$@"
  rc=$?

  grep -q '^FAIL' "$logf" 2>/dev/null && return 1
  [ "$rc" -eq 0 ] && return 0
  return 1
}
