#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Camera NHX validation

TESTNAME="Camera_NHX"

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

RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"

if [ -z "${INIT_ENV:-}" ]; then
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
. "$TOOLS/lib_system.sh"

# shellcheck disable=SC1090,SC1091
. "$TOOLS/camera/lib_camera.sh"

if [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$TOOLS/lib_pkg_provider.sh"
fi

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

NHX_JSON="${NHX_JSON:-}"
NHX_TARGET="${NHX_TARGET:-}"
NHX_RUNNER=""
NHX_RUNNER_SOURCE=""
NHX_JSON_RESOLVED=""
NHX_JSON_ARG=""
OVERLAY_REQUESTED=0
FIT_DTB_NAME=""
FIT_DTB_SOURCE=""
CAMX_FIT_DTB_SELECTED=0

# shellcheck disable=SC2317
cleanup() {
  if command -v efi_restore_efivarfs_ro >/dev/null 2>&1; then
    efi_restore_efivarfs_ro >/dev/null 2>&1 || true
  fi

  if [ "$CAM_SERVER_STOPPED_FOR_TEST" -eq 1 ] && [ "$CAM_SERVER_PRESENT" -eq 1 ]; then
    systemd_service_start_safe "$CAM_SERVER_SERVICE" >/dev/null 2>&1 || true
  fi

  if [ -n "${MARKER:-}" ]; then
    rm -f "$MARKER"
  fi
}

trap 'cleanup' EXIT INT TERM

usage() {
  cat <<EOF
Usage: $0 [--overlay] [--fit-dtb NAME] [--json JSON_FILE] [--target TARGET] [--help]

Options:
  --overlay        Install the Camera NHX CAMX package set on supported
                   Debian, Ubuntu, or CentOS images and ensure the CAMX FIT
                   DTB is selected for boot.
  --fit-dtb NAME    Select this FIT DTB compatibility name for the next boot.
                   Camera_NHX supports camx, which is the --overlay default.
                   This option requires --overlay.
  --json JSON_FILE NHX JSON file to pass to nhx.sh.
                     Can be absolute, relative to Camera_NHX/, or relative
                     to target folder when --target is provided.
  --target TARGET Target folder name: Kodiak, Lemans, Monaco, Talos.
                     Used to resolve/stage --json under /etc/camera/test/NHX.
  --help Show this help.

Examples:
  $0
  $0 --overlay
  $0 --overlay --fit-dtb camx
  $0 --json Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
  $0 --json Snapshot_YUVNV12_MaxResolution_NHX.json --target Kodiak
  NHX_JSON=Talos/Video_YUVNV12_MaxResolution_NHX.json $0
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    pkg_ensure_optional_package_set_present \
    pkg_verify_package_set_installed; do
    if ! command -v "$required_helper" >/dev/null 2>&1; then
      log_fail "$TESTNAME FAIL - required package helper is unavailable: $required_helper"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi
  done

  pkg_provider_init

  if ! pkg_ensure_optional_package_set_present \
    camera-nhx \
    qli-staging \
    auto \
    --overlay; then
    log_fail "$TESTNAME FAIL - failed to ensure Camera NHX CAMX package set"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
  fi

  log_pass "Camera NHX CAMX package set is ready"

  CAMX_OVERLAY_OS_ID="$(pkg_detect_os_id 2>/dev/null || true)"
  case "$CAMX_OVERLAY_OS_ID" in
    debian|ubuntu|centos)
      for required_helper in \
        efi_find_variable_by_name \
        efi_text_variable_matches \
        efi_write_text_variable \
        efi_restore_efivarfs_ro; do
        if ! command -v "$required_helper" >/dev/null 2>&1; then
          log_fail "$TESTNAME FAIL - required EFI helper is unavailable: $required_helper"
          echo "$TESTNAME FAIL" >"$RES_FILE"
          exit 0
        fi
      done

      if ! CHECK_DEPS_NO_EXIT=1 check_dependencies efivar mount mktemp od tr sed grep sync awk; then
        log_skip "$TESTNAME SKIP - CAMX FIT DTB verification requires efivar and EFI runtime tools"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi

      CAMX_DTB_OVERLAY_VARIABLE="$(efi_find_variable_by_name \
        VendorDtbOverlays \
        "$CAMX_EFI_LIST_LOG" 2>>"$CAMX_EFI_LOG")"
      if [ -z "$CAMX_DTB_OVERLAY_VARIABLE" ]; then
        log_skip "$TESTNAME SKIP - VendorDtbOverlays EFI variable was not found"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi

      log_info "CAMX FIT DTB EFI variable selected: $CAMX_DTB_OVERLAY_VARIABLE"

      if efi_text_variable_matches \
        "$CAMX_DTB_OVERLAY_VARIABLE" \
        "$FIT_DTB_NAME" \
        "$CAMX_EFI_LOG"; then
        CAMX_FIT_DTB_SELECTED=1
        log_pass "CAMX FIT DTB is selected in EFI, value=$FIT_DTB_NAME"
        log_info "Continuing with runtime DT and camera module validation"
      else
        log_info "Selecting CAMX FIT DTB for the next boot, value=$FIT_DTB_NAME"

        if ! efi_write_text_variable \
          "$CAMX_DTB_OVERLAY_VARIABLE" \
          "$FIT_DTB_NAME" \
          "$CAMX_EFI_LOG"; then
          log_fail "$TESTNAME FAIL - could not select CAMX FIT DTB in EFI"
          echo "$TESTNAME FAIL" >"$RES_FILE"
          exit 0
        fi

        log_skip "$TESTNAME SKIP - CAMX FIT DTB selected for the next boot, reboot the target manually and rerun Camera_NHX"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      ;;
    *)
      log_info "CAMX device-tree overlay selection is not applicable, os=${CAMX_OVERLAY_OS_ID:-unknown}"
      ;;
  esac
