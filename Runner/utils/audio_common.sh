#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Common audio helpers for PipeWire / PulseAudio runners.
# Requires: functestlib.sh (log_* helpers, extract_tar_from_url, scan_dmesg_errors)
# Reuse the repository package-provider abstraction directly.
if [ -n "${TOOLS:-}" ] &&
   [ -r "$TOOLS/lib_pkg_provider.sh" ] &&
   ! command -v pkg_detect_os_id >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$TOOLS/lib_pkg_provider.sh"
fi

# Check whether a command exists in PATH.
# Used by bootstrap helpers before attempting backend startup.
have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

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

audio_proc_running() {
  name="$1"
  [ -z "$name" ] && return 1

  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x "$name" >/dev/null 2>&1; return $?
  fi

  if command -v pidof >/dev/null 2>&1; then
    pidof "$name" >/dev/null 2>&1; return $?
  fi

  # shellcheck disable=SC2009
  ps 2>/dev/null | grep -w "$name" | grep -v grep >/dev/null 2>&1
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

audio_has_runnable_discovery_clips() {
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"
  found_any=0

  if [ ! -d "$clips_dir" ]; then
    return 1
  fi

  for audio_clip_path in "$clips_dir"/*.wav; do
    if [ ! -f "$audio_clip_path" ]; then
      continue
    fi

    found_any=1
    audio_clip_file="$(basename "$audio_clip_path")"
    if generate_clip_testcase_name "$audio_clip_file" >/dev/null 2>&1; then
      return 0
    fi
  done

  if [ "$found_any" -eq 1 ]; then
    return 1
  fi

  return 1
}

# audio_fetch_assets_from_url <url>
# Prefer functestlib's extract_tar_from_url; otherwise download + extract.
audio_fetch_assets_from_url() {
  url="$1"
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"
  marker_file="${AUDIO_EXTRACT_MARKER:-$clips_dir/.audioclips_extracted}"
  work_dir="${SCRIPT_DIR:-$(pwd)}"
  ts="$(date +%s 2>/dev/null || echo 0)"
  archive_path="$work_dir/AudioClips.$$.${ts}.tar.gz"
  fetch_log="$work_dir/AudioClips_fetch.$$.${ts}.log"
  fetch_attempts="${AUDIO_FETCH_RETRIES:-2}"
  fetch_retry_delay="${AUDIO_FETCH_RETRY_DELAY:-3}"
  fetch_attempt=1

  if [ -z "$url" ]; then
    log_error "audio_fetch_assets_from_url: URL is empty"
    return 1
  fi

  if [ ! -d "$clips_dir" ]; then
    if ! mkdir -p "$clips_dir"; then
      log_error "Failed to create clips directory: $clips_dir"
      return 1
    fi
  fi

  if [ -f "$marker_file" ]; then
    if audio_has_runnable_discovery_clips; then
      log_pass "AudioClips.tar.gz has already been extracted (marker present, runnable clips available)."
      log_info "Already extracted. Skipping download."
      return 0
    fi
    log_warn "Extraction marker present but runnable clips not found, continuing with download/re-extract path"
  fi

  while [ "$fetch_attempt" -le "$fetch_attempts" ]; do
    rm -f "$archive_path" >/dev/null 2>&1 || true
    rm -f "$fetch_log" >/dev/null 2>&1 || true

    download_ok=0

    if command -v curl >/dev/null 2>&1; then
      log_info "exec: curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o \"$archive_path\" \"$url\" (attempt ${fetch_attempt}/${fetch_attempts})"
      if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$archive_path" "$url" >"$fetch_log" 2>&1; then
        download_ok=1
      else
        log_warn "curl download failed on attempt ${fetch_attempt}/${fetch_attempts}, showing last lines from $fetch_log"
        tail -n 20 "$fetch_log" 2>/dev/null || true
      fi
    fi

    if [ "$download_ok" -ne 1 ]; then
      if command -v wget >/dev/null 2>&1; then
        log_info "exec: wget --tries=3 --timeout=20 -O \"$archive_path\" \"$url\" (attempt ${fetch_attempt}/${fetch_attempts})"
        if wget --tries=3 --timeout=20 -O "$archive_path" "$url" >"$fetch_log" 2>&1; then
          download_ok=1
        else
          log_warn "wget download failed on attempt ${fetch_attempt}/${fetch_attempts}, showing last lines from $fetch_log"
          tail -n 20 "$fetch_log" 2>/dev/null || true
        fi
      fi
    fi

    if [ "$download_ok" -eq 1 ]; then
      break
    fi

    if [ "$fetch_attempt" -lt "$fetch_attempts" ]; then
      log_warn "Download attempt ${fetch_attempt}/${fetch_attempts} failed, retrying after ${fetch_retry_delay}s"
      sleep "$fetch_retry_delay"
    fi

    fetch_attempt=$((fetch_attempt + 1))
  done

  if [ "$download_ok" -ne 1 ]; then
    log_error "Failed to download audio clips using available download tools"
    log_error "Fetch log preserved at: $fetch_log"
    rm -f "$archive_path" >/dev/null 2>&1 || true
    return 1
  fi

  if [ ! -s "$archive_path" ]; then
    log_error "Downloaded archive is missing or empty: $archive_path"
    log_error "Fetch log preserved at: $fetch_log"
    rm -f "$archive_path" >/dev/null 2>&1 || true
    return 1
  fi

  log_info "exec: tar -xzf \"$archive_path\" -C \"$clips_dir\""
  if ! tar -xzf "$archive_path" -C "$clips_dir" >>"$fetch_log" 2>&1; then
    log_error "Failed to extract audio clips archive into $clips_dir"
    log_error "Fetch log preserved at: $fetch_log"
    rm -f "$archive_path" >/dev/null 2>&1 || true
    return 1
  fi

  rm -f "$archive_path" >/dev/null 2>&1 || true

  # Normalize nested archive layout like AudioClips/AudioClips/*.wav -> AudioClips/*.wav
  if [ -d "$clips_dir/AudioClips" ]; then
    log_warn "Detected nested AudioClips directory after extraction.. normalizing layout"
    for nested_item in "$clips_dir/AudioClips"/*; do
      [ -e "$nested_item" ] || continue
      nested_name=$(basename "$nested_item")
      if [ ! -e "$clips_dir/$nested_name" ]; then
        if ! mv "$nested_item" "$clips_dir/"; then
          log_error "Failed to normalize extracted clips layout"
          log_error "Fetch log preserved at: $fetch_log"
          return 1
        fi
      fi
    done
    rmdir "$clips_dir/AudioClips" >/dev/null 2>&1 || true
  fi

  if ! audio_has_runnable_discovery_clips; then
    log_error "Extraction completed, but no runnable discovery clips were found in $clips_dir"
    log_error "Fetch log preserved at: $fetch_log"
    return 1
  fi

  : > "$marker_file" || true
  log_info "Audio clips download/extract validation completed"
  log_info "Fetch log saved at: $fetch_log"
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
        log_warn "Network unavailable, cannot fetch audio assets for $clip"
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
  audio_dump_out="$1"
  {
    echo "---- wpctl status ----"
    if command -v wpctl >/dev/null 2>&1; then
      audio_exec_with_timeout 2s wpctl status 2>&1 || echo "(wpctl status failed/timeout)"
    else
      echo "(wpctl not found)"
    fi
 
    echo "---- pactl list ----"
    if command -v pactl >/dev/null 2>&1; then
      audio_exec_with_timeout 3s pactl list 2>&1 || echo "(pactl list failed/timeout)"
    else
      echo "(pactl not found)"
    fi
  } >"$audio_dump_out" 2>/dev/null
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
    sleep 1; t=$((t + 1))
  done
  wait "$pid"; return $?
}

audio_restart_services_best_effort() {
  uid="$(id -u 2>/dev/null || echo 0)"
  rt="${XDG_RUNTIME_DIR:-/run/user/$uid}"
 
  # Ensure runtime dir exists (some LAVA/minimal images may not have it)
  if [ ! -d "$rt" ] && [ -n "$rt" ]; then
    mkdir -p "$rt" 2>/dev/null || true
    chmod 700 "$rt" 2>/dev/null || true
  fi
  [ -d "$rt" ] && export XDG_RUNTIME_DIR="$rt"
 
  # systemd user + system (best effort, bounded time)
  if command -v systemctl >/dev/null 2>&1; then
    # optional reloads (some images need this after overlay / unit changes)
    audio_exec_with_timeout 10s systemctl --user daemon-reload >/dev/null 2>&1 || true
    audio_exec_with_timeout 10s systemctl daemon-reload >/dev/null 2>&1 || true
 
    audio_exec_with_timeout 10s systemctl --user restart pipewire pipewire-pulse wireplumber pulseaudio >/dev/null 2>&1 || true
    audio_exec_with_timeout 10s systemctl restart pipewire pipewire-pulse wireplumber pulseaudio >/dev/null 2>&1 || true
  fi
 
  # If control-plane is OK already, stop here (accept PW or PA)
  if audio_pw_ctl_ok 2>/dev/null || audio_pa_ctl_ok 2>/dev/null; then
    return 0
  fi
 
  # hard reset (works without systemd/user session)
  if command -v pkill >/dev/null 2>&1; then
    pkill -x wireplumber >/dev/null 2>&1 || true
    pkill -x pipewire-pulse >/dev/null 2>&1 || true
    pkill -x pipewire >/dev/null 2>&1 || true
    pkill -x pulseaudio >/dev/null 2>&1 || true
  elif command -v killall >/dev/null 2>&1; then
    killall -q wireplumber pipewire-pulse pipewire pulseaudio 2>/dev/null || true
  fi
 
  sleep 1
 
  # stale sockets/locks
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    rm -f "$XDG_RUNTIME_DIR/pipewire-0" \
          "$XDG_RUNTIME_DIR/pipewire-0.lock" \
          "$XDG_RUNTIME_DIR/pulse/native" \
          "$XDG_RUNTIME_DIR/pulse/pid" \
          "$XDG_RUNTIME_DIR/pulse/cookie" \
          2>/dev/null || true
  fi
 
  # respawn (best effort, ShellCheck-clean)
  if command -v pipewire >/dev/null 2>&1; then
    pipewire >/dev/null 2>&1 &
  fi
 
  if command -v wireplumber >/dev/null 2>&1; then
    wireplumber >/dev/null 2>&1 &
  elif command -v pipewire-media-session >/dev/null 2>&1; then
    pipewire-media-session >/dev/null 2>&1 &
  fi
 
  if command -v pipewire-pulse >/dev/null 2>&1; then
    pipewire-pulse >/dev/null 2>&1 &
  fi
 
  if command -v pulseaudio >/dev/null 2>&1; then
    pulseaudio --start >/dev/null 2>&1 || true
  fi
 
  return 0
}

# Run PipeWire systemctl operations in the correct service scope.
#
# Debian:
#   Root orchestrator:
#       runuser -u debian -- systemctl --user ...
#
#   Temporary migration compatibility:
#       Existing runners that are still fully re-executed as the Debian Audio
#       user call systemctl --user directly.
#
# Yocto/qcom-distro/other:
#       systemctl ...
#
# Args:
#   All arguments are passed unchanged to systemctl.
#
# Returns:
#   The original systemctl exit status.
#   1 when the required user-session environment is unavailable.
audio_pipewire_systemctl() {
  if [ "$#" -eq 0 ]; then
    log_fail "audio_pipewire_systemctl requires systemctl arguments"
    return 1
  fi
 
  if ! command -v systemctl >/dev/null 2>&1; then
    log_fail "systemctl is unavailable"
    return 1
  fi
 
  ###########################################################################
  # Platform detection
  ###########################################################################
 
  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    aps_os_id="$(
      pkg_detect_os_id 2>/dev/null ||
        echo unknown
    )"
  else
    aps_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi
 
  [ -n "$aps_os_id" ] || aps_os_id="unknown"
 
  case "$aps_os_id" in
    debian)
      ;;
    *)
      # Preserve existing native/Yocto system-service behavior.
      systemctl "$@"
      return $?
      ;;
  esac
 
  ###########################################################################
  # Preferred Debian path: root orchestrator, command-level user execution
  ###########################################################################
 
  aps_current_uid="$(id -u 2>/dev/null || echo 1)"
 
  if [ "$aps_current_uid" -eq 0 ] 2>/dev/null; then
    if ! command -v audio_run_as_test_user >/dev/null 2>&1; then
      log_fail "Audio user-command helper is unavailable"
      return 1
    fi
 
    audio_run_as_test_user \
      --require-session \
      systemctl --user "$@"
 
    return $?
  fi
 
  ###########################################################################
  # Temporary compatibility for runners not migrated away from full re-exec
  ###########################################################################
 
  case "${AUDIO_TEST_USER_REEXEC:-0}:${AUDIO_TEST_COMMAND_USER_CONTEXT:-0}" in
    1:*|*:1)
      ;;
    *)
      log_fail "Debian PipeWire systemctl operation was invoked outside the prepared Audio user context"
      log_fail "Run audio_prepare_debian_audio_environment before invoking PipeWire service operations"
      return 1
      ;;
  esac
 
  aps_expected_user="${AUDIO_TEST_USER:-debian}"
  aps_current_user="$(id -un 2>/dev/null || echo unknown)"
 
  if [ "$aps_current_user" != "$aps_expected_user" ]; then
    log_fail "Unexpected Debian PipeWire service user: current=$aps_current_user expected=$aps_expected_user"
    return 1
  fi
 
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    log_fail "XDG_RUNTIME_DIR is not set for PipeWire user-service access"
    return 1
  fi
 
  if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    log_fail "PipeWire user runtime directory is unavailable: $XDG_RUNTIME_DIR"
    return 1
  fi
 
  if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
    log_fail "PipeWire user D-Bus socket is unavailable: $XDG_RUNTIME_DIR/bus"
    return 1
  fi
 
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    export DBUS_SESSION_BUS_ADDRESS
  fi
 
  systemctl --user "$@"
  return $?
}

# Prefer the invoking suite directory for test-owned scratch files. PWD covers
# helpers re-sourced in a child shell where SCRIPT_DIR is not exported, while
# AUDIO_RECORD_USER_CAPTURE_DIR provides the prepared Debian-user workspace.
audio_scratch_dir() {
  for asd_candidate in \
    "${SCRIPT_DIR:-}" \
    "${PWD:-}" \
    "${AUDIO_RECORD_USER_CAPTURE_DIR:-}" \
    "${LOGDIR:-}"
  do
    if [ -n "$asd_candidate" ] &&
       [ -d "$asd_candidate" ] &&
       [ -w "$asd_candidate" ]; then
      printf '%s\n' "$asd_candidate"
      return 0
    fi
  done

  return 1
}

# Restart PipeWire through systemd and wait for the service state to settle.
#
# Service scope:
#   AUDIO_SYSTEMCTL_USER_SCOPE=1
#       Use the current user's PipeWire service:
#       systemctl --user ...
#
#   AUDIO_SYSTEMCTL_USER_SCOPE unset or 0
#       Preserve the existing system-service behavior:
#       systemctl ...
#
# Args:
#   $1 - attempt label used in logs, for example 1/1
#
# Environment:
#   PIPEWIRE_SYSTEMCTL_TIMEOUT
#       Maximum number of seconds to wait; default: 180
#
# Returns:
#   0 - PipeWire reached active/running state
#   1 - restart failed, service failed, or timeout expired
audio_restart_pipewire_service() {
  aprs_label="${1:-1/1}"
  aprs_timeout="${PIPEWIRE_SYSTEMCTL_TIMEOUT:-180}"
  aprs_start_s="$(date +%s 2>/dev/null || echo 0)"
  aprs_next_log=10
  aprs_scope="system"
  aprs_exec_text="systemctl restart pipewire"
  aprs_output_dir="$(audio_scratch_dir 2>/dev/null || true)"
  if [ -z "$aprs_output_dir" ]; then
    log_fail "No writable Audio scratch directory is available"
    return 1
  fi
  aprs_output_file="$aprs_output_dir/audio-pipewire-systemctl.$$.log"
 
  case "${AUDIO_SYSTEMCTL_USER_SCOPE:-0}" in
    0)
      ;;
    1)
      aprs_scope="user"
      aprs_exec_text="systemctl --user restart pipewire"
      ;;
    *)
      log_fail "Invalid AUDIO_SYSTEMCTL_USER_SCOPE value: ${AUDIO_SYSTEMCTL_USER_SCOPE:-}"
      return 1
      ;;
  esac
 
  if ! command -v audio_pipewire_systemctl >/dev/null 2>&1; then
    log_fail "PipeWire systemctl scope helper is unavailable"
    return 1
  fi
 
  if ! command -v systemctl >/dev/null 2>&1; then
    log_fail "systemctl is unavailable, cannot restart PipeWire"
    return 1
  fi
 
  rm -f "$aprs_output_file"
  : >"$aprs_output_file" || {
    log_fail "Failed to create PipeWire systemctl output file: $aprs_output_file"
    return 1
  }
 
  log_info "exec: $aprs_exec_text (attempt $aprs_label)"
 
  audio_pipewire_systemctl restart pipewire \
    >"$aprs_output_file" 2>&1
  aprs_restart_rc=$?
 
  if [ -s "$aprs_output_file" ]; then
    while IFS= read -r aprs_line || [ -n "$aprs_line" ]; do
      if [ "$aprs_restart_rc" -eq 0 ]; then
        log_info "[systemctl:$aprs_scope] $aprs_line"
      else
        log_warn "[systemctl:$aprs_scope] $aprs_line"
      fi
    done <"$aprs_output_file"
  fi
 
  if [ "$aprs_restart_rc" -ne 0 ]; then
    log_warn "Failed to queue PipeWire restart job on attempt $aprs_label, scope=$aprs_scope, rc=$aprs_restart_rc"
 
    log_info "Current PipeWire service status, scope=$aprs_scope:"
 
    : >"$aprs_output_file"
 
    audio_pipewire_systemctl status \
      pipewire \
      --no-pager \
      --full \
      >"$aprs_output_file" 2>&1 || true
 
    if [ -s "$aprs_output_file" ]; then
      while IFS= read -r aprs_line || [ -n "$aprs_line" ]; do
        log_info "[systemctl-status:$aprs_scope] $aprs_line"
      done <"$aprs_output_file"
    else
      log_info "[systemctl-status:$aprs_scope] No status output available"
    fi
 
    if command -v journalctl >/dev/null 2>&1; then
      log_info "Recent PipeWire service journal, scope=$aprs_scope:"
 
      : >"$aprs_output_file"
 
      if [ "$aprs_scope" = "user" ]; then
        journalctl \
          --user \
          -u pipewire \
          -n 30 \
          --no-pager \
          >"$aprs_output_file" 2>&1 || true
      else
        journalctl \
          -u pipewire \
          -n 30 \
          --no-pager \
          >"$aprs_output_file" 2>&1 || true
      fi
 
      if [ -s "$aprs_output_file" ]; then
        while IFS= read -r aprs_line || [ -n "$aprs_line" ]; do
          log_info "[journalctl:$aprs_scope] $aprs_line"
        done <"$aprs_output_file"
      else
        log_info "[journalctl:$aprs_scope] No journal entries available"
      fi
    fi
 
    rm -f "$aprs_output_file"
    return 1
  fi
 
  rm -f "$aprs_output_file"
 
  while :; do
    aprs_now_s="$(date +%s 2>/dev/null || echo 0)"
    aprs_elapsed=$((aprs_now_s - aprs_start_s))
 
    if [ "$aprs_elapsed" -lt 0 ]; then
      aprs_elapsed=0
    fi
 
    aprs_active_state="$(
      audio_pipewire_systemctl show \
        -p ActiveState \
        --value \
        pipewire 2>/dev/null ||
        echo unknown
    )"
 
    aprs_sub_state="$(
      audio_pipewire_systemctl show \
        -p SubState \
        --value \
        pipewire 2>/dev/null ||
        echo unknown
    )"
 
    aprs_result_state="$(
      audio_pipewire_systemctl show \
        -p Result \
        --value \
        pipewire 2>/dev/null ||
        echo unknown
    )"
 
    aprs_job_state="$(
      audio_pipewire_systemctl show \
        -p Job \
        --value \
        pipewire 2>/dev/null ||
        echo unknown
    )"
 
    [ -n "$aprs_active_state" ] || aprs_active_state="unknown"
    [ -n "$aprs_sub_state" ] || aprs_sub_state="unknown"
    [ -n "$aprs_result_state" ] || aprs_result_state="unknown"
 
    case "$aprs_job_state" in
      ""|0)
        aprs_job_done=1
        ;;
      *)
        aprs_job_done=0
        ;;
    esac
 
    if [ "$aprs_active_state" = "active" ] &&
       [ "$aprs_sub_state" = "running" ] &&
       [ "$aprs_job_done" -eq 1 ]; then
      log_pass "PipeWire restart completed, scope=$aprs_scope attempt=$aprs_label"
      return 0
    fi
 
    if [ "$aprs_active_state" = "failed" ]; then
      log_warn "PipeWire entered failed state on attempt $aprs_label, scope=$aprs_scope state=$aprs_active_state/$aprs_sub_state result=$aprs_result_state"
      return 1
    fi
 
    case "$aprs_result_state" in
      failed|exit-code|signal|core-dump|timeout|watchdog|resources|protocol)
        log_warn "PipeWire restart job failed on attempt $aprs_label, scope=$aprs_scope state=$aprs_active_state/$aprs_sub_state result=$aprs_result_state"
        return 1
        ;;
    esac
 
    if [ "$aprs_elapsed" -ge "$aprs_timeout" ]; then
      log_warn "PipeWire restart attempt $aprs_label timed out after ${aprs_timeout}s, scope=$aprs_scope state=$aprs_active_state/$aprs_sub_state job=${aprs_job_state:-none}"
      return 1
    fi
 
    if [ "$aprs_elapsed" -ge "$aprs_next_log" ]; then
      log_info "Still waiting for PipeWire restart, scope=$aprs_scope state=$aprs_active_state/$aprs_sub_state job=${aprs_job_state:-none} elapsed=${aprs_elapsed}s/${aprs_timeout}s"
      aprs_next_log=$((aprs_next_log + 10))
    fi
 
    sleep 1
  done
}

# Function: setup_overlay_audio_environment
# Purpose: Validate overlay audio prerequisites without mutating system state.
# Returns: 0 on success, 1 on prerequisite failure
# Usage: Call early in audio test initialization, before backend detection.
#
# Distro is expected to provide correct dma_heap permissions and PipeWire
# readiness. This helper intentionally does not chmod /dev/dma_heap/system
# and does not restart PipeWire, so distro regressions are not hidden by tests.
setup_overlay_audio_environment() {
  PIPEWIRE_READY_TIMEOUT="${PIPEWIRE_READY_TIMEOUT:-120}"
 
  if ! command -v lsmod >/dev/null 2>&1; then
    log_fail "lsmod command not available, cannot detect overlay audio modules"
    return 1
  fi
 
  audio_modules="$(lsmod 2>/dev/null)" || {
    log_fail "lsmod failed, cannot detect overlay audio modules"
    return 1
  }
 
  if ! printf '%s\n' "$audio_modules" | awk '$1 ~ /^audioreach/ { found=1; exit } END { exit !found }'; then
    log_info "Base build detected, no audioreach modules, skipping overlay setup"
    return 0
  fi
 
  log_info "Overlay build detected, validating distro-provided audio prerequisites"
 
  if [ ! -e /dev/dma_heap/system ]; then
    log_fail "/dev/dma_heap/system is missing"
    log_fail "Distro should provide dma_heap system node for overlay audio"
    return 1
  fi
 
  if command -v stat >/dev/null 2>&1; then
    dma_heap_mode="$(stat -c '%a' /dev/dma_heap/system 2>/dev/null || echo unknown)"
    dma_heap_owner="$(stat -c '%U:%G' /dev/dma_heap/system 2>/dev/null || echo unknown)"
    log_info "/dev/dma_heap/system mode, ${dma_heap_mode}, owner, ${dma_heap_owner}"
  else
    log_info "stat command not available, skipping /dev/dma_heap/system mode and owner dump"
  fi
 
  if [ -r /dev/dma_heap/system ] && [ -w /dev/dma_heap/system ]; then
    log_pass "/dev/dma_heap/system is accessible"
  else
    log_fail "/dev/dma_heap/system is present but not accessible"
    log_fail "Distro should provide correct dma_heap permissions, test will not chmod it"
    return 1
  fi
 
  log_info "Waiting for PipeWire readiness, timeout ${PIPEWIRE_READY_TIMEOUT}s"
  if audio_wait_audio_ready "$PIPEWIRE_READY_TIMEOUT" pipewire; then
    log_pass "PipeWire is ready"
  else
    log_fail "PipeWire is not ready within ${PIPEWIRE_READY_TIMEOUT}s"
    log_fail "Distro should start PipeWire correctly, test will not restart it during overlay setup"
    return 1
  fi
 
  log_pass "Overlay audio prerequisites are ready"
  return 0
}

# ---------- PipeWire control helpers (bounded; never hang) ----------
pwctl_inspect_safe() {
  # Prints wpctl inspect <id> on stdout; returns nonzero on timeout/failure.
  id="$1"
  [ -n "$id" ] || return 1
  command -v wpctl >/dev/null 2>&1 || return 1
  audio_exec_with_timeout 2s wpctl inspect "$id" 2>/dev/null
}

# ---------- PipeWire: sinks (playback) ----------
# Return success only for a physical PipeWire audio sink. Dummy, null, monitor,
# and loopback sinks can accept streams without producing hardware audio.
pw_sink_is_real_audio() {
  psira_id="$1"

  [ -n "$psira_id" ] || return 1

  psira_inspect="$(pwctl_inspect_safe "$psira_id" 2>/dev/null || true)"
  [ -n "$psira_inspect" ] || return 1

  if ! printf '%s\n' "$psira_inspect" |
      grep -Eiq 'media[.]class[[:space:]]*=[[:space:]]*"Audio/Sink'; then
    return 1
  fi

  psira_label="$({
    printf '%s\n' "$psira_inspect" |
      grep -m1 -E 'node[.](description|name)[[:space:]]*=' |
      cut -d'"' -f2
  } 2>/dev/null)"

  if printf '%s\n' "$psira_label" |
      grep -Eiq '(^|[._ -])(null|dummy|monitor|loopback|freewheel)($|[._ -])'; then
    return 1
  fi

  return 0
}

# Prefer speaker or headphone sinks, then any physical audio sink. Do not use a
# PipeWire dummy sink as a successful speakers route.
pw_default_speakers() {
  st="$(pwctl_status_safe 2>/dev/null)" || {
    printf '%s\n' ""
    return 0
  }

  block="$(printf '%s\n' "$st" | sed -n '/Sinks:/,/Sources:/p')"
  preferred_ids="$(
    printf '%s\n' "$block" |
      grep -Ei 'speaker|headphone|line[._ -]*out|analog|hdmi' |
      sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p'
  )"
  all_ids="$(
    printf '%s\n' "$block" |
      sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p'
  )"
  checked_ids=""

  for id in $preferred_ids $all_ids; do
    case " $checked_ids " in
      *" $id "*)
        continue
        ;;
    esac

    checked_ids="$checked_ids $id"

    if pw_sink_is_real_audio "$id"; then
      printf '%s\n' "$id"
      return 0
    fi
  done

  printf '%s\n' ""
}

pw_default_null() {
  st="$(pwctl_status_safe 2>/dev/null)" || return 0
  printf '%s\n' "$st" \
    | sed -n '/Sinks:/,/Sources:/p' \
    | grep -i -E 'null|dummy|loopback|monitor' \
    | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' \
    | head -n1
}

pw_sink_name_safe() {
  id="$1"
  if [ -z "$id" ]; then
    echo ""
    return 1
  fi

  pw_inspect_text="$(pwctl_inspect_safe "$id" 2>/dev/null || true)"
  pw_sink_label="$(printf '%s\n' "$pw_inspect_text" | grep -m1 'node.description' | cut -d'"' -f2)"
  if [ -z "$pw_sink_label" ]; then
    pw_sink_label="$(printf '%s\n' "$pw_inspect_text" | grep -m1 'node.name' | cut -d'"' -f2)"
  fi

  if [ -z "$pw_sink_label" ]; then
    pw_status_text="$(pwctl_status_safe 2>/dev/null || true)"
    pw_sink_label="$(printf '%s\n' "$pw_status_text" \
      | sed -n '/Sinks:/,/Sources:/p' \
      | grep -E "^[^0-9]*${id}[.][[:space:]]" \
      | sed 's/^[^0-9]*[0-9][0-9]*[.][[:space:]][[:space:]]*//' \
      | sed 's/[[:space:]]*\[vol:.*$//' \
      | head -n 1)"
  fi

  printf '%s\n' "$pw_sink_label"
}

pw_sink_name() { pw_sink_name_safe "$@"; } # back-compat alias
pw_set_default_sink() {
  [ -n "$1" ] || return 1
  audio_exec_with_timeout 2s wpctl set-default "$1" >/dev/null 2>&1
}

# ---------- PipeWire: sources (record) ----------
# Return success only for a real PipeWire audio capture source. This prevents
# camera nodes listed under a generic Sources section from being selected.
pw_source_is_real_audio() {
  psira_id="$1"

  [ -n "$psira_id" ] || return 1

  psira_inspect="$(pwctl_inspect_safe "$psira_id" 2>/dev/null || true)"
  [ -n "$psira_inspect" ] || return 1

  if printf '%s\n' "$psira_inspect" |
      grep -Eiq 'media[.]class[[:space:]]*=[[:space:]]*"Video/Source'; then
    return 1
  fi

  if ! printf '%s\n' "$psira_inspect" |
      grep -Eiq 'media[.]class[[:space:]]*=[[:space:]]*"Audio/Source'; then
    return 1
  fi

  psira_label="$({
    printf '%s\n' "$psira_inspect" |
      grep -m1 -E 'node[.](description|name)[[:space:]]*=' |
      cut -d'"' -f2
  } 2>/dev/null)"

  if printf '%s\n' "$psira_label" |
      grep -Eiq '(^|[._ -])(null|dummy|monitor|loopback)($|[._ -])'; then
    return 1
  fi

  return 0
}

