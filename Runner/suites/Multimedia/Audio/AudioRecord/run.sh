#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Source init_env & tools ----
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then INIT_ENV="$SEARCH/init_env"; break; fi
  SEARCH=$(dirname "$SEARCH")
done
[ -z "$INIT_ENV" ] && echo "[ERROR] init_env not found" >&2 && exit 1
# shellcheck disable=SC1090
[ -z "$__INIT_ENV_LOADED" ] && . "$INIT_ENV"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
. "$TOOLS/audio_common.sh"

TESTNAME="AudioRecord"
RES_FILE="./${TESTNAME}.res"
LOGDIR="results/${TESTNAME}"
mkdir -p "$LOGDIR"

# ---------------- Defaults / CLI ----------------
AUDIO_BACKEND=""
SRC_CHOICE="${SRC_CHOICE:-mic}" # mic|null
DURATIONS="${DURATIONS:-short}" # label set OR numeric tokens when REC_SECS=auto
REC_SECS="${REC_SECS:-30s}" # DEFAULT: 30s; 'auto' maps short/med/long
LOOPS="${LOOPS:-1}"
TIMEOUT="${TIMEOUT:-0}" # 0 = no watchdog
STRICT="${STRICT:-0}"
DMESG_SCAN="${DMESG_SCAN:-1}"
VERBOSE=0
JUNIT_OUT=""

usage() {
  cat <<EOF
Usage: $0 [options]
  --backend {pipewire|pulseaudio}
  --source {mic|null}
  --rec-secs SECS|auto (default: 30s; 'auto' maps short=5s, medium=15s, long=30s)
  --durations "short [medium] [long] [10s] [35secs]" (used when --rec-secs auto)
  --loops N
  --timeout SECS
  --strict
  --no-dmesg
  --junit FILE.xml
  --verbose
  --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --backend) AUDIO_BACKEND="$2"; shift 2 ;;
    --source) SRC_CHOICE="$2"; shift 2 ;;
    --durations) DURATIONS="$2"; shift 2 ;;
    --rec-secs) REC_SECS="$2"; shift 2 ;;
    --loops) LOOPS="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --no-dmesg) DMESG_SCAN=0; shift ;;
    --junit) JUNIT_OUT="$2"; shift 2 ;;
    --verbose) export VERBOSE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) log_warn "Unknown option: $1"; shift ;;
  esac
done

# Ensure we run from the testcase dir
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
cd "$test_path" || { log_error "cd failed: $test_path"; echo "$TESTNAME FAIL" >"$RES_FILE"; exit 1; }

log_info "---------------- Starting $TESTNAME ----------------"
log_info "SoC: $(soc_id)"
log_info "Args: backend=${AUDIO_BACKEND:-auto} source=$SRC_CHOICE loops=$LOOPS durations='$DURATIONS' rec_secs=$REC_SECS timeout=$TIMEOUT strict=$STRICT dmesg=$DMESG_SCAN"

# Resolve backend
[ -z "$AUDIO_BACKEND" ] && AUDIO_BACKEND="$(detect_audio_backend)"
if [ -z "$AUDIO_BACKEND" ]; then
  log_skip "$TESTNAME SKIP - no audio backend running"
  echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0
fi
log_info "Using backend: $AUDIO_BACKEND"

if ! check_audio_daemon "$AUDIO_BACKEND"; then
  log_skip "$TESTNAME SKIP - backend not available: $AUDIO_BACKEND"
  echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0
fi

# Dependencies per backend
if [ "$AUDIO_BACKEND" = "pipewire" ]; then
  check_dependencies wpctl pw-record || { log_skip "$TESTNAME SKIP - missing PipeWire utils"; echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0; }
else
  check_dependencies pactl parecord || { log_skip "$TESTNAME SKIP - missing PulseAudio utils"; echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0; }
fi

# ----- Route source (set default; recorder uses default source) -----
SRC_ID=""
case "$AUDIO_BACKEND:$SRC_CHOICE" in
  pipewire:null) SRC_ID="$(pw_default_null_source)" ;;
  pipewire:*) SRC_ID="$(pw_default_mic)" ;;
  pulseaudio:null) SRC_ID="$(pa_default_null_source)" ;;
  pulseaudio:*) SRC_ID="$(pa_default_mic)" ;;
esac
if [ -z "$SRC_ID" ]; then
  log_skip "$TESTNAME SKIP - requested source '$SRC_CHOICE' not found for $AUDIO_BACKEND"
  echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0
fi

