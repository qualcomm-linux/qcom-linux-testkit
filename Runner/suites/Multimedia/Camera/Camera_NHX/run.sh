#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
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
. "$TOOLS/camera/lib_camera.sh"

LOG_DIR="$SCRIPT_DIR/logs"
OUT_DIR="$SCRIPT_DIR/out"
DUMP_DIR="/var/cache/camera/nativehaltest"

mkdir -p "$LOG_DIR" "$OUT_DIR"

TS=$(date "+%Y%m%d_%H%M%S")
RUN_LOG="$LOG_DIR/${TESTNAME}_${TS}.log"
SUMMARY_TXT="$OUT_DIR/${TESTNAME}_summary_${TS}.txt"
DMESG_DIR="$LOG_DIR/dmesg_${TS}"

# NHX helper output directory (IMPORTANT: lib_camera.sh expects a directory, not a file)
NHX_OUTDIR="$OUT_DIR/nhx_${TS}"

# dump list & checksum artifacts (produced by dump validation helper)
DUMPS_LIST="$NHX_OUTDIR/nhx_dumps.list"
CHECKSUMS_TXT="$NHX_OUTDIR/nhx_checksums.txt"
CHECKSUMS_PREV="$OUT_DIR/${TESTNAME}_checksums.prev.txt"

MARKER="$(mktemp "/tmp/${TESTNAME}.marker.XXXXXX" 2>/dev/null)"
if [ -z "$MARKER" ]; then
  MARKER="/tmp/${TESTNAME}.marker.$$"
  : >"$MARKER" 2>/dev/null || true
fi

cleanup() { rm -f "$MARKER" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Deps check (functestlib.sh provides check_dependencies)
# -----------------------------------------------------------------------------
deps_list="date awk sed grep tee wc ls find stat rm tr head tail dmesg sort opkg fdtdump mkfifo sha256sum md5sum cksum diff cp"
if ! check_dependencies "$deps_list"; then
  log_skip "$TESTNAME SKIP missing one or more dependencies: $deps_list"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if ! command -v nhx.sh >/dev/null 2>&1; then
  log_skip "$TESTNAME SKIP nhx.sh not found in PATH"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# -----------------------------------------------------------------------------
# CAMX prechecks
# Sequence:
# 1) DT check
# 2) fdtdump camera nodes sample
# 3) driver load checks
# 4) packages present
# 5) sensor presence warn-only
# -----------------------------------------------------------------------------
log_info "Checking CAMX proprietary prerequisites before running NHX"

# -----------------------------
# 1) DT check
# -----------------------------
log_info "DT check"

PATTERNS="qcom,cam qcom,camera camera_kt cam-req-mgr cam-cpas cam-jpeg cam-ife cam-icp cam-sensor camera0-thermal"
found_any=0
missing_list=""

for pat in $PATTERNS; do
  out="$(dt_confirm_node_or_compatible "$pat" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    found_any=1
  else
    # Explicit append logic (reviewer-friendly; avoids &&/|| ambiguity)
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

# -----------------------------
# 2) fdtdump camera nodes sample
# -----------------------------
log_info "fdtdump camera nodes sample"

FDT_MATCHES="$(camx_fdtdump_has_cam_nodes 2>/dev/null || true)"
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
  [ -n "$l" ] && log_info " $l"
done

# -----------------------------
# 3) driver load checks
# -----------------------------
log_info "driver load checks"

CAM_MOD=""

if command -v lsmod >/dev/null 2>&1; then
  CAM_MOD="$(lsmod 2>/dev/null | awk '{print $1}' \
    | grep -E '^(camera_qc|camera_qcm|camera_qcs)' \
    | head -n 1 || true)"
fi

if [ -z "$CAM_MOD" ]; then
  kver="$(uname -r 2>/dev/null || true)"
  if [ -n "$kver" ] && [ -d "/lib/modules/$kver" ]; then
    ko="$(find "/lib/modules/$kver" -type f \( -name 'camera_qc*.ko' -o -name 'camera_qcm*.ko' -o -name 'camera_qcs*.ko' \) \
      2>/dev/null | head -n 1 || true)"
    CAM_MOD="$(basename "${ko:-}" .ko)"
  fi
fi

if [ -z "$CAM_MOD" ]; then
  log_skip "$TESTNAME SKIP could not determine camera module name"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

CAM_KO="$(find_kernel_module "$CAM_MOD" 2>/dev/null || true)"
if [ -z "$CAM_KO" ] || [ ! -f "$CAM_KO" ]; then
  log_skip "$TESTNAME SKIP camera module artifact not found ${CAM_MOD}.ko"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "Camera module artifact found $CAM_KO"

if ! check_driver_loaded "$CAM_MOD" 2>/dev/null; then
  log_skip "$TESTNAME SKIP camera module not loaded $CAM_MOD"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "Camera module is loaded $CAM_MOD"

ICP_FW="$(camx_find_icp_firmware 2>/dev/null || true)"
if [ -z "$ICP_FW" ] || [ ! -f "$ICP_FW" ]; then
  log_skip "$TESTNAME SKIP CAMERA_ICP firmware not found"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "ICP firmware found $ICP_FW"

# dmesg collection and error scan
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
  if grep -F "CAM_INFO: CAM-ICP: cam_a5_download_fw" "$DM_SNAP" 2>/dev/null \
     | grep -F "$FW_BASENAME" >/dev/null 2>&1; then
    FW_DL_OK=1
  fi
  if grep -F "CAM_INFO: CAM-ICP: cam_icp_mgr_hw_open" "$DM_SNAP" 2>/dev/null \
     | grep -F "FW download done successfully" >/dev/null 2>&1; then
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
  case "$bind_cnt" in ''|*[!0-9]*) bind_cnt=0 ;; esac
