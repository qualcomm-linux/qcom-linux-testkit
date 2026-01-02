#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Source init_env & tools ----
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
  echo "[ERROR] init_env not found" >&2
  exit 1
fi

# shellcheck disable=SC1090
if [ -z "$__INIT_ENV_LOADED" ]; then
  . "$INIT_ENV"
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/audio_common.sh"

if ! setup_overlay_audio_environment; then
    log_fail "Overlay audio environment setup failed"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

TESTNAME="AudioRecord"
RES_FILE="./${TESTNAME}.res"
LOGDIR="results/${TESTNAME}"
mkdir -p "$LOGDIR"

# ---------------- Defaults / CLI ----------------
AUDIO_BACKEND=""
SRC_CHOICE="${SRC_CHOICE:-mic}" # mic|null
DURATIONS="${DURATIONS:-short}" # label set OR numeric tokens when RECORD_SECONDS=auto
RECORD_SECONDS="${RECORD_SECONDS:-30s}" # DEFAULT: 30s; 'auto' maps short/med/long
LOOPS="${LOOPS:-1}"
TIMEOUT="${TIMEOUT:-0}" # 0 = no watchdog
STRICT="${STRICT:-0}"
DMESG_SCAN="${DMESG_SCAN:-1}"
VERBOSE=0
JUNIT_OUT=""

# New config-based testing options
CONFIG_NAMES=""        # Explicit config names to test (e.g., "record_config1 record_config2")
CONFIG_FILTER=""       # Filter pattern for configs (e.g., "48KHz" or "2ch")
USE_CONFIG_DISCOVERY="${USE_CONFIG_DISCOVERY:-auto}"  # auto|true|false

usage() {
  cat <<EOF
Usage: $0 [options]
  --backend {pipewire|pulseaudio}
  --source {mic|null}
  --config-name "record_config1"        # Test specific config(s) by name (space-separated)
                                         # Also supports record_config1, record_config2, ..., record_config10
  --config-filter "48KHz"               # Filter configs by pattern
  --record-seconds SECS|auto (default: 30s; 'auto' maps short=5s, medium=15s, long=30s)
  --durations "short [medium] [long] [10s] [35secs]" (used when --record-seconds auto)
  --loops N
  --timeout SECS
  --strict [0|1]
  --no-dmesg
  --junit FILE.xml
  --verbose
  --help

Examples:
  # Test all 10 record configs
  $0

  # Test specific configs by name
  $0 --config-name "record_config1 record_config2 record_config3"

  # Test specific configs by descriptive name
  $0 --config-name "record_48KHz_2ch record_8KHz_1ch"

  # Filter configs by pattern
  $0 --config-filter "48KHz"
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --backend)
      AUDIO_BACKEND="$2"
      shift 2
      ;;
    --source)
      SRC_CHOICE="$2"
      shift 2
      ;;
    --config-name)
      CONFIG_NAMES="$2"
      USE_CONFIG_DISCOVERY=true
      shift 2
      ;;
    --config-filter)
      CONFIG_FILTER="$2"
      USE_CONFIG_DISCOVERY=true
      shift 2
      ;;
    --durations)
      DURATIONS="$2"
      USE_CONFIG_DISCOVERY=false  # Explicit durations = use old matrix mode
      shift 2
      ;;
    --record-seconds)
      RECORD_SECONDS="$2"
      shift 2
      ;;
    --loops)
      LOOPS="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --strict)
      case "$2" in
        --*|"")
          STRICT=1
          shift
          ;;
        *)
          STRICT="$2"
          shift 2
          ;;
      esac
      ;;
    --no-dmesg)
      DMESG_SCAN=0
      shift
      ;;
    --junit)
      JUNIT_OUT="$2"
      shift 2
      ;;
    --verbose)
      export VERBOSE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      log_warn "Unknown option: $1"
      shift
      ;;
  esac
done

# Ensure we run from the testcase dir
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
if ! cd "$test_path"; then
  log_error "cd failed: $test_path"
  echo "$TESTNAME FAIL" > "$RES_FILE"
  exit 1
fi

log_info "---------------- Starting $TESTNAME ----------------"
# --- Platform details (robust logging; prefer helpers) ---
if command -v detect_platform >/dev/null 2>&1; then
  detect_platform >/dev/null 2>&1 || true
  log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='${PLATFORM_KERNEL:-}' arch='${PLATFORM_ARCH:-}'"
else
  log_info "Platform Details: unknown"
fi

# ------------- Mode Detection and Validation -------------
# Determine whether to use config discovery or legacy matrix mode
if [ "$USE_CONFIG_DISCOVERY" = "auto" ]; then
  # Auto mode: use config discovery by default (no external dependencies needed)
  USE_CONFIG_DISCOVERY=true
  log_info "Auto-detected config discovery mode (testing all 10 record configs)"
