#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Camera NHX validation

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
  exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
  # shellcheck disable=SC1090
  . "$INIT_ENV"
  __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_system.sh"

# shellcheck disable=SC1090,SC1091
. "$TOOLS/camera/lib_camera.sh"

if [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$TOOLS/lib_pkg_provider.sh"
fi

TESTNAME="Camera_NHX"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

LOG_DIR="$SCRIPT_DIR/logs"
OUT_DIR="$SCRIPT_DIR/out"
DUMP_DIR="/var/cache/camera/nativehaltest"

mkdir -p "$LOG_DIR" "$OUT_DIR"

TS=$(date "+%Y%m%d_%H%M%S")
RUN_LOG="$LOG_DIR/${TESTNAME}_${TS}.log"
SUMMARY_TXT="$OUT_DIR/${TESTNAME}_summary_${TS}.txt"
DMESG_DIR="$LOG_DIR/dmesg_${TS}"
CAMX_EFI_LOG="$LOG_DIR/${TESTNAME}_camx_efi_${TS}.log"
CAMX_EFI_LIST_LOG="$LOG_DIR/${TESTNAME}_camx_efi_list_${TS}.log"
RUNNING_DTS="$OUT_DIR/${TESTNAME}_running_${TS}.dts"
RUNNING_DTS_WARNINGS="$LOG_DIR/${TESTNAME}_dtc_${TS}.log"
CAMERA_DTS_MATCHES="$OUT_DIR/${TESTNAME}_runtime_camera_${TS}.log"
SENSOR_DTS_MATCHES="$OUT_DIR/${TESTNAME}_runtime_sensors_${TS}.log"
CAMX_DT_NODES_LOG="$OUT_DIR/${TESTNAME}_enabled_camx_nodes_${TS}.log"
SENSOR_DT_NODES_LOG="$OUT_DIR/${TESTNAME}_enabled_sensor_nodes_${TS}.log"

NHX_OUTDIR="$OUT_DIR/nhx_${TS}"

DUMPS_LIST="$NHX_OUTDIR/nhx_dumps.list"
CHECKSUMS_TXT="$NHX_OUTDIR/nhx_checksums.txt"
CHECKSUMS_PREV="$OUT_DIR/${TESTNAME}_checksums.prev.txt"

MARKER="$(mktemp "/tmp/${TESTNAME}.marker.XXXXXX" 2>/dev/null)"
if [ -z "$MARKER" ]; then
  MARKER="/tmp/${TESTNAME}.marker.$$"
  : >"$MARKER" 2>/dev/null || true
fi

CAM_SERVER_PRESENT=0
CAM_SERVER_SERVICE=""
CAM_SERVER_STOPPED_FOR_TEST=0
CAM_SERVER_RESTORE_FAILED=0
NHX_CHECK_SETUP=0

NHX_JSON="${NHX_JSON:-}"
NHX_TARGET="${NHX_TARGET:-}"
NHX_RUNNER=""
NHX_RUNNER_SOURCE=""
NHX_RUNNER_MODE="wrapper"
NATIVE_REQUESTED=0
NATIVE_TEST=""
NATIVE_BIN=""
NATIVE_FRAMES=150
NATIVE_FRAMES_EXPLICIT=0
NATIVE_CAMERA=""
NATIVE_DUMP_OVERRIDE=""
NATIVE_SELECTOR=""
NATIVE_REPORT_VALID=1
NATIVE_NO_TESTS=0
NATIVE_MODE="test"
NATIVE_JSON_STATE=""
NATIVE_JSON_RESTORE_FAILED=0
NATIVE_CAPTURE_ACTIVE=0
NHX_JSON_RESOLVED=""
NHX_JSON_ARG=""
OVERLAY_REQUESTED=0
FIT_DTB_NAME=""
FIT_DTB_SOURCE=""
CAMX_FIT_DTB_SELECTED=0

# shellcheck disable=SC2317
cleanup() {
  trap - EXIT INT TERM
  if [ "$NATIVE_CAPTURE_ACTIVE" -eq 1 ]; then
    if ! nhx_stop_native_capture; then
      test_result_finish "FAIL" "$TESTNAME interrupted native capture could not be stopped safely"
    fi
  fi
  if [ -n "${NATIVE_JSON_STATE:-}" ]; then
    if ! nhx_restore_native_json "$NATIVE_JSON_STATE"; then
      NATIVE_JSON_RESTORE_FAILED=1
    fi
  fi
  if command -v efi_restore_efivarfs_ro >/dev/null 2>&1; then
    efi_restore_efivarfs_ro >/dev/null 2>&1 || true
  fi

  if [ "$CAM_SERVER_STOPPED_FOR_TEST" -eq 1 ] && [ "$CAM_SERVER_PRESENT" -eq 1 ]; then
    if ! nhx_restore_camera_service "$CAM_SERVER_SERVICE" "$LOG_DIR"; then
      test_result_finish "FAIL" "$TESTNAME FAIL camera-server restoration failed: $CAM_SERVER_SERVICE"
    fi
  fi

  if [ -n "${MARKER:-}" ]; then
    rm -f "$MARKER"
  fi
  if [ "${NATIVE_JSON_RESTORE_FAILED:-0}" -ne 0 ]; then
    test_result_finish "FAIL" "$TESTNAME native JSON cleanup failed, see $NATIVE_JSON_STATE"
  fi
}

trap 'cleanup' EXIT
trap 'test_result_finish "FAIL" "$TESTNAME interrupted, restoring owned camera state"' INT TERM

usage() {
  cat <<EOF
Usage: $0 [--check-setup] [--overlay] [--fit-dtb NAME] [--json JSON_FILE] [--target TARGET] [--help]
       $0 --native-test Suite.Case [--native-bin /path/nativehaltest]
          [--native-frames N] [--native-camera ID] [--native-dump-dir /path]

Options:
  --check-setup    Read-only NHX runtime readiness, no capture, package changes,
                   EFI writes or service changes. Writes Camera_NHX_Setup.res.
                   Cannot be combined with --overlay, --fit-dtb, --json or --target.
  --overlay        Verify the Camera NHX CAMX package set on supported Debian,
                   Ubuntu, or CentOS images, install missing packages, and
                   ensure the CAMX FIT DTB is selected for boot.
  --fit-dtb NAME    Select this FIT DTB compatibility name for the next boot.
                   Camera_NHX supports camx, which is the --overlay default.
                   This option requires --overlay.
  --json JSON_FILE NHX JSON file to pass to the selected NHX launcher.
                     Can be absolute, relative to Camera_NHX/, or relative
                     to target folder when --target is provided.
  --target TARGET Target folder name: Kodiak, Lemans, Monaco, Talos.
                     Used to resolve/stage --json under /etc/camera/test/NHX.
  --native-test NAME Run exactly one native HAL Suite.Case, no wildcards.
                     Selects native mode even when an NHX wrapper is installed.
                     Cannot be combined with --json or --target.
  --native-bin PATH Override native executable discovery with an absolute path.
  --native-frames N Number of native capture frames, 1..10000, default 150.
  --native-camera ID Explicit camera ID. Otherwise retain the client default.
  --native-dump-dir PATH Native image output directory to validate. Does not
                     redirect the binary output. Default: $DUMP_DIR
                     Native capture has a 180-second total timeout.
  --help Show this help.

Examples:
  $0
  $0 --check-setup
  $0 --check-setup --native-bin /usr/libexec/camx-kodiak/nativehaltest
  $0 --overlay
  $0 --overlay --fit-dtb camx
  $0 --json Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
  $0 --json Snapshot_YUVNV12_MaxResolution_NHX.json --target Kodiak
  $0 --json Kodiak/Preview_YUVNV12_MaxResolution_NHX.json --native-bin /usr/libexec/camx-kodiak/nativehaltest
  NHX_JSON=Talos/Video_YUVNV12_MaxResolution_NHX.json $0
EOF
}

# parse_args arguments...
# Parse NHX capture or read-only readiness options before any target mutation.
parse_args() {
while [ "$#" -gt 0 ]; do
  case "$1" in
    --native-test|--native-bin|--native-frames|--native-camera|--native-dump-dir)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        test_result_finish "FAIL" "$TESTNAME $1 requires a nonempty argument"
      fi
      NATIVE_REQUESTED=1
      case "$1" in
        --native-test)
          NATIVE_TEST="$2"
          ;;
        --native-bin)
          NATIVE_BIN="$2"
          ;;
        --native-frames)
          NATIVE_FRAMES="$2"
          NATIVE_FRAMES_EXPLICIT=1
          ;;
        --native-camera)
          NATIVE_CAMERA="$2"
          ;;
        --native-dump-dir)
          NATIVE_DUMP_OVERRIDE="$2"
          ;;
      esac
      shift 2
      ;;
    --check-setup)
      NHX_CHECK_SETUP=1
      TESTNAME="Camera_NHX_Setup"
      RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
      test_result_init "$TESTNAME" "$RES_FILE" || exit 1
      shift
      ;;
    --overlay)
      OVERLAY_REQUESTED=1
      shift
      ;;
    --fit-dtb)
      if [ "$#" -lt 2 ]; then
        echo "[ERROR] --fit-dtb requires an argument" >&2
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      FIT_DTB_NAME="$2"
      FIT_DTB_SOURCE="cli"
      shift 2
      ;;
    --fit-dtb=*)
      FIT_DTB_NAME="${1#--fit-dtb=}"
      FIT_DTB_SOURCE="cli"
      shift
      ;;
    --json)
      if [ "$#" -lt 2 ]; then
        echo "[ERROR] --json requires an argument" >&2
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      NHX_JSON="$2"
      shift 2
      ;;
    --json=*)
      NHX_JSON="${1#--json=}"
      shift
      ;;
    --target)
      if [ "$#" -lt 2 ]; then
        echo "[ERROR] --target requires an argument" >&2
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      NHX_TARGET="$2"
      shift 2
      ;;
    --target=*)
      NHX_TARGET="${1#--target=}"
      shift
      ;;
    -h|--help)
      usage
      echo "$TESTNAME SKIP" >"$RES_FILE"
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage >&2
      echo "$TESTNAME SKIP" >"$RES_FILE"
      exit 0
      ;;
  esac
