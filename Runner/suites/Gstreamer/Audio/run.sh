#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# GStreamer Audio Encode/Decode Test Runner

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

TESTNAME="Gstreamer_Audio_Tests"
RES_FILE="./${TESTNAME}.res"

# --- Defaults / knobs ---
if [ -z "${TIMEOUT:-}" ]; then TIMEOUT="60"; fi
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

# --- Audio settings ---
AUDIO_OUTPUT="./output_audio.wav"
AUDIO_EOS_BUFFERS="${AUDIO_EOS_BUFFERS:-2000}"

# --- GStreamer pipelines ---
AUDIO_ENCODE_PIPELINE="pulsesrc ! audioconvert ! audioresample ! identity eos-after=${AUDIO_EOS_BUFFERS} ! wavenc ! filesink location=${AUDIO_OUTPUT}"

AUDIO_DECODE_PIPELINE="filesrc location=${AUDIO_OUTPUT} ! wavparse ! audioconvert ! audioresample ! pulsesink"

usage() {
    cat <<EOF
Usage: $0 [--timeout S] [--strict] [--no-dmesg] [--stop-on-fail]
          [--loglevel N] [--repeat N] [--repeat-delay S] [--repeat-policy all|any]
          [--junit FILE] [--verbose]
          [--post-test-sleep S]
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
        --post-test-sleep) shift; POST_TEST_SLEEP="$1" ;;
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
for plugin in pulsesrc pulsesink wavenc wavparse audioconvert audioresample identity; do
    if ! gst-inspect-1.0 "$plugin" >/dev/null 2>&1; then
        log_skip "$TESTNAME SKIP - $plugin plugin not available"
        printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
done

# --- JUnit prep / results files ---
JUNIT_TMP="$LOG_DIR/.junit_cases.xml"
: > "$JUNIT_TMP"
printf '%s\n' "mode,id,result,name,elapsed,pass_runs,fail_runs" > "$LOG_DIR/results.csv"
: > "$LOG_DIR/summary.txt"

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
    
    if grep -q "negotiation failed" "$logf"; then
        return 0
    fi
    
    if grep -q "buffer pool activation failed" "$logf"; then
        return 0
    fi
    
    return 1
}

# --- Run tests ---
log_info "----------------------------------------------------------------------"
log_info "---------------------- Starting $TESTNAME ----------------------------"
log_info "TIMEOUT=${TIMEOUT}s LOGLEVEL=$LOGLEVEL REPEAT=$REPEAT"

total=0
pass=0
fail=0
skip=0
suite_rc=0

# --- Test 1: Audio Encode ---
id="audio-encode"
name="Audio Encode using pulsesrc → wavenc"
total=$((total + 1))

log_info "----------------------------------------------------------------------"
log_info "[$id] START - $name"

pass_runs=0
fail_runs=0
case_skipped=0
rep=1

while [ "$rep" -le "$REPEAT" ]; do
    if [ "$REPEAT" -gt 1 ]; then
        log_info "[$id] repeat $rep/$REPEAT"
    fi
    
    if run_gst_pipeline "$id" "$AUDIO_ENCODE_PIPELINE"; then
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

if [ "$DMESG_SCAN" -eq 1 ] && command -v scan_dmesg_errors >/dev/null 2>&1; then
    if scan_dmesg_errors "$LOG_DIR" "audio|sound|alsa|pulse" "dummy regulator|not found"; then
        log_warn "[$id] dmesg reported errors (STRICT=$STRICT)"
        [ "$STRICT" -eq 1 ] && final="FAIL"
    fi
fi

printf '%s\n' "$id $final $name" >> "$LOG_DIR/summary.txt"
printf '%s\n' "encode,$id,$final,$name,0,$pass_runs,$fail_runs" >> "$LOG_DIR/results.csv"

if [ "$final" = "PASS" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    suite_rc=1
    [ "$STOP_ON_FAIL" -eq 1 ] && exit 1
fi

[ "$POST_TEST_SLEEP" -gt 0 ] && sleep "$POST_TEST_SLEEP"

# --- Test 2: Audio Decode ---
id="audio-decode"
name="Audio Decode using wavparse → pulsesink"
total=$((total + 1))

log_info "----------------------------------------------------------------------"
log_info "[$id] START - $name"

pass_runs=0
fail_runs=0
case_skipped=0
rep=1

# Check if audio file exists from encode test
if [ ! -f "$AUDIO_OUTPUT" ]; then
    log_skip "[$id] SKIP - audio output file not available (run audio-encode first)"
    case_skipped=1
    skip=$((skip + 1))
    final="SKIP"
else
    while [ "$rep" -le "$REPEAT" ]; do
        if [ "$REPEAT" -gt 1 ]; then
            log_info "[$id] repeat $rep/$REPEAT"
        fi
        
        if run_gst_pipeline "$id" "$AUDIO_DECODE_PIPELINE"; then
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
    
    if [ "$DMESG_SCAN" -eq 1 ] && command -v scan_dmesg_errors >/dev/null 2>&1; then
        if scan_dmesg_errors "$LOG_DIR" "audio|sound|alsa|pulse" "dummy regulator|not found"; then
            log_warn "[$id] dmesg reported errors (STRICT=$STRICT)"
            [ "$STRICT" -eq 1 ] && final="FAIL"
        fi
    fi
fi

printf '%s\n' "$id $final $name" >> "$LOG_DIR/summary.txt"
printf '%s\n' "decode,$id,$final,$name,0,$pass_runs,$fail_runs" >> "$LOG_DIR/results.csv"

if [ "$final" = "PASS" ]; then
    pass=$((pass + 1))
elif [ "$final" = "FAIL" ]; then
    fail=$((fail + 1))
    suite_rc=1
fi

# --- Summary ---
log_info "----------------------------------------------------------------------"
log_info "Summary: total=$total pass=$pass fail=$fail skip=$skip"

if [ -s "$LOG_DIR/summary.txt" ]; then
    log_info "----------------------------------------------------------------------"
    log_info "Per-test results:"
    while IFS= read -r line; do
        log_info "$line"
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
    log_pass "$TESTNAME: PASS"
    printf '%s\n' "$TESTNAME PASS" >"$RES_FILE"
    exit 0
else
    log_fail "$TESTNAME: FAIL"
    printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi
