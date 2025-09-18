#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# libcamera 'cam' runner with strong post-capture validation (CLI-config only)
# ---------- Repo env + helpers (single-pass) ----------
SCRIPT_DIR=$(cd "$(dirname "$0")" || exit 1; pwd)
SEARCH="$SCRIPT_DIR"
INIT_ENV="${INIT_ENV:-}"
LIBCAM_PATH="${LIBCAM_PATH:-}"

# Find init_env quickly (single upward walk)
while [ "$SEARCH" != "/" ] && [ -z "$INIT_ENV" ]; do
    [ -f "$SEARCH/init_env" ] && INIT_ENV="$SEARCH/init_env" && break
    SEARCH=${SEARCH%/*}
done

if [ -z "$INIT_ENV" ]; then
    printf '%s\n' "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

# Prefer direct repo-root locations for lib_camera.sh
if [ -z "$LIBCAM_PATH" ]; then
    REPO_ROOT=$(dirname "$INIT_ENV")
    for cand in \
        "$REPO_ROOT/Runner/utils/camera/lib_camera.sh" \
        "$REPO_ROOT/utils/camera/lib_camera.sh"
    do
        [ -f "$cand" ] && { LIBCAM_PATH="$cand"; break; }
    done
fi

# Fallback upward walk only if still not found
if [ -z "$LIBCAM_PATH" ]; then
    SEARCH="$SCRIPT_DIR"
    while [ "$SEARCH" != "/" ]; do
        for cand in \
            "$SEARCH/Runner/utils/camera/lib_camera.sh" \
            "$SEARCH/utils/camera/lib_camera.sh"
        do
            [ -f "$cand" ] && { LIBCAM_PATH="$cand"; break 2; }
        done
        SEARCH=${SEARCH%/*}
    done
fi

if [ -z "$LIBCAM_PATH" ]; then
    if command -v log_error >/dev/null 2>&1; then
        log_error "lib_camera.sh not found (searched under Runner/utils/camera and utils/camera)"
    else
        printf '%s\n' "ERROR: lib_camera.sh not found (searched under Runner/utils/camera and utils/camera)" >&2
    fi
    exit 1
fi

# shellcheck source=../../../../utils/camera/lib_camera.sh disable=SC1091
. "$LIBCAM_PATH"

TESTNAME="Libcamera_cam"
RES_FILE="./${TESTNAME}.res"
: > "$RES_FILE"

# ---------- Defaults (override via CLI only) ----------
CAM_INDEX="auto" # --index <n>|all|n,m,k ; auto = first from `cam -l`
CAPTURE_COUNT="10" # --count <n>
OUT_DIR="./cam_out" # --out <dir>
SAVE_AS_PPM="no" # --ppm | --bin
CAM_EXTRA_ARGS="" # --args "<cam args>"

# Validation knobs
SEQ_STRICT="yes" # --no-strict to relax
ERR_STRICT="yes" # --no-strict to relax
DUP_MAX_RATIO="0.5" # --dup-max-ratio <0..1>
BIN_TOL_PCT="5" # --bin-tol-pct <int %>
PPM_SAMPLE_BYTES="65536"
BIN_SAMPLE_BYTES="65536"

print_usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --index N|all|n,m Camera index (default: auto from 'cam -l'; 'all' = run every camera)
  --count N Frames to capture (default: 10)
  --out DIR Output directory (default: ./cam_out)
  --ppm Save as PPM files (frame-#.ppm)
  --bin Save as BIN files (default; frame-#.bin)
  --args "STR" Extra arguments passed to 'cam' (e.g. -s width=1280,height=720,role=viewfinder)
  --strict Enforce strict validation (default)
  --no-strict Relax validation (no seq/err strictness)
  --dup-max-ratio R Fail if max duplicate bucket / total > R (default: 0.5)
  --bin-tol-pct P BIN size tolerance vs bytesused in % (default: 5)
  -h, --help Show this help
EOF
}

# ---------- CLI ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --index) shift; CAM_INDEX="$1" ;;
        --count) shift; CAPTURE_COUNT="$1" ;;
        --out) shift; OUT_DIR="$1" ;;
        --ppm) SAVE_AS_PPM="yes" ;;
        --bin) SAVE_AS_PPM="no" ;;
        --args) shift; CAM_EXTRA_ARGS="$1" ;;
        --strict) SEQ_STRICT="yes"; ERR_STRICT="yes" ;;
        --no-strict) SEQ_STRICT="no"; ERR_STRICT="no" ;;
        --dup-max-ratio) shift; DUP_MAX_RATIO="$1" ;;
        --bin-tol-pct) shift; BIN_TOL_PCT="$1" ;;
        -h|--help) print_usage; exit 0 ;;
        *) log_warn "Unknown option: $1"; print_usage; exit 2 ;;
    esac
    shift
done

# ---------- DT / platform readiness ----------
# Print both sensor and CAMSS/ISP matches if they exist; skip only if neither is present.
log_info "Verifying the availability of DT nodes, this process may take some time."
 
PATTERNS="sony,imx577 imx577 isp cam camss"
found_any=0
missing_list=""
 
for pat in $PATTERNS; do
  out="$(dt_confirm_node_or_compatible "$pat" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    found_any=1
  else
    [ -n "$missing_list" ] && missing_list="$missing_list, $pat" || missing_list="$pat"
  fi
done
 
if [ "$found_any" -eq 1 ]; then
  log_info "DT nodes present (see matches above)."
else
  log_skip "$TESTNAME SKIP – missing DT patterns: $missing_list"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# ---------- Dependencies ----------
log_info "Reviewing the dependencies needed to run the cam test."
check_dependencies cam || {
    log_error "cam utility not found"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
}
# nice-to-haves for validation
check_dependencies awk sed grep sort cut tr wc find stat head tail dd || true
(check_dependencies sha256sum || check_dependencies md5sum) || true

# ---------- Setup ----------
mkdir -p "$OUT_DIR" 2>/dev/null || true
RUN_TS="$(date -u +%Y%m%d-%H%M%S)"

log_info "Test: $TESTNAME"
log_info "OUT_DIR=$OUT_DIR | COUNT=$CAPTURE_COUNT | SAVE_AS_PPM=$SAVE_AS_PPM"
log_info "Extra args: ${CAM_EXTRA_ARGS:-<none>}"

# ---- IPA workaround: disable simple/uncalibrated to avoid buffer allocation failures ----
UNCALIB="/usr/share/libcamera/ipa/simple/uncalibrated.yaml"
if [ -f "$UNCALIB" ]; then
    log_info "Renaming $UNCALIB -> ${UNCALIB}.bk to avoid IPA buffer allocation issues"
    mv "$UNCALIB" "${UNCALIB}.bk" 2>/dev/null || log_warn "Failed to rename $UNCALIB (continuing)"
elif [ -f "${UNCALIB}.bk" ]; then
    # Already renamed in a previous run; just log for clarity
    log_info "IPA workaround already applied: ${UNCALIB}.bk present"
fi

# ---------- Sensor presence ----------
SENSOR_COUNT="$(libcam_list_sensors_count 2>/dev/null)"
# harden: ensure numeric
case "$SENSOR_COUNT" in ''|*[!0-9]*) SENSOR_COUNT=0 ;; esac
log_info "[cam -l] detected ${SENSOR_COUNT} camera(s)"
 
if [ "$SENSOR_COUNT" -lt 1 ]; then
    log_skip "No sensors reported by 'cam -l' - marking SKIP"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi
 

# ---------- Resolve indices (supports: auto | all | 0,2,5) ----------
INDICES="$(libcam_resolve_indices "$CAM_INDEX")"
if [ -z "$INDICES" ]; then
    log_skip "No valid camera indices resolved (cam -l empty?) - SKIP"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi
log_info "Resolved indices: $INDICES"

OVERALL_PASS=1
ANY_RC_NONZERO=0
PASS_LIST=""
FAIL_LIST=""
: > "$OUT_DIR/summary.txt"

for IDX in $INDICES; do
    # Per-camera logs & output dir
    CAM_DIR="${OUT_DIR%/}/cam${IDX}"
    mkdir -p "$CAM_DIR" 2>/dev/null || true
    RUN_LOG="${CAM_DIR%/}/cam-run-${RUN_TS}-cam${IDX}.log"
    INFO_LOG="${CAM_DIR%/}/cam-info-${RUN_TS}-cam${IDX}.log"

    log_info "---- Camera idx: $IDX ----"
    {
        echo "== cam -l =="
        cam -l || true
        echo
        echo "== cam -I (index $IDX) =="
        cam -c "$IDX" -I || true
    } >"$INFO_LOG" 2>&1

    # Capture
    FILE_TARGET="$CAM_DIR/"
    [ "$SAVE_AS_PPM" = "yes" ] && FILE_TARGET="$CAM_DIR/frame-#.ppm"

    log_info "cmd:"
    log_info " cam -c $IDX --capture=$CAPTURE_COUNT \\"
    log_info " --file=\"$FILE_TARGET\" ${CAM_EXTRA_ARGS:+\\}"
    [ -n "$CAM_EXTRA_ARGS" ] && log_info " $CAM_EXTRA_ARGS"

    # shellcheck disable=SC2086
    ( cam -c "$IDX" --capture="$CAPTURE_COUNT" --file="$FILE_TARGET" $CAM_EXTRA_ARGS ) \
       >"$RUN_LOG" 2>&1
    RC=$?

    tail -n 50 "$RUN_LOG" | sed "s/^/[cam idx $IDX] /"

    # Per-camera validation
    BIN_COUNT=$(find "$CAM_DIR" -maxdepth 1 -type f -name 'frame-*.bin' | wc -l | tr -d ' ')
    PPM_COUNT=$(find "$CAM_DIR" -maxdepth 1 -type f -name 'frame-*.ppm' | wc -l | tr -d ' ')
    TOTAL=$((BIN_COUNT + PPM_COUNT))
    log_info "[idx $IDX] Produced files: bin=$BIN_COUNT ppm=$PPM_COUNT total=$TOTAL (requested $CAPTURE_COUNT)"

    PASS=1
    [ "$TOTAL" -ge "$CAPTURE_COUNT" ] || { log_warn "[idx $IDX] Fewer files than requested"; PASS=0; }

    SEQ_REPORT="$(libcam_log_seqs "$RUN_LOG" | wc -l | tr -d ' ')"
    [ "$SEQ_REPORT" -ge "$CAPTURE_COUNT" ] || { log_warn "[idx $IDX] cam log shows fewer seq lines ($SEQ_REPORT) than requested ($CAPTURE_COUNT)"; PASS=0; }

    if [ "$SEQ_STRICT" = "yes" ]; then
        CSUM="$(libcam_log_seqs "$RUN_LOG" | libcam_check_contiguous 2>&1)"
        echo "$CSUM" | sed 's/^/[seq] /'
        echo "$CSUM" | grep -q 'MISSING=0' || { log_warn "[idx $IDX] non-contiguous sequences in log"; PASS=0; }
    fi

    libcam_files_and_seq "$CAM_DIR" "$SEQ_STRICT" || PASS=0
    libcam_validate_content "$CAM_DIR" "$RUN_LOG" "$PPM_SAMPLE_BYTES" "$BIN_SAMPLE_BYTES" "$BIN_TOL_PCT" "$DUP_MAX_RATIO" || PASS=0
    libcam_scan_errors "$RUN_LOG" "$ERR_STRICT" || PASS=0

    [ $RC -eq 0 ] || { ANY_RC_NONZERO=1; PASS=0; }

    if [ "$PASS" -eq 1 ]; then
        log_pass "[idx $IDX] PASS"
        PASS_LIST="$PASS_LIST $IDX"
        echo "cam$IDX PASS" >> "$OUT_DIR/summary.txt"
    else
        log_fail "[idx $IDX] FAIL"
        FAIL_LIST="$FAIL_LIST $IDX"
        echo "cam$IDX FAIL" >> "$OUT_DIR/summary.txt"
        OVERALL_PASS=0
    fi
done

# ---------- Per-camera summary (always printed) ----------
pass_trim="$(printf '%s' "$PASS_LIST" | sed 's/^ //')"
fail_trim="$(printf '%s' "$FAIL_LIST" | sed 's/^ //')"
log_info "---------- Per-camera summary ----------"
if [ -n "$pass_trim" ]; then
    log_info "PASS: $pass_trim"
else
    log_info "PASS: (none)"
fi
if [ -n "$fail_trim" ]; then
    log_info "FAIL: $fail_trim"
else
    log_info "FAIL: (none)"
fi
log_info "Summary file: $OUT_DIR/summary.txt"

# ---------- Final verdict ----------
if [ "$OVERALL_PASS" -eq 1 ] && [ $ANY_RC_NONZERO -eq 0 ]; then
    echo "$TESTNAME PASS" > "$RES_FILE"
    log_pass "$TESTNAME PASS"
    exit 0
else
    echo "$TESTNAME FAIL" > "$RES_FILE"
    log_fail "$TESTNAME FAIL"
    exit 1
fi

# ---------- Artifacts ----------
log_info "Artifacts under: $OUT_DIR/"
for IDX in $INDICES; do
    CAM_DIR="${OUT_DIR%/}/cam${IDX}"
    log_info " - $CAM_DIR/"
done