done
}
parse_args "$@"

if [ "$NATIVE_REQUESTED" -eq 1 ]; then
  if [ -n "$NATIVE_TEST" ] && [ -n "$NHX_JSON$NHX_TARGET" ]; then
    test_result_finish "FAIL" "$TESTNAME choose either --native-test or --json, not both"
  fi
  if [ -n "$NHX_JSON" ] && { [ "$NATIVE_FRAMES_EXPLICIT" -eq 1 ] || [ -n "$NATIVE_CAMERA" ]; }; then
    test_result_finish "FAIL" "$TESTNAME native JSON uses its own frames and camera, remove --native-frames and --native-camera"
  fi
  case "$NATIVE_BIN" in
    ""|/*)
      ;;
    *)
      test_result_finish "FAIL" "$TESTNAME --native-bin requires an absolute executable path"
      ;;
  esac
  if [ -n "$NATIVE_TEST" ] && \
    ! printf '%s\n' "$NATIVE_TEST" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$'; then
    test_result_finish "FAIL" "$TESTNAME --native-test requires one exact Suite.Case, no wildcard or multi-test filter"
  fi
  case "$NATIVE_FRAMES" in
    ''|*[!0-9]*|0)
      test_result_finish "FAIL" "$TESTNAME --native-frames requires an integer from 1 to 10000"
      ;;
  esac
  if [ "${#NATIVE_FRAMES}" -gt 5 ] || [ "$NATIVE_FRAMES" -lt 1 ] || [ "$NATIVE_FRAMES" -gt 10000 ]; then
    test_result_finish "FAIL" "$TESTNAME --native-frames must be within 1..10000"
  fi
  case "$NATIVE_CAMERA" in
    *[!0-9]*)
      test_result_finish "FAIL" "$TESTNAME --native-camera requires a nonnegative numeric camera ID"
      ;;
  esac
  if [ -n "$NATIVE_CAMERA" ]; then
    if [ "${#NATIVE_CAMERA}" -gt 10 ] || [ "$NATIVE_CAMERA" -gt 2147483647 ]; then
      test_result_finish "FAIL" "$TESTNAME --native-camera exceeds the supported integer ID range"
    fi
  fi
  case "$NATIVE_DUMP_OVERRIDE" in
    "")
      ;;
    /|/./|*/../*|*/..)
      test_result_finish "FAIL" "$TESTNAME --native-dump-dir must name the specific native capture directory"
      ;;
    /*)
      DUMP_DIR="$NATIVE_DUMP_OVERRIDE"
      ;;
    *)
      test_result_finish "FAIL" "$TESTNAME --native-dump-dir requires an absolute path"
      ;;
  esac
fi

if [ "$NHX_CHECK_SETUP" -eq 1 ]; then
  TESTNAME="Camera_NHX_Setup"
  RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
  test_result_init "$TESTNAME" "$RES_FILE" || exit 1
  if [ "$OVERLAY_REQUESTED" -eq 1 ] || [ -n "$FIT_DTB_NAME$NHX_JSON$NHX_TARGET" ]; then
    test_result_finish "FAIL" "$TESTNAME accepts only --check-setup, no overlay or capture selections"
  fi
  if [ -n "$NATIVE_TEST$NATIVE_CAMERA$NATIVE_DUMP_OVERRIDE" ] || [ "$NATIVE_FRAMES_EXPLICIT" -eq 1 ]; then
    test_result_finish "FAIL" "$TESTNAME accepts native executable discovery only, not native capture selections"
  fi
  if ! command -v pkg_detect_os_id >/dev/null 2>&1; then
    test_result_finish "FAIL" "$TESTNAME requires the repository package-provider helper"
  fi
  if [ "$(pkg_detect_os_id)" = centos ]; then
    nhx_check_rpm_setup "$LOG_DIR"
    NHX_SETUP_RPM_STATUS=$?
    case "$NHX_SETUP_RPM_STATUS" in
      0)
        ;;
      2)
        test_result_finish "SKIP" "$TESTNAME requires the image-provided CAMX core package set, inspect NHX-PACKAGE diagnostics"
        ;;
      *)
        test_result_finish "FAIL" "$TESTNAME could not query CAMX packages, inspect NHX-PACKAGE diagnostics"
        ;;
    esac
    if ! command -v efivar >/dev/null 2>&1; then
      test_result_finish "SKIP" "$TESTNAME requires image-provided efivar and its matching libraries, private RPM installation is not automated"
    fi
    NHX_SETUP_EFI=$(efi_find_variable_by_name VendorDtbOverlays "$CAMX_EFI_LIST_LOG")
    NHX_SETUP_EFI_STATUS=$?
    if [ "$NHX_SETUP_EFI_STATUS" -ne 0 ] && [ "$NHX_SETUP_EFI_STATUS" -ne 2 ]; then
      log_file_with_label "NHX-EFI" "$CAMX_EFI_LIST_LOG"
      test_result_finish "FAIL" "$TESTNAME could not discover EFI variables, check efivar runtime libraries and EFI permissions"
    fi
    if [ "$NHX_SETUP_EFI_STATUS" -eq 2 ]; then
      test_result_finish "SKIP" "$TESTNAME requires firmware exposing VendorDtbOverlays for CAMX selection"
    fi
    efi_text_variable_matches "$NHX_SETUP_EFI" camx "$CAMX_EFI_LOG" csv-token >/dev/null
    NHX_SETUP_EFI_STATUS=$?
    log_file_with_label NHX-EFI "$CAMX_EFI_LOG"
    case "$NHX_SETUP_EFI_STATUS" in
      0)
        ;;
      2)
        test_result_finish "SKIP" "$TESTNAME requires camx in the EFI VendorDtbOverlays list, provision the overlay and reboot before checking runtime readiness"
        ;;
      *)
        test_result_finish "FAIL" "$TESTNAME could not read or parse VendorDtbOverlays, inspect $CAMX_EFI_LOG. No EFI changes attempted"
        ;;
    esac
  fi
fi

if [ "$OVERLAY_REQUESTED" -eq 1 ]; then
  if [ -z "$FIT_DTB_NAME" ]; then
    FIT_DTB_NAME="camx"
    FIT_DTB_SOURCE="overlay-default"
  fi

  if [ "$FIT_DTB_NAME" != "camx" ]; then
    log_fail "$TESTNAME FAIL - Camera_NHX requires the camx FIT DTB compatibility name"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
  fi

  log_info "CAMX FIT DTB policy, name=$FIT_DTB_NAME source=$FIT_DTB_SOURCE"
elif [ -n "$FIT_DTB_NAME" ]; then
  log_fail "$TESTNAME FAIL - --fit-dtb requires --overlay"
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 0
fi

if [ "$OVERLAY_REQUESTED" -eq 1 ]; then
  for required_helper in \
    pkg_provider_init \
    pkg_detect_os_id \
    pkg_lookup_package_set \
    pkg_ensure_optional_package_set_present \
    pkg_verify_package_set_installed; do
    if ! command -v "$required_helper" >/dev/null 2>&1; then
      log_fail "$TESTNAME FAIL - required package helper is unavailable: $required_helper"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi
  done

  pkg_provider_init
  CAMX_OVERLAY_OS_ID="$(pkg_detect_os_id 2>/dev/null || true)"
  CAMX_APT_SOURCE="none"

  if [ "$CAMX_OVERLAY_OS_ID" = "debian" ]; then
    CAMX_APT_SOURCE="qli-staging"
  fi

  CAMX_PACKAGES="$(pkg_lookup_package_set camera-nhx 2>/dev/null || true)"
  if [ -z "$CAMX_PACKAGES" ]; then
    log_skip "$TESTNAME SKIP - no Camera NHX package-set mapping is available, os=${CAMX_OVERLAY_OS_ID:-unknown} action=add-a-camera-nhx-package-set-mapping-for-this-os"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi

  if pkg_verify_package_set_installed camera-nhx; then
    log_info "Reusing installed CAMX package set, no repository refresh or package installation required"
  else
    if [ "$CAMX_OVERLAY_OS_ID" = centos ]; then
      if ! pkg_prepare_camx_rpm_repositories "$LOG_DIR"; then
        test_result_finish "FAIL" "$TESTNAME CAMX repository preparation failed, inspect EPEL, Qualcomm and CLO diagnostics"
      fi
    fi
    log_info "Ensuring complete Camera NHX package set, os=${CAMX_OVERLAY_OS_ID:-unknown} packages=$CAMX_PACKAGES"
    if ! pkg_ensure_optional_package_set_present \
      camera-nhx \
      "$CAMX_APT_SOURCE" \
      auto \
      --overlay; then
      test_result_finish "FAIL" "$TESTNAME --overlay package-set installation failed, check configured repositories for $CAMX_PACKAGES"
    fi
    if ! pkg_verify_package_set_installed camera-nhx; then
      test_result_finish "FAIL" "$TESTNAME CAMX package recovery left an incomplete package set: $CAMX_PACKAGES"
    fi
  fi

  log_pass "Camera NHX CAMX package set is ready"

  case "$CAMX_OVERLAY_OS_ID" in
    debian|ubuntu|centos)
      for required_helper in \
        pkg_ensure_command \
        efi_ensure_mounted \
        efi_find_variable_by_name \
        efi_text_variable_matches \
        efi_write_text_variable \
        camx_ensure_fit_selection \
        efi_restore_efivarfs_ro; do
        if ! command -v "$required_helper" >/dev/null 2>&1; then
          log_fail "$TESTNAME FAIL - required EFI helper is unavailable: $required_helper"
          echo "$TESTNAME FAIL" >"$RES_FILE"
          exit 0
        fi
      done

      if ! pkg_ensure_command efivar; then
        test_result_finish "FAIL" "$TESTNAME could not provide efivar from the configured package repositories. Check the mapped package and matching runtime libraries, private RPM replacement is not automated"
      fi

      if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies efivar mount mktemp od tr sed grep sync awk mv rm sort find; then
        log_skip "$TESTNAME SKIP - CAMX FIT DTB verification requires efivar and EFI runtime tools"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi

      efi_ensure_mounted "$LOG_DIR/${TESTNAME}_efi_mount_${TS}.log"
      CAMX_EFI_MOUNT_STATUS=$?
      case "$CAMX_EFI_MOUNT_STATUS" in
        0)
          ;;
        2)
          test_result_finish "SKIP" "$TESTNAME requires EFI runtime support for CAMX overlay selection"
          ;;
        *)
          test_result_finish "FAIL" "$TESTNAME could not prepare efivarfs for CAMX overlay selection"
          ;;
      esac

      CAMX_DTB_OVERLAY_VARIABLE="$(efi_find_variable_by_name \
        VendorDtbOverlays \
        "$CAMX_EFI_LIST_LOG" 2>>"$CAMX_EFI_LOG")"
      CAMX_EFI_DISCOVERY_STATUS=$?
      case "$CAMX_EFI_DISCOVERY_STATUS" in
        0)
          ;;
        2)
          test_result_finish "SKIP" "$TESTNAME requires firmware exposing the VendorDtbOverlays EFI variable"
          ;;
        *)
          log_file_with_label "NHX-EFI" "$CAMX_EFI_LIST_LOG"
          log_file_with_label "NHX-EFI" "$CAMX_EFI_LOG"
          test_result_finish "FAIL" "$TESTNAME could not discover one VendorDtbOverlays variable, check efivar runtime libraries, EFI permissions and duplicate variables"
          ;;
      esac

      log_info "CAMX FIT DTB EFI variable selected: $CAMX_DTB_OVERLAY_VARIABLE"

      camx_ensure_fit_selection \
        "$CAMX_DTB_OVERLAY_VARIABLE" \
        "$FIT_DTB_NAME" \
        "$CAMX_EFI_LOG" \
        "$LOG_DIR/camx-fit-selection.pending"
      CAMX_SELECTION_STATUS=$?
      case "$CAMX_SELECTION_STATUS" in
        0)
          CAMX_FIT_DTB_SELECTED=1
          log_info "Continuing with camera runtime validation, no EFI setup changes needed"
          ;;
        2)
          test_result_finish "SKIP" "$TESTNAME CAMX FIT DTB selection awaits a manual reboot, then rerun the same command"
          ;;
        *)
          test_result_finish "FAIL" "$TESTNAME CAMX FIT selection could not be verified, inspect EFI before/write/readback diagnostics and any pending-selection record. No automatic rewrite or reboot retry"
          ;;
      esac
      ;;
    *)
      log_info "CAMX device-tree overlay selection is not applicable, os=${CAMX_OVERLAY_OS_ID:-unknown}"
      ;;
  esac
else
  log_info "Camera NHX overlay package recovery not requested"
fi

# -----------------------------------------------------------------------------
# Deps check
# -----------------------------------------------------------------------------
deps_list="date awk sed grep tee wc ls find stat rm tr head tail sort mkfifo cp mkdir"
if ! CHECK_DEPS_RECOVER=0 check_dependencies "$deps_list"; then
  log_skip "$TESTNAME SKIP missing one or more dependencies: $deps_list"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

CKSUM_TOOL="$(nhx_pick_cksum_tool)"
if [ -z "$CKSUM_TOOL" ]; then
  log_skip "$TESTNAME SKIP checksum validation requires one image-provided utility: sha256sum, md5sum, or cksum"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if [ "$NATIVE_REQUESTED" -eq 0 ]; then
  NHX_RUNNER=$(nhx_find_launcher wrapper "")
  NHX_DISCOVERY_STATUS=$?
else
  NHX_DISCOVERY_STATUS=2
fi
if [ "$NHX_DISCOVERY_STATUS" -eq 2 ]; then
  NHX_RUNNER_MODE=native
  NHX_RUNNER=$(nhx_find_launcher native "$NATIVE_BIN")
  NHX_DISCOVERY_STATUS=$?
fi
case "$NHX_DISCOVERY_STATUS" in
  0)
    ;;
  2)
    test_result_finish "SKIP" "$TESTNAME requires an executable nhx.sh, camera-nhx or nativehaltest from the image CAMX packages"
    ;;
  *)
    test_result_finish "FAIL" "$TESTNAME could not select a unique executable, inspect discovery diagnostics or specify --native-bin"
    ;;
esac
NHX_RUNNER_SOURCE="$NHX_RUNNER_MODE-runtime-discovery"

if [ "$NHX_RUNNER_MODE" = native ]; then
  if [ -n "$NHX_JSON" ]; then
    NATIVE_MODE=json
  elif [ -n "$NHX_TARGET" ]; then
    test_result_finish "FAIL" "$TESTNAME native JSON selection requires --json with --target"
  fi
  if ! NATIVE_SELECTOR=$(nhx_native_check_cli "$NHX_RUNNER" "$LOG_DIR" "$NATIVE_CAMERA" "$NATIVE_MODE"); then
    log_file_with_label NATIVE-HAL-HELP "$LOG_DIR/native-hal-help.log"
    test_result_finish "FAIL" "$TESTNAME installed nativehaltest lacks the required capture CLI or its help probe failed"
  fi
  if [ "$NHX_CHECK_SETUP" -eq 0 ] && [ -z "$NATIVE_TEST$NHX_JSON" ]; then
    test_result_finish "SKIP" "$TESTNAME nativehaltest found at $NHX_RUNNER. Select --json from the suite folder or --native-test Suite.Case supported by this client"
  fi
fi

log_info "NHX runner selected, path=$NHX_RUNNER source=$NHX_RUNNER_SOURCE"

# -----------------------------------------------------------------------------
# CAMX prechecks
# -----------------------------------------------------------------------------
log_info "Checking CAMX proprietary prerequisites before running NHX"

log_info "Decoding the active runtime device tree"

camx_dump_runtime_dts "$RUNNING_DTS" "$RUNNING_DTS_WARNINGS"
DTC_RC=$?
case "$DTC_RC" in
  0)
    log_pass "Active runtime DT decoded to $RUNNING_DTS"
    if [ -s "$RUNNING_DTS_WARNINGS" ]; then
      log_warn "dtc reported non-fatal warnings, retained in $RUNNING_DTS_WARNINGS"
    fi
    ;;
  2)
    : >"$RUNNING_DTS_WARNINGS"
    : >"$CAMERA_DTS_MATCHES"
    : >"$SENSOR_DTS_MATCHES"
    log_warn "dtc is not available in the image, continuing with enabled runtime-node validation"
    ;;
  3)
    : >"$RUNNING_DTS_WARNINGS"
    : >"$CAMERA_DTS_MATCHES"
    : >"$SENSOR_DTS_MATCHES"
    log_warn "No readable runtime device-tree root is exposed under procfs or sysfs"
    ;;
  *)
    : >"$CAMERA_DTS_MATCHES"
    : >"$SENSOR_DTS_MATCHES"
    log_warn "Active runtime DT decoding failed, continuing with enabled runtime-node validation, inspect $RUNNING_DTS_WARNINGS"
    ;;
esac

if [ "$DTC_RC" -eq 0 ]; then
  camx_extract_runtime_dts_evidence \
    "$RUNNING_DTS" \
    "$CAMERA_DTS_MATCHES" \
    "$SENSOR_DTS_MATCHES"
fi

RUNTIME_DT_ROOT="$(dt_runtime_root 2>/dev/null || true)"
RUNTIME_DT_MODEL="$(dt_property_text "$RUNTIME_DT_ROOT" model 2>/dev/null || true)"
RUNTIME_DT_COMPATIBLE="$(dt_property_text "$RUNTIME_DT_ROOT" compatible 2>/dev/null || true)"
log_info "Runtime DT model: ${RUNTIME_DT_MODEL:-unavailable}"
log_info "Runtime DT compatible: ${RUNTIME_DT_COMPATIBLE:-unavailable}"
if [ "$DTC_RC" -eq 0 ]; then
  log_info "[CAMX-CDT-FIT] efi_camx_selected=$CAMX_FIT_DTB_SELECTED active_dt=$RUNNING_DTS"
  log_info "Runtime camera DTS matches retained in $CAMERA_DTS_MATCHES"
  log_info "Runtime sensor DTS matches retained in $SENSOR_DTS_MATCHES"
else
  log_info "[CAMX-CDT-FIT] efi_camx_selected=$CAMX_FIT_DTB_SELECTED active_dt=unavailable"
fi

CAMX_DT_NODES="$(camx_list_enabled_runtime_nodes)"
: >"$CAMX_DT_NODES_LOG"
if [ -n "$CAMX_DT_NODES" ]; then
  printf '%s\n' "$CAMX_DT_NODES" >"$CAMX_DT_NODES_LOG"
fi
if [ -z "$CAMX_DT_NODES" ]; then
  if [ "$CAMX_FIT_DTB_SELECTED" -eq 1 ]; then
    log_fail "$TESTNAME FAIL - VendorDtbOverlays selects camx but the active runtime DT has no enabled downstream CamX nodes, verify the CDT-selected FIT configuration and rebooted image"
    echo "$TESTNAME FAIL" >"$RES_FILE"
  else
    log_skip "$TESTNAME SKIP - the active runtime DT has no enabled downstream CamX nodes, provision a CAMX-capable FIT configuration selected by CDT"
    echo "$TESTNAME SKIP" >"$RES_FILE"
  fi
  exit 0
fi

printf '%s\n' "$CAMX_DT_NODES" | while IFS= read -r camx_node; do
  if [ -n "$camx_node" ]; then
    log_info "Enabled CamX DT node: $camx_node"
  fi
done
log_pass "Active runtime DT exposes enabled downstream CamX nodes"

SENSOR_DT_NODES="$(camx_list_enabled_sensor_nodes)"
: >"$SENSOR_DT_NODES_LOG"
if [ -n "$SENSOR_DT_NODES" ]; then
  printf '%s\n' "$SENSOR_DT_NODES" >"$SENSOR_DT_NODES_LOG"
  printf '%s\n' "$SENSOR_DT_NODES" | while IFS= read -r sensor_node; do
    if [ -n "$sensor_node" ]; then
      log_info "Enabled camera sensor DT node: $sensor_node"
    fi
  done
else
  log_warn "No enabled IMX, OV, AR, CamX sensor, or GMSL sensor nodes were found, NHX execution remains authoritative"
fi

log_info "Checking optional raw FDT camera evidence"

FDT_MATCHES="$(camx_fdtdump_has_cam_nodes 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then
  printf '%s\n' "$FDT_MATCHES" | while IFS= read -r fdt_match; do
    if [ -n "$fdt_match" ]; then
      log_info "Raw FDT camera match: $fdt_match"
    fi
  done
elif [ "$rc" -eq 2 ]; then
  log_warn "Optional fdtdump command is unavailable, continuing with enabled runtime-node evidence"
else
  log_warn "Optional raw FDT scan did not find camera nodes, continuing with enabled runtime DT evidence"
fi

log_info "driver load checks"

CAM_MOD=""

if command -v camx_pick_camera_module >/dev/null 2>&1; then
  CAM_MOD="$(camx_pick_camera_module 2>/dev/null || true)"
fi

if [ -z "$CAM_MOD" ] && command -v lsmod >/dev/null 2>&1; then
  CAM_MOD="$(lsmod 2>/dev/null | awk '{print $1}' | grep -E '^(camera_qc|camera_qcm|camera_qcs|camera_x1e80100)' | head -n 1 || true)"
fi

if [ -z "$CAM_MOD" ]; then
  log_skip "$TESTNAME SKIP could not determine board-specific camera module"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

log_info "Board-specific camera module selected $CAM_MOD"

CAM_KO="$(find_kernel_module "$CAM_MOD" 2>/dev/null || true)"
if [ -z "$CAM_KO" ] || [ ! -f "$CAM_KO" ]; then
  log_skip "$TESTNAME SKIP camera module artifact not found ${CAM_MOD}.ko"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "Camera module artifact found $CAM_KO"

if ! is_module_loaded "$CAM_MOD" 2>/dev/null; then
  if [ "$CAMX_FIT_DTB_SELECTED" -eq 1 ]; then
    test_result_finish "FAIL" "$TESTNAME CAMX FIT DTB is selected in EFI but $CAM_MOD is not loaded, inspect the running-kernel CAMX module and probe diagnostics"
  else
    log_skip "$TESTNAME SKIP camera module not loaded $CAM_MOD"
  fi
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_pass "Driver/module '$CAM_MOD' is loaded"
log_info "Camera module is loaded $CAM_MOD"

if [ "$CAMX_FIT_DTB_SELECTED" -eq 1 ]; then
  log_pass "CAMX FIT DTB runtime evidence confirmed by loaded module $CAM_MOD"
fi

ICP_FW="$(camx_find_icp_firmware 2>/dev/null || true)"
if [ -z "$ICP_FW" ] || [ ! -f "$ICP_FW" ]; then
  log_skip "$TESTNAME SKIP CAMERA_ICP firmware not found"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "ICP firmware found $ICP_FW"

module_regex='CAM_(ERR|WARN|FATAL)'
exclude_regex='dummy regulator|supply [^ ]+ not found|using dummy regulator'

scan_dmesg_errors "$DMESG_DIR" "$module_regex" "$exclude_regex" || true

if [ -s "$DMESG_DIR/dmesg_errors.log" ]; then
  log_warn "dmesg scan found camera warnings or errors in $DMESG_DIR/dmesg_errors.log"
else
  log_info "dmesg scan did not find camera warnings or errors"
fi

DM_SNAP="$DMESG_DIR/dmesg_snapshot.log"

FW_BASENAME="$(basename "$ICP_FW" 2>/dev/null || echo "")"
FW_DL_OK=0
FW_DONE_OK=0

if [ -n "$FW_BASENAME" ] && [ -r "$DM_SNAP" ]; then
  if grep -F "CAM_INFO: CAM-ICP: cam_a5_download_fw" "$DM_SNAP" 2>/dev/null | grep -F "$FW_BASENAME" >/dev/null 2>&1; then
    FW_DL_OK=1
  fi
  if grep -F "CAM_INFO: CAM-ICP: cam_icp_mgr_hw_open" "$DM_SNAP" 2>/dev/null | grep -F "FW download done successfully" >/dev/null 2>&1; then
    FW_DONE_OK=1
  fi
fi

if [ "$FW_DL_OK" -eq 1 ] && [ "$FW_DONE_OK" -eq 1 ]; then
  log_info "ICP firmware load markers found in dmesg"
else
  log_warn "ICP firmware load markers missing in dmesg"
  log_warn "FW download marker $FW_DL_OK"
  log_warn "FW done marker $FW_DONE_OK"
  log_warn "dmesg snapshot $DM_SNAP"
fi

bind_cnt=0
if [ -r "$DM_SNAP" ]; then
  bind_cnt="$(grep -ciE 'cam_req_mgr.*bound|bound.*cam_req_mgr' "$DM_SNAP" 2>/dev/null || echo 0)"
  case "$bind_cnt" in
    ''|*[!0-9]*) bind_cnt=0 ;;
  esac
fi

if [ "$bind_cnt" -lt 1 ]; then
  log_warn "CAMX bind graph not observed in pre-NHX dmesg snapshot"
else
  log_info "CAMX bind graph observed in pre-NHX dmesg snapshot count=$bind_cnt"
fi

log_info "packages present"

CAMX_PKGS="$(camx_opkg_list_camx 2>/dev/null || true)"
if [ -z "$CAMX_PKGS" ]; then
  if [ "$OVERLAY_REQUESTED" -eq 1 ]; then
    log_warn "CAMX package inventory is unavailable after package-set verification, continuing"
  else
    log_skip "$TESTNAME SKIP CAMX packages not installed"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
else
  log_info "CAMX packages detected"
  printf '%s\n' "$CAMX_PKGS" | while IFS= read -r l; do
    if [ -n "$l" ]; then
      log_info " $l"
    fi
  done
fi

log_info "libcamera sensor inventory is advisory, it does not enumerate the proprietary CAMX HAL"

SENSOR_COUNT="$(libcam_list_sensors_count 2>/dev/null || true)"
case "$SENSOR_COUNT" in
  ''|*[!0-9]*) SENSOR_COUNT=0 ;;
esac
log_info "cam list detected $SENSOR_COUNT cameras"
if [ "$SENSOR_COUNT" -lt 1 ]; then
  log_warn "No sensors reported by cam list, NHX capture must still prove the selected camera works"
fi

if [ "$NHX_CHECK_SETUP" -eq 1 ]; then
  test_result_finish "PASS" "$TESTNAME NHX runtime prerequisites are present. No capture, QMMF service or physical sensor functionality was tested"
fi

if [ "$NHX_RUNNER_MODE" = native ] && [ "$NATIVE_MODE" = json ]; then
  if ! NHX_JSON_RESOLVED=$(nhx_resolve_json_file "$SCRIPT_DIR" "$NHX_JSON" "$NHX_TARGET"); then
    test_result_finish "FAIL" "$TESTNAME cannot resolve one JSON: $NHX_JSON, check the path and specify --target if ambiguous"
  fi
  if ! NATIVE_JSON_STATE=$(mktemp -d "$LOG_DIR/native-json.XXXXXX"); then
    test_result_finish "FAIL" "$TESTNAME cannot create native JSON evidence directory in $LOG_DIR"
  fi
  if ! NHX_JSON_ARG=$(nhx_prepare_native_json "$SCRIPT_DIR" "$NHX_JSON_RESOLVED" "$NATIVE_JSON_STATE"); then
    test_result_finish "FAIL" "$TESTNAME cannot safely stage native JSON $NHX_JSON_RESOLVED, inspect staging diagnostics"
  fi
  NATIVE_TEST="$NHX_JSON_ARG"
  log_info "Native JSON source=$NHX_JSON_RESOLVED argument=$NHX_JSON_ARG, retained in $NATIVE_JSON_STATE/selected.json"
fi

log_info "$TESTNAME starting"
log_info "RUN_LOG=$RUN_LOG"
log_info "DUMP_DIR=$DUMP_DIR"
log_info "NHX_OUTDIR=$NHX_OUTDIR"
log_info "CKSUM_TOOL=${CKSUM_TOOL:-none}"

# -----------------------------------------------------------------------------
# Camera server stop before NHX
# -----------------------------------------------------------------------------
CAM_SERVER_SERVICE="$(
  systemd_service_first_existing \
    "qti-cam-server.service" \
    "cam-server.service" \
    2>/dev/null || true
)"

if [ -n "$CAM_SERVER_SERVICE" ]; then
  CAM_SERVER_PRESENT=1

  CAM_SERVER_TS_BEFORE_STOP='5 minutes ago'

  log_info "Camera server selected for NHX: $CAM_SERVER_SERVICE"
  log_info "Camera server status before NHX"
  systemd_service_status_log "Camera server BEFORE NHX (status only)" \
    "$RUN_LOG" "$CAM_SERVER_SERVICE" || true

  log_info "Camera server stdout before NHX"
  systemd_service_stdout_since "Camera server BEFORE NHX (stdout recent)" \
    "$RUN_LOG" "$CAM_SERVER_TS_BEFORE_STOP" "$CAM_SERVER_SERVICE" || true

  if systemd_service_is_active "$CAM_SERVER_SERVICE"; then
    log_info "Stopping active camera server before NHX launcher"
    CAM_SERVER_STOPPED_FOR_TEST=1

    if ! systemd_service_stop_safe "$CAM_SERVER_SERVICE"; then
      log_fail "$TESTNAME FAIL - unable to stop active $CAM_SERVER_SERVICE before NHX launcher"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi

    if systemd_service_is_active "$CAM_SERVER_SERVICE"; then
      log_fail "$TESTNAME FAIL - $CAM_SERVER_SERVICE remains active after stop request"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi

    CAM_SERVER_TS_AFTER_STOP="$(date '+%Y-%m-%d %H:%M:%S')"

    log_info "Camera server status after stop"
    systemd_service_status_log "Camera server AFTER stop (status only)" \
      "$RUN_LOG" "$CAM_SERVER_SERVICE" || true

    log_info "Camera server stdout after stop"
    systemd_service_stdout_since "Camera server AFTER stop (stdout since stop marker)" \
      "$RUN_LOG" "$CAM_SERVER_TS_AFTER_STOP" "$CAM_SERVER_SERVICE" || true
  else
    log_info "Camera server was already inactive, leaving it inactive after NHX"
  fi
else
  log_info "No qti-cam-server.service or cam-server.service present, continuing"
fi

# -----------------------------------------------------------------------------
# Run NHX
# -----------------------------------------------------------------------------
: >"$MARKER" 2>/dev/null || touch "$MARKER"

if [ "$NHX_RUNNER_MODE" = native ]; then
  NATIVE_CAPTURE_ACTIVE=1
  nhx_run_native "$NHX_RUNNER" "$NATIVE_SELECTOR" "$NATIVE_TEST" \
    "$NATIVE_FRAMES" "$NATIVE_CAMERA" "$RUN_LOG" "$LOG_DIR" "$NATIVE_MODE"
  NHX_RC=$?
  NATIVE_CAPTURE_ACTIVE=0
elif [ -n "$NHX_JSON" ]; then
  if ! command -v nhx_resolve_json_file >/dev/null 2>&1; then
    log_skip "$TESTNAME SKIP nhx_resolve_json_file helper not available"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi

  if ! command -v nhx_stage_json_for_launcher >/dev/null 2>&1; then
    log_skip "$TESTNAME SKIP nhx_stage_json_for_launcher helper not available"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi

  NHX_JSON_RESOLVED="$(nhx_resolve_json_file "$SCRIPT_DIR" "$NHX_JSON" "$NHX_TARGET" 2>/dev/null)"
  nhx_resolve_rc=$?

  if [ "$nhx_resolve_rc" -eq 2 ]; then
    log_skip "$TESTNAME SKIP requested NHX JSON matched multiple target folders; pass --target: $NHX_JSON"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi

  if [ -z "$NHX_JSON_RESOLVED" ]; then
    log_skip "$TESTNAME SKIP requested NHX JSON not found: $NHX_JSON target=${NHX_TARGET:-<unset>}"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi

  NHX_JSON_ARG="$(nhx_stage_json_for_launcher "$SCRIPT_DIR" "$NHX_JSON_RESOLVED" "$NHX_TARGET" 2>/dev/null || true)"

  if [ -z "$NHX_JSON_ARG" ]; then
    log_skip "$TESTNAME SKIP failed to stage NHX JSON for selected launcher: $NHX_JSON_RESOLVED"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi

  log_info "Launching NHX with JSON source: $NHX_JSON_RESOLVED"
  log_info "Launching NHX with JSON argument: $NHX_JSON_ARG"

  if command -v run_cmd_live_to_log >/dev/null 2>&1; then
    run_cmd_live_to_log "$RUN_LOG" "$NHX_RUNNER" "$NHX_JSON_ARG"
    NHX_RC=$?
  else
    FIFO="/tmp/${TESTNAME}.fifo.$$"
    rm -f "$FIFO" 2>/dev/null || true

    if ! mkfifo "$FIFO"; then
      log_fail "$TESTNAME FAIL mkfifo failed"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi

    ( tee "$RUN_LOG" <"$FIFO"; rm -f "$FIFO" 2>/dev/null || true ) &
    TEEPID=$!

    "$NHX_RUNNER" "$NHX_JSON_ARG" >"$FIFO" 2>&1
    NHX_RC=$?

    wait "$TEEPID" 2>/dev/null || true
  fi
else
  log_info "Launching NHX with default SoC-specific JSON"

  if command -v run_cmd_live_to_log >/dev/null 2>&1; then
    run_cmd_live_to_log "$RUN_LOG" "$NHX_RUNNER"
    NHX_RC=$?
  else
    FIFO="/tmp/${TESTNAME}.fifo.$$"
    rm -f "$FIFO" 2>/dev/null || true

    if ! mkfifo "$FIFO"; then
      log_fail "$TESTNAME FAIL mkfifo failed"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi

    ( tee "$RUN_LOG" <"$FIFO"; rm -f "$FIFO" 2>/dev/null || true ) &
    TEEPID=$!

    "$NHX_RUNNER" >"$FIFO" 2>&1
    NHX_RC=$?

    wait "$TEEPID" 2>/dev/null || true
  fi
fi

# -----------------------------------------------------------------------------
# Restore camera server state after NHX
# -----------------------------------------------------------------------------
if [ -n "$NATIVE_JSON_STATE" ]; then
  if ! nhx_restore_native_json "$NATIVE_JSON_STATE"; then
    NATIVE_JSON_RESTORE_FAILED=1
  fi
fi

if [ "$CAM_SERVER_STOPPED_FOR_TEST" -eq 1 ]; then
  log_info "Restoring camera server after NHX launcher: $CAM_SERVER_SERVICE"
  if nhx_restore_camera_service "$CAM_SERVER_SERVICE" "$LOG_DIR"; then
    CAM_SERVER_STOPPED_FOR_TEST=0
    CAM_SERVER_TS_AFTER_START="$(date '+%Y-%m-%d %H:%M:%S')"

    log_info "Camera server status after restore"
    systemd_service_status_log "Camera server AFTER restore (status only)" \
      "$RUN_LOG" "$CAM_SERVER_SERVICE" || true

    log_info "Camera server stdout after restore"
    systemd_service_stdout_since "Camera server AFTER restore (stdout since restore marker)" \
      "$RUN_LOG" "$CAM_SERVER_TS_AFTER_START" "$CAM_SERVER_SERVICE" || true
  else
    CAM_SERVER_RESTORE_FAILED=1
    log_fail "Failed to restore camera server after NHX launcher: $CAM_SERVER_SERVICE"
  fi
else
  log_info "Camera server state was not changed for NHX, skipping restore"
fi

# -----------------------------------------------------------------------------
# Dump validation
# -----------------------------------------------------------------------------
DUMP_VALIDATION_FAIL=0

if ! {
  mkdir -p "$NHX_OUTDIR" &&
    : >"$DUMPS_LIST" &&
    : >"$CHECKSUMS_TXT"
}; then
  test_result_finish "FAIL" "$TESTNAME cannot initialize capture artifacts in $NHX_OUTDIR, check permissions and free space"
fi

if [ "$NHX_RUNNER_MODE" = native ]; then
  if NATIVE_COUNTS=$(nhx_native_result_counts "$RUN_LOG" "$NATIVE_TEST" "$NATIVE_MODE"); then
    NATIVE_REPORT_VALID=1
  else
    NATIVE_RESULT_RC=$?
    NATIVE_REPORT_VALID=0
    if [ "$NATIVE_RESULT_RC" -eq 2 ]; then
      NATIVE_NO_TESTS=1
      log_fail "Native HAL executed zero tests for $NATIVE_TEST with $NHX_RUNNER, verify the selected JSON or Suite.Case is supported by this client"
      log_info "Native CLI evidence: $LOG_DIR/native-hal-help.log, no alternate testcase or full-suite run will be attempted"
    fi
  fi
fi

if [ "$NATIVE_NO_TESTS" -eq 1 ]; then
  log_info "Capture validation was not exercised because native HAL executed zero tests"
elif command -v nhx_validate_dumps_and_checksums >/dev/null 2>&1; then
  if ! nhx_validate_dumps_and_checksums "$DUMP_DIR" "$MARKER" "$NHX_OUTDIR" "$CHECKSUMS_TXT" "$CHECKSUMS_PREV" "$NHX_RUNNER_MODE"; then
    DUMP_VALIDATION_FAIL=1
  fi

  if [ ! -s "$DUMPS_LIST" ]; then
    if [ -s "$NHX_OUTDIR/nhx_dumps.list" ]; then
      DUMPS_LIST="$NHX_OUTDIR/nhx_dumps.list"
    elif [ -s "$NHX_OUTDIR/dumps.list" ]; then
      DUMPS_LIST="$NHX_OUTDIR/dumps.list"
    elif [ -s "$NHX_OUTDIR/nhx_dump.list" ]; then
      DUMPS_LIST="$NHX_OUTDIR/nhx_dump.list"
    fi
  fi
else
  : >"$DUMPS_LIST" 2>/dev/null || true

  grep -F "Saving image to file:" "$RUN_LOG" \
    | sed 's/^.*Saving image to file:[[:space:]]*//' \
    | awk 'NF{print $0}' \
    | sort -u >"$DUMPS_LIST" 2>/dev/null || true

  DUMP_COUNT="$(wc -l <"$DUMPS_LIST" 2>/dev/null | awk '{print $1}')"
  if [ -z "$DUMP_COUNT" ]; then
    DUMP_COUNT=0
  fi

  if [ "$DUMP_COUNT" -eq 0 ]; then
    log_info "No dump paths found in log scanning dump dir for new files"
    if [ -d "$DUMP_DIR" ]; then
      find "$DUMP_DIR" -type f -newer "$MARKER" 2>/dev/null | sort -u >"$DUMPS_LIST"
    fi
  fi
