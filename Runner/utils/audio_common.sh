#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Common audio helpers for PipeWire / PulseAudio runners.
# Requires: functestlib.sh (log_* helpers, extract_tar_from_url, scan_dmesg_errors)

# ---------- Backend detection & daemon checks ----------
detect_audio_backend() {
  if pgrep -x pipewire >/dev/null 2>&1 && command -v wpctl >/dev/null 2>&1; then
    echo pipewire; return 0
  fi
  if pgrep -x pulseaudio >/dev/null 2>&1 && command -v pactl >/dev/null 2>&1; then
    echo pulseaudio; return 0
  fi
  # Accept pipewire-pulse shim as PulseAudio
  if pgrep -x pipewire-pulse >/dev/null 2>&1 && command -v pactl >/dev/null 2>&1; then
    echo pulseaudio; return 0
  fi
  echo ""
  return 1
}

check_audio_daemon() {
  case "$1" in
    pipewire) pgrep -x pipewire >/dev/null 2>&1 ;;
    pulseaudio) pgrep -x pulseaudio >/dev/null 2>&1 || pgrep -x pipewire-pulse >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# ---------- Assets / clips ----------
resolve_clip() {
  fmt="$1"; dur="$2"; base="AudioClips"
  case "$fmt:$dur" in
    wav:short|wav:medium|wav:long) printf '%s\n' "$base/yesterday_48KHz.wav" ;;
    *) printf '%s\n' "" ;;
  esac
}

# audio_download_with_any <url> <outfile>
audio_download_with_any() {
    url="$1"; out="$2"
    if command -v wget >/dev/null 2>&1; then
        wget -O "$out" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$out" "$url"
    else
        log_error "No downloader (wget/curl) available to fetch $url"
        return 1
    fi
}
# audio_fetch_assets_from_url <url>
# Prefer functestlib's extract_tar_from_url; otherwise download + extract.
audio_fetch_assets_from_url() {
    url="$1"
    if command -v extract_tar_from_url >/dev/null 2>&1; then
        extract_tar_from_url "$url"
        return $?
    fi
    fname="$(basename "$url")"
    log_info "Fetching assets: $url"
    if ! audio_download_with_any "$url" "$fname"; then
        log_warn "Download failed: $url"
        return 1
    fi
    tar -xzf "$fname" >/dev/null 2>&1 || tar -xf "$fname" >/dev/null 2>&1 || {
        log_warn "Extraction failed: $fname"
        return 1
    }
    return 0
}
# audio_ensure_clip_ready <clip-path> [tarball-url]
# Return codes:
#   0 = clip exists/ready
#   2 = network unavailable after attempts (caller should SKIP)
#   1 = fetch/extract/downloader error (caller will also SKIP per your policy)
audio_ensure_clip_ready() {
    clip="$1"
    url="${2:-${AUDIO_TAR_URL:-}}"
    [ -f "$clip" ] && return 0
    # Try once without forcing network (tarball may already be present)
    if [ -n "$url" ]; then
        audio_fetch_assets_from_url "$url" >/dev/null 2>&1 || true
        [ -f "$clip" ] && return 0
    fi
    # Bring network up and retry once
    if ! ensure_network_online; then
        log_warn "Network unavailable; cannot fetch audio assets for $clip"
        return 2
    fi
    if [ -n "$url" ]; then
        if audio_fetch_assets_from_url "$url" >/dev/null 2>&1; then
            [ -f "$clip" ] && return 0
        fi
    fi
    log_warn "Clip fetch/extract failed for $clip"
    return 1
}

# ---------- dmesg + mixer dumps ----------
scan_audio_dmesg() {
  outdir="$1"; mods='snd|audio|pipewire|pulseaudio'; excl='dummy regulator|EEXIST|probe deferred'
  scan_dmesg_errors "$mods" "$outdir" "$excl" || true
}

