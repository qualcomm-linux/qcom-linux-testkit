#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Dynamic Sensors validation (DT-free): discover via ssc_sensor_info and validate selected sensor types.

TESTNAME="Sensors"

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

# shellcheck disable=SC2034
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"

usage() {
  cat <<EOF
Usage: $0 [options]

Package handling:
  --overlay Install the Qualcomm Sensors runtime/test package set from
            qli-staging on Debian, Ubuntu, or CentOS.
            No package removal or base-mode transition is performed.

Discovery:
  --list List discovered sensor TYPEs (from ssc_sensor_info) and exit 0
  --sensors <csv> Comma-separated list of sensor TYPEs to test
                           Example: --sensors accel,gyro,mag
  --profile <name> Choose a preset list:
                             basic : accel,gyro
                             core : accel,gyro
                             vision: accel,gyro,mag,pressure
                             all : all discovered types (debug)
                           Default: auto (all discovered testable data sensors)

Durations / progress:
  --out <dir> Output directory (default: ./logs_Sensors)
  --see-duration <sec> see_workhorse duration (default: 5)
  --drva-duration <sec> ssc_drva_test duration (default: 10)
  --hb <sec> Heartbeat seconds (default: 5)
  --strict <0|1> Fail when an explicitly selected or named-profile sensor is
                absent (default: 1). Auto mode uses present sensors only.

Other:
  --help Show this help

Examples:
  $0 --overlay --list
  $0 --overlay --profile basic
  $0 --profile vision
  $0 --sensors accel,gyro,tilt --strict 0
  $0 --profile all --strict 0

Environment overrides:
  OUT_DIR, SEE_DURATION, DRVA_DURATION, HB_SECS, STRICT_REQUIRED,
  SENSORS_TIMEOUT_PAD_SECS, SENSORS_DISPLAY_EVENTS, SENSORS_DRVA_NUM_SAMPLES,
  SENSORS_SERVICE
EOF
}

SENSORS_CSV=""
PROFILE="auto"
LIST_ONLY=0
OVERLAY_REQUESTED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --overlay) OVERLAY_REQUESTED=1; shift 1 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --see-duration) SEE_DURATION="$2"; shift 2 ;;
    --drva-duration) DRVA_DURATION="$2"; shift 2 ;;
    --hb) HB_SECS="$2"; shift 2 ;;
    --strict) STRICT_REQUIRED="$2"; shift 2 ;;
    --sensors) SENSORS_CSV="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --list) LIST_ONLY=1; shift 1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[WARN] Unknown arg: $1" >&2; shift 1 ;;
  esac
done

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
  echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
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
. "$TOOLS/lib_sensors.sh"

if [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$TOOLS/lib_pkg_provider.sh"
fi

# Resolve test path and cd (single SKIP/exit path)
SKIP_REASON=""
test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
  SKIP_REASON="$TESTNAME SKIP - test path not found"
elif ! cd "$test_path"; then
  SKIP_REASON="$TESTNAME SKIP - cannot cd into $test_path"
else
  RES_FILE="$test_path/${TESTNAME}.res"
fi

if [ -n "$SKIP_REASON" ]; then
  log_skip "$SKIP_REASON"
  echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
  exit 0
fi

OUT_DIR="${OUT_DIR:-./logs_Sensors}"
SEE_DURATION="${SEE_DURATION:-5}"
DRVA_DURATION="${DRVA_DURATION:-10}"
HB_SECS="${HB_SECS:-5}"
STRICT_REQUIRED="${STRICT_REQUIRED:-1}"
SENSORS_SERVICE="${SENSORS_SERVICE:-sscrpcd.service}"
: "${SENSORS_DRVA_NUM_SAMPLES:=325}"

mkdir -p "$OUT_DIR" 2>/dev/null || true

OS_ID="unknown"
DISTRO_SENSORS_HANDLING_SUPPORTED=0

if command -v pkg_detect_os_id >/dev/null 2>&1; then
  OS_ID="$(pkg_detect_os_id 2>/dev/null || true)"
elif [ -r /etc/os-release ]; then
  OS_ID="$(
    sed -n 's/^ID=//p' /etc/os-release |
      head -n 1 |
      tr -d '"' |
      tr '[:upper:]' '[:lower:]'
  )"
