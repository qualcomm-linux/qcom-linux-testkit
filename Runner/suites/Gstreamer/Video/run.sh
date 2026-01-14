#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# GStreamer Video Encode/Decode Test Runner - 480p and 4K resolutions

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" || exit 1; pwd)"
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
. "$TOOLS/lib_video.sh"

TESTNAME="Gstreamer_Video_Tests"
RES_FILE="./${TESTNAME}.res"

# --- Defaults / knobs ---
if [ -z "${TIMEOUT:-}" ]; then TIMEOUT="120"; fi
if [ -z "${STRICT:-}" ]; then STRICT="0"; fi
if [ -z "${DMESG_SCAN:-}" ]; then DMESG_SCAN="1"; fi
if [ -z "${STOP_ON_FAIL:-}" ]; then STOP_ON_FAIL="0"; fi
if [ -z "${LOGLEVEL:-}" ]; then LOGLEVEL="15"; fi
if [ -z "${REPEAT:-}" ]; then REPEAT="1"; fi
if [ -z "${REPEAT_DELAY:-}" ]; then REPEAT_DELAY="0"; fi
if [ -z "${REPEAT_POLICY:-}" ]; then REPEAT_POLICY="all"; fi
JUNIT_OUT=""
VERBOSE="0"
POST_TEST_SLEEP="0"

# --- Test media files (encode outputs used as decode inputs) ---
H264_480P_OUTPUT="./output_h264_480p.mp4"
H264_4K_OUTPUT="./output_h264_4k.mp4"
H265_480P_OUTPUT="./output_h265_480p.mp4"
H265_4K_OUTPUT="./output_h265_4k.mp4"

# --- VP9 input files (fetched from URL if not present) ---
VP9_480P_INPUT="./vp9_480p.webm"
VP9_4K_INPUT="./vp9_4k.webm"

# VP9 clips URL (can be overridden via environment)
if [ -z "${VP9_CLIPS_URL:-}" ]; then
    VP9_CLIPS_URL="https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/vp9_clips.tar.gz"
fi

# --- Test parameters ---
FRAMERATE="30"
BITRATE_480P="1000000"
BITRATE_4K="8000000"
NUM_BUFFERS="300"

# --- Resolution definitions ---
WIDTH_480P="720"
HEIGHT_480P="480"
WIDTH_4K="3840"
HEIGHT_4K="2160"

# --- GStreamer pipelines ---
# H.264 480p Encode
H264_480P_ENCODE_PIPELINE="videotestsrc num-buffers=${NUM_BUFFERS} ! video/x-raw,width=${WIDTH_480P},height=${HEIGHT_480P},format=NV12,framerate=${FRAMERATE}/1 ! v4l2h264enc extra-controls=\"controls,video_bitrate=${BITRATE_480P}\" ! h264parse ! qtmux ! filesink location=${H264_480P_OUTPUT}"

# H.264 4K Encode
H264_4K_ENCODE_PIPELINE="videotestsrc num-buffers=${NUM_BUFFERS} ! video/x-raw,width=${WIDTH_4K},height=${HEIGHT_4K},format=NV12,framerate=${FRAMERATE}/1 ! v4l2h264enc extra-controls=\"controls,video_bitrate=${BITRATE_4K}\" ! h264parse ! qtmux ! filesink location=${H264_4K_OUTPUT}"

# H.265 480p Encode
H265_480P_ENCODE_PIPELINE="videotestsrc num-buffers=${NUM_BUFFERS} ! video/x-raw,width=${WIDTH_480P},height=${HEIGHT_480P},format=NV12,framerate=${FRAMERATE}/1 ! v4l2h265enc extra-controls=\"controls,video_bitrate=${BITRATE_480P}\" ! h265parse ! qtmux ! filesink location=${H265_480P_OUTPUT}"

# H.265 4K Encode
H265_4K_ENCODE_PIPELINE="videotestsrc num-buffers=${NUM_BUFFERS} ! video/x-raw,width=${WIDTH_4K},height=${HEIGHT_4K},format=NV12,framerate=${FRAMERATE}/1 ! v4l2h265enc extra-controls=\"controls,video_bitrate=${BITRATE_4K}\" ! h265parse ! qtmux ! filesink location=${H265_4K_OUTPUT}"