# Prefer microphone-labelled audio sources, then any real audio source. Never
# fall back to the first unclassified source because it may be a camera node.
pw_default_mic() {
  st="$(pwctl_status_safe 2>/dev/null)" || {
    printf '%s\n' ""
    return 0
  }

  blk="$(printf '%s\n' "$st" | sed -n '/Sources:/,/^$/p')"
  preferred_ids="$(
    printf '%s\n' "$blk" |
      grep -Ei 'mic|microphone|capture|audio.*input' |
      sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p'
  )"
  all_ids="$(
    printf '%s\n' "$blk" |
      sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p'
  )"
  checked_ids=""

  for id in $preferred_ids $all_ids; do
    case " $checked_ids " in
      *" $id "*)
        continue
        ;;
    esac

    checked_ids="$checked_ids $id"

    if pw_source_is_real_audio "$id"; then
      printf '%s\n' "$id"
      return 0
    fi
  done

  printf '%s\n' ""
}

pw_default_null_source() {
  st="$(pwctl_status_safe 2>/dev/null)" || { printf '%s\n' ""; return 0; }
 
  blk="$(printf '%s\n' "$st" | sed -n '/Sources:/,/^$/p')"
  id="$(printf '%s\n' "$blk" | grep -i 'null\|dummy' | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  printf '%s\n' "$id"
}

pw_source_label_safe() {
  id="$1"
  if [ -z "$id" ]; then
    echo ""
    return 1
  fi

  pw_inspect_text="$(pwctl_inspect_safe "$id" 2>/dev/null || true)"
  pw_source_label="$(printf '%s\n' "$pw_inspect_text" | grep -m1 'node.description' | cut -d'"' -f2)"
  if [ -z "$pw_source_label" ]; then
    pw_source_label="$(printf '%s\n' "$pw_inspect_text" | grep -m1 'node.name' | cut -d'"' -f2)"
  fi

  if [ -z "$pw_source_label" ]; then
    pw_status_text="$(pwctl_status_safe 2>/dev/null || true)"
    pw_source_label="$(printf '%s\n' "$pw_status_text" \
      | sed -n '/Sources:/,/Filters:/p' \
      | grep -E "^[^0-9]*${id}[.][[:space:]]" \
      | sed 's/^[^0-9]*[0-9][0-9]*[.][[:space:]][[:space:]]*//' \
      | sed 's/[[:space:]]*\[vol:.*$//' \
      | head -n 1)"
  fi

  printf '%s\n' "$pw_source_label"
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
    # Count Input/Output streams in RUNNING state
    pwctl_status_safe 2>/dev/null | grep -Eq 'RUNNING' && { echo 1; return; }
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
    uid="$(stat -c %u "$d" 2>/dev/null || stat -f %u "$d" 2>/dev/null || echo)"
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
           || pactl list short sink-inputs 2>/dev/null | grep -q '^[0-9][0-9]*' \
           || pactl list short source-outputs 2>/dev/null | grep -q '^[0-9][0-9]*' ; then
          echo 1; return
        fi
      else
        if [ -n "$cookie" ]; then
          PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactl info >/dev/null 2>&1 || { IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
            continue; }
          if PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactl list sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*State:[[:space:]]*RUNNING' \
             || PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactl list short sink-inputs 2>/dev/null | grep -q '^[0-9][0-9]*' \
             || PULSE_SERVER="unix:$sock" PULSE_COOKIE="$cookie" pactl list short source-outputs 2>/dev/null | grep -q '^[0-9][0-9]*' ; then
            echo 1; return
          fi
        else
          PULSE_SERVER="unix:$sock" pactl info >/dev/null 2>&1 || { IFS='|' read -r sock cookie rest <<EOF
$rest
EOF
            continue; }
          if PULSE_SERVER="unix:$sock" pactl list sinks 2>/dev/null | grep -qi -m1 '^[[:space:]]*State:[[:space:]]*RUNNING' \
             || PULSE_SERVER="unix:$sock" pactl list short sink-inputs 2>/dev/null | grep -q '^[0-9][0-9]*' \
             || PULSE_SERVER="unix:$sock" pactl list short source-outputs 2>/dev/null | grep -q '^[0-9][0-9]*' ; then
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
}

# Run a command with a bounded timeout.
#
# Return:
# child status - command exited before the timeout
# 124 - timeout expired and the child was terminated
audio_exec_with_timeout() {
  aewt_dur="${1:-0}"
  shift

  case "$aewt_dur" in
    ""|0)
      aewt_dur_norm=0
      ;;
    *s)
      aewt_dur_norm=${aewt_dur%s}
      ;;
    *)
      aewt_dur_norm=$aewt_dur
      ;;
  esac

  case "$aewt_dur_norm" in
    ""|*[!0-9]*)
      aewt_dur_norm=0
      ;;
  esac

  if [ "$aewt_dur_norm" -le 0 ] 2>/dev/null; then
    "$@"
    return $?
  fi

  "$@" &
  aewt_pid=$!

  aewt_start="$(
    date +%s 2>/dev/null ||
      echo 0
  )"

  aewt_deadline=$((aewt_start + aewt_dur_norm))
  aewt_timed_out=0

  while kill -0 "$aewt_pid" 2>/dev/null; do
    aewt_now="$(
      date +%s 2>/dev/null ||
        echo 0
    )"

    if [ "$aewt_now" -ge "$aewt_deadline" ] 2>/dev/null; then
      aewt_timed_out=1
      break
    fi

    sleep 1
  done

  if [ "$aewt_timed_out" -eq 0 ]; then
    wait "$aewt_pid"
    return $?
  fi

  kill -TERM "$aewt_pid" 2>/dev/null || true

  aewt_grace=0

  while kill -0 "$aewt_pid" 2>/dev/null &&
        [ "$aewt_grace" -lt 3 ]; do
    sleep 1
    aewt_grace=$((aewt_grace + 1))
  done

  if kill -0 "$aewt_pid" 2>/dev/null; then
    kill -KILL "$aewt_pid" 2>/dev/null || true
  fi

  wait "$aewt_pid" 2>/dev/null || true

  # The timeout itself is the authoritative status. Do not return pw-record's
  # implementation-specific SIGTERM status, which can be 1 despite a valid WAV.
  return 124
}

# Wait until the requested audio backend becomes usable.
# Uses real elapsed time, not loop count, so slow ctl probes do not skew timeout logs.
audio_wait_audio_ready() {
  max_s="${1:-${PIPEWIRE_READY_TIMEOUT:-120}}"
  backend_name="${2:-auto}"
  start_s="$(date +%s 2>/dev/null || echo 0)"
  next_log=10

  while :; do
    now_s="$(date +%s 2>/dev/null || echo 0)"
    elapsed=$((now_s - start_s))
    if [ "$elapsed" -lt 0 ]; then
      elapsed=0
    fi

    if [ "$elapsed" -ge "$max_s" ]; then
      break
    fi

    case "$backend_name" in
      pipewire)
        if audio_backend_ready pipewire; then
          return 0
        fi
        ;;
      pulseaudio)
        if audio_backend_ready pulseaudio; then
          return 0
        fi
        ;;
      auto|"")
        if audio_backend_ready pipewire; then
          return 0
        fi
        if audio_backend_ready pulseaudio; then
          return 0
        fi
        if [ -d /dev/snd ] || [ -e /proc/asound/cards ]; then
          return 0
        fi
        ;;
      *)
        return 1
        ;;
    esac

    if [ "$elapsed" -ge "$next_log" ]; then
      log_info "Still waiting for ${backend_name:-audio}... (${elapsed}s/${max_s}s)"
      next_log=$((next_log + 10))
    fi

    sleep 1
  done

  return 1
}

# --- bounded wpctl helpers (never hang) ---
pwctl_status_safe() {
  # Prints wpctl status to stdout on success, returns nonzero on failure/timeout.
  out="$(audio_exec_with_timeout 2s wpctl status 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out"
}
 
audio_pw_ctl_ok() {
  pwctl_status_safe >/dev/null 2>&1
}

audio_pa_ctl_ok() {
  command -v pactl >/dev/null 2>&1 || return 1
  audio_exec_with_timeout 2s pactl info >/dev/null 2>&1
}
# If you have an existing pw_set_default_source(), replace it with this bounded version.
pw_set_default_source() {
  id="$1"
  [ -n "$id" ] || return 1
  audio_exec_with_timeout 2s wpctl set-default "$id" >/dev/null 2>&1
}

# --------------------------------------------------------------------
# File size helper (portable across different stat implementations)
# --------------------------------------------------------------------

# Get file size in bytes using portable method
# Input: file path
# Output: file size in bytes to stdout
# Returns: 0=success, 1=file not found or not readable
file_size_bytes() {
  file="$1"
  [ -f "$file" ] || return 1
  [ -r "$file" ] || return 1
  wc -c < "$file" 2>/dev/null
}

# Extract clip duration from filename
# Input: clip filename (e.g., "play_48KHz_30s_16b_2ch.wav")
# Output: duration in seconds (e.g., "30") to stdout
# Returns: 0=success, 1=unable to parse duration
extract_clip_duration() {
  filename="$1"
  
  # Extract duration field from pattern: _RATE_DURATIONs_BITS_CHANNELS.wav
  # Use sed to match the exact 4-field structure
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
  pcs="$(arecord -L 2>/dev/null | sed -n 's/^[[:space:]]*\([[:alnum:]_][[:alnum:]_]*\)[[:space:]]*$/\1/p')"
  for pcm in pipewire pulse default; do
    if printf '%s\n' "$pcs" | grep -m1 -x "$pcm" >/dev/null 2>&1; then
      printf '%s\n' "$pcm"
      return 0
    fi
  done
  return 1
}


# Check if all required audio clips are available locally
# Usage: audio_check_clips_available "$FORMATS" "$DURATIONS"
# Returns: 0 if all clips present and non-empty, 1 if any clip missing or empty
audio_check_clips_available() {
  formats="$1"
  durations="$2"

  if [ -z "$formats" ] || [ -z "$durations" ]; then
    return 1
  fi

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

# ---------- New Clip Discovery Functions (for 20-clip enhancement) ----------

# ---------- Config Mapping ----------
# Provides stable, deterministic mapping from playback_config1-playback_config10 to specific
# audio format test cases. This ensures reproducible test coverage across
# different systems and releases.
#
# Playback config numbers map to specific sample rate, bit depth, and channel combinations:
#   playback_config1  → 8 KHz, 8-bit, 1ch
#   playback_config2  → 16 KHz, 8-bit, 6ch
#   playback_config3  → 16 KHz, 16-bit, 2ch
#   playback_config4  → 22.05 KHz, 8-bit, 1ch
#   playback_config5  → 24 KHz, 24-bit, 6ch
#   playback_config6  → 24 KHz, 32-bit, 1ch
#   playback_config7  → 32 KHz, 8-bit, 8ch
#   playback_config8  → 32 KHz, 16-bit, 2ch
#   playback_config9  → 44.1 KHz, 16-bit, 1ch
#   playback_config10 → 48 KHz, 8-bit, 2ch

# Translate playback_config name to test case name
# Returns descriptive test case name for given config
map_config_to_testcase() {
  config="$1"
  
  # Extract config number if using playback_config format
  config_num=""
  case "$config" in
    playback_config*)
      # Handle both formats: playback_config1 and playback_config01
      config_num="$(printf '%s' "$config" | sed -n 's/^playback_config0*\([0-9][0-9]*\)$/\1/p')"
      # Validate extraction succeeded
      if [ -z "$config_num" ]; then
        # Invalid format, return error
        return 1
      fi
      ;;
    Config*)
      # For backward compatibility
      config_num="$(printf '%s' "$config" | sed -n 's/^Config0*\([0-9][0-9]*\)$/\1/p')"
      # Validate extraction succeeded
      if [ -z "$config_num" ]; then
        # Invalid format, return error
        return 1
      fi
      ;;
    [0-9]*)
      # Direct number input
      config_num="$config"
      ;;
  esac
  
  # Map config number to test case name
  case "$config_num" in
    1)  printf 'play_8KHz_8b_1ch\n' ;;
    2)  printf 'play_16KHz_8b_6ch\n' ;;
    3)  printf 'play_16KHz_16b_2ch\n' ;;
    4)  printf 'play_22.05KHz_8b_1ch\n' ;;
    5)  printf 'play_24KHz_24b_6ch\n' ;;
    6)  printf 'play_24KHz_32b_1ch\n' ;;
    7)  printf 'play_32KHz_8b_8ch\n' ;;
    8)  printf 'play_32KHz_16b_2ch\n' ;;
    9)  printf 'play_44.1KHz_16b_1ch\n' ;;
    10) printf 'play_48KHz_8b_2ch\n' ;;
    *) return 1 ;;
  esac
  return 0
}

# Discover all audio clip files in the clips directory
# Outputs newline-separated list of clip filenames (basenames only) to stdout
# Logs diagnostic messages to stderr
# Exit codes: 0=success, 1=directory not found or no clips
discover_audio_clips() {
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"
  
  # Check directory exists
  if [ ! -d "$clips_dir" ]; then
    log_error "Clips directory not found: $clips_dir" >&2
    return 1
  fi
  
  # Find .wav files (only in top level, not recursive)
  clips="$(find "$clips_dir" -maxdepth 1 -name "*.wav" -type f 2>/dev/null | sort)"
  
  # Check if any clips found
  if [ -z "$clips" ]; then
    log_error "No .wav files found in $clips_dir" >&2
    return 1
  fi
  
  # Output basenames only to stdout
  for clip in $clips; do
    basename "$clip"
  done
  return 0
}

# Parse clip filename to extract metadata
# Input: yesterday_48KHz_30s_16b_2ch.wav
# Output: rate=48KHz bits=16b channels=2ch (space-separated key=value pairs)
# Returns: 0=success, 1=parse failure
parse_clip_metadata() {
  filename="$1"
  
  # Extract rate, bits, and channels in one sed call
  # Pattern matches exact 4-field structure from end: _RATE_DURATIONs_BITS_CHANNELS.wav
  # Anchored to .wav extension to ensure we're matching the correct fields
  metadata="$(printf '%s' "$filename" | sed -n 's/.*_\([0-9.][0-9.]*KHz\)_\([0-9][0-9]*s\)_\([0-9][0-9]*b\)_\([0-9][0-9]*ch\)\.wav$/\1 \3 \4/p')"
  
  # Validate extraction succeeded
  if [ -z "$metadata" ]; then
    log_warn "Cannot parse metadata from: $filename (skipping)"
    return 1
  fi
  
  # Split extracted fields (rate bits channels)
  # shellcheck disable=SC2086 # Intentional field splitting of generated key=value triplet.
  set -- $metadata
  rate="$1"; bits="$2"; channels="$3"
  
  # Validate all components present
  if [ -z "$rate" ] || [ -z "$bits" ] || [ -z "$channels" ]; then
    log_warn "Cannot parse metadata from: $filename (skipping)"
    return 1
  fi
  
  printf 'rate=%s bits=%s channels=%s\n' "$rate" "$bits" "$channels"
  return 0
}

# Generate test case name from clip filename
# Input: yesterday_48KHz_30s_16b_2ch.wav
# Output: play_48KHz_16b_2ch
# Returns: 0=success, 1=parse failure
generate_clip_testcase_name() {
  filename="$1"
  
  # Parse metadata (returns "rate=48KHz bits=16b channels=2ch")
  metadata="$(parse_clip_metadata "$filename")" || return 1
  
  # Extract values using positional parameters and prefix stripping
  # shellcheck disable=SC2086 # Intentional field splitting of generated key=value triplet.
  set -- $metadata
  rate="${1#rate=}"
  bits="${2#bits=}"
  channels="${3#channels=}"
  
  # Generate test case name
  printf 'play_%s_%s_%s\n' "$rate" "$bits" "$channels"
  return 0
}