fi

[ -n "$OS_ID" ] || OS_ID="unknown"

case "$OS_ID" in
  debian|ubuntu|centos)
    DISTRO_SENSORS_HANDLING_SUPPORTED=1
    ;;
esac

# ---- clock sanity (fix 1970 timestamps) ----
# If system time is too old, many logs become confusing. We don't FAIL for this.
now_epoch="$(date +%s 2>/dev/null || echo 0)"
# Jan 1, 2022 = 1640995200 (safe threshold)
if [ "$now_epoch" -lt 1640995200 ] 2>/dev/null; then
  log_warn "System clock looks unset (epoch=$now_epoch). Logs may show 1970, consider enabling NTP or setting RTC."
fi

log_info "------------------- Starting $TESTNAME testcase -------------------"
log_info "OS_ID=$OS_ID OVERLAY_REQUESTED=$OVERLAY_REQUESTED"
log_info "OUT_DIR=$OUT_DIR SEE_DURATION=$SEE_DURATION DRVA_DURATION=$DRVA_DURATION HB_SECS=$HB_SECS STRICT_REQUIRED=$STRICT_REQUIRED PROFILE=$PROFILE"
[ -n "$SENSORS_CSV" ] && log_info "Requested sensors (override): $SENSORS_CSV"

# Install only the explicitly mapped Qualcomm Sensors runtime/test packages.
# No wildcard, development, debug-symbol, package-removal, or base-transition
# operation is permitted here.
if [ "$OVERLAY_REQUESTED" -eq 1 ]; then
  if [ "$DISTRO_SENSORS_HANDLING_SUPPORTED" -eq 1 ]; then
    for required_helper in \
      pkg_provider_init \
      pkg_ensure_optional_package_set_present \
      pkg_verify_package_set_installed; do
      if ! command -v "$required_helper" >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - required package helper is unavailable: $required_helper"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
      fi
    done

    pkg_provider_init

    old_package_set_upgrade="${PKG_PACKAGE_SET_UPGRADE-__unset__}"
    PKG_PACKAGE_SET_UPGRADE=0
    export PKG_PACKAGE_SET_UPGRADE

    if ! pkg_ensure_optional_package_set_present \
      sensors \
      qli-staging \
      auto \
      --overlay; then
      case "$old_package_set_upgrade" in
        __unset__)
          unset PKG_PACKAGE_SET_UPGRADE
          ;;
        *)
          PKG_PACKAGE_SET_UPGRADE="$old_package_set_upgrade"
          export PKG_PACKAGE_SET_UPGRADE
          ;;
      esac

      log_fail "$TESTNAME FAIL - failed to ensure Qualcomm Sensors package set"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi

    case "$old_package_set_upgrade" in
      __unset__)
        unset PKG_PACKAGE_SET_UPGRADE
        ;;
      *)
        PKG_PACKAGE_SET_UPGRADE="$old_package_set_upgrade"
        export PKG_PACKAGE_SET_UPGRADE
        ;;
    esac

    log_pass "Qualcomm Sensors runtime/test package set is ready"
  else
    log_info "Package installation skipped for os=$OS_ID; using image-provided Sensors runtime"
  fi
else
  log_info "Overlay package installation not requested; validating installed Sensors runtime"
fi

deps="ssc_sensor_info see_workhorse awk sed grep sort wc tr"
if ! check_dependencies "$deps"; then
  log_skip "$TESTNAME SKIP - missing dependencies: $deps"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if [ ! -d /etc/sensors/config ]; then
  log_skip "$TESTNAME SKIP - /etc/sensors/config not present (likely non-prop build)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# The qcom-sensors-services package installs sscrpcd.service. On supported