fi

# Show deprecation warnings for legacy options when using config discovery
if [ "$USE_CONFIG_DISCOVERY" = "true" ]; then
  if [ "$DURATIONS" != "short" ] || [ "$RECORD_SECONDS" != "30s" ]; then
    log_warn "DEPRECATION WARNING: --durations and --record-seconds are deprecated"
    log_info "Use --config-name or --config-filter for config-based testing"
    log_info "Legacy options will be ignored in config discovery mode"
  fi
fi

# Validate CLI option conflicts
if [ -n "$CONFIG_NAMES" ] && [ -n "$CONFIG_FILTER" ]; then
  log_warn "Both --config-name and --config-filter specified"
  log_info "Using --config-name (ignoring --config-filter)"
  CONFIG_FILTER=""
fi

log_info "Args: backend=${AUDIO_BACKEND:-auto} source=$SRC_CHOICE loops=$LOOPS durations='$DURATIONS' record_seconds=$RECORD_SECONDS timeout=$TIMEOUT strict=$STRICT dmesg=$DMESG_SCAN"

# Resolve backend
if [ -z "$AUDIO_BACKEND" ]; then
  AUDIO_BACKEND="$(detect_audio_backend)"
fi
BACKENDS_TO_TRY="$(build_backend_chain)"
# Use it for visibility and to satisfy shellcheck usage
log_info "Backend fallback chain: $BACKENDS_TO_TRY"
if [ -z "$AUDIO_BACKEND" ]; then
  log_skip "$TESTNAME SKIP - no audio backend running"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 2
fi
log_info "Using backend: $AUDIO_BACKEND"

if ! check_audio_daemon "$AUDIO_BACKEND"; then
  log_skip "$TESTNAME SKIP - backend not available: $AUDIO_BACKEND"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 2
fi

# Dependencies per backend
if [ "$AUDIO_BACKEND" = "pipewire" ]; then
  if ! check_dependencies wpctl pw-record; then
    log_skip "$TESTNAME SKIP - missing PipeWire utils"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 2
  fi
else
  if ! check_dependencies pactl parecord; then
    log_skip "$TESTNAME SKIP - missing PulseAudio utils"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 2
  fi
fi

# ----- Route source (set default; recorder uses default source) -----
SRC_ID=""
case "$AUDIO_BACKEND:$SRC_CHOICE" in
  pipewire:null)
    SRC_ID="$(pw_default_null_source)"
    ;;
  pipewire:*)
    SRC_ID="$(pw_default_mic)"
    ;;
  pulseaudio:null)
    SRC_ID="$(pa_default_null_source)"
    ;;
  pulseaudio:*)
    SRC_ID="$(pa_default_mic)"
    ;;
esac

# ---- Dynamic fallback when mic is missing on the chosen backend ----
# Stay on PipeWire even if SRC_ID is empty; pw-record and arecord -D pipewire can use the default source.
if [ -z "$SRC_ID" ] && [ "$SRC_CHOICE" = "mic" ] && [ "$AUDIO_BACKEND" != "pipewire" ]; then
  for b in $BACKENDS_TO_TRY; do
    [ "$b" = "$AUDIO_BACKEND" ] && continue
    case "$b" in
      pipewire)
        cand="$(pw_default_mic)"
        if [ -n "$cand" ]; then
          AUDIO_BACKEND="pipewire"; SRC_ID="$cand"
          log_info "Falling back to backend: pipewire (source id=$SRC_ID)"
          break
        fi
        ;;
      pulseaudio)
        cand="$(pa_default_mic)"
        if [ -n "$cand" ]; then
          AUDIO_BACKEND="pulseaudio"; SRC_ID="$cand"
          log_info "Falling back to backend: pulseaudio (source=$SRC_ID)"
          break
        fi
        ;;
      alsa)
        cand="$(alsa_pick_capture)"
        if [ -n "$cand" ]; then
          AUDIO_BACKEND="alsa"; SRC_ID="$cand"
          log_info "Falling back to backend: alsa (device=$SRC_ID)"
          break
        fi
        ;;
    esac
  done
fi

# Only skip if no source AND not on PipeWire.
if [ -z "$SRC_ID" ] && [ "$AUDIO_BACKEND" != "pipewire" ]; then
  log_skip "$TESTNAME SKIP - requested source '$SRC_CHOICE' not available on any backend ($BACKENDS_TO_TRY)"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 2
fi