dump_mixers() {
  out="$1"
  {
    echo "---- wpctl status ----"
    command -v wpctl >/dev/null 2>&1 && wpctl status 2>&1 || echo "(wpctl not found)"
    echo "---- pactl list ----"
    command -v pactl >/dev/null 2>&1 && pactl list 2>&1 || echo "(pactl not found)"
  } >"$out" 2>/dev/null
}

# Returns child exit code (124 when killed by timeout). If tmo<=0, runs the
# command directly (no watchdog).

# ---------- Timeout runner (prefers provided wrappers) ----------
# Returns child's exit code. For the fallback-kill path, returns 143 on timeout.
audio_timeout_run() {
  tmo="$1"; shift
 
  # 0/empty => run without a watchdog (do NOT background/kill)
  case "$tmo" in ""|0|"0s"|"0S") "$@"; return $? ;; esac
 
  # Use project-provided wrappers if available
  if command -v run_with_timeout >/dev/null 2>&1; then
    run_with_timeout "$tmo" "$@"; return $?
  fi
  if command -v sh_timeout >/dev/null 2>&1; then
    sh_timeout "$tmo" "$@"; return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$tmo" "$@"; return $?
  fi
 
  # Last-resort busybox-safe watchdog
  # Normalize "15s" -> 15
  sec="$(printf '%s' "$tmo" | sed 's/[sS]$//')"
  [ -z "$sec" ] && sec="$tmo"
  # If parsing failed for some reason, just run directly
  case "$sec" in ''|*[!0-9]* ) "$@"; return $? ;; esac
 
  "$@" &
  pid=$!
  t=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$t" -ge "$sec" ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 143
    fi
    sleep 1; t=$((t+1))
  done
  wait "$pid"; return $?
}
 
# ---------- PipeWire: sinks (playback) ----------
pw_default_speakers() {
  _block="$(wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p')"
  _id="$(printf '%s\n' "$_block" \
        | grep -i -E 'speaker|headphone' \
        | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' \
        | head -n1)"
  [ -n "$_id" ] || _id="$(printf '%s\n' "$_block" \
        | sed -n 's/^[^*]*\*[[:space:]]*\([0-9][0-9]*\)\..*/\1/p' \
        | head -n1)"
  [ -n "$_id" ] || _id="$(printf '%s\n' "$_block" \
        | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' \
        | head -n1)"
  printf '%s\n' "$_id"
}

pw_default_null() {
  wpctl status 2>/dev/null \
  | sed -n '/Sinks:/,/Sources:/p' \
  | grep -i -E 'null|dummy|loopback|monitor' \
  | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' \
  | head -n1
}

pw_sink_name_safe() {
  id="$1"; [ -n "$id" ] || { echo ""; return 1; }
  name="$(wpctl inspect "$id" 2>/dev/null | grep -m1 'node.description' | cut -d'"' -f2)"
  [ -n "$name" ] || name="$(wpctl inspect "$id" 2>/dev/null | grep -m1 'node.name' | cut -d'"' -f2)"
  if [ -z "$name" ]; then
    name="$(wpctl status 2>/dev/null \
      | sed -n '/Sinks:/,/Sources:/p' \
      | grep -E "^[^0-9]*${id}[.][[:space:]]" \
      | sed 's/^[^0-9]*[0-9]\+[.][[:space:]]\+//' \
      | sed 's/[[:space:]]*\[vol:.*$//' \
      | head -n1)"
  fi
  printf '%s\n' "$name"
}

pw_sink_name() { pw_sink_name_safe "$@"; } # back-compat alias
pw_set_default_sink() { [ -n "$1" ] && wpctl set-default "$1" >/dev/null 2>&1; }