fi

DUMP_COUNT=0
if [ -r "$DUMPS_LIST" ]; then
  DUMP_COUNT="$(wc -l <"$DUMPS_LIST" | awk '{print $1}')"
else
  DUMP_VALIDATION_FAIL=1
  log_fail "Capture list is unavailable at $DUMPS_LIST, inspect dump validation diagnostics"
fi
if [ -z "$DUMP_COUNT" ]; then
  DUMP_COUNT=0
fi

ZERO_OR_MISSING=0
TOTAL_BYTES=0

{
  echo "========================================"
  echo "$TESTNAME Summary"
  echo "Timestamp: $TS"
  echo "NHX launcher exit code: $NHX_RC"
  echo "NHX runner: $NHX_RUNNER"
  echo "NHX runner source: $NHX_RUNNER_SOURCE"
  echo "Execution mode: $NHX_RUNNER_MODE"
  echo "Native testcase: ${NATIVE_TEST:-<not selected>}"
  if [ "$NATIVE_MODE" = json ]; then
    echo "Native capture settings: selected JSON"
    echo "Native JSON evidence: $NATIVE_JSON_STATE/selected.json"
  else
    echo "Native frames: $NATIVE_FRAMES"
    echo "Native camera: ${NATIVE_CAMERA:-<client default>}"
  fi
  echo "NHX JSON requested: ${NHX_JSON:-<default>}"
  echo "NHX target requested: ${NHX_TARGET:-<unset>}"
  echo "NHX JSON resolved: ${NHX_JSON_RESOLVED:-<default>}"
  echo "NHX JSON argument: ${NHX_JSON_ARG:-<default>}"
  echo "Dump directory: $DUMP_DIR"
  echo "Dump files detected: $DUMP_COUNT"
  echo "Log file: $RUN_LOG"
  echo "Checksum tool: ${CKSUM_TOOL:-none}"
  echo "NHX outdir: $NHX_OUTDIR"
  echo "Dump list: $DUMPS_LIST"
  echo "Checksums: $CHECKSUMS_TXT"
  echo "Prev checksums: $CHECKSUMS_PREV"
  echo "Dump validation helper fail: $DUMP_VALIDATION_FAIL"
  echo "========================================"
  echo
} >"$SUMMARY_TXT"