# desktop distributions, ensure an already-installed unit is running.
if [ "$DISTRO_SENSORS_HANDLING_SUPPORTED" -eq 1 ] &&
   command -v systemctl >/dev/null 2>&1; then
  if systemctl cat "$SENSORS_SERVICE" >/dev/null 2>&1; then
    if ! systemctl is-active --quiet "$SENSORS_SERVICE"; then
      log_info "Starting Sensors service, $SENSORS_SERVICE"

      if ! systemctl start "$SENSORS_SERVICE"; then
        log_fail "$TESTNAME FAIL - failed to start $SENSORS_SERVICE"
        systemctl status "$SENSORS_SERVICE" --no-pager --full 2>/dev/null || true
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
      fi
    fi

    log_pass "Sensors service is active, $SENSORS_SERVICE"
  else
    log_warn "Sensors service unit is not installed: $SENSORS_SERVICE"
  fi
fi

# ADSP remoteproc gating
sensors_check_adsp_remoteproc "adsp.mbn"
adsp_rc=$?

log_info "ADSP remoteproc:"
log_info " path=${SENSORS_ADSP_RPROC_PATH:-unknown} state=${SENSORS_ADSP_STATE:-unknown} firmware=${SENSORS_ADSP_FW:-unknown}"

if [ "$adsp_rc" -eq 3 ]; then
  log_skip "$TESTNAME SKIP - ADSP remoteproc not found"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
elif [ "$adsp_rc" -eq 2 ]; then
  log_fail "$TESTNAME FAIL - ADSP not running and firmware missing: ${SENSORS_ADSP_FW:-adsp.mbn}"
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 0
elif [ "$adsp_rc" -eq 1 ]; then
  log_fail "$TESTNAME FAIL - ADSP remoteproc state is not running: ${SENSORS_ADSP_STATE:-unknown}"
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 0
fi

# Discover sensors
SSC_LOG="$OUT_DIR/ssc_sensor_info.txt"
log_info "Collecting sensor inventory -> $SSC_LOG"

if ! sensors_dump_ssc_sensor_info "$SSC_LOG"; then
  log_skip "$TESTNAME SKIP - ssc_sensor_info failed to run (see $SSC_LOG)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if [ ! -s "$SSC_LOG" ] || ! grep -q '^TYPE[[:space:]]*=' "$SSC_LOG" 2>/dev/null; then
  log_skip "$TESTNAME SKIP - ssc_sensor_info produced no TYPE entries (see $SSC_LOG)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

types_nl="$(sensors_types_from_ssc_file "$SSC_LOG" 2>/dev/null || true)"
if [ -z "$types_nl" ]; then
  log_skip "$TESTNAME SKIP - no parsable sensor inventory from ssc_sensor_info (see $SSC_LOG)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

log_info "Sensor TYPEs discovered:"
printf '%s\n' "$types_nl" | while IFS= read -r t; do
  [ -n "$t" ] && log_info " - $t"
done

# ---- list-only mode should be a clean PASS for LAVA ----
if [ "$LIST_ONLY" -eq 1 ]; then
  log_pass "$TESTNAME PASS - --list requested"
  echo "$TESTNAME PASS" >"$RES_FILE"
  exit 0
fi

TARGET_NL=""
TARGET_SOURCE=""

# 1) explicit sensor list overrides everything
if [ -n "$SENSORS_CSV" ]; then
  TARGET_SOURCE="explicit list"
  OLDIFS=$IFS
  IFS=,
  set -- "$SENSORS_CSV"
  IFS=$OLDIFS
  for s in "$@"; do
    s="$(printf '%s' "$s" | tr -d '[:space:]')"
    [ -z "$s" ] && continue
    TARGET_NL="$(sensors_append_unique_line "$TARGET_NL" "$s")"
  done
else
  # 2) profile selection
  case "$PROFILE" in
    auto)
      TARGET_SOURCE="dynamic inventory"
      TARGET_NL="$(sensors_select_testable_types "$types_nl")"
      ;;
  esac

  case "$PROFILE" in
    auto)
      ;;
    basic|core)
      TARGET_SOURCE="$PROFILE profile"
      TARGET_NL="accel
gyro"
      ;;
    vision)
      TARGET_SOURCE="vision profile"
      TARGET_NL="accel
