#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
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
# Resolve clip path for legacy matrix mode (formats × durations)
# Returns: clip path on stdout, 0=success, 1=no clip found
# Fallback: If hardcoded clip missing, uses first available .wav file
resolve_clip() {
  fmt="$1"; dur="$2"
  base="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"

  case "$fmt:$dur" in
    wav:short|wav:medium|wav:long)
      # Try hardcoded clip first (backward compatibility)
      clip="$base/yesterday_48KHz.wav"
      if [ -f "$clip" ]; then
        printf '%s\n' "$clip"
        return 0
      fi

      # Fallback: discover first available clip
      first_clip="$(find "$base" -maxdepth 1 -name "*.wav" -type f 2>/dev/null | head -n1)"
      if [ -n "$first_clip" ] && [ -f "$first_clip" ]; then
        log_info "Using legacy matrix mode. Using fallback: $(basename "$first_clip")" >&2
        printf '%s\n' "$first_clip"
        return 0
      fi

      # No clips available
      log_error "No audio clips found in $base" >&2
      printf '%s\n' ""
      return 1
      ;;
    *)
      printf '%s\n' ""
      return 1
      ;;
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
# 0 = clip exists/ready
# 2 = network unavailable after attempts (caller should SKIP)
# 1 = fetch/extract/downloader error (caller will also SKIP per your policy)
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
    sleep 1
    t=$((t + 1))
  done
  wait "$pid"; return $?
}

# ---- Guard wpctl/pactl/systemctl calls (prevents hangs on stuck control plane) ----
AUDIO_WPCTL_TIMEOUT="${AUDIO_WPCTL_TIMEOUT:-3s}"
AUDIO_WPCTL_TIMEOUT_LONG="${AUDIO_WPCTL_TIMEOUT_LONG:-8s}"
AUDIO_PACTL_TIMEOUT="${AUDIO_PACTL_TIMEOUT:-3s}"
AUDIO_SYSTEMCTL_TIMEOUT="${AUDIO_SYSTEMCTL_TIMEOUT:-20s}"

wpctlT() { audio_timeout_run "$AUDIO_WPCTL_TIMEOUT" wpctl "$@"; }
wpctlTL() { audio_timeout_run "$AUDIO_WPCTL_TIMEOUT_LONG" wpctl "$@"; }
pactlT() { audio_timeout_run "$AUDIO_PACTL_TIMEOUT" pactl "$@"; }
systemctlT() { audio_timeout_run "$AUDIO_SYSTEMCTL_TIMEOUT" systemctl "$@"; }

# ---------------- PipeWire (wpctl) freeze-mitigation helpers ----------------
# These helpers keep wpctl interactions bounded and reusable across targets.

audio_pw_wpctl_status_safe() {
  # $1 optional timeout (default: AUDIO_WPCTL_TIMEOUT_LONG)
  tmo="${1:-$AUDIO_WPCTL_TIMEOUT_LONG}"
  command -v wpctl >/dev/null 2>&1 || return 1
  audio_timeout_run "$tmo" wpctl status 2>/dev/null
}

audio_pw_wpctl_responsive() {
  # $1 optional timeout
  audio_pw_wpctl_status_safe "${1:-$AUDIO_WPCTL_TIMEOUT}" >/dev/null 2>&1
}

audio_pw_pick_source_id_safe() {
  # $1 = mic|null ; $2 optional timeout
  want="$1"
  tmo="${2:-$AUDIO_WPCTL_TIMEOUT_LONG}"

  st="$(audio_pw_wpctl_status_safe "$tmo")" || { printf '%s\n' ""; return 1; }

  blk="$(printf '%s\n' "$st" | sed -n '/Sources:/,/Filters:/p')"
  [ -n "$blk" ] || blk="$(printf '%s\n' "$st" | sed -n '/Sources:/,/^$/p')"

  case "$want" in
    null)
      printf '%s\n' "$blk" \
        | grep -i -E 'null|dummy' \
        | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' \
        | head -n1
      ;;
    *)
      id="$(printf '%s\n' "$blk" \
        | grep -i 'mic' \
        | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' \
        | head -n1)"
      [ -n "$id" ] || id="$(printf '%s\n' "$blk" \
        | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' \
        | head -n1)"
      printf '%s\n' "$id"
      ;;
  esac
  return 0
}

audio_pw_set_default_source_safe() {
  # $1 = numeric id ; $2 optional timeout
  id="$1"
  tmo="${2:-$AUDIO_WPCTL_TIMEOUT}"
  [ -n "$id" ] || return 0
  command -v wpctl >/dev/null 2>&1 || return 0
  audio_timeout_run "$tmo" wpctl set-default "$id" >/dev/null 2>&1 || true
  return 0
}