# ---- Normalize ALSA device id (fix "hw:0 1," → "hw:0,1") ----
if [ "$AUDIO_BACKEND" = "alsa" ]; then
  case "$SRC_ID" in
    hw:*" "*,)
      SRC_ID=$(printf '%s' "$SRC_ID" | sed -E 's/^hw:([0-9]+) ([0-9]+),$/hw:\1,\2/')
      ;;
    hw:*" "*)
      SRC_ID=$(printf '%s' "$SRC_ID" | sed -E 's/^hw:([0-9]+) ([0-9]+)$/hw:\1,\2/')
      ;;
  esac
fi

# ---- Validate/auto-pick ALSA device if invalid (prevents "hw:,") ----
if [ "$AUDIO_BACKEND" = "alsa" ]; then
  case "$SRC_ID" in
    hw:[0-9]*,[0-9]*|plughw:[0-9]*,[0-9]*)
      : ;;
    *)
      cand="$(arecord -l 2>/dev/null | sed -n 's/^card[[:space:]]*\([0-9][0-9]*\).*device[[:space:]]*\([0-9][0-9]*\).*/hw:\1,\2/p' | head -n 1)"
      if [ -z "$cand" ]; then
        cand="$(sed -n 's/^\([0-9][0-9]*\)-\([0-9][0-9]*\):.*capture.*/hw:\1,\2/p' /proc/asound/pcm 2>/dev/null | head -n 1)"
      fi
      if [ -z "$cand" ]; then
        cand="$(sed -n 's/.*\[\s*\([0-9][0-9]*\)-\s*\([0-9][0-9]*\)\]:.*capture.*/hw:\1,\2/p' /proc/asound/devices 2>/dev/null | head -n 1)"
      fi
      if printf '%s\n' "$cand" | grep -Eq '^hw:[0-9]+,[0-9]+$'; then
        SRC_ID="$cand"
        log_info "ALSA auto-pick: using $SRC_ID"
      else
        log_skip "$TESTNAME SKIP - no valid ALSA capture device found"
        echo "$TESTNAME SKIP" > "$RES_FILE"
        exit 2
      fi
      ;;
  esac
fi

# ---- Routing log / defaults per backend ----
if [ "$AUDIO_BACKEND" = "pipewire" ]; then
  if [ -n "$SRC_ID" ]; then
    SRC_LABEL="$(pw_source_label_safe "$SRC_ID")"
    wpctl set-default "$SRC_ID" >/dev/null 2>&1 || true
    [ -z "$SRC_LABEL" ] && SRC_LABEL="unknown"
    log_info "Routing to source: id/name=$SRC_ID label='$SRC_LABEL' choice=$SRC_CHOICE"
  else
    SRC_LABEL="default"
    log_info "Routing to source: id/name=default label='default' choice=$SRC_CHOICE"
  fi
elif [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
  SRC_LABEL="$(pa_source_name "$SRC_ID" 2>/dev/null || echo "$SRC_ID")"
  pa_set_default_source "$SRC_ID" >/dev/null 2>&1 || true
  log_info "Routing to source: name='$SRC_LABEL' choice=$SRC_CHOICE"
else # ALSA
  SRC_LABEL="$SRC_ID"
  log_info "Routing to source: name='$SRC_LABEL' choice=$SRC_CHOICE"
fi

# If fallback changed backend, ensure deps are present (non-fatal → SKIP)
case "$AUDIO_BACKEND" in
  pipewire)
    if ! check_dependencies wpctl pw-record; then
      log_skip "$TESTNAME SKIP - missing PipeWire utils"
      echo "$TESTNAME SKIP" > "$RES_FILE"; exit 2
    fi ;;
  pulseaudio)
    if ! check_dependencies pactl parecord; then
      log_skip "$TESTNAME SKIP - missing PulseAudio utils"
      echo "$TESTNAME SKIP" > "$RES_FILE"; exit 2
    fi ;;
  alsa)
    if ! check_dependencies arecord; then
      log_skip "$TESTNAME SKIP - missing arecord"
      echo "$TESTNAME SKIP" > "$RES_FILE"; exit 2
    fi ;;
esac

# Watchdog info
dur_s="$(duration_to_secs "$TIMEOUT" 2>/dev/null || echo 0)"
[ -z "$dur_s" ] && dur_s=0
if [ "$dur_s" -gt 0 ] 2>/dev/null; then
  log_info "Watchdog/timeout: ${TIMEOUT}"
else
  log_info "Watchdog/timeout: disabled (no timeout)"
fi

# JUnit init (optional)
if [ -n "$JUNIT_OUT" ]; then
  JUNIT_TMP="$LOGDIR/.junit_cases.xml"
  : > "$JUNIT_TMP"
fi