# H.264 480p Decode (uses encoded output)
H264_480P_DECODE_PIPELINE="filesrc location=${H264_480P_OUTPUT} ! qtdemux ! h264parse ! v4l2h264dec ! videoconvert ! video/x-raw,format=NV12 ! fakevideosink"

# H.264 4K Decode (uses encoded output)
H264_4K_DECODE_PIPELINE="filesrc location=${H264_4K_OUTPUT} ! qtdemux ! h264parse ! v4l2h264dec ! videoconvert ! video/x-raw,format=NV12 ! fakevideosink"

# H.265 480p Decode (uses encoded output)
H265_480P_DECODE_PIPELINE="filesrc location=${H265_480P_OUTPUT} ! qtdemux ! h265parse ! v4l2h265dec ! videoconvert ! video/x-raw,format=NV12 ! fakevideosink"

# H.265 4K Decode (uses encoded output)
H265_4K_DECODE_PIPELINE="filesrc location=${H265_4K_OUTPUT} ! qtdemux ! h265parse ! v4l2h265dec ! videoconvert ! video/x-raw,format=NV12 ! fakevideosink"

# VP9 480p Decode (uses fetched input)
VP9_480P_DECODE_PIPELINE="filesrc location=${VP9_480P_INPUT} ! matroskademux ! vp9parse ! v4l2vp9dec ! videoconvert ! video/x-raw,format=NV12 ! fakevideosink"

# VP9 4K Decode (uses fetched input)
VP9_4K_DECODE_PIPELINE="filesrc location=${VP9_4K_INPUT} ! matroskademux ! vp9parse ! v4l2vp9dec ! videoconvert ! video/x-raw,format=NV12 ! fakevideosink"

usage() {
    cat <<EOF
Usage: $0 [--timeout S] [--strict] [--no-dmesg] [--stop-on-fail]
          [--loglevel N] [--repeat N] [--repeat-delay S] [--repeat-policy all|any]
          [--junit FILE] [--verbose]
          [--stack auto|upstream|downstream]
          [--platform lemans|monaco|kodiak]
          [--post-test-sleep S]
          [--vp9-clips-url URL]

Tests: H.264 and H.265 encode/decode at 480p (720x480) and 4K (3840x2160) resolutions
       VP9 decode tests at 480p and 4K (clips fetched from URL if not present)
       H.264/H.265 decode tests use the output from encode tests as input
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) shift; TIMEOUT="$1" ;;
        --strict) STRICT=1 ;;
        --no-dmesg) DMESG_SCAN=0 ;;
        --stop-on-fail) STOP_ON_FAIL=1 ;;
        --loglevel) shift; LOGLEVEL="$1" ;;
        --repeat) shift; REPEAT="$1" ;;
        --repeat-delay) shift; REPEAT_DELAY="$1" ;;
        --repeat-policy) shift; REPEAT_POLICY="$1" ;;
        --junit) shift; JUNIT_OUT="$1" ;;
        --verbose) VERBOSE=1 ;;
        --stack) shift; VIDEO_STACK="$1" ;;
        --platform) shift; VIDEO_PLATFORM="$1" ;;
        --post-test-sleep) shift; POST_TEST_SLEEP="$1" ;;
        --vp9-clips-url) shift; VP9_CLIPS_URL="$1" ;;
        --help|-h) usage; exit 0 ;;
        *) log_warn "Unknown arg: $1" ;;
    esac
    shift
done

# --- Dependency checks ---
if ! check_dependencies grep sed awk find sort gst-launch-1.0; then
    log_skip "$TESTNAME SKIP - required tools missing"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --- Resolve test path ---
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    test_path="$SCRIPT_DIR"
fi

if ! cd "$test_path"; then
    log_error "cd failed: $test_path"
    printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

# --- Create log directory ---
LOG_DIR="./logs_${TESTNAME}"
mkdir -p "$LOG_DIR"
export LOG_DIR

# --- Check GStreamer plugins ---
for plugin in v4l2h264dec v4l2h265dec v4l2h264enc v4l2h265enc qtmux qtdemux; do
    if ! gst-inspect-1.0 "$plugin" >/dev/null 2>&1; then
        log_skip "$TESTNAME SKIP - $plugin plugin not available"
        printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