audio_pw_record_timeout_for() {
  # $1 = duration (e.g. 30s), $2 = TIMEOUT (user) ; output timeout string
  dur="$1"
  user_tmo="$2"

  if [ -n "$user_tmo" ] && [ "$user_tmo" != "0" ]; then
    printf '%s\n' "$user_tmo"
    return 0
  fi

  s_int="$(audio_parse_secs "$dur" 2>/dev/null || echo 0)"
  [ -z "$s_int" ] && s_int=0
  if [ "$s_int" -le 0 ] 2>/dev/null; then
    printf '%s\n' "45s"
    return 0
  fi
  printf '%s\n' "$((s_int + 10))s"
  return 0
}

audio_dump_mixers_safe() {
  # $1 = out file ; $2 optional timeout
  out="$1"
  tmo="${2:-$AUDIO_WPCTL_TIMEOUT_LONG}"

  {
    echo "---- wpctl status ----"
    if command -v wpctl >/dev/null 2>&1; then
      audio_timeout_run "$tmo" wpctl status 2>&1 || echo "(wpctl status failed/timeout)"
    else
      echo "(wpctl not found)"
    fi
    echo "---- pactl list ----"
    if command -v pactl >/dev/null 2>&1; then
      pactlT list 2>&1 || echo "(pactl list failed/timeout)"
    else
      echo "(pactl not found)"
    fi
  } >"$out" 2>/dev/null
}

# Back-compat alias used by existing run.sh scripts
dump_mixers() { audio_dump_mixers_safe "$1" "$AUDIO_WPCTL_TIMEOUT_LONG"; }

# Function: setup_overlay_audio_environment
# Purpose: Configure audio environment for overlay builds (audioreach-based)
# Returns: 0 on success, 1 on failure
# Usage: Call early in audio test initialization, before backend detection
setup_overlay_audio_environment() {
  # Detect overlay build
  if ! lsmod 2>/dev/null | awk '$1 ~ /^audioreach/ { found=1; exit } END { exit !found }'; then
    log_info "Base build detected (no audioreach modules), skipping overlay setup"
    return 0
  fi
 
  log_info "Overlay build detected (audioreach modules present), configuring environment..."
 
  # Check root permissions
  if [ "$(id -u)" -ne 0 ]; then
    log_fail "Overlay audio setup requires root permissions"
    return 1
  fi
 
  # Configure DMA heap permissions
  if [ -e /dev/dma_heap/system ]; then
    log_info "Setting permissions on /dev/dma_heap/system"
    chmod 666 /dev/dma_heap/system || {
      log_fail "Failed to chmod /dev/dma_heap/system"
      return 1
    }
  else
    log_warn "/dev/dma_heap/system not found, skipping chmod"
  fi
 
  # Check systemctl availability
  if ! command -v systemctl >/dev/null 2>&1; then
    log_fail "systemctl not available, cannot restart pipewire"
    return 1
  fi
 
  # ---- Idempotent per-boot behavior ----
  # Overlay needs one restart after boot; subsequent test runs in the same boot
  # should NOT keep restarting (can hit systemd start-limit / transient dbus issues).
  STAMP="/run/.audio_overlay_pipewire_restarted"
 
  # If we've already done the restart once this boot, just validate readiness.
  if [ -f "$STAMP" ]; then
    if pgrep -x pipewire >/dev/null 2>&1; then
      if command -v wpctl >/dev/null 2>&1 && wpctlTL status >/dev/null 2>&1; then
        log_info "Overlay already configured this boot, PipeWire is ready. Skipping restart."
        return 0
      fi
    fi
    log_warn "Overlay already configured this boot, but PipeWire not ready.. attempting recovery restart..."
  fi
 
  # Restart PipeWire (guard against systemd/dbus hangs)
  log_info "Restarting pipewire service..."
 
  # Clear systemd start-limit if any (common after repeated restarts)
  systemctlT reset-failed pipewire >/dev/null 2>&1 || true
  systemctlT reset-failed pipewire-pulse >/dev/null 2>&1 || true
 
  if ! systemctlT restart pipewire >/dev/null 2>&1; then
    # If restart failed but service is actually healthy, treat as success (non-flaky).
    if pgrep -x pipewire >/dev/null 2>&1; then
      if command -v wpctl >/dev/null 2>&1 && wpctlTL status >/dev/null 2>&1; then
        : >"$STAMP" 2>/dev/null || true
        log_warn "pipewire restart returned failure, but PipeWire is responsive.. continuing."
        return 0
      fi
    fi
 
    # One more attempt after reset-failed (handles start-limit-hit)
    systemctlT reset-failed pipewire >/dev/null 2>&1 || true
    if ! systemctlT restart pipewire >/dev/null 2>&1; then
      log_fail "Failed to restart pipewire service"
      return 1
    fi
  fi
 
  # Wait for PipeWire with polling (max 60s, check every 2s)
  log_info "Waiting for pipewire to be ready..."
  max_wait=60
  elapsed=0
  poll_interval=2
 
  while [ "$elapsed" -lt "$max_wait" ]; do
    # Check if pipewire process is running
    if pgrep -x pipewire >/dev/null 2>&1; then
      # Verify wpctl can communicate (GUARDED to avoid freeze)
      if command -v wpctl >/dev/null 2>&1 && wpctlTL status >/dev/null 2>&1; then
        : >"$STAMP" 2>/dev/null || true
        log_pass "PipeWire is ready (took ${elapsed}s)"
        return 0
      fi
    fi
 
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
 
    if [ $((elapsed % 10)) -eq 0 ]; then
      log_info "Still waiting for pipewire... (${elapsed}s/${max_wait}s)"
    fi
  done
 
  # Timeout reached
  log_fail "PipeWire failed to become ready within ${max_wait}s"
  log_fail "Check 'systemctl status pipewire' and 'journalctl -u pipewire' for details"
  return 1
}

