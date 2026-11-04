#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc.
# SPDX-License-Identifier: BSD-3-Clause
# libcamera 'cam' runner with strong post-capture validation (CLI-config only)

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

LIBCAM_PATH="$TOOLS/camera/lib_camera.sh"

if [ ! -r "$LIBCAM_PATH" ]; then
    log_error "lib_camera.sh is unavailable at $LIBCAM_PATH"
    exit 1
fi

# shellcheck source=../../../../utils/camera/lib_camera.sh disable=SC1091
. "$LIBCAM_PATH"

TESTNAME="Libcamera_cam"
RES_FILE="./${TESTNAME}.res"
if ! test_result_init "$TESTNAME" "$RES_FILE"; then
    exit 1
fi

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
UNCALIB="/usr/share/libcamera/ipa/simple/uncalibrated.yaml"
UNCALIB_BACKUP="${UNCALIB}.qcom-testkit-backup"
UNCALIB_MOVED=0

# Restore test-owned runtime changes.
cleanup() {
    if [ "$UNCALIB_MOVED" -eq 1 ]; then
        libcam_restore_ipa_config "$UNCALIB" "$UNCALIB_BACKUP" || true
        UNCALIB_MOVED=0
    fi
}

trap 'cleanup' EXIT
trap 'exit 130' INT TERM

usage() {
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

# Parse command-line arguments.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --index|--count|--out|--args|--dup-max-ratio|--bin-tol-pct)
                if [ "$#" -lt 2 ]; then
                    log_error "Option $1 requires a value"
                    usage
                    return 2
                fi
                case "$1" in
                    --index)
                        CAM_INDEX="$2"
                        ;;
                    --count)
                        CAPTURE_COUNT="$2"
                        ;;
                    --out)
                        OUT_DIR="$2"
                        ;;
                    --args)
                        CAM_EXTRA_ARGS="$2"
                        ;;
                    --dup-max-ratio)
                        DUP_MAX_RATIO="$2"
                        ;;
                    --bin-tol-pct)
                        BIN_TOL_PCT="$2"
                        ;;
                esac
                shift 2
                ;;
            --ppm)
                SAVE_AS_PPM="yes"
                shift
                ;;
            --bin)
                SAVE_AS_PPM="no"
                shift
                ;;
            --strict)
                SEQ_STRICT="yes"
                ERR_STRICT="yes"
                shift
                ;;
            --no-strict)
                SEQ_STRICT="no"
                ERR_STRICT="no"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                return 2
                ;;
        esac
    done
}

if ! parse_args "$@"; then
    exit 2
fi

# ---------- DT / platform readiness ----------
log_info "Checking the runtime device tree for an enabled Qualcomm CAMSS pipeline"
CAMSS_NODES="$(libcam_list_enabled_pipeline_nodes 2>/dev/null || true)"

if [ -z "$CAMSS_NODES" ]; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP - no enabled Qualcomm CAMSS pipeline exists in the runtime device tree, select an upstream CAMSS image or overlay"
fi

printf '%s\n' "$CAMSS_NODES" |
    while IFS= read -r camss_node; do
        [ -n "$camss_node" ] || continue
        log_info "Enabled CAMSS pipeline node: $camss_node"
    done

# ---------- Dependencies ----------
log_info "Checking image-provided libcamera dependencies"
if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies cam; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP - enabled CAMSS is present but the image does not provide the libcamera cam utility"
fi

if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 \
    check_dependencies awk sed grep sort cut tr wc find stat head tail dd; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP - required image-provided shell utilities are unavailable"
fi

if ! command -v sha256sum >/dev/null 2>&1 &&
   ! command -v md5sum >/dev/null 2>&1; then
    log_info "No optional SHA-256 or MD5 utility is available, duplicate hash checks will be skipped"
fi

# ---------- Setup ----------
mkdir -p "$OUT_DIR" 2>/dev/null || true
RUN_TS="$(date -u +%Y%m%d-%H%M%S)"
CAM_LIST_LOG="${OUT_DIR%/}/cam-list-${RUN_TS}.log"

log_info "Test: $TESTNAME"
log_info "OUT_DIR=$OUT_DIR | COUNT=$CAPTURE_COUNT | SAVE_AS_PPM=$SAVE_AS_PPM"
log_info "Extra args: ${CAM_EXTRA_ARGS:-<none>}"

# ---- IPA workaround: disable simple/uncalibrated to avoid buffer allocation failures ----
if libcam_disable_ipa_config "$UNCALIB" "$UNCALIB_BACKUP"; then
    UNCALIB_MOVED=1
else
    IPA_CONFIG_RC=$?
    if [ "$IPA_CONFIG_RC" -eq 2 ]; then
        log_info "IPA workaround is not applicable, config is absent: $UNCALIB"
    fi
fi

# ---------- Sensor presence ----------
if cam -l >"$CAM_LIST_LOG" 2>&1; then
    CAM_LIST_RC=0
else
    CAM_LIST_RC=$?
fi

sed 's/^/[cam -l] /' "$CAM_LIST_LOG"

if [ "$CAM_LIST_RC" -ne 0 ]; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL - cam -l exited with status $CAM_LIST_RC although an enabled CAMSS pipeline is present, see $CAM_LIST_LOG"
fi

SENSOR_COUNT="$(libcam_count_sensors_from_file "$CAM_LIST_LOG" 2>/dev/null || true)"
case "$SENSOR_COUNT" in
    ''|*[!0-9]*) SENSOR_COUNT=0 ;;
esac
log_info "[cam -l] detected ${SENSOR_COUNT} camera(s)"

if [ "$SENSOR_COUNT" -lt 1 ]; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL - enabled CAMSS pipeline detected but cam -l reported zero cameras, provide matching libcamera pipeline-handler and sensor support, see $CAM_LIST_LOG"
fi

# ---------- Resolve indices (supports: auto | all | 0,2,5) ----------
INDICES="$(libcam_resolve_indices "$CAM_INDEX" "$CAM_LIST_LOG")"
if [ -z "$INDICES" ]; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL - cam -l reported cameras but no index matched --index $CAM_INDEX, see $CAM_LIST_LOG"
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
        cat "$CAM_LIST_LOG"
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
        test_result_record "PASS" "Camera index $IDX capture and validation passed"
        PASS_LIST="$PASS_LIST $IDX"
        echo "cam$IDX PASS" >> "$OUT_DIR/summary.txt"
    else
        test_result_record "FAIL" "Camera index $IDX capture or validation failed, see $RUN_LOG"
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

# ---------- Artifacts ----------
log_info "Artifacts under: $OUT_DIR/"
for IDX in $INDICES; do
    CAM_DIR="${OUT_DIR%/}/cam${IDX}"
    log_info " - $CAM_DIR/"
done

# ---------- Final verdict ----------
if [ "$OVERALL_PASS" -eq 1 ] && [ $ANY_RC_NONZERO -eq 0 ]; then
    test_result_finish \
        "PASS" \
        "$TESTNAME PASS - all selected camera captures passed"
else
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL - one or more selected camera captures failed, see $OUT_DIR/summary.txt"
fi
