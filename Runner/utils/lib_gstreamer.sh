#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Runner/utils/lib_gstreamer.sh
#
# GStreamer helpers.
#
# Contract:
# - run.sh sources functestlib.sh, and other required lib_* (optional), then this file.
# - run.sh decides PASS/FAIL/SKIP and writes .res (and always exits 0).
#
# POSIX only.

GSTBIN="${GSTBIN:-gst-launch-1.0}"
GSTINSPECT="${GSTINSPECT:-gst-inspect-1.0}"
GSTDISCOVER="${GSTDISCOVER:-gst-discoverer-1.0}"
GSTLAUNCHFLAGS="${GSTLAUNCHFLAGS:--e -v -m}"

# Optional env overrides (set by run.sh)
# GST_ALSA_PLAYBACK_DEVICE=hw:0,0
# GST_ALSA_CAPTURE_DEVICE=hw:0,1

# -------------------- Shared artifact directory (generic) --------------------
# gstreamer_shared_artifact_dir <env_var_name> <shared_subdir> <local_subdir> <script_dir> <outdir>
# Generic function to get shared artifact directory for any test type.
# Priority:
# 1. Environment variable if explicitly provided (e.g., VIDEO_SHARED_ENCODE_DIR, AUDIO_SHARED_RECORDED_DIR)
# 2. A job-shared path derived from the common LAVA prefix before /tests/
# 3. Fallback to <outdir>/<local_subdir> for local/manual runs
#
# Parameters:
#   env_var_name: Name of environment variable to check (e.g., "VIDEO_SHARED_ENCODE_DIR")
#   shared_subdir: Subdirectory name for shared path (e.g., "video-encode-decode", "audio-record-playback")
#   local_subdir: Subdirectory name for local fallback (e.g., "encoded", "recorded")
#   script_dir: Script directory path
#   outdir: Output directory path
#
# Example usage:
#   gstreamer_shared_artifact_dir "VIDEO_SHARED_ENCODE_DIR" "video-encode-decode" "encoded" "$SCRIPT_DIR" "$OUTDIR"
#   gstreamer_shared_artifact_dir "AUDIO_SHARED_RECORDED_DIR" "audio-record-playback" "recorded" "$SCRIPT_DIR" "$OUTDIR"
gstreamer_shared_artifact_dir() {
    env_var_name="$1"
    shared_subdir="$2"
    local_subdir="$3"
    script_dir="$4"
    outdir="$5"

    # Check if environment variable is set (using eval for dynamic variable name)
    env_value=$(eval "printf '%s' \"\${${env_var_name}:-}\"")
    if [ -n "$env_value" ]; then
        printf '%s\n' "$env_value"
        return 0
    fi

    # Check if we're in a LAVA test structure (contains /tests/)
    case "$script_dir" in
        */tests/*)
            printf '%s/shared/%s\n' "${script_dir%%/tests/*}" "$shared_subdir"
            ;;
        *)
            printf '%s/%s\n' "$outdir" "$local_subdir"
            ;;
    esac
}

# -------------------- Shared encoded-artifact directory (video) --------------------
# gstreamer_shared_encoded_dir <script_dir> <outdir>
# Prints a directory path to use for encoded video artifacts.
# This is a wrapper around gstreamer_shared_artifact_dir for backward compatibility.
# Priority:
# 1. VIDEO_SHARED_ENCODE_DIR if explicitly provided
# 2. A job-shared path derived from the common LAVA prefix before /tests/
# 3. Fallback to <outdir>/encoded for local/manual runs
gstreamer_shared_encoded_dir() {
    script_dir="$1"
    outdir="$2"
    
    gstreamer_shared_artifact_dir "VIDEO_SHARED_ENCODE_DIR" "video-encode-decode" "encoded" "$script_dir" "$outdir"
}

# -------------------- Shared recorded-artifact directory (audio) --------------------
# gstreamer_shared_recorded_dir <script_dir> <outdir>
# Prints a directory path to use for recorded audio artifacts.
# Priority:
# 1. AUDIO_SHARED_RECORDED_DIR if explicitly provided
# 2. A job-shared path derived from the common LAVA prefix before /tests/
# 3. Fallback to <outdir>/recorded for local/manual runs
gstreamer_shared_recorded_dir() {
    script_dir="$1"
    outdir="$2"
    
    gstreamer_shared_artifact_dir "AUDIO_SHARED_RECORDED_DIR" "audio-record-playback" "recorded" "$script_dir" "$outdir"
}
# -------------------- Element check --------------------
has_element() {
  elem="$1"
  [ -n "$elem" ] || return 1
  command -v "$GSTINSPECT" >/dev/null 2>&1 || return 1
  "$GSTINSPECT" "$elem" >/dev/null 2>&1
}

# -------------------- Pretty printing (multi-line) --------------------
gstreamer_pretty_pipeline() {
  pipe="$1"
  printf '%s\n' "$pipe" | sed 's/[[:space:]]\+![[:space:]]\+/ ! \\\n /g'
}

gstreamer_print_cmd_multiline() {
  pipe="$1"
  log_info "Final gst-launch command:"
  printf '%s \\\n' "$GSTBIN"
  printf ' %s \\\n' "$GSTLAUNCHFLAGS"
  gstreamer_pretty_pipeline "$pipe"
}

# -------------------- ALSA hw discovery (FIXED) --------------------
gstreamer_alsa_pick_playback_hw() {
  if [ -n "${GST_ALSA_PLAYBACK_DEVICE:-}" ]; then
    printf '%s\n' "$GST_ALSA_PLAYBACK_DEVICE"
    return 0
  fi

  # Prefer audio_common if present
  if command -v alsa_pick_playback >/dev/null 2>&1; then
    v="$(alsa_pick_playback 2>/dev/null || true)"
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  fi

  command -v aplay >/dev/null 2>&1 || { printf '%s\n' "default"; return 0; }

  line="$(aplay -l 2>/dev/null \
    | sed -n 's/^card \([0-9][0-9]*\):.*device \([0-9][0-9]*\):.*/\1 \2/p' \
    | head -n1)"

  if [ -n "$line" ]; then
    card="$(printf '%s\n' "$line" | awk '{print $1}')"
    dev="$(printf '%s\n' "$line" | awk '{print $2}')"
    case "$card:$dev" in
      (*[!0-9]*:*|*:*[!0-9]*) : ;;
      (*) printf 'hw:%s,%s\n' "$card" "$dev"; return 0 ;;
    esac
  fi

  printf '%s\n' "default"
  return 0
}

gstreamer_alsa_pick_capture_hw() {
  if [ -n "${GST_ALSA_CAPTURE_DEVICE:-}" ]; then
    printf '%s\n' "$GST_ALSA_CAPTURE_DEVICE"
    return 0
  fi

  # Prefer audio_common's alsa_pick_capture if present
  if command -v alsa_pick_capture >/dev/null 2>&1; then
    v="$(alsa_pick_capture 2>/dev/null || true)"
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  fi

  command -v arecord >/dev/null 2>&1 || { printf '%s\n' "default"; return 0; }

  line="$(arecord -l 2>/dev/null \
    | sed -n 's/^card \([0-9][0-9]*\):.*device \([0-9][0-9]*\):.*/\1 \2/p' \
    | head -n1)"

  if [ -n "$line" ]; then
    card="$(printf '%s\n' "$line" | awk '{print $1}')"
    dev="$(printf '%s\n' "$line" | awk '{print $2}')"
    case "$card:$dev" in
      (*[!0-9]*:*|*:*[!0-9]*) : ;;
      (*) printf 'hw:%s,%s\n' "$card" "$dev"; return 0 ;;
    esac
  fi

  printf '%s\n' "default"
  return 0
}

# -------------------- PipeWire/Pulse default sink selection --------------------
# gstreamer_select_default_sink <backend> <sinkSel> <useNullSink>
gstreamer_select_default_sink() {
  backend="$1"
  sinkSel="$2"
  useNullSink="$3"

  case "$backend" in
    pipewire)
      if [ "$useNullSink" = "1" ] && command -v pw_default_null >/dev/null 2>&1; then
        sid="$(pw_default_null 2>/dev/null || true)"
        if [ -n "$sid" ] && command -v pw_set_default_sink >/dev/null 2>&1; then
          pw_set_default_sink "$sid" >/dev/null 2>&1 || true
          log_info "PipeWire: set default sink to null/dummy id=$sid"
          return 0
        fi
      fi

      if [ -n "$sinkSel" ] && command -v wpctl >/dev/null 2>&1; then
        case "$sinkSel" in
          *[!0-9]*)
            blk="$(wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p')"
            sid="$(printf '%s\n' "$blk" | grep -i "$sinkSel" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' | head -n1)"
            ;;
          *)
            sid="$sinkSel"
            ;;
        esac
        if [ -n "${sid:-}" ] && command -v pw_set_default_sink >/dev/null 2>&1; then
          pw_set_default_sink "$sid" >/dev/null 2>&1 || true
          log_info "PipeWire: set default sink id=$sid (from --sink '$sinkSel')"
          return 0
        fi
      fi
      return 0
      ;;

    pulseaudio)
      if [ "$useNullSink" = "1" ] && command -v pa_default_null >/dev/null 2>&1; then
        sname="$(pa_default_null 2>/dev/null || true)"
        if [ -n "$sname" ] && command -v pa_set_default_sink >/dev/null 2>&1; then
          pa_set_default_sink "$sname" >/dev/null 2>&1 || true
          log_info "PulseAudio: set default sink to null/dummy '$sname'"
          return 0
        fi
      fi

      if [ -n "$sinkSel" ] && command -v pa_sink_name >/dev/null 2>&1 && command -v pa_set_default_sink >/dev/null 2>&1; then
        sname="$(pa_sink_name "$sinkSel" 2>/dev/null || true)"
        if [ -n "$sname" ]; then
          pa_set_default_sink "$sname" >/dev/null 2>&1 || true
          log_info "PulseAudio: set default sink '$sname' (from --sink '$sinkSel')"
          return 0
        fi
      fi
      return 0
      ;;

    alsa)
      return 0
      ;;

    *)
      return 1
      ;;
  esac
}

# -------------------- Sink element picker (backend-aware) --------------------
# Prints sink element string or empty (meaning: no usable sink).
gstreamer_pick_sink_element() {
  backend="$1"
  alsadev="$2"
  [ -n "$alsadev" ] || alsadev="default"

  case "$backend" in
    pipewire)
      if has_element pipewiresink; then
        printf '%s\n' "pipewiresink"
        return 0
      fi
      if has_element pulsesink; then
        printf '%s\n' "pulsesink"
        return 0
      fi
      if has_element alsasink; then
        printf '%s\n' "alsasink device=$alsadev"
        return 0
      fi
      ;;
    pulseaudio)
      if has_element pulsesink; then
        printf '%s\n' "pulsesink"
        return 0
      fi
      ;;
    alsa)
      if has_element alsasink; then
        printf '%s\n' "alsasink device=$alsadev"
        return 0
      fi
      ;;
  esac

  printf '%s\n' ""
  return 0
}

# -------------------- Decoder chain pickers --------------------
gstreamer_pick_aac_decode_chain() {
  if has_element aacparse && has_element avdec_aac; then
    printf '%s\n' "aacparse ! avdec_aac"
    return 0
  fi
  if has_element aacparse && has_element faad; then
    printf '%s\n' "aacparse ! faad"
    return 0
  fi
  printf '%s\n' "decodebin"
  return 0
}

gstreamer_pick_mp3_decode_chain() {
  if has_element mpegaudioparse && has_element mpg123audiodec; then
    printf '%s\n' "mpegaudioparse ! mpg123audiodec"
    return 0
  fi
  if has_element mpegaudioparse && has_element mad; then
    printf '%s\n' "mpegaudioparse ! mad"
    return 0
  fi
  printf '%s\n' "decodebin"
  return 0
}

gstreamer_pick_flac_decode_chain() {
  if has_element flacparse && has_element flacdec; then
    printf '%s\n' "flacparse ! flacdec"
    return 0
  fi
  printf '%s\n' "decodebin"
  return 0
}

gstreamer_pick_wav_decode_chain() {
  if has_element wavparse; then
    printf '%s\n' "wavparse"
    return 0
  fi
  printf '%s\n' "decodebin"
  return 0
}