done

# --- Check VP9 plugins (optional, won't skip entire suite) ---
VP9_AVAILABLE=0
if gst-inspect-1.0 v4l2vp9dec >/dev/null 2>&1 && \
   gst-inspect-1.0 vp9parse >/dev/null 2>&1 && \
   gst-inspect-1.0 matroskademux >/dev/null 2>&1; then
    VP9_AVAILABLE=1
    log_info "VP9 decode support detected"
else
    log_warn "VP9 decode plugins not available (v4l2vp9dec, vp9parse, or matroskademux missing)"
    log_warn "VP9 tests will be skipped"
fi

# --- Check video devices ---
if ! video_devices_present; then
    log_skip "$TESTNAME SKIP - no /dev/video* nodes"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --- JUnit prep / results files ---
JUNIT_TMP="$LOG_DIR/.junit_cases.xml"
: > "$JUNIT_TMP"
printf '%s\n' "mode,id,result,name,elapsed,pass_runs,fail_runs" > "$LOG_DIR/results.csv"
: > "$LOG_DIR/summary.txt"

# --- Helper: Fetch VP9 clips if needed ---
fetch_vp9_clips() {
    # Check if clips already exist
    if [ -f "$VP9_480P_INPUT" ] && [ -f "$VP9_4K_INPUT" ]; then
        log_info "VP9 clips already present"
        return 0
    fi
    
    log_info "VP9 clips missing, attempting to fetch from: $VP9_CLIPS_URL"
    
    # Check network availability
    if command -v check_network_status_rc >/dev/null 2>&1; then
        if ! check_network_status_rc; then
            log_warn "Network offline; cannot fetch VP9 clips"
            return 1
        fi
    fi
    
    # Use extract_tar_from_url from functestlib.sh
    if command -v extract_tar_from_url >/dev/null 2>&1; then
        if extract_tar_from_url "$VP9_CLIPS_URL"; then
            log_pass "VP9 clips fetched successfully"
            return 0
        else
            log_warn "Failed to fetch VP9 clips from $VP9_CLIPS_URL"
            return 1
        fi
    else
        log_warn "extract_tar_from_url not available; cannot fetch VP9 clips"
        return 1
    fi
}

# --- Helper functions ---
run_gst_pipeline() {
    id="$1"
    pipeline="$2"
    logf="$LOG_DIR/${id}.log"
    
    log_info "[$id] Running GStreamer pipeline"
    start_time=$(date +%s)
    
    if command -v run_with_timeout >/dev/null 2>&1; then
        if run_with_timeout "$TIMEOUT" gst-launch-1.0 -v $pipeline >"$logf" 2>&1; then
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            if check_pipeline_errors "$logf"; then
                log_fail "[$id] FAIL - Pipeline errors detected (${elapsed}s)"
                return 1
            else
                log_pass "[$id] PASS (${elapsed}s)"
                return 0
            fi
        else
            rc=$?
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            if [ "$rc" -eq 124 ]; then
                log_fail "[$id] FAIL - timeout after ${TIMEOUT}s"
            else
                log_fail "[$id] FAIL - gst-launch-1.0 exited with code $rc"
            fi
            return 1
        fi
    else
        if gst-launch-1.0 -v $pipeline >"$logf" 2>&1; then
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            if check_pipeline_errors "$logf"; then
                log_fail "[$id] FAIL - Pipeline errors detected (${elapsed}s)"
                return 1
            else
                log_pass "[$id] PASS (${elapsed}s)"
                return 0
            fi
        else
            rc=$?
            log_fail "[$id] FAIL - gst-launch-1.0 exited with code $rc"
            return 1
        fi
    fi
}

check_pipeline_errors() {
    logf="$1"
    
    if grep -q "ERROR:" "$logf"; then
        return 0
    fi
    
    if [ "$STRICT" -eq 1 ] && grep -q "WARNING:" "$logf"; then
        return 0
    fi
    
    if grep -q "v4l2.*failed" "$logf"; then
        return 0
    fi
    
    if grep -q "negotiation failed" "$logf"; then
        return 0
    fi
    
    if grep -q "buffer pool activation failed" "$logf"; then
        return 0
    fi
    
    return 1
}