# ---------- PipeWire: sinks (playback) ----------
pw_default_speakers() {
  _block="$(wpctlTL status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p')"
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
  wpctlTL status 2>/dev/null \
  | sed -n '/Sinks:/,/Sources:/p' \
  | grep -i -E 'null|dummy|loopback|monitor' \
  | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' \
  | head -n1
}

pw_sink_name_safe() {
  id="$1"; [ -n "$id" ] || { echo ""; return 1; }
  name="$(wpctlT inspect "$id" 2>/dev/null | grep -m1 'node.description' | cut -d'"' -f2)"
  [ -n "$name" ] || name="$(wpctlT inspect "$id" 2>/dev/null | grep -m1 'node.name' | cut -d'"' -f2)"
  if [ -z "$name" ]; then
    name="$(wpctlTL status 2>/dev/null \
      | sed -n '/Sinks:/,/Sources:/p' \
      | grep -E "^[^0-9]*${id}[.][[:space:]]" \
      | sed 's/^[^0-9]*[0-9][0-9]*[.][[:space:]][[:space:]]*//' \
      | sed 's/[[:space:]]*\[vol:.*$//' \
      | head -n1)"
  fi
  printf '%s\n' "$name"
}

pw_sink_name() { pw_sink_name_safe "$@"; } # back-compat alias
pw_set_default_sink() { [ -n "$1" ] && wpctlT set-default "$1" >/dev/null 2>&1; }