# ---------- PipeWire: sources (record) ----------
pw_default_mic() {
  blk="$(wpctl status 2>/dev/null | sed -n '/Sources:/,/^$/p')"
  id="$(printf '%s\n' "$blk" | grep -i 'mic' | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  [ -n "$id" ] || id="$(printf '%s\n' "$blk" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  printf '%s\n' "$id"
}

pw_default_null_source() {
  blk="$(wpctl status 2>/dev/null | sed -n '/Sources:/,/^$/p')"
  id="$(printf '%s\n' "$blk" | grep -i 'null\|dummy' | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  printf '%s\n' "$id"
}

pw_set_default_source() { [ -n "$1" ] && wpctl set-default "$1" >/dev/null 2>&1; }

pw_source_label_safe() {
  id="$1"; [ -n "$id" ] || { echo ""; return 1; }
  label="$(wpctl inspect "$id" 2>/dev/null | grep -m1 'node.description' | cut -d'"' -f2)"
  [ -n "$label" ] || label="$(wpctl inspect "$id" 2>/dev/null | grep -m1 'node.name' | cut -d'"' -f2)"
  if [ -z "$label" ]; then
    label="$(wpctl status 2>/dev/null \
      | sed -n '/Sources:/,/Filters:/p' \
      | grep -E "^[^0-9]*${id}[.][[:space:]]" \
      | sed 's/^[^0-9]*[0-9]\+[.][[:space:]]\+//' \
      | sed 's/[[:space:]]*\[vol:.*$//' \
      | head -n1)"
  fi
  printf '%s\n' "$label"
}

# ---------- PulseAudio: sinks (playback) ----------
pa_default_speakers() {
  def="$(pactl info 2>/dev/null | sed -n 's/^Default Sink:[[:space:]]*//p' | head -n1)"
  if [ -n "$def" ]; then printf '%s\n' "$def"; return 0; fi
  name="$(pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -i 'speaker\|head' | head -n1)"
  [ -n "$name" ] || name="$(pactl list short sinks 2>/dev/null | awk '{print $2}' | head -n1)"
  printf '%s\n' "$name"
}

pa_default_null() {
  pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -i 'null\|dummy' | head -n1
}

pa_set_default_sink() { [ -n "$1" ] && pactl set-default-sink "$1" >/dev/null 2>&1; }

# Map numeric index → sink name; pass through names unchanged
pa_sink_name() {
  id="$1"
  case "$id" in
    '' ) echo ""; return 0;;
    *[!0-9]* ) echo "$id"; return 0;;
    * ) pactl list short sinks 2>/dev/null | awk -v k="$id" '$1==k{print $2; exit}'; return 0;;
  esac
}

# ---------- PulseAudio: sources (record) ----------
pa_default_source() {
  s="$(pactl get-default-source 2>/dev/null | tr -d '\r')"
  [ -n "$s" ] || s="$(pactl info 2>/dev/null | awk -F': ' '/Default Source:/{print $2}')"
  [ -n "$s" ] || s="$(pactl list short sources 2>/dev/null | awk 'NR==1{print $2}')"
  printf '%s\n' "$s"
}

pa_set_default_source() {
  if [ -n "$1" ]; then
    pactl set-default-source "$1" >/dev/null 2>&1 || true
  fi
}

pa_source_name() {
  id="$1"; [ -n "$id" ] || return 1
  if pactl list short sources 2>/dev/null | awk '{print $1}' | grep -qx "$id"; then
    pactl list short sources 2>/dev/null | awk -v idx="$id" '$1==idx{print $2; exit}'
  else
    printf '%s\n' "$id"
  fi
}

pa_resolve_mic_fallback() {
  s="$(pactl list short sources 2>/dev/null \
       | awk 'BEGIN{IGNORECASE=1} /mic|handset|headset|speaker_mic|voice/ {print $2; exit}')"
  [ -n "$s" ] || s="$(pactl list short sources 2>/dev/null | awk 'NR==1{print $2}')"
  printf '%s\n' "$s"
}