run_test() {
    id="$1"
    name="$2"
    pipeline="$3"
    
    total=$((total + 1))
    
    log_info "----------------------------------------------------------------------"
    log_info "[$id] START - $name"
    
    pass_runs=0
    fail_runs=0
    rep=1
    
    while [ "$rep" -le "$REPEAT" ]; do
        if [ "$REPEAT" -gt 1 ]; then
            log_info "[$id] repeat $rep/$REPEAT"
        fi
        
        if run_gst_pipeline "$id" "$pipeline"; then
            pass_runs=$((pass_runs + 1))
        else
            fail_runs=$((fail_runs + 1))
        fi
        
        if [ "$rep" -lt "$REPEAT" ] && [ "$REPEAT_DELAY" -gt 0 ]; then
            sleep "$REPEAT_DELAY"
        fi
        
        rep=$((rep + 1))
    done
    
    final="FAIL"
    case "$REPEAT_POLICY" in
        any) [ "$pass_runs" -ge 1 ] && final="PASS" ;;
        all|*) [ "$fail_runs" -eq 0 ] && final="PASS" ;;
    esac
    
    video_step "$id" "DMESG triage"
    video_scan_dmesg_if_enabled "$DMESG_SCAN" "$LOG_DIR"
    dmesg_rc=$?
    
    if [ "$dmesg_rc" -eq 0 ] && [ "$STRICT" -eq 1 ]; then
        final="FAIL"
    fi
    
    printf '%s\n' "$id $final $name" >> "$LOG_DIR/summary.txt"
    printf '%s\n' "test,$id,$final,$name,0,$pass_runs,$fail_runs" >> "$LOG_DIR/results.csv"
    
    if [ "$final" = "PASS" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        suite_rc=1
        [ "$STOP_ON_FAIL" -eq 1 ] && exit 1
    fi
    
    [ "$POST_TEST_SLEEP" -gt 0 ] && sleep "$POST_TEST_SLEEP"
}

# --- Fetch VP9 clips if VP9 is available ---
if [ "$VP9_AVAILABLE" -eq 1 ]; then
    fetch_vp9_clips || log_warn "VP9 clip fetch failed; VP9 tests will be skipped"
fi

# --- Run tests ---
log_info "======================================================================"
log_info "==================== Starting $TESTNAME =========================="
log_info "TIMEOUT=${TIMEOUT}s LOGLEVEL=$LOGLEVEL REPEAT=$REPEAT"
log_info "Resolutions: 480p (${WIDTH_480P}x${HEIGHT_480P}), 4K (${WIDTH_4K}x${HEIGHT_4K})"
log_info "VP9 Support: $([ "$VP9_AVAILABLE" -eq 1 ] && echo "YES" || echo "NO")"
log_info "======================================================================"

total=0
pass=0
fail=0
skip=0
suite_rc=0

# --- ENCODE TESTS (must run first to generate files for decode) ---

# Test 1: H.264 480p Encode
run_test "h264-480p-encode" "H.264 480p Encode (${WIDTH_480P}x${HEIGHT_480P})" "$H264_480P_ENCODE_PIPELINE"

# Test 2: H.264 4K Encode
run_test "h264-4k-encode" "H.264 4K Encode (${WIDTH_4K}x${HEIGHT_4K})" "$H264_4K_ENCODE_PIPELINE"

# Test 3: H.265 480p Encode
run_test "h265-480p-encode" "H.265 480p Encode (${WIDTH_480P}x${HEIGHT_480P})" "$H265_480P_ENCODE_PIPELINE"

# Test 4: H.265 4K Encode
run_test "h265-4k-encode" "H.265 4K Encode (${WIDTH_4K}x${HEIGHT_4K})" "$H265_4K_ENCODE_PIPELINE"

# --- DECODE TESTS (use encoded outputs as inputs) ---

# Test 5: H.264 480p Decode
if [ -f "$H264_480P_OUTPUT" ]; then
    run_test "h264-480p-decode" "H.264 480p Decode (${WIDTH_480P}x${HEIGHT_480P})" "$H264_480P_DECODE_PIPELINE"