# Resolve clip file path from test case name or clip name
# Input: play_48KHz_16b_2ch OR 48KHz_16b_2ch OR yesterday_48KHz_30s_16b_2ch.wav
# Output: AudioClips/yesterday_48KHz_30s_16b_2ch.wav
# Returns: 0=success, 1=not found
resolve_clip_by_name() {
  name="$1"
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"
  
  # If name already looks like a filename, try direct path
  if printf '%s' "$name" | grep -F -q -- '.wav'; then
    clip_path="$clips_dir/$name"
    if [ -f "$clip_path" ]; then
      printf '%s\n' "$clip_path"
      return 0
    fi
  fi
  
  # Strip "play_" prefix if present
  search_name="$(printf '%s' "$name" | sed 's/^play_//')"
  
  # Search for matching clip using literal string matching
  for clip_file in "$clips_dir"/*.wav; do
    [ -f "$clip_file" ] || continue
    clip_basename="$(basename "$clip_file")"
    
    # Check if clip contains the search pattern (literal string match)
    if printf '%s' "$clip_basename" | grep -F -q -- "$search_name"; then
      printf '%s\n' "$clip_file"
      return 0
    fi
  done
  
  return 1
}

# Validate clip name against available clips
# Input: requested_name (e.g., play_48KHz_16b_2ch OR playback_config1), available_clips (list)
# Output: matching clip filename to stdout
# Logs error messages to stderr
# Returns: 0=found, 1=not found
validate_clip_name() {
  requested_name="$1"
  available_clips="$2"
  
  # Check if requested_name is a generic config name (playback_config1, Config1, etc.)
  # Support both formats for backward compatibility
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
    # Generic config name - map to clip by index (1-based)
    # Count total clips first using POSIX-compliant approach
    # shellcheck disable=SC2086 # Intentional field splitting of generated key=value triplet.
    set -- $available_clips
    idx=$#
    
    # Validate config number is positive and within range
    if [ "$config_num" -le 0 ] 2>/dev/null || [ "$config_num" -gt "$idx" ] 2>/dev/null; then
      log_error "Invalid config number: $requested_name. Available range: Config1 to Config$idx. Please check again." >&2
      return 1
    fi
    
    # Get clip by index (1-based) using POSIX-compliant approach
    current_idx=0
    for clip in $available_clips; do
      current_idx=$((current_idx + 1))
      if [ "$current_idx" -eq "$config_num" ]; then
        printf '%s\n' "$clip"
        return 0
      fi
    done
    
    # This shouldn't happen, but just in case
    log_error "Invalid config number: $requested_name. Available range: Config1 to Config$idx. Please check again." >&2
    return 1
  fi
  
  # Try exact match for specific clip names (play_48KHz_16b_2ch format)
  for clip in $available_clips; do
    test_name="$(generate_clip_testcase_name "$clip" 2>/dev/null)" || continue
    if [ "$test_name" = "$requested_name" ]; then
      printf '%s\n' "$clip"
      return 0
    fi
  done
  
  # No match found - count available clips for helpful message using POSIX-compliant approach
  # shellcheck disable=SC2086 # Intentional field splitting of space-separated clip list.
  set -- $available_clips
  idx=$#
  
  # No match found - provide helpful error message with range
  log_error "Wrong clip name: '$requested_name'. Available range: playback_config1 to playback_config$idx. Please check again." >&2
  return 1
}

# Input: filter (space-separated patterns), available_clips (list)
# Output: filtered clip list
# Returns: 0=success, 1=no matches
apply_clip_filter() {
  filter="$1"
  available_clips="$2"
  
  # If no filter, return all clips
  if [ -z "$filter" ]; then
    printf '%s\n' "$available_clips"
    return 0
  fi
  
  # Apply filter
  filtered=""
  for clip in $available_clips; do
    for pattern in $filter; do
      # Match against filename or test case name
      test_name="$(generate_clip_testcase_name "$clip" 2>/dev/null)" || continue
      if printf '%s %s' "$clip" "$test_name" | grep -F -q -- "$pattern"; then
        filtered="$filtered $clip"
        break
      fi
    done
  done
  
  # Remove leading space
  filtered="$(printf '%s' "$filtered" | sed 's/^ //')"
  
  # Check if filter matched anything
  if [ -z "$filtered" ]; then
    log_error "Filter '$filter' matched no clips" >&2
    log_info "Available clips:" >&2
    for clip in $available_clips; do
      log_info "  - $(basename "$clip")" >&2
    done
    return 1
  fi
  
  printf '%s\n' "$filtered"
  return 0
}

# Validate clip file is accessible and non-empty
# Input: clip_path
# Returns: 0=valid, 1=invalid
validate_clip_file() {
  clip_path="$1"
  
  # Check exists
  if [ ! -f "$clip_path" ]; then
    log_error "Clip file not found: $clip_path"
    return 1
  fi
  
  # Check readable
  if [ ! -r "$clip_path" ]; then
    log_error "Clip file not readable: $clip_path"
    return 1
  fi
  
  # Check not empty using portable file size helper
  size="$(file_size_bytes "$clip_path")"
  if [ -z "$size" ] || [ "$size" -le 0 ] 2>/dev/null; then
    log_error "Clip file is empty: $clip_path"
    return 1
  fi
  
  return 0
}

# Discover and filter clips based on user input
# Input: clip_names (explicit list), clip_filter (pattern filter)
# Output: final list of clip filenames to test (to stdout)
# Logs error messages to stderr
# Returns: 0=success, 1=no valid clips
discover_and_filter_clips() {
  clip_names="$1"
  clip_filter="$2"
  
  # Discover all available clips (logs go to stderr automatically)
  available_clips="$(discover_audio_clips)" || {
    log_error "Failed to discover audio clips" >&2
    return 1
  }
  
  # If explicit clip names provided, validate and use them
  if [ -n "$clip_names" ]; then
    validated=""
    failed_names=""
    
    for name in $clip_names; do
      # Validate clip name - let error messages display to stderr
      if clip="$(validate_clip_name "$name" "$available_clips")"; then
        validated="$validated $clip"
      else
        failed_names="$failed_names $name"
      fi
    done
    
    validated="$(printf '%s' "$validated" | sed 's/^ //')"
    failed_names="$(printf '%s' "$failed_names" | sed 's/^ //')"
    
    if [ -z "$validated" ]; then
      # Don't repeat the error - validate_clip_name already showed it
      return 1
    fi
    
    # Warn about any failed names (only if there are some valid ones)
    if [ -n "$failed_names" ]; then
      log_warn "Invalid clip/config names skipped: $failed_names" >&2
    fi
    
    printf '%s\n' "$validated"
    return 0
  fi
  
  # Apply filter if provided
  if [ -n "$clip_filter" ]; then
    filtered="$(apply_clip_filter "$clip_filter" "$available_clips" 2>/dev/null)" || {
      log_error "Filter did not match any clips" >&2
      return 1
    }
    printf '%s\n' "$filtered"
    return 0
  fi
  
  # No filter - return all clips
  printf '%s\n' "$available_clips"
  return 0
}

# ---------- Record Configuration Functions (10-config enhancement) ----------

# Discover all available record configurations
# Returns: space-separated list of record_config1 through record_config10
# Exit codes: 0=success (always succeeds - configs are predefined)
discover_record_configs() {
  printf '%s\n' "record_config1 record_config2 record_config3 record_config4 record_config5 record_config6 record_config7 record_config8 record_config9 record_config10"
  return 0
}

# Get recording parameters for a specific config
# Input: config_name (e.g., record_config1, record_config01, record_8KHz_1ch)
# Output: "rate channels" (e.g., "8000 1")
# Returns: 0=success, 1=invalid config
get_record_config_params() {
  config_name="$1"
  
  # Normalize config name to handle both formats (record_config1 and record_config01)
  normalized_name="$config_name"
  case "$config_name" in
    record_config0*)
      # Extract number and remove leading zero for internal processing
      config_num="$(printf '%s' "$config_name" | sed -n 's/^record_config0*\([0-9][0-9]*\)$/\1/p')"
      # Only normalize if extraction succeeded
      if [ -n "$config_num" ]; then
        normalized_name="record_config$config_num"
      fi
      # If config_num is empty, normalized_name stays as original config_name
      ;;
  esac
  
  case "$normalized_name" in
    record_config1|record_8KHz_1ch)      printf '%s\n' "8000 1" ;;
    record_config2|record_16KHz_1ch)     printf '%s\n' "16000 1" ;;
    record_config3|record_16KHz_2ch)     printf '%s\n' "16000 2" ;;
    record_config4|record_24KHz_1ch)     printf '%s\n' "24000 1" ;;
    record_config5|record_32KHz_2ch)     printf '%s\n' "32000 2" ;;
    record_config6|record_44.1KHz_2ch)   printf '%s\n' "44100 2" ;;
    record_config7|record_48KHz_2ch)     printf '%s\n' "48000 2" ;;
    record_config8|record_48KHz_6ch)     printf '%s\n' "48000 6" ;;
    record_config9|record_96KHz_2ch)     printf '%s\n' "96000 2" ;;
    record_config10|record_96KHz_6ch)    printf '%s\n' "96000 6" ;;
    *) return 1 ;;
  esac
  return 0
}

# Generate descriptive test case name from config name
# Input: record_config1 or record_config01
# Output: record_8KHz_1ch
# Returns: 0=success, 1=invalid config
generate_record_testcase_name() {
  config_name="$1"
  
  # Normalize config name to handle both formats (record_config1 and record_config01)
  normalized_name="$config_name"
  case "$config_name" in
    record_config0*)
      # Extract number and remove leading zero for internal processing
      config_num="$(printf '%s' "$config_name" | sed -n 's/^record_config0*\([0-9][0-9]*\)$/\1/p')"
      normalized_name="record_config$config_num"
      ;;
  esac
  
  case "$normalized_name" in
    record_config1)  printf '%s\n' "record_8KHz_1ch" ;;
    record_config2)  printf '%s\n' "record_16KHz_1ch" ;;
    record_config3)  printf '%s\n' "record_16KHz_2ch" ;;
    record_config4)  printf '%s\n' "record_24KHz_1ch" ;;
    record_config5)  printf '%s\n' "record_32KHz_2ch" ;;
    record_config6)  printf '%s\n' "record_44.1KHz_2ch" ;;
    record_config7)  printf '%s\n' "record_48KHz_2ch" ;;
    record_config8)  printf '%s\n' "record_48KHz_6ch" ;;
    record_config9)  printf '%s\n' "record_96KHz_2ch" ;;
    record_config10) printf '%s\n' "record_96KHz_6ch" ;;
    *) printf '%s\n' "$config_name" ;;  # Already descriptive or unknown
  esac
  return 0
}

# Generate output filename with parameters
# Input: testcase_base (e.g., "record_short"), rate (e.g., "48000"), channels (e.g., "2")
# Output: record_short_48KHz_2ch.wav
# Returns: 0=success
generate_record_filename() {
  testcase_base="$1"
  rate="$2"
  channels="$3"
  
  # Convert rate to KHz format
  rate_khz="$rate"
  case "$rate" in
    8000)  rate_khz="8KHz" ;;
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
    *) rate_khz="${rate}Hz" ;;  # Fallback for unknown rates
  esac
  
  printf '%s_%s_%sch.wav\n' "$testcase_base" "$rate_khz" "$channels"
  return 0
}

# Validate record config name
# Input: requested_name (e.g., record_config1, record_8KHz_1ch)
# Returns: 0=valid, 1=invalid (with helpful error message)
validate_record_config_name() {
  requested_name="$1"
  
  # Validate by checking if get_record_config_params() supports it
  # This eliminates redundant pattern matching that could be misleading
  if get_record_config_params "$requested_name" >/dev/null 2>&1; then
    return 0
  fi
  
  log_error "Invalid record config name: $requested_name" >&2
  log_error "Available configs: record_config1-record_config10, record_8KHz_1ch, record_16KHz_1ch, record_16KHz_2ch, record_24KHz_1ch, record_32KHz_2ch, record_44.1KHz_2ch, record_48KHz_2ch, record_48KHz_6ch, record_96KHz_2ch, record_96KHz_6ch" >&2
  return 1
}

# Apply filter to record configs
# Input: filter (space-separated patterns), available_configs (list)
# Output: filtered config list
# Returns: 0=success, 1=no matches
apply_record_config_filter() {
  filter="$1"
  available_configs="$2"
  
  # If no filter, return all configs
  if [ -z "$filter" ]; then
    printf '%s\n' "$available_configs"
    return 0
  fi
  
  # Apply filter
  filtered=""
  for config in $available_configs; do
    # Generate descriptive name for matching
    desc_name="$(generate_record_testcase_name "$config" 2>/dev/null)" || continue
    
    for pattern in $filter; do
      # Match against config name or descriptive name
      if printf '%s %s' "$config" "$desc_name" | grep -F -q -- "$pattern"; then
        filtered="$filtered $config"
        break
      fi
    done
  done
  
  # Remove leading space
  filtered="$(printf '%s' "$filtered" | sed 's/^ //')"
  
  # Check if filter matched anything
  if [ -z "$filtered" ]; then
    log_error "Filter '$filter' matched no record configs" >&2
    log_info "Available configs: record_config1 to record_config10" >&2
    return 1
  fi
  
  printf '%s\n' "$filtered"
  return 0
}

# Discover and filter record configs based on user input
# Input: config_names (explicit list), config_filter (pattern filter)
# Output: final list of config names to test (to stdout)
# Logs error messages to stderr
# Returns: 0=success, 1=no valid configs
discover_and_filter_record_configs() {
  config_names="$1"
  config_filter="$2"
  
  # Get all available configs
  available_configs="$(discover_record_configs)"
  
  # If explicit config names provided, validate and use them
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
    
    if [ -z "$validated" ]; then
      return 1
    fi
    
    # Warn about any failed names (only if there are some valid ones)
    if [ -n "$failed_names" ]; then
      log_warn "Invalid record config names skipped: $failed_names" >&2
    fi
    
    printf '%s\n' "$validated"
    return 0
  fi
  
  # Apply filter if provided
  if [ -n "$config_filter" ]; then
    filtered="$(apply_record_config_filter "$config_filter" "$available_configs")" || return 1
    printf '%s\n' "$filtered"
    return 0
  fi
  
  # No filter - return all configs
  printf '%s\n' "$available_configs"
  return 0
}

# Generic backend readiness wrapper used by run.sh.
# Reuses existing daemon/control-plane helpers instead of duplicating probe logic.
audio_backend_ready() {
  case "$1" in
    pipewire)
      if check_audio_daemon pipewire >/dev/null 2>&1; then
        if audio_pw_ctl_ok >/dev/null 2>&1; then
          return 0
        fi
      fi
      return 1
      ;;
    pulseaudio)
      if check_audio_daemon pulseaudio >/dev/null 2>&1; then
        if audio_pa_ctl_ok >/dev/null 2>&1; then
          return 0
        fi
      fi
      return 1
      ;;
    alsa)
      if command -v arecord >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# Track background daemon PIDs started by this script.
# These PIDs are later cleaned up on exit.
audio_add_started_pid() {
  if [ -n "$1" ]; then
    if [ -n "${AUDIO_STARTED_PIDS:-}" ]; then
      AUDIO_STARTED_PIDS="$AUDIO_STARTED_PIDS $1"
    else
      AUDIO_STARTED_PIDS="$1"
    fi
    export AUDIO_STARTED_PIDS
  fi
}

# Stop any audio daemons started by manual bootstrap.
# Also removes the temporary runtime directory if this script created it.
audio_cleanup_started_daemons() {
  for pid in ${AUDIO_STARTED_PIDS:-}; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done

  if [ "${AUDIO_CREATED_RUNTIME_DIR:-0}" -eq 1 ] 2>/dev/null; then
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
      rmdir "$XDG_RUNTIME_DIR" >/dev/null 2>&1 || true
    fi
  fi
}

# Ensure XDG_RUNTIME_DIR is available for PipeWire/PulseAudio in minimal userspace.
# Reuses an existing writable runtime dir when possible, otherwise creates one under /tmp.
audio_ensure_runtime_dir() {
  uid_now="$(id -u 2>/dev/null || echo 0)"

  if [ -n "${AUDIO_RUNTIME_DIR:-}" ]; then
    run_dir="$AUDIO_RUNTIME_DIR"
  elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
    return 0
  elif [ -d "/run/user/$uid_now" ] && [ -w "/run/user/$uid_now" ]; then
    run_dir="/run/user/$uid_now"
  else
    run_dir="/tmp/audio-runtime-$uid_now"
    AUDIO_CREATED_RUNTIME_DIR=1
    export AUDIO_CREATED_RUNTIME_DIR
  fi

  if [ ! -d "$run_dir" ]; then
    mkdir -p "$run_dir" || return 1
  fi

  chmod 700 "$run_dir" >/dev/null 2>&1 || true
  XDG_RUNTIME_DIR="$run_dir"
  export XDG_RUNTIME_DIR
  return 0
}

# Start a background process and redirect its output to a log file.
# Returns the spawned PID so the caller can track and clean it up later.
audio_start_bg_logged() {
  bg_log="$1"
  shift
  "$@" >>"$bg_log" 2>&1 &
  echo "$!"
}

# Manually start PipeWire and its session manager in minimal ramdisk userspace.
# Reuses existing daemon/control-plane helpers to validate readiness.
audio_manual_start_pipewire() {
  pipewire_log="$LOGDIR/pipewire-bootstrap.log"
  session_log="$LOGDIR/pipewire-session.log"
  pulse_log="$LOGDIR/pipewire-pulse.log"

  if check_audio_daemon pipewire >/dev/null 2>&1; then
    if audio_pw_ctl_ok >/dev/null 2>&1; then
      return 0
    fi
  fi

  if ! have_cmd pipewire; then
    return 1
  fi

  if ! audio_ensure_runtime_dir; then
    log_error "Failed to prepare XDG_RUNTIME_DIR for PipeWire"
    return 1
  fi

  export HOME="${HOME:-/tmp}"

  pw_pid="$(audio_start_bg_logged "$pipewire_log" pipewire)"
  audio_add_started_pid "$pw_pid"
  sleep 2

  if have_cmd pipewire-media-session; then
    sm_pid="$(audio_start_bg_logged "$session_log" pipewire-media-session)"
    audio_add_started_pid "$sm_pid"
  elif have_cmd wireplumber; then
    sm_pid="$(audio_start_bg_logged "$session_log" wireplumber)"
    audio_add_started_pid "$sm_pid"
  else
    log_warn "No PipeWire session manager found (wireplumber / pipewire-media-session)"
  fi

  if have_cmd pipewire-pulse; then
    pp_pid="$(audio_start_bg_logged "$pulse_log" pipewire-pulse)"
    audio_add_started_pid "$pp_pid"
  fi

  AUDIO_BACKEND="pipewire"
  export AUDIO_BACKEND

  audio_wait_audio_ready 20 >/dev/null 2>&1 || true

  if check_audio_daemon pipewire >/dev/null 2>&1; then
    if audio_pw_ctl_ok >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

# Manually start PulseAudio in minimal ramdisk userspace.
# Reuses existing daemon/control-plane helpers to validate readiness.
audio_manual_start_pulseaudio() {
  pulseaudio_log="$LOGDIR/pulseaudio-bootstrap.log"
  uid_now="$(id -u 2>/dev/null || echo 0)"

  if check_audio_daemon pulseaudio >/dev/null 2>&1; then
    if audio_pa_ctl_ok >/dev/null 2>&1; then
      return 0
    fi
  fi

  if ! have_cmd pulseaudio; then
    return 1
  fi

  if ! audio_ensure_runtime_dir; then
    log_error "Failed to prepare XDG_RUNTIME_DIR for PulseAudio"
    return 1
  fi

  export HOME="${HOME:-/tmp}"

  if [ "$uid_now" -eq 0 ] 2>/dev/null; then
    pa_pid="$(audio_start_bg_logged "$pulseaudio_log" pulseaudio --system --daemonize=no --disallow-exit --exit-idle-time=-1)"
  else
    pa_pid="$(audio_start_bg_logged "$pulseaudio_log" pulseaudio --daemonize=no --exit-idle-time=-1)"
  fi
  audio_add_started_pid "$pa_pid"

  AUDIO_BACKEND="pulseaudio"
  export AUDIO_BACKEND

  audio_wait_audio_ready 20 >/dev/null 2>&1 || true

  if check_audio_daemon pulseaudio >/dev/null 2>&1; then
    if [ -z "${PULSE_SERVER:-}" ]; then
      if [ -S "$XDG_RUNTIME_DIR/pulse/native" ]; then
        PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
        export PULSE_SERVER
      elif [ -S /run/pulse/native ]; then
        PULSE_SERVER="unix:/run/pulse/native"
        export PULSE_SERVER
      elif [ -S /var/run/pulse/native ]; then
        PULSE_SERVER="unix:/var/run/pulse/native"
        export PULSE_SERVER
      fi
    fi

    if audio_pa_ctl_ok >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

# Choose which backend to bootstrap when none is explicitly running yet.
# Prefers PipeWire first, then PulseAudio, based on available binaries/tools.
audio_choose_bootstrap_backend() {
  if [ -n "${AUDIO_BACKEND:-}" ]; then
    echo "$AUDIO_BACKEND"
    return 0
  fi

  if have_cmd pipewire; then
    if have_cmd pw-play || have_cmd pw-record || have_cmd wpctl || have_cmd pw-cli; then
      echo "pipewire"
      return 0
    fi
  fi

  if have_cmd pulseaudio; then
    if have_cmd paplay || have_cmd parecord || have_cmd pactl; then
      echo "pulseaudio"
      return 0
    fi
  fi

  echo ""
  return 1
}

# Return success only when the given systemd unit actually exists on this target.
audio_systemd_unit_exists() {
  unit_name="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  if systemctl list-unit-files "$unit_name" --no-legend 2>/dev/null | awk 'NF { found=1 } END { exit !found }'; then
    return 0
  fi

  return 1
}

# Return success only when the requested backend is genuinely managed by systemd here.
# This avoids assuming that "systemctl exists" means "pipewire/pulseaudio service exists".
audio_backend_is_systemd_managed() {
  backend_name="$1"

  case "$backend_name" in
    pipewire)
      if audio_systemd_unit_exists "pipewire.service" \
        || audio_systemd_unit_exists "pipewire.socket" \
        || audio_systemd_unit_exists "pipewire-pulse.service" \
        || audio_systemd_unit_exists "pipewire-pulse.socket"; then
        return 0
      fi
      return 1
      ;;
    pulseaudio)
      if audio_systemd_unit_exists "pulseaudio.service" \
        || audio_systemd_unit_exists "pulseaudio.socket"; then
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# Decide whether manual bootstrap is allowed, then start the best available backend.
# In auto mode, bootstrap is allowed when:
# 1) there is no normal systemd userspace, or
# 2) the chosen backend is not systemd-managed on this target.
audio_bootstrap_backend_if_needed() {
  start_allowed=0
  requested_backend="${AUDIO_BACKEND:-}"
  chosen_backend=""
  backend_probe=""

  case "${AUDIO_BOOTSTRAP_MODE:-auto}" in
    true|1|yes)
      start_allowed=1
      ;;
    auto)
      backend_probe="$requested_backend"
      if [ -z "$backend_probe" ]; then
        backend_probe="$(audio_choose_bootstrap_backend 2>/dev/null || echo "")"
      fi

      if [ -n "$backend_probe" ]; then
        if ! audio_should_use_service_recovery "$backend_probe"; then
          start_allowed=1
        fi
      fi
      ;;
    false|0|no)
      start_allowed=0
      ;;
    *)
      log_warn "Unknown AUDIO_BOOTSTRAP_MODE='${AUDIO_BOOTSTRAP_MODE:-}', treating as auto"
      backend_probe="$requested_backend"
      if [ -z "$backend_probe" ]; then
        backend_probe="$(audio_choose_bootstrap_backend 2>/dev/null || echo "")"
      fi
      if [ -n "$backend_probe" ]; then
        if ! audio_should_use_service_recovery "$backend_probe"; then
          start_allowed=1
        fi
      fi
      ;;
  esac

  if [ "$start_allowed" -ne 1 ]; then
    return 1
  fi

  chosen_backend="$(audio_choose_bootstrap_backend)"
  if [ -z "$chosen_backend" ]; then
    log_warn "No backend binaries available for manual bootstrap"
    return 1
  fi

  log_info "Attempting manual audio backend bootstrap: $chosen_backend"

  if [ "$chosen_backend" = "pipewire" ]; then
    if audio_manual_start_pipewire; then
      AUDIO_BACKEND="pipewire"
      export AUDIO_BACKEND
      return 0
    fi

    if [ -z "$requested_backend" ]; then
      if have_cmd pulseaudio && have_cmd paplay; then
        log_warn "PipeWire bootstrap failed, trying PulseAudio fallback"
        if audio_manual_start_pulseaudio; then
          AUDIO_BACKEND="pulseaudio"
          export AUDIO_BACKEND
          return 0
        fi
      fi
    fi
  elif [ "$chosen_backend" = "pulseaudio" ]; then
    if audio_manual_start_pulseaudio; then
      AUDIO_BACKEND="pulseaudio"
      export AUDIO_BACKEND
      return 0
    fi
  fi

  return 1
}

audio_backend_has_service_unit() {
  case "$1" in
    pipewire)
      if audio_systemd_unit_exists "pipewire.service"; then
        return 0
      fi
      return 1
      ;;
    pulseaudio)
      if audio_systemd_unit_exists "pulseaudio.service"; then
        return 0
      fi
      if audio_systemd_unit_exists "pulseaudio.socket"; then
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

audio_should_use_service_recovery() {
  backend_name="$1"

  if [ ! -d /run/systemd/system ]; then
    return 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  if audio_backend_has_service_unit "$backend_name"; then
    return 0
  fi

  return 1
}

# Require an image-provided ALSA topology in the configured DSP firmware
# directory or its platform parent. Some images keep a shared platform topology
# above variant-specific firmware directories such as cqs, iqs, or cqm.
audio_remoteproc_topology_path() {
  artp_firmware_path="$1"
  artp_firmware_dir="$(dirname "$artp_firmware_path")"
  artp_platform_dir="$(dirname "$artp_firmware_dir")"

  for artp_search_dir in "$artp_firmware_dir" "$artp_platform_dir"; do
    for artp_path in \
      "$artp_search_dir"/*tplg* \
      "$artp_search_dir"/*topology*
    do
      if [ -f "$artp_path" ]; then
        printf '%s\n' "$artp_path"
        return 0
      fi
    done
  done

  return 1
}

# Return success for a remoteproc identity commonly used to host the audio
# firmware. The caller applies the Shikra platform gate to modem instances.
audio_remoteproc_is_audio_candidate() {
  ariac_name="$1"
  ariac_firmware="$2"
  ariac_identity="$(
    printf '%s %s\n' "$ariac_name" "$ariac_firmware" |
      tr '[:upper:]' '[:lower:]'
  )"

  case "$ariac_identity" in
    *qdsp6sw*|*mdsp*|*audio*dsp*|*adsp*|*modem*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Return success when the runtime remoteproc name identifies a modem-hosted
# audio path. This is intentionally based on the name, never its index.
audio_remoteproc_is_modem() {
  arim_name="$1"
  arim_name_lower="$(printf '%s\n' "$arim_name" | tr '[:upper:]' '[:lower:]')"

  case "$arim_name_lower" in
    *modem*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Return success when runtime platform evidence identifies a Shikra target.
# The preflight runs before the suites call detect_platform, so inspect both
# any already-populated platform variables and the standard runtime DT paths.
audio_platform_is_shikra() {
  apis_identity="${PLATFORM_MACHINE:-} ${PLATFORM_TARGET:-}"
  apis_identity="$apis_identity ${PLATFORM_SOC_MACHINE:-}"
  apis_identity="$apis_identity ${PLATFORM_DT_MODEL:-}"
  apis_identity="$apis_identity ${PLATFORM_DT_COMPAT:-}"

  for apis_file in \
    /proc/device-tree/model \
    /proc/device-tree/compatible \
    /sys/firmware/devicetree/base/model \
    /sys/firmware/devicetree/base/compatible
  do
    if [ -r "$apis_file" ]; then
      apis_value="$(tr '\000' ' ' <"$apis_file" 2>/dev/null || true)"
      apis_identity="$apis_identity $apis_value"
    fi
  done

  apis_identity="$(
    printf '%s\n' "$apis_identity" |
      tr '[:upper:]' '[:lower:]'
  )"

  case "$apis_identity" in
    *shikra*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Reorder an inventory so a modem-hosted audio path is considered before DSP
# fallbacks. The caller still validates its firmware and topology, and no
# remoteproc index is inferred or hardcoded.
audio_remoteproc_prioritize_modem() {
  arpm_instances="$1"

  for arpm_pass in modem other; do
    while IFS='|' read -r arpm_path arpm_name arpm_firmware arpm_state ||
          [ -n "$arpm_path" ]
    do
      if audio_remoteproc_is_modem "$arpm_name"; then
        if [ "$arpm_pass" != "modem" ]; then
          continue
        fi
      elif [ "$arpm_pass" != "other" ]; then
        continue
      fi

      printf '%s|%s|%s|%s\n' \
        "$arpm_path" \
        "$arpm_name" \
        "$arpm_firmware" \
        "$arpm_state"
    done <<EOF
$arpm_instances
EOF
  done
}

# Check the audio-bearing remoteproc before audio tests begin. A matching
# remoteproc needs image-provided firmware and topology evidence before an
# offline instance is started. Return 2 when no applicable remoteproc exists.
audio_prepare_audio_remoteproc() {
  AUDIO_REMOTE_PROC_REASON=""
  AUDIO_REMOTE_PROC_STARTED=0
  export AUDIO_REMOTE_PROC_STARTED
  arpr_matched=0

  if ! command -v list_remoteproc_instances >/dev/null 2>&1 ||
     ! command -v find_image_firmware >/dev/null 2>&1 ||
     ! command -v start_remoteproc >/dev/null 2>&1; then
    AUDIO_REMOTE_PROC_REASON="remoteproc helpers are unavailable"
    export AUDIO_REMOTE_PROC_REASON
    return 2
  fi

  arpr_instances="$(list_remoteproc_instances 2>/dev/null || true)"
  if [ -z "$arpr_instances" ]; then
    AUDIO_REMOTE_PROC_REASON="no runtime remoteproc instances are exposed"
    export AUDIO_REMOTE_PROC_REASON
    return 2
  fi

  arpr_instances="$(audio_remoteproc_prioritize_modem "$arpr_instances")"

  while IFS='|' read -r arpr_path arpr_name arpr_firmware arpr_state ||
        [ -n "$arpr_path" ]
  do
    arpr_is_shikra_modem=0

    if ! audio_remoteproc_is_audio_candidate "$arpr_name" "$arpr_firmware"; then
      continue
    fi

    # The modem-hosted audio remoteproc is a Shikra-specific path. Other
    # platforms can expose a modem remoteproc without provisioning Shikra
    # audio firmware, which must not block their normal audio validation.
    if audio_remoteproc_is_modem "$arpr_name" &&
       ! audio_platform_is_shikra; then
      continue
    fi
    if audio_remoteproc_is_modem "$arpr_name"; then
      arpr_is_shikra_modem=1
    fi

    arpr_matched=1
    arpr_firmware_path="$(
      find_image_firmware "$arpr_firmware" 2>/dev/null || true
    )"
    if [ -z "$arpr_firmware_path" ]; then
      AUDIO_REMOTE_PROC_REASON="audio remoteproc firmware is not provisioned: name='$arpr_name' firmware='$arpr_firmware'"
      continue
    fi

    if [ "$arpr_is_shikra_modem" -eq 1 ]; then
      # Public Shikra images package qdsp6sw as modem firmware and lpaicp as
      # separate audio firmware. They do not provide an ALSA topology beside
      # qdsp6sw, so firmware presence is the correct startup prerequisite.
      arpr_topology_path="not-required"
    else
      arpr_topology_path="$(
        audio_remoteproc_topology_path "$arpr_firmware_path" 2>/dev/null || true
      )"
      if [ -z "$arpr_topology_path" ]; then
        AUDIO_REMOTE_PROC_REASON="audio topology is not provisioned for firmware '$arpr_firmware_path'"
        continue
      fi
    fi

    case "$arpr_state" in
      running)
        log_info "Audio remoteproc ready: name='$arpr_name' state=running firmware='$arpr_firmware_path' topology='$arpr_topology_path'"
        AUDIO_REMOTE_PROC_REASON=""
        export AUDIO_REMOTE_PROC_REASON
        return 0
        ;;
      offline)
        log_info "Starting offline audio remoteproc: name='$arpr_name' path='$arpr_path' firmware='$arpr_firmware_path' topology='$arpr_topology_path'"
        if start_remoteproc "$arpr_path"; then
          log_info "Audio remoteproc started: name='$arpr_name' path='$arpr_path'"
          AUDIO_REMOTE_PROC_REASON=""
          AUDIO_REMOTE_PROC_STARTED=1
          export AUDIO_REMOTE_PROC_STARTED
          export AUDIO_REMOTE_PROC_REASON
          return 0
        fi
        AUDIO_REMOTE_PROC_REASON="failed to start audio remoteproc: name='$arpr_name' path='$arpr_path'"
        ;;
      *)
        AUDIO_REMOTE_PROC_REASON="audio remoteproc is in unexpected state '$arpr_state': name='$arpr_name' path='$arpr_path'"
        ;;
    esac
  done <<EOF
$arpr_instances
EOF

  if [ "$arpr_matched" -eq 0 ]; then
    AUDIO_REMOTE_PROC_REASON="no applicable audio remoteproc was identified"
    export AUDIO_REMOTE_PROC_REASON
    return 2
  fi

  export AUDIO_REMOTE_PROC_REASON
  export AUDIO_REMOTE_PROC_STARTED
  return 1
}

# Reuse the shared remoteproc preflight when a later ALSA probe needs a retry.
# Success is reported only when this call started the offline remoteproc.
audio_recover_offline_dsp() {
  audio_prepare_audio_remoteproc
  ard_rc=$?

  if [ "$ard_rc" -eq 0 ] && [ "${AUDIO_REMOTE_PROC_STARTED:-0}" -eq 1 ]; then
    AUDIO_DSP_RECOVERY_REASON=""
    export AUDIO_DSP_RECOVERY_REASON
    return 0
  fi

  if [ "$ard_rc" -eq 0 ]; then
    AUDIO_DSP_RECOVERY_REASON="audio remoteproc is already running"
  else
    AUDIO_DSP_RECOVERY_REASON="${AUDIO_REMOTE_PROC_REASON:-no offline audio remoteproc was identified}"
  fi

  export AUDIO_DSP_RECOVERY_REASON
  return 1
}

# Return success when an exact mixer control is exposed by the selected card.
audio_alsa_control_exists() {
  aace_card="$1"
  aace_name="$2"

  command -v amixer >/dev/null 2>&1 || return 1

  amixer -c "$aace_card" controls 2>/dev/null |
    grep -F "name='$aace_name'" >/dev/null 2>&1
}

# Set an optional mixer control without assuming that every platform has it.
audio_alsa_set_control_if_present() {
  aascip_card="$1"
  aascip_name="$2"
  aascip_value="$3"

  if ! audio_alsa_control_exists "$aascip_card" "$aascip_name"; then
    return 1
  fi

  amixer -c "$aascip_card" \
    cset "iface=MIXER,name=$aascip_name" "$aascip_value" >/dev/null 2>&1
}

# List unique ALSA card indexes from procfs and the playback/capture inventories.
audio_alsa_card_indexes() {
  {
    sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]].*/\1/p' \
      /proc/asound/cards 2>/dev/null
    aplay -l 2>/dev/null |
      sed -n 's/^card[[:space:]]*\([0-9][0-9]*\):.*/\1/p'
    arecord -l 2>/dev/null |
      sed -n 's/^card[[:space:]]*\([0-9][0-9]*\):.*/\1/p'
  } | awk '!seen[$0]++'
}