if [ "$DUMP_COUNT" -gt 0 ]; then
  {
    echo "Dump validation"
    echo "----------------------------------------"
  } >>"$SUMMARY_TXT"

  while IFS= read -r f; do
    [ -z "$f" ] && continue

    if [ ! -f "$f" ]; then
      ZERO_OR_MISSING=$((ZERO_OR_MISSING + 1))
      echo "MISSING: $f" >>"$SUMMARY_TXT"
      continue
    fi

    SZ="$(nhx_dump_size_bytes "$f" 2>/dev/null || printf '%s\n' "0")"
    case "$SZ" in
      ''|*[!0-9]*) SZ=0 ;;
    esac

    if [ "$SZ" -le 0 ]; then
      ZERO_OR_MISSING=$((ZERO_OR_MISSING + 1))
      echo "ZERO-BYTES: $f size=$SZ" >>"$SUMMARY_TXT"
      continue
    fi

    TOTAL_BYTES=$((TOTAL_BYTES + SZ))
    echo "OK: $f size=$SZ" >>"$SUMMARY_TXT"
  done <"$DUMPS_LIST"

  {
    echo "----------------------------------------"
    echo "Total dump bytes: $TOTAL_BYTES"
    echo "Dump issues (missing/zero): $ZERO_OR_MISSING"
    echo
  } >>"$SUMMARY_TXT"