if [ "$AUDIO_BACKEND" = "pipewire" ]; then
  SRC_LABEL="$(pw_source_label_safe "$SRC_ID")"
  wpctl set-default "$SRC_ID" >/dev/null 2>&1 || true
  [ -n "$SRC_LABEL" ] || SRC_LABEL="unknown"
  log_info "Routing to source: id/name=$SRC_ID label='$SRC_LABEL' choice=$SRC_CHOICE"
else
  SRC_LABEL="$(pa_source_name "$SRC_ID" 2>/dev/null || echo "$SRC_ID")"
  pa_set_default_source "$SRC_ID" >/dev/null 2>&1 || true
  log_info "Routing to source: name='$SRC_LABEL' choice=$SRC_CHOICE"
fi

# Watchdog info
dur_s="$(duration_to_secs "$TIMEOUT" 2>/dev/null || echo 0)"
[ -z "$dur_s" ] && dur_s=0
if [ "$dur_s" -gt 0 ] 2>/dev/null; then
  log_info "Watchdog/timeout: ${TIMEOUT}"
else
  log_info "Watchdog/timeout: disabled (no timeout)"
fi

# JUnit init (optional)
if [ -n "$JUNIT_OUT" ]; then JUNIT_TMP="$LOGDIR/.junit_cases.xml"; : > "$JUNIT_TMP"; fi
append_junit() {
  name="$1"; elapsed="$2"; status="$3"; logf="$4"
  [ -n "$JUNIT_OUT" ] || return 0
  safe_msg="$(tail -n 50 "$logf" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')"
  {
    printf ' <testcase classname="%s" name="%s" time="%s">\n' "Audio.Record" "$name" "$elapsed"
    case "$status" in
      PASS) : ;;
      SKIP) printf ' <skipped/>\n' ;;
      FAIL) printf ' <failure message="%s">\n' "failed"; printf '%s\n' "$safe_msg"; printf ' </failure>\n' ;;
    esac
    printf ' </testcase>\n'
  } >> "$JUNIT_TMP"
}

# Auto map if REC_SECS=auto, and accept numeric tokens in DURATIONS like 35s/35sec/35secs/35seconds
auto_secs_for() {
  case "$1" in
    short) echo "5s" ;;
    medium) echo "15s" ;;
    long) echo "30s" ;;
    *) echo "5s" ;;
  esac
}

# ---------------- Matrix execution ----------------
total=0; pass=0; fail=0; skip=0; suite_rc=0