# Extract the card index from an hw:CARD,DEV or plughw:CARD,DEV identifier.
audio_alsa_device_card() {
  printf '%s\n' "$1" |
    sed -n 's/^\(plug\)\{0,1\}hw:\([0-9][0-9]*\),.*/\2/p'
}

# Return success after ALSA exposes at least one hardware capture PCM.
audio_alsa_capture_inventory_available() {
  if command -v arecord >/dev/null 2>&1 &&
     arecord -l 2>/dev/null |
       grep -E '^card[[:space:]]+[0-9]+:.*device[[:space:]]+[0-9]+:' \
         >/dev/null 2>&1; then
    return 0
  fi

  if grep -E '^[0-9]+-[0-9]+:.*capture' /proc/asound/pcm \
      >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# Classify the playback route by mixer capabilities instead of platform names.
# The profile controls both mixer preparation and preferred PCM selection.
audio_alsa_playback_profile() {
  aapp_card="$1"

  if audio_alsa_control_exists \
      "$aapp_card" "PRIMARY_MI2S_RX Audio Mixer MultiMedia1"; then
    if audio_alsa_control_exists \
        "$aapp_card" "Left Speaker Mixer Left DAC Switch" ||
       audio_alsa_control_exists \
        "$aapp_card" "Playback Path DC Blocking"; then
      printf '%s\n' "primary-mi2s"
      return 0
    fi

    printf '%s\n' "legacy-primary"
    return 0
  fi

  if audio_alsa_control_exists \
      "$aapp_card" "SECONDARY_TDM_RX_0 Audio Mixer MultiMedia1"; then
    printf '%s\n' "secondary-tdm"
    return 0
  fi

  if audio_alsa_control_exists "$aapp_card" "Rx Slot Mask"; then
    printf '%s\n' "codec-direct"
    return 0
  fi

  if audio_alsa_control_exists \
      "$aapp_card" "stream0.vol_ctrl0 MultiMedia1 Playback Volu"; then
    printf '%s\n' "legacy-primary"
    return 0
  fi

  printf '%s\n' "generic"
}

# Find the first card exposing a recognized hardware playback route.
audio_alsa_find_playback_card() {
  for aafpc_card in $(audio_alsa_card_indexes); do
    aafpc_profile="$(audio_alsa_playback_profile "$aafpc_card")"
    if [ "$aafpc_profile" != "generic" ]; then
      printf '%s\n' "$aafpc_card"
      return 0
    fi
  done

  return 1
}

# Enable UCM first, then apply only mixer controls present for the detected
# primary-MI2S, secondary-TDM, codec-direct, or legacy playback path.
audio_playback_alsa_prepare() {
  ap_card="${1:-}"
  ap_profile=""
  ap_ucm_card=""

  if [ "${SINK_CHOICE:-speakers}" = "null" ]; then
    return 0
  fi

  if command -v alsaucm >/dev/null 2>&1; then
    ap_ucm_card="$(alsaucm listcards 2>/dev/null | awk 'NR==2 {sub(/^[[:space:]]+/, "", $0); print; exit}')"
    if [ -n "$ap_ucm_card" ]; then
      alsaucm -n -b - <<EOF >/dev/null 2>&1
open $ap_ucm_card
reset
set _verb HiFi
set _enadev Speaker
EOF
    fi
  fi

  if ! command -v amixer >/dev/null 2>&1; then
    return 0
  fi

  if [ -z "$ap_card" ]; then
    ap_card="$(audio_alsa_find_playback_card 2>/dev/null || true)"
  fi
  if [ -z "$ap_card" ]; then
    return 0
  fi

  ap_profile="$(audio_alsa_playback_profile "$ap_card")"

  case "$ap_profile" in
    primary-mi2s)
      audio_alsa_set_control_if_present \
        "$ap_card" "Left Speaker Mixer Left DAC Switch" on || true
      audio_alsa_set_control_if_present \
        "$ap_card" "Right Speaker Mixer Right DAC Switch" on || true
      audio_alsa_set_control_if_present \
        "$ap_card" "Speaker Left Switch" on || true
      audio_alsa_set_control_if_present \
        "$ap_card" "Speaker Right Switch" on || true
      audio_alsa_set_control_if_present \
        "$ap_card" "Speaker Switch" on || true
      audio_alsa_set_control_if_present \
        "$ap_card" "Speaker Volume" 10 || true
      audio_alsa_set_control_if_present \
        "$ap_card" "Speaker Left Mixer Volume" 3 || true
      audio_alsa_set_control_if_present \
        "$ap_card" "Speaker Right Mixer Volume" 3 || true
      audio_alsa_set_control_if_present \
        "$ap_card" "Playback Path DC Blocking" 1 || true
      audio_alsa_set_control_if_present \
        "$ap_card" "PRIMARY_MI2S_RX Audio Mixer MultiMedia1" 1 || true
      ;;
    secondary-tdm)
      audio_alsa_set_control_if_present \
        "$ap_card" "SECONDARY_TDM_RX_0 Audio Mixer MultiMedia1" 1 || true
      audio_alsa_set_control_if_present \
        "$ap_card" "stream0.vol_ctrl0 MM1 Playback Volume" 65535 || true
      ;;
    legacy-primary)
      audio_alsa_set_control_if_present \
        "$ap_card" "PRIMARY_MI2S_RX Audio Mixer MultiMedia1" 1 || true
      ;;
  esac

  audio_alsa_set_control_if_present \
    "$ap_card" "stream0.vol_ctrl0 MultiMedia1 Playback Volu" 65535 || true

  if [ "$ap_profile" != "primary-mi2s" ]; then
    audio_alsa_set_control_if_present \
      "$ap_card" "Rx Slot Mask" 3 || true

    if audio_alsa_control_exists \
        "$ap_card" "SA1 FU21 Stereo Gain Offset dB"; then
      audio_alsa_set_control_if_present \
        "$ap_card" "SA1 FU21 Stereo Gain Offset dB" 72 || true
    else
      audio_alsa_set_control_if_present \
        "$ap_card" "Speaker Volume" 72 || true
    fi

    if audio_alsa_control_exists "$ap_card" "OT23 Usage Mode"; then
      audio_alsa_set_control_if_present \
        "$ap_card" "OT23 Usage Mode" 3 || true
    else
      audio_alsa_set_control_if_present \
        "$ap_card" "Usage Mode" 3 || true
    fi
  fi

  return 0
}

# Prefer the PCM associated with a detected hardware route, then retain the
# existing default, sysdefault, and first-device fallback order.
audio_playback_pick_alsa_sink() {
  ap_dev=""
  ap_card=""
  ap_profile="generic"

  if [ "${SINK_CHOICE:-speakers}" = "null" ]; then
    echo "null"
    return 0
  fi

  if command -v aplay >/dev/null 2>&1; then
    ap_card="$(audio_alsa_find_playback_card 2>/dev/null || true)"
    if [ -n "$ap_card" ]; then
      ap_profile="$(audio_alsa_playback_profile "$ap_card")"

      case "$ap_profile" in
        primary-mi2s|secondary-tdm)
          if aplay -l 2>/dev/null |
              grep -E "^card[[:space:]]+$ap_card:.*device[[:space:]]+0:" >/dev/null 2>&1; then
            printf '%s\n' "plughw:$ap_card,0"
            return 0
          fi
          ;;
        codec-direct)
          if aplay -l 2>/dev/null |
              grep -E "^card[[:space:]]+$ap_card:.*device[[:space:]]+2:" >/dev/null 2>&1; then
            printf '%s\n' "plughw:$ap_card,2"
            return 0
          fi
          ;;
      esac
    fi

    ap_dev="$(aplay -L 2>/dev/null | awk '/^default:CARD=/{print $1; exit}')"
    if [ -n "$ap_dev" ]; then
      echo "$ap_dev"
      return 0
    fi

    ap_dev="$(aplay -L 2>/dev/null | awk '/^sysdefault:CARD=/{print $1; exit}')"
    if [ -n "$ap_dev" ]; then
      echo "$ap_dev"
      return 0
    fi

    ap_dev="$(aplay -l 2>/dev/null | sed -n 's/^card[[:space:]]*\([0-9][0-9]*\):.*device[[:space:]]*\([0-9][0-9]*\):.*/plughw:\1,\2/p' | head -n 1)"
    if [ -n "$ap_dev" ]; then
      echo "$ap_dev"
      return 0
    fi
  fi

  echo ""
  return 1
}

# Prepare the selected card before verifying that its playback PCM can open.
audio_playback_alsa_probe() {
  ap_probe_dev="$(audio_playback_pick_alsa_sink)"
  if [ -z "$ap_probe_dev" ]; then
    return 1
  fi

  ap_probe_card="$(audio_alsa_device_card "$ap_probe_dev")"
  audio_playback_alsa_prepare "$ap_probe_card" >/dev/null 2>&1 || true

  if audio_exec_with_timeout 5s aplay -D "$ap_probe_dev" -t raw -f S16_LE -r 48000 -c 2 -d 1 /dev/zero >/dev/null 2>&1; then
    AUDIO_ALSA_PLAYBACK_DEVICE="$ap_probe_dev"
    export AUDIO_ALSA_PLAYBACK_DEVICE
    return 0
  fi

  return 1
}

# Print the successfully probed ALSA playback device for propagation from a
# Debian Audio-user subprocess back into the root orchestrator.
audio_playback_alsa_probe_device() {
  if ! audio_playback_alsa_probe; then
    return 1
  fi

  printf '%s\n' "$AUDIO_ALSA_PLAYBACK_DEVICE"
}

# Return success after ALSA exposes at least one hardware playback PCM.
audio_alsa_playback_inventory_available() {
  if command -v aplay >/dev/null 2>&1 &&
     aplay -l 2>/dev/null |
       grep -E '^card[[:space:]]+[0-9]+:.*device[[:space:]]+[0-9]+:' \
         >/dev/null 2>&1; then
    return 0
  fi

  if grep -E '^[0-9]+-[0-9]+:.*playback' /proc/asound/pcm \
      >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# Probe direct ALSA playback in the prepared user context. When no playback PCM
# exists, root may start one fully provisioned offline audio DSP and retry.
audio_playback_probe_alsa_with_recovery() {
  appawr_output="$(
    audio_run_helper_as_test_user audio_playback_alsa_probe_device 2>/dev/null
  )"
  appawr_rc=$?

  if [ "$appawr_rc" -eq 0 ] && [ -n "$appawr_output" ]; then
    AUDIO_ALSA_PLAYBACK_DEVICE="$(printf '%s\n' "$appawr_output" | tail -n 1)"
    export AUDIO_ALSA_PLAYBACK_DEVICE
    return 0
  fi

  appawr_candidate="$(
    audio_run_helper_as_test_user audio_playback_pick_alsa_sink 2>/dev/null || true
  )"
  if [ -n "$appawr_candidate" ]; then
    return 1
  fi

  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ] ||
     [ "${AUDIO_DSP_RECOVERY_ATTEMPTED:-0}" -eq 1 ]; then
    return 1
  fi

  AUDIO_DSP_RECOVERY_ATTEMPTED=1
  export AUDIO_DSP_RECOVERY_ATTEMPTED

  if ! audio_recover_offline_dsp; then
    return 1
  fi

  appawr_wait=0
  while [ "$appawr_wait" -lt 10 ]; do
    if audio_alsa_playback_inventory_available; then
      break
    fi

    sleep 1
    appawr_wait=$((appawr_wait + 1))
  done

  appawr_output="$(
    audio_run_helper_as_test_user audio_playback_alsa_probe_device 2>/dev/null
  )"
  appawr_rc=$?

  if [ "$appawr_rc" -ne 0 ] || [ -z "$appawr_output" ]; then
    return 1
  fi

  AUDIO_ALSA_PLAYBACK_DEVICE="$(printf '%s\n' "$appawr_output" | tail -n 1)"
  export AUDIO_ALSA_PLAYBACK_DEVICE
  return 0
}

# Enable UCM first, then configure any exposed VA-DMIC or legacy capture route.
audio_record_alsa_prepare_capture() {
  ar_card="${1:-}"
  ar_ucm_card=""

  if command -v alsaucm >/dev/null 2>&1; then
    ar_ucm_card="$(alsaucm listcards 2>/dev/null | awk 'NR==2 {sub(/^[[:space:]]+/, "", $0); print; exit}')"
    if [ -n "$ar_ucm_card" ]; then
      alsaucm -n -b - <<EOF >/dev/null 2>&1
open $ar_ucm_card
reset
set _verb HiFi
set _enadev Mic
EOF
    fi
  fi

  if ! command -v amixer >/dev/null 2>&1; then
    return 0
  fi

  if [ -z "$ar_card" ]; then
    for ar_candidate_card in $(audio_alsa_card_indexes); do
      if audio_alsa_control_exists "$ar_candidate_card" "VA DEC0 MUX" ||
         audio_alsa_control_exists \
          "$ar_candidate_card" "MultiMedia2 Mixer TERTIARY_MI2S_TX"; then
        ar_card="$ar_candidate_card"
        break
      fi
    done
  fi
  if [ -z "$ar_card" ]; then
    return 0
  fi

  audio_alsa_set_control_if_present \
    "$ar_card" "VA DEC0 MUX" "VA_DMIC" || true
  audio_alsa_set_control_if_present \
    "$ar_card" "VA DMIC MUX0" "DMIC0" || true
  audio_alsa_set_control_if_present \
    "$ar_card" "VA_AIF1_CAP Mixer DEC0" 1 || true
  audio_alsa_set_control_if_present \
    "$ar_card" "VA_DEC0 Volume" 100 || true
  audio_alsa_set_control_if_present \
    "$ar_card" "MultiMedia3 Mixer VA_CODEC_DMA_TX_0" 1 || true
  audio_alsa_set_control_if_present \
    "$ar_card" "MultiMedia2 Mixer TERTIARY_MI2S_TX" 1 || true

  return 0
}

# Prefer the capture PCM implied by the available VA DMA controls, falling back
# to the first ALSA capture device for platforms with other routing schemes.
audio_record_pick_alsa_capture() {
  ar_dev=""
  ar_card=""

  if command -v arecord >/dev/null 2>&1; then
    for ar_card in $(audio_alsa_card_indexes); do
      if audio_alsa_control_exists \
          "$ar_card" "MultiMedia3 Mixer VA_CODEC_DMA_TX_0"; then
        if arecord -l 2>/dev/null |
            grep -E "^card[[:space:]]+$ar_card:.*device[[:space:]]+2:" >/dev/null 2>&1; then
          printf '%s\n' "plughw:$ar_card,2"
          return 0
        fi
      elif audio_alsa_control_exists "$ar_card" "VA DEC0 MUX"; then
        if arecord -l 2>/dev/null |
            grep -E "^card[[:space:]]+$ar_card:.*device[[:space:]]+3:" >/dev/null 2>&1; then
          printf '%s\n' "plughw:$ar_card,3"
          return 0
        fi
      fi
    done

    ar_dev="$(arecord -l 2>/dev/null | sed -n 's/^card[[:space:]]*\([0-9][0-9]*\):.*device[[:space:]]*\([0-9][0-9]*\):.*/hw:\1,\2/p' | head -n 1)"
    if [ -n "$ar_dev" ]; then
      echo "$ar_dev"
      return 0
    fi
  fi

  ar_dev="$(sed -n 's/^\([0-9][0-9]*\)-\([0-9][0-9]*\):.*capture.*/hw:\1,\2/p' /proc/asound/pcm 2>/dev/null | head -n 1)"
  if [ -n "$ar_dev" ]; then
    echo "$ar_dev"
    return 0
  fi

  echo ""
  return 1
}

audio_record_alsa_capture_probe() {
  ar_probe_dev="$(audio_record_pick_alsa_capture)"
  if [ -z "$ar_probe_dev" ]; then
    return 1
  fi

  ar_probe_card="$(audio_alsa_device_card "$ar_probe_dev")"
  audio_record_alsa_prepare_capture "$ar_probe_card" >/dev/null 2>&1 || true

  ar_probe_dir="$(audio_scratch_dir 2>/dev/null || true)"
  if [ -z "$ar_probe_dir" ]; then
    return 1
  fi
  ar_probe_out="$(mktemp "$ar_probe_dir/audio_record_probe.XXXXXX.wav" 2>/dev/null || printf '%s\n' "$ar_probe_dir/audio_record_probe.$$.wav")"
  rm -f "$ar_probe_out" >/dev/null 2>&1 || true

  for ar_probe_combo in "S16_LE 16000 1" "S16_LE 48000 1" "S16_LE 48000 2"; do
    ar_fmt="$(printf '%s\n' "$ar_probe_combo" | awk '{print $1}')"
    ar_rate="$(printf '%s\n' "$ar_probe_combo" | awk '{print $2}')"
    ar_ch="$(printf '%s\n' "$ar_probe_combo" | awk '{print $3}')"

    if audio_exec_with_timeout 5s arecord -D "$ar_probe_dev" -f "$ar_fmt" -r "$ar_rate" -c "$ar_ch" -d 1 "$ar_probe_out" >/dev/null 2>&1; then
      if [ -s "$ar_probe_out" ]; then
        AUDIO_ALSA_CAPTURE_DEVICE="$ar_probe_dev"
        export AUDIO_ALSA_CAPTURE_DEVICE
        rm -f "$ar_probe_out" >/dev/null 2>&1 || true
        return 0
      fi
    fi
    rm -f "$ar_probe_out" >/dev/null 2>&1 || true

    case "$ar_probe_dev" in
      hw:*)
        ar_alt_dev="plughw:${ar_probe_dev#hw:}"
        if audio_exec_with_timeout 5s arecord -D "$ar_alt_dev" -f "$ar_fmt" -r "$ar_rate" -c "$ar_ch" -d 1 "$ar_probe_out" >/dev/null 2>&1; then
          if [ -s "$ar_probe_out" ]; then
            AUDIO_ALSA_CAPTURE_DEVICE="$ar_alt_dev"
            export AUDIO_ALSA_CAPTURE_DEVICE
            rm -f "$ar_probe_out" >/dev/null 2>&1 || true
            return 0
          fi
        fi
        rm -f "$ar_probe_out" >/dev/null 2>&1 || true
        ;;
    esac
  done

  rm -f "$ar_probe_out" >/dev/null 2>&1 || true
  return 1
}

audio_probe_alsa_capture_profile() {
  # shellcheck disable=SC2034
  AUDIO_ALSA_CAPTURE_DEVICE=""
  # shellcheck disable=SC2034
  AUDIO_ALSA_CAPTURE_FORMAT=""
  # shellcheck disable=SC2034
  AUDIO_ALSA_CAPTURE_RATE=""
  # shellcheck disable=SC2034
  AUDIO_ALSA_CAPTURE_CHANNELS=""
  # shellcheck disable=SC2034
  AUDIO_ALSA_CAPTURE_REASON=""

  if ! command -v arecord >/dev/null 2>&1; then
    # shellcheck disable=SC2034
    AUDIO_ALSA_CAPTURE_REASON="arecord not available"
    return 1
  fi

  probe_dir="$(audio_scratch_dir 2>/dev/null || true)"
  if [ -z "$probe_dir" ]; then
    AUDIO_ALSA_CAPTURE_REASON="no writable Audio scratch directory is available"
    return 1
  fi
  probe_tmp=""
  if command -v mktemp >/dev/null 2>&1; then
    probe_tmp="$(mktemp "$probe_dir/audio_record_probe.XXXXXX.wav" 2>/dev/null || true)"
  fi
  if [ -z "$probe_tmp" ]; then
    probe_tmp="$probe_dir/audio_record_probe.$$.$(date +%s 2>/dev/null || echo 0).wav"
  fi

  probe_cleanup() {
    if [ -n "$probe_tmp" ] && [ -f "$probe_tmp" ]; then
      rm -f "$probe_tmp" >/dev/null 2>&1 || true
    fi
  }

  probe_devices=""
  cand="$(alsa_pick_capture 2>/dev/null || true)"
  if [ -n "$cand" ]; then
    probe_devices="$cand"
    case "$cand" in
      hw:*)
        probe_devices="$probe_devices plughw:${cand#hw:}"
        ;;
      plughw:*)
        probe_devices="$probe_devices hw:${cand#plughw:}"
        ;;
    esac
  fi

  extra_devices="$(sed -n 's/^\([0-9][0-9]*\)-\([0-9][0-9]*\):.*capture.*/hw:\1,\2/p' /proc/asound/pcm 2>/dev/null)"
  if [ -n "$extra_devices" ]; then
    for dev in $extra_devices; do
      seen=0
      for existing in $probe_devices; do
        if [ "$existing" = "$dev" ]; then
          seen=1
          break
        fi
      done
      if [ "$seen" -eq 0 ]; then
        probe_devices="$probe_devices $dev"
        case "$dev" in
          hw:*)
            probe_devices="$probe_devices plughw:${dev#hw:}"
            ;;
        esac
      fi
    done
  fi

  if [ -z "$probe_devices" ]; then
    # shellcheck disable=SC2034
    AUDIO_ALSA_CAPTURE_REASON="no ALSA capture device candidates found"
    probe_cleanup
    return 1
  fi

  for dev in $probe_devices; do
    # Mixer controls and PCM devices must come from the same ALSA card.
    probe_card="$(audio_alsa_device_card "$dev")"
    audio_record_alsa_prepare_capture "$probe_card" >/dev/null 2>&1 || true

    for combo in \
      "S16_LE 48000 1" \
      "S16_LE 16000 1" \
      "S16_LE 48000 2" \
      "S16_LE 16000 2" \
      "S24_LE 48000 2"
    do
      fmt="$(printf '%s\n' "$combo" | awk '{print $1}')"
      rate="$(printf '%s\n' "$combo" | awk '{print $2}')"
      ch="$(printf '%s\n' "$combo" | awk '{print $3}')"

      : > "$probe_tmp"

      if audio_exec_with_timeout 5s \
        arecord -q -D "$dev" -f "$fmt" -r "$rate" -c "$ch" -d 1 "$probe_tmp" >/dev/null 2>&1
      then
        bytes="$(file_size_bytes "$probe_tmp" 2>/dev/null || echo 0)"
        if [ "${bytes:-0}" -gt 44 ] 2>/dev/null; then
          # Used later by sourced run.sh
          # shellcheck disable=SC2034
          AUDIO_ALSA_CAPTURE_DEVICE="$dev"
          # shellcheck disable=SC2034
          AUDIO_ALSA_CAPTURE_FORMAT="$fmt"
          # shellcheck disable=SC2034
          AUDIO_ALSA_CAPTURE_RATE="$rate"
          # shellcheck disable=SC2034
          AUDIO_ALSA_CAPTURE_CHANNELS="$ch"
          # shellcheck disable=SC2034
          AUDIO_ALSA_CAPTURE_REASON=""
          probe_cleanup
          return 0
        fi
      fi
    done
  done

  # Used later by sourced run.sh
  # shellcheck disable=SC2034
  AUDIO_ALSA_CAPTURE_REASON="no ALSA capture profile could be opened"
  probe_cleanup
  return 1
}