gstreamer_pick_decode_chain() {
  format="$1"
  case "$format" in
    aac) gstreamer_pick_aac_decode_chain ;;
    flac) gstreamer_pick_flac_decode_chain ;;
    mp3) gstreamer_pick_mp3_decode_chain ;;
    wav) gstreamer_pick_wav_decode_chain ;;
    *) printf '%s\n' "decodebin" ;;
  esac
}

# -------------------- Device-provided assets provisioning (reusable) --------------------
# gstreamer_assets_provision <assetsPath> <clipsDir> <scriptDir>
# Prints final clipsDir (or empty if none)
gstreamer_assets_provision() {
  assetsPath="$1"
  clipsDir="$2"
  scriptDir="$3"

  [ -n "$assetsPath" ] || { printf '%s\n' "${clipsDir:-}"; return 0; }

  if [ -d "$assetsPath" ]; then
    printf '%s\n' "$assetsPath"
    return 0
  fi

  if [ ! -f "$assetsPath" ]; then
    log_warn "Invalid assets path: $assetsPath"
    printf '%s\n' "${clipsDir:-}"
    return 0
  fi

  if [ -z "$clipsDir" ]; then
    clipsDir="${scriptDir:-.}/AudioClips"
  fi

  mkdir -p "$clipsDir" >/dev/null 2>&1 || true
  log_info "Extracting assets into clipsDir=$clipsDir"

  tar -xzf "$assetsPath" -C "$clipsDir" >/dev/null 2>&1 \
    || tar -xJf "$assetsPath" -C "$clipsDir" >/dev/null 2>&1 \
    || tar -xf "$assetsPath" -C "$clipsDir" >/dev/null 2>&1 \
    || log_warn "Failed to extract assets: $assetsPath"

  printf '%s\n' "$clipsDir"
  return 0
}

# -------------------- Clip metadata + caps inference (reusable) --------------------
# gstreamer_log_clip_metadata <clip> <metaLog>
gstreamer_log_clip_metadata() {
  clip="$1"
  metaLog="$2"

  [ -n "$clip" ] || return 1
  [ -n "$metaLog" ] || return 1
  command -v "$GSTDISCOVER" >/dev/null 2>&1 || return 1
  [ -f "$clip" ] || return 1

  : >"$metaLog" 2>/dev/null || true

  "$GSTDISCOVER" "$clip" >"$metaLog" 2>&1 || true

  log_info "Clip metadata ($GSTDISCOVER):"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    log_info "$line"
  done <"$metaLog"

  return 0
}

# gstreamer_infer_audio_params_from_meta <metaLog>
# Prints: "<rate> <channels>" (either can be empty)
gstreamer_infer_audio_params_from_meta() {
  metaLog="$1"
  [ -f "$metaLog" ] || { printf '%s\n' " "; return 0; }

  rate=""
  ch=""

  # Prefer explicit keys first (avoids matching "Bitrate")
  rate="$(grep -i -m1 -E '^[[:space:]]*Sample[[:space:]]+rate[[:space:]]*[:=][[:space:]]*[0-9]+' "$metaLog" 2>/dev/null \
    | sed -n 's/.*[:=][[:space:]]*\([0-9][0-9]*\).*/\1/p')"

  ch="$(grep -i -m1 -E '^[[:space:]]*Channels[[:space:]]*[:=][[:space:]]*[0-9]+' "$metaLog" 2>/dev/null \
    | sed -n 's/.*[:=][[:space:]]*\([0-9][0-9]*\).*/\1/p')"

  # Fallback: audio/x-raw caps line
  if [ -z "$rate" ] || [ -z "$ch" ]; then
    capsLine="$(grep -m1 -E 'audio/x-raw' "$metaLog" 2>/dev/null || true)"
    if [ -z "$rate" ] && [ -n "$capsLine" ]; then
      rate="$(printf '%s' "$capsLine" | sed -n 's/.*rate[^0-9]*\([0-9][0-9]*\).*/\1/p')"
    fi
    if [ -z "$ch" ] && [ -n "$capsLine" ]; then
      ch="$(printf '%s' "$capsLine" | sed -n 's/.*channels[^0-9]*\([0-9][0-9]*\).*/\1/p')"
    fi
  fi

  printf '%s %s\n' "${rate:-}" "${ch:-}"
  return 0
}

# gstreamer_build_capsfilter_string <rate> <channels>
# Prints "audio/x-raw[,rate=...][,channels=...]" or "" if neither set.
gstreamer_build_capsfilter_string() {
  rate="$1"
  channels="$2"

  if [ -n "$rate" ]; then
    case "$rate" in *[!0-9]* ) rate="";; esac
  fi
  if [ -n "$channels" ]; then
    case "$channels" in *[!0-9]* ) channels="";; esac
  fi

  if [ -z "$rate" ] && [ -z "$channels" ]; then
    printf '%s\n' ""
    return 0
  fi

  caps="audio/x-raw"
  if [ -n "$rate" ]; then
    caps="${caps},rate=${rate}"
  fi
  if [ -n "$channels" ]; then
    caps="${caps},channels=${channels}"
  fi

  printf '%s\n' "$caps"
  return 0
}

# -------------------- Evidence (central wrapper) --------------------
gstreamer_backend_evidence() {
  backend="$1"

  case "$backend" in
    pipewire)
      command -v audio_evidence_pw_streaming >/dev/null 2>&1 && {
        v="$(audio_evidence_pw_streaming 2>/dev/null || echo 0)"
        [ "$v" -eq 1 ] 2>/dev/null && { echo 1; return; }
      }
      ;;
    pulseaudio)
      command -v audio_evidence_pa_streaming >/dev/null 2>&1 && {
        v="$(audio_evidence_pa_streaming 2>/dev/null || echo 0)"
        [ "$v" -eq 1 ] 2>/dev/null && { echo 1; return; }
      }
      ;;
    alsa)
      command -v audio_evidence_alsa_running_any >/dev/null 2>&1 && {
        v="$(audio_evidence_alsa_running_any 2>/dev/null || echo 0)"
        [ "$v" -eq 1 ] 2>/dev/null && { echo 1; return; }
      }
      ;;
  esac

  command -v audio_evidence_asoc_path_on >/dev/null 2>&1 && {
    audio_evidence_asoc_path_on
    return
  }

  echo 0
}

gstreamer_backend_evidence_sampled() {
  backend="$1"
  tries="${2:-3}"

  case "$tries" in ''|*[!0-9]*) tries=3 ;; esac

  i=0
  while [ "$i" -lt "$tries" ] 2>/dev/null; do
    v="$(gstreamer_backend_evidence "$backend")"
    [ "$v" -eq 1 ] 2>/dev/null && { echo 1; return; }
    sleep 1
    i=$((i + 1))
  done

  echo 0
}

# -------------------- Single runner: gst-launch with timeout --------------------
# gstreamer_run_gstlaunch_timeout <secs> <pipelineString>
# Returns gst-launch rc.
#
# Sends SIGINT (not SIGTERM) to trigger proper EOS handling via -e flag.
# This ensures pipelines with muxers (mp4mux, etc.) can finalize output files.
gstreamer_run_gstlaunch_timeout() {
  secs="$1"
  pipe="$2"

  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  command -v "$GSTBIN" >/dev/null 2>&1 || return 127

  gstreamer_print_cmd_multiline "$pipe"

  if [ "$secs" -gt 0 ] 2>/dev/null; then
    if command -v timeout >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      # Send SIGINT instead of SIGTERM to trigger EOS via -e flag
      timeout --signal=INT "$secs" "$GSTBIN" $GSTLAUNCHFLAGS $pipe
      return $?
    else
      log_warn "No timeout command available, running without timeout"
    fi
  fi

  # shellcheck disable=SC2086
  "$GSTBIN" $GSTLAUNCHFLAGS $pipe
  return $?
}

# -------------------- Audio Record/Playback pipeline builders --------------------
# gstreamer_build_audio_record_pipeline <source_type> <format> <output_file> [num_buffers]
# Builds audio recording pipeline with specified source
# Parameters:
#   source_type: "audiotestsrc" or "pulsesrc"
#   format: "wav" or "flac"
#   output_file: path to output file
#   num_buffers: (optional) number of buffers for audiotestsrc (ignored for pulsesrc)
# Prints: pipeline string or empty if format/source not supported
gstreamer_build_audio_record_pipeline() {
  source_type="$1"
  fmt="$2"
  output_file="$3"
  num_buffers="${4:-}"

  # Build source element
  case "$source_type" in
    audiotestsrc)
      # num_buffers is required for audiotestsrc
      if [ -z "$num_buffers" ]; then
        printf '%s\n' ""
        return 1
      fi
      source_elem="audiotestsrc wave=sine freq=440 volume=1.0 num-buffers=${num_buffers}"
      ;;
    pulsesrc)
      # pulsesrc doesn't use num_buffers (continuous capture until timeout)
      source_elem="pulsesrc volume=10"
      ;;
    *)
      printf '%s\n' ""
      return 1
      ;;
  esac

  # Build encoder element
  case "$fmt" in
    wav)
      encoder_elem="wavenc"
      ;;
    flac)
      encoder_elem="flacenc"
      ;;
    *)
      printf '%s\n' ""
      return 1
      ;;
  esac

  # Construct complete pipeline
  printf '%s\n' "${source_elem} ! audioconvert ! audioresample ! ${encoder_elem} ! filesink location=${output_file}"
  return 0
}


# -------------------- Playback pipeline builder (backend-aware) --------------------
# gstreamer_build_playback_pipeline <backend> <format> <file> <capsStrOrEmpty> <alsadev>
gstreamer_build_playback_pipeline() {
  backend="$1"
  format="$2"
  file="$3"
  capsStr="$4"
  alsadev="$5"

  [ -n "$alsadev" ] || alsadev="default"

  dec="$(gstreamer_pick_decode_chain "$format")"
  sinkElem="$(gstreamer_pick_sink_element "$backend" "$alsadev")"
  if [ -z "$sinkElem" ]; then
    printf '%s\n' ""
    return 0
  fi

  if [ -n "$capsStr" ]; then
    printf '%s\n' "filesrc location=${file} ! ${dec} ! audioconvert ! audioresample ! ${capsStr} ! ${sinkElem}"
    return 0
  fi

  printf '%s\n' "filesrc location=${file} ! ${dec} ! audioconvert ! audioresample ! ${sinkElem}"
  return 0
}


# gstreamer_build_audio_playback_pipeline <format> <input_file>
# Builds audio playback pipeline using pulsesink
# Supports: wav, flac, ogg, mp3 formats
# Prints: pipeline string or empty if format not supported
gstreamer_build_audio_playback_pipeline() {
  _fmt="$1"
  _input_file="$2"

  case "$_fmt" in
    wav)
      printf '%s\n' "filesrc location=${_input_file} ! wavparse ! audioconvert ! pulsesink volume=10"
      return 0
      ;;
    flac)
      printf '%s\n' "filesrc location=${_input_file} ! flacparse ! flacdec ! audioconvert ! pulsesink volume=10"
      return 0
      ;;
    ogg)
      printf '%s\n' "filesrc location=${_input_file} ! oggdemux ! vorbisdec ! audioconvert ! pulsesink volume=10"
      return 0
      ;;
    mp3)
      printf '%s\n' "filesrc location=${_input_file} ! mpegaudioparse ! mpg123audiodec ! audioconvert ! pulsesink volume=10"
      return 0
      ;;
    *)
      printf '%s\n' ""
      return 1
      ;;
  esac
}

