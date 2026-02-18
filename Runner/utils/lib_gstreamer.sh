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
    fi
    if command -v timeout >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      timeout "$secs" "$GSTBIN" $GSTLAUNCHFLAGS $pipe
      return $?
    fi
  fi

  # shellcheck disable=SC2086
  "$GSTBIN" $GSTLAUNCHFLAGS $pipe
  return $?
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

# -------------------- GStreamer error log checker --------------------
# gstreamer_check_errors <logfile>
# Returns: 0 if no critical errors found, 1 if errors found
# Checks for common GStreamer ERROR patterns that indicate failure
# Uses severity-based matching to avoid false positives on benign logs
gstreamer_check_errors() {
  logfile="$1"
  
  [ -f "$logfile" ] || return 0
  
  # Check for explicit ERROR: prefixed messages (most reliable)
  if grep -q -E "^ERROR:|^0:[0-9]+:[0-9]+\.[0-9]+ [0-9]+ [^ ]+ ERROR" "$logfile" 2>/dev/null; then
    return 1
  fi
  
  # Check for ERROR messages from GStreamer elements
  if grep -q -E "ERROR: from element|gst.*ERROR" "$logfile" 2>/dev/null; then
    return 1
  fi
  
  # Check for critical streaming errors
  if grep -q -E "Internal data stream error|streaming stopped, reason not-negotiated" "$logfile" 2>/dev/null; then
    return 1
  fi
  
  # Check for pipeline failures (more specific patterns)
  if grep -q -E "pipeline doesn't want to preroll|pipeline doesn't want to play|ERROR.*pipeline" "$logfile" 2>/dev/null; then
    return 1
  fi
  
  # Check for state change failures (require ERROR context)
  if grep -q -E "ERROR.*failed to change state|ERROR.*state change failed" "$logfile" 2>/dev/null; then
    return 1
  fi
  
  # Check for specific error patterns with proper grouping
  if grep -q -E '(^ERROR:|ERROR: from element|Internal data stream error|streaming stopped, reason not-negotiated|pipeline.*failed|state change failed|Could not open resource|No such file or directory)' "$logfile" 2>/dev/null; then
    return 1
  fi
  
  # Check for CRITICAL or FATAL level messages (keep these as they are actual severity indicators)
  if grep -q -E '(^CRITICAL:|^FATAL:|gst.*(CRITICAL|FATAL))' "$logfile" 2>/dev/null; then
    return 1
  fi
  
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
    log_fail "$testname: GStreamer errors detected in log"
    
    # Extract and log specific error messages
    if grep -q "ERROR:" "$logfile" 2>/dev/null; then
      log_fail "Error messages found:"
      grep "ERROR:" "$logfile" 2>/dev/null | head -n 5 | while IFS= read -r line; do
        log_fail "  $line"
      done
    fi
    
    # Check for specific failure reasons
    if grep -q "not-negotiated" "$logfile" 2>/dev/null; then
      log_fail "  Reason: Format negotiation failed (caps mismatch)"
    fi
    
    if grep -q "Could not open" "$logfile" 2>/dev/null; then
      log_fail "  Reason: File or device access failed"
    fi
    
    if grep -q "No such file" "$logfile" 2>/dev/null; then
      log_fail "  Reason: File not found"
    fi
    
    return 1
  fi
  
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
      parser=""
      container="matroskademux"
      ;;
    *)
      parser="identity"
      container=""
      ;;
  esac
  
  # Build decoder parameters
  decoder_params=""
  if [ "$video_stack" = "downstream" ]; then
    decoder_params="capture-io-mode=4 output-io-mode=4"
  fi
  
  # Build pipeline based on container format
  if [ -n "$container" ]; then
    # MP4 container (h264/h265)
    if [ -n "$decoder_params" ]; then
      printf '%s\n' "filesrc location=${input_file} ! ${container} ! ${parser} ! ${decoder} ${decoder_params} ! videoconvert ! fakesink"
    else
      printf '%s\n' "filesrc location=${input_file} ! ${container} ! ${parser} ! ${decoder} ! videoconvert ! fakesink"
    fi
  else
    # VP9 with webm container
    if [ -n "$decoder_params" ]; then
      printf '%s\n' "filesrc location=${input_file} ! ${parser} ! ${decoder} ${decoder_params} ! videoconvert ! fakesink"
    else
      printf '%s\n' "filesrc location=${input_file} ! ${parser} ! ${decoder} ! videoconvert ! fakesink"
    fi
  fi
  
  return 0
}