###############################################################################
# ALSA sound card registration helpers
###############################################################################
audio_card_log_alsa_inventory() {
  log_info "----- ALSA sound inventory -----"

  if [ -f /proc/asound/cards ]; then
    log_info "/proc/asound/cards:"
    while IFS= read -r line || [ -n "$line" ]; do
      log_info "[asound-cards] $line"
    done < /proc/asound/cards
  else
    log_warn "/proc/asound/cards is missing"
  fi

  if [ -f /proc/asound/devices ]; then
    log_info "/proc/asound/devices:"
    while IFS= read -r line || [ -n "$line" ]; do
      log_info "[asound-devices] $line"
    done < /proc/asound/devices
  else
    log_warn "/proc/asound/devices is missing"
  fi

  if [ -f /proc/asound/pcm ]; then
    log_info "/proc/asound/pcm:"
    while IFS= read -r line || [ -n "$line" ]; do
      log_info "[asound-pcm] $line"
    done < /proc/asound/pcm
  else
    log_warn "/proc/asound/pcm is missing"
  fi

  if [ -d /dev/snd ]; then
    log_info "/dev/snd:"
    for audio_snd_path in /dev/snd/*; do
      [ -e "$audio_snd_path" ] || continue

      if command -v stat >/dev/null 2>&1; then
        audio_snd_mode="$(stat -c '%A' "$audio_snd_path" 2>/dev/null || printf '%s' '?')"
        audio_snd_owner="$(stat -c '%U:%G' "$audio_snd_path" 2>/dev/null || printf '%s' '?')"
        audio_snd_type="$(stat -c '%F' "$audio_snd_path" 2>/dev/null || printf '%s' '?')"
        log_info "[dev-snd] ${audio_snd_mode} ${audio_snd_owner} ${audio_snd_type} ${audio_snd_path}"
      else
        log_info "[dev-snd] ${audio_snd_path}"
      fi
    done
  else
    log_warn "/dev/snd is missing"
  fi

  if [ -d /sys/class/sound ]; then
    log_info "/sys/class/sound:"
    for audio_sound_path in /sys/class/sound/*; do
      [ -e "$audio_sound_path" ] || continue

      audio_sound_target=""
      if [ -L "$audio_sound_path" ] && command -v readlink >/dev/null 2>&1; then
        audio_sound_target="$(readlink "$audio_sound_path" 2>/dev/null || true)"
      fi

      if command -v stat >/dev/null 2>&1; then
        audio_sound_mode="$(stat -c '%A' "$audio_sound_path" 2>/dev/null || printf '%s' '?')"
        audio_sound_owner="$(stat -c '%U:%G' "$audio_sound_path" 2>/dev/null || printf '%s' '?')"
        audio_sound_type="$(stat -c '%F' "$audio_sound_path" 2>/dev/null || printf '%s' '?')"

        if [ -n "$audio_sound_target" ]; then
          log_info "[sys-sound] ${audio_sound_mode} ${audio_sound_owner} ${audio_sound_type} ${audio_sound_path} -> ${audio_sound_target}"
        else
          log_info "[sys-sound] ${audio_sound_mode} ${audio_sound_owner} ${audio_sound_type} ${audio_sound_path}"
        fi
      else
        if [ -n "$audio_sound_target" ]; then
          log_info "[sys-sound] ${audio_sound_path} -> ${audio_sound_target}"
        else
          log_info "[sys-sound] ${audio_sound_path}"
        fi
      fi
    done
  else
    log_warn "/sys/class/sound is missing"
  fi

  if command -v aplay >/dev/null 2>&1; then
    log_info "aplay -l:"
    aplay -l 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
      log_info "[aplay] $line"
    done
  else
    log_info "aplay not available, skipping aplay -l dump"
  fi

  if command -v arecord >/dev/null 2>&1; then
    log_info "arecord -l:"
    arecord -l 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
      log_info "[arecord] $line"
    done
  else
    log_info "arecord not available, skipping arecord -l dump"
  fi

  log_info "----- End ALSA sound inventory -----"
}

# Print registered ALSA cards as:
# card_index|card_id|description
audio_card_get_registered_cards() {
  if [ ! -f /proc/asound/cards ]; then
    return 1
  fi

  awk '
    /^[[:space:]]*[0-9]+[[:space:]]+\[/ {
      idx = $1
      id = $0
      desc = $0

      sub(/^[^[]*\[/, "", id)
      sub(/\].*$/, "", id)

      sub(/^[^:]*:[[:space:]]*/, "", desc)

      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", desc)

      print idx "|" id "|" desc
    }
  ' /proc/asound/cards
}

# Return 0 if the card line is dummy/loopback-only.
audio_card_is_dummy_or_generic() {
  card_line="$1"

  printf '%s\n' "$card_line" | grep -Eiq 'dummy|loopback|aloop|snd-dummy'
}

# Print only non-dummy registered cards.
audio_card_get_valid_cards() {
  audio_card_get_registered_cards 2>/dev/null | while IFS= read -r card_line || [ -n "$card_line" ]; do
    [ -n "$card_line" ] || continue

    if audio_card_is_dummy_or_generic "$card_line"; then
      continue
    fi

    printf '%s\n' "$card_line"
  done
}

# Count non-dummy registered cards.
audio_card_count_valid_cards() {
  count="$(audio_card_get_valid_cards 2>/dev/null | wc -l | awk '{print $1}')"

  if [ -z "$count" ]; then
    count=0
  fi

  printf '%s\n' "$count"
}

# Print valid cards matching a case-insensitive substring.
# Empty match means all valid cards.
audio_card_find_matching_cards() {
  match="$1"

  if [ -z "$match" ]; then
    audio_card_get_valid_cards
    return $?
  fi

  audio_card_get_valid_cards 2>/dev/null | awk -v pat="$match" '
    BEGIN {
      pat = tolower(pat)
    }
    {
      line = tolower($0)
      if (index(line, pat) > 0) {
        print $0
      }
    }
  '
}

# Return 0 if current DT/sysfs suggests audio card registration is expected.
audio_card_dt_audio_expected() {
  if [ -d /sys/class/sound ]; then
    for card_path in /sys/class/sound/card*; do
      if [ -e "$card_path" ]; then
        return 0
      fi
    done
  fi

  if [ ! -d /proc/device-tree ]; then
    return 1
  fi

  if find /proc/device-tree -type d \( \
      -name "sound" -o \
      -name "*sound*" -o \
      -name "*audio*" \
    \) 2>/dev/null | grep -q .; then
    return 0
  fi

  compat_match_dir="$(audio_scratch_dir 2>/dev/null || true)"
  [ -n "$compat_match_dir" ] || return 1
  compat_match_file="$(mktemp "$compat_match_dir/audio_compat_match.XXXXXX" 2>/dev/null || printf '%s\n' "$compat_match_dir/audio_compat_match.$$")"
  : > "$compat_match_file" 2>/dev/null || return 1

  find /proc/device-tree -name compatible -type f 2>/dev/null |
  while IFS= read -r compat_file || [ -n "$compat_file" ]; do
    [ -n "$compat_file" ] || continue

    if tr '\000' '\n' < "$compat_file" 2>/dev/null | grep -Eiq 'qcom,.*(sound|audio|snd|lpass|wsa|rx-macro|tx-macro|va-macro|codec|swr|soundwire)'; then
      printf '%s\n' "$compat_file" > "$compat_match_file"
      break
    fi
  done

  if [ -s "$compat_match_file" ]; then
    rm -f "$compat_match_file" 2>/dev/null || true
    return 0
  fi

  rm -f "$compat_match_file" 2>/dev/null || true
  return 1
}

# Wait for at least one valid ALSA card, optionally matching AUDIO_CARD_MATCH.
audio_card_wait_for_cards() {
  wait_secs="$1"
  card_match="$2"
  elapsed=0

  case "$wait_secs" in
    ''|*[!0-9]*)
      wait_secs=30
      ;;
  esac

  log_info "Waiting up to ${wait_secs}s for ALSA sound card registration"

  while [ "$elapsed" -le "$wait_secs" ]; do
    if [ -n "$card_match" ]; then
      if audio_card_find_matching_cards "$card_match" | grep -q .; then
        return 0
      fi
    else
      card_count="$(audio_card_count_valid_cards)"
      if [ "$card_count" -gt 0 ] 2>/dev/null; then
        return 0
      fi
    fi

    if [ "$elapsed" -eq "$wait_secs" ]; then
      break
    fi

    sleep 1
    elapsed=$((elapsed + 1))

    case "$elapsed" in
      5|10|15|20|25|30|45|60)
        log_info "Still waiting for ALSA card registration, elapsed=${elapsed}s"
        ;;
    esac
  done

  return 1
}

# Validate /dev/snd/controlC<N> for every matched valid card.
audio_card_validate_control_nodes() {
  cards_file="$1"
  failed=0

  if [ ! -s "$cards_file" ]; then
    log_fail "No matched ALSA cards provided for control node validation"
    return 1
  fi

  while IFS='|' read -r card_idx card_id card_desc || [ -n "$card_idx" ]; do
    [ -n "$card_idx" ] || continue

    control_node="/dev/snd/controlC${card_idx}"

    if [ -e "$control_node" ]; then
      log_pass "ALSA control node present for card ${card_idx}, ${control_node}, id='${card_id}', desc='${card_desc}'"
    else
      log_fail "Missing ALSA control node for card ${card_idx}, expected ${control_node}, id='${card_id}', desc='${card_desc}'"
      failed=1
    fi
  done < "$cards_file"

  if [ "$failed" -eq 0 ]; then
    return 0
  fi

  return 1
}

# Validate PCM entries for every matched valid card.
# mode:
# any - require any PCM for the card
# playback - require playback PCM
# capture - require capture PCM
audio_card_validate_pcm_nodes() {
  cards_file="$1"
  mode="$2"
  failed=0
  total_checked=0
  pcm_tmp_file=""

  if [ -z "$mode" ]; then
    mode="any"
  fi

  case "$mode" in
    any|playback|capture)
      ;;
    *)
      log_warn "Invalid PCM validation mode '${mode}', using any"
      mode="any"
      ;;
  esac

  if [ ! -s "$cards_file" ]; then
    log_fail "No matched ALSA cards provided for PCM validation"
    return 1
  fi

  if [ ! -f /proc/asound/pcm ]; then
    log_fail "/proc/asound/pcm is missing"
    return 1
  fi

  pcm_tmp_dir="$(audio_scratch_dir 2>/dev/null || true)"
  if [ -z "$pcm_tmp_dir" ]; then
    log_fail "No writable Audio scratch directory is available"
    return 1
  fi
  pcm_tmp_file="$(mktemp "$pcm_tmp_dir/audio_pcm_lines.XXXXXX" 2>/dev/null || printf '%s\n' "$pcm_tmp_dir/audio_pcm_lines.$$")"
  : > "$pcm_tmp_file" 2>/dev/null || return 1

  while IFS='|' read -r card_idx card_id card_desc || [ -n "$card_idx" ]; do
    [ -n "$card_idx" ] || continue

    case "$card_idx" in
      ''|*[!0-9]*)
        log_warn "Invalid ALSA card index '${card_idx}', skipping PCM validation for this entry"
        continue
        ;;
    esac

    card_prefix="$(printf '%02d' "$card_idx" 2>/dev/null || printf '%s' "$card_idx")"
    card_has_pcm=0
    card_has_mode=0
    card_checked=0

    grep "^${card_prefix}-" /proc/asound/pcm 2>/dev/null > "$pcm_tmp_file" || true

    if [ ! -s "$pcm_tmp_file" ]; then
      log_fail "PCM entry missing for card ${card_idx}, id='${card_id}', desc='${card_desc}'"
      failed=1
      continue
    fi

    while IFS= read -r pcm_line || [ -n "$pcm_line" ]; do
      [ -n "$pcm_line" ] || continue

      card_has_pcm=1

      pcm_dev="$(printf '%s\n' "$pcm_line" | sed -n 's/^[0-9][0-9]-\([0-9][0-9]\):.*/\1/p')"
      [ -n "$pcm_dev" ] || continue

      pcm_dev_num="$(printf '%s\n' "$pcm_dev" | sed 's/^0*//')"
      if [ -z "$pcm_dev_num" ]; then
        pcm_dev_num=0
      fi

      if printf '%s\n' "$pcm_line" | grep -qi 'playback'; then
        if [ "$mode" = "any" ] || [ "$mode" = "playback" ]; then
          card_has_mode=1
          card_checked=$((card_checked + 1))
          total_checked=$((total_checked + 1))
          pcm_node="/dev/snd/pcmC${card_idx}D${pcm_dev_num}p"

          if [ -e "$pcm_node" ]; then
            if [ "$mode" = "any" ]; then
              log_pass "Advertised playback PCM node present, ${pcm_node}, card=${card_idx}, id='${card_id}', desc='${card_desc}'"
            fi
          else
            log_fail "Advertised playback PCM node missing, expected ${pcm_node}, line='${pcm_line}', card=${card_idx}, id='${card_id}', desc='${card_desc}'"
            failed=1
          fi
        fi
      fi

      if printf '%s\n' "$pcm_line" | grep -qi 'capture'; then
        if [ "$mode" = "any" ] || [ "$mode" = "capture" ]; then
          card_has_mode=1
          card_checked=$((card_checked + 1))
          total_checked=$((total_checked + 1))
          pcm_node="/dev/snd/pcmC${card_idx}D${pcm_dev_num}c"

          if [ -e "$pcm_node" ]; then
            if [ "$mode" = "any" ]; then
              log_pass "Advertised capture PCM node present, ${pcm_node}, card=${card_idx}, id='${card_id}', desc='${card_desc}'"
            fi
          else
            log_fail "Advertised capture PCM node missing, expected ${pcm_node}, line='${pcm_line}', card=${card_idx}, id='${card_id}', desc='${card_desc}'"
            failed=1
          fi
        fi
      fi
    done < "$pcm_tmp_file"

    if [ "$mode" = "any" ]; then
      if [ "$card_has_pcm" -eq 1 ]; then
        log_pass "PCM entry present for card ${card_idx}, id='${card_id}', desc='${card_desc}'"
      else
        log_fail "PCM entry missing for card ${card_idx}, id='${card_id}', desc='${card_desc}'"
        failed=1
      fi
    elif [ "$mode" = "playback" ]; then
      if [ "$card_has_mode" -eq 1 ]; then
        log_pass "Playback PCM validation passed for card ${card_idx}, count=${card_checked}, id='${card_id}', desc='${card_desc}'"
      else
        log_fail "Playback PCM entry missing for card ${card_idx}, id='${card_id}', desc='${card_desc}'"
        failed=1
      fi
    elif [ "$mode" = "capture" ]; then
      if [ "$card_has_mode" -eq 1 ]; then
        log_pass "Capture PCM validation passed for card ${card_idx}, count=${card_checked}, id='${card_id}', desc='${card_desc}'"
      else
        log_fail "Capture PCM entry missing for card ${card_idx}, id='${card_id}', desc='${card_desc}'"
        failed=1
      fi
    fi
  done < "$cards_file"

  rm -f "$pcm_tmp_file" 2>/dev/null || true

  if [ "$total_checked" -eq 0 ]; then
    log_warn "No advertised PCM device nodes were validated from /proc/asound/pcm, mode=${mode}"
  else
    log_info "Validated advertised PCM device nodes, mode=${mode}, count=${total_checked}"
  fi

  if [ "$failed" -eq 0 ]; then
    return 0
  fi

  return 1
}

# Audio-card focused dmesg scan.
audio_card_dmesg_scan() {
  outdir="$1"

  if [ -z "$outdir" ]; then
    outdir="."
  fi

  audio_dmesg_modules="snd|asoc|audio|lpass|q6|q6afe|q6asm|q6adm|apr|glink|wsa|rx-macro|tx-macro|va-macro|soundwire|swr|codec|remoteproc"
  audio_dmesg_benign="dummy regulator|probe deferred|deferred probe pending"

  if command -v scan_dmesg_errors >/dev/null 2>&1; then
    scan_dmesg_errors \
      "$outdir" \
      "$audio_dmesg_modules" \
      "$audio_dmesg_benign" || true
  else
    log_warn "scan_dmesg_errors helper not available, skipping audio dmesg scan"
  fi
}

###############################################################################
# Audio package preparation, overlay activation, and WAV payload validation
###############################################################################

AUDIO_OVERLAY_PACKAGES_CHANGED=0
AUDIO_OVERLAY_REBOOT_REQUIRED=0
AUDIO_WAV_VALIDATION_SUMMARY=""

# Refresh kernel-module metadata and device state after Debian AudioReach
# package preparation.
#
# Args:
#   $1 - 0 for base Audio mode
#        1 when --overlay was explicitly requested
#
#   $2 - 0 when the AudioReach package state did not change
#        1 when one or more AudioReach packages changed
#
# Platform behavior:
#   Debian overlay:
#     - run depmod when the AudioReach package state changed
#     - install and activate the repository-owned AudioReach udev rule
#
#   Debian base:
#     - no-op
#
#   Yocto/qcom-distro/other:
#     - strict no-op
#
# This helper does not:
#   - chmod or chown device nodes directly
#   - install packages
#   - reload kernel modules
#   - restart PipeWire
#
# Returns:
#   0 - refresh completed or not applicable
#   1 - refresh failed
audio_refresh_overlay_devices() {
  arod_overlay_requested="${1:-0}"
  arod_packages_changed="${2:-0}"
 
  case "$arod_overlay_requested" in
    0)
      return 0
      ;;
    1)
      ;;
    *)
      log_fail "Invalid Audio overlay request value: $arod_overlay_requested"
      return 1
      ;;
  esac
 
  case "$arod_packages_changed" in
    0|1)
      ;;
    *)
      log_fail "Invalid Audio package-change value: $arod_packages_changed"
      return 1
      ;;
  esac
 
  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    arod_os_id="$(
      pkg_detect_os_id 2>/dev/null ||
        echo unknown
    )"
  else
    arod_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi
 
  [ -n "$arod_os_id" ] || arod_os_id="unknown"
 
  case "$arod_os_id" in
    debian)
      ;;
    qcom-distro|poky|openembedded|oe)
      log_info "Native image detected, AudioReach device refresh is not required"
      return 0
      ;;
    *)
      log_info "AudioReach device refresh is not enabled for os=$arod_os_id"
      return 0
      ;;
  esac
 
  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    log_fail "AudioReach device refresh must run as root"
    return 1
  fi
 
  ###########################################################################
  # Kernel module dependency metadata
  ###########################################################################
 
  if [ "$arod_packages_changed" -eq 1 ]; then
    if command -v depmod >/dev/null 2>&1; then
      log_info "Refreshing kernel module dependency metadata"
 
      if ! audio_exec_with_timeout \
          30s \
          depmod -a 2>&1; then
        log_fail "Failed to refresh kernel module dependency metadata"
        return 1
      fi
 
      log_pass "Kernel module dependency metadata refreshed"
    else
      log_warn "depmod is unavailable, kernel module metadata was not refreshed"
    fi
  else
    log_info "AudioReach packages are unchanged, depmod refresh is not required"
  fi
 
  ###########################################################################
  # Runtime udev rule and device permissions
  ###########################################################################
 
  if ! command -v audio_prepare_audioreach_udev_rule \
      >/dev/null 2>&1; then
    log_fail "AudioReach udev preparation helper is unavailable"
    return 1
  fi
 
  if ! audio_prepare_audioreach_udev_rule \
      "$arod_overlay_requested"; then
    log_fail "Failed to install or activate the AudioReach udev rule"
    return 1
  fi
 
  log_pass "AudioReach device refresh completed"
  return 0
}

# Validate the dma-heap node required by the Debian AudioReach overlay.
#
# The helper is deliberately non-mutating: it never chmods the node and never
# changes users or groups. Packaged udev/group policy must provide access.
#
# Return:
#   0 - node exists and is readable/writable by the current test process
#   1 - node is missing or inaccessible
audio_validate_dma_heap_access() {
  avdha_node="${AUDIO_DMA_HEAP_NODE:-/dev/dma_heap/system}"

  if [ ! -e "$avdha_node" ]; then
    log_fail "$avdha_node is missing"
    return 1
  fi

  if command -v stat >/dev/null 2>&1; then
    avdha_mode="$(stat -c '%a' "$avdha_node" 2>/dev/null || echo unknown)"
    avdha_owner="$(stat -c '%U:%G' "$avdha_node" 2>/dev/null || echo unknown)"
    log_info "$avdha_node mode=$avdha_mode owner=$avdha_owner"
  fi

  if [ -r "$avdha_node" ] && [ -w "$avdha_node" ]; then
    log_pass "$avdha_node is readable and writable"
    return 0
  fi

  log_fail "$avdha_node is present but is not accessible to uid=$(id -u 2>/dev/null || echo unknown)"
  log_fail "Fix audioreach-config udev/group policy, the test will not chmod the node"
  return 1
}