# -------------------- GStreamer error log checker --------------------
# gstreamer_check_errors <logfile>
# Returns: 0 if no critical errors found, 1 if errors found
# Checks for common GStreamer ERROR patterns that indicate failure
# Uses severity-based matching to avoid false positives on benign logs
gstreamer_check_errors() {
  logfile="$1"

  [ -f "$logfile" ] || return 0

  filtered_log="${logfile}.filtered.$$"
  check_log="$logfile"

  # Ignore known benign warnings seen on successful downstream V4L2 decode paths.
  if sed \
    -e '/gst_video_info_dma_drm_to_caps: assertion .*drm_fourcc != DRM_FORMAT_INVALID/d' \
    -e "/gst_structure_remove_field: assertion 'IS_MUTABLE (structure)' failed/d" \
    -e '/WARN.*udmabuf-allocator.*Udmabuf allocator not available.*can'\''t open \/dev\/udmabuf/d' \
    "$logfile" >"$filtered_log" 2>/dev/null; then
    check_log="$filtered_log"
  fi

  # Explicit gst-launch / GStreamer ERROR/FATAL lines.
  if grep -q -E '^ERROR:|^FATAL:|^0:[0-9]+:[0-9]+\.[0-9]+ [0-9]+ [^ ]+ (ERROR|FATAL)' "$check_log" 2>/dev/null; then
    rm -f "$filtered_log" 2>/dev/null || true
    return 1
  fi

  # Segmentation faults and signals
  if grep -q -E 'Caught SIGSEGV|Segmentation fault|SIGABRT|SIGBUS|SIGILL' "$check_log" 2>/dev/null; then
    rm -f "$filtered_log" 2>/dev/null || true
    return 1
  fi

  # Element-reported hard failures.
  if grep -q -E 'ERROR: from element|gst.*ERROR|gst.*FATAL' "$check_log" 2>/dev/null; then
    rm -f "$filtered_log" 2>/dev/null || true
    return 1
  fi

  # Known fatal streaming / negotiation failures.
  if grep -q -E 'Internal data stream error|streaming stopped, reason not-negotiated|not-negotiated' "$check_log" 2>/dev/null; then
    rm -f "$filtered_log" 2>/dev/null || true
    return 1
  fi

  # Pipeline / state transition failures.
  if grep -q -E "pipeline doesn't want to preroll|pipeline doesn't want to play|ERROR.*pipeline|ERROR.*failed to change state|ERROR.*state change failed|failed to change state|state change failed" "$check_log" 2>/dev/null; then
    rm -f "$filtered_log" 2>/dev/null || true
    return 1
  fi

  # Resource / file failures.
  if grep -q -E 'Could not open resource|No such file or directory|Failed to open|failed to open' "$check_log" 2>/dev/null; then
    rm -f "$filtered_log" 2>/dev/null || true
    return 1
  fi

  rm -f "$filtered_log" 2>/dev/null || true
  return 0
}

# -------------------- GStreamer log validation with detailed reporting --------------------
# gstreamer_validate_log <logfile> <testname>
# Returns: 0 if validation passes, 1 if errors found
# Logs detailed error information if errors are detected
gstreamer_validate_log() {
  logfile="$1"
  testname="${2:-test}"

  [ -f "$logfile" ] || {
    log_warn "$testname: Log file not found: $logfile"
    return 1
  }

  if ! gstreamer_check_errors "$logfile"; then
    log_fail "$testname: GStreamer fatal errors detected in log"

    grep -E '^ERROR:|^FATAL:|ERROR: from element|gst.*ERROR|gst.*FATAL|Internal data stream error|streaming stopped, reason not-negotiated|not-negotiated|pipeline doesn'\''t want to preroll|pipeline doesn'\''t want to play|failed to change state|state change failed|Could not open resource|No such file or directory|Failed to open|failed to open' \
      "$logfile" 2>/dev/null | head -n 5 | while IFS= read -r line; do
      [ -n "$line" ] && log_fail " $line"
    done

    if grep -q 'not-negotiated' "$logfile" 2>/dev/null; then
      log_fail " Reason: Format negotiation failed (caps mismatch)"
    fi

    if grep -q -E 'Could not open resource|Failed to open|failed to open' "$logfile" 2>/dev/null; then
      log_fail " Reason: File or device access failed"
    fi

    if grep -q 'No such file or directory' "$logfile" 2>/dev/null; then
      log_fail " Reason: File not found"
    fi

    if grep -q -E 'Caught SIGSEGV|Segmentation fault' "$logfile" 2>/dev/null; then
      log_fail " Reason: Segmentation fault (SIGSEGV) - critical crash"
    fi

    if grep -q -E 'SIGABRT|SIGBUS|SIGILL' "$logfile" 2>/dev/null; then
      log_fail " Reason: Fatal signal caught - process crashed"
    fi

    return 1
  fi

  filtered_log="${logfile}.filtered.$$"
  check_log="$logfile"

  # Ignore known benign warnings seen on successful downstream V4L2 decode paths.
  if sed \
    -e '/gst_video_info_dma_drm_to_caps: assertion .*drm_fourcc != DRM_FORMAT_INVALID/d' \
    -e "/gst_structure_remove_field: assertion 'IS_MUTABLE (structure)' failed/d" \
    -e '/WARN.*udmabuf-allocator.*Udmabuf allocator not available.*can'\''t open \/dev\/udmabuf/d' \
    "$logfile" >"$filtered_log" 2>/dev/null; then
    check_log="$filtered_log"
  fi

  # If any CRITICAL lines remain after filtering, decide using success evidence
  # instead of failing blindly on severity alone.
  if grep -q -E '(^CRITICAL:|^FATAL:|gst.*(CRITICAL|FATAL))' "$check_log" 2>/dev/null; then
    playing_seen=0
    eos_seen=0
    complete_seen=0
    caps_seen=0

    if grep -q -E 'Setting pipeline to PLAYING|new-state=\(GstState\)playing' "$logfile" 2>/dev/null; then
      playing_seen=1
    fi

    if grep -q -E 'Got EOS from element|EOS received - stopping pipeline' "$logfile" 2>/dev/null; then
      eos_seen=1
    fi

    if grep -q -E 'Execution ended after|Freeing pipeline' "$logfile" 2>/dev/null; then
      complete_seen=1
    fi

    if grep -q -E 'caps = (video|audio)/x-|caps = image/' "$logfile" 2>/dev/null; then
      caps_seen=1
    fi

    if [ "$eos_seen" -eq 1 ]; then
      complete_seen=1
    fi

    if [ "$playing_seen" -eq 1 ] && [ "$complete_seen" -eq 1 ] && [ "$caps_seen" -eq 1 ]; then
      log_warn "$testname: Non-fatal GStreamer criticals detected, but pipeline completed successfully"
      grep -E '(^CRITICAL:|^FATAL:|gst.*(CRITICAL|FATAL))' "$check_log" 2>/dev/null | head -n 5 | while IFS= read -r line; do
        [ -n "$line" ] && log_warn " $line"
      done
      rm -f "$filtered_log" 2>/dev/null || true
      return 0
    fi

    log_fail "$testname: GStreamer critical/fatal messages detected without clear success evidence"
    grep -E '(^CRITICAL:|^FATAL:|gst.*(CRITICAL|FATAL))' "$check_log" 2>/dev/null | head -n 5 | while IFS= read -r line; do
      [ -n "$line" ] && log_fail " $line"
    done
    rm -f "$filtered_log" 2>/dev/null || true
    return 1
  fi

  rm -f "$filtered_log" 2>/dev/null || true
  return 0
}
# -------------------- Video codec helpers (V4L2) --------------------
# gstreamer_resolution_to_wh <resolution>
# Converts resolution name to width and height
# Prints: "<width> <height>"
gstreamer_resolution_to_wh() {
  res="$1"
  # Validate input
  [ -z "$res" ] && {
    printf '%s %s\n' "640" "480"  # Default resolution if none provided
    return 0
  }
  
  # Convert to lowercase for case-insensitive matching
  res=$(printf '%s' "$res" | tr '[:upper:]' '[:lower:]')
  
  case "$res" in
    480p)
      printf '%s %s\n' "640" "480"
      ;;
    720p)
      printf '%s %s\n' "1280" "720"
      ;;
    1080p|fhd)
      printf '%s %s\n' "1920" "1080"
      ;;
    4k|4K|2160p|uhd)
      printf '%s %s\n' "3840" "2160"
      ;;
    # Support explicit WxH format (e.g. "1920x1080")
    *x*)
      w=$(printf '%s' "$res" | cut -d'x' -f1)
      h=$(printf '%s' "$res" | cut -d'x' -f2)
      case "$w" in
        ''|*[!0-9]*) w="640" ;; # Default if invalid
      esac
      case "$h" in
        ''|*[!0-9]*) h="480" ;; # Default if invalid
      esac
      printf '%s %s\n' "$w" "$h"
      ;;
    *)
      printf '%s %s\n' "640" "480"  # Default for unknown formats
      ;;
  esac
}

# gstreamer_v4l2_encoder_for_codec <codec>
# Returns the V4L2 encoder element for the given codec
# Supports: H.264, H.265 (VP9 is decode-only, no encoder support)
# Prints: encoder element name or empty string if not available
gstreamer_v4l2_encoder_for_codec() {
  codec="$1"
  case "$codec" in
    h264)
      if has_element v4l2h264enc; then
        printf '%s\n' "v4l2h264enc"
        return 0
      fi
      ;;
    h265|hevc)
      if has_element v4l2h265enc; then
        printf '%s\n' "v4l2h265enc"
        return 0
      fi
      ;;
    vp9)
      # VP9 is decode-only, no encoder support
      printf '%s\n' ""
      return 1
      ;;
  esac
  printf '%s\n' ""
  return 1
}

# gstreamer_v4l2_decoder_for_codec <codec>
# Returns the V4L2 decoder element for the given codec
# Prints: decoder element name or empty string if not available
gstreamer_v4l2_decoder_for_codec() {
  codec="$1"
  case "$codec" in
    h264)
      if has_element v4l2h264dec; then
        printf '%s\n' "v4l2h264dec"
        return 0
      fi
      ;;
    h265|hevc)
      if has_element v4l2h265dec; then
        printf '%s\n' "v4l2h265dec"
        return 0
      fi
      ;;
    vp9)
      if has_element v4l2vp9dec; then
        printf '%s\n' "v4l2vp9dec"
        return 0
      fi
      ;;
  esac
  printf '%s\n' ""
  return 1
}

# gstreamer_v4l2_decoder_args <video_stack>
# Returns stack-dependent decoder arguments for V4L2 decoders
# Prints: decoder arguments string (e.g., "capture-io-mode=4 output-io-mode=4") or empty
gstreamer_v4l2_decoder_args() {
  video_stack="$1"
  case "$video_stack" in
    downstream)
      printf '%s\n' "capture-io-mode=4 output-io-mode=4"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

# gstreamer_container_ext_for_codec <codec>
# Returns the default container file extension for the given video codec.
# This standardizes container format selection across encode/decode operations:
#   - H.264/H.265: mp4 container (ISO BMFF/MP4) - encode & decode supported
#   - VP9: webm container (WebM) - decode-only
# 
# The encode pipeline builders (gstreamer_build_v4l2_encode_pipeline) use
# appropriate muxers (mp4mux for H.264/H.265). VP9 encoding is not supported.
# The decode pipeline builders (gstreamer_build_v4l2_decode_pipeline) use
# appropriate demuxers (qtdemux for MP4, matroskademux for WebM).
#
# Prints: file extension (without dot) - "mp4", "webm", etc.
gstreamer_container_ext_for_codec() {
  codec="$1"
  case "$codec" in
    vp9)
      # VP9 uses WebM container format (Matroska-based)
      printf '%s\n' "webm"
      ;;
    h264|h265|hevc)
      # H.264/H.265 use MP4 container format (ISO BMFF)
      printf '%s\n' "mp4"
      ;;
    *)
      # Default to MP4 for unknown codecs
      printf '%s\n' "mp4"
      ;;
  esac
}

# -------------------- Bitrate and file size helpers --------------------
# gstreamer_bitrate_for_resolution <width> <height>
# Returns recommended bitrate in bps based on resolution
# Prints: bitrate in bps
gstreamer_bitrate_for_resolution() {
  width="$1"
  height="$2"
  
  # Default bitrate calculation
  bitrate=8000000
  if [ "$width" -le 640 ]; then
    bitrate=1000000
  elif [ "$width" -le 1280 ]; then
    bitrate=2000000
  elif [ "$width" -le 1920 ]; then
    bitrate=4000000
  fi
  
  printf '%s\n' "$bitrate"
}

# gstreamer_file_size_bytes <filepath>
# Returns file size in bytes (portable across BSD/GNU stat)
# Prints: file size in bytes or 0 if file doesn't exist
gstreamer_file_size_bytes() {
  filepath="$1"
  
  [ -f "$filepath" ] || { printf '%s\n' "0"; return 1; }
  
  # Try BSD stat first, then GNU stat
  file_size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo 0)
  printf '%s\n' "$file_size"
}