else
  log_info "Camera NHX overlay package installation not requested"
fi

# -----------------------------------------------------------------------------
# Deps check
# -----------------------------------------------------------------------------
deps_list="date awk sed grep tee wc ls find stat rm tr head tail dmesg sort fdtdump mkfifo sha256sum md5sum cksum diff cp mkdir"
if ! check_dependencies "$deps_list"; then
  log_skip "$TESTNAME SKIP missing one or more dependencies: $deps_list"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

NHX_RUNNER="$(command -v nhx.sh 2>/dev/null || true)"
if [ -n "$NHX_RUNNER" ] && [ -f "$NHX_RUNNER" ] && [ -x "$NHX_RUNNER" ]; then
  NHX_RUNNER_SOURCE="PATH"
elif [ -f "/usr/libexec/camx/nhx.sh" ] && [ -x "/usr/libexec/camx/nhx.sh" ]; then
  NHX_RUNNER="/usr/libexec/camx/nhx.sh"
  NHX_RUNNER_SOURCE="packaged-libexec"
else
  log_skip "$TESTNAME SKIP nhx.sh not found in PATH or /usr/libexec/camx"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

log_info "NHX runner selected, path=$NHX_RUNNER source=$NHX_RUNNER_SOURCE"

# -----------------------------------------------------------------------------
# CAMX prechecks
# -----------------------------------------------------------------------------
log_info "Checking CAMX proprietary prerequisites before running NHX"

log_info "DT check"

PATTERNS="qcom,cam-sensor qcom,cam-gmsl-sensor qcom,cam-gmsl-deserializer qcom,eeprom qcom,cci qcom,csiphy qcom,cam-tpg1031 qcom,camera qcom,cam camera_kt cam-req-mgr cam-cpas cam-jpeg cam-ife cam-icp camera0-thermal"
found_any=0
missing_list=""

for pat in $PATTERNS; do
  out="$(dt_confirm_node_or_compatible "$pat" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    found_any=1
  else
    if [ -n "$missing_list" ]; then
      missing_list="$missing_list, $pat"
    else
      missing_list="$pat"
    fi
  fi
done

if [ "$found_any" -ne 1 ]; then
  log_skip "$TESTNAME SKIP missing DT patterns $missing_list"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

log_info "fdtdump camera nodes sample"

FDT_MATCHES="$(camx_fdtdump_has_cam_nodes 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 2 ]; then
    log_skip "$TESTNAME SKIP fdtdump not available"
  else
    log_skip "$TESTNAME SKIP fdtdump did not show conclusive camera nodes"
  fi
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

printf '%s\n' "$FDT_MATCHES" | while IFS= read -r l; do
  if [ -n "$l" ]; then
    log_info " $l"
  fi
done

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
    log_skip "$TESTNAME SKIP - CAMX FIT DTB is selected in EFI but $CAM_MOD is not loaded, reboot the target manually and rerun Camera_NHX"
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

log_info "sensor presence warn-only NHX may still work without cam sensors"

SENSOR_COUNT="$(libcam_list_sensors_count 2>/dev/null || true)"
case "$SENSOR_COUNT" in
  ''|*[!0-9]*) SENSOR_COUNT=0 ;;
esac
log_info "cam list detected $SENSOR_COUNT cameras"
if [ "$SENSOR_COUNT" -lt 1 ]; then
  log_warn "No sensors reported by cam list continuing"
fi

CKSUM_TOOL=""
if command -v nhx_pick_cksum_tool >/dev/null 2>&1; then
  CKSUM_TOOL="$(nhx_pick_cksum_tool)"