# PipeWire sink label by ID (tries description, then node.name, then status line)
pw_sink_name_safe() {
  id="$1"; [ -n "$id" ] || return 1
  name="$(wpctl inspect "$id" 2>/dev/null | grep -m1 'node.description' | cut -d'"' -f2)"
  [ -n "$name" ] || name="$(wpctl inspect "$id" 2>/dev/null | grep -m1 'node.name' | cut -d'"' -f2)"
  if [ -z "$name" ]; then
    name="$(wpctl status 2>/dev/null \
      | sed -n '/^[[:space:]]*Sinks:/,/^[[:space:]]*$/p' \
      | grep -E "^[[:space:]]*\*?[[:space:]]*${id}[.][[:space:]]" \
      | sed 's/^[[:space:]]*\*\?[[:space:]]*[0-9]\+[.][[:space:]]\+//' \
      | sed 's/[[:space:]]*\[vol:.*$//' \
      | head -n1)"
  fi
  printf '%s\n' "$name"
}

# ----------- PulseAudio Source Helpers -----------
pa_default_mic() {
  def="$(pactl info 2>/dev/null | sed -n 's/^Default Source:[[:space:]]*//p' | head -n1)"
  if [ -n "$def" ]; then
    printf '%s\n' "$def"; return 0
  fi
  name="$(pactl list short sources 2>/dev/null | awk '{print $2}' | grep -i 'mic' | head -n1)"
  [ -n "$name" ] || name="$(pactl list short sources 2>/dev/null | awk '{print $2}' | head -n1)"
  printf '%s\n' "$name"
}
pa_default_null_source() {
  name="$(pactl list short sources 2>/dev/null | awk '{print $2}' | grep -i 'null\|dummy' | head -n1)"
  printf '%s\n' "$name"
}


# ---------- Evidence helpers (used by run.sh for PASS-on-evidence) ----------
# PipeWire: 1 if any output audio stream exists; fallback parses Streams: block
audio_evidence_pw_streaming() {
  # Try wpctl (fast); fall back to log scan if AUDIO_LOGCTX is available
  if command -v wpctl >/dev/null 2>&1; then
    # Count Input/Output streams in RUNNING state
    wpctl status 2>/dev/null | grep -Eq 'RUNNING' && { echo 1; return; }
  fi
  # Fallback to log
  if [ -n "${AUDIO_LOGCTX:-}" ] && [ -r "$AUDIO_LOGCTX" ]; then
    grep -qiE 'paused -> streaming|stream time:' "$AUDIO_LOGCTX" 2>/dev/null && { echo 1; return; }
  fi
  echo 0
}
 