# -------------------- V4L2 encode pipeline builder --------------------
# gstreamer_build_v4l2_encode_pipeline <codec> <width> <height> <duration> <framerate> <bitrate> <output_file> <video_stack>
# Builds a complete V4L2 encode pipeline string
# Prints: pipeline string or empty if encoder not available
gstreamer_build_v4l2_encode_pipeline() {
  codec="$1"
  width="$2"
  height="$3"
  duration="$4"
  framerate="$5"
  bitrate="$6"
  output_file="$7"
  video_stack="${8:-upstream}"
  
  # Validate numeric parameters
  case "$duration" in
    ''|*[!0-9]*) duration=30 ;; # Default 30s for invalid/non-numeric duration
  esac
  
  case "$framerate" in
    ''|*[!0-9]*) framerate=30 ;; # Default 30fps for invalid/non-numeric framerate
  esac
  
  encoder=$(gstreamer_v4l2_encoder_for_codec "$codec")
  if [ -z "$encoder" ]; then
    printf '%s\n' ""
    return 1
  fi
  
  # Determine parser based on codec
  case "$codec" in
    h264)
      parser="h264parse"
      ;;
    h265|hevc)
      parser="h265parse"
      ;;
    *)
      parser=""
      ;;
  esac
  
  # Build encoder parameters
  encoder_params="extra-controls=\"controls,video_bitrate=${bitrate}\""
  if [ "$video_stack" = "downstream" ]; then
    encoder_params="${encoder_params} capture-io-mode=4 output-io-mode=4"
  fi
  
  # Calculate total frames with numeric safety
  total_frames=0
  if [ "$duration" -gt 0 ] 2>/dev/null && [ "$framerate" -gt 0 ] 2>/dev/null; then
    total_frames=$((duration * framerate))
  else
    total_frames=900 # Default 30s * 30fps = 900 frames
  fi

  # Build pipeline with mp4mux for MP4 container
  if [ -n "$parser" ]; then
    printf '%s\n' "videotestsrc num-buffers=${total_frames} pattern=smpte ! video/x-raw,width=${width},height=${height},format=NV12,framerate=${framerate}/1 ! ${encoder} ${encoder_params} ! ${parser} ! mp4mux ! filesink location=${output_file}"
  else
    printf '%s\n' "videotestsrc num-buffers=${total_frames} pattern=smpte ! video/x-raw,width=${width},height=${height},format=NV12,framerate=${framerate}/1 ! ${encoder} ${encoder_params} ! mp4mux ! filesink location=${output_file}"
  fi
  
  return 0
}

# -------------------- V4L2 decode pipeline builder --------------------
# gstreamer_build_v4l2_decode_pipeline <codec> <input_file> <video_stack>
# Builds a complete V4L2 decode pipeline string
# Prints: pipeline string or empty if decoder not available
gstreamer_build_v4l2_decode_pipeline() {
  codec="$1"
  input_file="$2"
  video_stack="${3:-upstream}"
  
  decoder=$(gstreamer_v4l2_decoder_for_codec "$codec")
  if [ -z "$decoder" ]; then
    printf '%s\n' ""
    return 1
  fi
  
  # Determine parser and container based on codec
  case "$codec" in
    h264)
      parser="h264parse"
      container="qtdemux"
      ;;
    h265|hevc)
      parser="h265parse"
      container="qtdemux"
      ;;
    vp9)
      # Try to use vp9parse if available, otherwise skip parser
      if has_element vp9parse; then
        parser="vp9parse"
      else
        parser=""
      fi
      container="matroskademux"
      ;;
  esac
  
  # Get stack-dependent decoder arguments
  decoder_args=$(gstreamer_v4l2_decoder_args "$video_stack")
  
  # Build pipeline based on parser availability
  # All supported formats (h264, h265, vp9) have containers (MP4 or WebM)
  if [ -n "$parser" ]; then
    # Use parser if available
    if [ -n "$decoder_args" ]; then
      printf '%s\n' "filesrc location=${input_file} ! ${container} ! ${parser} ! ${decoder} ${decoder_args} ! videoconvert ! fakesink"
    else
      printf '%s\n' "filesrc location=${input_file} ! ${container} ! ${parser} ! ${decoder} ! videoconvert ! fakesink"
    fi
  else
    # Skip parser if not available (e.g. VP9 without vp9parse)
    if [ -n "$decoder_args" ]; then
      printf '%s\n' "filesrc location=${input_file} ! ${container} ! ${decoder} ${decoder_args} ! videoconvert ! fakesink"
    else
      printf '%s\n' "filesrc location=${input_file} ! ${container} ! ${decoder} ! videoconvert ! fakesink"
    fi
  fi
  
  return 0
}

prepare_vp9_from_local_path() {
  src="$1"
  outdir="$2"
  ivf_out="$3"
  webm_out="$4"

  [ -n "$src" ] || return 1
  [ -e "$src" ] || return 1

  # If directory: search inside for clips
  if [ -d "$src" ]; then
    found_webm=$(find "$src" -type f -name '*.webm' 2>/dev/null | head -n 1 || true)
    found_ivf=$(find "$src" -type f -name '*.ivf' 2>/dev/null | head -n 1 || true)

    if [ -n "$found_webm" ] && [ ! -f "$webm_out" ]; then
      cp "$found_webm" "$webm_out" 2>/dev/null || true
    fi
    if [ -n "$found_ivf" ] && [ ! -f "$ivf_out" ]; then
      cp "$found_ivf" "$ivf_out" 2>/dev/null || true
    fi

    [ -f "$webm_out" ] || [ -f "$ivf_out" ]
    return $?
  fi

  # If file: extract to a staging dir (tar/tar.gz/tgz/tar.xz/txz supported)
  if [ -f "$src" ]; then
    stage="$outdir/local_clip_stage"
    mkdir -p "$stage" >/dev/null 2>&1 || true

    case "$src" in
      *.tar)
        tar -xf "$src" -C "$stage" >/dev/null 2>&1 || return 1
        ;;
      *.tar.gz|*.tgz)
        tar -xzf "$src" -C "$stage" >/dev/null 2>&1 || return 1
        ;;
      *.tar.xz|*.txz)
        tar -xJf "$src" -C "$stage" >/dev/null 2>&1 || return 1
        ;;
      *.xz)
        # Could be .tar.xz already handled above, else try decompressing single file
        if command -v xz >/dev/null 2>&1; then
          base=$(basename "$src" .xz)
          out="$stage/$base"
          xz -dc "$src" >"$out" 2>/dev/null || return 1
          case "$out" in
            *.tar)
              tar -xf "$out" -C "$stage" >/dev/null 2>&1 || return 1
              ;;
          esac
        else
          return 1
        fi
        ;;
      *)
        # Unknown file type; still try as a direct clip file
        stage="$src"
        ;;
    esac

    found_webm=$(find "$stage" -type f -name '*.webm' 2>/dev/null | head -n 1 || true)
    found_ivf=$(find "$stage" -type f -name '*.ivf' 2>/dev/null | head -n 1 || true)

    if [ -n "$found_webm" ] && [ ! -f "$webm_out" ]; then
      cp "$found_webm" "$webm_out" 2>/dev/null || true
    fi
    if [ -n "$found_ivf" ] && [ ! -f "$ivf_out" ]; then
      cp "$found_ivf" "$ivf_out" 2>/dev/null || true
    fi

    [ -f "$webm_out" ] || [ -f "$ivf_out" ]
    return $?
  fi

  return 1
}