# Prepare and validate the Debian AudioReach overlay runtime.
#
# The preferred execution model keeps the test runner as root and executes only
# user-session or unprivileged device-access commands as the Debian Audio user.
#
# Args:
#   $1 - 0 for base Audio mode
#        1 when --overlay was explicitly requested
#
# Prerequisite for the preferred Debian root path:
#   audio_prepare_debian_audio_environment 1
#
# Platform behavior:
#   Debian overlay:
#     - validate dma-heap access as the Debian Audio user
#     - validate ALSA node access as the Debian Audio user
#     - validate PipeWire through the Debian user session
#     - restart PipeWire only when required
#
#   Debian base:
#     - no-op
#
#   Yocto/qcom-distro/other:
#     - strict no-op
#
# Environment:
#   AUDIO_OVERLAY_PACKAGES_CHANGED
#       0 - AudioReach packages were already installed
#       1 - AudioReach userspace package state changed
#
#   AUDIO_OVERLAY_REBOOT_REQUIRED
#       1 - a DKMS change requires reboot
#
#   PIPEWIRE_READY_TIMEOUT
#       final PipeWire readiness timeout; default: 120 seconds
#
# Returns:
#   0 - runtime ready or not applicable
#   1 - runtime preparation failed
#   2 - reboot required
audio_prepare_overlay_runtime() {
  apor_overlay_requested="${1:-0}"
  apor_packages_changed="${AUDIO_OVERLAY_PACKAGES_CHANGED:-0}"
  apor_ready_timeout="${PIPEWIRE_READY_TIMEOUT:-120}"

  case "$apor_overlay_requested" in
    0)
      return 0
      ;;
    1)
      ;;
    *)
      log_fail "Invalid Audio overlay request value: $apor_overlay_requested"
      return 1
      ;;
  esac

  case "$apor_packages_changed" in
    0|1)
      ;;
    *)
      log_warn "Invalid AUDIO_OVERLAY_PACKAGES_CHANGED value: $apor_packages_changed"
      log_warn "Treating AudioReach package state as changed"
      apor_packages_changed=1
      ;;
  esac

  case "$apor_ready_timeout" in
    ''|*[!0-9]*)
      log_warn "Invalid PIPEWIRE_READY_TIMEOUT value: $apor_ready_timeout"
      apor_ready_timeout=120
      ;;
  esac

  ###########################################################################
  # Platform detection
  ###########################################################################

  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    apor_os_id="$(
      pkg_detect_os_id 2>/dev/null ||
        echo unknown
    )"
  else
    apor_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi

  [ -n "$apor_os_id" ] || apor_os_id="unknown"

  case "$apor_os_id" in
    debian)
      ;;
    *)
      # Preserve native/Yocto behavior.
      return 0
      ;;
  esac

  ###########################################################################
  # Reboot-required guard
  ###########################################################################

  case "${AUDIO_OVERLAY_REBOOT_REQUIRED:-0}" in
    1)
      log_warn "AudioReach DKMS package changed"
      log_warn "A reboot is required before AudioReach validation"
      return 2
      ;;
    0|'')
      ;;
    *)
      log_fail "Invalid AUDIO_OVERLAY_REBOOT_REQUIRED value: ${AUDIO_OVERLAY_REBOOT_REQUIRED:-}"
      return 1
      ;;
  esac

  ###########################################################################
  # Determine preferred root mode or temporary re-executed-user mode
  ###########################################################################

  apor_current_uid="$(id -u 2>/dev/null || echo 1)"
  apor_user_command_mode=""

  if [ "$apor_current_uid" -eq 0 ] 2>/dev/null; then
    apor_user_command_mode="root-wrapper"

    if ! command -v audio_run_as_test_user >/dev/null 2>&1; then
      log_fail "Audio user-command helper is unavailable"
      return 1
    fi

    if [ -z "${AUDIO_TEST_USER:-}" ] ||
       [ -z "${AUDIO_TEST_UID:-}" ] ||
       [ -z "${AUDIO_TEST_RUNTIME_DIR:-}" ] ||
       [ -z "${AUDIO_TEST_DBUS_ADDRESS:-}" ]; then
      log_fail "Debian Audio environment has not been prepared"
      log_fail "Call audio_prepare_debian_audio_environment 1 before overlay runtime preparation"
      return 1
    fi

    log_info "Preparing Debian AudioReach runtime from root orchestration"
  else
    # Temporary compatibility until Playback and Record stop re-executing the
    # complete runner as the Debian user.
    case "${AUDIO_TEST_USER_REEXEC:-0}:${AUDIO_TEST_COMMAND_USER_CONTEXT:-0}" in
      1:*|*:1)
        apor_user_command_mode="existing-user"
        ;;
      *)
        log_fail "AudioReach runtime preparation must be initiated by root"
        return 1
        ;;
    esac

    log_info "Preparing Debian AudioReach runtime in temporary re-executed-user mode"
  fi

  ###########################################################################
  # dma-heap existence and diagnostic information
  ###########################################################################

  if [ ! -e /dev/dma_heap/system ]; then
    log_fail "/dev/dma_heap/system is missing"
    return 1
  fi

  if command -v stat >/dev/null 2>&1; then
    apor_dma_mode="$(
      stat -c '%a' /dev/dma_heap/system 2>/dev/null ||
        echo unknown
    )"

    apor_dma_owner="$(
      stat -c '%U:%G' /dev/dma_heap/system 2>/dev/null ||
        echo unknown
    )"

    log_info "/dev/dma_heap/system mode=$apor_dma_mode owner=$apor_dma_owner"
  fi

  ###########################################################################
  # Validate dma-heap access as the Debian Audio user
  ###########################################################################

  if [ "$apor_user_command_mode" = "root-wrapper" ]; then
    # Variables in this command script are intentionally expanded by the child shell.
    # shellcheck disable=SC2016
    audio_run_as_test_user \
      sh -c '
        dma_node=$1
        [ -r "$dma_node" ] && [ -w "$dma_node" ]
      ' \
      sh \
      /dev/dma_heap/system

    apor_dma_rc=$?
  else
    if [ -r /dev/dma_heap/system ] &&
       [ -w /dev/dma_heap/system ]; then
      apor_dma_rc=0
    else
      apor_dma_rc=1
    fi
  fi

  if [ "$apor_dma_rc" -ne 0 ]; then
    log_fail "Debian Audio user cannot read and write /dev/dma_heap/system"
    return 1
  fi

  log_pass "/dev/dma_heap/system is accessible to the Debian Audio user"

  ###########################################################################
  # Validate ALSA nodes as the Debian Audio user
  ###########################################################################

  if [ ! -d /dev/snd ]; then
    log_fail "/dev/snd is missing"
    log_fail "No ALSA device nodes are available"
    return 1
  fi
  # Variables in this command script are intentionally expanded by the child shell.
  # shellcheck disable=SC2016
  apor_alsa_probe='
    alsa_node_found=0

    for alsa_node in \
      /dev/snd/controlC* \
      /dev/snd/pcmC*
    do
      [ -e "$alsa_node" ] || continue

      alsa_node_found=1

      if [ -r "$alsa_node" ] &&
         [ -w "$alsa_node" ]; then
        exit 0
      fi
    done

    if [ "$alsa_node_found" -eq 0 ]; then
      exit 2
    fi

    exit 1
  '

  if [ "$apor_user_command_mode" = "root-wrapper" ]; then
    audio_run_as_test_user \
      sh -c "$apor_alsa_probe"

    apor_alsa_rc=$?
  else
    sh -c "$apor_alsa_probe"
    apor_alsa_rc=$?
  fi

  case "$apor_alsa_rc" in
    0)
      log_pass "ALSA device nodes are accessible to the Debian Audio user"
      ;;
    2)
      log_fail "No ALSA control or PCM device nodes were found under /dev/snd"
      return 1
      ;;
    *)
      log_fail "ALSA control and PCM nodes are not accessible to the Debian Audio user"

      if command -v stat >/dev/null 2>&1; then
        for apor_snd_node in /dev/snd/*; do
          [ -e "$apor_snd_node" ] || continue

          apor_snd_mode="$(
            stat -c '%a' "$apor_snd_node" 2>/dev/null ||
              echo unknown
          )"

          apor_snd_owner="$(
            stat -c '%U:%G' "$apor_snd_node" 2>/dev/null ||
              echo unknown
          )"

          log_info "[dev-snd] mode=$apor_snd_mode owner=$apor_snd_owner path=$apor_snd_node"
        done
      fi

      return 1
      ;;
  esac

  ###########################################################################
  # PipeWire control-plane probe
  ###########################################################################

  apor_pipewire_probe='
    if command -v wpctl >/dev/null 2>&1; then
      wpctl status >/dev/null 2>&1
      exit $?
    fi

    if command -v pw-cli >/dev/null 2>&1; then
      pw-cli info 0 >/dev/null 2>&1
      exit $?
    fi

    exit 127
  '

  apor_pipewire_control_ready=0

  if [ "$apor_user_command_mode" = "root-wrapper" ]; then
    if audio_run_as_test_user \
        --require-session \
        sh -c "$apor_pipewire_probe"; then
      apor_pipewire_control_ready=1
    fi
  else
    if sh -c "$apor_pipewire_probe"; then
      apor_pipewire_control_ready=1
    fi
  fi

  apor_pipewire_service_ready=0

  if audio_pipewire_systemctl \
      is-active \
      --quiet \
      pipewire >/dev/null 2>&1; then
    apor_pipewire_service_ready=1
  fi

  ###########################################################################
  # Preserve a healthy unchanged PipeWire runtime
  ###########################################################################

  if [ "$apor_packages_changed" -eq 0 ] &&
     [ "$apor_pipewire_service_ready" -eq 1 ] &&
     [ "$apor_pipewire_control_ready" -eq 1 ]; then
    log_pass "PipeWire user service and control plane are already ready"
    log_info "PipeWire restart is not required"
    return 0
  fi

  if [ "$apor_packages_changed" -eq 1 ]; then
    log_info "AudioReach userspace package state changed"
    log_info "Restarting PipeWire to load updated userspace components"
  elif [ "$apor_pipewire_service_ready" -ne 1 ]; then
    log_warn "PipeWire user service is not active"
    log_warn "Attempting one bounded restart"
  else
    log_warn "PipeWire user service is active but its control plane is unresponsive"
    log_warn "Attempting one bounded restart"
  fi

  ###########################################################################
  # Bounded PipeWire restart
  ###########################################################################

  if ! command -v audio_restart_pipewire_service >/dev/null 2>&1; then
    log_fail "Bounded PipeWire restart helper is unavailable"
    return 1
  fi

  if ! audio_restart_pipewire_service "1/1"; then
    log_fail "Failed to restart the Debian PipeWire user service"
    return 1
  fi

  ###########################################################################
  # Wait for both the user service and the PipeWire control plane
  ###########################################################################

  apor_wait=0
  apor_next_log=10

  log_info "Waiting for PipeWire user runtime readiness, timeout=${apor_ready_timeout}s"

  while [ "$apor_wait" -lt "$apor_ready_timeout" ]; do
    apor_pipewire_service_ready=0
    apor_pipewire_control_ready=0

    if audio_pipewire_systemctl \
        is-active \
        --quiet \
        pipewire >/dev/null 2>&1; then
      apor_pipewire_service_ready=1
    fi

    if [ "$apor_user_command_mode" = "root-wrapper" ]; then
      if audio_run_as_test_user \
          --require-session \
          sh -c "$apor_pipewire_probe"; then
        apor_pipewire_control_ready=1
      fi
    else
      if sh -c "$apor_pipewire_probe"; then
        apor_pipewire_control_ready=1
      fi
    fi

    if [ "$apor_pipewire_service_ready" -eq 1 ] &&
       [ "$apor_pipewire_control_ready" -eq 1 ]; then
      log_pass "Debian AudioReach runtime is ready"
      return 0
    fi

    if [ "$apor_wait" -ge "$apor_next_log" ]; then
      log_info "Still waiting for PipeWire readiness, service=$apor_pipewire_service_ready control=$apor_pipewire_control_ready ${apor_wait}s/${apor_ready_timeout}s"
      apor_next_log=$((apor_next_log + 10))
    fi

    sleep 1
    apor_wait=$((apor_wait + 1))
  done

  ###########################################################################
  # Failure diagnostics
  ###########################################################################

  log_fail "PipeWire did not become ready within ${apor_ready_timeout}s"

  log_info "Current PipeWire user-service status:"

  audio_pipewire_systemctl \
    status \
    pipewire \
    --no-pager \
    --full 2>&1 |
    while IFS= read -r apor_status_line ||
          [ -n "$apor_status_line" ]; do
      log_info "[systemctl:user] $apor_status_line"
    done

  if [ "$apor_user_command_mode" = "root-wrapper" ]; then
    if command -v audio_run_as_test_user >/dev/null 2>&1; then
      log_info "Current PipeWire control-plane status:"

      audio_run_as_test_user \
        --require-session \
        sh -c '
          if command -v wpctl >/dev/null 2>&1; then
            exec wpctl status
          fi

          if command -v pw-cli >/dev/null 2>&1; then
            exec pw-cli info 0
          fi

          exit 127
        ' 2>&1 |
        while IFS= read -r apor_status_line ||
              [ -n "$apor_status_line" ]; do
          log_info "[pipewire:user] $apor_status_line"
        done
    fi
  else
    log_info "Current PipeWire control-plane status:"

    if command -v wpctl >/dev/null 2>&1; then
      wpctl status 2>&1 |
        while IFS= read -r apor_status_line ||
              [ -n "$apor_status_line" ]; do
          log_info "[wpctl] $apor_status_line"
        done
    elif command -v pw-cli >/dev/null 2>&1; then
      pw-cli info 0 2>&1 |
        while IFS= read -r apor_status_line ||
              [ -n "$apor_status_line" ]; do
          log_info "[pw-cli] $apor_status_line"
        done
    fi
  fi

  return 1
}

# Install and activate the repository-owned Qualcomm AudioReach udev rule.
#
# Args:
#   $1 - 0 for base Audio mode
#        1 when --overlay was explicitly requested
#
# Platform behavior:
#   Debian overlay:
#     - installs the rule under /run/udev/rules.d
#     - reloads udev rules
#     - retriggers the dma_heap subsystem when available
#     - validates the resulting device ownership and mode
#
#   Debian base:
#     - no-op
#
#   Yocto/qcom-distro/other:
#     - strict no-op
#
# Returns:
#   0 - rule installed and active, device not currently enumerated, or not
#       applicable
#   1 - rule installation, activation, or validation failed
audio_prepare_audioreach_udev_rule() {
  apar_overlay_requested="${1:-0}"
  apar_rule_name="90-qcom-audioreach.rules"
  apar_rule_source=""
  apar_rule_dir="${AUDIO_UDEV_RUNTIME_RULE_DIR:-/run/udev/rules.d}"
  apar_rule_target="$apar_rule_dir/$apar_rule_name"
  apar_rule_tmp="${apar_rule_target}.$$"

  case "$apar_overlay_requested" in
    0)
      return 0
      ;;
    1)
      ;;
    *)
      log_fail "Invalid Audio overlay request value: $apar_overlay_requested"
      return 1
      ;;
  esac

  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    apar_os_id="$(pkg_detect_os_id 2>/dev/null || echo unknown)"
  else
    apar_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi

  [ -n "$apar_os_id" ] || apar_os_id="unknown"

  case "$apar_os_id" in
    debian)
      ;;
    qcom-distro|poky|openembedded|oe)
      log_info "Native image detected, AudioReach udev preparation is not required"
      return 0
      ;;
    *)
      log_info "AudioReach udev preparation is not enabled for os=$apar_os_id"
      return 0
      ;;
  esac

  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    log_fail "AudioReach udev rule preparation must run as root"
    return 1
  fi

  if ! command -v udevadm >/dev/null 2>&1; then
    log_fail "udevadm is unavailable, cannot activate AudioReach device rules"
    return 1
  fi

  if ! command -v stat >/dev/null 2>&1; then
    log_fail "stat is unavailable, cannot validate AudioReach device permissions"
    return 1
  fi

  if ! getent group audio >/dev/null 2>&1; then
    log_fail "Required Debian group does not exist: audio"
    return 1
  fi

  # Resolve the repository-owned rule without assuming a particular current
  # working directory.
  if [ -n "${ROOT_DIR:-}" ] &&
     [ -r "$ROOT_DIR/config/udev/$apar_rule_name" ]; then
    apar_rule_source="$ROOT_DIR/config/udev/$apar_rule_name"
  elif [ -n "${TOOLS:-}" ] &&
       [ -r "$TOOLS/../config/udev/$apar_rule_name" ]; then
    apar_rule_source="$TOOLS/../config/udev/$apar_rule_name"
  fi

  if [ -z "$apar_rule_source" ]; then
    log_fail "Repository-owned AudioReach udev rule was not found"
    log_fail "Expected rule: config/udev/$apar_rule_name"
    return 1
  fi

  if ! mkdir -p "$apar_rule_dir"; then
    log_fail "Failed to create runtime udev rule directory: $apar_rule_dir"
    return 1
  fi

  rm -f "$apar_rule_tmp"

  if ! cp "$apar_rule_source" "$apar_rule_tmp"; then
    log_fail "Failed to copy AudioReach udev rule to temporary path"
    rm -f "$apar_rule_tmp"
    return 1
  fi

  if ! chmod 0644 "$apar_rule_tmp"; then
    log_fail "Failed to set permissions on temporary AudioReach udev rule"
    rm -f "$apar_rule_tmp"
    return 1
  fi

  if ! mv "$apar_rule_tmp" "$apar_rule_target"; then
    log_fail "Failed to install runtime AudioReach udev rule"
    rm -f "$apar_rule_tmp"
    return 1
  fi

  log_pass "Installed runtime AudioReach udev rule: $apar_rule_target"

  log_info "Reloading udev rules"

  if ! audio_exec_with_timeout \
      10s \
      udevadm control --reload-rules 2>&1; then
    log_fail "Failed to reload udev rules"
    return 1
  fi

  if [ -d /sys/class/dma_heap ]; then
    log_info "Retriggering dma_heap devices"

    if ! audio_exec_with_timeout \
        15s \
        udevadm trigger \
          --action=change \
          --subsystem-match=dma_heap 2>&1; then
      log_fail "Failed to retrigger dma_heap devices"
      return 1
    fi
  else
    log_info "dma_heap subsystem is not currently enumerated, rule remains installed"
  fi

  log_info "Waiting for udev event processing to settle"

  if ! audio_exec_with_timeout \
      30s \
      udevadm settle 2>&1; then
    log_fail "udev did not settle after AudioReach rule activation"
    return 1
  fi

  # The node may not exist yet when the driver has not been loaded. Runtime
  # preparation performs the mandatory existence check later.
  if [ ! -e /dev/dma_heap/system ]; then
    log_info "/dev/dma_heap/system is not currently present, permission validation is deferred"
    return 0
  fi

  apar_dma_mode="$(
    stat -c '%a' /dev/dma_heap/system 2>/dev/null ||
      echo unknown
  )"

  apar_dma_owner="$(
    stat -c '%U:%G' /dev/dma_heap/system 2>/dev/null ||
      echo unknown
  )"

  log_info "/dev/dma_heap/system mode=$apar_dma_mode owner=$apar_dma_owner"

  if [ "$apar_dma_owner" != "root:audio" ]; then
    log_fail "/dev/dma_heap/system has incorrect ownership: $apar_dma_owner"
    log_fail "Expected ownership: root:audio"
    return 1
  fi

  if [ "$apar_dma_mode" != "660" ]; then
    log_fail "/dev/dma_heap/system has incorrect mode: $apar_dma_mode"
    log_fail "Expected mode: 660"
    return 1
  fi

  log_pass "/dev/dma_heap/system permissions are ready for the audio group"
  return 0
}

# Ensure packages needed by tests under Runner/suites/Multimedia/Audio.
#
# Reuses lib_pkg_provider.sh directly. No package-provider wrapper functions are
# added here.
#
# Args:
#   $1 - 0 for native/base mode, 1 when --overlay was explicitly requested
#
# Platform policy:
#   qcom-distro/Yocto - strict no-op
#   Debian base       - ensure the mapped audio-base package set
#   Debian overlay    - ensure audio-base and Debian AudioReach package sets
#   other distros     - no-op until their package mappings are verified
#
# Return:
#   0 - ready or not applicable
#   1 - package preparation failed
#   2 - AudioReach DKMS package changed; reboot required
audio_prepare_test_packages() {
  atp_overlay_requested="${1:-0}"
 
  if [ "$#" -gt 0 ]; then
    shift
  fi
 
  AUDIO_OVERLAY_PACKAGES_CHANGED=0
  AUDIO_OVERLAY_REBOOT_REQUIRED=0
 
  export AUDIO_OVERLAY_PACKAGES_CHANGED
  export AUDIO_OVERLAY_REBOOT_REQUIRED
 
  case "$atp_overlay_requested" in
    0|1)
      ;;
    *)
      log_fail "Invalid Audio overlay request value: $atp_overlay_requested"
      return 1
      ;;
  esac
 
  # Resolve the operating-system ID without making the package-provider
  # library mandatory on native embedded images.
  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    atp_os_id="$(
      pkg_detect_os_id 2>/dev/null ||
        echo unknown
    )"
  else
    atp_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi
 
  [ -n "$atp_os_id" ] || atp_os_id="unknown"
 
  case "$atp_os_id" in
    qcom-distro|poky|openembedded|oe)
      log_info "Native image detected, Audio package preparation is not required"
      return 0
      ;;
    debian)
      ;;
    *)
      log_info "Audio package preparation is not enabled for os=$atp_os_id"
      return 0
      ;;
  esac
 
  # Debian package preparation must run before the test is re-executed as the
  # unprivileged Audio user.
  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    log_fail "Debian Audio package preparation must run as root"
    return 1
  fi
 
  ###########################################################################
  # Debian base mode
  ###########################################################################
 
  if [ "$atp_overlay_requested" -eq 0 ]; then
    if ! command -v pkg_ensure_required_package_set_present \
        >/dev/null 2>&1; then
      log_fail "Required package-set helper is unavailable"
      return 1
    fi
 
    if ! pkg_ensure_required_package_set_present audio-base; then
      log_fail "Failed to ensure Debian base Audio package set"
      return 1
    fi
 
    log_pass "Debian base Audio package set is ready"
    return 0
  fi
 
  ###########################################################################
  # Debian AudioReach overlay mode
  ###########################################################################
 
  if ! command -v pkg_ensure_optional_package_set_present \
      >/dev/null 2>&1; then
    log_fail "Optional package-set helper is unavailable"
    return 1
  fi
 
  if ! command -v pkg_installed_package_version \
      >/dev/null 2>&1; then
    log_fail "Installed package-version helper is unavailable"
    return 1
  fi
 
  # Capture AudioReach package versions before package preparation. These
  # values let us distinguish an already-ready target from an install or
  # upgrade performed during this invocation.
  atp_before_plugin="$(
    pkg_installed_package_version \
      audioreach-pipewire-plugin 2>/dev/null ||
      true
  )"
 
  atp_before_dkms="$(
    pkg_installed_package_version \
      audioreach-kernel-dkms 2>/dev/null ||
      true
  )"
 
  atp_before_config="$(
    pkg_installed_package_version \
      audioreach-config 2>/dev/null ||
      true
  )"
 
  # The optional package provider intentionally requires the literal
  # --overlay argument. Passing only the internal value "1" makes the provider
  # treat the request as base mode.
  if ! pkg_ensure_optional_package_set_present \
      audio \
      qli-staging \
      auto \
      --overlay \
      "$@"; then
    log_fail "Failed to ensure Debian AudioReach package set"
    return 1
  fi
 
  atp_after_plugin="$(
    pkg_installed_package_version \
      audioreach-pipewire-plugin 2>/dev/null ||
      true
  )"
 
  atp_after_dkms="$(
    pkg_installed_package_version \
      audioreach-kernel-dkms 2>/dev/null ||
      true
  )"
 
  atp_after_config="$(
    pkg_installed_package_version \
      audioreach-config 2>/dev/null ||
      true
  )"
 
  if [ "$atp_before_plugin" != "$atp_after_plugin" ] ||
     [ "$atp_before_dkms" != "$atp_after_dkms" ] ||
     [ "$atp_before_config" != "$atp_after_config" ]; then
    AUDIO_OVERLAY_PACKAGES_CHANGED=1
    export AUDIO_OVERLAY_PACKAGES_CHANGED
 
    log_info "AudioReach package state changed during package preparation"
 
    if [ "$atp_before_plugin" != "$atp_after_plugin" ]; then
      log_info "AudioReach PipeWire plugin version changed: ${atp_before_plugin:-not-installed} -> ${atp_after_plugin:-not-installed}"
    fi
 
    if [ "$atp_before_config" != "$atp_after_config" ]; then
      log_info "AudioReach configuration version changed: ${atp_before_config:-not-installed} -> ${atp_after_config:-not-installed}"
    fi
 
    if [ "$atp_before_dkms" != "$atp_after_dkms" ]; then
      log_info "AudioReach DKMS version changed: ${atp_before_dkms:-not-installed} -> ${atp_after_dkms:-not-installed}"
    fi
  else
    log_info "AudioReach packages were already installed, runtime package state is unchanged"
  fi
 
  # Do not continue into Audio testing after installing or upgrading the DKMS
  # package. The active kernel must boot with the newly prepared module.
  if [ "$atp_before_dkms" != "$atp_after_dkms" ]; then
    AUDIO_OVERLAY_REBOOT_REQUIRED=1
    export AUDIO_OVERLAY_REBOOT_REQUIRED
 
    log_warn "AudioReach DKMS package changed"
    log_warn "A reboot is required before running AudioReach validation"
    return 2
  fi
  
  # Refresh module metadata when package state changed, then install and
  # activate the repository-owned AudioReach udev rule.
  if ! command -v audio_refresh_overlay_devices \
      >/dev/null 2>&1; then
    log_fail "AudioReach device-refresh helper is unavailable"
    return 1
  fi
 
  if ! audio_refresh_overlay_devices \
      "$atp_overlay_requested" \
      "$AUDIO_OVERLAY_PACKAGES_CHANGED"; then
    log_fail "Failed to refresh AudioReach devices"
    return 1
  fi
 
  log_pass "Debian AudioReach package set is ready"
  return 0
}

# Prepare the Debian Audio test user and optional systemd user manager.
#
# Unlike audio_prepare_debian_audio_test_user(), this function does not:
#   - re-execute the complete runner
#   - change ownership of result or log directories
#   - create or modify clip directories
#   - invoke runuser
#
# The calling test remains the root orchestrator. Individual audio commands
# will be executed as the Debian Audio user through audio_run_as_test_user().
#
# Args:
#   $1 - 1 when a PipeWire systemd user manager is required
#        0 for ALSA-only operations
#
# Platform behavior:
#   Debian:
#     - require root orchestration
#     - ensure AUDIO_TEST_USER belongs to audio
#     - optionally start or refresh user@UID.service
#     - export the resolved user-session environment
#
#   Yocto/qcom-distro/other:
#     - strict no-op
#
# Environment exported on Debian:
#   AUDIO_TEST_USER
#   AUDIO_TEST_UID
#   AUDIO_TEST_HOME
#   AUDIO_TEST_RUNTIME_DIR
#   AUDIO_TEST_DBUS_ADDRESS
#   AUDIO_SYSTEMCTL_USER_SCOPE
#
# Returns:
#   0 - preparation completed or not applicable
#   1 - preparation failed
audio_prepare_debian_audio_environment() {
  apdae_need_user_manager="${1:-0}"

  case "$apdae_need_user_manager" in
    0|1)
      ;;
    *)
      log_fail "Invalid Audio user-manager mode: $apdae_need_user_manager"
      return 1
      ;;
  esac

  ###########################################################################
  # Platform detection
  ###########################################################################

  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    apdae_os_id="$(
      pkg_detect_os_id 2>/dev/null ||
        echo unknown
    )"
  else
    apdae_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi

  [ -n "$apdae_os_id" ] || apdae_os_id="unknown"

  case "$apdae_os_id" in
    debian)
      ;;
    qcom-distro|poky|openembedded|oe)
      return 0
      ;;
    *)
      return 0
      ;;
  esac

  ###########################################################################
  # Root orchestration
  ###########################################################################

  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    log_fail "Debian Audio environment preparation must run as root"
    return 1
  fi

  apdae_user="${AUDIO_TEST_USER:-debian}"

  if ! id "$apdae_user" >/dev/null 2>&1; then
    log_fail "Debian Audio test user does not exist: $apdae_user"
    return 1
  fi

  if command -v getent >/dev/null 2>&1; then
    if ! getent group audio >/dev/null 2>&1; then
      log_fail "Required Debian group does not exist: audio"
      return 1
    fi
  elif ! grep -q '^audio:' /etc/group 2>/dev/null; then
    log_fail "Required Debian group does not exist: audio"
    return 1
  fi

  ###########################################################################
  # Audio-group membership
  ###########################################################################

  apdae_group_changed=0

  if id -nG "$apdae_user" 2>/dev/null |
      tr ' ' '\n' |
      grep -qx audio; then
    log_pass "User is already a member of audio: $apdae_user"
  else
    if ! command -v usermod >/dev/null 2>&1; then
      log_fail "usermod is unavailable, cannot configure Audio test user"
      return 1
    fi

    log_info "Adding Debian Audio test user to audio group: $apdae_user"

    if ! usermod -aG audio "$apdae_user"; then
      log_fail "Failed to add $apdae_user to the audio group"
      return 1
    fi

    apdae_group_changed=1

    if ! id -nG "$apdae_user" 2>/dev/null |
        tr ' ' '\n' |
        grep -qx audio; then
      log_fail "Audio-group membership was not applied to user: $apdae_user"
      return 1
    fi

    log_pass "Added user to audio group: $apdae_user"
  fi

  ###########################################################################
  # User account details
  ###########################################################################

  apdae_uid="$(id -u "$apdae_user" 2>/dev/null || true)"

  if [ -z "$apdae_uid" ]; then
    log_fail "Unable to resolve uid for Audio test user: $apdae_user"
    return 1
  fi

  if command -v getent >/dev/null 2>&1; then
    apdae_passwd_entry="$(
      getent passwd "$apdae_user" 2>/dev/null |
        sed -n '1p'
    )"
  else
    apdae_passwd_entry="$(
      awk -F: -v requested_user="$apdae_user" \
        '$1 == requested_user { print; exit }' \
        /etc/passwd 2>/dev/null
    )"
  fi

  apdae_home="$(
    printf '%s\n' "$apdae_passwd_entry" |
      awk -F: 'NR == 1 { print $6 }'
  )"

  [ -n "$apdae_home" ] || apdae_home="/home/$apdae_user"

  apdae_runtime_dir="/run/user/$apdae_uid"
  apdae_bus_address="unix:path=$apdae_runtime_dir/bus"

  ###########################################################################
  # Optional systemd user-manager preparation
  ###########################################################################

  if [ "$apdae_need_user_manager" -eq 1 ]; then
    if ! command -v systemctl >/dev/null 2>&1; then
      log_fail "systemctl is unavailable, cannot prepare PipeWire user services"
      return 1
    fi

    if [ ! -d /run/systemd/system ]; then
      log_fail "systemd is not running, cannot prepare PipeWire user services"
      return 1
    fi

    apdae_user_unit="user@${apdae_uid}.service"

    if systemctl is-active --quiet "$apdae_user_unit"; then
      if [ "$apdae_group_changed" -eq 1 ]; then
        log_info "Restarting Debian user manager after audio-group update: $apdae_user_unit"

        if command -v audio_exec_with_timeout >/dev/null 2>&1; then
          audio_exec_with_timeout \
            30s \
            systemctl restart "$apdae_user_unit"
          apdae_systemctl_rc=$?
        else
          systemctl restart "$apdae_user_unit"
          apdae_systemctl_rc=$?
        fi

        if [ "$apdae_systemctl_rc" -ne 0 ]; then
          log_fail "Failed to restart Debian user manager: $apdae_user_unit"
          return 1
        fi
      else
        log_pass "Debian user manager is already active: $apdae_user_unit"
      fi
    else
      log_info "Starting Debian user manager: $apdae_user_unit"

      systemctl reset-failed \
        "$apdae_user_unit" \
        >/dev/null 2>&1 || true

      if command -v audio_exec_with_timeout >/dev/null 2>&1; then
        audio_exec_with_timeout \
          30s \
          systemctl start "$apdae_user_unit"
        apdae_systemctl_rc=$?
      else
        systemctl start "$apdae_user_unit"
        apdae_systemctl_rc=$?
      fi

      if [ "$apdae_systemctl_rc" -ne 0 ]; then
        log_fail "Failed to start Debian user manager: $apdae_user_unit"

        systemctl status \
          "$apdae_user_unit" \
          --no-pager \
          --full 2>&1 |
          while IFS= read -r apdae_line ||
                [ -n "$apdae_line" ]; do
            log_info "[systemctl:user-manager] $apdae_line"
          done

        return 1
      fi
    fi

    apdae_wait=0
    apdae_wait_timeout="${AUDIO_USER_MANAGER_READY_TIMEOUT:-30}"

    case "$apdae_wait_timeout" in
      ''|*[!0-9]*)
        apdae_wait_timeout=30
        ;;
    esac

    log_info "Waiting for Debian user runtime and D-Bus, timeout=${apdae_wait_timeout}s"

    while [ "$apdae_wait" -lt "$apdae_wait_timeout" ]; do
      if [ -d "$apdae_runtime_dir" ] &&
         [ -S "$apdae_runtime_dir/bus" ]; then
        break
      fi

      sleep 1
      apdae_wait=$((apdae_wait + 1))
    done

    if [ ! -d "$apdae_runtime_dir" ]; then
      log_fail "Debian user runtime directory is unavailable: $apdae_runtime_dir"
      return 1
    fi

    if [ ! -S "$apdae_runtime_dir/bus" ]; then
      log_fail "Debian user D-Bus is unavailable: $apdae_runtime_dir/bus"
      return 1
    fi

    log_pass "Debian user runtime is ready: $apdae_runtime_dir"
  fi

  ###########################################################################
  # Export resolved environment for command-level user execution
  ###########################################################################

  AUDIO_TEST_USER="$apdae_user"
  AUDIO_TEST_UID="$apdae_uid"
  AUDIO_TEST_HOME="$apdae_home"
  AUDIO_TEST_RUNTIME_DIR="$apdae_runtime_dir"
  AUDIO_TEST_DBUS_ADDRESS="$apdae_bus_address"
  AUDIO_SYSTEMCTL_USER_SCOPE=1

  export AUDIO_TEST_USER
  export AUDIO_TEST_UID
  export AUDIO_TEST_HOME
  export AUDIO_TEST_RUNTIME_DIR
  export AUDIO_TEST_DBUS_ADDRESS
  export AUDIO_SYSTEMCTL_USER_SCOPE

  log_pass "Debian Audio environment prepared: user=$apdae_user uid=$apdae_uid"
  return 0
}

# Execute one Audio command as the configured Debian Audio user.
#
# The main test runner remains the root orchestrator. Only the supplied command
# is executed as the Debian user.
#
# Usage:
#   audio_run_as_test_user command [args...]
#
#   audio_run_as_test_user \
#     --require-session \
#     command [args...]
#
# Options:
#   --require-session
#       Require the prepared systemd user runtime and D-Bus socket. Use this
#       for PipeWire and systemctl --user commands.
#
#       It is not required for direct ALSA commands such as aplay and arecord.
#
# Platform behavior:
#   Debian:
#     - require the caller to be root
#     - verify the configured Audio user and audio-group membership
#     - execute only the supplied command through runuser
#
#   Yocto/qcom-distro/other:
#     - execute the command directly as the current user
#
# Prerequisite on Debian:
#   audio_prepare_debian_audio_environment must run before this helper.
#
# Returns:
#   The exact exit status of the supplied command.
#   1 when user/session preparation is invalid.
audio_run_as_test_user() {
  aratu_require_session=0

  case "${1:-}" in
    --require-session)
      aratu_require_session=1
      shift
      ;;
  esac

  if [ "$#" -eq 0 ]; then
    log_fail "audio_run_as_test_user requires a command"
    return 1
  fi

  ###########################################################################
  # Platform detection
  ###########################################################################

  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    aratu_os_id="$(
      pkg_detect_os_id 2>/dev/null ||
        echo unknown
    )"
  else
    aratu_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi

  [ -n "$aratu_os_id" ] || aratu_os_id="unknown"

  case "$aratu_os_id" in
    debian)
      ;;
    *)
      # Preserve existing native/Yocto execution behavior.
      "$@"
      return $?
      ;;
  esac

  ###########################################################################
  # Debian root orchestration validation
  ###########################################################################

  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    log_fail "Debian Audio command execution must be initiated by root"
    return 1
  fi

  if ! command -v runuser >/dev/null 2>&1; then
    log_fail "runuser is unavailable, cannot execute an Audio command as the Debian user"
    return 1
  fi

  aratu_user="${AUDIO_TEST_USER:-debian}"

  if ! id "$aratu_user" >/dev/null 2>&1; then
    log_fail "Debian Audio test user does not exist: $aratu_user"
    return 1
  fi

  if ! id -nG "$aratu_user" 2>/dev/null |
      tr ' ' '\n' |
      grep -qx audio; then
    log_fail "Debian Audio test user is not a member of audio: $aratu_user"
    log_fail "Call audio_prepare_debian_audio_environment before running user commands"
    return 1
  fi

  ###########################################################################
  # Resolve user account details
  ###########################################################################

  aratu_uid="$(id -u "$aratu_user" 2>/dev/null || true)"

  if [ -z "$aratu_uid" ]; then
    log_fail "Unable to resolve uid for Debian Audio test user: $aratu_user"
    return 1
  fi

  aratu_home="${AUDIO_TEST_HOME:-}"
  aratu_shell=""

  if command -v getent >/dev/null 2>&1; then
    aratu_passwd_entry="$(
      getent passwd "$aratu_user" 2>/dev/null |
        sed -n '1p'
    )"
  else
    aratu_passwd_entry="$(
      awk -F: -v requested_user="$aratu_user" \
        '$1 == requested_user { print; exit }' \
        /etc/passwd 2>/dev/null
    )"
  fi

  if [ -z "$aratu_home" ]; then
    aratu_home="$(
      printf '%s\n' "$aratu_passwd_entry" |
        awk -F: 'NR == 1 { print $6 }'
    )"
  fi

  aratu_shell="$(
    printf '%s\n' "$aratu_passwd_entry" |
      awk -F: 'NR == 1 { print $7 }'
  )"

  [ -n "$aratu_home" ] || aratu_home="/home/$aratu_user"
  [ -n "$aratu_shell" ] || aratu_shell="/bin/sh"

  aratu_runtime_dir="$(
    printf '%s\n' \
      "${AUDIO_TEST_RUNTIME_DIR:-/run/user/$aratu_uid}"
  )"

  aratu_bus_address="$(
    printf '%s\n' \
      "${AUDIO_TEST_DBUS_ADDRESS:-unix:path=$aratu_runtime_dir/bus}"
  )"

  ###########################################################################
  # Optional user-session validation
  ###########################################################################

  if [ "$aratu_require_session" -eq 1 ]; then
    if [ ! -d "$aratu_runtime_dir" ]; then
      log_fail "Debian Audio user runtime directory is unavailable: $aratu_runtime_dir"
      return 1
    fi

    if [ ! -S "$aratu_runtime_dir/bus" ]; then
      log_fail "Debian Audio user D-Bus socket is unavailable: $aratu_runtime_dir/bus"
      return 1
    fi
  fi

  ###########################################################################
  # Execute only the requested command as the Debian Audio user
  ###########################################################################

  case "${VERBOSE:-0}" in
    1)
      log_info "Running Audio command as user=$aratu_user: $1"
      ;;
  esac

  runuser \
    -u "$aratu_user" \
    -- \
    env \
      HOME="$aratu_home" \
      USER="$aratu_user" \
      LOGNAME="$aratu_user" \
      SHELL="$aratu_shell" \
      TMPDIR="/tmp" \
      XDG_RUNTIME_DIR="$aratu_runtime_dir" \
      DBUS_SESSION_BUS_ADDRESS="$aratu_bus_address" \
      AUDIO_TEST_USER="$aratu_user" \
      AUDIO_TEST_UID="$aratu_uid" \
      AUDIO_TEST_HOME="$aratu_home" \
      AUDIO_TEST_RUNTIME_DIR="$aratu_runtime_dir" \
      AUDIO_TEST_DBUS_ADDRESS="$aratu_bus_address" \
      AUDIO_TEST_COMMAND_USER_CONTEXT=1 \
      "$@"

  return $?
}

# Execute one existing audio_common.sh helper as the Debian Audio user.
#
# This preserves helper/library reuse while keeping the main test runner as the
# root orchestrator. On native/Yocto systems, the already-sourced helper is
# called directly in the current shell.
#
# Usage:
#   audio_run_helper_as_test_user helper [args...]
#   audio_run_helper_as_test_user --require-session helper [args...]
#
# Returns:
#   The exact helper exit status.
#   1 for invalid arguments or missing preparation.
#   127 when the requested helper is unavailable in the child shell.
audio_run_helper_as_test_user() {
  arhatu_require_session=0

  case "${1:-}" in
    --require-session)
      arhatu_require_session=1
      shift
      ;;
  esac

  if [ "$#" -eq 0 ]; then
    log_fail "audio_run_helper_as_test_user requires a helper name"
    return 1
  fi

  arhatu_helper="$1"
  shift

  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    arhatu_os_id="$(
      pkg_detect_os_id 2>/dev/null ||
        echo unknown
    )"
  else
    arhatu_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi

  [ -n "$arhatu_os_id" ] || arhatu_os_id="unknown"

  case "$arhatu_os_id" in
    debian)
      ;;
    *)
      "$arhatu_helper" "$@"
      return $?
      ;;
  esac

  if ! command -v audio_run_as_test_user >/dev/null 2>&1; then
    log_fail "Audio user-command helper is unavailable"
    return 1
  fi

  if [ -z "${TOOLS:-}" ] ||
     [ ! -r "$TOOLS/functestlib.sh" ] ||
     [ ! -r "$TOOLS/audio_common.sh" ]; then
    log_fail "Audio helper libraries are unavailable in TOOLS=${TOOLS:-<unset>}"
    return 1
  fi

  if [ "$arhatu_require_session" -eq 1 ]; then
    # Variables in this command script are intentionally expanded by the child shell.
    # shellcheck disable=SC2016
    audio_run_as_test_user \
      --require-session \
      sh -c '
        helper=$1
        shift

        . "$TOOLS/functestlib.sh"
        . "$TOOLS/audio_common.sh"

        if ! command -v "$helper" >/dev/null 2>&1; then
          exit 127
        fi

        "$helper" "$@"
      ' \
      sh \
      "$arhatu_helper" \
      "$@"
  else
    # Variables in this command script are intentionally expanded by the child shell.
    # shellcheck disable=SC2016
    audio_run_as_test_user \
      sh -c '
        helper=$1
        shift

        . "$TOOLS/functestlib.sh"
        . "$TOOLS/audio_common.sh"

        if ! command -v "$helper" >/dev/null 2>&1; then
          exit 127
        fi

        "$helper" "$@"
      ' \
      sh \
      "$arhatu_helper" \
      "$@"
  fi

  return $?
}

# Execute one command through audio_exec_with_timeout as the Debian Audio user.
# Root opens any surrounding redirection before this helper is called, so test
# logs and result files remain root-owned.
#
# Usage:
#   audio_run_with_timeout_as_test_user TIMEOUT command [args...]
#   audio_run_with_timeout_as_test_user --require-session TIMEOUT command [args...]
audio_run_with_timeout_as_test_user() {
  arwtatu_require_session=0

  case "${1:-}" in
    --require-session)
      arwtatu_require_session=1
      shift
      ;;
  esac

  if [ "$#" -lt 2 ]; then
    log_fail "audio_run_with_timeout_as_test_user requires TIMEOUT and command"
    return 1
  fi

  arwtatu_timeout="$1"
  shift

  if [ "$arwtatu_require_session" -eq 1 ]; then
    audio_run_helper_as_test_user \
      --require-session \
      audio_exec_with_timeout \
      "$arwtatu_timeout" \
      "$@"
  else
    audio_run_helper_as_test_user \
      audio_exec_with_timeout \
      "$arwtatu_timeout" \
      "$@"
  fi

  return $?
}

# AudioRecord root-orchestrator helpers
#
# Insert this block into Runner/utils/audio_common.sh after
# audio_run_with_timeout_as_test_user().
#
# These helpers are intentionally shared because they implement backend recovery,
# Debian-user capture workspace handling, mixer collection, and ALSA profile
# propagation. They do not parse AudioRecord CLI options or emit final results.

audio_record_restart_backend_best_effort() {
  arbbe_backend="$1"

  if [ "${AUDIO_RECORD_DEBIAN_ROOT_MODE:-0}" -ne 1 ]; then
    audio_restart_services_best_effort
    return $?
  fi

  case "$arbbe_backend" in
    pipewire)
      audio_restart_pipewire_service "1/1"
      ;;
    pulseaudio)
      audio_run_as_test_user \
        --require-session \
        systemctl --user restart pulseaudio
      ;;
    *)
      return 1
      ;;
  esac
}

# On Debian, manual daemon bootstrap is replaced by one user-service recovery
# attempt. Native and minimal Yocto images retain their existing bootstrap path.
audio_record_bootstrap_backend_if_needed() {
  if [ "${AUDIO_RECORD_DEBIAN_ROOT_MODE:-0}" -ne 1 ]; then
    audio_bootstrap_backend_if_needed
    return $?
  fi

  case "${AUDIO_BACKEND:-pipewire}" in
    pipewire|'')
      audio_restart_pipewire_service "1/1"
      ;;
    pulseaudio)
      audio_run_as_test_user \
        --require-session \
        systemctl --user restart pulseaudio
      ;;
    *)
      return 1
      ;;
  esac
}

# Record whether a recovered backend is managed by the Debian user manager or
# by the native/minimal-image bootstrap path.
audio_record_set_recovered_backend_management() {
  if [ "${AUDIO_RECORD_DEBIAN_ROOT_MODE:-0}" -eq 1 ]; then
    AUDIO_SYSTEMD_MANAGED=1
  else
    AUDIO_SYSTEMD_MANAGED=0
  fi

  export AUDIO_SYSTEMD_MANAGED
}

# Resolve the root-owned final WAV and the Debian-user scratch WAV for one case.
audio_record_set_capture_paths() {
  arcsp_case_name="$1"

  record_out="$LOGDIR/${arcsp_case_name}.wav"

  if [ "${AUDIO_RECORD_DEBIAN_ROOT_MODE:-0}" -eq 1 ]; then
    record_user_out="$AUDIO_RECORD_USER_CAPTURE_DIR/${arcsp_case_name}.wav"
  else
    record_user_out="$record_out"
  fi
}

# Remove the previous scratch WAV without pre-creating a root-owned file.
audio_record_reset_capture_output() {
  rm -f "$record_user_out"
}

# Return the current scratch WAV size.
audio_record_capture_size() {
  file_size_bytes "$record_user_out" 2>/dev/null || echo 0
}

# Move the Debian-user scratch WAV into the root-owned final results directory.
# When no scratch file was produced, create an empty final file so the existing
# WAV validator can report the backend failure consistently.
audio_record_promote_capture_output() {
  if [ "$record_user_out" = "$record_out" ]; then
    return 0
  fi

  rm -f "$record_out"

  if [ -f "$record_user_out" ]; then
    if ! mv "$record_user_out" "$record_out"; then
      log_fail "Failed to promote captured WAV into final results: $record_out"
      return 1
    fi

    if ! chown 0:0 "$record_out"; then
      log_fail "Failed to restore root ownership on captured WAV: $record_out"
      return 1
    fi

    if ! chmod 0644 "$record_out"; then
      log_fail "Failed to set captured WAV permissions: $record_out"
      return 1
    fi
  else
    if ! : >"$record_out"; then
      log_fail "Failed to initialize missing capture result: $record_out"
      return 1
    fi
  fi

  return 0
}

# Collect user-session mixer/control information while root owns the output file.
audio_record_dump_mixers() {
  ardm_out="$1"

  if [ "${AUDIO_RECORD_DEBIAN_ROOT_MODE:-0}" -ne 1 ]; then
    dump_mixers "$ardm_out"
    return $?
  fi

  if [ "${AUDIO_RECORD_USER_MANAGER_REQUIRED:-1}" -ne 1 ]; then
    {
      echo "---- wpctl status ----"
      echo "(PipeWire user session was not requested for this ALSA-only run)"
      echo "---- pactl list ----"
      echo "(PulseAudio user session was not requested for this ALSA-only run)"
    } >"$ardm_out" 2>/dev/null
    return 0
  fi

  {
    echo "---- wpctl status ----"
    if command -v wpctl >/dev/null 2>&1; then
      audio_run_with_timeout_as_test_user \
        --require-session \
        2s \
        wpctl status 2>&1 ||
        echo "(wpctl status failed/timeout)"
    else
      echo "(wpctl not found)"
    fi

    echo "---- pactl list ----"
    if command -v pactl >/dev/null 2>&1; then
      audio_run_with_timeout_as_test_user \
        --require-session \
        3s \
        pactl list 2>&1 ||
        echo "(pactl list failed/timeout)"
    else
      echo "(pactl not found)"
    fi
  } >"$ardm_out" 2>/dev/null
}

# Run one capture probe in the correct user context and copy its profile into
# the root orchestrator.
audio_record_probe_alsa_capture_profile_once() {
  if [ "${AUDIO_RECORD_DEBIAN_ROOT_MODE:-0}" -ne 1 ]; then
    audio_probe_alsa_capture_profile
    return $?
  fi

  arpacp_output="$(
    # Variables in this command script are intentionally expanded by the child shell.
    # shellcheck disable=SC2016
    audio_run_as_test_user \
      sh -c '
        . "$TOOLS/functestlib.sh"
        . "$TOOLS/audio_common.sh"

        audio_probe_alsa_capture_profile >/dev/null 2>&1
        probe_rc=$?

        printf "%s\n" \
          "${AUDIO_ALSA_CAPTURE_DEVICE:-}" \
          "${AUDIO_ALSA_CAPTURE_FORMAT:-}" \
          "${AUDIO_ALSA_CAPTURE_RATE:-}" \
          "${AUDIO_ALSA_CAPTURE_CHANNELS:-}" \
          "${AUDIO_ALSA_CAPTURE_REASON:-}"

        exit "$probe_rc"
      '
  )"
  arpacp_rc=$?

  AUDIO_ALSA_CAPTURE_DEVICE="$(
    printf '%s\n' "$arpacp_output" |
      sed -n '1p'
  )"
  AUDIO_ALSA_CAPTURE_FORMAT="$(
    printf '%s\n' "$arpacp_output" |
      sed -n '2p'
  )"
  AUDIO_ALSA_CAPTURE_RATE="$(
    printf '%s\n' "$arpacp_output" |
      sed -n '3p'
  )"
  AUDIO_ALSA_CAPTURE_CHANNELS="$(
    printf '%s\n' "$arpacp_output" |
      sed -n '4p'
  )"
  AUDIO_ALSA_CAPTURE_REASON="$(
    printf '%s\n' "$arpacp_output" |
      sed -n '5,$p'
  )"

  export AUDIO_ALSA_CAPTURE_DEVICE
  export AUDIO_ALSA_CAPTURE_FORMAT
  export AUDIO_ALSA_CAPTURE_RATE
  export AUDIO_ALSA_CAPTURE_CHANNELS
  export AUDIO_ALSA_CAPTURE_REASON

  return "$arpacp_rc"
}

# Retry capture discovery after a narrowly guarded audio-DSP startup. Recovery
# is attempted once and only when ALSA exposes no capture PCM at all.
audio_record_probe_alsa_capture_profile() {
  if audio_record_probe_alsa_capture_profile_once; then
    return 0
  fi

  if [ "${AUDIO_ALSA_CAPTURE_REASON:-}" != \
       "no ALSA capture device candidates found" ]; then
    return 1
  fi

  if [ "${AUDIO_DSP_RECOVERY_ATTEMPTED:-0}" -eq 1 ]; then
    return 1
  fi

  AUDIO_DSP_RECOVERY_ATTEMPTED=1
  export AUDIO_DSP_RECOVERY_ATTEMPTED

  if ! audio_recover_offline_dsp; then
    AUDIO_ALSA_CAPTURE_REASON="$AUDIO_ALSA_CAPTURE_REASON, ${AUDIO_DSP_RECOVERY_REASON:-audio DSP recovery was not applicable}"
    export AUDIO_ALSA_CAPTURE_REASON
    return 1
  fi

  arpacp_wait=0
  while [ "$arpacp_wait" -lt 10 ]; do
    if audio_alsa_capture_inventory_available; then
      break
    fi

    sleep 1
    arpacp_wait=$((arpacp_wait + 1))
  done

  if audio_record_probe_alsa_capture_profile_once; then
    return 0
  fi

  if [ "${AUDIO_ALSA_CAPTURE_REASON:-}" = \
       "no ALSA capture device candidates found" ]; then
    AUDIO_ALSA_CAPTURE_REASON="$AUDIO_ALSA_CAPTURE_REASON after audio DSP startup"
    export AUDIO_ALSA_CAPTURE_REASON
  fi

  return 1
}

# Prepare the Debian Audio test user and re-execute the current test as that
# user.
#
# Package preparation must complete successfully before calling this function.
# This helper does not install packages.
#
# Args:
# $1 - absolute path to the current run.sh
# $2 - result file path
# $3 - test-specific log/output directory
# $4 - 1 when the test requires PipeWire user services
# 0 for ALSA-only tests such as Audio_Card_Registration
# $5... - original run.sh arguments
#
# Platform behavior:
# Debian:
# - initial process must run as root
# - ensures AUDIO_TEST_USER belongs to the audio group
# - prepares test-owned result/output paths
# - starts or refreshes user@UID.service when requested
# - re-executes the runner as AUDIO_TEST_USER
#
# Yocto/qcom-distro/other:
# - strict no-op
#
# Environment:
# AUDIO_TEST_USER
# Debian test user; default: debian
#
# AUDIO_TEST_USER_REEXEC
# Internal recursion guard.
#
# AUDIO_PACKAGE_PREPARED
# Marks package preparation as already completed by root.
#
# AUDIO_SYSTEMCTL_USER_SCOPE
# Selects systemctl --user for PipeWire service operations.
#
# Returns:
# 0 - not applicable or already executing as the prepared Debian user
# 1 - user, output-path, or user-manager preparation failed
#
# A successful root-to-user transition uses exec and therefore does not return.
audio_prepare_debian_audio_test_user() {
  if [ "$#" -lt 4 ]; then
    log_fail "audio_prepare_debian_audio_test_user requires runner, result file, log directory, and user-manager mode"
    return 1
  fi

  apdatu_script="$1"
  apdatu_res_file="$2"
  apdatu_log_dir="$3"
  apdatu_need_user_manager="$4"

  shift 4

  ###########################################################################
  # Platform detection
  ###########################################################################

  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    apdatu_os_id="$(
      pkg_detect_os_id 2>/dev/null ||
        echo unknown
    )"
  else
    apdatu_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi

  [ -n "$apdatu_os_id" ] || apdatu_os_id="unknown"

  case "$apdatu_os_id" in
    debian)
      ;;
    qcom-distro|poky|openembedded|oe)
      # Preserve all native-image execution behavior.
      return 0
      ;;
    *)
      # User switching is intentionally limited to verified Debian images.
      return 0
      ;;
  esac

  case "$apdatu_need_user_manager" in
    0|1)
      ;;
    *)
      log_fail "Invalid Audio user-manager mode: $apdatu_need_user_manager"
      return 1
      ;;
  esac

  apdatu_user="${AUDIO_TEST_USER:-debian}"
  apdatu_current_uid="$(id -u 2>/dev/null || echo 1)"
  apdatu_current_user="$(id -un 2>/dev/null || echo unknown)"

  ###########################################################################
  # Re-executed Debian child
  ###########################################################################

  if [ "${AUDIO_TEST_USER_REEXEC:-0}" -eq 1 ]; then
    if [ "$apdatu_current_user" != "$apdatu_user" ]; then
      log_fail "Audio user re-exec mismatch: expected=$apdatu_user actual=$apdatu_current_user"
      return 1
    fi

    if ! id -nG "$apdatu_user" 2>/dev/null |
        tr ' ' '\n' |
        grep -qx audio; then
      log_fail "Debian Audio test user is not a member of audio: $apdatu_user"
      return 1
    fi

    apdatu_uid="$(id -u "$apdatu_user" 2>/dev/null || true)"

    if [ -z "$apdatu_uid" ]; then
      log_fail "Unable to resolve uid for Debian Audio test user: $apdatu_user"
      return 1
    fi

    XDG_RUNTIME_DIR="/run/user/$apdatu_uid"
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$apdatu_uid/bus"
    AUDIO_TEST_UID="$apdatu_uid"
    AUDIO_SYSTEMCTL_USER_SCOPE=1

    export XDG_RUNTIME_DIR
    export DBUS_SESSION_BUS_ADDRESS
    export AUDIO_TEST_UID
    export AUDIO_SYSTEMCTL_USER_SCOPE

    if [ "$apdatu_need_user_manager" -eq 1 ]; then
      if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        log_fail "Debian user runtime directory is missing: $XDG_RUNTIME_DIR"
        return 1
      fi

      if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
        log_fail "Debian user D-Bus is unavailable: $XDG_RUNTIME_DIR/bus"
        return 1
      fi
    fi

    log_pass "Audio test is running as Debian user: user=$apdatu_user uid=$apdatu_uid"
    return 0
  fi

  ###########################################################################
  # Initial Debian process must be root
  ###########################################################################

  if [ "$apdatu_current_uid" -ne 0 ]; then
    log_fail "Debian Audio tests must initially run as root"
    log_fail "Package preparation and Audio user setup require root privileges"
    return 1
  fi

  if [ -z "$apdatu_script" ] || [ ! -f "$apdatu_script" ]; then
    log_fail "Audio runner was not found: $apdatu_script"
    return 1
  fi

  if [ ! -x "$apdatu_script" ]; then
    log_fail "Audio runner is not executable: $apdatu_script"
    return 1
  fi

  if ! id "$apdatu_user" >/dev/null 2>&1; then
    log_fail "Debian Audio test user does not exist: $apdatu_user"
    return 1
  fi

  if command -v getent >/dev/null 2>&1; then
    if ! getent group audio >/dev/null 2>&1; then
      log_fail "Required Debian group does not exist: audio"
      return 1
    fi
  elif ! grep -q '^audio:' /etc/group 2>/dev/null; then
    log_fail "Required Debian group does not exist: audio"
    return 1
  fi

  ###########################################################################
  # Audio-group membership
  ###########################################################################

  apdatu_group_changed=0

  if id -nG "$apdatu_user" 2>/dev/null |
      tr ' ' '\n' |
      grep -qx audio; then
    log_pass "User is already a member of audio: $apdatu_user"
  else
    if ! command -v usermod >/dev/null 2>&1; then
      log_fail "usermod is unavailable, cannot configure Audio test user"
      return 1
    fi

    log_info "Adding Debian Audio test user to audio group: $apdatu_user"

    if ! usermod -aG audio "$apdatu_user"; then
      log_fail "Failed to add $apdatu_user to the audio group"
      return 1
    fi

    apdatu_group_changed=1

    if ! id -nG "$apdatu_user" 2>/dev/null |
        tr ' ' '\n' |
        grep -qx audio; then
      log_fail "Audio-group membership was not applied to user: $apdatu_user"
      return 1
    fi

    log_pass "Added user to audio group: $apdatu_user"
  fi

  apdatu_uid="$(id -u "$apdatu_user" 2>/dev/null || true)"

  if [ -z "$apdatu_uid" ]; then
    log_fail "Unable to resolve uid for Debian Audio test user: $apdatu_user"
    return 1
  fi

  if command -v getent >/dev/null 2>&1; then
    apdatu_passwd_entry="$(
      getent passwd "$apdatu_user" 2>/dev/null |
        sed -n '1p'
    )"
  else
    apdatu_passwd_entry="$(
      awk -F: -v requested_user="$apdatu_user" \
        '$1 == requested_user { print; exit }' \
        /etc/passwd 2>/dev/null
    )"
  fi

  apdatu_home="$(
    printf '%s\n' "$apdatu_passwd_entry" |
      awk -F: 'NR == 1 { print $6 }'
  )"

  apdatu_shell="$(
    printf '%s\n' "$apdatu_passwd_entry" |
      awk -F: 'NR == 1 { print $7 }'
  )"

  [ -n "$apdatu_home" ] || apdatu_home="/home/$apdatu_user"
  [ -n "$apdatu_shell" ] || apdatu_shell="/bin/sh"

  ###########################################################################
  # Prepare test-owned output paths
  ###########################################################################

  if [ -n "$apdatu_res_file" ]; then
    apdatu_res_parent="$(dirname "$apdatu_res_file")"

    if ! mkdir -p "$apdatu_res_parent"; then
      log_fail "Failed to create result-file directory: $apdatu_res_parent"
      return 1
    fi

    if ! : >"$apdatu_res_file"; then
      log_fail "Failed to prepare result file: $apdatu_res_file"
      return 1
    fi

    if ! chown "$apdatu_user:audio" "$apdatu_res_file"; then
      log_fail "Failed to assign result file to $apdatu_user:audio"
      return 1
    fi

    if ! chmod 0664 "$apdatu_res_file"; then
      log_fail "Failed to set result-file permissions: $apdatu_res_file"
      return 1
    fi

    log_pass "Prepared Audio result file for user=$apdatu_user: $apdatu_res_file"
  fi

  if [ -n "$apdatu_log_dir" ]; then
    case "$apdatu_log_dir" in
      /)
        log_fail "Refusing to use the filesystem root as an Audio log directory"
        return 1
        ;;
    esac

    if ! mkdir -p "$apdatu_log_dir"; then
      log_fail "Failed to create Audio log directory: $apdatu_log_dir"
      return 1
    fi

    apdatu_script_dir="$(
      cd "$(dirname "$apdatu_script")" 2>/dev/null &&
        pwd
    )"

    apdatu_log_dir_abs="$(
      cd "$apdatu_log_dir" 2>/dev/null &&
        pwd
    )"

    if [ -n "$apdatu_script_dir" ] &&
       [ "$apdatu_log_dir_abs" = "$apdatu_script_dir" ]; then
      log_fail "Refusing to recursively change ownership of the runner directory"
      log_fail "Use a dedicated test-specific LOGDIR"
      return 1
    fi

    if ! chown -R "$apdatu_user:audio" "$apdatu_log_dir"; then
      log_fail "Failed to assign Audio log directory to $apdatu_user:audio"
      return 1
    fi

    if ! chmod u+rwx "$apdatu_log_dir"; then
      log_fail "Failed to make Audio log directory writable by $apdatu_user"
      return 1
    fi

    log_pass "Prepared Audio log directory for user=$apdatu_user: $apdatu_log_dir"
  fi

  ###########################################################################
  # PipeWire user-manager preparation
  ###########################################################################

  if [ "$apdatu_need_user_manager" -eq 1 ]; then
    if ! command -v systemctl >/dev/null 2>&1; then
      log_fail "systemctl is unavailable, cannot prepare PipeWire user services"
      return 1
    fi

    if [ ! -d /run/systemd/system ]; then
      log_fail "systemd is not running, cannot prepare PipeWire user services"
      return 1
    fi

    apdatu_user_unit="user@${apdatu_uid}.service"

    if systemctl is-active --quiet "$apdatu_user_unit"; then
      if [ "$apdatu_group_changed" -eq 1 ]; then
        # The existing user manager was started before the audio-group update.
        # Restart it so PipeWire inherits the new supplementary group.
        log_info "Restarting Debian user manager after audio-group update: $apdatu_user_unit"

        if command -v audio_exec_with_timeout >/dev/null 2>&1; then
          audio_exec_with_timeout \
            30s \
            systemctl restart "$apdatu_user_unit"
          apdatu_systemctl_rc=$?
        else
          systemctl restart "$apdatu_user_unit"
          apdatu_systemctl_rc=$?
        fi

        if [ "$apdatu_systemctl_rc" -ne 0 ]; then
          log_fail "Failed to restart Debian user manager: $apdatu_user_unit"
          return 1
        fi
      else
        log_pass "Debian user manager is already active: $apdatu_user_unit"
      fi
    else
      log_info "Starting Debian user manager: $apdatu_user_unit"

      # Clear a previous failed state before attempting a new start.
      systemctl reset-failed "$apdatu_user_unit" 2>/dev/null || true

      if command -v audio_exec_with_timeout >/dev/null 2>&1; then
        audio_exec_with_timeout \
          30s \
          systemctl start "$apdatu_user_unit"
        apdatu_systemctl_rc=$?
      else
        systemctl start "$apdatu_user_unit"
        apdatu_systemctl_rc=$?
      fi

      if [ "$apdatu_systemctl_rc" -ne 0 ]; then
        log_fail "Failed to start Debian user manager: $apdatu_user_unit"

        systemctl status \
          "$apdatu_user_unit" \
          --no-pager \
          --full 2>&1 |
          while IFS= read -r apdatu_line ||
                [ -n "$apdatu_line" ]; do
            log_info "[systemctl:user-manager] $apdatu_line"
          done

        return 1
      fi
    fi

    apdatu_runtime_dir="/run/user/$apdatu_uid"
    apdatu_bus_path="$apdatu_runtime_dir/bus"
    apdatu_wait=0
    apdatu_wait_timeout="${AUDIO_USER_MANAGER_READY_TIMEOUT:-30}"

    case "$apdatu_wait_timeout" in
      ''|*[!0-9]*)
        apdatu_wait_timeout=30
        ;;
    esac

    log_info "Waiting for Debian user runtime and D-Bus, timeout=${apdatu_wait_timeout}s"

    while [ "$apdatu_wait" -lt "$apdatu_wait_timeout" ]; do
      if [ -d "$apdatu_runtime_dir" ] &&
         [ -S "$apdatu_bus_path" ]; then
        break
      fi

      sleep 1
      apdatu_wait=$((apdatu_wait + 1))
    done

    if [ ! -d "$apdatu_runtime_dir" ]; then
      log_fail "Debian user runtime directory is unavailable: $apdatu_runtime_dir"
      return 1
    fi

    if [ ! -S "$apdatu_bus_path" ]; then
      log_fail "Debian user D-Bus is unavailable: $apdatu_bus_path"
      return 1
    fi

    log_pass "Debian user runtime is ready: $apdatu_runtime_dir"
  else
    apdatu_runtime_dir="/run/user/$apdatu_uid"
    apdatu_bus_path="$apdatu_runtime_dir/bus"
  fi

  ###########################################################################
  # Re-execute the test as the Debian Audio user
  ###########################################################################

  if ! command -v runuser >/dev/null 2>&1; then
    log_fail "runuser is unavailable, cannot execute Audio test as $apdatu_user"
    return 1
  fi

  AUDIO_TEST_USER="$apdatu_user"
  AUDIO_TEST_UID="$apdatu_uid"
  AUDIO_TEST_USER_REEXEC=1
  AUDIO_PACKAGE_PREPARED=1
  AUDIO_SYSTEMCTL_USER_SCOPE=1
  AUDIO_TEST_USER_MANAGER_REQUIRED="$apdatu_need_user_manager"

  export AUDIO_TEST_USER
  export AUDIO_TEST_UID
  export AUDIO_TEST_USER_REEXEC
  export AUDIO_PACKAGE_PREPARED
  export AUDIO_SYSTEMCTL_USER_SCOPE
  export AUDIO_TEST_USER_MANAGER_REQUIRED
  
  log_info "Re-executing Audio test as user=$apdatu_user uid=$apdatu_uid"

  # Replacing the privileged wrapper is intentional. This ensures signals and
  # the final test exit status belong directly to the unprivileged test process.
  # shellcheck disable=SC2093
  exec runuser \
    -u "$apdatu_user" \
    --preserve-environment \
    -- \
    env \
      HOME="$apdatu_home" \
      USER="$apdatu_user" \
      LOGNAME="$apdatu_user" \
      SHELL="$apdatu_shell" \
      TMPDIR="/tmp" \
      XDG_RUNTIME_DIR="$apdatu_runtime_dir" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$apdatu_bus_path" \
      AUDIO_TEST_USER="$apdatu_user" \
      AUDIO_TEST_UID="$apdatu_uid" \
      AUDIO_TEST_USER_REEXEC=1 \
      AUDIO_PACKAGE_PREPARED=1 \
      AUDIO_SYSTEMCTL_USER_SCOPE=1 \
      AUDIO_TEST_USER_MANAGER_REQUIRED="$apdatu_need_user_manager" \
      AUDIO_OVERLAY_PACKAGES_CHANGED="${AUDIO_OVERLAY_PACKAGES_CHANGED:-0}" \
      AUDIO_OVERLAY_REBOOT_REQUIRED="${AUDIO_OVERLAY_REBOOT_REQUIRED:-0}" \
      "$apdatu_script" \
      "$@"
}

# Minimal WAV fallback for images without Python. It validates RIFF/WAVE/fmt/data,
# requested rate/channels, bounded duration, and signed PCM sample activity.
# WAVE_FORMAT_EXTENSIBLE PCM is supported. Float WAV validation requires Python.
audio_validate_recorded_wav_od() {
  avrwo_file="$1"
  avrwo_source_kind="$2"
  avrwo_rate="$3"
  avrwo_channels="$4"
  avrwo_expected_seconds="$5"
  avrwo_analyze_bytes="${AUDIO_RECORD_ANALYZE_BYTES:-4194304}"
  avrwo_min_active="${AUDIO_RECORD_MIN_ACTIVE_SAMPLES:-100}"
  avrwo_min_distinct="${AUDIO_RECORD_MIN_DISTINCT_SAMPLES:-4}"
  avrwo_threshold_lsb="${AUDIO_RECORD_SAMPLE_THRESHOLD_LSB:-${AUDIO_RECORD_SAMPLE_THRESHOLD:-8}}"

  command -v od >/dev/null 2>&1 || return 1
  command -v dd >/dev/null 2>&1 || return 1
  [ -s "$avrwo_file" ] || return 1

  avrwo_meta="$({
    dd if="$avrwo_file" bs=1 count=1048576 2>/dev/null |
      od -An -v -tu1
  } | awk '
    function u16(i) {
      return b[i] + (b[i + 1] * 256)
    }
    function u32(i) {
      return b[i] + (b[i + 1] * 256) + (b[i + 2] * 65536) + (b[i + 3] * 16777216)
    }
    function fourcc(i) {
      return sprintf("%c%c%c%c", b[i], b[i + 1], b[i + 2], b[i + 3])
    }
    {
      for (i = 1; i <= NF; i++) {
        b[++n] = $i
      }
    }
    END {
      if (n < 44 || (fourcc(1) != "RIFF" && fourcc(1) != "RF64") || fourcc(9) != "WAVE") {
        exit 1
      }

      pos = 13
      fmt = 0
      channels = 0
      rate = 0
      byte_rate = 0
      align = 0
      bits = 0

      while ((pos + 7) <= n) {
        id = fourcc(pos)
        size = u32(pos + 4)

        if (id == "fmt " && size >= 16 && (pos + 23) <= n) {
          fmt = u16(pos + 8)
          channels = u16(pos + 10)
          rate = u32(pos + 12)
          byte_rate = u32(pos + 16)
          align = u16(pos + 20)
          bits = u16(pos + 22)

          # WAVE_FORMAT_EXTENSIBLE: first two bytes of SubFormat GUID.
          if (fmt == 65534 && size >= 40 && (pos + 33) <= n) {
            fmt = u16(pos + 32)
          }
        }

        if (id == "data") {
          # AWK arrays are one-based. pos+7 is the zero-based byte offset used
          # by dd skip= for the first payload byte at array index pos+8.
          printf "%d|%d|%d|%d|%d|%d|%d|%d\n", pos + 7, size, fmt, channels, rate, byte_rate, align, bits
          exit 0
        }

        pos += 8 + size + (size % 2)
      }

      exit 1
    }
  ' 2>/dev/null)" || return 1

  IFS='|' read -r \
    avrwo_offset \
    avrwo_declared \
    avrwo_format \
    avrwo_actual_channels \
    avrwo_actual_rate \
    avrwo_byte_rate \
    avrwo_block_align \
    avrwo_bits <<EOF
$avrwo_meta
EOF

  [ "$avrwo_format" -eq 1 ] 2>/dev/null || {
    log_warn "od WAV fallback supports PCM only, format=$avrwo_format requires Python"
    return 1
  }

  case "$avrwo_bits" in
    8|16|24|32)
      ;;
    *)
      log_warn "od WAV fallback does not support PCM bit depth $avrwo_bits"
      return 1
      ;;
  esac

  [ "$avrwo_actual_rate" = "$avrwo_rate" ] || return 1
  [ "$avrwo_actual_channels" = "$avrwo_channels" ] || return 1
  [ "$avrwo_byte_rate" -gt 0 ] 2>/dev/null || return 1
  [ "$avrwo_block_align" -gt 0 ] 2>/dev/null || return 1
  [ $((avrwo_block_align % avrwo_actual_channels)) -eq 0 ] 2>/dev/null || return 1
  [ "$avrwo_byte_rate" -eq $((avrwo_actual_rate * avrwo_block_align)) ] 2>/dev/null || return 1
  avrwo_bytes_per_sample=$((avrwo_block_align / avrwo_actual_channels))
  [ "$avrwo_bits" -gt 0 ] 2>/dev/null || return 1
  [ "$avrwo_bits" -le $((avrwo_bytes_per_sample * 8)) ] 2>/dev/null || return 1

  avrwo_file_bytes="$(file_size_bytes "$avrwo_file" 2>/dev/null || echo 0)"
  avrwo_available=$((avrwo_file_bytes - avrwo_offset))
  [ "$avrwo_available" -gt 0 ] 2>/dev/null || return 1

  if [ "$avrwo_declared" -gt 0 ] 2>/dev/null &&
     [ "$avrwo_declared" -lt "$avrwo_available" ] 2>/dev/null; then
    avrwo_usable="$avrwo_declared"
  else
    avrwo_usable="$avrwo_available"
  fi

  # Analyze complete frames only.
  avrwo_usable=$((avrwo_usable - (avrwo_usable % avrwo_block_align)))
  [ "$avrwo_usable" -gt 0 ] 2>/dev/null || return 1

  if [ "$avrwo_expected_seconds" -gt 0 ] 2>/dev/null; then
    avrwo_duration_ok="$(awk \
      -v bytes="$avrwo_usable" \
      -v byte_rate="$avrwo_byte_rate" \
      -v expected="$avrwo_expected_seconds" \
      -v ratio="${AUDIO_RECORD_MIN_DURATION_RATIO:-0.70}" \
      'BEGIN { actual=bytes/byte_rate; minimum=expected*ratio; if (minimum < 0.25) minimum=0.25; print (actual >= minimum) ? 1 : 0 }')"
    [ "$avrwo_duration_ok" -eq 1 ] || return 1
  fi

  if [ "$avrwo_source_kind" = "null" ]; then
    AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION status=PASS reason=valid-null-source-recording validator=od payload_bytes=$avrwo_usable"
    export AUDIO_WAV_VALIDATION_SUMMARY
    return 0
  fi

  if [ "$avrwo_usable" -lt "$avrwo_analyze_bytes" ] 2>/dev/null; then
    avrwo_count="$avrwo_usable"
  else
    avrwo_count="$avrwo_analyze_bytes"
  fi
  avrwo_count=$((avrwo_count - (avrwo_count % avrwo_block_align)))
  [ "$avrwo_count" -gt 0 ] 2>/dev/null || return 1

  avrwo_stats="$({
    dd if="$avrwo_file" \
      bs=1 \
      skip="$avrwo_offset" \
      count="$avrwo_count" \
      2>/dev/null |
      od -An -v -tu1
  } | awk \
      -v bits="$avrwo_bits" \
      -v min_active="$avrwo_min_active" \
      -v min_distinct="$avrwo_min_distinct" \
      -v threshold_lsb="$avrwo_threshold_lsb" '
    function abs_value(value) {
      return value < 0 ? -value : value
    }
    function power2(exponent, value, i) {
      value = 1
      for (i = 0; i < exponent; i++) value *= 2
      return value
    }
    function consume_sample(raw, sign_limit, full_range, threshold, key) {
      sign_limit = power2(bits - 1)
      full_range = power2(bits)
      if (raw >= sign_limit) raw -= full_range

      samples++
      if (raw != 0) nonzero_samples++

      threshold = (threshold_lsb / 32768.0) * sign_limit
      if (threshold < 0) threshold = 0
      if (abs_value(raw) > threshold) active_samples++

      if (distinct_samples < 256) {
        key = sprintf("%.0f", raw)
        if (!(key in seen)) {
          seen[key] = 1
          distinct_samples++
        }
      }
    }
    BEGIN {
      bytes_per_sample = bits / 8
    }
    {
      for (i = 1; i <= NF; i++) {
        sample_bytes[++sample_index] = $i
        if (sample_index == bytes_per_sample) {
          raw = 0
          multiplier = 1
          for (j = 1; j <= bytes_per_sample; j++) {
            raw += sample_bytes[j] * multiplier
            multiplier *= 256
            delete sample_bytes[j]
          }
          sample_index = 0
          consume_sample(raw)
        }
      }
    }
    END {
      printf "%d|%d|%d|%d\n", samples, nonzero_samples, active_samples, distinct_samples
      if (samples <= 0 || nonzero_samples <= 0 || active_samples < min_active || distinct_samples < min_distinct) {
        exit 1
      }
    }
  ')" || return 1

  IFS='|' read -r \
    avrwo_samples \
    avrwo_nonzero_samples \
    avrwo_active_samples \
    avrwo_distinct_samples <<EOF
$avrwo_stats
EOF

  AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION status=PASS reason=pcm-signal-activity-present validator=od analyzed_samples=$avrwo_samples nonzero_samples=$avrwo_nonzero_samples active_samples=$avrwo_active_samples distinct_samples=$avrwo_distinct_samples"
  export AUDIO_WAV_VALIDATION_SUMMARY
  return 0
}

# Validate one recorded WAV using the repository Python validator when possible,
# with an od/dd fallback for smaller embedded images.
# Args: file, source-kind, expected-rate, expected-channels, expected-seconds,
#       optional log file.
audio_validate_recorded_wav() {
  avrw_file="$1"
  avrw_source_kind="${2:-mic}"
  avrw_rate="${3:-0}"
  avrw_channels="${4:-0}"
  avrw_expected_seconds="${5:-0}"
  avrw_log="${6:-}"
  avrw_validator="${AUDIO_WAV_VALIDATOR:-${TOOLS:-}/audio_wav_validate.py}"

  AUDIO_WAV_VALIDATION_SUMMARY=""
  export AUDIO_WAV_VALIDATION_SUMMARY

  if command -v python3 >/dev/null 2>&1 && [ -r "$avrw_validator" ]; then
    avrw_output="$(python3 "$avrw_validator" \
      --file "$avrw_file" \
      --source-kind "$avrw_source_kind" \
      --expect-rate "$avrw_rate" \
      --expect-channels "$avrw_channels" \
      --expected-seconds "$avrw_expected_seconds" \
      --analyze-bytes "${AUDIO_RECORD_ANALYZE_BYTES:-4194304}" \
      --min-active-samples "${AUDIO_RECORD_MIN_ACTIVE_SAMPLES:-100}" \
      --sample-threshold-lsb "${AUDIO_RECORD_SAMPLE_THRESHOLD_LSB:-${AUDIO_RECORD_SAMPLE_THRESHOLD:-8}}" \
      --min-distinct-samples "${AUDIO_RECORD_MIN_DISTINCT_SAMPLES:-4}" \
      --min-duration-ratio "${AUDIO_RECORD_MIN_DURATION_RATIO:-0.70}" \
      --strict-signal "${AUDIO_RECORD_STRICT_SIGNAL:-0}" \
      --min-rms-dbfs "${AUDIO_RECORD_MIN_RMS_DBFS:--60}" \
      2>&1)"
    avrw_rc=$?

    [ -n "$avrw_log" ] && printf '%s\n' "$avrw_output" >>"$avrw_log"
    printf '%s\n' "$avrw_output" |
      while IFS= read -r avrw_line; do
        [ -n "$avrw_line" ] && log_info "$avrw_line"
      done

    AUDIO_WAV_VALIDATION_SUMMARY="$(printf '%s\n' "$avrw_output" | tail -n 1)"
    export AUDIO_WAV_VALIDATION_SUMMARY
    [ "$avrw_rc" -eq 0 ]
    return $?
  fi

  log_warn "Python WAV validator unavailable, using bounded od/dd fallback"
  if audio_validate_recorded_wav_od \
      "$avrw_file" \
      "$avrw_source_kind" \
      "$avrw_rate" \
      "$avrw_channels" \
      "$avrw_expected_seconds"; then
    [ -n "$avrw_log" ] && printf '%s\n' "$AUDIO_WAV_VALIDATION_SUMMARY" >>"$avrw_log"
    log_info "$AUDIO_WAV_VALIDATION_SUMMARY"
    return 0
  fi

  AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION status=FAIL reason=od-fallback-validation-failed"
  export AUDIO_WAV_VALIDATION_SUMMARY
  [ -n "$avrw_log" ] && printf '%s\n' "$AUDIO_WAV_VALIDATION_SUMMARY" >>"$avrw_log"
  log_fail "$AUDIO_WAV_VALIDATION_SUMMARY"
  return 1
}

# Validate one recorder result using the existing timeout and file-size helpers
# plus the WAV payload validator above.
#
# Args:
#   $1 file
#   $2 source kind: mic|null
#   $3 expected rate, 0 disables the rate check
#   $4 expected channels, 0 disables the channel check
#   $5 expected recording duration
#   $6 recorder return code
#   $7 watchdog timeout passed to audio_exec_with_timeout
#   $8 optional log file
#
# Return:
#   0 - recorder status is acceptable and WAV validation passed
#   1 - recorder status or WAV validation failed
audio_validate_recording_result() {
  avrr_file="$1"
  avrr_source_kind="${2:-mic}"
  avrr_rate="${3:-0}"
  avrr_channels="${4:-0}"
  avrr_expected_duration="${5:-0}"
  avrr_rc="${6:-1}"
  avrr_timeout="${7:-0}"
  avrr_log="${8:-}"

  avrr_bytes="$(file_size_bytes "$avrr_file" 2>/dev/null || echo 0)"
  if [ "${avrr_bytes:-0}" -le 44 ] 2>/dev/null; then
    AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION status=FAIL reason=file-empty-or-header-only file_bytes=${avrr_bytes:-0}"
    export AUDIO_WAV_VALIDATION_SUMMARY
    [ -n "$avrr_log" ] && printf '%s\n' "$AUDIO_WAV_VALIDATION_SUMMARY" >>"$avrr_log"
    return 1
  fi

  avrr_expected_seconds="$(audio_parse_secs "$avrr_expected_duration" 2>/dev/null || echo 0)"
  [ -n "$avrr_expected_seconds" ] || avrr_expected_seconds=0

  if ! audio_validate_recorded_wav \
      "$avrr_file" \
      "$avrr_source_kind" \
      "$avrr_rate" \
      "$avrr_channels" \
      "$avrr_expected_seconds" \
      "$avrr_log"; then
    return 1
  fi

  case "$avrr_rc" in
    0)
      ;;
    124|137|143)
      avrr_timeout_seconds="$(audio_parse_secs "$avrr_timeout" 2>/dev/null || echo 0)"
      if [ -z "$avrr_timeout_seconds" ] || [ "$avrr_timeout_seconds" -le 0 ] 2>/dev/null; then
        AUDIO_WAV_VALIDATION_SUMMARY="${AUDIO_WAV_VALIDATION_SUMMARY} recorder_rc=$avrr_rc recorder_status=unexpected-timeout"
        export AUDIO_WAV_VALIDATION_SUMMARY
        return 1
      fi
      log_warn "Recorder ended through expected watchdog timeout rc=$avrr_rc, validated WAV payload is accepted"
      ;;
    *)
      AUDIO_WAV_VALIDATION_SUMMARY="${AUDIO_WAV_VALIDATION_SUMMARY} recorder_rc=$avrr_rc recorder_status=failed"
      export AUDIO_WAV_VALIDATION_SUMMARY
      return 1
      ;;
  esac

  if command -v sox >/dev/null 2>&1 && [ -n "$avrr_log" ]; then
    {
      printf '%s\n' "---- optional sox recording statistics ----"
      sox "$avrr_file" -n stat 2>&1 || true
    } >>"$avrr_log"
  fi

  return 0
}
