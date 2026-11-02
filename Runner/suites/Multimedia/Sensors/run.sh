#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Dynamic Sensors validation (DT-free): discover via ssc_sensor_info and validate selected sensor types.

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

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_sensors.sh"

if [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_pkg_provider.sh"
fi

TESTNAME="Sensors"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

# usage
# Print supported CLI options and environment overrides. No target operations.
usage() {
  cat <<EOF
Usage: $0 [options]

Package handling:
  --overlay Install the Qualcomm Sensors runtime/test package set from
            qli on Debian, image APT sources on Ubuntu, or CentOS RPM sources.
            Debian package recovery requires a reboot before validation.
            No package removal or base-mode transition is performed.

Discovery:
  --list List discovered sensor TYPEs (from ssc_sensor_info) and exit 0
  --sensors <csv> Comma-separated list of sensor TYPEs to test
                           Example: --sensors accel,gyro,mag
                           Whitespace around names is trimmed, duplicates run once.
                           Empty fields or unsafe names are rejected.
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
                With 0, missing entries are SKIP. No tested sensors means SKIP.

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

# parse_args ARGS...
# Validate selection before discovery or package/service operations. Invalid input
# publishes FAIL through shared result handling. Sets existing CLI policy globals.
parse_args() {
    SENSORS_CSV=""
    SENSORS_REQUESTED=0
    REQUESTED_TARGETS=""
    PROFILE=auto
    LIST_ONLY=0
    OVERLAY_REQUESTED=0
    STRICT_REQUIRED="${STRICT_REQUIRED:-1}"

    while [ $# -gt 0 ]; do
        case "$1" in
            --overlay)
                OVERLAY_REQUESTED=1
                shift
                ;;
            --list)
                LIST_ONLY=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --out|--see-duration|--drva-duration|--hb|--strict|--sensors|--profile)
                if [ $# -lt 2 ]; then
                    test_result_finish FAIL "Missing value for $1, see --help"
                fi
                case "$2" in
                    --*)
                        test_result_finish FAIL "Missing value for $1 before $2, see --help"
                        ;;
                esac
                case "$1" in
                    --out)
                        OUT_DIR="$2"
                        ;;
                    --see-duration)
                        SEE_DURATION="$2"
                        ;;
                    --drva-duration)
                        DRVA_DURATION="$2"
                        ;;
                    --hb)
                        HB_SECS="$2"
                        ;;
                    --strict)
                        STRICT_REQUIRED="$2"
                        ;;
                    --sensors)
                        SENSORS_CSV="$2"
                        SENSORS_REQUESTED=1
                        ;;
                    --profile)
                        PROFILE="$2"
                        ;;
                esac
                shift 2
                ;;
            *)
                test_result_finish FAIL "Unknown option: $1, see --help"
                ;;
        esac
    done

    case "$STRICT_REQUIRED" in
        0|1)
            ;;
        *)
            test_result_finish FAIL "Invalid strict value '$STRICT_REQUIRED', use 0 or 1"
            ;;
    esac
    case "$PROFILE" in
        auto|basic|core|vision|all)
            ;;
        *)
            test_result_finish FAIL "Unknown profile '$PROFILE', use auto, basic, core, vision or all"
            ;;
    esac
    if [ "$SENSORS_REQUESTED" -eq 1 ]; then
        if ! REQUESTED_TARGETS=$(sensors_parse_csv "$SENSORS_CSV"); then
            test_result_finish FAIL "Invalid --sensors CSV, use nonempty comma-separated TYPE names with letters, digits, underscores or hyphens, see --list"
        fi
    fi
}

parse_args "$@"

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
  test_result_finish SKIP "$SKIP_REASON"
fi
if [ "$TEST_RESULT_FILE" != "$RES_FILE" ]; then
  test_result_init "$TESTNAME" "$RES_FILE" || exit 1
fi

OUT_DIR="${OUT_DIR:-./logs_Sensors}"
SEE_DURATION="${SEE_DURATION:-5}"
DRVA_DURATION="${DRVA_DURATION:-10}"
HB_SECS="${HB_SECS:-5}"
STRICT_REQUIRED="${STRICT_REQUIRED:-1}"
SENSORS_SERVICE="${SENSORS_SERVICE:-}"
: "${SENSORS_DRVA_NUM_SAMPLES:=325}"