# --------------------------------------------------------------
# download_resource
#   $1  url   – URL to download
#   $2  dest  – Either a file name or an existing directory.
#   Prints the full path of the downloaded file on stdout.
# --------------------------------------------------------------
download_resource() {
    url=$1
    dest=$2

    if [ -d "${dest}" ]; then
        filename=$(basename "${url}")
        dest="${dest%/}/${filename}"
    fi

    # Check if file already exists and is non-empty
    if [ -f "${dest}" ] && [ -s "${dest}" ]; then
        if command -v realpath >/dev/null 2>&1; then
            realpath "${dest}"
        else
            case "${dest}" in
                ./*) echo "${dest#./}" ;;
                *)   echo "${dest}" ;;
            esac
        fi
        return 0
    fi
    if command -v ensure_network_online >/dev/null 2>&1; then
        if ! ensure_network_online; then
            echo "Network offline/limited; cannot fetch assets"
            return 1
        fi
    fi

    mkdir -p "$(dirname "${dest}")"
    if command -v curl >/dev/null 2>&1; then
        curl -fkL "${url}" -o "${dest}" || { echo "Error: curl failed to download ${url}" >&2; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q "${url}" -O "${dest}" || { echo "Error: wget failed to download ${url}" >&2; return 1; }
    else
        echo "Error: neither 'curl' nor 'wget' is installed." >&2
        return 1
    fi

    # Verify successful download with non-empty file
    if [ ! -s "${dest}" ]; then
        echo "Error: downloaded file is empty: ${dest}" >&2
        return 1
    fi

    if command -v realpath >/dev/null 2>&1; then
        realpath "${dest}"
    else
        case "${dest}" in
        ./*) echo "${dest#./}" ;;
        *)   echo "${dest}" ;;
        esac
    fi
}
# --------------------------------------------------------------
# extract_zip_to_dir
# --------------------------------------------------------------
extract_zip_to_dir() {
    zip_path=$1
    dest_dir=$2

    mkdir -p "${dest_dir}"
    if ! unzip -o "${zip_path}" -d "${dest_dir}" >/dev/null; then
        echo "Unzip of ${zip_path} failed" >&2
        return 1
    fi
}
# -------------------------------------------------------------------------
# check_pipeline_elements <pipeline-string>
#   Verify that every GStreamer element that appears in a gst-launch
#   pipeline is installed on the system (via `has_element`).
#   Returns:
#       0 – all elements are present
#       1 – at least one element is missing
# -------------------------------------------------------------------------
check_pipeline_elements() {
    pipeline="${1:?missing pipeline argument}"
    missing_count=0
    missing_list=""
    total_elements=0

    log_info "Checking elements in pipeline"

    # ---------------------------------------------------------
    # Normalise the pipeline string
    # ---------------------------------------------------------
    pipeline=$(printf '%s' "$pipeline" | tr -d '\\\n')
    pipeline=${pipeline#gst-launch-1.0* }
    #   Remove the literal "gst-launch-1.0" if present
    pipeline=${pipeline#gst-launch-1.0}
    #   Trim any leading whitespace left by the previous step
    pipeline=${pipeline#"${pipeline%%[![:space:]]*}"}
    #   Drop leading option tokens (e.g. "-e", "-v", "--no-fault")
    while [ "${pipeline#-}" != "$pipeline" ]; do
        #   Remove the first token (option) and any following whitespace
        pipeline=${pipeline#* }
        pipeline=${pipeline#"${pipeline%%[![:space:]]*}"}
    done

    # ---------------------------------------------------------
    # Write the token list to a temporary file
    # ---------------------------------------------------------
    tmpfile=$(mktemp)
    printf '%s' "$pipeline" | tr '!' '\n' >"$tmpfile"

    # ---------------------------------------------------------
    # Read the file line‑by‑line – this runs in the *current*
    #    shell, so variable updates survive.
    # ---------------------------------------------------------
    while IFS= read -r element_spec; do
        # ---- NEW ----
        # Strip surrounding whitespace; skip blank lines
        # element_spec=$(printf '%s' "$element_spec" | xargs)
        element_spec=$(printf '%s\n' "$element_spec" | awk '{$1=$1; print}')
        [ -z "$element_spec" ] && continue
        # --------------

        element_name=$(printf '%s' "$element_spec" | cut -d' ' -f1)

        case "$element_name" in
            *.)               log_info "Skipping element reference: $element_name" ; continue ;;
            name=*)           log_info "Skipping property assignment: $element_name" ; continue ;;
            *_::*)            log_info "Skipping property assignment: $element_name" ; continue ;;
            video/*|audio/*|application/*|text/*|image/*)
                            log_info "Skipping caps filter: $element_name" ; continue ;;
            *)
                total_elements=$(( total_elements + 1 ))
                if ! has_element "$element_name"; then
                    missing_count=$(( missing_count + 1 ))
                    missing_list="${missing_list}${element_name} "
                    log_error "Required element missing: $element_name"
                fi
                ;;
        esac
    done <"$tmpfile"
    # Clean up the temporary file
    rm -f "$tmpfile"

    if [ "$missing_count" -eq 0 ]; then
        log_pass "All $total_elements elements in pipeline are available"
        return 0
    else
        log_fail "Missing $missing_count/$total_elements elements: $missing_list"
        return 1
    fi
}
# ----------------------------------------------------------------------
#  Run a pipeline with timeout, capture console output and GST debug logs.
# ----------------------------------------------------------------------
run_pipeline_with_logs() {
    name=$1
    cmd=$2
    logdir=${3:-logs}
    TIMEOUT=${4:-60} # default 60 seconds
    test_type=${5:-}      # Optional: uvc, drc, concurrency-h264, etc. for extended validation
    expected_count=${6:-1} # Optional: For concurrency tests

    console_log="${logdir}/${name}_console.log"
    gst_debug_log="${logdir}/${name}_gst_debug.log"

    export GST_DEBUG_FILE="${gst_debug_log}"

    log_info "Running ${name} (timeout=${TIMEOUT}s)"
    gstreamer_run_gstlaunch_timeout "$TIMEOUT" "$cmd" >"$console_log" 2>&1
    rc=$?

    # Check 1: PLAYING state reached
    playing=$(grep -c "Setting pipeline to PLAYING" "$console_log" || true)
    if [ "$playing" -eq 0 ]; then
        log_fail "${name} FAIL: Pipeline never reached PLAYING state"
        return 1
    fi
    
    # Check 2: No ERROR messages (original check)
    error_present=$(grep -c "ERROR:" "$console_log" || true)
    
    # Extended validation for timeout-based tests (if test_type provided)
    if [ -n "$test_type" ]; then
        log_info "${name}: ✓ PLAYING state reached"
        
        # Check 2b: Negotiated video caps observed (extended check)
        if ! grep -q "caps.*video/x-raw" "$console_log"; then
            log_fail "${name} FAIL: No video caps negotiation detected"
            return 1
        fi
        log_info "${name}: ✓ Video caps negotiated"
        
        # Check 3: No fatal/error patterns (extended check - more comprehensive)
        if grep -qi "ERROR\|CRITICAL\|FATAL" "$console_log"; then
            log_fail "${name} FAIL: Fatal errors detected in log"
            log_info "=== ERROR DETAILS ==="
            grep -i "ERROR\|CRITICAL\|FATAL" "$console_log" | tail -n 20 |
                while IFS= read -r line; do log_info "$line"; done
            log_info "====================="
            return 1
        fi
        log_info "${name}: ✓ No fatal errors"
        
        # Check 4: Test-specific activity evidence
        case "$test_type" in
            uvc)
                # For UVC: REQUIRE positive frame/buffer activity or FPS evidence
                if grep -q "rendered.*frames\|fps.*[0-9]\|frame.*[0-9]" "$console_log"; then
                    log_info "${name}: ✓ Frame activity detected"
                else
                    log_fail "${name}: FAIL - No frame/buffer activity detected (required for UVC test)"
                    return 1
                fi
                ;;
                
            drc)
                # For DRC: REQUIRE ordered 1080p→720p caps transition and frame activity after second caps
                # Expected: 1080p (1920x1080) → 720p (1280x720) transition with frames after 720p
                
                # Extract all video caps lines with line numbers to preserve order
                caps_with_lines=$(grep -n "caps.*video/x-raw" "$console_log" || true)
                
                if [ -z "$caps_with_lines" ]; then
                    log_fail "${name}: FAIL - No video caps events found in console log"
                    return 1
                fi
                
                # Find first 1080p caps event (line number)
                first_1080p_line=$(printf '%s\n' "$caps_with_lines" | grep "width.*1920.*height.*1080\|width=1920.*height=1080\|width=(int)1920.*height=(int)1080" | head -n 1 | cut -d: -f1 || echo "0")
                
                # Find first 720p caps event (line number)
                first_720p_line=$(printf '%s\n' "$caps_with_lines" | grep "width.*1280.*height.*720\|width=1280.*height=720\|width=(int)1280.*height=(int)720" | head -n 1 | cut -d: -f1 || echo "0")
                
                # Sanitize line numbers
                case "$first_1080p_line" in ''|*[!0-9]*) first_1080p_line=0 ;; esac
                case "$first_720p_line" in ''|*[!0-9]*) first_720p_line=0 ;; esac
                
                log_info "${name}: DRC transition analysis:"
                log_info "${name}:   First 1080p caps at line: $first_1080p_line"
                log_info "${name}:   First 720p caps at line: $first_720p_line"
                
                # Verify both resolutions were detected
                if [ "$first_1080p_line" -eq 0 ]; then
                    log_fail "${name}: FAIL - No 1920x1080 caps event found"
                    return 1
                fi
                
                if [ "$first_720p_line" -eq 0 ]; then
                    log_fail "${name}: FAIL - No 1280x720 caps event found"
                    return 1
                fi
                
                # Verify ordered transition: 1080p must come before 720p
                if [ "$first_1080p_line" -ge "$first_720p_line" ]; then
                    log_fail "${name}: FAIL - Invalid transition order (1080p at line $first_1080p_line, 720p at line $first_720p_line)"
                    log_fail "${name}:   Expected: 1080p → 720p (1080p line < 720p line)"
                    return 1
                fi
                
                log_info "${name}: ✓ Ordered transition verified (1080p → 720p)"
                
                # REQUIRE frame activity after the 720p caps event (second resolution)
                # Extract all lines after the 720p caps event
                lines_after_720p=$(tail -n +$((first_720p_line + 1)) "$console_log" || true)
                
                if ! printf '%s\n' "$lines_after_720p" | grep -q "rendered.*frames\|fps.*[0-9]\|frame.*[0-9]"; then
                    log_fail "${name}: FAIL - No frame activity detected after 720p caps event (line $first_720p_line)"
                    log_fail "${name}:   Frame activity is required after the second resolution to verify DRC completed"
                    return 1
                fi
                
                log_info "${name}: ✓ Frame activity detected after 720p transition"
                ;;
                
            concurrency-*)
                # For concurrency: REQUIRE per-branch caps negotiation AND buffer activity
                # Verify that each decoder branch negotiated caps and produced buffers
                codec="${test_type#concurrency-}"
                
                # Determine decoder element name pattern based on codec
                case "$codec" in
                    h264)
                        decoder_pattern="v4l2h264dec[0-9]\+"
                        ;;
                    h265)
                        decoder_pattern="v4l2h265dec[0-9]\+"
                        ;;
                    mjpeg)
                        decoder_pattern="jpegdec[0-9]\+"
                        ;;
                    *)
                        log_fail "${name}: FAIL - Unknown codec for concurrency test: $codec"
                        return 1
                        ;;
                esac
                
                # Extract all unique decoder instance names
                decoder_instances=$(grep -o "$decoder_pattern" "$console_log" 2>/dev/null | sort -u || true)
                decoder_count=$(printf '%s\n' "$decoder_instances" | grep -c . || echo 0)
                
                # Sanitize decoder_count
                case "$decoder_count" in
                    ''|*[!0-9]*) decoder_count=0 ;;
                esac
                
                log_info "${name}: Detected $decoder_count distinct decoder instances (expected: $expected_count)"
                
                # Verify correct number of decoder instances
                if [ "$decoder_count" -ne "$expected_count" ]; then
                    log_fail "${name}: FAIL - Decoder instance count mismatch (found: $decoder_count, expected: $expected_count)"
                    return 1
                fi
                
                log_info "${name}: ✓ Correct number of decoder instances constructed"
                
                # REQUIRE per-branch caps negotiation and buffer activity
                # For each decoder instance, verify it negotiated caps and produced buffers
                log_info "${name}: Verifying per-branch caps negotiation and buffer activity..."
                
                failed_branches=0
                while IFS= read -r decoder_instance; do
                    [ -z "$decoder_instance" ] && continue
                    
                    # Check if this decoder instance has caps negotiation evidence
                    # Look for caps events mentioning this specific decoder instance
                    if ! grep -q "${decoder_instance}.*caps.*video/x-raw\|caps.*video/x-raw.*${decoder_instance}" "$console_log"; then
                        log_fail "${name}:   ✗ ${decoder_instance}: No caps negotiation detected"
                        failed_branches=$((failed_branches + 1))
                        continue
                    fi
                    
                    # Check if this decoder instance has buffer activity evidence
                    # Look for buffer/frame activity mentioning this specific decoder instance
                    if ! grep -q "${decoder_instance}.*buffer\|${decoder_instance}.*frame\|chain.*${decoder_instance}" "$console_log"; then
                        log_fail "${name}:   ✗ ${decoder_instance}: No buffer activity detected"
                        failed_branches=$((failed_branches + 1))
                        continue
                    fi
                    
                    log_info "${name}:   ✓ ${decoder_instance}: Caps negotiated and buffers active"
                done <<EOF
$decoder_instances
EOF
                
                if [ "$failed_branches" -gt 0 ]; then
                    log_fail "${name}: FAIL - $failed_branches/$decoder_count branches failed validation"
                    return 1
                fi
                
                log_info "${name}: ✓ All $decoder_count branches validated (caps + buffers)"
        esac
        
        # Accept timeout (124) or success (0) if all extended checks passed
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; then
            log_pass "${name} PASS"
            return 0
        else
            log_fail "${name} FAIL (unexpected exit code: $rc)"
            return 1
        fi
    else
        # Original validation logic (backward compatible)
        if [ "$playing" -gt 0 ] && [ "$error_present" -eq 0 ]; then
            log_pass "${name} PASS"
            return 0
        fi

        # Special case: timeout (rc = 124) but PLAYING was already reached.
        if [ "$rc" -eq 124 ] && [ "$playing" -gt 0 ]; then
            log_pass "${name} PASS (completed before timeout)"
            return 0
        fi

        # Anything else is a failure.
        log_fail "${name} FAIL (rc=${rc})"
        log_info "=== ERROR DETAILS ==="
        if [ "$error_present" -gt 0 ]; then
            grep -A10 -B5 "ERROR:" "$console_log" | tail -n 30 |
                while IFS= read -r line; do log_info "$line"; done
        else
            tail -n 30 "$console_log" |
                while IFS= read -r line; do log_info "$line"; done
        fi
        log_info "====================="
        return 1
    fi
}
# ------------------------------------------------------------------
# Function:  check_file_size
# Purpose :  Check that a file exists and its size > 0.
# Returns :  0  → file size > 0 (success)
#            1  → file missing, unreadable, or size == 0 (failure)
# Requires:  GNU coreutils (stat -c %s)
# ------------------------------------------------------------------
check_file_size() {
  input_file_path="$1"
  expected_file_size="$2"

  if [ -z "$input_file_path" ]; then
      log_fail "No input file path provided"
      return 1
  fi
  if [ ! -e "$input_file_path" ]; then
      log_fail "Encoded video file does not exist: $input_file_path"
      return 1
  fi

    # ---- Ensure we have `stat` ------------------------------------------------
    if ! command -v stat >/dev/null 2>&1; then
        log_fail "stat command not found – cannot determine file size"
        return 1
    fi

    # ---- Get the actual size -------------------------------------------------
    size_in_bytes=$(stat -c %s "$input_file_path" 2>/dev/null || wc -c <"$input_file_path" 2>/dev/null) || {
        log_fail "Unable to read size of file: $input_file_path"
        return 1
    }

    # ---- Compare with the expected size --------------------------------------
    if [ "$size_in_bytes" -ge "$expected_file_size" ]; then
        log_pass "File OK (size ${size_in_bytes} bytes ≥ ${expected_file_size} bytes): $input_file_path"
        return 0
    else
        log_info "File too small (size ${size_in_bytes} bytes < ${expected_file_size} bytes): $input_file_path"
        return 1
    fi
}

# ==================== Camera Pipeline Builders ====================

# -------------------- Camera format helpers --------------------
# camera_format_to_gst_string <format>
# Converts camera format name to GStreamer format string
# Prints: GStreamer format string (NV12 or NV12_Q08C)
camera_format_to_gst_string() {
  format="$1"
  case "$format" in
    nv12) printf '%s\n' "NV12" ;;
    ubwc) printf '%s\n' "NV12_Q08C" ;;
    *) printf '%s\n' "" ;;
  esac
}

# -------------------- qtiqmmfsrc pipeline builders --------------------
# camera_build_qtiqmmfsrc_fakesink_pipeline <camera_id> <format> <width> <height> <framerate>
# Builds qtiqmmfsrc fakesink test pipeline (uses timeout for duration control)
# Prints: pipeline string
camera_build_qtiqmmfsrc_fakesink_pipeline() {
  camera_id="$1"
  format="$2"
  width="$3"
  height="$4"
  framerate="$5"
  
  gst_format=$(camera_format_to_gst_string "$format")
  [ -z "$gst_format" ] && return 1
  
  if [ "$format" = "ubwc" ]; then
    printf '%s\n' "qtiqmmfsrc camera=${camera_id} name=camsrc ! video/x-raw,format=${gst_format},width=${width},height=${height},framerate=${framerate}/1,interlace-mode=progressive,colorimetry=bt601 ! queue ! fakesink"
  else
    printf '%s\n' "qtiqmmfsrc camera=${camera_id} name=camsrc ! video/x-raw,format=${gst_format},width=${width},height=${height},framerate=${framerate}/1 ! fakesink"
  fi
}

# camera_build_qtiqmmfsrc_preview_pipeline <camera_id> <format> <width> <height> <framerate>
# Builds qtiqmmfsrc preview pipeline with waylandsink
# Prints: pipeline string
camera_build_qtiqmmfsrc_preview_pipeline() {
  camera_id="$1"
  format="$2"
  width="$3"
  height="$4"
  framerate="$5"
  
  gst_format=$(camera_format_to_gst_string "$format")
  [ -z "$gst_format" ] && return 1
  
  if [ "$format" = "ubwc" ]; then
    printf '%s\n' "qtiqmmfsrc camera=${camera_id} name=camsrc ! video/x-raw,format=${gst_format},width=${width},height=${height},framerate=${framerate}/1 ! waylandsink fullscreen=true async=true sync=false"
  else
    printf '%s\n' "qtiqmmfsrc camera=${camera_id} name=camsrc ! video/x-raw,format=${gst_format},width=${width},height=${height},framerate=${framerate}/1 ! waylandsink fullscreen=true async=true sync=false"
  fi
}

# camera_build_qtiqmmfsrc_encode_pipeline <camera_id> <format> <width> <height> <framerate> <output_file>
# Builds qtiqmmfsrc encode pipeline with v4l2h264enc
# Prints: pipeline string
camera_build_qtiqmmfsrc_encode_pipeline() {
  camera_id="$1"
  format="$2"
  width="$3"
  height="$4"
  framerate="$5"
  output_file="$6"
  
  gst_format=$(camera_format_to_gst_string "$format")
  [ -z "$gst_format" ] && return 1
  
  if [ "$format" = "ubwc" ]; then
    printf '%s\n' "qtiqmmfsrc camera=${camera_id} name=camsrc ! video/x-raw,format=${gst_format},width=${width},height=${height},framerate=${framerate}/1,interlace-mode=progressive,colorimetry=bt601 ! queue ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! queue ! filesink location=${output_file}"
  else
    printf '%s\n' "qtiqmmfsrc camera=${camera_id} name=camsrc ! video/x-raw,format=${gst_format},width=${width},height=${height},framerate=${framerate}/1 ! queue ! v4l2h264enc capture-io-mode=4 output-io-mode=4 ! h264parse ! mp4mux ! queue ! filesink location=${output_file}"
  fi
}

# camera_build_qtiqmmfsrc_snapshot_pipeline <camera_id> <width> <height> <framerate> <output_location> <max_files>
# Builds qtiqmmfsrc snapshot pipeline for still image capture
# Uses NV12 format with jpegenc for JPEG output
# Parameters:
#   camera_id: Camera device ID
#   width: Image width
#   height: Image height
#   framerate: Framerate in fps
#   output_location: Output file pattern (e.g., /path/to/camera0_4k_image%d.jpg)
#   max_files: Maximum number of snapshots to capture
# Prints: pipeline string
camera_build_qtiqmmfsrc_snapshot_pipeline() {
  camera_id="$1"
  width="$2"
  height="$3"
  framerate="$4"
  output_location="$5"
  max_files="${6:-2}"
  
  printf '%s\n' "qtiqmmfsrc camera=${camera_id} name=camsrc ! capsfilter caps=\"video/x-raw,format=NV12,width=${width},height=${height},framerate=${framerate}/1\" ! jpegenc ! multifilesink location=\"${output_location}\" max-files=${max_files}"
}

# -------------------- libcamerasrc pipeline builders --------------------
# camera_build_libcamera_fakesink_pipeline <width> <height> <framerate>
# Builds libcamerasrc fakesink pipeline with optional resolution caps (uses timeout for duration control)
# Parameters:
#   width: Video width (0 for no caps filter)
#   height: Video height (0 for no caps filter)
#   framerate: Framerate in fps
# Prints: pipeline string
camera_build_libcamera_fakesink_pipeline() {
  width="$1"
  height="$2"
  framerate="${3:-30}"
  
  # If width/height are 0 or empty, build pipeline without caps filter
  if [ -z "$width" ] || [ -z "$height" ] || [ "$width" -eq 0 ] 2>/dev/null || [ "$height" -eq 0 ] 2>/dev/null; then
    printf '%s\n' "libcamerasrc ! fakesink"
  else
    printf '%s\n' "libcamerasrc ! video/x-raw,width=${width},height=${height},framerate=${framerate}/1 ! fakesink"
  fi
}

# camera_build_libcamera_preview_pipeline <width> <height> <framerate>
# Builds libcamerasrc preview pipeline with optional resolution caps (uses timeout for duration control)
# Parameters:
#   width: Video width (0 for no caps filter)
#   height: Video height (0 for no caps filter)
#   framerate: Framerate in fps
# Prints: pipeline string
camera_build_libcamera_preview_pipeline() {
  width="$1"
  height="$2"
  framerate="${3:-30}"
  
  # If width/height are 0 or empty, build pipeline without caps filter
  if [ -z "$width" ] || [ -z "$height" ] || [ "$width" -eq 0 ] 2>/dev/null || [ "$height" -eq 0 ] 2>/dev/null; then
    printf '%s\n' "libcamerasrc ! videoconvert ! waylandsink fullscreen=true"
  else
    printf '%s\n' "libcamerasrc ! video/x-raw,width=${width},height=${height},framerate=${framerate}/1 ! videoconvert ! waylandsink fullscreen=true"
  fi
}

# camera_build_libcamera_encode_pipeline <width> <height> <output_file> <framerate>
# Builds libcamerasrc encode pipeline with NV12 format (uses timeout for duration control)
# Parameters:
#   width: Video width
#   height: Video height
#   output_file: Output MP4 file path
#   framerate: Framerate in fps
# Prints: pipeline string
camera_build_libcamera_encode_pipeline() {
  width="$1"
  height="$2"
  output_file="$3"
  framerate="${4:-30}"
  
  printf '%s\n' "libcamerasrc ! videoconvert ! video/x-raw,format=NV12,width=${width},height=${height},framerate=${framerate}/1 ! v4l2h264enc capture-io-mode=4 output-io-mode=4 ! h264parse ! mp4mux ! filesink location=${output_file}"
}

# camera_build_libcamera_snapshot_pipeline <width> <height> <output_location> <max_files>
# Builds libcamerasrc snapshot pipeline for still image capture
# Uses src_1::stream-role=still-capture for high-quality still images
# Parameters:
#   width: Image width
#   height: Image height
#   output_location: Output file pattern (e.g., /path/to/snapshot%d.jpg)
#   max_files: Maximum number of snapshots to capture
# Prints: pipeline string
camera_build_libcamera_snapshot_pipeline() {
  width="$1"
  height="$2"
  output_location="$3"
  max_files="${4:-5}"
  
  printf '%s\n' "libcamerasrc name=camsrc src_1::stream-role=still-capture ! video/x-raw,width=${width},height=${height} ! videoconvert ! jpegenc ! multifilesink location=\"${output_location}\" max-files=${max_files}"
}

# -------------------- Wayland/Weston setup helper --------------------
# camera_setup_wayland_environment <test_name>
# Sets up Wayland/Weston environment for camera preview tests
# Sets wayland_ready=1 if successful, 0 otherwise
# Tracks whether Weston was started and registers cleanup trap
# Parameters:
#   test_name: Name of the test for logging purposes
# Returns: 0 if Wayland is ready, 1 otherwise
camera_setup_wayland_environment() {
  test_name="${1:-Camera_Test}"
  
  wayland_ready=0
  sock=""
  
  # Track initial Weston state ONLY on first call (preserve across multiple setup calls)
  # This ensures we remember the original compositor state before any test modifications
  if [ -z "${GSTREAMER_WESTON_INITIAL_STATE:-}" ]; then
    GSTREAMER_WESTON_INITIAL_STATE=0
    if command -v weston_is_running >/dev/null 2>&1; then
      if weston_is_running >/dev/null 2>&1; then
        GSTREAMER_WESTON_INITIAL_STATE=1
      fi
    elif command -v pgrep >/dev/null 2>&1; then
      if pgrep -x weston >/dev/null 2>&1; then
        GSTREAMER_WESTON_INITIAL_STATE=1
      fi
    fi
    export GSTREAMER_WESTON_INITIAL_STATE
    log_info "Captured initial Weston state: $([ "$GSTREAMER_WESTON_INITIAL_STATE" -eq 1 ] && echo 'running' || echo 'not running')"
  fi
  
  # Try to find existing Wayland socket
  if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
    sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
    if [ -n "$sock" ]; then
      log_info "Found existing Wayland socket: $sock"
      if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        if adopt_wayland_env_from_socket "$sock"; then
          wayland_ready=1
          log_info "Adopted Wayland environment from socket"
        fi
      fi
    fi
  fi
  
  # Try starting Weston if no socket found
  if [ "$wayland_ready" -eq 0 ] && [ -z "$sock" ]; then
    if command -v weston_pick_env_or_start >/dev/null 2>&1; then
      log_info "No Wayland socket found, attempting to start Weston..."
      if weston_pick_env_or_start "$test_name"; then
        # Track that we started Weston (for cleanup by runner)
        GSTREAMER_STARTED_WESTON=1
        export GSTREAMER_STARTED_WESTON
        
        # Re-discover socket after Weston start
        if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
          sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
          if [ -n "$sock" ]; then
            log_info "Weston started successfully with socket: $sock"
            if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
              if adopt_wayland_env_from_socket "$sock"; then
                wayland_ready=1
              fi
            fi
          fi
        fi
      fi
    fi
  fi
  
  # Verify Wayland connection
  if [ "$wayland_ready" -eq 1 ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    if command -v wayland_connection_ok >/dev/null 2>&1; then
      if wayland_connection_ok; then
        wayland_ready=1
        log_info "Wayland connection verified: OK"
      else
        wayland_ready=0
        log_warn "Wayland connection test failed"
      fi
    else
      # Assume ready if WAYLAND_DISPLAY is set and no verification available
      wayland_ready=1
      log_info "Wayland environment set (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"
    fi
  fi
  
  # Export wayland_ready for caller
  export wayland_ready
  
  return $((1 - wayland_ready))
}

# camera_cleanup_wayland_environment
# Cleanup function to restore Weston state if it was started by camera_setup_wayland_environment
# This function should be called from the runner's existing cleanup function (not via trap).
# The runner should check GSTREAMER_STARTED_WESTON and call this if needed.
camera_cleanup_wayland_environment() {
  # Only cleanup if we started Weston
  if [ "${GSTREAMER_STARTED_WESTON:-0}" -eq 1 ]; then
    log_info "Cleaning up Weston (started by camera_setup_wayland_environment)"
    
    # Use captured initial state to decide cleanup action
    # If Weston was not running initially, just stop it
    # If Weston was running initially, restore it using weston_restore_runtime
    # shellcheck disable=SC2153  # GSTREAMER_WESTON_INITIAL_STATE is set in camera_setup_wayland_environment
    if [ "${GSTREAMER_WESTON_INITIAL_STATE:-0}" -eq 0 ]; then
      # Weston was not running initially - just stop it
      if command -v weston_stop >/dev/null 2>&1; then
        weston_stop >/dev/null 2>&1 || true
        log_info "Stopped Weston (was not running initially)"
      fi
    else
      # Weston was running initially - restore it
      if command -v weston_restore_runtime >/dev/null 2>&1; then
        if ! weston_restore_runtime 15; then
          log_warn "Weston restoration failed"
        else
          log_info "Restored Weston (was running initially)"
        fi
      fi
    fi
    
    # Clear the flags
    GSTREAMER_STARTED_WESTON=0
    export GSTREAMER_STARTED_WESTON
    unset GSTREAMER_WESTON_INITIAL_STATE
  fi
}

# -------------------- Downstream-Only Test Detection --------------------
# gstreamer_is_downstream_stack
# Checks if current video stack is downstream
# Returns: 0 if downstream, 1 otherwise
gstreamer_is_downstream_stack() {
  if ! command -v video_stack_status >/dev/null 2>&1; then
    return 1
  fi
  stack=$(video_stack_status "" 2>/dev/null || echo "unknown")
  [ "$stack" = "downstream" ]
}

# -------------------- UVC Camera Detection --------------------
# gstreamer_detect_uvc_camera
# Detects UVC camera device by checking kernel driver via sysfs
# Prints: device path (e.g., /dev/video2) or empty if not found
gstreamer_detect_uvc_camera() {
  for dev in /dev/video*; do
    [ -c "$dev" ] || continue
    
    # Check if device uses uvcvideo driver via sysfs
    drv=$(readlink -f "/sys/class/video4linux/${dev##*/}/device/driver" 2>/dev/null)
    
    if printf '%s\n' "$drv" | grep -q "/uvcvideo$"; then
      printf '%s\n' "$dev"
      return 0
    fi
  done
  
  return 1
}