else
  {
    echo "Dump validation"
    echo "----------------------------------------"
    echo "No dump files detected"
    echo "----------------------------------------"
    echo
  } >>"$SUMMARY_TXT"
fi

# -----------------------------------------------------------------------------
# Parse Final Report
# -----------------------------------------------------------------------------
FINAL_LINE="$(grep -F "Final Report ->" "$RUN_LOG" | tail -n 1)"

PASSED=""
FAILED=""
SKIPPED=""

if [ -n "$FINAL_LINE" ]; then
  PASSED="$(echo "$FINAL_LINE" | sed -n 's/.*\[\([0-9][0-9]*\) PASSED\].*/\1/p')"
  FAILED="$(echo "$FINAL_LINE" | sed -n 's/.*\[\([0-9][0-9]*\) FAILED\].*/\1/p')"
  SKIPPED="$(echo "$FINAL_LINE" | sed -n 's/.*\[\([0-9][0-9]*\) SKIPPED\].*/\1/p')"
fi

if [ "$NHX_RUNNER_MODE" = native ]; then
  if [ "$NATIVE_REPORT_VALID" -eq 1 ]; then
    read -r PASSED FAILED SKIPPED <<EOF
$NATIVE_COUNTS
EOF
    FINAL_LINE="Native HAL completed exactly the selected testcase: $NATIVE_TEST"
  elif [ "$NATIVE_NO_TESTS" -eq 1 ]; then
    PASSED=0
    FAILED=0
    SKIPPED=0
  else
    NATIVE_REPORT_VALID=0
  fi