if ! mkdir -p "$OUT_DIR"; then
  test_result_finish FAIL "Cannot create sensor evidence directory $OUT_DIR, check permissions"
fi
TARGET_FILE="$OUT_DIR/targets.txt"
if ! : >"$TARGET_FILE"; then
  test_result_finish FAIL "Cannot reset $TARGET_FILE, check evidence directory permissions"
fi

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
        test_result_finish FAIL "Required package helper is unavailable: $required_helper"
      fi
    done

    pkg_provider_init

    sensors_apt_source="qli-staging"
    if [ "$OS_ID" = debian ]; then
      sensors_apt_source="qli"
      if ! pkg_verify_package_set_installed sensors; then
        # Mark before recovery so an interrupted transaction cannot bypass the
        # reboot requirement on a subsequent run. Recovery remains retryable.
        if ! sensors_overlay_reboot_state mark; then
          test_result_finish FAIL "Cannot retain Debian Sensors reboot state, check CWD permissions"
        fi
      fi
    fi

    old_package_set_upgrade="${PKG_PACKAGE_SET_UPGRADE-__unset__}"
    PKG_PACKAGE_SET_UPGRADE=0
    export PKG_PACKAGE_SET_UPGRADE

    if ! pkg_ensure_optional_package_set_present \
      sensors \
      "$sensors_apt_source" \
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

      test_result_finish FAIL "Failed to ensure Qualcomm Sensors package set"
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

    log_info "Qualcomm Sensors runtime/test package set is ready"
  else
    log_info "Package installation skipped for os=$OS_ID, using image-provided Sensors runtime"
  fi
else
  log_info "Overlay package installation not requested, validating installed Sensors runtime"
fi

if [ "$OS_ID" = debian ]; then
  sensors_overlay_reboot_state check
  sensors_reboot_rc=$?
  case "$sensors_reboot_rc" in
    0)
      ;;
    2)
      test_result_finish SKIP "Debian Sensors package preparation requires a reboot, complete --overlay recovery if interrupted, then reboot and rerun from this directory"
      ;;
    *)
      test_result_finish FAIL "Cannot validate Debian Sensors reboot state, check .sensors-overlay-boot-id in the testcase directory"
      ;;
  esac
fi

deps="ssc_sensor_info see_workhorse awk sed grep sort wc tr"
# Debian package changes must use the explicit full-set flow above so they
# cannot bypass reboot tracking through per-command dependency recovery.
if [ "$OS_ID" = debian ]; then
  export CHECK_DEPS_RECOVER=0
fi
if ! check_dependencies "$deps"; then
  test_result_finish SKIP "Missing sensor dependencies, provision image commands: $deps"
fi

if [ ! -d /etc/sensors/config ]; then
  test_result_finish SKIP "/etc/sensors/config not present, provision Sensors runtime configuration"
fi

# Debian's sensinghub-sensors-daemon provides sensors.qti.service. Retain the
# legacy sscrpcd.service fallback and explicit service overrides.
if [ "$DISTRO_SENSORS_HANDLING_SUPPORTED" -eq 1 ] &&
   command -v systemctl >/dev/null 2>&1; then
  SENSORS_SERVICE="$(sensors_select_service "$SENSORS_SERVICE")"
  if systemctl cat "$SENSORS_SERVICE" >/dev/null 2>&1; then
    if ! systemctl is-active --quiet "$SENSORS_SERVICE"; then
      log_info "Starting Sensors service, $SENSORS_SERVICE"

      if ! systemctl start "$SENSORS_SERVICE" ||
         ! systemctl is-active --quiet "$SENSORS_SERVICE"; then
        systemctl status "$SENSORS_SERVICE" --no-pager --full 2>/dev/null || true
        test_result_finish FAIL "$SENSORS_SERVICE did not become active, check the service status"
      fi
    fi

    log_info "Sensors service is active, $SENSORS_SERVICE"
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
  test_result_finish SKIP "ADSP remoteproc not found, check image ADSP support"
elif [ "$adsp_rc" -eq 2 ]; then
  test_result_finish FAIL "ADSP not running and firmware missing: ${SENSORS_ADSP_FW:-adsp.mbn}"
elif [ "$adsp_rc" -eq 1 ]; then
  test_result_finish FAIL "ADSP remoteproc state is not running: ${SENSORS_ADSP_STATE:-unknown}"
fi

