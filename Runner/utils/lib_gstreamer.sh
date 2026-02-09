#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
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

    mkdir -p "$(dirname "${dest}")"

    if command -v curl >/dev/null 2>&1; then
        curl -fkL "${url}" -o "${dest}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "${url}" -O "${dest}"
    else
        echo "Error: neither 'curl' nor 'wget' is installed." >&2
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

    tmp_dir=$(mktemp -d -t "$(basename "${zip_path%.*}")_XXXX")

    if ! unzip -o "${zip_path}" -d "${tmp_dir}" >/dev/null; then
        echo "Unzip of ${zip_path} failed" >&2
        rm -rf "${tmp_dir}"
        return 1
    fi

    mkdir -p "${dest_dir}"
    cp -r "${tmp_dir}"/* "${dest_dir}/"

    # Clean up the temporary folder;
    rm -rf "${tmp_dir}" "${zip_path}"
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
    tmpfile=$(mktemp) || exit 1
    printf '%s' "$pipeline" | tr '!' '\n' >"$tmpfile"

    # ---------------------------------------------------------
    # Read the file line‑by‑line – this runs in the *current*
    #    shell, so variable updates survive.
    # ---------------------------------------------------------
    while IFS= read -r element_spec; do
        # ---- NEW ----
        # Strip surrounding whitespace; skip blank lines
        element_spec=$(printf '%s' "$element_spec" | xargs)
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
                log_info "Checking element: $element_name"
                if ! has_element "$element_name"; then
                    missing_count=$(( missing_count + 1 ))
                    missing_list="${missing_list}${element_name} "
                    log_error "Required element missing: $element_name"
                else
                    log_info "Element found: $element_name"
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
    timeout=$3
    TIMEOUT=${timeout:-60}   # default 60 seconds

    console_log="${name}_console.log"
    gst_debug_log="${name}_gst_debug.log"

    export GST_DEBUG_FILE="${gst_debug_log}"

    log_info "Running ${name} (timeout=${TIMEOUT}s)"
    timeout "${TIMEOUT}" sh -c "$cmd" >"$console_log" 2>&1
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
    size_in_bytes=$(stat -c %s "$input_file_path" 2>/dev/null) || {
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