# 2) PulseAudio streaming - safe when PA is absent (returns 0 without forcing FAIL)
#Return 1 if PulseAudio is actively streaming (sink-inputs, source-outputs, or RUNNING sink),
# else 0. Works even when the PA daemon is a different user by trying sockets + cookies.
audio_evidence_pa_streaming() {
  # quick exits if tools are missing
  command -v pactl >/dev/null 2>&1 || command -v pacmd >/dev/null 2>&1 || {
    # final fallback: try to infer from our log if present
    if [ -n "${AUDIO_LOGCTX:-}" ] && [ -s "$AUDIO_LOGCTX" ]; then
      grep -qiE 'Connected to PulseAudio|Opening audio stream|Stream started|Starting recording|Playing' "$AUDIO_LOGCTX" && { echo 1; return; }
    fi
    echo 0; return
  }
 
  # build candidate socket + cookie pairs
  cand=""
  # per-user runtime dir sockets
  for d in /run/user/* /var/run/user/*; do
    [ -S "$d/pulse/native" ] || continue
    sock="$d/pulse/native"
    cookie=""
    [ -r "$d/pulse/cookie" ] && cookie="$d/pulse/cookie"
    # try to derive a home cookie for that uid as well
    uid="$(stat -c %u "$d" 2>/dev/null || echo)"
    if [ -n "$uid" ]; then
      home="$(getent passwd "$uid" 2>/dev/null | awk -F: '{print $6}')"
      [ -n "$home" ] && [ -r "$home/.config/pulse/cookie" ] && cookie="$home/.config/pulse/cookie"
    fi
    cand="$cand|$sock|$cookie"
  done
  # system-wide socket (no per-user cookie nearby)
  for s in /run/pulse/native /var/run/pulse/native; do
    [ -S "$s" ] && cand="$cand|$s|"
  done
  # also try current env (no explicit socket)
  cand="$cand|::env::|"
 
  # try pactl first with cookie if available
  if command -v pactl >/dev/null 2>&1; then
    IFS='|' read -r _ sock cookie rest <<EOF
$cand
EOF
    while [ -n "$sock" ] || [ -n "$rest" ]; do
      if [ "$sock" = "::env::" ]; then
        pactl info >/dev/null 2>&1 || true
        if pactl list sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*State:[[:space:]]*RUNNING' \
           || pactl list short sink-inputs 2>/dev/null | grep -q '^[0-9]\+' \
           || pactl list short source-outputs 2>/dev/null | grep -q '^[0-9]\+' ; then
          echo 1; return
        fi
      else
        if [ -n "$cookie" ]; then
          PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactl info >/dev/null 2>&1 || { IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
            continue; }
          if PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactl list sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*State:[[:space:]]*RUNNING' \
             || PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactl list short sink-inputs 2>/dev/null | grep -q '^[0-9]\+' \
             || PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactl list short source-outputs 2>/dev/null | grep -q '^[0-9]\+' ; then
            echo 1; return
          fi
        else
          PULSE_SERVER="unix:$sock" pactl info >/dev/null 2>&1 || { IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
            continue; }
          if PULSE_SERVER="unix:$sock" pactl list sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*State:[[:space:]]*RUNNING' \
             || PULSE_SERVER="unix:$sock" pactl list short sink-inputs 2>/dev/null | grep -q '^[0-9]\+' \
             || PULSE_SERVER="unix:$sock" pactl list short source-outputs 2>/dev/null | grep -q '^[0-9]\+' ; then
            echo 1; return
          fi
        fi
      fi
      IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
    done
  fi
 
  # fall back to pacmd if pactl didn't work
  if command -v pacmd >/dev/null 2>&1; then
    IFS='|' read -r _ sock cookie rest <<EOF
$cand
EOF
    while [ -n "$sock" ] || [ -n "$rest" ]; do
      if [ "$sock" = "::env::" ]; then
        pacmd stat >/dev/null 2>&1 || true
        if pacmd list-sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*state:[[:space:]]*RUNNING' \
           || pacmd list-sink-inputs 2>/dev/null | grep -q -m1 '^[[:space:]]*index:' \
           || pacmd list-source-outputs 2>/dev/null | grep -q -m1 '^[[:space:]]*index:' ; then
          echo 1; return
        fi
      else
        # pacmd -s doesn't use PULSE_COOKIE directly, but trying -s is still useful when the server is accessible
        pacmd -s "unix:$sock" stat >/dev/null 2>&1 || { IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
          continue; }
        if pacmd -s "unix:$sock" list-sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*state:[[:space:]]*RUNNING' \
           || pacmd -s "unix:$sock" list-sink-inputs 2>/dev/null | grep -q -m1 '^[[:space:]]*index:' \
           || pacmd -s "unix:$sock" list-source-outputs 2>/dev/null | grep -q -m1 '^[[:space:]]*index:' ; then
          echo 1; return
        fi
      fi
      IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
    done
  fi
 
  # Last resort: infer from our player/recorder logs
  if [ -n "${AUDIO_LOGCTX:-}" ] && [ -s "$AUDIO_LOGCTX" ]; then
    grep -qiE 'Connected to PulseAudio|Opening audio stream|Stream started|Starting recording|Playing' "$AUDIO_LOGCTX" && { echo 1; return; }
  fi
 
  echo 0
}
 
# 3) ALSA RUNNING - sample a few times to beat teardown race
audio_evidence_alsa_running_any() {
  found=0
  for f in /proc/asound/card*/pcm*/sub*/status; do
    [ -r "$f" ] || continue
    if grep -q "state:[[:space:]]*RUNNING" "$f"; then
      found=1; break
    fi
  done
  echo "$found"
}
# 4) ASoC path on - try both debugfs locations; mount if needed
audio_evidence_asoc_path_on() {
  base="/sys/kernel/debug/asoc"
  [ -d "$base" ] || { echo 0; return; }
 
  # Fast path: any explicit "On" marker in any dapm node
  if grep -RIlq --binary-files=text -E '(^|\s)\[on\]|\:\s*On(\s|$)' "$base"/*/dapm 2>/dev/null; then
    echo 1; return
  fi
 
  # Many QCS boards expose lots of Playback/Capture endpoints; if any of them say "On", mark active
  dapm_pc_files="$(grep -RIl --binary-files=text -E '/dapm/.*(Playback|Capture)$' "$base"/*/dapm 2>/dev/null)"
  if [ -n "$dapm_pc_files" ]; then
    echo "$dapm_pc_files" | xargs -r grep -I -q -E ':\s*On(\s|$)' 2>/dev/null && { echo 1; return; }
  fi
 
  # Some kernels only flip bias level when any path is active
  if grep -RIlq --binary-files=text '/dapm/bias_level$' "$base"/*/dapm 2>/dev/null; then
    grep -RIl --binary-files=text '/dapm/bias_level$' "$base"/*/dapm 2>/dev/null \
      | xargs -r grep -I -q -E 'On|Standby' 2>/dev/null && { echo 1; return; }
  fi
 
  # Fallback heuristic: if ALSA says a PCM substream is RUNNING, assume DAPM is up
  if audio_evidence_alsa_running_any 2>/dev/null | grep -qx 1; then
    echo 1; return
  fi
 
  echo 0
}
# 5) PW log evidence (optional, from AUDIO_LOGCTX)
audio_evidence_pw_log_seen() {
  if [ -n "${AUDIO_LOGCTX:-}" ] && [ -r "$AUDIO_LOGCTX" ]; then
    grep -qiE 'paused -> streaming|stream time:' "$AUDIO_LOGCTX" 2>/dev/null && { echo 1; return; }
  fi
  echo 0
}