# -------------------- Advanced Test Pipeline Builders --------------------

# gstreamer_build_uvc_preview_pipeline
# Build pipeline for UVC camera live preview
# Args: device width height framerate
# Returns: pipeline string or empty on error
gstreamer_build_uvc_preview_pipeline() {
  device="$1"
  width="$2"
  height="$3"
  framerate="$4"
  
  [ -n "$device" ] || return 1
  [ -n "$width" ] || width="1920"
  [ -n "$height" ] || height="1080"
  [ -n "$framerate" ] || framerate="5"
  
  if has_element qtivtransform; then
    printf 'v4l2src device=%s ! qtivtransform rotate=0 ! video/x-raw,width=%s,height=%s,framerate=%s/1 ! waylandsink fullscreen=true' \
      "$device" "$width" "$height" "$framerate"
  else
    printf 'v4l2src device=%s ! video/x-raw,width=%s,height=%s,framerate=%s/1 ! waylandsink fullscreen=true' \
      "$device" "$width" "$height" "$framerate"
  fi
}

# gstreamer_build_drc_decode_pipeline
# Build pipeline for Dynamic Resolution Change H.264 decode test
# Args: clip_path video_stack
# Returns: pipeline string or empty on error
gstreamer_build_drc_decode_pipeline() {
  clip_path="$1"
  video_stack="${2:-upstream}"
  
  [ -n "$clip_path" ] || return 1
  [ -f "$clip_path" ] || return 1
  
  # Get stack-dependent decoder arguments
  decoder_args=$(gstreamer_v4l2_decoder_args "$video_stack")
  
  if [ -n "$decoder_args" ]; then
    printf 'filesrc location=%s ! qtdemux ! queue ! h264parse ! v4l2h264dec %s ! video/x-raw,format=NV12 ! fpsdisplaysink video-sink="waylandsink fullscreen=true" text-overlay=false' \
      "$clip_path" "$decoder_args"
  else
    printf 'filesrc location=%s ! qtdemux ! queue ! h264parse ! v4l2h264dec ! video/x-raw,format=NV12 ! fpsdisplaysink video-sink="waylandsink fullscreen=true" text-overlay=false' \
      "$clip_path"
  fi
}

