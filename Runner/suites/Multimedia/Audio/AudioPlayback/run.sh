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

TESTNAME="AudioPlayback"
RES_FILE="./${TESTNAME}.res"
LOGDIR="results/${TESTNAME}"
mkdir -p "$LOGDIR"

# ---- Assets ----
AUDIO_TAR_URL="${AUDIO_TAR_URL:-https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/Pulse-Audio-Files-v1.0/AudioClips.tar.gz}"
export AUDIO_TAR_URL

# ------------- Defaults / CLI -------------
AUDIO_BACKEND=""
SINK_CHOICE="${SINK_CHOICE:-speakers}" # speakers|null
FORMATS="${FORMATS:-wav}"
DURATIONS="${DURATIONS:-short}" # short|medium|long
LOOPS="${LOOPS:-1}"
TIMEOUT="${TIMEOUT:-0}" # 0 = no timeout (recommended)
STRICT="${STRICT:-0}"
DMESG_SCAN="${DMESG_SCAN:-1}"
VERBOSE=0
EXTRACT_AUDIO_ASSETS="${EXTRACT_AUDIO_ASSETS:-true}"
JUNIT_OUT=""

usage() {
  cat <<EOF
Usage: $0 [options]
  --backend {pipewire|pulseaudio}
  --sink {speakers|null}
  --formats "wav"
  --durations "short|short medium|short medium long"
  --loops N
  --timeout SECS # set 0 to disable watchdog
  --strict
  --no-dmesg
  --no-extract-assets
  --junit FILE.xml
  --verbose
  --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --backend) AUDIO_BACKEND="$2"; shift 2 ;;
    --sink) SINK_CHOICE="$2"; shift 2 ;;
    --formats) FORMATS="$2"; shift 2 ;;
    --durations) DURATIONS="$2"; shift 2 ;;
    --loops) LOOPS="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --no-dmesg) DMESG_SCAN=0; shift ;;
    --no-extract-assets) EXTRACT_AUDIO_ASSETS=false; shift ;;
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
log_info "Args: backend=${AUDIO_BACKEND:-auto} sink=$SINK_CHOICE loops=$LOOPS timeout=$TIMEOUT formats='$FORMATS' durations='$DURATIONS' strict=$STRICT dmesg=$DMESG_SCAN extract=$EXTRACT_AUDIO_ASSETS"

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
  check_dependencies wpctl pw-play || { log_skip "$TESTNAME SKIP - missing PipeWire utils"; echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0; }
else
  check_dependencies pactl paplay || { log_skip "$TESTNAME SKIP - missing PulseAudio utils"; echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0; }
fi

# ----- Route sink (set default; player uses default sink) -----
SINK_ID=""
case "$AUDIO_BACKEND:$SINK_CHOICE" in
  pipewire:null) SINK_ID="$(pw_default_null)" ;;
  pipewire:*) SINK_ID="$(pw_default_speakers)" ;;
  pulseaudio:null) SINK_ID="$(pa_default_null)" ;;
  pulseaudio:*) SINK_ID="$(pa_default_speakers)" ;;
esac
if [ -z "$SINK_ID" ]; then
  log_skip "$TESTNAME SKIP - requested sink '$SINK_CHOICE' not found for $AUDIO_BACKEND"
  echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0
fi

if [ "$AUDIO_BACKEND" = "pipewire" ]; then
  SINK_NAME="$(pw_sink_name_safe "$SINK_ID")"
  wpctl set-default "$SINK_ID" >/dev/null 2>&1 || true
  [ -n "$SINK_NAME" ] || SINK_NAME="unknown"
  log_info "Routing to sink: id=$SINK_ID name='$SINK_NAME' choice=$SINK_CHOICE"
else
  SINK_NAME="$(pa_sink_name "$SINK_ID")"
  [ -n "$SINK_NAME" ] || SINK_NAME="$SINK_ID"
  pa_set_default_sink "$SINK_ID" >/dev/null 2>&1 || true
  log_info "Routing to sink: name='$SINK_NAME' choice=$SINK_CHOICE"
fi

# JUnit init
if [ -n "$JUNIT_OUT" ]; then JUNIT_TMP="$LOGDIR/.junit_cases.xml"; : > "$JUNIT_TMP"; fi
append_junit() {
  name="$1"; elapsed="$2"; status="$3"; logf="$4"
  [ -n "$JUNIT_OUT" ] || return 0
  safe_msg="$(tail -n 50 "$logf" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')"
  {
    printf ' <testcase classname="%s" name="%s" time="%s">\n' "Audio.Playback" "$name" "$elapsed"
    case "$status" in
      PASS) : ;;
      SKIP) printf ' <skipped/>\n' ;;
      FAIL) printf ' <failure message="%s">\n' "failed"; printf '%s\n' "$safe_msg"; printf ' </failure>\n' ;;
    esac
    printf ' </testcase>\n'
  } >> "$JUNIT_TMP"
}