# Parse a human duration into integer seconds.
# Prints seconds to stdout on success, returns 0.
# Prints nothing and returns non-zero on failure.
#
# Accepted examples:
#   "15" "15s" "15sec" "15secs" "15second" "15seconds"
#   "2m" "2min" "2mins" "2minute" "2minutes"
#   "1h" "1hr" "1hrs" "1hour" "1hours"
#   "1h30m" "2m10s" "1h2m3s" (any combination h/m/s)
#   "90s" "120m" "3h"
#   "MM:SS"   (e.g., "01:30" -> 90)
#   "HH:MM:SS" (e.g., "2:03:04" -> 7384)
audio_parse_secs() {
  in="$*"
  norm=$(printf '%s' "$in" | tr -d ' \t\r\n' | tr '[:upper:]' '[:lower:]')
  [ -n "$norm" ] || return 1
 
  case "$norm" in
    *:*)
      IFS=':' set -- "$norm"
      for p in "$@"; do case "$p" in ''|*[!0-9]*) return 1;; esac; done
      case $# in
        2) h=0; m=$1; s=$2 ;;
        3) h=$1; m=$2; s=$3 ;;
        *) return 1 ;;
      esac
      printf '%s\n' $(( ${h:-0}*3600 + ${m:-0}*60 + ${s:-0} ))
      return 0
      ;;
    *[!0-9]*)
      case "$norm" in
        [0-9]*s|[0-9]*sec|[0-9]*secs|[0-9]*second|[0-9]*seconds)
          n=$(printf '%s' "$norm" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'); printf '%s\n' "$n"; return 0 ;;
        [0-9]*m|[0-9]*min|[0-9]*mins|[0-9]*minute|[0-9]*minutes)
          n=$(printf '%s' "$norm" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'); printf '%s\n' $((n*60)); return 0 ;;
        [0-9]*h|[0-9]*hr|[0-9]*hrs|[0-9]*hour|[0-9]*hours)
          n=$(printf '%s' "$norm" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'); printf '%s\n' $((n*3600)); return 0 ;;
        *)
          tokens=$(printf '%s' "$norm" | sed 's/\([0-9][0-9]*[a-z][a-z]*\)/\1 /g')
          total=0; ok=0
          for t in $tokens; do
            n=$(printf '%s' "$t" | sed -n 's/^\([0-9][0-9]*\).*/\1/p') || return 1
            u=$(printf '%s' "$t" | sed -n 's/^[0-9][0-9]*\([a-z][a-z]*\)$/\1/p')
            case "$u" in
              s|sec|secs|second|seconds) add=$n ;;
              m|min|mins|minute|minutes) add=$((n*60)) ;;
              h|hr|hrs|hour|hours)       add=$((n*3600)) ;;
              *) return 1 ;;
            esac
            total=$((total+add)); ok=1
          done
          [ "$ok" -eq 1 ] 2>/dev/null || return 1
          printf '%s\n' "$total"
          return 0
          ;;
      esac
      ;;
    *)
      printf '%s\n' "$norm"
      return 0
      ;;
  esac
  return 1
}