else
    log_warn "[h264-480p-decode] SKIP - encode output not found: $H264_480P_OUTPUT"
    skip=$((skip + 1))
    total=$((total + 1))
fi

# Test 6: H.264 4K Decode
if [ -f "$H264_4K_OUTPUT" ]; then
    run_test "h264-4k-decode" "H.264 4K Decode (${WIDTH_4K}x${HEIGHT_4K})" "$H264_4K_DECODE_PIPELINE"
else
    log_warn "[h264-4k-decode] SKIP - encode output not found: $H264_4K_OUTPUT"
    skip=$((skip + 1))
    total=$((total + 1))
fi

# Test 7: H.265 480p Decode
if [ -f "$H265_480P_OUTPUT" ]; then
    run_test "h265-480p-decode" "H.265 480p Decode (${WIDTH_480P}x${HEIGHT_480P})" "$H265_480P_DECODE_PIPELINE"
else
    log_warn "[h265-480p-decode] SKIP - encode output not found: $H265_480P_OUTPUT"
    skip=$((skip + 1))
    total=$((total + 1))
fi

# Test 8: H.265 4K Decode
if [ -f "$H265_4K_OUTPUT" ]; then
    run_test "h265-4k-decode" "H.265 4K Decode (${WIDTH_4K}x${HEIGHT_4K})" "$H265_4K_DECODE_PIPELINE"
else
    log_warn "[h265-4k-decode] SKIP - encode output not found: $H265_4K_OUTPUT"
    skip=$((skip + 1))
    total=$((total + 1))
fi

# --- VP9 DECODE TESTS (use fetched input files) ---

# Test 9: VP9 480p Decode
if [ "$VP9_AVAILABLE" -eq 1 ]; then
    if [ -f "$VP9_480P_INPUT" ]; then
        run_test "vp9-480p-decode" "VP9 480p Decode (${WIDTH_480P}x${HEIGHT_480P})" "$VP9_480P_DECODE_PIPELINE"
    else
        log_warn "[vp9-480p-decode] SKIP - input file not found: $VP9_480P_INPUT"
        skip=$((skip + 1))
        total=$((total + 1))
    fi
else
    log_info "[vp9-480p-decode] SKIP - VP9 plugins not available"
    skip=$((skip + 1))
    total=$((total + 1))
fi

# Test 10: VP9 4K Decode
if [ "$VP9_AVAILABLE" -eq 1 ]; then
    if [ -f "$VP9_4K_INPUT" ]; then
        run_test "vp9-4k-decode" "VP9 4K Decode (${WIDTH_4K}x${HEIGHT_4K})" "$VP9_4K_DECODE_PIPELINE"
    else
        log_warn "[vp9-4k-decode] SKIP - input file not found: $VP9_4K_INPUT"
        skip=$((skip + 1))
        total=$((total + 1))
    fi
else
    log_info "[vp9-4k-decode] SKIP - VP9 plugins not available"
    skip=$((skip + 1))
    total=$((total + 1))
fi

# --- Summary ---
log_info "======================================================================"
log_info "Summary: total=$total pass=$pass fail=$fail skip=$skip"
log_info "======================================================================"

if [ -s "$LOG_DIR/summary.txt" ]; then
    log_info "Per-test results:"
    while IFS= read -r line; do
        log_info "  $line"
    done < "$LOG_DIR/summary.txt"
fi

# --- JUnit finalize ---
if [ -n "$JUNIT_OUT" ]; then
    {
        printf '<testsuite name="%s" tests="%s" failures="%s" skipped="%s">\n' "$TESTNAME" "$total" "$fail" "$skip"
        cat "$JUNIT_TMP"
        printf '</testsuite>\n'
    } > "$JUNIT_OUT"
    log_info "Wrote JUnit: $JUNIT_OUT"
fi

# Overall result
if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ] && [ "$skip" -gt 0 ]; then
    log_skip "$TESTNAME: SKIP"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ "$suite_rc" -eq 0 ]; then
    log_pass "$TESTNAME: PASS (passed: $pass/$total)"
    printf '%s\n' "$TESTNAME PASS" >"$RES_FILE"
    exit 0
else
    log_fail "$TESTNAME: FAIL (failed: $fail/$total)"
    printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi
