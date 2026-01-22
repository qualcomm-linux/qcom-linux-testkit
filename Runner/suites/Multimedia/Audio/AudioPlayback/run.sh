#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Source init_env & tools ----
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
. "$TOOLS/audio_common.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_video.sh"

TESTNAME="AudioPlayback"
RES_SUFFIX=""  # Optional suffix for unique result files (e.g., "Config1")
# RES_FILE will be set after parsing command-line arguments

# Pre-parse --res-suffix for early failure handling
# This ensures unique result files even if setup fails in parallel CI runs
prev_arg=""
for arg in "$@"; do
  case "$prev_arg" in
    --res-suffix)
      RES_SUFFIX="$arg"
      break
      ;;
  esac
  prev_arg="$arg"
done

# Early failure handling with suffix support
if ! setup_overlay_audio_environment; then
    log_fail "Overlay audio environment setup failed"
    if [ -n "$RES_SUFFIX" ]; then
      echo "$TESTNAME FAIL" > "$SCRIPT_DIR/${TESTNAME}_${RES_SUFFIX}.res"
    else
      echo "$TESTNAME FAIL" > "$SCRIPT_DIR/${TESTNAME}.res"
    fi
    exit 0
fi

# LOGDIR will be set after parsing command-line arguments (to apply RES_SUFFIX correctly)

# ---- Assets ----
AUDIO_TAR_URL="${AUDIO_TAR_URL:-https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/Pulse-Audio-Files-v1.0/AudioClips.tar.gz}"
export AUDIO_TAR_URL

# ------------- Defaults / CLI -------------
AUDIO_BACKEND=""
SINK_CHOICE="${SINK_CHOICE:-speakers}" # speakers|null
FORMATS=""  # Will be set to default only if using legacy mode
DURATIONS=""  # Will be set to default only if using legacy mode
LOOPS="${LOOPS:-1}"
TIMEOUT="${TIMEOUT:-0}" # 0 = no timeout (recommended)
STRICT="${STRICT:-0}"
DMESG_SCAN="${DMESG_SCAN:-1}"
VERBOSE=0
EXTRACT_AUDIO_ASSETS="${EXTRACT_AUDIO_ASSETS:-true}"
ENABLE_NETWORK_DOWNLOAD="${ENABLE_NETWORK_DOWNLOAD:-false}" # Default: no network operations
AUDIO_CLIPS_BASE_DIR="${AUDIO_CLIPS_BASE_DIR:-}" # Custom path for audio clips (CI use)

# New clip-based testing options
CLIP_NAMES=""        # Explicit clip names to test (e.g., "play_48KHz_16b_2ch play_8KHz_8b_1ch")
CLIP_FILTER=""       # Filter pattern for clips (e.g., "48KHz" or "16b")
USE_CLIP_DISCOVERY="${USE_CLIP_DISCOVERY:-auto}"  # auto|true|false

# Network bring-up knobs (match video behavior)
if [ -z "${NET_STABILIZE_SLEEP:-}" ]; then
  NET_STABILIZE_SLEEP="5"
fi
if [ -z "${TOP_LEVEL_RUN:-}" ]; then
  TOP_LEVEL_RUN="1"
fi

SSID=""
PASSWORD=""

usage() {
  cat <<EOF
Usage: $0 [options]
  --backend {pipewire|pulseaudio}
  --sink {speakers|null}
  --formats "wav"                    # Legacy matrix mode only 
  --durations "short|short medium"   # Legacy matrix mode only (not recommended for new tests)
  --clip-name "play_48KHz_16b_2ch"   # Test specific clip(s) by name (space-separated)
                                     # Also supports playback_config1, playback_config2, ..., playback_config10
  --clip-filter "48KHz"              # Filter clips by pattern
  --res-suffix SUFFIX                # Suffix for unique result file (e.g., "Config1")
                                     # Generates AudioPlayback_SUFFIX.res instead of AudioPlayback.res
  --loops N
  --timeout SECS # set 0 to disable watchdog
  --enable-network-download
  --audio-clips-path PATH # Custom location for audio clips (CI use)
  --strict
  --no-dmesg
  --no-extract-assets
  --ssid SSID
  --password PASS
  --verbose
  --help

Testing Modes:
  Clip Discovery Mode (Recommended):
    - Auto-discovers clips from AudioClips directory
    - Use --clip-name or --clip-filter to select specific clips
    - Provides descriptive test case names based on audio format
    - Examples:
        $0 --clip-name "playback_config1 playback_config7"
        $0 --clip-filter "48KHz"
        $0 --clip-name "playback_config1" --res-suffix "Config1"  # CI/LAVA use
  
  Legacy Matrix Mode:
    - Uses --formats and --durations to generate test matrix
    - Maintained for backward compatibility
    - Example:
        $0 --formats "wav" --durations "short medium"
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --backend)
      AUDIO_BACKEND="$2"
      shift 2
      ;;
    --sink)
      SINK_CHOICE="$2"
      shift 2
      ;;
    --formats)
      FORMATS="$2"
      USE_CLIP_DISCOVERY=false  # Explicit formats = use old matrix mode
      shift 2
      ;;
    --durations)
      DURATIONS="$2"
      USE_CLIP_DISCOVERY=false  # Explicit durations = use old matrix mode
      shift 2
      ;;
    --clip-name)
      CLIP_NAMES="$2"
      USE_CLIP_DISCOVERY=true
      shift 2
      ;;
    --clip-filter)
      CLIP_FILTER="$2"
      USE_CLIP_DISCOVERY=true
      shift 2
      ;;
    --res-suffix)
      RES_SUFFIX="$2"
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
    --no-extract-assets)
      EXTRACT_AUDIO_ASSETS=false
      shift
      ;;
    --enable-network-download)
      ENABLE_NETWORK_DOWNLOAD=true
      shift
      ;;
    --audio-clips-path)
      AUDIO_CLIPS_BASE_DIR="$2"
      shift 2
      ;;
    --ssid)
      # shellcheck disable=SC2034
      SSID="$2"
      shift 2
      ;;
    --password)
      # shellcheck disable=SC2034
      PASSWORD="$2"
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

# Auto-enable network download if WiFi credentials provided
if [ -n "$SSID" ] && [ -n "$PASSWORD" ]; then
  log_info "WiFi credentials provided, auto-enabling network download"
  ENABLE_NETWORK_DOWNLOAD=true
fi

# Generate result file path with optional suffix (after parsing CLI args)
# Use absolute path anchored to SCRIPT_DIR for consistency
if [ -n "$RES_SUFFIX" ]; then
  RES_FILE="$SCRIPT_DIR/${TESTNAME}_${RES_SUFFIX}.res"
  log_info "Using unique result file: $RES_FILE"
else
  RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
fi

# Initialize LOGDIR after parsing CLI args (to apply RES_SUFFIX correctly)
# Use absolute paths for LOGDIR to work from any directory
# Apply suffix for unique log directories per invocation (matches RES_FILE behavior)
LOGDIR="$SCRIPT_DIR/results/${TESTNAME}"
if [ -n "$RES_SUFFIX" ]; then
  LOGDIR="${LOGDIR}_${RES_SUFFIX}"
  log_info "Using unique log directory: $LOGDIR"
fi
mkdir -p "$LOGDIR"

# Initialize summary file to prevent accumulation from previous test runs
: > "$LOGDIR/summary.txt"

# ------------- Mode Detection and Validation -------------

# Check for conflicting parameters (discovery vs legacy mode)
if { [ -n "$CLIP_NAMES" ] || [ -n "$CLIP_FILTER" ]; } && { [ -n "$FORMATS" ] || [ -n "$DURATIONS" ]; }; then
  log_error "Cannot mix clip discovery parameters (--clip-name, --clip-filter) with legacy matrix parameters (--formats, --durations)"
  log_error "Please use either clip discovery mode OR legacy matrix mode, not both"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

# Set defaults for legacy mode parameters only if using legacy mode
if [ "$USE_CLIP_DISCOVERY" = "false" ]; then
  FORMATS="${FORMATS:-wav}"
  DURATIONS="${DURATIONS:-short}"
fi

# Determine whether to use clip discovery or legacy matrix mode
if [ "$USE_CLIP_DISCOVERY" = "auto" ]; then
  # Auto mode: use clip discovery if AudioClips directory exists with .wav files
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"
  if [ -d "$clips_dir" ]; then
    # Check for .wav files using shell glob pattern
    wav_found=false
    for wav_file in "$clips_dir"/*.wav; do
      if [ -f "$wav_file" ]; then
        # Found at least one .wav file
        wav_found=true
        break
      fi
    done
    
    if [ "$wav_found" = "true" ]; then
      USE_CLIP_DISCOVERY=true
      log_info "Auto-detected clip discovery mode (found clips in $clips_dir)"
    else
      USE_CLIP_DISCOVERY=false
      log_info "Auto-detected legacy matrix mode (no clips found in $clips_dir)"
    fi
  else
    USE_CLIP_DISCOVERY=false
    log_info "Auto-detected legacy matrix mode (no clips directory found)"
  fi
fi


# Validate CLI option conflicts
if [ -n "$CLIP_NAMES" ] && [ -n "$CLIP_FILTER" ]; then
  log_warn "Both --clip-name and --clip-filter specified"
  log_info "Using --clip-name (ignoring --clip-filter)"
  CLIP_FILTER=""
fi

# Validate numeric parameters
case "$LOOPS" in
  ''|*[!0-9]*) 
    log_error "Invalid --loops value: $LOOPS (must be positive integer)"
    exit 1
    ;;
esac

if [ "$LOOPS" -le 0 ] 2>/dev/null; then
  log_error "Invalid --loops value: $LOOPS (must be positive)"
  exit 1
fi

# Ensure we run from the testcase dir
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
if ! cd "$test_path"; then
  log_error "cd failed: $test_path"
  echo "$TESTNAME FAIL" >"$RES_FILE"
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

# Export AUDIO_CLIPS_BASE_DIR for use by resolve_clip() in audio_common.sh
if [ -n "$AUDIO_CLIPS_BASE_DIR" ]; then
  export AUDIO_CLIPS_BASE_DIR
  log_info "Using custom audio clips path: $AUDIO_CLIPS_BASE_DIR"
fi

log_info "Args: backend=${AUDIO_BACKEND:-auto} sink=$SINK_CHOICE loops=$LOOPS timeout=$TIMEOUT formats='$FORMATS' durations='$DURATIONS' strict=$STRICT dmesg=$DMESG_SCAN extract=$EXTRACT_AUDIO_ASSETS network_download=$ENABLE_NETWORK_DOWNLOAD clips_path=${AUDIO_CLIPS_BASE_DIR:-default}"

# --- Rootfs minimum size check (mirror video policy) ---
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
  ensure_rootfs_min_size 2
else
  log_info "Sub-run: skipping rootfs size check (already performed)."
fi

# --- Smart network gating: only connect if needed ---
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
  if [ "${EXTRACT_AUDIO_ASSETS}" = "true" ]; then
    # First check: Do we have all files we need?
    if audio_check_clips_available "$FORMATS" "$DURATIONS"; then
      log_info "All required audio clips present locally, skipping all network operations"
    else
      # Files missing - check if network download is enabled
      if [ "${ENABLE_NETWORK_DOWNLOAD}" = "true" ]; then
        log_info "Audio clips missing, network download enabled - bringing network online"
        # Now check network status and bring up if needed
        NET_RC="1"
        if command -v check_network_status_rc >/dev/null 2>&1; then
          check_network_status_rc
          NET_RC="$?"
        elif command -v check_network_status >/dev/null 2>&1; then
          check_network_status >/dev/null 2>&1
          NET_RC="$?"
        fi

        if [ "$NET_RC" -ne 0 ]; then
          video_step "" "Bring network online (Wi-Fi credentials if provided)"
          ensure_network_online || true
          sleep "${NET_STABILIZE_SLEEP}"
        else
          sleep "${NET_STABILIZE_SLEEP}"
        fi
        
        # Download and extract audio clips tarball
        log_info "Downloading audio clips from: $AUDIO_TAR_URL"
        if audio_fetch_assets_from_url "$AUDIO_TAR_URL"; then
          log_info "Audio clips downloaded and extracted successfully"
        else
          log_error "Failed to download or extract audio clips from: $AUDIO_TAR_URL"
          log_skip "$TESTNAME SKIP - Audio clips download failed"
          echo "$TESTNAME SKIP" >"$RES_FILE"
          exit 0
        fi
      else
        log_skip "$TESTNAME SKIP - Required audio clips not found locally and network download disabled"
        log_info "To download audio clips, run with: --enable-network-download"
        log_info "Or manually download from: $AUDIO_TAR_URL"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
    fi
  fi
else
  log_info "Sub-run: skipping initial network bring-up."
fi

# Resolve backend
if [ -z "$AUDIO_BACKEND" ]; then
  AUDIO_BACKEND="$(detect_audio_backend)"
fi
if [ -z "$AUDIO_BACKEND" ]; then
  log_skip "$TESTNAME SKIP - no audio backend running"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "Using backend: $AUDIO_BACKEND"

if ! check_audio_daemon "$AUDIO_BACKEND"; then
  log_skip "$TESTNAME SKIP - backend not available: $AUDIO_BACKEND"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# Dependencies per backend
if [ "$AUDIO_BACKEND" = "pipewire" ]; then
  if ! check_dependencies wpctl pw-play; then
    log_skip "$TESTNAME SKIP - missing PipeWire utils"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
else
  if ! check_dependencies pactl paplay; then
    log_skip "$TESTNAME SKIP - missing PulseAudio utils"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
fi

# ----- Route sink (set default; player uses default sink) -----
SINK_ID=""
case "$AUDIO_BACKEND:$SINK_CHOICE" in
  pipewire:null)
    SINK_ID="$(pw_default_null)"
    ;;
  pipewire:*)
    SINK_ID="$(pw_default_speakers)"
    ;;
  pulseaudio:null)
    SINK_ID="$(pa_default_null)"
    ;;
  pulseaudio:*)
    SINK_ID="$(pa_default_speakers)"
    ;;
esac

if [ -z "$SINK_ID" ]; then
  log_skip "$TESTNAME SKIP - requested sink '$SINK_CHOICE' not found for $AUDIO_BACKEND"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if [ "$AUDIO_BACKEND" = "pipewire" ]; then
  SINK_NAME="$(pw_sink_name_safe "$SINK_ID")"
  wpctl set-default "$SINK_ID" >/dev/null 2>&1 || true
  if [ -z "$SINK_NAME" ]; then
    SINK_NAME="unknown"
  fi
  log_info "Routing to sink: id=$SINK_ID name='$SINK_NAME' choice=$SINK_CHOICE"
else
  SINK_NAME="$(pa_sink_name "$SINK_ID")"
  if [ -z "$SINK_NAME" ]; then
    SINK_NAME="$SINK_ID"
  fi
  pa_set_default_sink "$SINK_ID" >/dev/null 2>&1 || true
  log_info "Routing to sink: name='$SINK_NAME' choice=$SINK_CHOICE"
fi

# Decide minimum ok seconds if timeout>0
dur_s="$(duration_to_secs "$TIMEOUT" 2>/dev/null || echo 0)"
if [ -z "$dur_s" ]; then
  dur_s=0
fi

min_ok=0
if [ "$dur_s" -gt 0 ] 2>/dev/null; then
  min_ok=$(expr $dur_s - 1)
  if [ "$min_ok" -lt 1 ]; then
    min_ok=1
  fi
  log_info "Watchdog/timeout: ${TIMEOUT}"
else
  log_info "Watchdog/timeout: disabled (no timeout)"
fi

# ------------- Test Execution (Matrix or Clip Discovery) -------------
total=0
pass=0
fail=0
skip=0
suite_rc=0

if [ "$USE_CLIP_DISCOVERY" = "true" ]; then
  # ========== NEW: Clip Discovery Mode ==========
  log_info "Using clip discovery mode"
  
  # Discover and filter clips
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"
  
  # Get list of clips to test
  if [ -n "$CLIP_NAMES" ] || [ -n "$CLIP_FILTER" ]; then
    # Use discover_and_filter_clips helper (logs go to stderr automatically)
    CLIPS_TO_TEST="$(discover_and_filter_clips "$CLIP_NAMES" "$CLIP_FILTER")" || {
      # Error messages already printed to stderr, just skip
      log_skip "$TESTNAME SKIP - Invalid clip/config name(s) provided"
      echo "$TESTNAME SKIP" > "$RES_FILE"
      exit 0
    }
  else
    # Discover all clips (logs go to stderr automatically)
    CLIPS_TO_TEST="$(discover_audio_clips)" || {
      # Error messages already printed to stderr, just skip
      log_skip "$TESTNAME SKIP - No audio clips found in $clips_dir"
      echo "$TESTNAME SKIP" > "$RES_FILE"
      exit 0
    }
  fi
  
  # Count clips
  clip_count=0
  for clip_file in $CLIPS_TO_TEST; do
    clip_count=$(expr $clip_count + 1)
  done
  
  log_info "Discovered $clip_count clips to test"
  
  # Test each clip
  for clip_file in $CLIPS_TO_TEST; do
    # Generate test case name from clip filename
    case_name="$(generate_clip_testcase_name "$clip_file")" || {
      log_warn "Skipping clip with unparseable name: $clip_file"
      continue
    }
    
    # Resolve full path
    clip_path="$clips_dir/$clip_file"
    
    # Validate clip file
    if ! validate_clip_file "$clip_path"; then
      log_skip "[$case_name] SKIP: Invalid clip file: $clip_path"
      echo "$case_name SKIP (invalid file)" >> "$LOGDIR/summary.txt"
      skip=$(expr $skip + 1)
      continue
    fi
    
    # Extract clip duration for accurate timeout handling
    clip_duration="$(extract_clip_duration "$clip_file" 2>/dev/null || echo 0)"
    if [ "$clip_duration" -gt 0 ] 2>/dev/null; then
      # Use clip duration for timeout calculations
      clip_dur_s="$clip_duration"
      clip_min_ok=$(expr $clip_duration - 1)
      if [ "$clip_min_ok" -lt 1 ]; then
        clip_min_ok=1
      fi
      log_info "[$case_name] Clip duration: ${clip_duration}s (timeout threshold: ${clip_min_ok}s)"
    else
      # Fallback to global timeout values if duration cannot be parsed
      clip_dur_s="$dur_s"
      clip_min_ok="$min_ok"
    fi
    
    total=$(expr $total + 1)
    logf="$LOGDIR/${case_name}.log"
    : > "$logf"
    export AUDIO_LOGCTX="$logf"
    
    CLIP_BYTES="$(file_size_bytes "$clip_path" 2>/dev/null || echo 0)"
    log_info "[$case_name] Using clip: $clip_file (${CLIP_BYTES} bytes)"
    
    i=1
    ok_runs=0
    last_elapsed=0
    
    while [ "$i" -le "$LOOPS" ]; do
      iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      
      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        loop_hdr="sink=$SINK_CHOICE($SINK_ID)"
      else
        loop_hdr="sink=$SINK_CHOICE($SINK_NAME)"
      fi
      
      log_info "[$case_name] loop $i/$LOOPS start=$iso clip=$clip_file backend=$AUDIO_BACKEND $loop_hdr"
      
      # Determine effective timeout: use clip duration when TIMEOUT is disabled
      effective_timeout="$TIMEOUT"
      if [ "$TIMEOUT" = "0" ] || [ "$TIMEOUT" = "" ]; then
        if [ "$clip_duration" -gt 0 ] 2>/dev/null; then
          effective_timeout="$clip_duration"
          log_info "[$case_name] Using clip duration as timeout: ${effective_timeout}s"
        fi
      fi
      
      start_s="$(date +%s 2>/dev/null || echo 0)"
      
      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        log_info "[$case_name] exec: pw-play -v \"$clip_path\""
        audio_exec_with_timeout "$effective_timeout" pw-play -v "$clip_path" >>"$logf" 2>&1
        rc=$?
      else
        log_info "[$case_name] exec: paplay --device=\"$SINK_NAME\" \"$clip_path\""
        audio_exec_with_timeout "$effective_timeout" paplay --device="$SINK_NAME" "$clip_path" >>"$logf" 2>&1
        rc=$?
      fi
      
      end_s="$(date +%s 2>/dev/null || echo 0)"
      last_elapsed=$(expr $end_s - $start_s)
      if [ "$last_elapsed" -lt 0 ]; then
        last_elapsed=0
      fi
      
      # Evidence collection
      pw_ev="$(audio_evidence_pw_streaming || echo 0)"
      pa_ev="$(audio_evidence_pa_streaming || echo 0)"
      
      # Minimal PulseAudio fallback
      if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 0 ]; then
        if [ "$rc" -eq 0 ] || { [ "$rc" -eq 124 ] && [ "$dur_s" -gt 0 ] 2>/dev/null && [ "$last_elapsed" -ge "$min_ok" ]; }; then
          pa_ev=1
        fi
      fi
      
      alsa_ev="$(audio_evidence_alsa_running_any || echo 0)"
      asoc_ev="$(audio_evidence_asoc_path_on || echo 0)"
      pwlog_ev="$(audio_evidence_pw_log_seen || echo 0)"
      if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
        pwlog_ev=0
      fi
      
      # Fast teardown fallback
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
      
      log_info "[$case_name] evidence: pw_streaming=$pw_ev pa_streaming=$pa_ev alsa_running=$alsa_ev asoc_path_on=$asoc_ev pw_log=$pwlog_ev"
      
      # Determine result (use clip-specific timeout thresholds)
      if [ "$rc" -eq 0 ]; then
        log_pass "[$case_name] loop $i OK (rc=0, ${last_elapsed}s)"
        ok_runs=$(expr $ok_runs + 1)
      elif [ "$rc" -eq 124 ] && [ "$clip_dur_s" -gt 0 ] 2>/dev/null && [ "$last_elapsed" -ge "$clip_min_ok" ]; then
        log_warn "[$case_name] TIMEOUT ($TIMEOUT) - PASS (ran ~${last_elapsed}s, expected ${clip_duration}s)"
        ok_runs=$(expr $ok_runs + 1)
      elif [ "$rc" -ne 0 ] && { [ "$pw_ev" -eq 1 ] || [ "$pa_ev" -eq 1 ] || [ "$alsa_ev" -eq 1 ] || [ "$asoc_ev" -eq 1 ]; }; then
        log_warn "[$case_name] nonzero rc=$rc but evidence indicates playback - PASS"
        ok_runs=$(expr $ok_runs + 1)
      else
        log_fail "[$case_name] loop $i FAILED (rc=$rc, ${last_elapsed}s) - see $logf"
      fi
      
      i=$(expr $i + 1)
    done
    
    # Aggregate result for this clip
    if [ "$ok_runs" -ge 1 ]; then
      pass=$(expr $pass + 1)
      echo "$case_name PASS" >> "$LOGDIR/summary.txt"
    else
      fail=$(expr $fail + 1)
      echo "$case_name FAIL" >> "$LOGDIR/summary.txt"
      suite_rc=1
    fi
  done
  
  # Collect evidence once at end (not per clip)
  if [ "$DMESG_SCAN" -eq 1 ]; then
    scan_audio_dmesg "$LOGDIR"
    dump_mixers "$LOGDIR/mixer_dump.txt"
  fi

else
  # ========== LEGACY: Matrix Mode ==========
  
  for fmt in $FORMATS; do
    for dur in $DURATIONS; do
    clip="$(resolve_clip "$fmt" "$dur")"
    case_name="play_${fmt}_${dur}"
    total=$(expr $total + 1)
    logf="$LOGDIR/${case_name}.log"
    : > "$logf"
    export AUDIO_LOGCTX="$logf"

    if [ -z "$clip" ]; then
      log_warn "[$case_name] No clip mapping for format=$fmt duration=$dur"
      echo "$case_name SKIP (no clip mapping)" >> "$LOGDIR/summary.txt"
      skip=$(expr $skip + 1)
      continue
    fi

    # Check if clip is available (should have been downloaded at top level if needed)
    if [ "${EXTRACT_AUDIO_ASSETS}" = "true" ]; then
      if [ -s "$clip" ]; then
        CLIP_BYTES="$(file_size_bytes "$clip" 2>/dev/null || echo 0)"
        log_info "[$case_name] Using clip: $clip (${CLIP_BYTES} bytes)"
      else
        # Clip missing or empty - this shouldn't happen if top-level download succeeded
        log_skip "[$case_name] SKIP: Clip not available: $clip"
        if [ "${ENABLE_NETWORK_DOWNLOAD}" = "true" ]; then
          log_info "[$case_name] Hint: Clip should have been downloaded at test startup"
        else
          log_info "[$case_name] Hint: Run with --enable-network-download to download clips"
        fi
        echo "$case_name SKIP (clip unavailable)" >> "$LOGDIR/summary.txt"
        skip=$(expr $skip + 1)
        continue
      fi
    fi

    i=1
    ok_runs=0
    last_elapsed=0

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
      last_elapsed=$(expr $end_s - $start_s)
      if [ "$last_elapsed" -lt 0 ]; then
        last_elapsed=0
      fi

      # Evidence
      pw_ev="$(audio_evidence_pw_streaming || echo 0)"
      pa_ev="$(audio_evidence_pa_streaming || echo 0)"

      # Minimal PulseAudio fallback so pa_streaming doesn't read as 0 after teardown
      if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 0 ]; then
        if [ "$rc" -eq 0 ] || { [ "$rc" -eq 124 ] && [ "$dur_s" -gt 0 ] 2>/dev/null && [ "$last_elapsed" -ge "$min_ok" ]; }; then
          pa_ev=1
        fi
      fi

      alsa_ev="$(audio_evidence_alsa_running_any || echo 0)"
      asoc_ev="$(audio_evidence_asoc_path_on || echo 0)"
      pwlog_ev="$(audio_evidence_pw_log_seen || echo 0)"
      if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
        pwlog_ev=0
      fi

      # Fast teardown fallback: if user-space stream was active, trust ALSA/ASoC too.
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

      log_info "[$case_name] evidence: pw_streaming=$pw_ev pa_streaming=$pa_ev alsa_running=$alsa_ev asoc_path_on=$asoc_ev pw_log=$pwlog_ev"

      if [ "$rc" -eq 0 ]; then
        log_pass "[$case_name] loop $i OK (rc=0, ${last_elapsed}s)"
        ok_runs=$(expr $ok_runs + 1)
      elif [ "$rc" -eq 124 ] && [ "$dur_s" -gt 0 ] 2>/dev/null && [ "$last_elapsed" -ge "$min_ok" ]; then
        log_warn "[$case_name] TIMEOUT ($TIMEOUT) - PASS (ran ~${last_elapsed}s)"
        ok_runs=$(expr $ok_runs + 1)
      elif [ "$rc" -ne 0 ] && { [ "$pw_ev" -eq 1 ] || [ "$pa_ev" -eq 1 ] || [ "$alsa_ev" -eq 1 ] || [ "$asoc_ev" -eq 1 ]; }; then
        log_warn "[$case_name] nonzero rc=$rc but evidence indicates playback - PASS"
        ok_runs=$(expr $ok_runs + 1)
      else
        log_fail "[$case_name] loop $i FAILED (rc=$rc, ${last_elapsed}s) - see $logf"
      fi

      i=$(expr $i + 1)
    done

    if [ "$ok_runs" -ge 1 ]; then
      pass=$(expr $pass + 1)
      echo "$case_name PASS" >> "$LOGDIR/summary.txt"
    else
      fail=$(expr $fail + 1)
      echo "$case_name FAIL" >> "$LOGDIR/summary.txt"
      suite_rc=1
    fi
    done
  done
  
  # Collect evidence once at end (not per test case)
  if [ "$DMESG_SCAN" -eq 1 ]; then
    scan_audio_dmesg "$LOGDIR"
    dump_mixers "$LOGDIR/mixer_dump.txt"
  fi
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