# --- Local watchdog that always honors the first argument (e.g. "15" or "15s") ---
audio_exec_with_timeout() {
  dur="$1"; shift
  # normalize: allow "15" or "15s"
  case "$dur" in
    ""|"0") dur_norm=0 ;;
    *s) dur_norm="${dur%s}" ;;
    *) dur_norm="$dur" ;;
  esac
 
  # numeric? if not, treat as no-timeout
  case "$dur_norm" in *[!0-9]*|"") dur_norm=0 ;; esac
 
  if [ "$dur_norm" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
    timeout "$dur_norm" "$@"; return $?
  fi
 
  if [ "$dur_norm" -gt 0 ] 2>/dev/null; then
    # portable fallback watchdog
    "$@" &
    pid=$!
    (
      sleep "$dur_norm"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
    ) &
    w=$!
    wait "$pid"; rc=$?
    kill -TERM "$w" 2>/dev/null || true
    # map "killed by watchdog" to 124 (GNU timeout convention)
    [ "$rc" -eq 143 ] && rc=124
    return "$rc"
  fi
 
  # no timeout
  "$@"
}

# --------------------------------------------------------------------
# Backend chain + minimal ALSA capture picker (for fallback in run.sh)
# --------------------------------------------------------------------

# Prefer: currently selected (or detected) backend, then pipewire, pulseaudio, alsa.
# We keep it simple: we don't filter by daemon state here; the caller tries each.
build_backend_chain() {
  preferred="${AUDIO_BACKEND:-$(detect_audio_backend)}"
  chain=""
  add_unique() {
    case " $chain " in
      *" $1 "*) : ;;
      *) chain="${chain:+$chain }$1" ;;
    esac
  }
  [ -n "$preferred" ] && add_unique "$preferred"
  for b in pipewire pulseaudio alsa; do
    add_unique "$b"
  done
  printf '%s\n' "$chain"
}

# Pick a plausible ALSA capture device.
# Returns something like hw:0,0 if available, else "default".
alsa_pick_capture() {
  line="$(arecord -l 2>/dev/null | sed -n 's/^card \([0-9][0-9]*\):.*device \([0-9][0-9]*\):.*/\1 \2/p' | head -n1)"
  if [ -n "$line" ]; then
    set -- "$line"
    printf 'hw:%s,%s\n' "$1" "$2"
    return 0
  fi
  printf '%s\n' "default"
  return 0
}

alsa_pick_capture() {
  command -v arecord >/dev/null 2>&1 || return 1
  # Prefer the first real capture device from `arecord -l`
  arecord -l 2>/dev/null | awk '
    /card [0-9]+: .*device [0-9]+:/ {
      if (match($0, /card ([0-9]+):/, c) && match($0, /device ([0-9]+):/, d)) {
        printf("hw:%s,%s\n", c[1], d[1]);
        exit 0;
      }
    }
  '
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