else
  if command -v sha256sum >/dev/null 2>&1; then
    CKSUM_TOOL="sha256sum"
  elif command -v md5sum >/dev/null 2>&1; then
    CKSUM_TOOL="md5sum"
  elif command -v cksum >/dev/null 2>&1; then
    CKSUM_TOOL="cksum"
  fi
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
    log_info "Stopping active camera server before nhx.sh"

    if ! systemd_service_stop_safe "$CAM_SERVER_SERVICE"; then
      log_fail "$TESTNAME FAIL - unable to stop active $CAM_SERVER_SERVICE before nhx.sh"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi

    if systemd_service_is_active "$CAM_SERVER_SERVICE"; then
      log_fail "$TESTNAME FAIL - $CAM_SERVER_SERVICE remains active after stop request"
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 0
    fi

    CAM_SERVER_STOPPED_FOR_TEST=1
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

if [ -n "$NHX_JSON" ]; then
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
    log_skip "$TESTNAME SKIP failed to stage NHX JSON for nhx.sh: $NHX_JSON_RESOLVED"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi

  log_info "Launching nhx.sh with JSON source: $NHX_JSON_RESOLVED"
  log_info "Launching nhx.sh with JSON argument: $NHX_JSON_ARG"

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
  log_info "Launching nhx.sh with default SoC-specific JSON"

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
if [ "$CAM_SERVER_STOPPED_FOR_TEST" -eq 1 ]; then
  log_info "Restoring camera server after nhx.sh: $CAM_SERVER_SERVICE"
  if systemd_service_start_safe "$CAM_SERVER_SERVICE"; then
    CAM_SERVER_STOPPED_FOR_TEST=0
    CAM_SERVER_TS_AFTER_START="$(date '+%Y-%m-%d %H:%M:%S')"

    log_info "Camera server status after restore"
    systemd_service_status_log "Camera server AFTER restore (status only)" \
      "$RUN_LOG" "$CAM_SERVER_SERVICE" || true

    log_info "Camera server stdout after restore"
    systemd_service_stdout_since "Camera server AFTER restore (stdout since restore marker)" \
      "$RUN_LOG" "$CAM_SERVER_TS_AFTER_START" "$CAM_SERVER_SERVICE" || true
  else
    log_warn "Failed to restore camera server after nhx.sh: $CAM_SERVER_SERVICE"
  fi
else
  log_info "Camera server state was not changed for NHX, skipping restore"
fi

# -----------------------------------------------------------------------------
# Dump validation
# -----------------------------------------------------------------------------
DUMP_VALIDATION_FAIL=0

mkdir -p "$NHX_OUTDIR" 2>/dev/null || true

if command -v nhx_validate_dumps_and_checksums >/dev/null 2>&1; then
  if ! nhx_validate_dumps_and_checksums "$DUMP_DIR" "$MARKER" "$NHX_OUTDIR" "$CHECKSUMS_TXT" "$CHECKSUMS_PREV"; then
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

DUMP_COUNT="$(wc -l <"$DUMPS_LIST" 2>/dev/null | awk '{print $1}')"
if [ -z "$DUMP_COUNT" ]; then
  DUMP_COUNT=0
fi

ZERO_OR_MISSING=0
TOTAL_BYTES=0

{
  echo "========================================"
  echo "$TESTNAME Summary"
  echo "Timestamp: $TS"
  echo "nhx.sh exit code: $NHX_RC"
  echo "NHX runner: $NHX_RUNNER"
  echo "NHX runner source: $NHX_RUNNER_SOURCE"
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
  else
    RESULT="PASS"
    REASON="NHX reported FAILED=0"
  fi
fi

if [ "$ZERO_OR_MISSING" -gt 0 ]; then
  RESULT="FAIL"
  if [ -n "$REASON" ]; then
    REASON="$REASON dump issues=$ZERO_OR_MISSING"
  else
    REASON="dump issues=$ZERO_OR_MISSING"
  fi
fi

if [ "$DUMP_COUNT" -eq 0 ]; then
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

log_info "========================================"
log_info "$TESTNAME final"
log_info "Final Report PASSED=${PASSED:-?} FAILED=${FAILED:-?} SKIPPED=${SKIPPED:-?}"
log_info "Dumps detected=$DUMP_COUNT issues=$ZERO_OR_MISSING total_bytes=$TOTAL_BYTES"
log_info "Dump validation helper fail=$DUMP_VALIDATION_FAIL"
log_info "Summary $SUMMARY_TXT"
log_info "Log $RUN_LOG"
log_info "Decision $RESULT $REASON"
log_info "========================================"

if [ "$RESULT" = "PASS" ]; then
  log_pass "$TESTNAME PASS $REASON"
  echo "$TESTNAME PASS" >"$RES_FILE"
else
  log_fail "$TESTNAME FAIL $REASON"
  echo "$TESTNAME FAIL" >"$RES_FILE"
fi

exit 0