# gstreamer_build_concurrency_decode_pipeline
# Build pipeline for concurrent decode tests (H.264, H.265, MJPEG)
# Supports configurable session count with dynamic grid layout
# Args: codec clip_path video_stack session_count
# Returns: pipeline string or empty on error
gstreamer_build_concurrency_decode_pipeline() {
  codec="$1"
  clip_path="$2"
  video_stack="${3:-upstream}"
  sessions="${4:-8}"
  
  [ -n "$codec" ] || return 1
  [ -n "$clip_path" ] || return 1
  [ -f "$clip_path" ] || return 1
  
  # Validate session count is numeric and supported (only 2 or 8)
  case "$sessions" in
    ''|*[!0-9]*) 
      # Invalid: not numeric
      return 1
      ;;
    2|8)
      # Valid session counts - now validate against codec
      ;;
    *)
      # Invalid: unsupported session count (must be 2 or 8)
      return 1
      ;;
  esac
  
  # Validate session count matches codec requirements
  # H.264/H.265 require 8 sessions, MJPEG requires 2 sessions
  case "$codec" in
    h264|h265)
      if [ "$sessions" -ne 8 ]; then
        # H.264/H.265 must use 8 sessions
        return 1
      fi
      ;;
    mjpeg)
      if [ "$sessions" -ne 2 ]; then
        # MJPEG must use 2 sessions
        return 1
      fi
      ;;
    *)
      # Unknown codec
      return 1
      ;;
  esac
  
  # Get stack-dependent decoder arguments (only for H.264/H.265, not MJPEG)
  decoder_args=""
  case "$codec" in
    h264|h265)
      decoder_args=$(gstreamer_v4l2_decoder_args "$video_stack")
      ;;
  esac
  
  # Build qtivcomposer with grid layout based on session count
  # Display: 1920x1080
  pipeline="qtivcomposer name=mix"
  
  case "$sessions" in
    2)
      # 2x1 grid: 960x1080 each
      pipeline="$pipeline sink_0::position=\"<0,0>\" sink_0::dimensions=\"<960,1080>\""
      pipeline="$pipeline sink_1::position=\"<960,0>\" sink_1::dimensions=\"<960,1080>\""
      ;;
    8)
      # 4x2 grid: 480x540 each
      pipeline="$pipeline sink_0::position=\"<0,0>\" sink_0::dimensions=\"<480,540>\""
      pipeline="$pipeline sink_1::position=\"<480,0>\" sink_1::dimensions=\"<480,540>\""
      pipeline="$pipeline sink_2::position=\"<960,0>\" sink_2::dimensions=\"<480,540>\""
      pipeline="$pipeline sink_3::position=\"<1440,0>\" sink_3::dimensions=\"<480,540>\""
      pipeline="$pipeline sink_4::position=\"<0,540>\" sink_4::dimensions=\"<480,540>\""
      pipeline="$pipeline sink_5::position=\"<480,540>\" sink_5::dimensions=\"<480,540>\""
      pipeline="$pipeline sink_6::position=\"<960,540>\" sink_6::dimensions=\"<480,540>\""
      pipeline="$pipeline sink_7::position=\"<1440,540>\" sink_7::dimensions=\"<480,540>\""
      ;;
  esac
  
  # Different output for MJPEG (needs mix. before waylandsink)
  case "$codec" in
    mjpeg)
      pipeline="$pipeline mix. ! queue ! waylandsink fullscreen=true"
      ;;
    *)
      pipeline="$pipeline ! queue ! waylandsink fullscreen=true"
      ;;
  esac
  
  # Add decode chains based on codec and session count
  i=0
  while [ "$i" -lt "$sessions" ]; do
    case "$codec" in
      h264)
        if [ -n "$decoder_args" ]; then
          pipeline="$pipeline filesrc location=${clip_path} ! qtdemux ! queue ! h264parse ! v4l2h264dec ${decoder_args} ! video/x-raw,format=NV12 ! queue ! mix."
        else
          pipeline="$pipeline filesrc location=${clip_path} ! qtdemux ! queue ! h264parse ! v4l2h264dec ! video/x-raw,format=NV12 ! queue ! mix."
        fi
        ;;
      h265)
        if [ -n "$decoder_args" ]; then
          pipeline="$pipeline filesrc location=${clip_path} ! qtdemux ! queue ! h265parse ! v4l2h265dec ${decoder_args} ! video/x-raw,format=NV12 ! queue ! mix."
        else
          pipeline="$pipeline filesrc location=${clip_path} ! qtdemux ! queue ! h265parse ! v4l2h265dec ! video/x-raw,format=NV12 ! queue ! mix."
        fi
        ;;
      mjpeg)
        # MJPEG uses jpegdec (software decoder), no stack-specific args needed
        pipeline="$pipeline filesrc location=${clip_path} ! avidemux ! queue ! jpegdec ! videoconvert ! video/x-raw,format=RGB ! queue ! mix."
        ;;
      *)
        return 1
        ;;
    esac
    i=$((i + 1))
  done
  
  printf '%s' "$pipeline"
}

# gstreamer_build_smart_encode_pipeline
# Build pipeline for HEVC Smart Encode with dual camera streams
# Args: output_file
# Returns: pipeline string or empty on error
gstreamer_build_smart_encode_pipeline() {
  output_file="$1"
  
  [ -n "$output_file" ] || return 1
  
  printf 'qtiqmmfsrc camera=0 noise-reduction=2 video_0::extra-buffers=20 video_0::type=preview name=camsrc video_0::type=video ! video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 ! queue ! scb.sink qtismartvencbin default-gop=30 max-gop=600 smart-framerate=true smart-bitrate=true smart-gop=false max-bitrate=4200000 name=scb encoder=v4l2h265enc ! queue ! h265parse ! queue ! mp4mux ! queue ! filesink location=%s camsrc. ! video/x-raw,format=NV12,width=640,height=480,framerate=15/1 ! queue ! scb.sink_ctrl' \
    "$output_file"
}

# gstreamer_build_camera_encode_pipeline
# Build pipeline for camera-based encoding with custom controls
# Args: codec width height output_file extra_controls video_stack
# Returns: pipeline string or empty on error
gstreamer_build_camera_encode_pipeline() {
  codec="$1"
  width="$2"
  height="$3"
  output_file="$4"
  extra_controls="$5"
  video_stack="$6"
  
  [ -n "$codec" ] || return 1
  [ -n "$width" ] || return 1
  [ -n "$height" ] || return 1
  [ -n "$output_file" ] || return 1
  
  # Determine encoder and parser
  case "$codec" in
    h264)
      encoder="v4l2h264enc"
      parser="h264parse"
      ;;
    h265|hevc)
      encoder="v4l2h265enc"
      parser="h265parse"
      ;;
    *)
      return 1
      ;;
  esac
  
  # Build pipeline
  if [ -n "$extra_controls" ]; then
    printf 'qtiqmmfsrc name=qmmf ! video/x-raw,format=NV12,width=%s,height=%s,framerate=30/1 ! %s extra-controls="%s" capture-io-mode=4 output-io-mode=4 ! %s ! mp4mux ! filesink location=%s' \
      "$width" "$height" "$encoder" "$extra_controls" "$parser" "$output_file"
  else
    printf 'qtiqmmfsrc name=qmmf ! video/x-raw,format=NV12,width=%s,height=%s,framerate=30/1 ! %s capture-io-mode=4 output-io-mode=4 ! %s ! mp4mux ! filesink location=%s' \
      "$width" "$height" "$encoder" "$parser" "$output_file"
  fi
}