fi

if [ "$bind_cnt" -lt 5 ]; then
  log_skip "$TESTNAME SKIP CAMX bind graph not observed"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "CAMX bind graph observed"

# -----------------------------
# 4) packages present
# -----------------------------
log_info "packages present"

CAMX_PKGS="$(camx_opkg_list_camx 2>/dev/null || true)"
if [ -z "$CAMX_PKGS" ]; then
  log_skip "$TESTNAME SKIP CAMX packages not installed"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

log_info "CAMX packages detected"
printf '%s\n' "$CAMX_PKGS" | while IFS= read -r l; do
  [ -n "$l" ] && log_info " $l"
done

# -----------------------------
# 5) sensor presence warn-only
# -----------------------------
log_info "sensor presence warn-only NHX may still work without cam sensors"

SENSOR_COUNT="$(libcam_list_sensors_count 2>/dev/null || true)"
case "$SENSOR_COUNT" in ''|*[!0-9]*) SENSOR_COUNT=0 ;; esac
log_info "cam list detected $SENSOR_COUNT cameras"
if [ "$SENSOR_COUNT" -lt 1 ]; then
  log_warn "No sensors reported by cam list continuing"
fi

# -----------------------------------------------------------------------------
# Pick checksum tool (prefer helper in lib_camera.sh)
# -----------------------------------------------------------------------------
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
# Run NHX
# -----------------------------------------------------------------------------
: >"$MARKER" 2>/dev/null || touch "$MARKER"

log_info "Launching nhx.sh"

if command -v run_cmd_live_to_log >/dev/null 2>&1; then
  run_cmd_live_to_log "$RUN_LOG" nhx.sh
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

  nhx.sh >"$FIFO" 2>&1
  NHX_RC=$?

  wait "$TEEPID" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Dump validation (delegate to lib_camera.sh helper)
# IMPORTANT: helper expects an output DIRECTORY, not a file path.
# -----------------------------------------------------------------------------
DUMP_VALIDATION_FAIL=0

# Ensure output directory exists regardless of helper/fallback
mkdir -p "$NHX_OUTDIR" 2>/dev/null || true

if command -v nhx_validate_dumps_and_checksums >/dev/null 2>&1; then
  # nhx_validate_dumps_and_checksums <dump_dir> <marker_file> <out_dir> <out_checksums> <prev_checksums>
  if ! nhx_validate_dumps_and_checksums "$DUMP_DIR" "$MARKER" "$NHX_OUTDIR" "$CHECKSUMS_TXT" "$CHECKSUMS_PREV"; then
    DUMP_VALIDATION_FAIL=1
  fi

  # If helper generated a different list name, keep our expected path working.
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
  # fallback: old behavior
  : >"$DUMPS_LIST" 2>/dev/null || true

  grep -F "Saving image to file:" "$RUN_LOG" \
    | sed 's/^.*Saving image to file:[[:space:]]*//' \
    | awk 'NF{print $0}' \
    | sort -u >"$DUMPS_LIST" 2>/dev/null || true

  DUMP_COUNT="$(wc -l <"$DUMPS_LIST" 2>/dev/null | awk '{print $1}')"
  [ -n "$DUMP_COUNT" ] || DUMP_COUNT=0

  if [ "$DUMP_COUNT" -eq 0 ]; then
    log_info "No dump paths found in log scanning dump dir for new files"
    if [ -d "$DUMP_DIR" ]; then
      find "$DUMP_DIR" -type f -newer "$MARKER" 2>/dev/null | sort -u >"$DUMPS_LIST"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Compute dump count (based on DUMPS_LIST produced by helper/fallback)
# -----------------------------------------------------------------------------
DUMP_COUNT="$(wc -l <"$DUMPS_LIST" 2>/dev/null | awk '{print $1}')"
[ -n "$DUMP_COUNT" ] || DUMP_COUNT=0

# -----------------------------------------------------------------------------
# Validate dumps (summary-side size scan; checksum is already done by helper)
# -----------------------------------------------------------------------------
ZERO_OR_MISSING=0
TOTAL_BYTES=0

{
  echo "========================================"
  echo "$TESTNAME Summary"
  echo "Timestamp: $TS"
  echo "nhx.sh exit code: $NHX_RC"
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
    # Clear, reviewer-friendly empty-line skip
    [ -z "$f" ] && continue

    if [ ! -f "$f" ]; then
      ZERO_OR_MISSING=$((ZERO_OR_MISSING + 1))
      echo "MISSING: $f" >>"$SUMMARY_TXT"
      continue
    fi

    SZ="$(stat -c %s "$f" 2>/dev/null)"
    if [ -z "$SZ" ]; then
      SZ="$(wc -c <"$f" 2>/dev/null | awk '{print $1}')"
    fi
    [ -n "$SZ" ] || SZ=0

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