# Discover sensors
SSC_LOG="$OUT_DIR/ssc_sensor_info.txt"
log_info "Collecting sensor inventory -> $SSC_LOG"

if ! sensors_dump_ssc_sensor_info "$SSC_LOG"; then
  test_result_finish FAIL "ssc_sensor_info execution failed, check sensor runtime and $SSC_LOG"
fi

if [ ! -s "$SSC_LOG" ] || ! grep -q '^TYPE[[:space:]]*=' "$SSC_LOG" 2>/dev/null; then
  test_result_finish FAIL "ssc_sensor_info produced no TYPE entries, check runtime discovery in $SSC_LOG"
fi

types_nl="$(sensors_types_from_ssc_file "$SSC_LOG" 2>/dev/null || true)"
if [ -z "$types_nl" ]; then
  log_info "No available sensor TYPEs in inventory, evidence=$SSC_LOG"
fi

log_info "Sensor TYPEs discovered:"
printf '%s\n' "$types_nl" | while IFS= read -r t; do
  [ -n "$t" ] && log_info " - $t"
done

# ---- list-only mode should be a clean PASS for LAVA ----
if [ "$LIST_ONLY" -eq 1 ]; then
  test_result_finish PASS "Sensors inventory listing completed, --list does not validate streaming"
fi

TARGET_NL=""
TARGET_SOURCE=""

# 1) explicit sensor list overrides everything
if [ "$SENSORS_REQUESTED" -eq 1 ]; then
  TARGET_SOURCE="explicit list"
  TARGET_NL="$REQUESTED_TARGETS"
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
      test_result_finish FAIL "Unknown profile: $PROFILE, see --help"
      ;;
  esac
fi

present_targets=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  if sensors_type_present "$types_nl" "$s"; then
    present_targets="$(sensors_append_unique_line "$present_targets" "$s")"
  else
    if [ "$STRICT_REQUIRED" = "1" ]; then
      test_result_record FAIL "Requested sensor '$s' is unavailable in $SSC_LOG, check --list and sensor provisioning"
    else
      test_result_record SKIP "Requested sensor '$s' is unavailable in $SSC_LOG, ignored by --strict 0, check --list"
    fi
  fi
done <<EOF
$TARGET_NL
EOF

if [ "$TEST_RESULT_FAIL_COUNT" -gt 0 ]; then
  test_result_finish
fi

TARGET_NL="$present_targets"

if [ -z "$TARGET_NL" ]; then
  test_result_record SKIP "No selected sensors are available for streaming, source=$TARGET_SOURCE, check --list and $SSC_LOG"
  test_result_finish
fi

log_info "Sensors selected to test from $TARGET_SOURCE:"
printf '%s\n' "$TARGET_NL" | while IFS= read -r s; do
  [ -n "$s" ] && log_info " - $s"
done

if ! printf '%s\n' "$TARGET_NL" >"$TARGET_FILE"; then
  test_result_finish FAIL "Cannot write selected sensors to $TARGET_FILE, check evidence directory permissions"
fi

while IFS= read -r s; do
  [ -z "$s" ] && continue

  log_info "---- Sensor test: $s ----"

  if sensors_run_see_workhorse "$s" "$SEE_DURATION" "$OUT_DIR" "$HB_SECS"; then
    test_result_record PASS "see_workhorse ($s), log=$OUT_DIR/see_workhorse_${s}.log"
  else
    test_result_record FAIL "see_workhorse ($s) failed execution or its final PASS marker is absent, inspect $OUT_DIR/see_workhorse_${s}.log"
    continue
  fi

  sensors_run_ssc_drva_test "$s" "$DRVA_DURATION" "$OUT_DIR" "$HB_SECS"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    test_result_record PASS "ssc_drva_test ($s), log=$OUT_DIR/ssc_drva_test_${s}.log"
    continue
  fi
  if [ "$rc" -eq 2 ]; then
    test_result_record SKIP "ssc_drva_test ($s) is not installed, provision the optional driver-test binary for additional coverage"
    continue
  fi

  test_result_record FAIL "ssc_drva_test ($s) failed, inspect $OUT_DIR/ssc_drva_test_${s}.log"
done <"$TARGET_FILE"

log_info "Summary (checks): pass=$TEST_RESULT_PASS_COUNT fail=$TEST_RESULT_FAIL_COUNT skip=$TEST_RESULT_SKIP_COUNT (logs in $OUT_DIR)"
test_result_finish