# -------------------- Advanced Encode Output Validation --------------------
# gstreamer_validate_encode_output <testname> <output_file> <gstRc> <expected_codec> <expected_width> <expected_height> <min_duration>
# Comprehensive validation for camera-based encode tests
# Validates: exit code, file creation, file size, container, codec, resolution, duration
# Returns: 0 if all validations pass, 1 otherwise
#
# Parameters:
#   testname: Test name for logging
#   output_file: Path to encoded output file
#   gstRc: GStreamer exit code
#   expected_codec: Expected codec (h264, H.264, h265, H.265, hevc, HEVC)
#   expected_width: Expected video width in pixels
#   expected_height: Expected video height in pixels
#   min_duration: Minimum expected duration in seconds (optional, default: 5)
#
# Example usage:
#   gstreamer_validate_encode_output "HEVC_Encode_720p" "$output_file" "$gstRc" "h265" "1280" "720" "10"
gstreamer_validate_encode_output() {
  testname="$1"
  output_file="$2"
  gstRc="$3"
  expected_codec="$4"
  expected_width="$5"
  expected_height="$6"
  # shellcheck disable=SC2034  # min_duration is used later in duration validation
  min_duration="${7:-5}"
  
  # 1. Verify exit code is expected (0 or timeout 124)
  if [ "$gstRc" -ne 0 ] && [ "$gstRc" -ne 124 ]; then
    log_fail "$testname: FAIL (unexpected exit code: $gstRc)"
    return 1
  fi
  log_info "$testname: ✓ Exit code acceptable ($gstRc)"
  
  # 2. Verify file was created
  if [ ! -f "$output_file" ]; then
    log_fail "$testname: FAIL (output file not created: $output_file)"
    return 1
  fi
  log_info "$testname: ✓ Output file created"
  
  # 3. Verify file size exceeds minimum (1MB for camera-based encodes)
  file_size=$(gstreamer_file_size_bytes "$output_file")
  min_size=1048576  # 1MB minimum for camera encodes
  if [ "$file_size" -lt "$min_size" ]; then
    log_fail "$testname: FAIL (file too small: $file_size bytes < $min_size bytes)"
    return 1
  fi
  log_info "$testname: ✓ File size acceptable ($file_size bytes)"
  
  # 4. REQUIRE gst-discoverer-1.0 to verify container, codec, resolution, duration
  if ! command -v gst-discoverer-1.0 >/dev/null 2>&1; then
    log_fail "$testname: FAIL (gst-discoverer-1.0 required for validation but not available)"
    return 1
  fi
  
  discover_log="${output_file}.discover.log"
  if ! gst-discoverer-1.0 "$output_file" >"$discover_log" 2>&1; then
    log_fail "$testname: FAIL (gst-discoverer-1.0 failed to analyze file)"
    return 1
  fi
  
  # Log full gst-discoverer output for debugging
  log_info "$testname: === gst-discoverer output ==="
  while IFS= read -r line; do
    log_info "$testname:   $line"
  done < "$discover_log"
  log_info "$testname: ==================================="
  
  # Extract and log detected properties
  # Pattern matches both "container: Quicktime" and "container #0: Quicktime"
  detected_container=$(grep -i "container" "$discover_log" | head -n1 | sed -n 's/.*container[^:]*:[[:space:]]*\(.*\)/\1/p' || echo "Unknown")
  detected_codec=$(grep -E "video.*:" "$discover_log" | head -n1 | sed -n 's/.*video[^:]*:[[:space:]]*\([^(]*\).*/\1/p' | sed 's/[[:space:]]*$//' || echo "Unknown")
  detected_width=$(grep -E "^[[:space:]]*Width:" "$discover_log" | head -n1 | sed -n 's/.*Width:[[:space:]]*\([0-9][0-9]*\).*/\1/p' || echo "0")
  detected_height=$(grep -E "^[[:space:]]*Height:" "$discover_log" | head -n1 | sed -n 's/.*Height:[[:space:]]*\([0-9][0-9]*\).*/\1/p' || echo "0")
  
  log_info "$testname: Detected properties:"
  log_info "$testname:   Container: $detected_container"
  log_info "$testname:   Codec: $detected_codec"
  log_info "$testname:   Resolution: ${detected_width}x${detected_height}"
  
  # Start validation section
  log_info "$testname: === Validation Results ==="
  validation_failed=0
  
  # Verify container (MP4) - STRICT: return failure if mismatch
  # Match both "container: Quicktime" and "container #0: Quicktime"
  log_info "$testname: Validating Container..."
  log_info "$testname:   Expected: Quicktime (MP4 container)"
  log_info "$testname:   Detected: $detected_container"
  if ! grep -q -i "quicktime" "$discover_log"; then
    log_fail "$testname:   Result: ✗ FAIL - Container mismatch (expected Quicktime, got $detected_container)"
    validation_failed=1
  else
    log_pass "$testname:   Result: ✓ PASS - Container matches (Quicktime)"
  fi
  
  # Verify codec - STRICT: return failure if mismatch
  log_info "$testname: Validating Codec..."
  case "$expected_codec" in
    h264|H.264)
      log_info "$testname:   Expected: H.264"
      log_info "$testname:   Detected: $detected_codec"
      if grep -q "H\.264" "$discover_log"; then
        log_pass "$testname:   Result: ✓ PASS - Codec matches"
      else
        log_fail "$testname:   Result: ✗ FAIL - Codec mismatch"
        validation_failed=1
      fi
      ;;
    h265|H.265|hevc|HEVC)
      log_info "$testname:   Expected: H.265/HEVC"
      log_info "$testname:   Detected: $detected_codec"
      if grep -q "H\.265\|HEVC" "$discover_log"; then
        log_pass "$testname:   Result: ✓ PASS - Codec matches"
      else
        log_fail "$testname:   Result: ✗ FAIL - Codec mismatch"
        validation_failed=1
      fi
      ;;
  esac
  
  # Verify resolution - STRICT: return failure if mismatch
  log_info "$testname: Validating Resolution..."
  log_info "$testname:   Expected: ${expected_width}x${expected_height}"
  log_info "$testname:   Detected: ${detected_width}x${detected_height}"
  if [ "$detected_width" = "$expected_width" ] && [ "$detected_height" = "$expected_height" ]; then
    log_pass "$testname:   Result: ✓ PASS - Resolution matches"
  else
    log_fail "$testname:   Result: ✗ FAIL - Resolution mismatch"
    validation_failed=1
  fi
  
  # Verify duration - STRICT: parse to seconds and enforce min_duration
  log_info "$testname: Validating Duration..."
  duration_line=$(grep "Duration:" "$discover_log" | head -n 1)
  if [ -z "$duration_line" ]; then
    log_fail "$testname:   Result: ✗ FAIL - No duration information found"
    log_info "$testname: ==================================="
    rm -f "$discover_log" 2>/dev/null || true
    return 1
  fi
  
  # Extract duration in format like "0:00:30.123456789"
  duration_str=$(printf '%s' "$duration_line" | sed -n 's/.*Duration: \([0-9:\.]*\).*/\1/p')
  if [ -z "$duration_str" ]; then
    log_fail "$testname:   Result: ✗ FAIL - Could not parse duration"
    log_info "$testname: ==================================="
    rm -f "$discover_log" 2>/dev/null || true
    return 1
  fi
  
  # Parse duration to seconds (format: H:MM:SS.nanoseconds or M:SS.nanoseconds)
  # Split by colons and extract hours, minutes, seconds
  hours=0
  minutes=0
  seconds=0
  
  # Count colons to determine format
  colon_count=$(printf '%s' "$duration_str" | tr -cd ':' | wc -c)
  
  case "$colon_count" in
    2)
      # Format: H:MM:SS.nnn
      hours=$(printf '%s' "$duration_str" | cut -d: -f1)
      minutes=$(printf '%s' "$duration_str" | cut -d: -f2)
      seconds=$(printf '%s' "$duration_str" | cut -d: -f3 | cut -d. -f1)
      ;;
    1)
      # Format: M:SS.nnn or MM:SS.nnn
      minutes=$(printf '%s' "$duration_str" | cut -d: -f1)
      seconds=$(printf '%s' "$duration_str" | cut -d: -f2 | cut -d. -f1)
      ;;
    0)
      # Format: SS.nnn (just seconds)
      seconds=$(printf '%s' "$duration_str" | cut -d. -f1)
      ;;
  esac
  
  # Sanitize to ensure numeric values
  case "$hours" in ''|*[!0-9]*) hours=0 ;; esac
  case "$minutes" in ''|*[!0-9]*) minutes=0 ;; esac
  case "$seconds" in ''|*[!0-9]*) seconds=0 ;; esac
  
  # Convert to total seconds
  total_seconds=$((hours * 3600 + minutes * 60 + seconds))
  
  log_info "$testname:   Expected: >= ${min_duration}s (minimum)"
  log_info "$testname:   Detected: ${total_seconds}s (from $duration_str)"
  
  # Enforce minimum duration
  if [ "$total_seconds" -lt "$min_duration" ]; then
    log_fail "$testname:   Result: ✗ FAIL - Duration too short (${total_seconds}s < ${min_duration}s)"
    validation_failed=1
  else
    log_pass "$testname:   Result: ✓ PASS - Duration meets minimum requirement"
  fi
  
  log_info "$testname: ==================================="
  
  # Final validation result
  if [ "$validation_failed" -eq 1 ]; then
    log_fail "$testname: Overall validation: FAILED"
    rm -f "$discover_log" 2>/dev/null || true
    return 1
  else
    log_pass "$testname: Overall validation: PASSED"
    rm -f "$discover_log" 2>/dev/null || true
    return 0
  fi
}

# gstreamer_verify_rotation <testname> <output_file> <input_width> <input_height> <rotation_degrees>
# Verify that video rotation was applied by checking output dimensions
# For 90° or 270° rotation, dimensions should be swapped
# Returns: 0 if rotation verified, 1 otherwise
# REQUIRES gst-discoverer-1.0 and usable dimension evidence
#
# Parameters:
#   testname: Test name for logging
#   output_file: Path to encoded output file
#   input_width: Original input width before rotation
#   input_height: Original input height before rotation
#   rotation_degrees: Expected rotation (90, 180, 270)
#
# Example usage:
#   gstreamer_verify_rotation "HEVC_Encode_4K_Rotate90" "$output_file" "3840" "2160" "90"
gstreamer_verify_rotation() {
  testname="$1"
  output_file="$2"
  input_width="$3"
  input_height="$4"
  rotation_degrees="$5"
  
  [ -n "$testname" ] || return 1
  [ -f "$output_file" ] || return 1
  [ -n "$input_width" ] || return 1
  [ -n "$input_height" ] || return 1
  [ -n "$rotation_degrees" ] || return 1
  
  # REQUIRE gst-discoverer - fail if not available
  if ! command -v gst-discoverer-1.0 >/dev/null 2>&1; then
    log_fail "$testname: FAIL (gst-discoverer-1.0 required for rotation verification)"
    return 1
  fi
  
  log_info "$testname: Verifying ${rotation_degrees}° rotation..."
  
  # Get discoverer output and save to log file for debugging
  discover_log="${output_file}.rotation_discover.log"
  if ! gst-discoverer-1.0 "$output_file" >"$discover_log" 2>&1; then
    log_fail "$testname: FAIL (gst-discoverer-1.0 failed to analyze file for rotation verification)"
    rm -f "$discover_log" 2>/dev/null || true
    return 1
  fi
  
  # Log discoverer output for debugging
  log_info "$testname: === gst-discoverer output (rotation check) ==="
  while IFS= read -r line; do
    log_info "$testname:   $line"
  done < "$discover_log"
  log_info "$testname: ==================================="
  
  # Extract video dimensions using same robust parsing as validation function
  # Handles indented format: "  Width: 1280"
  actual_width=$(grep -E "^[[:space:]]*Width:" "$discover_log" | head -n1 | sed -n 's/.*Width:[[:space:]]*\([0-9][0-9]*\).*/\1/p' || echo "")
  actual_height=$(grep -E "^[[:space:]]*Height:" "$discover_log" | head -n1 | sed -n 's/.*Height:[[:space:]]*\([0-9][0-9]*\).*/\1/p' || echo "")
  
  # REQUIRE usable dimension evidence - fail if cannot extract
  if [ -z "$actual_width" ] || [ -z "$actual_height" ]; then
    log_fail "$testname: FAIL (Could not extract dimensions from output file - no usable evidence)"
    rm -f "$discover_log" 2>/dev/null || true
    return 1
  fi
  
  log_info "$testname: Extracted dimensions: ${actual_width}x${actual_height}"
  
  # Determine expected dimensions based on rotation
  case "$rotation_degrees" in
    90|270)
      # Dimensions should be swapped
      expected_width="$input_height"
      expected_height="$input_width"
      log_info "$testname: Expected dimensions after ${rotation_degrees}° rotation: ${expected_width}x${expected_height}"
      ;;
    180)
      # Dimensions should remain the same
      expected_width="$input_width"
      expected_height="$input_height"
      log_info "$testname: Expected dimensions after ${rotation_degrees}° rotation: ${expected_width}x${expected_height}"
      ;;
    *)
      log_fail "$testname: FAIL (Unsupported rotation angle: ${rotation_degrees}°)"
      return 1
      ;;
  esac
  
  # Verify dimensions match expected
  log_info "$testname: === Rotation Validation ==="
  log_info "$testname:   Expected dimensions: ${expected_width}x${expected_height}"
  log_info "$testname:   Actual dimensions:   ${actual_width}x${actual_height}"
  
  if [ "$actual_width" = "$expected_width" ] && [ "$actual_height" = "$expected_height" ]; then
    log_pass "$testname:   Result: ✓ PASS - Rotation verified (dimensions correctly transformed)"
    log_info "$testname: ==================================="
    rm -f "$discover_log" 2>/dev/null || true
    return 0
  else
    log_fail "$testname:   Result: ✗ FAIL - Rotation not applied correctly"
    log_fail "$testname:   Expected: ${expected_width}x${expected_height}, Got: ${actual_width}x${actual_height}"
    log_info "$testname: ==================================="
    rm -f "$discover_log" 2>/dev/null || true
    return 1
  fi
}