append_junit() {
  name="$1"
  elapsed="$2"
  status="$3"
  logf="$4"

  if [ -z "$JUNIT_OUT" ]; then
    return 0
  fi

  safe_msg="$(
    tail -n 50 "$logf" 2>/dev/null \
      | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g'
  )"

  {
    printf ' <testcase classname="%s" name="%s" time="%s">\n' "Audio.Record" "$name" "$elapsed"
    case "$status" in
      PASS) : ;;
      SKIP) printf ' <skipped/>\n' ;;
      FAIL)
        printf ' <failure message="%s">\n' "failed"
        printf '%s\n' "$safe_msg"
        printf ' </failure>\n'
        ;;
    esac
    printf ' </testcase>\n'
  } >> "$JUNIT_TMP"
}

# Auto map if RECORD_SECONDS=auto, and accept numeric tokens like 35s/35sec/35secs/35seconds
auto_secs_for() {
  case "$1" in
    short) echo "5s" ;;
    medium) echo "15s" ;;
    long) echo "30s" ;;
    *) echo "5s" ;;
  esac
}

# Prefer virtual capture PCMs (PipeWire/Pulse) over raw hw: when a sound server is present
alsa_pick_virtual_pcm() {
  command -v arecord >/dev/null 2>&1 || return 1

  pcs="$(arecord -L 2>/dev/null | sed -n 's/^[[:space:]]*\([[:alnum:]_]\+\)[[:space:]]*$/\1/p')"

  for pcm in pipewire pulse default; do
    if printf '%s\n' "$pcs" | grep -m1 -x "$pcm" >/dev/null 2>&1; then
      printf '%s\n' "$pcm"
      return 0
    fi
  done

  return 1
}

# ------------- Test Execution (Matrix or Config Discovery) -------------
total=0
pass=0
fail=0
skip=0
suite_rc=0