# ---------- PipeWire: sources (record) ----------
pw_default_mic() {
  blk="$(wpctlTL status 2>/dev/null | sed -n '/Sources:/,/^$/p')"
  id="$(printf '%s\n' "$blk" | grep -i 'mic' | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  [ -n "$id" ] || id="$(printf '%s\n' "$blk" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  printf '%s\n' "$id"
}

pw_default_null_source() {
  blk="$(wpctlTL status 2>/dev/null | sed -n '/Sources:/,/^$/p')"
  id="$(printf '%s\n' "$blk" | grep -i 'null\|dummy' | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  printf '%s\n' "$id"
}

pw_set_default_source() { [ -n "$1" ] && wpctlT set-default "$1" >/dev/null 2>&1; }

pw_source_label_safe() {
  id="$1"; [ -n "$id" ] || { echo ""; return 1; }
  label="$(wpctlT inspect "$id" 2>/dev/null | grep -m1 'node.description' | cut -d'"' -f2)"
  [ -n "$label" ] || label="$(wpctlT inspect "$id" 2>/dev/null | grep -m1 'node.name' | cut -d'"' -f2)"
  if [ -z "$label" ]; then
    label="$(wpctlTL status 2>/dev/null \
      | sed -n '/Sources:/,/Filters:/p' \
      | grep -E "^[^0-9]*${id}[.][[:space:]]" \
      | sed 's/^[^0-9]*[0-9][0-9]*[.][[:space:]][[:space:]]*//' \
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
    # Count Input/Output streams in RUNNING state (GUARDED)
    wpctlTL status 2>/dev/null | grep -Eq 'RUNNING' && { echo 1; return; }
  fi
  # Fallback to log
  if [ -n "${AUDIO_LOGCTX:-}" ] && [ -r "$AUDIO_LOGCTX" ]; then
    grep -qiE 'paused -> streaming|stream time:' "$AUDIO_LOGCTX" 2>/dev/null && { echo 1; return; }
  fi
  echo 0
}

# 2) PulseAudio streaming - safe when PA is absent (returns 0 without forcing FAIL)
audio_evidence_pa_streaming() {
  command -v pactl >/dev/null 2>&1 || command -v pacmd >/dev/null 2>&1 || {
    if [ -n "${AUDIO_LOGCTX:-}" ] && [ -s "$AUDIO_LOGCTX" ]; then
      grep -qiE 'Connected to PulseAudio|Opening audio stream|Stream started|Starting recording|Playing' "$AUDIO_LOGCTX" && { echo 1; return; }
    fi
    echo 0; return
  }

  cand=""
  for d in /run/user/* /var/run/user/*; do
    [ -S "$d/pulse/native" ] || continue
    sock="$d/pulse/native"
    cookie=""
    [ -r "$d/pulse/cookie" ] && cookie="$d/pulse/cookie"
    uid="$(stat -c %u "$d" 2>/dev/null || stat -f %u "$d" 2>/dev/null || echo)"
    if [ -n "$uid" ]; then
      home="$(getent passwd "$uid" 2>/dev/null | awk -F: '{print $6}')"
      [ -n "$home" ] && [ -r "$home/.config/pulse/cookie" ] && cookie="$home/.config/pulse/cookie"
    fi
    cand="$cand|$sock|$cookie"
  done
  for s in /run/pulse/native /var/run/pulse/native; do
    [ -S "$s" ] && cand="$cand|$s|"
  done
  cand="$cand|::env::|"

  if command -v pactl >/dev/null 2>&1; then
    IFS='|' read -r _ sock cookie rest <<EOF
$cand
EOF
    while [ -n "$sock" ] || [ -n "$rest" ]; do
      if [ "$sock" = "::env::" ]; then
        pactlT info >/dev/null 2>&1 || true
        if pactlT list sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*State:[[:space:]]*RUNNING' \
           || pactlT list short sink-inputs 2>/dev/null | grep -q '^[0-9][0-9]*' \
           || pactlT list short source-outputs 2>/dev/null | grep -q '^[0-9][0-9]*' ; then
          echo 1; return
        fi
      else
        if [ -n "$cookie" ]; then
          PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactlT info >/dev/null 2>&1 || {
            IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
            continue
          }
          if PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactlT list sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*State:[[:space:]]*RUNNING' \
             || PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactlT list short sink-inputs 2>/dev/null | grep -q '^[0-9][0-9]*' \
             || PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactlT list short source-outputs 2>/dev/null | grep -q '^[0-9][0-9]*' ; then
            echo 1; return
          fi
        else
          PULSE_SERVER="unix:$sock" pactlT info >/dev/null 2>&1 || {
            IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
            continue
          }
          if PULSE_SERVER="unix:$sock" pactlT list sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*State:[[:space:]]*RUNNING' \
             || PULSE_SERVER="unix:$sock" pactlT list short sink-inputs 2>/dev/null | grep -q '^[0-9][0-9]*' \
             || PULSE_SERVER="unix:$sock" pactlT list short source-outputs 2>/dev/null | grep -q '^[0-9][0-9]*' ; then
            echo 1; return
          fi
        fi
      fi
      IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
    done
  fi

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
        pacmd -s "unix:$sock" stat >/dev/null 2>&1 || {
          IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
          continue
        }
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

# 4) ASoC path on
audio_evidence_asoc_path_on() {
  base="/sys/kernel/debug/asoc"
  [ -d "$base" ] || { echo 0; return; }

  if grep -RIlq --binary-files=text -E '(^|\s)\[on\]|\:\s*On(\s|$)' "$base"/*/dapm 2>/dev/null; then
    echo 1; return
  fi

  dapm_pc_files="$(grep -RIl --binary-files=text -E '/dapm/.*(Playback|Capture)$' "$base"/*/dapm 2>/dev/null)"
  if [ -n "$dapm_pc_files" ]; then
    echo "$dapm_pc_files" | xargs -r grep -I -q -E ':\s*On(\s|$)' 2>/dev/null && { echo 1; return; }
  fi

  if grep -RIlq --binary-files=text '/dapm/bias_level$' "$base"/*/dapm 2>/dev/null; then
    grep -RIl --binary-files=text '/dapm/bias_level$' "$base"/*/dapm 2>/dev/null \
      | xargs -r grep -I -q -E 'On|Standby' 2>/dev/null && { echo 1; return; }
  fi

  if audio_evidence_alsa_running_any 2>/dev/null | grep -qx 1; then
    echo 1; return
  fi

  echo 0
}

audio_evidence_pw_log_seen() {
  if [ -n "${AUDIO_LOGCTX:-}" ] && [ -r "$AUDIO_LOGCTX" ]; then
    grep -qiE 'paused -> streaming|stream time:' "$AUDIO_LOGCTX" 2>/dev/null && { echo 1; return; }
  fi
  echo 0
}

# Parse a human duration into integer seconds.
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
      h_val=${h:-0}; m_val=${m:-0}; s_val=${s:-0}
      result=$((h_val * 3600 + m_val * 60 + s_val))
      printf '%s\n' "$result"
      return 0
      ;;
    *[!0-9]*)
      case "$norm" in
        [0-9]*s|[0-9]*sec|[0-9]*secs|[0-9]*second|[0-9]*seconds)
          n=$(printf '%s' "$norm" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'); printf '%s\n' "$n"; return 0 ;;
        [0-9]*m|[0-9]*min|[0-9]*mins|[0-9]*minute|[0-9]*minutes)
          n=$(printf '%s' "$norm" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'); printf '%s\n' "$((n * 60))"; return 0 ;;
        [0-9]*h|[0-9]*hr|[0-9]*hrs|[0-9]*hour|[0-9]*hours)
          n=$(printf '%s' "$norm" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'); printf '%s\n' "$((n * 3600))"; return 0 ;;
        *)
          tokens=$(printf '%s' "$norm" | sed 's/\([0-9][0-9]*[a-z][a-z]*\)/\1 /g')
          total=0; ok=0
          for t in $tokens; do
            n=$(printf '%s' "$t" | sed -n 's/^\([0-9][0-9]*\).*/\1/p') || return 1
            u=$(printf '%s' "$t" | sed -n 's/^[0-9][0-9]*\([a-z][a-z]*\)$/\1/p')
            case "$u" in
              s|sec|secs|second|seconds) add=$n ;;
              m|min|mins|minute|minutes) add=$((n * 60)) ;;
              h|hr|hrs|hour|hours) add=$((n * 3600)) ;;
              *) return 1 ;;
            esac
            total=$((total + add)); ok=1
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

  case "$dur_norm" in *[!0-9]*|"") dur_norm=0 ;; esac

  if [ "$dur_norm" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
    timeout "$dur_norm" "$@"; return $?
  fi

  if [ "$dur_norm" -gt 0 ] 2>/dev/null; then
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
    [ "$rc" -eq 143 ] && rc=124
    return "$rc"
  fi

  "$@"
}