fi

{
  echo "Final Report parse"
  echo "----------------------------------------"
  echo "Final line: ${FINAL_LINE:-<not found>}"
  echo "PASSED=$PASSED FAILED=$FAILED SKIPPED=$SKIPPED"
  echo "----------------------------------------"
} >>"$SUMMARY_TXT"

# -----------------------------------------------------------------------------
# Decide PASS/FAIL
# -----------------------------------------------------------------------------
RESULT="FAIL"
REASON=""

if [ -z "$FINAL_LINE" ] || [ -z "$FAILED" ] || [ -z "$PASSED" ]; then
  RESULT="FAIL"
  REASON="Final Report not found or could not parse"
else
  if [ "$FAILED" -gt 0 ]; then
    RESULT="FAIL"
    REASON="NHX reported FAILED=$FAILED"
  elif [ "$PASSED" -eq 0 ]; then
    RESULT="FAIL"
    REASON="NHX reported no passing tests"
  else
    RESULT="PASS"
    REASON="NHX reported FAILED=0"
  fi
fi

if [ "$NHX_RC" -ne 0 ]; then
  RESULT="FAIL"
  REASON="$REASON. NHX launcher exited with rc=$NHX_RC"
fi

if [ "${NATIVE_NO_TESTS:-0}" -eq 1 ]; then
  RESULT="FAIL"
  REASON="Native HAL executed zero tests for $NATIVE_TEST using $NHX_RUNNER (exit=$NHX_RC). Verify the selected JSON or Suite.Case is supported by this client, see $LOG_DIR/native-hal-help.log and $RUN_LOG. Capture validation was not exercised"