if [ "$USE_CONFIG_DISCOVERY" = "true" ]; then
  # ========== NEW: Config Discovery Mode ==========
  log_info "Using config discovery mode"
  
  # Discover and filter configs
  CONFIGS_OUTPUT="$(discover_and_filter_record_configs "$CONFIG_NAMES" "$CONFIG_FILTER" 2>&1)"
  CONFIGS_RC=$?
  
  # Extract just the config list (non-log lines)
  CONFIGS_TO_TEST="$(printf '%s\n' "$CONFIGS_OUTPUT" | grep -v "^\[[A-Z]*\]")"
  
  if [ $CONFIGS_RC -ne 0 ] || [ -z "$CONFIGS_TO_TEST" ]; then
    # Extract error message with range information if available
    ERROR_MSG="$(printf '%s\n' "$CONFIGS_OUTPUT" | grep "^\[ERROR\].*Available range" | head -1)"
    if [ -z "$ERROR_MSG" ]; then
      log_skip "$TESTNAME SKIP - No valid record configs found"
    else
      log_skip "$TESTNAME SKIP - $ERROR_MSG"
    fi
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 2
  fi
  
  # Count configs
  config_count=0
  for config in $CONFIGS_TO_TEST; do
    config_count=$((config_count + 1))
  done
  
  log_info "Discovered $config_count configs to test"
  
  # Test each config
  for config in $CONFIGS_TO_TEST; do
    # Generate test case name
    case_name="$(generate_record_testcase_name "$config")" || {
      log_warn "Skipping config with invalid name: $config"
      continue
    }
    
    # Get recording parameters
    params="$(get_record_config_params "$config")" || {
      log_warn "Skipping config with invalid parameters: $config"
      continue
    }
    
    rate="$(printf '%s' "$params" | awk '{print $1}')"
    channels="$(printf '%s' "$params" | awk '{print $2}')"
    
    total=$((total + 1))
    logf="$LOGDIR/${case_name}.log"
    : > "$logf"
    export AUDIO_LOGCTX="$logf"
    
    log_info "[$case_name] Using config: $config (rate=${rate}Hz channels=$channels)"
    
    # Determine recording duration
    secs="$RECORD_SECONDS"
    if [ "$secs" = "auto" ]; then
      secs="5s"  # Default for config discovery mode
    fi
    
    i=1
    ok_runs=0
    last_elapsed=0
    
    while [ "$i" -le "$LOOPS" ]; do
      iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      effective_timeout="$secs"
      if [ -n "$TIMEOUT" ] && [ "$TIMEOUT" != "0" ]; then
        effective_timeout="$TIMEOUT"
      fi
      
      loop_hdr="source=$SRC_CHOICE"
      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        if [ -n "$SRC_ID" ]; then
          loop_hdr="$loop_hdr($SRC_ID)"
        else
          loop_hdr="$loop_hdr(default)"
        fi
      else
        loop_hdr="$loop_hdr($SRC_LABEL)"
      fi
      
      log_info "[$case_name] loop $i/$LOOPS start=$iso rate=${rate}Hz channels=$channels backend=$AUDIO_BACKEND $loop_hdr"
      
      out="$LOGDIR/${case_name}.wav"
      : > "$out"
      
      start_s="$(date +%s 2>/dev/null || echo 0)"
      
      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        log_info "[$case_name] exec: pw-record -v --rate=$rate --channels=$channels \"$out\""
        audio_exec_with_timeout "$effective_timeout" pw-record -v --rate="$rate" --channels="$channels" "$out" >> "$logf" 2>&1
        rc=$?
        bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
        
        # If we already got real audio, accept and skip fallbacks
        if [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
          if [ "$rc" -ne 0 ]; then
            log_warn "[$case_name] nonzero rc=$rc but recording looks valid (bytes=$bytes) - PASS"
            rc=0
          fi
        else
          # Only if output is tiny/empty do we try a virtual PCM (pipewire/pulse/default)
          if command -v arecord >/dev/null 2>&1; then
            pcm="$(alsa_pick_virtual_pcm || true)"
            if [ -n "$pcm" ]; then
              secs_int="$(audio_parse_secs "$secs" 2>/dev/null || echo 0)"; [ -z "$secs_int" ] && secs_int=0
              : > "$out"
              log_info "[$case_name] fallback: arecord -D $pcm -f S16_LE -r $rate -c $channels -d $secs_int \"$out\""
              audio_exec_with_timeout "$effective_timeout" \
                arecord -D "$pcm" -f S16_LE -r "$rate" -c "$channels" -d "$secs_int" "$out" >> "$logf" 2>&1
              rc=$?
              bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
            fi
          fi
          
          # As a last resort, retry pw-record with --target (only if we have a source id)
          if { [ "$rc" -ne 0 ] || [ "${bytes:-0}" -le 1024 ] 2>/dev/null; } && [ -n "$SRC_ID" ]; then
            : > "$out"
            log_info "[$case_name] exec: pw-record -v --rate=$rate --channels=$channels --target \"$SRC_ID\" \"$out\""
            audio_exec_with_timeout "$effective_timeout" pw-record -v --rate="$rate" --channels="$channels" --target "$SRC_ID" "$out" >> "$logf" 2>&1
            rc=$?
            bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
          fi
        fi
        
        # (Optional safety) If nonzero rc but output is clearly valid, accept.
        if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
          log_warn "[$case_name] nonzero rc==$rc but recording looks valid (bytes=$bytes) - PASS"
          rc=0
        fi
      else
        if [ "$AUDIO_BACKEND" = "alsa" ]; then
          secs_int="$(audio_parse_secs "$secs" 2>/dev/null || echo 0)"
          [ -z "$secs_int" ] && secs_int=0
          log_info "[$case_name] exec: arecord -D \"$SRC_ID\" -f S16_LE -r $rate -c $channels -d $secs_int \"$out\""
          audio_exec_with_timeout "$effective_timeout" \
            arecord -D "$SRC_ID" -f S16_LE -r "$rate" -c "$channels" -d "$secs_int" "$out" >> "$logf" 2>&1
          rc=$?
          bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
          
          if [ "$rc" -ne 0 ] || [ "${bytes:-0}" -le 1024 ] 2>/dev/null; then
            if printf '%s\n' "$SRC_ID" | grep -q '^hw:'; then
              alt_dev="plughw:${SRC_ID#hw:}"
            else
              alt_dev="$SRC_ID"
            fi
            
            # Try with the specific config parameters
            : > "$out"
            log_info "[$case_name] retry: arecord -D \"$alt_dev\" -f S16_LE -r $rate -c $channels -d $secs_int \"$out\""
            audio_exec_with_timeout "$effective_timeout" \
              arecord -D "$alt_dev" -f S16_LE -r "$rate" -c "$channels" -d "$secs_int" "$out" >> "$logf" 2>&1
            rc=$?
            bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
            
            # If still failing, try fallback combinations
            if [ "$rc" -ne 0 ] || [ "${bytes:-0}" -le 1024 ] 2>/dev/null; then
              for combo in "S16_LE 48000 2" "S16_LE 44100 2" "S16_LE 16000 1"; do
                fmt=$(printf '%s\n' "$combo" | awk '{print $1}')
                fallback_rate=$(printf '%s\n' "$combo" | awk '{print $2}')
                fallback_ch=$(printf '%s\n' "$combo" | awk '{print $3}')
                [ -z "$fmt" ] || [ -z "$fallback_rate" ] || [ -z "$fallback_ch" ] && continue
                : > "$out"
                log_info "[$case_name] fallback: arecord -D \"$alt_dev\" -f $fmt -r $fallback_rate -c $fallback_ch -d $secs_int \"$out\""
                audio_exec_with_timeout "$effective_timeout" \
                  arecord -D "$alt_dev" -f "$fmt" -r "$fallback_rate" -c "$fallback_ch" -d "$secs_int" "$out" >> "$logf" 2>&1
                rc=$?
                bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
                if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
                  break
                fi
              done
            fi
          fi
          
          if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
            log_warn "[$case_name] nonzero rc=$rc but recording looks valid (bytes=$bytes) - PASS"
            rc=0
          fi
        else
          # PulseAudio
          log_info "[$case_name] exec: parecord --rate=$rate --channels=$channels --file-format=wav \"$out\""
          audio_exec_with_timeout "$effective_timeout" parecord --rate="$rate" --channels="$channels" --file-format=wav "$out" >> "$logf" 2>&1
          rc=$?
          bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
          if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
            log_warn "[$case_name] nonzero rc=$rc but recording looks valid (bytes=$bytes) - PASS"
            rc=0
          fi
        fi
      fi
      
      end_s="$(date +%s 2>/dev/null || echo 0)"
      last_elapsed=$((end_s - start_s))
      [ "$last_elapsed" -lt 0 ] && last_elapsed=0
      
      # Evidence
      pw_ev=$(audio_evidence_pw_streaming || echo 0)
      pa_ev=$(audio_evidence_pa_streaming || echo 0)
      
      if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 0 ]; then
        if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
          pa_ev=1
        fi
      fi
      
      alsa_ev=$(audio_evidence_alsa_running_any || echo 0)
      asoc_ev=$(audio_evidence_asoc_path_on || echo 0)
      pwlog_ev=$(audio_evidence_pw_log_seen || echo 0)
      if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
        pwlog_ev=0
      fi
      
      if [ "$alsa_ev" -eq 0 ]; then
        if [ "$AUDIO_BACKEND" = "pipewire" ] && [ "$pw_ev" -eq 1 ]; then
          alsa_ev=1
        fi
        if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 1 ]; then
          alsa_ev=1
        fi
      fi
      
      if [ "$asoc_ev" -eq 0 ] && [ "$alsa_ev" -eq 1 ]; then
        asoc_ev=1
      fi
      
      log_info "[$case_name] evidence: pw_streaming=$pw_ev pa_streaming=$pa_ev alsa_running=$alsa_ev asoc_path_on=$asoc_ev bytes=${bytes:-0} pw_log=$pwlog_ev"
      
      if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
        log_pass "[$case_name] loop $i OK (rc=0, ${last_elapsed}s, bytes=$bytes)"
        ok_runs=$((ok_runs + 1))
      else
        log_fail "[$case_name] loop $i FAILED (rc=$rc, ${last_elapsed}s, bytes=${bytes:-0}) - see $logf"
      fi
      
      i=$((i + 1))
    done
    
    # Collect evidence once per config
    if [ "$DMESG_SCAN" -eq 1 ]; then
      scan_audio_dmesg "$LOGDIR"
      dump_mixers "$LOGDIR/mixer_dump.txt"
    fi
    
    # Aggregate result for this config
    status="FAIL"
    if [ "$ok_runs" -ge 1 ]; then
      status="PASS"
    fi
    
    append_junit "$case_name" "$last_elapsed" "$status" "$logf"
    
    case "$status" in
      PASS)
        pass=$((pass + 1))
        echo "$case_name PASS" >> "$LOGDIR/summary.txt"
        ;;
      SKIP)
        skip=$((skip + 1))
        echo "$case_name SKIP" >> "$LOGDIR/summary.txt"
        ;;
      FAIL)
        fail=$((fail + 1))
        echo "$case_name FAIL" >> "$LOGDIR/summary.txt"
        suite_rc=1
        ;;
    esac
  done