# --------------------------------------------------------------------
# File size helper (portable across different stat implementations)
# --------------------------------------------------------------------
file_size_bytes() {
  file="$1"
  [ -f "$file" ] || return 1
  [ -r "$file" ] || return 1
  wc -c < "$file" 2>/dev/null
}

extract_clip_duration() {
  filename="$1"
  duration_str="$(printf '%s' "$filename" | sed -n 's/.*_[0-9.][0-9.]*KHz_\([0-9][0-9]*\)s_[0-9][0-9]*b_[0-9][0-9]*ch\.wav$/\1/p')"
  if [ -z "$duration_str" ]; then
    return 1
  fi
  printf '%s\n' "$duration_str"
  return 0
}

# --------------------------------------------------------------------
# Backend chain + minimal ALSA capture picker (for fallback in run.sh)
# --------------------------------------------------------------------
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

alsa_pick_capture() {
  command -v arecord >/dev/null 2>&1 || return 1
  arecord -l 2>/dev/null | awk '
    /card [0-9]+: .*device [0-9]+:/ {
      if (match($0, /card ([0-9]+):/, c) && match($0, /device ([0-9]+):/, d)) {
        printf("hw:%s,%s\n", c[1], d[1]);
        exit 0;
      }
    }
  '
}

alsa_pick_virtual_pcm() {
  command -v arecord >/dev/null 2>&1 || return 1
  pcs="$(arecord -L 2>/dev/null | sed -n 's/^[[:space:]]*\([[:alnum:]_][[:alnum:]_]*\)[[:space:]]*$/\1/p')"
  for pcm in pipewire pulse default; do
    if printf '%s\n' "$pcs" | grep -m1 -x "$pcm" >/dev/null 2>&1; then
      printf '%s\n' "$pcm"
      return 0
    fi
  done
  return 1
}

audio_check_clips_available() {
  formats="$1"
  durations="$2"

  for fmt in $formats; do
    for dur in $durations; do
      clip="$(resolve_clip "$fmt" "$dur")"
      if [ -z "$clip" ] || [ ! -s "$clip" ]; then
        return 1
      fi
    done
  done
  return 0
}