# Decide minimum ok seconds if timeout>0
dur_s="$(duration_to_secs "$TIMEOUT" 2>/dev/null || echo 0)"
[ -z "$dur_s" ] && dur_s=0
min_ok=0
if [ "$dur_s" -gt 0 ] 2>/dev/null; then
  min_ok=$((dur_s - 1)); [ "$min_ok" -lt 1 ] && min_ok=1
  log_info "Watchdog/timeout: ${TIMEOUT}"
else
  log_info "Watchdog/timeout: disabled (no timeout)"
fi

# ------------- Matrix execution -------------
total=0; pass=0; fail=0; skip=0; suite_rc=0

for fmt in $FORMATS; do
  for dur in $DURATIONS; do
    clip="$(resolve_clip "$fmt" "$dur")"
    case_name="play_${fmt}_${dur}"
    total=$((total + 1))
    logf="$LOGDIR/${case_name}.log"; : > "$logf"
    export AUDIO_LOGCTX="$logf"

    if [ -z "$clip" ]; then
      log_warn "[$case_name] No clip mapping for format=$fmt duration=$dur"
      echo "$case_name SKIP (no clip mapping)" >> "$LOGDIR/summary.txt"
      append_junit "$case_name" "0" "SKIP" "$logf"; skip=$((skip + 1)); continue
    fi

    if [ "${EXTRACT_AUDIO_ASSETS:-true}" = "true" ]; then
      ensure_playback_clip "$clip" || {
        log_warn "[$case_name] Clip missing and could not be fetched: $clip"
        echo "$case_name SKIP (clip missing)" >> "$LOGDIR/summary.txt"
        append_junit "$case_name" "0" "SKIP" "$logf"; skip=$((skip + 1)); continue
      }
    fi

    i=1; ok_runs=0; last_elapsed=0
    while [ "$i" -le "$LOOPS" ]; do
      iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        loop_hdr="sink=$SINK_CHOICE($SINK_ID)"
      else
        loop_hdr="sink=$SINK_CHOICE($SINK_NAME)"
      fi
      log_info "[$case_name] loop $i/$LOOPS start=$iso clip=$clip backend=$AUDIO_BACKEND $loop_hdr"
      start_s="$(date +%s 2>/dev/null || echo 0)"

      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        log_info "[$case_name] exec: pw-play -v \"$clip\""
        audio_exec_with_timeout "$TIMEOUT" pw-play -v "$clip" >>"$logf" 2>&1
        rc=$?
      else
        log_info "[$case_name] exec: paplay --device=\"$SINK_NAME\" \"$clip\""
        audio_exec_with_timeout "$TIMEOUT" paplay --device="$SINK_NAME" "$clip" >>"$logf" 2>&1
        rc=$?
      fi

      end_s="$(date +%s 2>/dev/null || echo 0)"
      last_elapsed=$((end_s - start_s)); [ "$last_elapsed" -lt 0 ] && last_elapsed=0

      # Evidence
      pw_ev=$(audio_evidence_pw_streaming || echo 0)
      pa_ev=$(audio_evidence_pa_streaming || echo 0)
      # ---- minimal PulseAudio fallback so pa_streaming doesn't read as 0 after teardown ----
      if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 0 ]; then
        if [ "$rc" -eq 0 ] || { [ "$rc" -eq 124 ] && [ "$dur_s" -gt 0 ] 2>/dev/null && [ "$last_elapsed" -ge "$min_ok" ]; }; then
          pa_ev=1
        fi
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
      log_info "[$case_name] evidence: pw_streaming=$pw_ev pa_streaming=$pa_ev alsa_running=$alsa_ev asoc_path_on=$asoc_ev pw_log=$pwlog_ev"

      if [ "$rc" -eq 0 ]; then
        log_pass "[$case_name] loop $i OK (rc=0, ${last_elapsed}s)"
        ok_runs=$((ok_runs + 1))
      elif [ "$rc" -eq 124 ] && [ "$dur_s" -gt 0 ] 2>/dev/null && [ "$last_elapsed" -ge "$min_ok" ]; then
        log_warn "[$case_name] TIMEOUT ($TIMEOUT) - PASS (ran ~${last_elapsed}s)"
        ok_runs=$((ok_runs + 1))
      elif [ "$rc" -ne 0 ] && { [ "$pw_ev" -eq 1 ] || [ "$pa_ev" -eq 1 ] || [ "$alsa_ev" -eq 1 ] || [ "$asoc_ev" -eq 1 ]; }; then
        log_warn "[$case_name] nonzero rc=$rc but evidence indicates playback - PASS"
        ok_runs=$((ok_runs + 1))
      else
        log_fail "[$case_name] loop $i FAILED (rc=$rc, ${last_elapsed}s) - see $logf"
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