gyro
mag
pressure"
      ;;
    all)
      TARGET_SOURCE="all profile"
      TARGET_NL="$types_nl"
      ;;
    *)
      log_skip "$TESTNAME SKIP - unknown profile: $PROFILE"
      echo "$TESTNAME SKIP" >"$RES_FILE"
      exit 0
      ;;
  esac
fi

present_targets=""
missing_targets=""
for s in $TARGET_NL; do
  if sensors_type_present "$types_nl" "$s"; then
    present_targets="$(sensors_append_unique_line "$present_targets" "$s")"
  else
    missing_targets="$(sensors_append_unique_line "$missing_targets" "$s")"
  fi
done

if [ -n "$missing_targets" ]; then
  printf '%s\n' "$missing_targets" | while IFS= read -r s; do
    [ -n "$s" ] && log_warn "Selected sensor type is not present: $s"
  done

  if [ "$STRICT_REQUIRED" = "1" ]; then
    if [ "$PROFILE" != "auto" ] || [ -n "$SENSORS_CSV" ]; then
      log_fail "$TESTNAME FAIL - required selected sensor types are missing"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi
  fi
fi

TARGET_NL="$present_targets"

if [ -z "$TARGET_NL" ]; then
  log_info "No streamable data sensor types are present, completing SSC control-plane validation only"
  log_pass "$TESTNAME PASS - SSC control plane is healthy, no physical data-sensor streaming was applicable"
  echo "$TESTNAME PASS" >"$RES_FILE"
  exit 0
fi

log_info "Sensors selected to test from $TARGET_SOURCE:"
printf '%s\n' "$TARGET_NL" | while IFS= read -r s; do
  [ -n "$s" ] && log_info " - $s"
done

TARGET_FILE="$OUT_DIR/targets.txt"
printf '%s\n' "$TARGET_NL" >"$TARGET_FILE" 2>/dev/null || true

pass_count=0
fail_count=0
skip_count=0

while IFS= read -r s; do
  [ -z "$s" ] && continue

  log_info "---- Sensor test: $s ----"

  if ! sensors_type_present "$types_nl" "$s"; then
    log_info "Sensor $s: not present -> SKIP"
    skip_count=$((skip_count + 1))
    continue
  fi

  if sensors_run_see_workhorse "$s" "$SEE_DURATION" "$OUT_DIR" "$HB_SECS"; then
    log_info "see_workhorse: PASS ($s) [log: $OUT_DIR/see_workhorse_${s}.log]"
  else
    log_error "see_workhorse: FAIL ($s) [log: $OUT_DIR/see_workhorse_${s}.log]"
    fail_count=$((fail_count + 1))
    continue
  fi

  sensors_run_ssc_drva_test "$s" "$DRVA_DURATION" "$OUT_DIR" "$HB_SECS"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    log_info "ssc_drva_test: PASS ($s) [log: $OUT_DIR/ssc_drva_test_${s}.log]"
    pass_count=$((pass_count + 1))
    continue
  fi
  if [ "$rc" -eq 2 ]; then
    log_info "ssc_drva_test: SKIP ($s) (tool not present)"
    pass_count=$((pass_count + 1))
    continue
  fi

  log_error "ssc_drva_test: FAIL ($s) [log: $OUT_DIR/ssc_drva_test_${s}.log]"
  fail_count=$((fail_count + 1))
done <"$TARGET_FILE"

log_info "Summary: pass=$pass_count fail=$fail_count skip=$skip_count (logs in $OUT_DIR)"

if [ "$fail_count" -gt 0 ]; then
  log_fail "$TESTNAME FAIL - failures=$fail_count passes=$pass_count skips=$skip_count (logs in $OUT_DIR)"
  echo "$TESTNAME FAIL" >"$RES_FILE"
else
  if [ "$pass_count" -eq 0 ]; then
    log_skip "$TESTNAME SKIP - no selected sensors were validated (all missing/unsupported)"
    echo "$TESTNAME SKIP" >"$RES_FILE"
  else
    log_pass "$TESTNAME PASS - passes=$pass_count skips=$skip_count"
    echo "$TESTNAME PASS" >"$RES_FILE"
  fi
fi

exit 0