for dur in $DURATIONS; do
  case_name="record_${dur}"
  total=$((total + 1))
  logf="$LOGDIR/${case_name}.log"; : > "$logf"
  export AUDIO_LOGCTX="$logf"

  secs="$REC_SECS"
  if [ "$secs" = "auto" ]; then
    tok="$(printf '%s' "$dur" | tr '[:upper:]' '[:lower:]')"
    tok_secs="$(printf '%s' "$tok" | sed -n 's/^\([0-9][0-9]*\)\(s\|sec\|secs\|seconds\)$/\1s/p')"
    if [ -n "$tok_secs" ]; then
      secs="$tok_secs"
    else
      secs="$(auto_secs_for "$dur")"
    fi
  fi

  i=1; ok_runs=0; last_elapsed=0
  while [ "$i" -le "$LOOPS" ]; do
    iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    effective_timeout="$secs"
    if [ -n "$TIMEOUT" ] && [ "$TIMEOUT" != "0" ]; then
      effective_timeout="$TIMEOUT"
    fi
    loop_hdr="source=$SRC_CHOICE"
    [ "$AUDIO_BACKEND" = "pipewire" ] && loop_hdr="$loop_hdr($SRC_ID)" || loop_hdr="$loop_hdr($SRC_LABEL)"
    log_info "[$case_name] loop $i/$LOOPS start=$iso secs=$secs backend=$AUDIO_BACKEND $loop_hdr"
    out="$LOGDIR/${case_name}.wav"
    : > "$out"

    start_s="$(date +%s 2>/dev/null || echo 0)"
    if [ "$AUDIO_BACKEND" = "pipewire" ]; then
      log_info "[$case_name] exec: pw-record -v \"$out\""
      audio_exec_with_timeout "$effective_timeout" pw-record -v "$out" >>"$logf" 2>&1
      rc=$?
      bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"

      if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
        log_warn "[$case_name] nonzero rc=$rc but recording looks valid (bytes=$bytes) - PASS"
        rc=0
      fi

      if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -le 1024 ] 2>/dev/null; then
        log_warn "[$case_name] first attempt rc=$rc bytes=$bytes; retry with --target $SRC_ID"
        : > "$out"
        log_info "[$case_name] exec: pw-record -v --target \"$SRC_ID\" \"$out\""
        audio_exec_with_timeout "$effective_timeout" pw-record -v --target "$SRC_ID" "$out" >>"$logf" 2>&1
        rc=$?
        bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
        if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
          log_warn "[$case_name] nonzero rc=$rc after retry but recording looks valid (bytes=$bytes) - PASS"
          rc=0
        fi
      fi
    else
      log_info "[$case_name] exec: parecord --file-format=wav \"$out\""
      audio_exec_with_timeout "$effective_timeout" parecord --file-format=wav "$out" >>"$logf" 2>&1
      rc=$?
      bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
      if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
        log_warn "[$case_name] nonzero rc=$rc but recording looks valid (bytes=$bytes) - PASS"
        rc=0
      fi
    fi
    end_s="$(date +%s 2>/dev/null || echo 0)"
    last_elapsed=$((end_s - start_s)); [ "$last_elapsed" -lt 0 ] && last_elapsed=0

    # Evidence
    pw_ev=$(audio_evidence_pw_streaming || echo 0)
    pa_ev=$(audio_evidence_pa_streaming || echo 0)
    # ---- minimal PulseAudio fallback so pa_streaming doesn't read as 0 after teardown ----
    if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 0 ]; then
      if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then pa_ev=1; fi
    fi
    alsa_ev=$(audio_evidence_alsa_running_any || echo 0)
    asoc_ev=$(audio_evidence_asoc_path_on || echo 0)
    pwlog_ev=$(audio_evidence_pw_log_seen || echo 0)
    [ "$AUDIO_BACKEND" = "pulseaudio" ] && pwlog_ev=0
    # Fast teardown fallback: if user-space stream was active, trust ALSA/ASoC too.
    if [ "$alsa_ev" -eq 0 ]; then
      if [ "$AUDIO_BACKEND" = "pipewire" ] && [ "$pw_ev" -eq 1 ]; then alsa_ev=1; fi
      if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 1 ]; then alsa_ev=1; fi
    fi
    if [ "$asoc_ev" -eq 0 ] && [ "$alsa_ev" -eq 1 ]; then
     asoc_ev=1
    fi
    log_info "[$case_name] evidence: pw_streaming=$pw_ev pa_streaming=$pa_ev alsa_running=$alsa_ev asoc_path_on=$asoc_ev bytes=${bytes:-0} pw_log=$pwlog_ev"

    # Final PASS/FAIL
    if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
      log_pass "[$case_name] loop $i OK (rc=0, ${last_elapsed}s, bytes=$bytes)"
      ok_runs=$((ok_runs + 1))
    else
      log_fail "[$case_name] loop $i FAILED (rc=$rc, ${last_elapsed}s, bytes=${bytes:-0}) - see $logf"
    fi

    i=$((i + 1))
  done

  if [ "$DMESG_SCAN" -eq 1 ]; then
    scan_audio_dmesg "$LOGDIR"
    dump_mixers "$LOGDIR/mixer_dump.txt"
  fi

  status="FAIL"; [ "$ok_runs" -ge 1 ] && status="PASS"
  append_junit "$case_name" "$last_elapsed" "$status" "$logf"
  case "$status" in
    PASS) pass=$((pass + 1)); echo "$case_name PASS" >> "$LOGDIR/summary.txt" ;;
    SKIP) skip=$((skip + 1)); echo "$case_name SKIP" >> "$LOGDIR/summary.txt" ;;
    FAIL) fail=$((fail + 1)); echo "$case_name FAIL" >> "$LOGDIR/summary.txt"; suite_rc=1 ;;
  esac
done

log_info "Summary: total=$total pass=$pass fail=$fail skip=$skip"

if [ -n "$JUNIT_OUT" ]; then
  tests=$((pass + fail + skip))
  failures="$fail"
  skipped="$skip"
  {
    printf '<testsuite name="%s" tests="%s" failures="%s" skipped="%s">\n' "$TESTNAME" "$tests" "$failures" "$skipped"
    cat "$JUNIT_TMP"
    printf '</testsuite>\n'
  } > "$JUNIT_OUT"
  log_info "Wrote JUnit: $JUNIT_OUT"
fi

if [ "$suite_rc" -eq 0 ]; then
  log_pass "$TESTNAME PASS"; echo "$TESTNAME PASS" > "$RES_FILE"
else
  log_fail "$TESTNAME FAIL"; echo "$TESTNAME FAIL" > "$RES_FILE"
fi
exit "$suite_rc"