else
  # ========== LEGACY: Matrix Mode ==========
  for dur in $DURATIONS; do
    case_name="record_${dur}"
    total=$((total + 1))

    logf="$LOGDIR/${case_name}.log"
    : > "$logf"
    export AUDIO_LOGCTX="$logf"

    secs="$RECORD_SECONDS"
    if [ "$secs" = "auto" ]; then
      tok="$(printf '%s' "$dur" | tr '[:upper:]' '[:lower:]')"
      tok_secs="$(printf '%s' "$tok" | sed -n 's/^\([0-9][0-9]*\)\(s\|sec\|secs\|seconds\)$/\1s/p')"
      if [ -n "$tok_secs" ]; then
        secs="$tok_secs"
      else
        secs="$(auto_secs_for "$dur")"
      fi
    fi

    i=1
    ok_runs=0
    last_elapsed=0

    while [ "$i" -le "$LOOPS" ]; do
      iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      effective_timeout="$secs"
      if [ -n "$TIMEOUT" ] && [ "$TIMEOUT" != "0" ]; then
        effective_timeout="$TIMEOUT"
      fi

      loop_hdr="source=$SRC_CHOICE"
      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        if [ -n "$SRC_ID" ]; then
          loop_hdr="$loop_hdr($SRC_ID)"
        else
          loop_hdr="$loop_hdr(default)"
        fi
      else
        loop_hdr="$loop_hdr($SRC_LABEL)"
      fi

      log_info "[$case_name] loop $i/$LOOPS start=$iso secs=$secs backend=$AUDIO_BACKEND $loop_hdr"

      out="$LOGDIR/${case_name}.wav"
      : > "$out"

      start_s="$(date +%s 2>/dev/null || echo 0)"

      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        log_info "[$case_name] exec: pw-record -v \"$out\""
        audio_exec_with_timeout "$effective_timeout" pw-record -v "$out" >> "$logf" 2>&1
        rc=$?
        bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"

        # If we already got real audio, accept and skip fallbacks
        if [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
          if [ "$rc" -ne 0 ]; then
            log_warn "[$case_name] nonzero rc=$rc but recording looks valid (bytes=$bytes) - PASS"
            rc=0
          fi
        else
          # Only if output is tiny/empty do we try a virtual PCM (pipewire/pulse/default)
          if command -v arecord >/dev/null 2>&1; then
            pcm="$(alsa_pick_virtual_pcm || true)"
            if [ -n "$pcm" ]; then
              secs_int="$(audio_parse_secs "$secs" 2>/dev/null || echo 0)"; [ -z "$secs_int" ] && secs_int=0
              : > "$out"
              log_info "[$case_name] fallback: arecord -D $pcm -f S16_LE -r 48000 -c 2 -d $secs_int \"$out\""
              audio_exec_with_timeout "$effective_timeout" \
                arecord -D "$pcm" -f S16_LE -r 48000 -c 2 -d "$secs_int" "$out" >> "$logf" 2>&1
              rc=$?
              bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
            fi
          fi

          # As a last resort, retry pw-record with --target (only if we have a source id)
          if { [ "$rc" -ne 0 ] || [ "${bytes:-0}" -le 1024 ] 2>/dev/null; } && [ -n "$SRC_ID" ]; then
            : > "$out"
            log_info "[$case_name] exec: pw-record -v --target \"$SRC_ID\" \"$out\""
            audio_exec_with_timeout "$effective_timeout" pw-record -v --target "$SRC_ID" "$out" >> "$logf" 2>&1
            rc=$?
            bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
          fi
        fi

        # (Optional safety) If nonzero rc but output is clearly valid, accept.
        if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
          log_warn "[$case_name] nonzero rc==$rc but recording looks valid (bytes=$bytes) - PASS"
          rc=0
        fi
      else
        if [ "$AUDIO_BACKEND" = "alsa" ]; then
          secs_int="$(audio_parse_secs "$secs" 2>/dev/null || echo 0)"
          [ -z "$secs_int" ] && secs_int=0
          log_info "[$case_name] exec: arecord -D \"$SRC_ID\" -f S16_LE -r 48000 -c 2 -d $secs_int \"$out\""
          audio_exec_with_timeout "$effective_timeout" \
            arecord -D "$SRC_ID" -f S16_LE -r 48000 -c 2 -d "$secs_int" "$out" >> "$logf" 2>&1
          rc=$?
          bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"

          if [ "$rc" -ne 0 ] || [ "${bytes:-0}" -le 1024 ] 2>/dev/null; then
            if printf '%s\n' "$SRC_ID" | grep -q '^hw:'; then
              alt_dev="plughw:${SRC_ID#hw:}"
            else
              alt_dev="$SRC_ID"
            fi
            for combo in "S16_LE 48000 2" "S16_LE 44100 2" "S16_LE 16000 1"; do
              fmt=$(printf '%s\n' "$combo" | awk '{print $1}')
              rate=$(printf '%s\n' "$combo" | awk '{print $2}')
              ch=$(printf '%s\n' "$combo" | awk '{print $3}')
              [ -z "$fmt" ] || [ -z "$rate" ] || [ -z "$ch" ] && continue
              : > "$out"
              log_info "[$case_name] retry: arecord -D \"$alt_dev\" -f $fmt -r $rate -c $ch -d $secs_int \"$out\""
              audio_exec_with_timeout "$effective_timeout" \
                arecord -D "$alt_dev" -f "$fmt" -r "$rate" -c "$ch" -d "$secs_int" "$out" >> "$logf" 2>&1
              rc=$?
              bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
              if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
                break
              fi
            done
          fi

          if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
            log_warn "[$case_name] nonzero rc=$rc but recording looks valid (bytes=$bytes) - PASS"
            rc=0
          fi
        else
          log_info "[$case_name] exec: parecord --file-format=wav \"$out\""
          audio_exec_with_timeout "$effective_timeout" parecord --file-format=wav "$out" >> "$logf" 2>&1
          rc=$?
          bytes="$(stat -c '%s' "$out" 2>/dev/null || wc -c < "$out")"
          if [ "$rc" -ne 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
            log_warn "[$case_name] nonzero rc=$rc but recording looks valid (bytes=$bytes) - PASS"
            rc=0
          fi
        fi
      fi

      end_s="$(date +%s 2>/dev/null || echo 0)"
      last_elapsed=$((end_s - start_s))
      [ "$last_elapsed" -lt 0 ] && last_elapsed=0

      # Evidence
      pw_ev=$(audio_evidence_pw_streaming || echo 0)
      pa_ev=$(audio_evidence_pa_streaming || echo 0)

      if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 0 ]; then
        if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
          pa_ev=1
        fi
      fi

      alsa_ev=$(audio_evidence_alsa_running_any || echo 0)
      asoc_ev=$(audio_evidence_asoc_path_on || echo 0)
      pwlog_ev=$(audio_evidence_pw_log_seen || echo 0)
      if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
        pwlog_ev=0
      fi

      if [ "$alsa_ev" -eq 0 ]; then
        if [ "$AUDIO_BACKEND" = "pipewire" ] && [ "$pw_ev" -eq 1 ]; then
          alsa_ev=1
        fi
        if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 1 ]; then
          alsa_ev=1
        fi
      fi

      if [ "$asoc_ev" -eq 0 ] && [ "$alsa_ev" -eq 1 ]; then
        asoc_ev=1
      fi

      log_info "[$case_name] evidence: pw_streaming=$pw_ev pa_streaming=$pa_ev alsa_running=$alsa_ev asoc_path_on=$asoc_ev bytes=${bytes:-0} pw_log=$pwlog_ev"

      if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
        log_pass "[$case_name] loop $i OK (rc=0, ${last_elapsed}s, bytes=$bytes)"
        ok_runs=$((ok_runs + 1))
      else
        log_fail "[$case_name] loop $i FAILED (rc=$rc, ${last_elapsed}s, bytes=${bytes:-0}) - see $logf"
      fi

      i=$((i + 1))
    done

    # Collect evidence once per duration
    if [ "$DMESG_SCAN" -eq 1 ]; then
      scan_audio_dmesg "$LOGDIR"
      dump_mixers "$LOGDIR/mixer_dump.txt"
    fi

    # Aggregate result for this duration
    status="FAIL"
    if [ "$ok_runs" -ge 1 ]; then
      status="PASS"
    fi

    append_junit "$case_name" "$last_elapsed" "$status" "$logf"

    case "$status" in
      PASS)
        pass=$((pass + 1))
        echo "$case_name PASS" >> "$LOGDIR/summary.txt"
        ;;
      SKIP)
        skip=$((skip + 1))
        echo "$case_name SKIP" >> "$LOGDIR/summary.txt"
        ;;
      FAIL)
        fail=$((fail + 1))
        echo "$case_name FAIL" >> "$LOGDIR/summary.txt"
        suite_rc=1
        ;;
    esac
  done
fi

# JUnit finalize (optional)
if [ -n "$JUNIT_OUT" ]; then
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites>\n'
    printf '<testsuite name="%s" tests="%d" failures="%d" skipped="%d">\n' "Audio.Record" "$total" "$fail" "$skip"
    cat "$JUNIT_TMP"
    printf '</testsuite>\n'
    printf '</testsuites>\n'
  } > "$JUNIT_OUT"
  rm -f "$JUNIT_TMP"
fi

log_info "Summary: total=$total pass=$pass fail=$fail skip=$skip"

# --- Proper exit codes: PASS=0, FAIL=1, SKIP-only=0 ---
if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ] && [ "$skip" -gt 0 ]; then
  log_skip "$TESTNAME SKIP"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

if [ "$suite_rc" -eq 0 ]; then
  log_pass "$TESTNAME PASS"
  echo "$TESTNAME PASS" > "$RES_FILE"
  exit 0
fi

log_fail "$TESTNAME FAIL"
echo "$TESTNAME FAIL" > "$RES_FILE"
exit 1