elif [ "$NATIVE_REPORT_VALID" -ne 1 ]; then
  RESULT="FAIL"
  REASON="$REASON. Native HAL did not report exactly one completed passing testcase matching $NATIVE_TEST, inspect the native stdout before changing result parsing"
fi

if [ "$CAM_SERVER_RESTORE_FAILED" -ne 0 ]; then
  RESULT="FAIL"
  REASON="$REASON. Camera-server restoration failed"
fi

if [ "${NATIVE_JSON_RESTORE_FAILED:-0}" -ne 0 ]; then
  RESULT="FAIL"
  REASON="$REASON. Native JSON cleanup failed, see $NATIVE_JSON_STATE"
fi

if [ "$ZERO_OR_MISSING" -gt 0 ]; then
  RESULT="FAIL"
  if [ -n "$REASON" ]; then
    REASON="$REASON dump issues=$ZERO_OR_MISSING"
  else
    REASON="dump issues=$ZERO_OR_MISSING"
  fi
fi

if [ "$DUMP_COUNT" -eq 0 ] && [ "${NATIVE_NO_TESTS:-0}" -eq 0 ]; then
  RESULT="FAIL"
  if [ -n "$REASON" ]; then
    REASON="$REASON no dumps detected"
  else
    REASON="no dumps detected"
  fi
