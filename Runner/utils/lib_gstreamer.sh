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
gstreamer_run_gstlaunch_timeout() {
  secs="$1"
  pipe="$2"

  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  command -v "$GSTBIN" >/dev/null 2>&1 || return 127

  gstreamer_print_cmd_multiline "$pipe"

  if [ "$secs" -gt 0 ] 2>/dev/null; then
    if command -v audio_timeout_run >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      audio_timeout_run "${secs}s" "$GSTBIN" $GSTLAUNCHFLAGS $pipe
      return $?
    elif command -v timeout >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      timeout "$secs" "$GSTBIN" $GSTLAUNCHFLAGS $pipe
      return $?
    else
      log_warn "No timeout command available (audio_timeout_run or timeout), running without timeout"
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
  
  # Build decoder parameters
  decoder_params=""
  if [ "$video_stack" = "downstream" ]; then
    decoder_params="capture-io-mode=4 output-io-mode=4"
  fi
  
  # Build pipeline based on parser availability
  # All supported formats (h264, h265, vp9) have containers (MP4 or WebM)
  if [ -n "$parser" ]; then
    # Use parser if available
    if [ -n "$decoder_params" ]; then
      printf '%s\n' "filesrc location=${input_file} ! ${container} ! ${parser} ! ${decoder} ${decoder_params} ! videoconvert ! fakesink"
    else
      printf '%s\n' "filesrc location=${input_file} ! ${container} ! ${parser} ! ${decoder} ! videoconvert ! fakesink"
    fi
  else
    # Skip parser if not available (e.g. VP9 without vp9parse)
    if [ -n "$decoder_params" ]; then
      printf '%s\n' "filesrc location=${input_file} ! ${container} ! ${decoder} ${decoder_params} ! videoconvert ! fakesink"
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

    console_log="${logdir}/${name}_console.log"
    gst_debug_log="${logdir}/${name}_gst_debug.log"

    export GST_DEBUG_FILE="${gst_debug_log}"

    log_info "Running ${name} (timeout=${TIMEOUT}s)"
    gstreamer_run_gstlaunch_timeout "$TIMEOUT" "$cmd" >"$console_log" 2>&1
    rc=$?

    # Look for a successful PLAYING state and the absence of ERROR messages.
    playing=$(grep -c "Setting pipeline to PLAYING" "$console_log" || true)
    error_present=$(grep -c "ERROR:" "$console_log" || true)

    if [ "$playing" -gt 0 ] && [ "$error_present" -eq 0 ]; then
        log_pass "${name} PASS"
        return 0
    fi

    # Special case: timeout (rc = 124) but PLAYING was already reached.
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

# -------------------- Wayland/Weston setup helper --------------------
# camera_setup_wayland_environment <test_name>
# Sets up Wayland/Weston environment for camera preview tests
# Sets wayland_ready=1 if successful, 0 otherwise
# Parameters:
#   test_name: Name of the test for logging purposes
# Returns: 0 if Wayland is ready, 1 otherwise
camera_setup_wayland_environment() {
  test_name="${1:-Camera_Test}"
  
  wayland_ready=0
  sock=""
  
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