# ---------- Config Mapping ----------
map_config_to_testcase() {
  config="$1"
  config_num=""
  case "$config" in
    playback_config*)
      config_num="$(printf '%s' "$config" | sed -n 's/^playback_config0*\([0-9][0-9]*\)$/\1/p')"
      [ -n "$config_num" ] || return 1
      ;;
    Config*)
      config_num="$(printf '%s' "$config" | sed -n 's/^Config0*\([0-9][0-9]*\)$/\1/p')"
      [ -n "$config_num" ] || return 1
      ;;
    [0-9]*)
      config_num="$config"
      ;;
  esac

  case "$config_num" in
    1) printf 'play_8KHz_8b_1ch\n' ;;
    2) printf 'play_16KHz_8b_6ch\n' ;;
    3) printf 'play_16KHz_16b_2ch\n' ;;
    4) printf 'play_22.05KHz_8b_1ch\n' ;;
    5) printf 'play_24KHz_24b_6ch\n' ;;
    6) printf 'play_24KHz_32b_1ch\n' ;;
    7) printf 'play_32KHz_8b_8ch\n' ;;
    8) printf 'play_32KHz_16b_2ch\n' ;;
    9) printf 'play_44.1KHz_16b_1ch\n' ;;
    10) printf 'play_48KHz_8b_2ch\n' ;;
    *) return 1 ;;
  esac
  return 0
}

discover_audio_clips() {
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"
  if [ ! -d "$clips_dir" ]; then
    log_error "Clips directory not found: $clips_dir" >&2
    return 1
  fi
  clips="$(find "$clips_dir" -maxdepth 1 -name "*.wav" -type f 2>/dev/null | sort)"
  if [ -z "$clips" ]; then
    log_error "No .wav files found in $clips_dir" >&2
    return 1
  fi
  for clip in $clips; do
    basename "$clip"
  done
  return 0
}

parse_clip_metadata() {
  filename="$1"
  # Produces: "<rate> <bits> <channels>"
  metadata="$(printf '%s' "$filename" | sed -n 's/.*_\([0-9.][0-9.]*KHz\)_\([0-9][0-9]*s\)_\([0-9][0-9]*b\)_\([0-9][0-9]*ch\)\.wav$/\1 \3 \4/p')"
  if [ -z "$metadata" ]; then
    log_warn "Cannot parse metadata from: $filename (skipping)"
    return 1
  fi

  rate="${metadata%% *}"
  rest="${metadata#* }"
  bits="${rest%% *}"
  channels="${rest#* }"

  if [ -z "$rate" ] || [ -z "$bits" ] || [ -z "$channels" ] || [ "$rest" = "$metadata" ]; then
    log_warn "Cannot parse metadata from: $filename (skipping)"
    return 1
  fi

  printf 'rate=%s bits=%s channels=%s\n' "$rate" "$bits" "$channels"
  return 0
}

generate_clip_testcase_name() {
  filename="$1"
  metadata="$(parse_clip_metadata "$filename")" || return 1

  first="${metadata%% *}"
  rest="${metadata#* }"
  second="${rest%% *}"
  third="${rest#* }"

  rate="${first#rate=}"
  bits="${second#bits=}"
  channels="${third#channels=}"

  printf 'play_%s_%s_%s\n' "$rate" "$bits" "$channels"
  return 0
}

resolve_clip_by_name() {
  name="$1"
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"

  if printf '%s' "$name" | grep -F -q -- '.wav'; then
    clip_path="$clips_dir/$name"
    if [ -f "$clip_path" ]; then
      printf '%s\n' "$clip_path"
      return 0
    fi
  fi

  search_name="$(printf '%s' "$name" | sed 's/^play_//')"
  for clip_file in "$clips_dir"/*.wav; do
    [ -f "$clip_file" ] || continue
    clip_basename="$(basename "$clip_file")"
    if printf '%s' "$clip_basename" | grep -F -q -- "$search_name"; then
      printf '%s\n' "$clip_file"
      return 0
    fi
  done
  return 1
}

validate_clip_name() {
  requested_name="$1"
  available_clips="$2"

  config_num=""
  case "$requested_name" in
    playback_config*)
      config_num="$(printf '%s' "$requested_name" | sed -n 's/^playback_config\([0-9][0-9]*\)$/\1/p')"
      ;;
    [Cc]onfig*)
      config_num="$(printf '%s' "$requested_name" | sed -n 's/^[Cc]onfig\([0-9][0-9]*\)$/\1/p')"
      ;;
  esac

  if [ -n "$config_num" ]; then
    idx=0
    for _clip in $available_clips; do
      idx=$((idx + 1))
    done

    if [ "$config_num" -le 0 ] 2>/dev/null || [ "$config_num" -gt "$idx" ] 2>/dev/null; then
      log_error "Invalid config number: $requested_name. Available range: Config1 to Config$idx. Please check again." >&2
      return 1
    fi

    current_idx=0
    for clip in $available_clips; do
      current_idx=$((current_idx + 1))
      if [ "$current_idx" -eq "$config_num" ]; then
        printf '%s\n' "$clip"
        return 0
      fi
    done

    log_error "Invalid config number: $requested_name. Available range: Config1 to Config$idx. Please check again." >&2
    return 1
  fi

  for clip in $available_clips; do
    test_name="$(generate_clip_testcase_name "$clip" 2>/dev/null)" || continue
    if [ "$test_name" = "$requested_name" ]; then
      printf '%s\n' "$clip"
      return 0
    fi
  done

  idx=0
  for _clip in $available_clips; do
    idx=$((idx + 1))
  done

  log_error "Wrong clip name: '$requested_name'. Available range: playback_config1 to playback_config$idx. Please check again." >&2
  return 1
}

apply_clip_filter() {
  filter="$1"
  available_clips="$2"

  if [ -z "$filter" ]; then
    printf '%s\n' "$available_clips"
    return 0
  fi

  filtered=""
  for clip in $available_clips; do
    for pattern in $filter; do
      test_name="$(generate_clip_testcase_name "$clip" 2>/dev/null)" || continue
      if printf '%s %s' "$clip" "$test_name" | grep -F -q -- "$pattern"; then
        filtered="$filtered $clip"
        break
      fi
    done
  done

  filtered="$(printf '%s' "$filtered" | sed 's/^ //')"
  if [ -z "$filtered" ]; then
    log_error "Filter '$filter' matched no clips" >&2
    log_info "Available clips:" >&2
    for clip in $available_clips; do
      log_info " - $(basename "$clip")" >&2
    done
    return 1
  fi

  printf '%s\n' "$filtered"
  return 0
}

validate_clip_file() {
  clip_path="$1"
  if [ ! -f "$clip_path" ]; then
    log_error "Clip file not found: $clip_path"
    return 1
  fi
  if [ ! -r "$clip_path" ]; then
    log_error "Clip file not readable: $clip_path"
    return 1
  fi
  size="$(file_size_bytes "$clip_path")"
  if [ -z "$size" ] || [ "$size" -le 0 ] 2>/dev/null; then
    log_error "Clip file is empty: $clip_path"
    return 1
  fi
  return 0
}

discover_and_filter_clips() {
  clip_names="$1"
  clip_filter="$2"

  available_clips="$(discover_audio_clips)" || {
    log_error "Failed to discover audio clips" >&2
    return 1
  }

  if [ -n "$clip_names" ]; then
    validated=""
    failed_names=""

    for name in $clip_names; do
      if clip="$(validate_clip_name "$name" "$available_clips")"; then
        validated="$validated $clip"
      else
        failed_names="$failed_names $name"
      fi
    done

    validated="$(printf '%s' "$validated" | sed 's/^ //')"
    failed_names="$(printf '%s' "$failed_names" | sed 's/^ //')"

    [ -n "$validated" ] || return 1

    if [ -n "$failed_names" ]; then
      log_warn "Invalid clip/config names skipped: $failed_names" >&2
    fi

    printf '%s\n' "$validated"
    return 0
  fi

  if [ -n "$clip_filter" ]; then
    filtered="$(apply_clip_filter "$clip_filter" "$available_clips" 2>/dev/null)" || {
      log_error "Filter did not match any clips" >&2
      return 1
    }
    printf '%s\n' "$filtered"
    return 0
  fi

  printf '%s\n' "$available_clips"
  return 0
}

# ---------- Record Configuration Functions (10-config enhancement) ----------
discover_record_configs() {
  printf '%s\n' "record_config1 record_config2 record_config3 record_config4 record_config5 record_config6 record_config7 record_config8 record_config9 record_config10"
  return 0
}

get_record_config_params() {
  config_name="$1"
  normalized_name="$config_name"
  case "$config_name" in
    record_config0*)
      config_num="$(printf '%s' "$config_name" | sed -n 's/^record_config0*\([0-9][0-9]*\)$/\1/p')"
      if [ -n "$config_num" ]; then
        normalized_name="record_config$config_num"
      fi
      ;;
  esac

  case "$normalized_name" in
    record_config1|record_8KHz_1ch) printf '%s\n' "8000 1" ;;
    record_config2|record_16KHz_1ch) printf '%s\n' "16000 1" ;;
    record_config3|record_16KHz_2ch) printf '%s\n' "16000 2" ;;
    record_config4|record_24KHz_1ch) printf '%s\n' "24000 1" ;;
    record_config5|record_32KHz_2ch) printf '%s\n' "32000 2" ;;
    record_config6|record_44.1KHz_2ch) printf '%s\n' "44100 2" ;;
    record_config7|record_48KHz_2ch) printf '%s\n' "48000 2" ;;
    record_config8|record_48KHz_6ch) printf '%s\n' "48000 6" ;;
    record_config9|record_96KHz_2ch) printf '%s\n' "96000 2" ;;
    record_config10|record_96KHz_6ch) printf '%s\n' "96000 6" ;;
    *) return 1 ;;
  esac
  return 0
}

generate_record_testcase_name() {
  config_name="$1"
  normalized_name="$config_name"
  case "$config_name" in
    record_config0*)
      config_num="$(printf '%s' "$config_name" | sed -n 's/^record_config0*\([0-9][0-9]*\)$/\1/p')"
      normalized_name="record_config$config_num"
      ;;
  esac

  case "$normalized_name" in
    record_config1) printf '%s\n' "record_8KHz_1ch" ;;
    record_config2) printf '%s\n' "record_16KHz_1ch" ;;
    record_config3) printf '%s\n' "record_16KHz_2ch" ;;
    record_config4) printf '%s\n' "record_24KHz_1ch" ;;
    record_config5) printf '%s\n' "record_32KHz_2ch" ;;
    record_config6) printf '%s\n' "record_44.1KHz_2ch" ;;
    record_config7) printf '%s\n' "record_48KHz_2ch" ;;
    record_config8) printf '%s\n' "record_48KHz_6ch" ;;
    record_config9) printf '%s\n' "record_96KHz_2ch" ;;
    record_config10) printf '%s\n' "record_96KHz_6ch" ;;
    *) printf '%s\n' "$config_name" ;;
  esac
  return 0
}

generate_record_filename() {
  testcase_base="$1"
  rate="$2"
  channels="$3"

  rate_khz="$rate"
  case "$rate" in
    8000) rate_khz="8KHz" ;;
    16000) rate_khz="16KHz" ;;
    22050) rate_khz="22.05KHz" ;;
    24000) rate_khz="24KHz" ;;
    32000) rate_khz="32KHz" ;;
    44100) rate_khz="44.1KHz" ;;
    48000) rate_khz="48KHz" ;;
    88200) rate_khz="88.2KHz" ;;
    96000) rate_khz="96KHz" ;;
    176400) rate_khz="176.4KHz" ;;
    192000) rate_khz="192KHz" ;;
    352800) rate_khz="352.8KHz" ;;
    384000) rate_khz="384KHz" ;;
    *) rate_khz="${rate}Hz" ;;
  esac

  printf '%s_%s_%sch.wav\n' "$testcase_base" "$rate_khz" "$channels"
  return 0
}

validate_record_config_name() {
  requested_name="$1"
  if get_record_config_params "$requested_name" >/dev/null 2>&1; then
    return 0
  fi
  log_error "Invalid record config name: $requested_name" >&2
  log_error "Available configs: record_config1-record_config10, record_8KHz_1ch, record_16KHz_1ch, record_16KHz_2ch, record_24KHz_1ch, record_32KHz_2ch, record_44.1KHz_2ch, record_48KHz_2ch, record_48KHz_6ch, record_96KHz_2ch, record_96KHz_6ch" >&2
  return 1
}

apply_record_config_filter() {
  filter="$1"
  available_configs="$2"

  if [ -z "$filter" ]; then
    printf '%s\n' "$available_configs"
    return 0
  fi

  filtered=""
  for config in $available_configs; do
    desc_name="$(generate_record_testcase_name "$config" 2>/dev/null)" || continue
    for pattern in $filter; do
      if printf '%s %s' "$config" "$desc_name" | grep -F -q -- "$pattern"; then
        filtered="$filtered $config"
        break
      fi
    done
  done

  filtered="$(printf '%s' "$filtered" | sed 's/^ //')"
  if [ -z "$filtered" ]; then
    log_error "Filter '$filter' matched no record configs" >&2
    log_info "Available configs: record_config1 to record_config10" >&2
    return 1
  fi

  printf '%s\n' "$filtered"
  return 0
}

discover_and_filter_record_configs() {
  config_names="$1"
  config_filter="$2"
  available_configs="$(discover_record_configs)"

  if [ -n "$config_names" ]; then
    validated=""
    failed_names=""
    for name in $config_names; do
      if validate_record_config_name "$name"; then
        validated="$validated $name"
      else
        failed_names="$failed_names $name"
      fi
    done

    validated="$(printf '%s' "$validated" | sed 's/^ //')"
    failed_names="$(printf '%s' "$failed_names" | sed 's/^ //')"

    [ -n "$validated" ] || return 1

    if [ -n "$failed_names" ]; then
      log_warn "Invalid record config names skipped: $failed_names" >&2
    fi

    printf '%s\n' "$validated"
    return 0
  fi

  if [ -n "$config_filter" ]; then
    filtered="$(apply_record_config_filter "$config_filter" "$available_configs")" || return 1
    printf '%s\n' "$filtered"
    return 0
  fi

  printf '%s\n' "$available_configs"
  return 0
}