fi

if [ "$DUMP_VALIDATION_FAIL" -ne 0 ]; then
  RESULT="FAIL"
  if [ -n "$REASON" ]; then
    REASON="$REASON dump checksum validation failed"
  else
    REASON="dump checksum validation failed"
  fi
fi

if [ "$RESULT" = FAIL ] && [ "${NHX_RUNNER_MODE:-wrapper}" = native ] &&
  [ -s "$DMESG_DIR/dmesg_errors.log" ]; then
  log_warn "Camera warnings/errors were already present before native capture, see $DMESG_DIR/dmesg_errors.log"
  log_warn "Firmware file presence does not prove a successful ICP load. Pre-run messages alone do not establish the cause of this invocation failure"
  REASON="$REASON. Pre-run camera diagnostics: $DMESG_DIR/dmesg_errors.log"
fi

log_info "========================================"
log_info "$TESTNAME final"
log_info "Final Report PASSED=${PASSED:-?} FAILED=${FAILED:-?} SKIPPED=${SKIPPED:-?}"
log_info "Dumps detected=$DUMP_COUNT issues=$ZERO_OR_MISSING total_bytes=$TOTAL_BYTES"
log_info "Dump validation helper fail=$DUMP_VALIDATION_FAIL"
log_info "Summary $SUMMARY_TXT"
log_info "Log $RUN_LOG"
log_info "Decision $RESULT $REASON"
log_info "========================================"

test_result_finish "$RESULT" "$TESTNAME $RESULT $REASON"
