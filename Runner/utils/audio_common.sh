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
  if pgrep -x pipewire >/dev/null 2>&1; then
    echo pipewire; return 0
  fi
  if pgrep -x pulseaudio >/dev/null 2>&1; then
    echo pulseaudio; return 0
  fi
  # Accept pipewire-pulse shim as PulseAudio
  if pgrep -x pipewire-pulse >/dev/null 2>&1; then
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

# audio_ensure_download_client
# Ensures that curl or wget is available. Takes no arguments and emits no
# machine-readable stdout. It may install the complete mapped audio-download
# package set on Ubuntu and writes diagnostics through log_* helpers. Returns 0
# when a downloader is available and 1 otherwise.
audio_ensure_download_client() {
  if command -v curl >/dev/null 2>&1 ||
     command -v wget >/dev/null 2>&1; then
    return 0
  fi

  if command -v pkg_ensure_host_distro_package_set_present >/dev/null 2>&1; then
    log_info "Audio asset download requires curl or wget, attempting mapped package recovery"
    pkg_ensure_host_distro_package_set_present audio-download
    audio_download_recovery_rc=$?

    case "$audio_download_recovery_rc" in
      0)
        ;;
      2)
        log_warn "Audio downloader package recovery is not configured for this operating system"
        ;;
      *)
        log_error "Failed to recover the audio-download package set"
        ;;
    esac
  fi

  if command -v curl >/dev/null 2>&1 ||
     command -v wget >/dev/null 2>&1; then
    return 0
  fi

  log_error "No downloader is available, provision curl and wget in the image or enable Ubuntu package recovery"
  return 1
}

# audio_download_with_any <url> <outfile>
# Downloads the non-empty URL to the output path using an available curl or
# wget client and writes downloader output to stdout and stderr. Returns the
# downloader status, or 1 when neither client is available. The caller owns
# output-file cleanup.
audio_download_with_any() {
  url="$1"
  out="$2"

  if [ -z "$url" ] || [ -z "$out" ]; then
    log_error "audio_download_with_any requires a URL and output path"
    return 1
  fi

  audio_ensure_download_client || return 1

  if command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    curl -L --fail -o "$out" "$url"
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

# audio_ensure_archive_extractor
# Check gzip-tar support with an empty archive under the CWD scratch directory.
# BusyBox/libarchive can pass without an external gzip binary. Recover the full
# mapped audio-extract set only when needed, respecting shared provider policy.
# No arguments or stdout data. Log diagnostics and return 0 ready, 1 unavailable.
audio_ensure_archive_extractor() (
  aae_dir="$(audio_scratch_dir)" || return 1
  ensure_tar_extractor "$aae_dir" audio-extract gzip
)

# audio_fetch_assets_from_url <url>
# Downloads and extracts the audio archive URL into AUDIO_CLIPS_BASE_DIR. The
# URL must be non-empty. The function writes diagnostic logs and temporary
# archive files, may recover mapped downloader/extractor package sets, and
# emits no machine-readable stdout. Returns 0 when runnable clips are ready and
# 1 when download, extraction, or validation fails.
audio_fetch_assets_from_url() {
  url="$1"
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"
  marker_file="${AUDIO_EXTRACT_MARKER:-$clips_dir/.audioclips_extracted}"
  work_dir="$(audio_scratch_dir)" || return 1
  ts="$(date +%s 2>/dev/null || echo 0)"
  archive_path="$work_dir/AudioClips.$$.${ts}.tar.gz"
  fetch_log="$work_dir/AudioClips_fetch.$$.${ts}.log"
  extract_log="$work_dir/AudioClips_extract.$$.${ts}.log"
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

  audio_ensure_archive_extractor || return 1
  audio_ensure_download_client || return 1

  while [ "$fetch_attempt" -le "$fetch_attempts" ]; do
    rm -f "$archive_path" >/dev/null 2>&1 || true
    rm -f "$fetch_log" >/dev/null 2>&1 || true

    download_ok=0
    fetch_client=""

    if command -v curl >/dev/null 2>&1 &&
       command -v wget >/dev/null 2>&1; then
      if [ $((fetch_attempt % 2)) -eq 1 ]; then
        fetch_client="curl"
      else
        fetch_client="wget"
      fi
    elif command -v curl >/dev/null 2>&1; then
      fetch_client="curl"
    elif command -v wget >/dev/null 2>&1; then
      fetch_client="wget"
    fi

    if [ "$fetch_client" = "curl" ]; then
      log_info "exec: curl -fL --connect-timeout 20 --max-time 120 -o \"$archive_path\" \"$url\" (attempt ${fetch_attempt}/${fetch_attempts})"
      if audio_exec_with_timeout 125 \
          curl -fL \
          --connect-timeout 20 \
          --max-time 120 \
          -o "$archive_path" \
          "$url" >"$fetch_log" 2>&1; then
        download_ok=1
      else
        log_warn "curl download failed on attempt ${fetch_attempt}/${fetch_attempts}, showing last lines from $fetch_log"
        tail -n 20 "$fetch_log" 2>/dev/null || true
      fi
    elif [ "$fetch_client" = "wget" ]; then
      log_info "exec: wget --tries=1 --timeout=20 -O \"$archive_path\" \"$url\" (attempt ${fetch_attempt}/${fetch_attempts})"
      if audio_exec_with_timeout 125 \
          wget --tries=1 \
          --timeout=20 \
          -O "$archive_path" \
          "$url" >"$fetch_log" 2>&1; then
        download_ok=1
      else
        log_warn "wget download failed on attempt ${fetch_attempt}/${fetch_attempts}, showing last lines from $fetch_log"
        tail -n 20 "$fetch_log" 2>/dev/null || true
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
  if ! tar -xzf "$archive_path" -C "$clips_dir" >"$extract_log" 2>&1; then
    cat "$extract_log" >>"$fetch_log"
    log_error "Failed to extract audio clips archive into $clips_dir"
    log_error "Fetch log preserved at: $fetch_log"
    log_file_with_label AUDIO-EXTRACT "$extract_log" 40
    rm -f "$archive_path" >/dev/null 2>&1 || true
    return 1
  fi
  cat "$extract_log" >>"$fetch_log"

  rm -f "$archive_path" >/dev/null 2>&1 || true

  # Normalize nested archive layout like AudioClips/AudioClips/*.wav -> AudioClips/*.wav
  if [ -d "$clips_dir/AudioClips" ]; then
    log_info "Detected nested AudioClips directory after extraction, normalizing layout"
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
# scan_audio_dmesg <output-directory>
# Capture an audio-focused kernel snapshot in the supplied evidence directory.
# Produces no machine-readable stdout and always returns success after the scan.
scan_audio_dmesg() {
  sad_output_dir="$1"
  mkdir -p "$sad_output_dir" || return 1
  sad_modules='snd[^:]*|asoc[^:]*|qcom[-_,](apm|apr|q6)[^:]*|q6[^:]*|apr[^:]*|gpr[^:]*|remoteproc[^:]*|audio[^:]*|lpass[^:]*|.*codec[^:]*|pipewire[^:]*|pulseaudio[^:]*'
  sad_exclusions='dummy regulator|EEXIST|probe deferred'

  scan_dmesg_errors \
    "$sad_output_dir" \
    "$sad_modules" \
    "$sad_exclusions" >"$sad_output_dir/kernel_capture.log" 2>&1 || true
  audio_kernel_diagnostic_summary "$sad_output_dir"
}

# audio_kernel_diagnostic_summary <captured-output-directory>
# Classify the shared provider snapshot without capturing it again. Diagnostics
# never change functional PASS policy, selected DSP crashes use the separate
# health gate. Stdout reports scope, access and counts, artifacts retain details.
audio_kernel_diagnostic_summary() {
  akds_out="$1"
  : >"$akds_out/audio_kernel_errors.log"
  : >"$akds_out/audio_kernel_warnings.log"
  if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ] ||
     [ ! -s "$akds_out/dmesg_snapshot.log" ]; then
    log_warn "[AUDIO-KERNEL] Evidence unavailable, kernel health is unverified. See $akds_out/dmesg_access.log and kernel_capture.log"
    return 0
  fi
  if ! awk -v since="${AUDIO_REMOTE_PROC_SINCE:-}" \
      -v errors="$akds_out/audio_kernel_errors.log" \
      -v warnings="$akds_out/audio_kernel_warnings.log" '
    {
      if (since ~ /^[0-9]+$/) {
        if ($0 !~ /^\[[[:space:]]*[0-9]+([.][0-9]+)?\]/) next
        stamp = $0
        sub(/^\[[[:space:]]*/, "", stamp)
        sub(/\].*$/, "", stamp)
        if (stamp + 0 < since + 0) next
      }
      line = tolower($0)
      if (line ~ /dummy regulator|supply [^ ]+ not found|eexist|probe deferred|binding deferred/) next
      relevant = line ~ /(^|[[:space:]])(snd[[:alnum:]_-]*|asoc|qcom[-_,](apm|apr|q6)[[:alnum:]_-]*|q6[[:alnum:]_-]*|apr|gpr|remoteproc|lpass[[:alnum:]_-]*|[[:alnum:]_-]*codec|[rtv]x[-_]macro|va[-_]macro|wsa[[:alnum:]_-]*|soundwire|swr[[:alnum:]_-]*|pipewire|pulseaudio)([[:space:]:]|$)/
      if (!relevant) next
      if (line ~ /unknown symbol|probe.*fail|failed|failure|error|timed out|timeout|not found|invalid|corrupt|abort|panic|oops|unhandled|watchdog|crash/)
        print $0 > errors
      else if (line ~ /unknown pin|no backend dais|underrun|overrun|xrun/)
        print $0 > warnings
    }
  ' "$akds_out/dmesg_snapshot.log"; then
    log_warn "[AUDIO-KERNEL] Snapshot classification failed, kernel health is unverified. Retain $akds_out/dmesg_snapshot.log for triage"
    return 0
  fi
  akds_errors="$(wc -l <"$akds_out/audio_kernel_errors.log")"
  akds_warnings="$(wc -l <"$akds_out/audio_kernel_warnings.log")"
  log_info "[AUDIO-KERNEL] Captured audio diagnostics: errors=$akds_errors warnings=$akds_warnings since_uptime=${AUDIO_REMOTE_PROC_SINCE:-boot}, independent of stream execution result"
  if [ "$akds_errors" -gt 0 ] || [ "$akds_warnings" -gt 0 ]; then
    log_warn "[AUDIO-KERNEL] Audio messages require triage even when playback/recording passes, artifacts: $akds_out/audio_kernel_errors.log and audio_kernel_warnings.log"
    log_file_with_label AUDIO-KERNEL-ERROR "$akds_out/audio_kernel_errors.log" 40
    log_file_with_label AUDIO-KERNEL-WARN "$akds_out/audio_kernel_warnings.log" 40
  fi
  return 0
}

dump_mixers() {
  audio_dump_out="$1"
  {
    echo "---- ALSA playback and capture inventory ----"
    audio_exec_with_timeout 5s env LC_ALL=C aplay -l 2>&1 || true
    audio_exec_with_timeout 5s env LC_ALL=C arecord -l 2>&1 || true
    for audio_dump_card in $(audio_alsa_card_indexes); do
      echo "---- ALSA mixer card $audio_dump_card ----"
      audio_exec_with_timeout 5s amixer -c "$audio_dump_card" contents 2>&1 || true
    done
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
# Debian and CentOS:
#   Root orchestrator:
#       runuser -u debian -- systemctl --user ...
#
#   Temporary migration compatibility:
#       Existing runners that are still fully re-executed as the desktop Audio
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
    debian|centos)
      ;;
    *)
      # Preserve existing native/Yocto system-service behavior.
      systemctl "$@"
      return $?
      ;;
  esac
 
  ###########################################################################
  # Preferred desktop path: root orchestrator, command-level user execution
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
      log_fail "PipeWire systemctl operation was invoked outside the prepared Audio user context"
      log_fail "Run audio_prepare_desktop_audio_environment before invoking PipeWire service operations"
      return 1
      ;;
  esac
 
  aps_expected_user="${AUDIO_TEST_USER:-}"
  aps_current_user="$(id -un 2>/dev/null || echo unknown)"

  if [ -z "$aps_expected_user" ]; then
    log_fail "The prepared Audio test user is unavailable"
    return 1
  fi
 
  if [ "$aps_current_user" != "$aps_expected_user" ]; then
    log_fail "Unexpected PipeWire service user: current=$aps_current_user expected=$aps_expected_user"
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

# Prefer the prepared CWD workspace, including desktop-user child commands.
# Only desktop child commands use their explicitly prepared TMPDIR workspace.
# Print a writable directory or return 1, never fall back to system temp paths.
audio_scratch_dir() {
  asd_user_tmp=""
  if [ "${AUDIO_TEST_COMMAND_USER_CONTEXT:-0}" -eq 1 ]; then
    asd_user_tmp="${TMPDIR:-}"
  fi
  for asd_candidate in \
    "${AUDIO_RECORD_USER_CAPTURE_DIR:-}" \
    "${LOGDIR:-}" \
    "$asd_user_tmp" \
    "${PWD:-}"
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
  aprs_start_s="$(get_monotonic_seconds)"
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
    aprs_now_s="$(get_monotonic_seconds)"
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

# Resolve a discovered wpctl source ID to a pw-record target in this session.
# Argument: global node ID. Stdout is one node.name or positive object.serial.
# Return 1 on failed inspection, a non-source node or missing target properties.
# Never substitute the global ID, a description or the session default.
pw_source_target_safe() {
  psts_id="$1"
  if ! psts_inspect="$(pwctl_inspect_safe "$psts_id")"; then
    printf 'Cannot inspect selected PipeWire source ID %s\n' "$psts_id" >&2
    return 1
  fi
  if ! printf '%s\n' "$psts_inspect" | awk -F '"' '
    $1 ~ /^[[:space:]*]*media[.]class[[:space:]]*=[[:space:]]*$/ { source = $2 }
    NF == 3 && $1 ~ /^[[:space:]*]*node[.]name[[:space:]]*=[[:space:]]*$/ { name = $2 }
    $1 ~ /^[[:space:]*]*object[.]serial[[:space:]]*=[[:space:]]*$/ { serial = $2 }
    END {
      if (source != "Audio/Source") {
        exit 1
      }
      if (name != "" && name != "auto" && name !~ /^[0-9]+$/ && name !~ /\\/) {
        print name
      } else if (serial ~ /^[0-9]+$/ && serial + 0 > 0) {
        print serial
      } else {
        exit 1
      }
    }
  '; then
    printf 'Selected PipeWire source ID %s has no usable node.name or object.serial\n' "$psts_id" >&2
    return 1
  fi
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

# Prefer speaker sinks before other physical outputs. A generic physical sink
# remains a compatibility fallback, but an explicitly named headphones sink is
# never selected for a speakers request.
pw_default_speakers() {
  st="$(pwctl_status_safe 2>/dev/null)" || {
    printf '%s\n' ""
    return 0
  }

  block="$(printf '%s\n' "$st" | sed -n '/Sinks:/,/Sources:/p')"
  speaker_ids="$(
    printf '%s\n' "$block" |
      grep -Ei 'speaker' |
      sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p'
  )"
  output_ids="$(
    printf '%s\n' "$block" |
      grep -Ei 'line[._ -]*out|analog|hdmi' |
      sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p'
  )"
  all_ids="$(
    printf '%s\n' "$block" |
      sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p'
  )"
  checked_ids=""

  for id in $speaker_ids $output_ids $all_ids; do
    case " $checked_ids " in
      *" $id "*)
        continue
        ;;
    esac

    checked_ids="$checked_ids $id"

    ps_label="$(
      pwctl_inspect_safe "$id" 2>/dev/null |
        grep -E 'node[.](description|name)[[:space:]]*=' |
        cut -d'"' -f2 |
        tr '\n' ' '
    )"

    if printf '%s\n' "$ps_label" | grep -Eiq 'headphone|headset|3[.]5|hsj'; then
      continue
    fi

    if pw_sink_is_real_audio "$id"; then
      printf '%s\n' "$id"
      return 0
    fi
  done

  printf '%s\n' ""
}

# Return the first real PipeWire sink identified as headphones at runtime.
pw_default_headphones() {
  pdh_status="$(pwctl_status_safe 2>/dev/null)" || {
    printf '%s\n' ""
    return 0
  }

  pdh_block="$(printf '%s\n' "$pdh_status" | sed -n '/Sinks:/,/Sources:/p')"
  pdh_ids="$(
    printf '%s\n' "$pdh_block" |
      grep -Ei 'headphone|headset|3[.]5|hsj' |
      sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p'
  )"

  for pdh_id in $pdh_ids; do
    if pw_sink_is_real_audio "$pdh_id"; then
      printf '%s\n' "$pdh_id"
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

    pdm_label="$(
      pwctl_inspect_safe "$id" 2>/dev/null |
        grep -E 'node[.](description|name)[[:space:]]*=' |
        cut -d'"' -f2 |
        tr '\n' ' '
    )"

    if printf '%s\n' "$pdm_label" |
        grep -Eiq 'headphone|headset|3[.]5|hsj|hsmic'; then
      continue
    fi

    if pw_source_is_real_audio "$id"; then
      printf '%s\n' "$id"
      return 0
    fi
  done

  printf '%s\n' ""
}

# Return the first real PipeWire source identified as a headset microphone.
pw_default_headset_mic() {
  pdhm_status="$(pwctl_status_safe 2>/dev/null)" || {
    printf '%s\n' ""
    return 0
  }

  pdhm_block="$(
    printf '%s\n' "$pdhm_status" |
      sed -n '/Sources:/,/Filters:/p'
  )"
  pdhm_ids="$(
    printf '%s\n' "$pdhm_block" |
      grep -Ei 'headphone|headset|3[.]5|hsj|hsmic' |
      sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p'
  )"

  for pdhm_id in $pdhm_ids; do
    if pw_source_is_real_audio "$pdhm_id"; then
      printf '%s\n' "$pdhm_id"
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
# Print stable route-identification fields for one PulseAudio sink. Do not
# include the complete Ports section because it lists inactive routes too.
pa_sink_route_label() {
  pasrl_name="$1"

  [ -n "$pasrl_name" ] || return 1

  {
    printf '%s\n' "$pasrl_name"
    pactl list sinks 2>/dev/null |
      awk -v requested="$pasrl_name" '
        $1 == "Name:" {
          selected = ($2 == requested)
        }
        selected &&
          ($1 == "Description:" ||
           $1 == "Active" && $2 == "Port:" ||
           $1 == "device.description" ||
           $1 == "device.form_factor") {
          print
        }
      '
  } |
    tr '\n' ' '
}

# Return success for a non-virtual PulseAudio playback sink. The short sink
# inventory is authoritative for existence, while metadata only rejects known
# virtual endpoints so older distributions with sparse properties still work.
pa_sink_is_real_audio() {
  pasira_name="$1"

  [ -n "$pasira_name" ] || return 1

  if ! pactl list short sinks 2>/dev/null |
      awk -v requested="$pasira_name" \
        '$2 == requested { found = 1 } END { exit !found }'; then
    return 1
  fi

  pasira_label="$(pa_sink_route_label "$pasira_name" 2>/dev/null || true)"
  if printf '%s\n' "$pasira_label" |
      grep -Eiq '(^|[._ /-])(null|dummy|monitor|loopback|freewheel)($|[._ /-])'; then
    return 1
  fi

  return 0
}

pa_default_speakers() {
  pds_sinks="$(pactl list short sinks 2>/dev/null)"
  pds_names="$(printf '%s\n' "$pds_sinks" | awk '{print $2}')"
  pds_default="$(
    pactl info 2>/dev/null |
      sed -n 's/^Default Sink:[[:space:]]*//p' |
      head -n 1
  )"
  pds_preferred=""
  pds_fallback=""

  for pds_name in $pds_names; do
    if ! pa_sink_is_real_audio "$pds_name"; then
      continue
    fi

    pds_label="$(pa_sink_route_label "$pds_name" 2>/dev/null || true)"
    if printf '%s\n' "$pds_label" |
        grep -Eiq 'headphone|headset|3[.]5|hsj'; then
      continue
    fi

    if printf '%s\n' "$pds_label" |
        grep -Eiq 'speaker|line[._ /-]*out|analog|hdmi'; then
      pds_preferred="$pds_name"
      break
    fi

    if [ "$pds_name" = "$pds_default" ]; then
      pds_fallback="$pds_name"
    elif [ -z "$pds_fallback" ]; then
      pds_fallback="$pds_name"
    fi
  done

  if [ -n "$pds_preferred" ]; then
    printf '%s\n' "$pds_preferred"
  else
    printf '%s\n' "$pds_fallback"
  fi
}

# Return the first PulseAudio sink identified as headphones at runtime.
pa_default_headphones() {
  pdh_names="$(pactl list short sinks 2>/dev/null | awk '{print $2}')"

  for pdh_name in $pdh_names; do
    if ! pa_sink_is_real_audio "$pdh_name"; then
      continue
    fi

    pdh_label="$(pa_sink_route_label "$pdh_name" 2>/dev/null || true)"
    if printf '%s\n' "$pdh_label" |
        grep -Eiq 'headphone|headset|3[.]5|hsj'; then
      printf '%s\n' "$pdh_name"
      return 0
    fi
  done

  printf '%s\n' ""
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
# Print stable route-identification fields for one PulseAudio source. This
# excludes inactive port inventory for the same reason as pa_sink_route_label.
pa_source_route_label() {
  pasrl_name="$1"

  [ -n "$pasrl_name" ] || return 1

  {
    printf '%s\n' "$pasrl_name"
    pactl list sources 2>/dev/null |
      awk -v requested="$pasrl_name" '
        $1 == "Name:" {
          selected = ($2 == requested)
        }
        selected &&
          ($1 == "Description:" ||
           $1 == "Active" && $2 == "Port:" ||
           $1 == "device.description" ||
           $1 == "device.form_factor") {
          print
        }
      '
  } |
    tr '\n' ' '
}

# Return success for a non-monitor, non-virtual PulseAudio capture source.
pa_source_is_real_audio() {
  pasira_name="$1"

  [ -n "$pasira_name" ] || return 1

  if ! pactl list short sources 2>/dev/null |
      awk -v requested="$pasira_name" \
        '$2 == requested { found = 1 } END { exit !found }'; then
    return 1
  fi

  pasira_label="$(pa_source_route_label "$pasira_name" 2>/dev/null || true)"
  if printf '%s\n' "$pasira_label" |
      grep -Eiq '(^|[._ /-])(null|dummy|monitor|loopback|freewheel)($|[._ /-])'; then
    return 1
  fi

  return 0
}

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
  pdm_names="$(pactl list short sources 2>/dev/null | awk '{print $2}')"
  pdm_default="$(
    pactl info 2>/dev/null |
      sed -n 's/^Default Source:[[:space:]]*//p' |
      head -n 1
  )"
  pdm_preferred=""
  pdm_fallback=""

  for pdm_name in $pdm_names; do
    if ! pa_source_is_real_audio "$pdm_name"; then
      continue
    fi

    pdm_label="$(pa_source_route_label "$pdm_name" 2>/dev/null || true)"
    if printf '%s\n' "$pdm_label" |
        grep -Eiq 'headphone|headset|3[.]5|hsj|hsmic'; then
      continue
    fi

    if printf '%s\n' "$pdm_label" |
        grep -Eiq 'mic|microphone|capture|audio[._ /-]*input'; then
      pdm_preferred="$pdm_name"
      break
    fi

    if [ "$pdm_name" = "$pdm_default" ]; then
      pdm_fallback="$pdm_name"
    elif [ -z "$pdm_fallback" ]; then
      pdm_fallback="$pdm_name"
    fi
  done

  if [ -n "$pdm_preferred" ]; then
    printf '%s\n' "$pdm_preferred"
  else
    printf '%s\n' "$pdm_fallback"
  fi
}

# Return the first PulseAudio source identified as a headset microphone.
pa_default_headset_mic() {
  pdhm_names="$(pactl list short sources 2>/dev/null | awk '{print $2}')"

  for pdhm_name in $pdhm_names; do
    if ! pa_source_is_real_audio "$pdhm_name"; then
      continue
    fi

    pdhm_label="$(pa_source_route_label "$pdhm_name" 2>/dev/null || true)"
    if printf '%s\n' "$pdhm_label" |
        grep -Eiq 'headphone|headset|3[.]5|hsj|hsmic'; then
      printf '%s\n' "$pdhm_name"
      return 0
    fi
  done

  printf '%s\n' ""
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

# Add startup headroom to an AudioRecord capture watchdog.
# PipeWire and PulseAudio recorders do not take a duration on these paths, so
# the watchdog starts before the stream is ready. Preserve the requested WAV
# duration by adding configurable startup grace to the watchdog only.
audio_record_timeout_with_grace() {
  artg_requested="$(audio_parse_secs "$1" 2>/dev/null || echo 0)"
  artg_grace="${AUDIO_RECORD_START_GRACE:-5}"

  if ! is_unsigned_number "$artg_grace"; then
    artg_grace=5
  fi

  if [ "${artg_requested:-0}" -gt 0 ] 2>/dev/null &&
     [ "$artg_grace" -gt 0 ] 2>/dev/null; then
    printf '%ss\n' "$((artg_requested + artg_grace))"
    return 0
  fi

  printf '%s\n' "$1"
}

# Run a command with a bounded timeout.
# Timeout accounting uses monotonic uptime so an RTC or NTP correction cannot
# prematurely terminate the child.
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

  aewt_start="$(get_monotonic_seconds)"

  aewt_deadline=$((aewt_start + aewt_dur_norm))
  aewt_timed_out=0

  while kill -0 "$aewt_pid" 2>/dev/null; do
    aewt_now="$(get_monotonic_seconds)"

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
  start_s="$(get_monotonic_seconds)"
  next_log=10

  while :; do
    now_s="$(get_monotonic_seconds)"
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

# audio_pipewire_capture_target <route> [identity]
# Resolve a fresh capture node using existing route policy in the stream user's
# session. Print only its node.name or object.serial for pw-record --target.
# With identity, print node ID|object serial|target for guarded volume writes.
# Retain inspect evidence on stderr. Return 1 for missing/invalid route identity.
audio_pipewire_capture_target() {
  apct_selection="$(audio_select_managed_capture_route pipewire "$1")" || return 1
  apct_id="${apct_selection#*|}"
  case "$apct_id" in
    ''|*[!0-9]*)
      printf '%s\n' "PipeWire capture route '$1' has no valid source ID" >&2
      return 1
      ;;
  esac
  apct_inspect="$(pwctl_inspect_safe "$apct_id")" || return 1
  printf '%s\n' "$apct_inspect" >&2
  apct_target="$(printf '%s\n' "$apct_inspect" | awk '
    {
      key=$0; sub(/=.*/, "", key)
      gsub(/^[[:space:]*]+|[[:space:]]+$/, "", key)
      value=$0; sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]+$/, "", value)
      sub(/^"/, "", value); sub(/"$/, "", value)
      if (key=="media.class") media=value
      if (key=="node.name") name=value
      if (key=="object.serial") serial=value
    }
    END {
      if (media !~ /^Audio\/Source($|\/)/) exit 1
      if (name!="" && name!="auto" && name !~ /^[0-9]+$/) print name
      else if (serial ~ /^[0-9]+$/ && serial+0>0) print serial
      else exit 1
    }
  ')" || {
    printf '%s\n' "PipeWire source $apct_id has no usable capture target identity" >&2
    return 1
  }
  printf '%s\n' "PipeWire capture route=$1 source_id=$apct_id target=$apct_target" >&2
  if [ "${2:-}" = identity ]; then
    apct_serial="$(printf '%s\n' "$apct_inspect" | awk '
      /object.serial[[:space:]]*=/ {
        sub(/.*=[[:space:]]*"?/, "")
        sub(/"?[[:space:]]*$/, "")
        if ($0 ~ /^[0-9]+$/) print
      }
    ')"
    case "$apct_serial" in
      ''|0|*[!0-9]*)
        return 1
        ;;
    esac
    printf '%s|%s|%s\n' "$apct_id" "$apct_serial" "$apct_target"
  else
    printf '%s\n' "$apct_target"
  fi
}

# audio_pipewire_volume_props <saved|unity>
# Parse pw-cli enum-params Props on stdin into a canonical writable JSON object.
# Preserve channel balance and optional soft controls in saved mode. Unity mode
# sets only exposed capture volume controls to 1.0 and mute controls to false.
# Return 1 for incomplete/ambiguous properties, never guess a restoration value.
audio_pipewire_volume_props() {
  LC_ALL=C awk -v mode="$1" '
    /Prop: key / {
      key=$0
      sub(/.*:Props:/, "", key)
      sub(/[[:space:]].*/, "", key)
      active=(key=="volume" || key=="mute" || key=="channelVolumes" ||
              key=="softMute" || key=="softVolumes")
      if (active && seen[key]++) bad=1
      next
    }
    active && $1=="Float" {
      if (key=="mute" || key=="softMute") bad=1
      if ($2 !~ /^[+]?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/) {
        bad=1
        next
      }
      number=(mode=="unity" ? 1 : $2+0)
      values[key]=values[key] (count[key]++ ? ", " : "") sprintf("%.9g", number)
    }
    active && $1=="Bool" {
      if (key!="mute" && key!="softMute") bad=1
      if ($2!="true" && $2!="false") bad=1
      values[key]=(mode=="unity" ? "false" : $2)
      count[key]++
    }
    END {
      if (bad || count["volume"]!=1 || count["mute"]!=1 ||
          count["channelVolumes"]<1 || count["channelVolumes"]>64) exit 1
      if (seen["softMute"] && count["softMute"]!=1) exit 1
      if (seen["softVolumes"] && (count["softVolumes"]<1 ||
          count["softVolumes"]>64)) exit 1
      printf "{ \"volume\": %s, \"mute\": %s, \"channelVolumes\": [ %s ]", \
        values["volume"], values["mute"], values["channelVolumes"]
      if (seen["softMute"]) printf ", \"softMute\": %s", values["softMute"]
      if (seen["softVolumes"]) printf ", \"softVolumes\": [ %s ]", values["softVolumes"]
      print " }"
    }
  '
}

# audio_pipewire_volume_identity <id> <serial> [media-class]
# Require the same object/class before writing or restoring properties.
# Existing capture callers default to Audio/Source, playback uses Audio/Sink.
# No stdout. Return 1 if the original node vanished or its ID was recycled.
audio_pipewire_volume_identity() {
  apvi_inspect="$(pwctl_inspect_safe "$1")" || return 1
  printf '%s\n' "$apvi_inspect" | awk -v serial="$2" -v class="${3:-Audio/Source}" '
    {
      key=$0; sub(/=.*/, "", key)
      gsub(/^[[:space:]*]+|[[:space:]]+$/, "", key)
      value=$0; sub(/^[^=]*=[[:space:]]*/, "", value)
      gsub(/^"|"[[:space:]]*$/, "", value)
      if (key=="object.serial" && value==serial) matched=1
      if (key=="media.class" && (value==class || index(value, class "/")==1)) source=1
    }
    END { exit !(matched && source) }
  '
}

# audio_pipewire_volume_read <id>
# Print canonical current volume state. Preserve command failures before parsing.
audio_pipewire_volume_read() {
  apvr_raw="$(audio_exec_with_timeout 3s pw-cli enum-params "$1" Props)" || return 1
  printf '%s\n' "$apvr_raw" | audio_pipewire_volume_props saved
}

# audio_prepare_playback_volume <sink-id> [volume]
# Snapshot sink identity and full volume/mute state in the stream user context.
# Mark ownership before unmuting/optional gain changes. Return 1 on failure.
# If pw-cli is absent, preserve existing state without making untracked writes.
audio_prepare_playback_volume() {
  [ "${AUDIO_PLAYBACK_VOLUME_PENDING:-0}" -eq 0 ] || return 1
  if ! command -v pw-cli >/dev/null 2>&1; then
    log_warn "pw-cli is absent, playback volume/mute state is left unchanged"
    return 0
  fi
  AUDIO_PLAYBACK_VOLUME_ID="$1"
  appv_inspect="$(audio_run_helper_as_test_user --require-session pwctl_inspect_safe "$1")" || return 1
  AUDIO_PLAYBACK_VOLUME_SERIAL="$(printf '%s\n' "$appv_inspect" |
    awk '/object.serial[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/["[:space:]]/, "")
      print
      exit
    }')"
  case "$AUDIO_PLAYBACK_VOLUME_SERIAL" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  audio_run_helper_as_test_user --require-session audio_pipewire_volume_identity \
    "$1" "$AUDIO_PLAYBACK_VOLUME_SERIAL" Audio/Sink || return 1
  AUDIO_PLAYBACK_VOLUME_SAVED="$(audio_run_helper_as_test_user --require-session \
    audio_pipewire_volume_read "$1")" || return 1
  printf '%s\n' "id=$1 serial=$AUDIO_PLAYBACK_VOLUME_SERIAL" "$AUDIO_PLAYBACK_VOLUME_SAVED" \
    >"$LOGDIR/playback-volume.initial" || return 1
  AUDIO_PLAYBACK_VOLUME_PENDING=1
  audio_run_with_timeout_as_test_user --require-session 3s wpctl set-mute "$1" 0 || return 1
  if [ -n "${2:-}" ]; then
    audio_run_with_timeout_as_test_user --require-session 3s wpctl set-volume "$1" "$2" || return 1
  fi
  log_info "Prepared temporary playback volume/mute state, original state retained in $LOGDIR/playback-volume.initial"
}

# audio_restore_playback_volume
# Restore only the snapshotted sink. Reject recycled IDs and verify readback.
# Return 1 on failure, never modify a replacement node or restart services.
audio_restore_playback_volume() {
  [ "${AUDIO_PLAYBACK_VOLUME_PENDING:-0}" -eq 1 ] || return 0
  AUDIO_PLAYBACK_VOLUME_PENDING=0
  if audio_run_helper_as_test_user --require-session audio_pipewire_volume_identity \
      "$AUDIO_PLAYBACK_VOLUME_ID" "$AUDIO_PLAYBACK_VOLUME_SERIAL" Audio/Sink &&
     audio_run_with_timeout_as_test_user --require-session 3s pw-cli set-param \
      "$AUDIO_PLAYBACK_VOLUME_ID" Props "$AUDIO_PLAYBACK_VOLUME_SAVED" &&
     arpv_current="$(audio_run_helper_as_test_user --require-session \
      audio_pipewire_volume_read "$AUDIO_PLAYBACK_VOLUME_ID")" &&
     [ "$arpv_current" = "$AUDIO_PLAYBACK_VOLUME_SAVED" ]; then
    log_info "Restored temporary playback volume/mute changes on sink $AUDIO_PLAYBACK_VOLUME_ID"
    return 0
  fi
  log_fail "Playback volume restoration could not be verified, no replacement node will be modified"
  return 1
}

# audio_pipewire_volume_restore
# EXIT handler for the isolated capture session. Restore the snapshot only when
# this test changed volume, on the original node. Verify readback or return 4.
audio_pipewire_volume_restore() {
  apvs_exit=$?
  trap - EXIT HUP INT TERM
  if [ "$apvs_changed" -eq 1 ]; then
    if audio_pipewire_volume_identity "$apvs_id" "$apvs_serial" &&
       audio_exec_with_timeout 3s pw-cli set-param "$apvs_id" Props "$apvs_saved" >&2 &&
       apvs_restored="$(audio_pipewire_volume_read "$apvs_id")" &&
       [ "$apvs_restored" = "$apvs_saved" ]; then
      printf '%s\n' "Capture volume restored: $apvs_saved" >&2
    else
      printf '%s\n' 'FAIL: capture volume restoration could not be verified, no replacement node will be modified' >&2
      apvs_exit=4
      apvs_prepared=0
    fi
  fi
  if [ "$apvs_prepared" -eq 1 ]; then
    printf '%s\n' 'AUDIO_CAPTURE_VOLUME_STATUS=complete' >&2
  else
    printf '%s\n' 'AUDIO_CAPTURE_VOLUME_STATUS=failed' >&2
  fi
  exit "$apvs_exit"
}

# audio_pipewire_volume_interrupt <exit-status>
# Stop only the current recorder before EXIT restoration on catchable signals.
audio_pipewire_volume_interrupt() {
  trap '' HUP INT TERM
  if [ -n "${aewt_pid:-}" ] && kill -0 "$aewt_pid" 2>/dev/null; then
    kill -TERM "$aewt_pid" 2>/dev/null || true
    sleep 3
    if kill -0 "$aewt_pid" 2>/dev/null; then
      kill -KILL "$aewt_pid" 2>/dev/null || true
    fi
    wait "$aewt_pid" 2>/dev/null || true
  fi
  exit "$1"
}

# audio_pipewire_capture_volume_session <id> <serial> <timeout> <command...>
# Run in the stream user/session. Snapshot, normalize, verify, record, restore.
# Stderr contains volume diagnostics, stdout contains recorder output. An absent
# optional pw-cli preserves legacy execution with a warning and no volume writes.
# Return recorder status, 3 for preparation failure, 4 for restoration failure.
audio_pipewire_capture_volume_session() (
  apvs_id="$1"
  apvs_serial="$2"
  apvs_timeout="$3"
  shift 3
  apvs_changed=0
  apvs_prepared=0
  apvs_raw=""
  aewt_pid=""
  trap 'audio_pipewire_volume_restore' EXIT
  trap 'audio_pipewire_volume_interrupt 129' HUP
  trap 'audio_pipewire_volume_interrupt 130' INT
  trap 'audio_pipewire_volume_interrupt 143' TERM
  if ! command -v pw-cli >/dev/null 2>&1; then
    printf '%s\n' 'WARN: image-provided pw-cli is absent, capture volume normalization is unavailable, existing volume is unchanged' >&2
    apvs_prepared=1
    audio_exec_with_timeout "$apvs_timeout" "$@" 2>&1
    exit $?
  fi
  if ! audio_pipewire_volume_identity "$apvs_id" "$apvs_serial" ||
     ! apvs_raw="$(audio_exec_with_timeout 3s pw-cli enum-params "$apvs_id" Props)" ||
     ! apvs_saved="$(printf '%s\n' "$apvs_raw" | audio_pipewire_volume_props saved)"; then
    printf '%s\n' 'FAIL: selected capture source volume cannot be snapshotted, recording not started' >&2
    printf '%s\n' "${apvs_raw:-No readable source properties}" >&2
    exit 3
  fi
  printf '%s\n' "Capture source id=$apvs_id serial=$apvs_serial, volume before: $apvs_saved" >&2
  apvs_unity="$(printf '%s\n' "$apvs_raw" | audio_pipewire_volume_props unity)" || exit 3
  if [ "$apvs_saved" != "$apvs_unity" ]; then
    audio_pipewire_volume_identity "$apvs_id" "$apvs_serial" || exit 3
    apvs_changed=1
    if ! audio_exec_with_timeout 3s pw-cli set-param "$apvs_id" Props "$apvs_unity" >&2; then
      printf '%s\n' 'FAIL: could not normalize the selected capture source volume' >&2
      exit 3
    fi
  fi
  if ! audio_pipewire_volume_identity "$apvs_id" "$apvs_serial" ||
     ! apvs_current="$(audio_pipewire_volume_read "$apvs_id")" ||
     [ "$apvs_current" != "$apvs_unity" ]; then
    printf '%s\n' 'FAIL: capture volume readback does not match unmuted unity gain' >&2
    exit 3
  fi
  printf '%s\n' "Capture volume ready: $apvs_current" >&2
  apvs_prepared=1
  aewt_pid=""
  audio_exec_with_timeout "$apvs_timeout" "$@" 2>&1
  exit $?
)

# audio_create_run_directory <base-directory>
# Create a unique retained run directory with traversal for desktop test users.
# Print its absolute path, only its dedicated user workspace is user-writable.
# Return nonzero when the CWD-based caller destination is not writable.
audio_create_run_directory() {
  mkdir -p "$1" || return 1
  acrd_base="$(CDPATH='' cd "$1" && pwd -P)" || return 1
  acrd_run="$(mktemp -d "$acrd_base/run-$(date -u +%Y%m%d-%H%M%S).XXXXXX")" || return 1
  chmod 0755 "$acrd_run" || return 1
  printf '%s\n' "$acrd_run"
}

# audio_record_pipewire_capture <timeout> <route> <output> <log> [rate channels seconds grace completion-marker]
# Resolve and pin the route for every attempt, never change the session default.
# With seconds supplied, use audio_record_with_progress in the volume session.
# Otherwise preserve the existing timeout wrapper and exact recorder status.
# Retain bounded before/after server evidence without recovery or retries.
# Return 3 and set AUDIO_PIPEWIRE_CAPTURE_TARGET_FAILED when discovery fails,
# so callers cannot turn a lost selected route into an unrelated ALSA fallback.
audio_record_pipewire_capture() {
  # Consumed by AudioRecord/run.sh, not by this library.
  # shellcheck disable=SC2034
  AUDIO_PIPEWIRE_CAPTURE_TARGET_FAILED=0
  if [ "${AUDIO_PIPEWIRE_CAPTURE_VOLUME_FAILED:-0}" -eq 1 ]; then
    AUDIO_PIPEWIRE_CAPTURE_TARGET_FAILED=1
    log_fail 'Capture blocked after a volume setup or restoration failure, inspect the earlier volume diagnostics'
    return 4
  fi
  arpc_timeout="$1"
  arpc_route="$2"
  arpc_output="$3"
  arpc_log="$4"
  arpc_rate="${5:-}"
  arpc_channels="${6:-}"
  arpc_seconds="${7:-}"
  arpc_grace="${8:-5}"
  arpc_completion="${9:-}"
  arpc_since="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  audio_record_server_diagnostics "$arpc_log.server-before" || true
  arpc_identity_mode=identity
  if [ "$arpc_route" = null ]; then
    arpc_identity_mode=""
  fi
  if ! arpc_identity="$(audio_run_helper_as_test_user --require-session \
      audio_pipewire_capture_target "$arpc_route" "$arpc_identity_mode" 2>>"$arpc_log.route")"; then
    # shellcheck disable=SC2034
    AUDIO_PIPEWIRE_CAPTURE_TARGET_FAILED=1
    log_fail "PipeWire capture route '$arpc_route' could not be resolved, inspect $arpc_log.route"
    log_file_with_label AUDIO-RECORD-ROUTE "$arpc_log.route" 40
    audio_record_server_diagnostics "$arpc_log.server-after" "$arpc_since" || true
    return 3
  fi
  if [ "$arpc_route" = null ]; then
    arpc_target="$arpc_identity"
  else
    arpc_id="${arpc_identity%%|*}"
    arpc_identity="${arpc_identity#*|}"
    arpc_serial="${arpc_identity%%|*}"
    arpc_target="${arpc_identity#*|}"
  fi
  set -- pw-record -v --target "$arpc_target"
  if [ -n "$arpc_rate" ]; then
    set -- "$@" "--rate=$arpc_rate" "--channels=$arpc_channels"
  fi
  set -- "$@" "$arpc_output"
  arpc_command="PipeWire capture exec: pw-record -v --target '$arpc_target' rate=${arpc_rate:-default} channels=${arpc_channels:-default} output='$arpc_output' timeout=$arpc_timeout"
  if [ -n "$arpc_seconds" ]; then
    arpc_command="$arpc_command requested=$arpc_seconds start_grace=$arpc_grace capture=sample-progress"
    if [ -n "$arpc_completion" ]; then
      set -- --until-complete "$arpc_completion" "$@"
    fi
    set -- audio_record_with_progress "$arpc_output" "$arpc_seconds" \
      "$arpc_grace" "$arpc_timeout" --pipewire-links "$@"
    # The progress helper owns the deadline and recorder PID. Run it directly
    # so its traps stop the recorder before the volume session restores state.
    arpc_timeout=0
  fi
  log_info "$arpc_command"
  printf '%s\n' "$arpc_command" >>"$arpc_log"
  if [ "$arpc_route" = null ]; then
    audio_run_with_timeout_as_test_user --require-session "$arpc_timeout" \
      "$@" >>"$arpc_log" 2>&1
    arpc_rc=$?
    audio_record_server_diagnostics "$arpc_log.server-after" "$arpc_since" || true
    return "$arpc_rc"
  fi
  printf '%s\n' 'AUDIO_CAPTURE_VOLUME_STATUS=pending' >>"$arpc_log.volume"
  audio_run_helper_as_test_user --require-session \
    audio_pipewire_capture_volume_session "$arpc_id" "$arpc_serial" \
    "$arpc_timeout" "$@" >>"$arpc_log" 2>>"$arpc_log.volume"
  arpc_rc=$?
  audio_record_server_diagnostics "$arpc_log.server-after" "$arpc_since" || true
  log_file_with_label AUDIO-CAPTURE-VOLUME "$arpc_log.volume" 60
  arpc_volume_status="$(awk -F = '/^AUDIO_CAPTURE_VOLUME_STATUS=/ { state=$2 } END { print state }' "$arpc_log.volume")"
  case "$arpc_volume_status" in
    complete)
      ;;
    *)
      # Consumed by AudioRecord fallback policy.
      # shellcheck disable=SC2034
      AUDIO_PIPEWIRE_CAPTURE_TARGET_FAILED=1
      # Consumed by AudioRecord aggregation, never hide state failures on retry.
      # shellcheck disable=SC2034
      AUDIO_PIPEWIRE_CAPTURE_VOLUME_FAILED=1
      arpc_rc=4
      ;;
  esac
  return "$arpc_rc"
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

# audio_detect_runtime_mode <explicit-overlay-request>
# Set shell-local effective mode from the CLI or loaded/built-in AudioReach
# modules. Installed files alone are not runtime evidence. Log the source,
# never install packages or change the explicit package-preparation request.
audio_detect_runtime_mode() {
  AUDIO_PLAYBACK_PROBE_FAILED=0
  AUDIO_CAPTURE_PROBE_FAILED=0
  AUDIO_OVERLAY_SERVICES_PENDING=0
  AUDIO_OVERLAY_ACCESS_CHECKED=0
  AUDIO_OVERLAY_ACTIVE="$1"
  AUDIO_OVERLAY_MODE_SOURCE=base
  if [ "$1" -eq 1 ]; then
    AUDIO_OVERLAY_MODE_SOURCE=explicit
  else
    for adrm_module in /sys/module/audioreach*; do
      [ -d "$adrm_module" ] || continue
      AUDIO_OVERLAY_ACTIVE=1
      AUDIO_OVERLAY_MODE_SOURCE="runtime-module:${adrm_module##*/}"
      break
    done
    if [ "$AUDIO_OVERLAY_ACTIVE" -eq 0 ] && [ -r /proc/modules ]; then
      adrm_module="$(awk '$1 ~ /^audioreach/ { print $1; exit }' /proc/modules)"
      if [ -n "$adrm_module" ]; then
        AUDIO_OVERLAY_ACTIVE=1
        AUDIO_OVERLAY_MODE_SOURCE="runtime-module:$adrm_module"
      fi
    fi
  fi
  log_info "Audio runtime mode: overlay=$AUDIO_OVERLAY_ACTIVE source=$AUDIO_OVERLAY_MODE_SOURCE package_request=$1"
}

# audio_overlay_live_route <playback|capture|loopback> <route> [capture-route]
# Check the live daemon/control plane and reuse the existing physical-route
# selectors. Print route|target on success, never set defaults or play a stream.
audio_overlay_live_route() {
  if ! audio_backend_ready pipewire >/dev/null 2>&1; then
    printf '%s\n' 'PipeWire daemon/control-plane check failed in the selected user session' >&2
    return 1
  fi
  case "$1" in
    playback)
      audio_select_managed_playback_route pipewire "$2"
      ;;
    capture)
      audio_select_managed_capture_route pipewire "$2"
      ;;
    loopback)
      aolr_playback="$(audio_select_managed_playback_route pipewire "$2")" || return 1
      aolr_capture="$(audio_select_managed_capture_route pipewire "$3")" || return 1
      [ -n "$aolr_playback" ] && [ -n "$aolr_capture" ] || return 1
      printf 'playback=%s capture=%s\n' "$aolr_playback" "$aolr_capture"
      ;;
    *)
      return 1
      ;;
  esac
}

# audio_wait_overlay_route <direction> <route> <artifact-prefix> <seconds> [capture-route]
# Poll the existing read-only route selector, retaining each attempt and its
# status. Return 0 with AUDIO_OVERLAY_READY_ROUTE set, or 1 after the readiness
# budget expires. Each underlying client query is bounded separately. No service
# or routing mutations, diagnostic stdout only, no functional PASS inference.
audio_wait_overlay_route() {
  awor_direction="$1"
  awor_requested="$2"
  awor_prefix="$3"
  awor_limit="$4"
  awor_capture="${5:-}"
  AUDIO_OVERLAY_READY_ROUTE=""
  awor_start="$(get_monotonic_seconds)"
  : >"$awor_prefix.log" || return 1
  log_info "Waiting for overlay PipeWire and $awor_direction route '$awor_requested', capture_route='${awor_capture:-not-applicable}', timeout=${awor_limit}s, no service reset during discovery"
  while :; do
    awor_rc=0
    audio_run_helper_as_test_user --require-session \
      audio_overlay_live_route "$awor_direction" "$awor_requested" "$awor_capture" \
      >"$awor_prefix.target" 2>"$awor_prefix.current" || awor_rc=$?
    awor_route="$(cat "$awor_prefix.target")" || return 1
    awor_elapsed=$(( $(get_monotonic_seconds) - awor_start ))
    printf 'elapsed_s=%s rc=%s direction=%s requested=%s capture_route=%s target=%s\n' \
      "$awor_elapsed" "$awor_rc" "$awor_direction" "$awor_requested" \
      "${awor_capture:-not-applicable}" "$awor_route" >>"$awor_prefix.log" || return 1
    cat "$awor_prefix.current" >>"$awor_prefix.log" || return 1
    if [ "$awor_rc" -eq 0 ] && [ -n "$awor_route" ]; then
      AUDIO_OVERLAY_READY_ROUTE="$awor_route"
      return 0
    fi
    if [ "$awor_rc" -eq 0 ]; then
      printf '%s\n' 'Route discovery returned no target' >>"$awor_prefix.log" || return 1
    fi
    [ "$awor_elapsed" -lt "$awor_limit" ] || break
    sleep 1
  done
  log_file_with_label AUDIO-OVERLAY-ROUTE "$awor_prefix.log" 40
  return 1
}

# audio_overlay_units_idle <expected-unit-snapshot> <current-unit-snapshot>
# Check an exact canonical unit set with no jobs or transitional states.
# Return 0 if settled, 1 otherwise. Read-only, no stdout.
audio_overlay_units_idle() {
  awk -F '|' '
    NR==FNR { expected[$1]=1; count++; next }
    {
      seen++
      if (!($1 in expected) || found[$1]++ || $5!="0") bad=1
      if ($2!="active" && $2!="inactive" && $2!="failed") bad=1
    }
    END { exit (bad || !count || seen!=count) }
  ' "$1" "$2"
}

# audio_overlay_failure_diagnostics <artifact-directory> <journal-since>
# Reuse bounded server/session diagnostics before incomplete-setup rollback can
# replace crash evidence. Replay retained evidence to stdout. Diagnostic tools
# are optional and do not change the original failure or service state.
audio_overlay_failure_diagnostics() {
  aofd_dir="$1"
  audio_record_server_diagnostics "$aofd_dir/failure-server.log" "$2" readiness || true
  audio_run_with_timeout_as_test_user --require-session 5s wpctl status \
    >"$aofd_dir/failure-nodes.log" 2>&1 ||
    printf 'PipeWire node inventory unavailable, rc=%s\n' "$?" >>"$aofd_dir/failure-nodes.log"
  log_file_with_label AUDIO-OVERLAY-SERVER "$aofd_dir/failure-server.log" 180
  log_file_with_label AUDIO-OVERLAY-NODES "$aofd_dir/failure-nodes.log" 60
  aofd_init_rc=0
  audio_check_overlay_initialization_errors "$aofd_dir/failure-server.log" \
    "$aofd_dir/initialization-errors.log" || aofd_init_rc=$?
  if [ "$aofd_init_rc" -eq 1 ]; then
    log_file_with_label AUDIO-OVERLAY-INIT "$aofd_dir/initialization-errors.log" 20
    aofd_summary="$(head -n 3 "$aofd_dir/initialization-errors.log" | tr '\n' ' ')"
    AUDIO_OVERLAY_FAILURE_REASON="${AUDIO_OVERLAY_FAILURE_REASON:+$AUDIO_OVERLAY_FAILURE_REASON. }AudioReach initialization evidence: $aofd_summary Check image-provided calibration/configuration and service access, details=$aofd_dir/initialization-errors.log"
  elif [ "$aofd_init_rc" -ne 0 ]; then
    log_warn "Overlay initialization journal evidence is incomplete, no clean initialization result is inferred"
  fi
}

# audio_overlay_read_units <artifact-file> [--user] <units...>
# Capture systemd properties in one bounded query. Write canonical ID, active
# state, substate, result and job ID as pipe-separated rows, retaining raw
# properties (including configured timeouts) alongside them. --user queries the
# prepared test user's manager but writes artifacts as the caller. No stdout data.
audio_overlay_read_units() {
  aoru_file="$1"
  shift
  aoru_rc=0
  if [ "${1:-}" = "--user" ]; then
    audio_run_with_timeout_as_test_user --require-session 5s systemctl show --all --no-pager \
      --property=Id,ActiveState,SubState,Result,Job,TimeoutStartUSec,TimeoutStopUSec \
      "$@" >"$aoru_file.raw" 2>&1 || aoru_rc=$?
  else
    audio_exec_with_timeout 5s systemctl show --all --no-pager \
      --property=Id,ActiveState,SubState,Result,Job,TimeoutStartUSec,TimeoutStopUSec \
      "$@" >"$aoru_file.raw" 2>&1 || aoru_rc=$?
  fi
  if [ "$aoru_rc" -ne 0 ]; then
    log_fail "Overlay systemctl show failed: rc=$aoru_rc units=$*, artifact=$aoru_file.raw"
    return 1
  fi
  if ! awk '
    BEGIN { RS=""; FS="\n" }
    {
      id=""; state=""; substate=""; result=""; job=""; job_seen=0
      for (i=1; i<=NF; i++) {
        key=$i; sub(/=.*/, "", key)
        value=$i; sub(/^[^=]*=/, "", value)
        if (key=="Id") id=value
        if (key=="ActiveState") state=value
        if (key=="SubState") substate=value
        if (key=="Result") result=value
        if (key=="Job") { job=value; job_seen=1 }
      }
      sub(/[[:space:]].*$/, "", job)
      if (job=="") job="0"
      if (id=="" || state=="" || substate=="" || !job_seen || job !~ /^[0-9]+$/) bad=1
      else if (!seen[id]++) print id "|" state "|" substate "|" result "|" job
    }
    END { if (bad || NR==0) exit 1 }
  ' "$aoru_file.raw" >"$aoru_file"; then
    log_fail "Overlay unit properties are incomplete, artifact=$aoru_file.raw"
    return 1
  fi
  return 0
}

# audio_overlay_service_action <start|stop> <artifact-prefix> <units...>
# Queue a nonblocking systemd transaction, then wait for every requested unit
# to reach the target state with no pending job. Use the existing bounded
# PIPEWIRE_SYSTEMCTL_TIMEOUT policy (default 180s), not a stop-client watchdog.
# Refuse pre-existing jobs. On timeout report outstanding jobs without cancelling
# unrelated work, restoration also refuses to race a still-pending transaction.
audio_overlay_service_action() {
  aosa_action="$1"
  aosa_prefix="$2"
  shift 2
  [ "$#" -gt 0 ] || return 0
  case "$aosa_action" in
    start|stop)
      ;;
    *)
      return 1
      ;;
  esac
  aosa_limit="${PIPEWIRE_SYSTEMCTL_TIMEOUT:-180}"
  case "$aosa_limit" in
    ''|0|*[!0-9]*)
      log_fail "Invalid PIPEWIRE_SYSTEMCTL_TIMEOUT, expected positive seconds"
      return 1
      ;;
  esac
  if ! [ "$aosa_limit" -gt 0 ] 2>/dev/null; then
    log_fail "Invalid PIPEWIRE_SYSTEMCTL_TIMEOUT, expected positive seconds"
    return 1
  fi
  audio_overlay_read_units "$aosa_prefix.before" "$@" || return 1
  for aosa_unit in "$@"; do
    if ! awk -F '|' -v unit="$aosa_unit" '$1==unit { found=1 } END { exit !found }' "$aosa_prefix.before"; then
      log_fail "Overlay $aosa_action has no state for requested unit $aosa_unit"
      return 1
    fi
  done
  if ! awk -F '|' '$5 != "0" { bad=1 } END { exit bad }' "$aosa_prefix.before"; then
    log_fail "Overlay $aosa_action was not queued, units already have pending jobs"
    log_file_with_label AUDIO-OVERLAY-JOBS "$aosa_prefix.before" 32
    return 1
  fi
  aosa_start="$(get_monotonic_seconds)"
  log_info "Overlay command: systemctl --no-block --no-ask-password $aosa_action $*, completion_timeout=${aosa_limit}s"
  if audio_exec_with_timeout 10s systemctl --no-block --no-ask-password \
      "$aosa_action" "$@" >"$aosa_prefix.command.log" 2>&1; then
    aosa_rc=0
  else
    aosa_rc=$?
  fi
  log_info "Overlay command submission: action=$aosa_action rc=$aosa_rc, artifact=$aosa_prefix.command.log"
  log_file_with_label AUDIO-OVERLAY-COMMAND "$aosa_prefix.command.log" 40
  [ "$aosa_rc" -eq 0 ] || return 1
  aosa_previous=""
  aosa_next_log=0
  while :; do
    audio_overlay_read_units "$aosa_prefix.current" "$@" || return 1
    aosa_elapsed=$(( $(get_monotonic_seconds) - aosa_start ))
    aosa_current="$(cat "$aosa_prefix.current")"
    if [ "$aosa_current" != "$aosa_previous" ] || [ "$aosa_elapsed" -ge "$aosa_next_log" ]; then
      log_info "Overlay $aosa_action progress: elapsed_s=$aosa_elapsed, fields=unit|active|substate|result|job"
      log_file_with_label AUDIO-OVERLAY-JOB "$aosa_prefix.current" 32
      aosa_previous="$aosa_current"
      aosa_next_log=$((aosa_elapsed + 10))
    fi
    if awk -F '|' -v action="$aosa_action" '
      NR==FNR { initial[$1]=$2; count++; next }
      {
        seen++
        if (!($1 in initial)) bad=1
        if ($5 != "0") { pending=1; next }
        if (action=="start") {
          if ($2=="failed") bad=1
          else if ($2!="active") pending=1
        } else {
          if ($2=="failed" && initial[$1]!="failed") bad=1
          else if ($2!="inactive" && $2!="failed") pending=1
        }
      }
      END {
        if (bad || seen!=count) exit 3
        if (pending) exit 1
      }
    ' "$aosa_prefix.before" "$aosa_prefix.current"; then
      log_info "Overlay $aosa_action completed: elapsed_s=$aosa_elapsed, no pending unit jobs"
      return 0
    else
      aosa_state_rc=$?
      if [ "$aosa_state_rc" -eq 3 ]; then
        log_fail "Overlay $aosa_action failed, inspect unit states/results in $aosa_prefix.current.raw"
        return 1
      fi
    fi
    if [ "$aosa_elapsed" -ge "$aosa_limit" ]; then
      log_fail "Overlay $aosa_action completion timed out after ${aosa_elapsed}s, outstanding states/jobs are in $aosa_prefix.current. Systemd jobs may still be pending"
      return 1
    fi
    sleep 1
  done
}

# audio_overlay_client_prerequisites <playback|capture|loopback>
# Check installed route and stream clients in the calling user's PATH before
# service preparation or polling. No package recovery or service operations.
# Return 0 when available, 1 with the missing capability on stderr. No stdout.
audio_overlay_client_prerequisites() (
  aocp_missing=""
  command -v wpctl >/dev/null 2>&1 || aocp_missing="wpctl"
  case "$1" in
    playback|loopback)
      if ! command -v pw-play >/dev/null 2>&1; then
        aocp_help=""
        if command -v pw-cat >/dev/null 2>&1; then
          aocp_help="$(audio_exec_with_timeout 3s pw-cat --help 2>&1)" || aocp_help=""
        fi
        if ! printf '%s\n' "$aocp_help" | grep -q -- '--playback'; then
          aocp_missing="${aocp_missing:+$aocp_missing, }pw-play or pw-cat with --playback"
        fi
      fi
      ;;
    capture)
      ;;
    *)
      printf 'Invalid overlay direction: %s\n' "$1" >&2
      return 1
      ;;
  esac
  case "$1" in
    capture|loopback)
      if ! command -v pw-record >/dev/null 2>&1; then
        aocp_missing="${aocp_missing:+$aocp_missing, }pw-record"
      fi
      ;;
  esac
  if [ -n "$aocp_missing" ]; then
    printf 'Missing image-provided overlay %s capabilities: %s. Provision the matching PipeWire/WirePlumber clients in the image\n' \
      "$1" "$aocp_missing" >&2
    return 1
  fi
  return 0
)

# audio_validate_overlay_readiness <playback|capture|loopback> <route> [capture-route]
# Check image-provided clients, then prepare desktop runtime for both explicit
# and detected overlays. Validate heap access and PipeWire after DSP preparation, in
# the same user context as the stream. Native modem overlays reuse a healthy
# live route after bounded discovery. Attempt startup once only for an inactive
# or failed PipeWire service. Roll back incomplete preparation, but retain
# successfully prepared native services for subsequent tests and reruns.
# Return 0 when ready, 1 on failure, with diagnostics on stdout/stderr.
audio_validate_overlay_readiness() {
  avor_direction="$1"
  avor_requested="$2"
  avor_capture="${3:-}"
  AUDIO_OVERLAY_FAILURE_REASON=""
  mkdir -p "$LOGDIR/overlay-services" || return 1
  avor_since="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  if ! audio_run_helper_as_test_user --require-session \
      audio_overlay_client_prerequisites "$avor_direction" \
      >"$LOGDIR/overlay-services/clients.log" 2>&1; then
    AUDIO_OVERLAY_FAILURE_REASON="Overlay $avor_direction client preflight failed, $(cat "$LOGDIR/overlay-services/clients.log")"
    log_fail "$AUDIO_OVERLAY_FAILURE_REASON"
    return 1
  fi
  # Package opt-in remains separate. Never start a desktop service on ramdisk
  # or route native system services through a desktop-user helper.
  if [ "${SYSTEMD_AVAILABLE:-0}" -eq 1 ] &&
     { [ "${AUDIO_PLAYBACK_DESKTOP_ROOT_MODE:-0}" -eq 1 ] ||
       [ "${AUDIO_RECORD_DESKTOP_ROOT_MODE:-0}" -eq 1 ]; }; then
    if ! audio_prepare_overlay_runtime 1; then
      AUDIO_OVERLAY_FAILURE_REASON="Desktop overlay runtime preparation failed, inspect service/session and device-access diagnostics"
      log_fail "$AUDIO_OVERLAY_FAILURE_REASON"
      audio_overlay_failure_diagnostics "$LOGDIR/overlay-services" "$avor_since"
      return 1
    fi
  fi
  avor_timeout="${PIPEWIRE_READY_TIMEOUT:-120}"
  case "$avor_timeout" in
    ''|*[!0-9]*)
      avor_timeout=120
      ;;
  esac
  avor_modem=0
  if audio_overlay_modem_selected; then
    avor_modem=1
  fi
  if ! audio_prepare_modem_overlay_services "$avor_direction" "$avor_requested" "$avor_timeout" "$avor_capture"; then
    audio_overlay_failure_diagnostics "$LOGDIR/overlay-services" "$avor_since"
    return 1
  fi
  if [ "${AUDIO_OVERLAY_ACCESS_CHECKED:-0}" -eq 0 ]; then
    audio_validate_overlay_device_access "$avor_modem" || return 1
  fi
  # Native reuse has already waited and refreshed all unit states. Do not
  # introduce a second discovery window after that successful decision.
  if [ -n "${AUDIO_OVERLAY_READY_ROUTE:-}" ] ||
     audio_wait_overlay_route "$avor_direction" "$avor_requested" \
       "$LOGDIR/overlay-services/route-check" "$avor_timeout" "$avor_capture"; then
    log_info "Overlay live $avor_direction route ready: $AUDIO_OVERLAY_READY_ROUTE"
    if [ "${AUDIO_OVERLAY_SERVICES_PENDING:-0}" -eq 1 ]; then
      AUDIO_OVERLAY_SERVICES_PENDING=0
      log_info "Retaining prepared native overlay services for reuse, initial state remains in $AUDIO_OVERLAY_SERVICE_SNAPSHOT. Temporary capture processes and volume changes still require cleanup"
    fi
    return 0
  fi
  AUDIO_OVERLAY_FAILURE_REASON="Image-provided overlay PipeWire or requested $avor_direction route '$avor_requested' capture_route='${avor_capture:-not-applicable}' is not ready, inspect service/session and AudioReach configuration in $LOGDIR/overlay-services"
  log_fail "$AUDIO_OVERLAY_FAILURE_REASON"
  audio_overlay_failure_diagnostics "$LOGDIR/overlay-services" "$avor_since"
  return 1
}

# audio_validate_overlay_device_access <modem-required> [service-user]
# Wait for modem ABI nodes and log their current permissions without changing
# ownership or mode. Verify access in the actual test-user context. The daemon
# user is logged separately, successful PipeWire readiness/streaming is still
# required and is not inferred from the client-side device access check.
audio_validate_overlay_device_access() {
  if [ "$1" -eq 1 ]; then
    avoda_heap="$(audio_overlay_heap_node 1)"
    log_info "Modem-overlay service user=${2:-${AUDIO_TEST_UID:-current-user}}, device permissions are left unchanged"
    for avoda_node in /dev/aud_pasthru_modem "$avoda_heap"; do
      if ! wait_for_path "$avoda_node" 10 || [ ! -c "$avoda_node" ]; then
        log_fail "Modem overlay device is missing or not a character device: $avoda_node"
        return 1
      fi
      avoda_state="$(stat -c '%a %U:%G %u:%g' "$avoda_node")" || return 1
      log_info "Modem-overlay device: $avoda_node mode/owner=$avoda_state"
    done
  fi
  audio_run_helper_as_test_user audio_validate_dma_heap_access "$1" || return 1
  AUDIO_OVERLAY_ACCESS_CHECKED=1
  return 0
}


# audio_overlay_modem_selected
# Return 0 only for the runtime-selected audio modem, with no numeric instance
# or board mapping. This is an internal policy check and produces no stdout.
audio_overlay_modem_selected() {
  [ -n "${AUDIO_REMOTE_PROC_PATH:-}" ] || return 1
  [ -r "$AUDIO_REMOTE_PROC_PATH/name" ] || return 1
  aoms_name="$(cat "$AUDIO_REMOTE_PROC_PATH/name")"
  audio_remoteproc_is_modem "$aoms_name"
}

# audio_prepare_modem_overlay_services <direction> <route> [wait-seconds] [capture-route]
# Prepare native Config2 services after DSP preparation. Discover installed
# PipeWire/WirePlumber units and snapshot activity. Reuse active PipeWire after
# bounded route discovery, otherwise attempt one reset-and-start transaction.
# Check canonical units for pending jobs before reuse or startup,
# without requiring optional inactive units to be active. Desktop sessions and
# images without systemd keep their existing paths. Return 1 for setup failure.
audio_prepare_modem_overlay_services() {
  AUDIO_OVERLAY_READY_ROUTE=""
  audio_overlay_modem_selected || return 0
  [ "${SYSTEMD_AVAILABLE:-0}" -eq 1 ] || return 0
  [ "${AUDIO_PLAYBACK_DESKTOP_ROOT_MODE:-0}" -eq 0 ] || return 0
  [ "${AUDIO_RECORD_DESKTOP_ROOT_MODE:-0}" -eq 0 ] || return 0
  [ "${AUDIO_OVERLAY_SERVICES_PENDING:-0}" -eq 0 ] || return 0
  apos_direction="$1"
  apos_requested="$2"
  apos_timeout="${3:-120}"
  apos_capture="${4:-}"
  apos_out="$LOGDIR/overlay-services"
  mkdir -p "$apos_out" || return 1
  audio_validate_overlay_device_access 1 || return 1
  audio_exec_with_timeout 10s systemctl list-unit-files --no-legend --no-pager \
    'pipewire*' 'wireplumber*' >"$apos_out/inventory.log" 2>&1 || return 1
  apos_units="$(awk '{print $1}' "$apos_out/inventory.log")"
  AUDIO_OVERLAY_SERVICE_SNAPSHOT="$apos_out/initial-state.txt"
  : >"$AUDIO_OVERLAY_SERVICE_SNAPSHOT" || return 1
  apos_count=0
  apos_pipewire=0
  set --
  for apos_unit in $apos_units; do
    case "$apos_unit" in
      *[!a-zA-Z0-9_.@-]*|*@*)
        continue
        ;;
      pipewire*.service|pipewire*.socket|wireplumber.service|wireplumber.socket)
        ;;
      *)
        continue
        ;;
    esac
    audio_overlay_read_units "$apos_out/unit-query" "$apos_unit" || return 1
    if [ "$(wc -l <"$apos_out/unit-query")" -ne 1 ]; then
      log_fail "Overlay unit query did not identify one canonical unit: $apos_unit"
      return 1
    fi
    apos_id="$(cut -d'|' -f1 "$apos_out/unit-query")"
    case "$apos_id" in
      *[!a-zA-Z0-9_.-]*)
        log_fail "Overlay unit query returned an invalid canonical ID: $apos_unit"
        return 1
        ;;
      pipewire*.service|pipewire*.socket|wireplumber.service|wireplumber.socket)
        ;;
      *)
        log_fail "Overlay unit alias resolves outside the audio unit set: $apos_unit -> $apos_id"
        return 1
        ;;
    esac
    if cut -d'|' -f1 "$AUDIO_OVERLAY_SERVICE_SNAPSHOT" | grep -F -x "$apos_id" >/dev/null; then
      log_info "Overlay unit alias already included: $apos_unit -> $apos_id"
      continue
    fi
    apos_unit="$apos_id"
    apos_count=$((apos_count + 1))
    [ "$apos_count" -le 32 ] || return 1
    apos_state="$(cut -d'|' -f2 "$apos_out/unit-query")"
    case "$apos_state" in
      active|inactive|failed)
        ;;
      *)
        log_fail "Cannot safely reuse or start $apos_unit while its state is '$apos_state'"
        return 1
        ;;
    esac
    printf '%s|%s\n' "$apos_unit" "$apos_state" >>"$AUDIO_OVERLAY_SERVICE_SNAPSHOT" || return 1
    [ "$apos_unit" != pipewire.service ] || apos_pipewire=1
    set -- "$@" "$apos_unit"
  done
  if [ "$apos_pipewire" -ne 1 ]; then
    log_fail "Modem overlay has no installed pipewire.service, provision the image service configuration"
    return 1
  fi
  # Refresh all canonical units together before route discovery. Do not reuse
  # or queue a start while another audio service/socket job is outstanding.
  audio_overlay_read_units "$apos_out/preflight-units" "$@" || return 1
  log_file_with_label AUDIO-OVERLAY-PREFLIGHT "$apos_out/preflight-units" 32
  if ! audio_overlay_units_idle "$AUDIO_OVERLAY_SERVICE_SNAPSHOT" "$apos_out/preflight-units"; then
    log_fail "Cannot reuse or start overlay audio units with pending jobs, transitional states or incomplete inventory. Inspect $apos_out/preflight-units and retry after the jobs settle"
    return 1
  fi
  if awk -F '|' '$1=="pipewire.service" && $2=="active" { ready=1 } END { exit !ready }' "$apos_out/preflight-units"; then
    if ! audio_wait_overlay_route "$apos_direction" "$apos_requested" "$apos_out/reuse-route" "$apos_timeout" "$apos_capture"; then
      AUDIO_OVERLAY_FAILURE_REASON="Running PipeWire did not expose a ready $apos_direction route '$apos_requested' capture_route='${apos_capture:-not-applicable}' within ${apos_timeout}s, no service reset was attempted. Check image route configuration and session access in $apos_out"
      log_fail "$AUDIO_OVERLAY_FAILURE_REASON"
      return 1
    fi
    audio_overlay_read_units "$apos_out/reuse-units" "$@" || return 1
    if ! audio_overlay_units_idle "$AUDIO_OVERLAY_SERVICE_SNAPSHOT" "$apos_out/reuse-units" ||
       ! awk -F '|' '$1=="pipewire.service" && $2=="active" { ready=1 } END { exit !ready }' "$apos_out/reuse-units"; then
      AUDIO_OVERLAY_FAILURE_REASON="Audio service state changed during route discovery, no service reset was attempted. Inspect $apos_out/reuse-units"
      log_fail "$AUDIO_OVERLAY_FAILURE_REASON"
      log_file_with_label AUDIO-OVERLAY-JOB "$apos_out/reuse-units" 32
      return 1
    fi
    log_info "Reusing ready modem-overlay PipeWire control plane: $apos_direction route=$AUDIO_OVERLAY_READY_ROUTE, all discovered audio units have no pending jobs, no service reset. Functional audio validation is still required"
    return 0
  fi
  awk -F '|' '{ print $1 "|" $2 }' "$apos_out/preflight-units" \
    >"$AUDIO_OVERLAY_SERVICE_SNAPSHOT" || return 1
  apos_user="$(audio_exec_with_timeout 5s systemctl show \
    --property=User --value pipewire.service 2>>"$apos_out/setup.log")" || return 1
  [ -n "$apos_user" ] || apos_user=root
  log_file_with_label AUDIO-OVERLAY-INITIAL "$AUDIO_OVERLAY_SERVICE_SNAPSHOT" 32
  audio_validate_overlay_device_access 1 "$apos_user" || return 1
  # Mark cleanup ownership before the one recovery attempt can change state.
  AUDIO_OVERLAY_SERVICES_PENDING=1
  log_info "Recovering inactive or failed modem-overlay pipewire.service with one reset-and-start attempt"
  if ! audio_overlay_service_action stop "$apos_out/setup-stop" "$@"; then
    AUDIO_OVERLAY_FAILURE_REASON="Overlay service stop failed during recovery, inspect $apos_out/setup-stop.current.raw and failure-server.log for crash or pending-job evidence"
    return 1
  fi
  audio_validate_overlay_device_access 1 "$apos_user" || return 1
  if ! audio_overlay_service_action start "$apos_out/setup-start" pipewire.service; then
    AUDIO_OVERLAY_FAILURE_REASON="Overlay PipeWire start failed during initialization, inspect $apos_out/setup-start.current.raw and failure-server.log"
    return 1
  fi
  return 0
}

# audio_restore_overlay_services
# Restore recorded activity, stopping only units that were not initially active.
# Previously failed units return to inactive, their original failure is retained
# in the snapshot. Return 1 if restoration cannot be completed and verified.
audio_restore_overlay_services() {
  [ "${AUDIO_OVERLAY_SERVICES_PENDING:-0}" -eq 1 ] || return 0
  if [ ! -r "$AUDIO_OVERLAY_SERVICE_SNAPSHOT" ] ||
     [ ! -s "$AUDIO_OVERLAY_SERVICE_SNAPSHOT" ]; then
    log_fail "Overlay service activity snapshot is missing or unreadable: $AUDIO_OVERLAY_SERVICE_SNAPSHOT"
    return 1
  fi
  aros_rc=0
  aros_log="${AUDIO_OVERLAY_SERVICE_SNAPSHOT%/*}/restore.log"
  set --
  while IFS='|' read -r aros_unit aros_initial; do
    set -- "$@" "$aros_unit"
  done <"$AUDIO_OVERLAY_SERVICE_SNAPSHOT"
  aros_preflight="${AUDIO_OVERLAY_SERVICE_SNAPSHOT%/*}/restore-preflight"
  audio_overlay_read_units "$aros_preflight" "$@" || return 1
  if ! awk -F '|' '$5!="0" { bad=1 } END { exit bad }' "$aros_preflight"; then
    log_fail "Overlay restoration was not queued, audio units still have pending jobs"
    log_file_with_label AUDIO-OVERLAY-JOBS "$aros_preflight" 32
    return 1
  fi
  for aros_action in stop start; do
    set --
    while IFS='|' read -r aros_unit aros_initial; do
      case "$aros_action:$aros_initial" in
        start:active|stop:inactive|stop:failed)
          set -- "$@" "$aros_unit"
          ;;
      esac
    done <"$AUDIO_OVERLAY_SERVICE_SNAPSHOT"
    if [ "$#" -gt 0 ]; then
      audio_overlay_service_action "$aros_action" \
        "${AUDIO_OVERLAY_SERVICE_SNAPSHOT%/*}/restore-$aros_action" "$@" || aros_rc=1
    fi
  done
  while IFS='|' read -r aros_unit aros_initial; do
    aros_state="$(audio_exec_with_timeout 5s systemctl show \
      --property=ActiveState --value "$aros_unit" 2>>"$aros_log")" || aros_rc=1
    case "$aros_initial:$aros_state" in
      active:active|inactive:inactive|failed:inactive|failed:failed)
        ;;
      *)
        log_warn "Overlay service activity restoration failed: $aros_unit initial=$aros_initial current=$aros_state"
        aros_rc=1
        ;;
    esac
  done <"$AUDIO_OVERLAY_SERVICE_SNAPSHOT"
  AUDIO_OVERLAY_SERVICES_PENDING=0
  if [ "$aros_rc" -eq 0 ]; then
    log_info "Restored initial overlay service activity, snapshot=$AUDIO_OVERLAY_SERVICE_SNAPSHOT"
  fi
  return "$aros_rc"
}

# audio_cleanup_runtime
# Run existing daemon cleanup and restore any modem-overlay service activity.
# Service rollback applies only when native overlay preparation was incomplete.
# Publish FAIL through the shared lifecycle if restoration fails, including
# when cleanup follows an otherwise successful stream result.
audio_cleanup_runtime() {
  acr_cleanup_rc=0
  audio_restore_playback_volume || acr_cleanup_rc=1
  audio_cleanup_started_daemons
  audio_restore_overlay_services || acr_cleanup_rc=1
  if [ "$acr_cleanup_rc" -ne 0 ]; then
    test_result_init "${RESULT_TESTNAME:-$TESTNAME}" "$RES_FILE" || exit 1
    test_result_record FAIL "$TESTNAME FAIL - temporary audio state restoration or incomplete-setup rollback failed, inspect $LOGDIR"
    test_result_finish
  fi
}

# audio_discovery_finish <playback|capture> <reason> [optional-client]
# Finish an unsuccessful discovery through the shared result lifecycle. Absent
# optional routes SKIP, but explicit/overlay requirements, applicable prepared
# DSPs and attempted candidate failures FAIL. Retain kernel evidence on FAIL.
# This is terminal orchestration, test_result_finish exits the runner.
audio_discovery_finish() {
  adf_direction="$1"
  adf_reason="$2"
  adf_status=SKIP
  case "$adf_direction" in
    playback)
      adf_failed="${AUDIO_PLAYBACK_PROBE_FAILED:-0}"
      adf_explicit="${AUDIO_PLAYBACK_ROUTE_EXPLICIT:-0}"
      ;;
    capture)
      adf_failed="${AUDIO_CAPTURE_PROBE_FAILED:-0}"
      adf_explicit="${AUDIO_CAPTURE_ROUTE_EXPLICIT:-0}"
      ;;
    *)
      adf_failed=1
      adf_explicit=0
      ;;
  esac
  if [ "$adf_failed" -eq 1 ] ||
     [ "${AUDIO_OVERLAY_ACTIVE:-${AUDIO_OVERLAY_REQUESTED:-0}}" -eq 1 ] ||
     { [ "${3:-}" != optional-client ] &&
       { [ "$adf_explicit" -eq 1 ] || [ -n "${AUDIO_BACKEND_REQUESTED:-}" ] ||
         [ "${audio_remoteproc_rc:-2}" -eq 0 ]; }; }; then
    adf_status=FAIL
    for adf_artifact in setup.log restore.log; do
      if [ -s "$LOGDIR/overlay-services/$adf_artifact" ]; then
        log_file_with_label AUDIO-OVERLAY "$LOGDIR/overlay-services/$adf_artifact" 40
      fi
    done
    if [ -n "${AUDIO_OVERLAY_FAILURE_REASON:-}" ]; then
      adf_reason="$adf_reason, $AUDIO_OVERLAY_FAILURE_REASON"
    else
      adf_reason="$adf_reason, inspect the retained ALSA probe logs, runtime routing and image audio services"
    fi
    if [ "${DMESG_SCAN:-1}" -eq 1 ]; then
      scan_audio_dmesg "$LOGDIR/discovery-failure"
      audio_remoteproc_report_health "$LOGDIR/discovery-failure" || true
    fi
  fi
  test_result_init "$RESULT_TESTNAME" "$RES_FILE" || exit 1
  test_result_record "$adf_status" "$TESTNAME $adf_status - $adf_reason"
  test_result_finish
}

# audio_backend_for_mode <requested-backend> <effective-overlay-mode>
# Print the effective request. Detected or explicit overlay requires PipeWire,
# never a successful base ALSA fallback. Base-mode selection is unchanged.
audio_backend_for_mode() {
  case "$2:$1" in
    0:*)
      printf '%s\n' "$1"
      ;;
    1:|1:pipewire)
      printf '%s\n' pipewire
      ;;
    *)
      printf '%s\n' 'AudioReach overlay validation requires the PipeWire backend' >&2
      return 1
      ;;
  esac
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
# Exit codes: 0=success, 1=directory not found or no clips, 2=discovery error
discover_audio_clips() {
  clips_dir="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"
  
  # Check directory exists
  if [ ! -d "$clips_dir" ]; then
    log_error "Clips directory not found: $clips_dir" >&2
    return 1
  fi
  
  # Find .wav files (only in top level, not recursive)
  if ! clips="$(find "$clips_dir" -maxdepth 1 -name "*.wav" -type f)"; then
    log_error "Cannot enumerate clips in $clips_dir, check directory permissions and find support" >&2
    return 2
  fi
  clips="$(printf '%s\n' "$clips" | sort)" || return 2
  
  # Check if any clips found
  if [ -z "$clips" ]; then
    log_error "No .wav files found in $clips_dir" >&2
    return 1
  fi
  
  # Output basenames only to stdout
  while IFS= read -r clip; do
    clip_basename="${clip##*/}"
    case "$clip_basename" in
      *[[:space:]]*)
        log_error "Clip filenames containing whitespace are not supported by the selector list: $clip_basename" >&2
        return 2
        ;;
    esac
    printf '%s\n' "$clip_basename"
  done <<EOF
$clips
EOF
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
    if [ "$clip" = "$requested_name" ]; then
      printf '%s\n' "$clip"
      return 0
    fi
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

# audio_validate_clip_selectors <space-separated-selectors>
# Validate syntax independently of installed assets, before service preparation.
# Accept existing index/semantic names and exact WAV basenames. No stdout data.
# Return 1 for malformed names, 0 otherwise. Asset availability is separate.
audio_validate_clip_selectors() {
  for avcs_name in $1; do
    if printf '%s\n' "$avcs_name" |
       grep -Eq '^(playback_config|[Cc]onfig)0*[1-9][0-9]*$|^play_[0-9]+([.][0-9]+)?KHz_[0-9]+b_[0-9]+ch$'; then
      continue
    fi
    case "$avcs_name" in
      */*|playback_config*|[Cc]onfig*)
        ;;
      *.wav)
        continue
        ;;
    esac
    log_error "Malformed clip selector '$avcs_name', use playback_configN (N greater than zero), play_RATEKHz_BITSb_CHANNELSch or an exact WAV basename" >&2
    return 1
  done
  return 0
}

# audio_log_clip_inventory <newline-separated-filenames>
# Log available runtime filenames, index aliases and parsed semantic selectors
# to stderr. Unparseable names remain selectable by exact basename or index.
audio_log_clip_inventory() {
  alci_index=0
  for alci_clip in $1; do
    alci_index=$((alci_index + 1))
    alci_name="$(generate_clip_testcase_name "$alci_clip" 2>/dev/null || true)"
    log_info "Available clip: playback_config$alci_index filename='$alci_clip' semantic='${alci_name:-unavailable}'" >&2
  done
}

# Discover and filter clips based on user input
# Input: clip_names (explicit list), clip_filter (pattern filter)
# Output: final list of clip filenames to test (to stdout)
# Logs error messages to stderr
# Returns: 0=success, 1=malformed selector, 2=discovery error, 3=missing assets.
# Never silently run a partial explicit selection when another asset is absent.
discover_and_filter_clips() {
  clip_names="$1"
  clip_filter="$2"
  
  audio_validate_clip_selectors "$clip_names" || return 1
  clip_discovery_rc=0
  available_clips="$(discover_audio_clips)" || clip_discovery_rc=$?
  case "$clip_discovery_rc" in
    0)
      ;;
    1)
      return 3
      ;;
    *)
      return 2
      ;;
  esac
  audio_log_clip_inventory "$available_clips"
  
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
    
    if [ -n "$failed_names" ]; then
      log_warn "Requested clip assets were not matched: $failed_names. No partial selection will run, provision the matching WAV files or use a listed selector" >&2
      return 3
    fi
    
    printf '%s\n' "$validated"
    return 0
  fi
  
  # Apply filter if provided
  if [ -n "$clip_filter" ]; then
    filtered="$(apply_clip_filter "$clip_filter" "$available_clips")" || {
      log_error "Filter did not match any clips" >&2
      return 3
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
    record_48KHz_1ch)
      printf '%s\n' "48000 1"
      ;;
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
  log_error "Available configs: record_config1-record_config10, record_8KHz_1ch, record_16KHz_1ch, record_16KHz_2ch, record_24KHz_1ch, record_32KHz_2ch, record_44.1KHz_2ch, record_48KHz_1ch, record_48KHz_2ch, record_48KHz_6ch, record_96KHz_2ch, record_96KHz_6ch" >&2
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
# Reuses an existing writable runtime dir, otherwise creates a private CWD child.
audio_ensure_runtime_dir() {
  uid_now="$(id -u 2>/dev/null || echo 0)"

  if [ -n "${AUDIO_RUNTIME_DIR:-}" ]; then
    run_dir="$AUDIO_RUNTIME_DIR"
  elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
    return 0
  elif [ -d "/run/user/$uid_now" ] && [ -w "/run/user/$uid_now" ]; then
    run_dir="/run/user/$uid_now"
  else
    # Unix socket paths are limited to 107 bytes. Avoid the deeper run-log path
    # and leave room for PipeWire's socket names below this private directory.
    runtime_parent="${AUDIO_WORK_DIR:-$(pwd -P)}"
    run_dir="$(mktemp -d "$runtime_parent/.ar.XXXXXX")" || return 1
    if [ "$(printf '%s' "$run_dir" | wc -c)" -gt 88 ]; then
      log_fail "CWD is too long for a private PipeWire socket directory, launch from a shorter writable directory: $runtime_parent"
      rmdir "$run_dir" 2>/dev/null || true
      return 1
    fi
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

  export HOME="${HOME:-$(audio_scratch_dir)}"

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

  export HOME="${HOME:-$(audio_scratch_dir)}"

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

# audio_dt_requires_topology <sound-card-DT-node>
# Return 0 when an enabled card link references the q6apm topology provider,
# otherwise 1. Shared by pre-registration and registered-card validation.
audio_dt_requires_topology() {
  adrt_node="$1"
  adrt_providers="$(dt_list_compatible_nodes 'qcom,q6apm' 2>/dev/null)"
  for adrt_provider in $adrt_providers; do
    if ! dt_property_text "$adrt_provider" compatible |
        tr ' ' '\n' | grep -F -x qcom,q6apm >/dev/null; then
      continue
    fi
    adrt_phandle="$(dt_property_hex "$adrt_provider" phandle)"
    [ -n "$adrt_phandle" ] || continue
    for adrt_link in "$adrt_node"/*; do
      [ -d "$adrt_link/platform" ] || continue
      dt_node_enabled "$adrt_link" || continue
      dt_node_enabled "$adrt_link/platform" || continue
      if [ "$(dt_property_hex "$adrt_link/platform" sound-dai)" = "$adrt_phandle" ]; then
        return 0
      fi
    done
  done
  return 1
}

# audio_topology_for_dt_model <model>
# Before ALSA registers, discover the installed driver directory containing the
# exact DT-model topology basename. Print its nonempty image-provided path.
# Reject ambiguous driver directories. The registered-card check later verifies
# the exact ALSA driver name. Use the same roots/precedence as find_image_firmware.
audio_topology_for_dt_model() {
  atfdm_model="$1"
  case "$atfdm_model" in
    ''|*/*|*..*)
      printf '%s\n' "Invalid or missing sound-card DT model for topology discovery: '$atfdm_model'" >&2
      return 1
      ;;
  esac
  atfdm_release="$(uname -r)"
  atfdm_drivers=""
  for atfdm_root in \
      "/lib/firmware/$atfdm_release" \
      "/usr/lib/firmware/$atfdm_release" \
      /lib/firmware /usr/lib/firmware; do
    for atfdm_dir in "$atfdm_root"/qcom/*; do
      [ -d "$atfdm_dir" ] || continue
      for atfdm_suffix in '' .xz .zst; do
        if [ -f "$atfdm_dir/$atfdm_model-tplg.bin$atfdm_suffix" ]; then
          atfdm_drivers="${atfdm_drivers}${atfdm_dir##*/}
"
          break
        fi
      done
    done
  done
  atfdm_drivers="$(printf '%s' "$atfdm_drivers" | sort -u)"
  if [ -z "$atfdm_drivers" ]; then
    printf '%s\n' "Required DT-model topology '$atfdm_model-tplg.bin' is missing from the image firmware qcom/<driver>/ directories, provision it in the build" >&2
    return 1
  fi
  if [ "$(printf '%s\n' "$atfdm_drivers" | wc -l)" -ne 1 ]; then
    printf '%s\n' "Ambiguous image topology directories for DT model '$atfdm_model': $atfdm_drivers" >&2
    return 1
  fi
  atfdm_path="$(find_image_firmware "qcom/$atfdm_drivers/$atfdm_model-tplg.bin")" || return 1
  if [ ! -s "$atfdm_path" ]; then
    printf '%s\n' "Required audio topology is empty: $atfdm_path, provision a valid topology in the build" >&2
    return 1
  fi
  printf '%s\n' "$atfdm_path"
}

# audio_dt_fit_candidates
# List canonical FIT candidate files from already accessible boot directories
# and mounted FAT filesystems. No mounting, raw partition reads or boot-slot
# assumptions. A candidate is not proof that firmware booted that file.
audio_dt_fit_candidates() {
  {
    printf '%s\n' /boot /efi /firmware
    if [ -r /proc/mounts ]; then
      awk '$3 == "vfat" { print $2 }' /proc/mounts |
        while IFS= read -r adfc_mount; do
          printf '%b\n' "$adfc_mount"
        done
    fi
  } | sort -u |
    while IFS= read -r adfc_root; do
      [ -d "$adfc_root" ] || continue
      find "$adfc_root" -maxdepth 4 \( -type f -o -type l \) \
        \( -name qclinux_fit.img -o -name qclinuxfitImage -o -name 'fitImage*' \) \
        -print 2>/dev/null
    done |
    while IFS= read -r adfc_file; do
      readlink -f "$adfc_file" 2>/dev/null
    done | sort -u
}

# audio_dt_fit_select <inventory-file> <EFI-selector>
# Select a unique configuration from config|compatibles|ordered-FDTs rows.
# Prefer literal matches. Otherwise match vendor,board,qualifier[,qualifier]
# against vendor,board-qualifier metadata, retaining every qualifier. Only
# unambiguous full matches succeed. Print config|compatible|FDTs|match-kind.
audio_dt_fit_select() {
  awk -F '|' -v selector="$2" '
    BEGIN {
      parts = split(selector, selected, ",")
      base = selected[1] "," selected[2]
      qualified = parts > 2 && selected[1] != "" && selected[2] != ""
      for (i = 3; i <= parts; i++) {
        if (selected[i] !~ /^[a-zA-Z0-9_.+]+$/ || wanted[selected[i]]++) qualified = 0
      }
    }
    function qualifiers_match(compatible, suffix, n, words, j) {
      if (!qualified || substr(compatible, 1, length(base) + 1) != base "-") return 0
      suffix = substr(compatible, length(base) + 2)
      n = split(suffix, words, "-")
      if (n != parts - 2) return 0
      for (j in seen) delete seen[j]
      for (j = 1; j <= n; j++) {
        if (!(words[j] in wanted) || seen[words[j]]++) return 0
      }
      return 1
    }
    NF == 3 {
      count = split($2, aliases, " ")
      for (a = 1; a <= count; a++) {
        if (aliases[a] == selector && !literal_seen[$1]++) {
          literal_count++
          literal = $1 "|" aliases[a] "|" $3 "|exact"
        } else if (qualifiers_match(aliases[a]) && !qualified_seen[$1]++) {
          qualified_count++
          translated = $1 "|" aliases[a] "|" $3 "|qualified"
        }
      }
    }
    END {
      if (literal_count == 1) print literal
      else if (literal_count == 0 && qualified_count == 1) print translated
      else exit 2
    }
  ' "$1"
}

# audio_dt_fit_resolve <FIT> <selector> <artifact-directory>
# Enumerate configurations and ordered FDT references, resolve one selector
# and extract its base DTB with image-provided tools. Print the base's first
# compatible only. Return 2 when evidence is unavailable, invalid or ambiguous.
# Do not infer identity from filenames or compare generic SoC compatibles.
audio_dt_fit_resolve() {
  adfr_fit="$1"
  adfr_selector="$2"
  adfr_out="$3"
  : >"$adfr_out/fit_inventory.txt"
  command -v fdtget >/dev/null 2>&1 &&
    command -v dumpimage >/dev/null 2>&1 &&
    command -v timeout >/dev/null 2>&1 || return 2
  adfr_start="$(get_monotonic_seconds)"
  adfr_configs="$(timeout 5 fdtget -l "$adfr_fit" /configurations 2>>"$adfr_out/fit_tools.log")" || return 2
  adfr_total=0
  for adfr_config in $adfr_configs; do
    case "$adfr_config" in
      ''|*[!a-zA-Z0-9_.+@-]*)
        return 2
        ;;
    esac
    [ "$(( $(get_monotonic_seconds) - adfr_start ))" -lt 30 ] || return 2
    adfr_total=$((adfr_total + 1))
    [ "$adfr_total" -le 512 ] || return 2
    if adfr_compat="$(timeout 5 fdtget -t s "$adfr_fit" "/configurations/$adfr_config" compatible 2>>"$adfr_out/fit_tools.log")"; then
      :
    else
      adfr_rc=$?
      # fdtget returns 1 for a configuration without a compatible property.
      # A timed-out or unavailable reader makes the inventory incomplete.
      [ "$adfr_rc" -eq 1 ] || return 2
      continue
    fi
    adfr_fdts="$(timeout 5 fdtget -t s "$adfr_fit" "/configurations/$adfr_config" fdt 2>>"$adfr_out/fit_tools.log")" || return 2
    printf '%s|%s|%s\n' "$adfr_config" "$adfr_compat" "$adfr_fdts" >>"$adfr_out/fit_inventory.txt"
  done
  adfr_selection="$(audio_dt_fit_select "$adfr_out/fit_inventory.txt" "$adfr_selector")" || {
    printf '%s\n' "EFI selector '$adfr_selector' has no unique full FIT match, qualifiers were not discarded" >>"$adfr_out/fit_tools.log"
    return 2
  }
  printf '%s\n' "$adfr_selection" >"$adfr_out/selected_fit_config.txt"
  adfr_selected="$(printf '%s\n' "$adfr_selection" | cut -d'|' -f3)"
  adfr_base="${adfr_selected%% *}"
  case "$adfr_base" in
    ''|*[!a-zA-Z0-9_.+@-]*)
      return 2
      ;;
  esac
  adfr_images="$(timeout 5 fdtget -l "$adfr_fit" /images 2>>"$adfr_out/fit_tools.log")" || return 2
  adfr_index=0
  adfr_found=0
  for adfr_image in $adfr_images; do
    if [ "$adfr_image" = "$adfr_base" ]; then
      adfr_found=1
      break
    fi
    adfr_index=$((adfr_index + 1))
  done
  [ "$adfr_found" -eq 1 ] || return 2
  [ "$(timeout 5 fdtget -t s "$adfr_fit" "/images/$adfr_base" type 2>>"$adfr_out/fit_tools.log")" = flat_dt ] || return 2
  [ "$(timeout 5 fdtget -t s "$adfr_fit" "/images/$adfr_base" compression 2>>"$adfr_out/fit_tools.log")" = none ] || return 2
  : >"$adfr_out/selected_base.dtb"
  timeout 5 dumpimage -T flat_dt -p "$adfr_index" \
    -o "$adfr_out/selected_base.dtb" "$adfr_fit" >>"$adfr_out/fit_tools.log" 2>&1 || return 2
  adfr_identity="$(timeout 5 fdtget -t s "$adfr_out/selected_base.dtb" / compatible 2>>"$adfr_out/fit_tools.log")" || return 2
  [ -n "$adfr_identity" ] || return 2
  printf '%s\n' "$adfr_selected" >"$adfr_out/selected_fdt_refs.txt"
  printf '%s\n' "${adfr_identity%% *}"
}

# audio_dt_fit_preflight <artifact-directory> [expected-compatible] [FIT-path]
# Read-only active DT and EFI/FIT reporting before audio preparation. Explicit
# expectations are enforced, automatically found FITs are only candidates.
# Return 1 on an unmet explicit contract or evidence-artifact failure, otherwise
# 0 (including unavailable optional evidence). Does not claim overlay application.
audio_dt_fit_preflight() {
  adfp_out="$1"
  adfp_expected="${2:-}"
  adfp_fit="${3:-}"
  adfp_explicit_fit=0
  [ -z "$adfp_fit" ] || adfp_explicit_fit=1
  mkdir -p "$adfp_out" || return 1
  for adfp_artifact in report.txt active_compatible.txt fit_inventory.txt \
      fit_tools.log fit_candidates.txt selected_base.dtb selected_fdt_refs.txt selected_fit_config.txt \
      sound_dai_nodes.txt sound_cards.txt; do
    : >"$adfp_out/$adfp_artifact" || return 1
  done
  adfp_root="$(dt_runtime_root 2>/dev/null || true)"
  if [ -z "$adfp_root" ]; then
    log_info "[AUDIO-DT] Runtime DT unavailable, identity verification not performed"
    printf '%s\n' 'runtime_dt=unavailable' >"$adfp_out/report.txt"
    [ -z "$adfp_expected$adfp_fit" ] && return 0
    log_fail "[AUDIO-DT] Explicit DT/FIT verification requires the running device tree"
    return 1
  fi
  dt_property_text "$adfp_root" compatible |
    tr ' ' '\n' >"$adfp_out/active_compatible.txt"
  adfp_model="$(dt_property_text "$adfp_root" model)"
  adfp_active="$(sed -n '1p' "$adfp_out/active_compatible.txt")"
  printf '%s\n' "runtime_root=$adfp_root" "model=$adfp_model" \
    "board_compatible=$adfp_active" >"$adfp_out/report.txt"
  log_info "[AUDIO-DT] Active model='$adfp_model' board_compatible='$adfp_active' root=$adfp_root"
  log_file_with_label AUDIO-DT-COMPATIBLE "$adfp_out/active_compatible.txt"
  if [ -n "$adfp_expected" ] &&
     ! grep -Fxq -- "$adfp_expected" "$adfp_out/active_compatible.txt"; then
    log_fail "[AUDIO-DT] Expected '$adfp_expected' is absent from the active DT, select the correct boot DT and reboot before testing audio"
    return 1
  fi
  # Log sound-card nodes even if no PCM/card has registered yet.
  adfp_discovery_rc=0
  dt_list_enabled_property_nodes "$adfp_root" sound-dai >"$adfp_out/sound_dai_nodes.txt" || adfp_discovery_rc=$?
  if [ "$adfp_discovery_rc" -gt 1 ]; then
    log_fail "[AUDIO-DT] Cannot inspect sound-dai nodes, discovery rc=$adfp_discovery_rc. Check DT access and discovery tools"
    printf '%s\n' "sound_dai_discovery=failed rc=$adfp_discovery_rc" >>"$adfp_out/report.txt"
    return 1
  fi
  while IFS= read -r adfp_dai; do
    adfp_link="${adfp_dai%/*}"
    adfp_card="${adfp_link%/*}"
    [ -r "$adfp_card/model" ] || continue
    printf '%s|%s|%s\n' "$adfp_card" \
      "$(dt_property_text "$adfp_card" model)" \
      "$(dt_property_text "$adfp_card" compatible)"
  done <"$adfp_out/sound_dai_nodes.txt" | sort -u >"$adfp_out/sound_cards.txt"
  log_file_with_label AUDIO-DT-SOUND "$adfp_out/sound_cards.txt"
  adfp_selector=""
  if ! command -v efi_read_text_variable >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$TOOLS/lib_system.sh"
  fi
  adfp_selector="$(efi_read_text_variable VendorDtbOverlays /sys/firmware/efi/efivars 2>/dev/null || true)"
  printf '%s\n' "efi_selector=$adfp_selector" >>"$adfp_out/report.txt"
  log_info "[AUDIO-DT] EFI selection='${adfp_selector:-unavailable}', this is not proof of the active boot selection"
  if [ -z "$adfp_fit" ]; then
    audio_dt_fit_candidates >"$adfp_out/fit_candidates.txt"
    if [ "$(wc -l <"$adfp_out/fit_candidates.txt")" -eq 1 ]; then
      IFS= read -r adfp_fit <"$adfp_out/fit_candidates.txt"
    fi
  fi
  if [ -z "$adfp_fit" ]; then
    log_info "[AUDIO-DT] Boot FIT not uniquely accessible, preserving runtime audio discovery. Optional --fit-image supplies the intended boot FIT"
    return 0
  fi
  adfp_fit="$(readlink -f "$adfp_fit" 2>/dev/null || true)"
  printf '%s\n' "fit=$adfp_fit" "fit_explicit=$adfp_explicit_fit" >>"$adfp_out/report.txt"
  if [ -z "$adfp_fit" ] || [ ! -r "$adfp_fit" ] || [ ! -f "$adfp_fit" ]; then
    log_warn "[AUDIO-DT] FIT is not a readable regular file"
    [ "$adfp_explicit_fit" -eq 0 ]
    return $?
  fi
  if adfp_base="$(audio_dt_fit_resolve "$adfp_fit" "$adfp_selector" "$adfp_out")"; then
    printf '%s\n' "selected_base_compatible=$adfp_base" >>"$adfp_out/report.txt"
    log_info "[AUDIO-DT] FIT=$adfp_fit EFI-selected base='$adfp_base', ordered FDT references: $(cat "$adfp_out/selected_fdt_refs.txt")"
    log_file_with_label AUDIO-DT-FIT-SELECTION "$adfp_out/selected_fit_config.txt"
    if ! grep -Fxq -- "$adfp_base" "$adfp_out/active_compatible.txt"; then
      if [ "$adfp_explicit_fit" -eq 1 ]; then
        log_fail "[AUDIO-DT] Supplied FIT and EFI selection expect '$adfp_base', active DT is '$adfp_active'. Correct the boot selection and reboot before audio validation"
        return 1
      fi
      log_warn "[AUDIO-DT] Candidate FIT/EFI base differs from active DT, boot provenance is unverified. Confirm the boot FIT with --fit-image before enforcing this comparison"
    else
      log_info "[AUDIO-DT] Base identity agrees, this does not prove every FIT overlay was applied"
    fi
  else
    log_warn "[AUDIO-DT] FIT selection could not be resolved, need fdtget, dumpimage, timeout, one readable EFI selector and a matching uncompressed base FDT. Artifacts: $adfp_out"
    [ "$adfp_explicit_fit" -eq 0 ] || return 1
  fi
  return 0
}

# audio_base_topology_preflight
# Discover enabled sound cards through runtime DT platform sound-dai links,
# before any ALSA card exists. Print validated topology paths, diagnostics to
# stderr. Return 0 when all q6apm dependencies are provisioned, 2 when none are
# declared, 3 when DT is unavailable, and 1 for an unmet topology requirement.
audio_base_topology_preflight() {
  abtp_root="$(dt_runtime_root)" || return 3
  abtp_discovery_rc=0
  abtp_platforms="$(dt_list_enabled_property_nodes "$abtp_root" sound-dai)" || abtp_discovery_rc=$?
  if [ "$abtp_discovery_rc" -gt 1 ]; then
    printf '%s\n' "Audio topology discovery failed, rc=$abtp_discovery_rc. Check DT access and discovery tools" >&2
    return 1
  fi
  abtp_cards="$(
    printf '%s\n' "$abtp_platforms" |
      while IFS= read -r abtp_platform; do
        [ "${abtp_platform##*/}" = platform ] || continue
        abtp_link="${abtp_platform%/*}"
        abtp_card="${abtp_link%/*}"
        dt_node_enabled "$abtp_link" || continue
        dt_node_enabled "$abtp_card" || continue
        printf '%s\n' "$abtp_card"
      done | sort -u
  )"
  abtp_paths=""
  while IFS= read -r abtp_card; do
    [ -n "$abtp_card" ] || continue
    audio_dt_requires_topology "$abtp_card" || continue
    abtp_model="$(dt_property_text "$abtp_card" model)"
    abtp_path="$(audio_topology_for_dt_model "$abtp_model")" || return 1
    printf '%s\n' "Audio topology preflight: DT=$abtp_card model=$abtp_model file=$abtp_path, exact ALSA driver path will be checked after card registration" >&2
    abtp_paths="${abtp_paths}${abtp_path}
"
  done <<EOF
$abtp_cards
EOF
  [ -n "$abtp_paths" ] || return 2
  printf '%s' "$abtp_paths"
}

# audio_wait_for_capture_payload <WAV> <owner-pid> <seconds>
# Wait for a valid WAV header and at least one complete PCM frame while the
# owned capture process is alive. No stdout data, return 1 on exit or timeout.
audio_wait_for_capture_payload() (
  awcp_file="$1"
  awcp_pid="$2"
  awcp_limit="$3"
  awcp_start="$(get_monotonic_seconds)"
  while kill -0 "$awcp_pid" 2>/dev/null; do
    awcp_meta="$(audio_wav_header_metadata "$awcp_file" 2>/dev/null || true)"
    if [ -n "$awcp_meta" ]; then
      awcp_offset="${awcp_meta%%|*}"
      awcp_size="$(file_size_bytes "$awcp_file" 2>/dev/null || echo 0)"
      awcp_align="$(printf '%s\n' "$awcp_meta" | cut -d'|' -f7)"
      if [ "$awcp_align" -gt 0 ] &&
         [ "$awcp_size" -ge "$((awcp_offset + awcp_align))" ] &&
         kill -0 "$awcp_pid" 2>/dev/null; then
        return 0
      fi
    fi
    [ "$(( $(get_monotonic_seconds) - awcp_start ))" -lt "$awcp_limit" ] || break
    sleep 1
  done
  log_fail "Capture did not provide PCM payload while alive within ${awcp_limit}s, artifact=$awcp_file"
  return 1
)

# audio_loopback_cleanup
# Terminate/reap only this loopback's recorder owner, whose progress-helper
# traps also terminate its recorder child and restore capture volume.
audio_loopback_cleanup() {
  if [ -n "${RECORDER_PID:-}" ]; then
    # A desktop launcher/volume subshell can sit between the owner and recorder.
    # Stop the verified recorder first, allowing progress/volume traps to finish.
    audio_stop_capture_descendant "$RECORDER_PID" "${capture_wav:-}" || true
    alc_start="$(get_monotonic_seconds)"
    while kill -0 "$RECORDER_PID" 2>/dev/null &&
          [ "$(( $(get_monotonic_seconds) - alc_start ))" -lt 30 ]; do
      sleep 1
    done
    audio_record_stop_child "$RECORDER_PID" || true
    RECORDER_PID=""
  fi
  audio_cleanup_runtime
}

# audio_stop_capture_descendant <owner-pid> <WAV>
# Signal the recorder only if its saved start time still matches and /proc
# proves it descends from the live test-owned launcher. Never signal a recycled
# PID. Return 0 for no live matching child, 1 for invalid evidence or kill failure.
audio_stop_capture_descendant() (
  ascd_owner="$1"
  ascd_file="$2.recorder"
  [ -r "$ascd_file" ] || return 0
  IFS='|' read -r ascd_pid ascd_start <"$ascd_file" || return 1
  case "$ascd_pid:$ascd_start" in
    *[!0-9:]*|:*)
      return 1
      ;;
  esac
  [ -r "/proc/$ascd_pid/stat" ] || return 0
  ascd_current="$(awk '{sub(/^.*\) /, ""); print $20}' "/proc/$ascd_pid/stat")" || return 1
  [ "$ascd_current" = "$ascd_start" ] || return 0
  ascd_parent="$ascd_pid"
  ascd_depth=0
  while [ "$ascd_parent" -gt 1 ] && [ "$ascd_depth" -lt 64 ]; do
    ascd_parent="$(awk '{sub(/^.*\) /, ""); print $2}' "/proc/$ascd_parent/stat" 2>/dev/null)" || return 0
    if [ "$ascd_parent" = "$ascd_owner" ]; then
      audio_record_stop_child "$ascd_pid"
      return $?
    fi
    ascd_depth=$((ascd_depth + 1))
  done
  return 0
)

# audio_loopback_prepare_overlay
# Reuse the existing modem-audio applicability and runtime-overlay discovery
# before automatic native Loopback backend selection. Explicit ALSA devices,
# desktop distributions and non-applicable boards retain their existing paths.
# Prepare image-provided DSP/services, then require both routes in one readiness
# decision. Return 0 when prepared, 1 on failure, 2 when not applicable.
# Never install packages or fall back after overlay failure.
audio_loopback_prepare_overlay() {
  [ -z "${PLAYBACK_DEVICE:-}" ] && [ -z "${CAPTURE_DEVICE:-}" ] || return 2
  case "${audio_loopback_os_id:-unknown}" in
    debian|ubuntu|centos|rhel)
      return 2
      ;;
  esac
  audio_platform_is_shikra || return 2
  audio_detect_runtime_mode 0
  [ "$AUDIO_OVERLAY_ACTIVE" -eq 1 ] || return 2
  SYSTEMD_AVAILABLE=0
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    SYSTEMD_AVAILABLE=1
  fi
  if ! audio_prepare_audio_remoteproc; then
    AUDIO_OVERLAY_FAILURE_REASON="Loopback overlay DSP preparation failed: ${AUDIO_REMOTE_PROC_REASON:-no applicable image-provided audio remoteproc}"
    audio_collect_remoteproc_diagnostics "$LOGDIR/remoteproc-preflight" || true
    return 1
  fi
  if ! audio_overlay_modem_selected; then
    AUDIO_OVERLAY_FAILURE_REASON="Loopback overlay did not identify its modem-audio remoteproc, inspect runtime DT and image firmware"
    return 1
  fi
  audio_validate_overlay_readiness loopback "$PLAYBACK_ROUTE" "$CAPTURE_ROUTE" || return 1
  return 0
}

# audio_loopback_prepare_alsa
# Prepare provisioned audio firmware/topology before functional ALSA loopback
# probes, then require playback and capture registration. Keep non-applicable
# platforms' existing lazy recovery unchanged, only the existing runtime
# Shikra modem-audio gate opts into eager startup. Return 1 on failure, 0 otherwise.
audio_loopback_prepare_alsa() {
  AUDIO_REMOTE_PROC_PATH=""
  AUDIO_REMOTE_PROC_REASON=""
  if ! audio_platform_is_shikra; then
    return 0
  fi
  audio_prepare_audio_remoteproc
  alpa_rc=$?
  case "$alpa_rc" in
    0)
      audio_wait_for_alsa_registration playback || return 1
      audio_wait_for_alsa_registration capture || return 1
      ;;
    2)
      log_info "Loopback remoteproc preparation not applicable: $AUDIO_REMOTE_PROC_REASON"
      ;;
    *)
      audio_collect_remoteproc_diagnostics "$LOGDIR/remoteproc-preflight" || true
      return 1
      ;;
  esac
  return 0
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
#
# All repository callers source functestlib.sh before audio_common.sh,
# including child user-session paths. platform_identity_matches() from
# functestlib.sh is therefore always available and is the single contract.
# If standalone sourcing is required, source functestlib.sh explicitly first.
audio_platform_is_shikra() {
  platform_identity_matches "shikra"
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
  AUDIO_REMOTE_PROC_PATH=""
  AUDIO_REMOTE_PROC_SINCE=""
  AUDIO_REMOTE_PROC_CONTROLLER=""
  AUDIO_REMOTE_PROC_INITIAL_STATE=""
  export AUDIO_REMOTE_PROC_STARTED
  export AUDIO_REMOTE_PROC_PATH AUDIO_REMOTE_PROC_SINCE
  export AUDIO_REMOTE_PROC_CONTROLLER AUDIO_REMOTE_PROC_INITIAL_STATE
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
    AUDIO_REMOTE_PROC_PATH="$arpr_path"
    AUDIO_REMOTE_PROC_INITIAL_STATE="$arpr_state"
    arpr_device=""
    if [ -e "$arpr_path/device" ]; then
      arpr_device="$(readlink -f "$arpr_path/device" 2>/dev/null)"
    else
      arpr_realpath="$(readlink -f "$arpr_path" 2>/dev/null)"
      case "$arpr_realpath" in
        */remoteproc/*)
          arpr_device="${arpr_realpath%/remoteproc/*}"
          ;;
      esac
    fi
    AUDIO_REMOTE_PROC_CONTROLLER="${arpr_device##*/}"
    if [ -r /proc/uptime ]; then
      AUDIO_REMOTE_PROC_SINCE="$(get_monotonic_seconds)"
    fi
    export AUDIO_REMOTE_PROC_PATH AUDIO_REMOTE_PROC_SINCE
    export AUDIO_REMOTE_PROC_CONTROLLER AUDIO_REMOTE_PROC_INITIAL_STATE
    arpr_firmware_path="$(
      find_image_firmware "$arpr_firmware" 2>/dev/null || true
    )"
    if [ -z "$arpr_firmware_path" ]; then
      AUDIO_REMOTE_PROC_REASON="audio remoteproc firmware is not provisioned: name='$arpr_name' firmware='$arpr_firmware'"
      continue
    fi

    arpr_topology_rc=2
    if [ "${AUDIO_OVERLAY_ACTIVE:-${AUDIO_OVERLAY_REQUESTED:-0}}" -eq 0 ]; then
      arpr_topology_path="$(audio_base_topology_preflight)"
      arpr_topology_rc=$?
      if [ "$arpr_topology_rc" -eq 1 ]; then
        AUDIO_REMOTE_PROC_REASON="required base audio topology is missing, empty or ambiguous, see the runtime DT-model diagnostic above"
        export AUDIO_REMOTE_PROC_REASON
        return 1
      fi
    fi
    if [ "$arpr_topology_rc" -eq 0 ]; then
      :
    elif [ "$arpr_is_shikra_modem" -eq 1 ]; then
      if [ "${AUDIO_OVERLAY_ACTIVE:-${AUDIO_OVERLAY_REQUESTED:-0}}" -eq 1 ]; then
        arpr_topology_path="managed-overlay, base ALSA topology check not applicable"
      elif [ "$arpr_topology_rc" -eq 3 ]; then
        AUDIO_REMOTE_PROC_REASON="runtime DT is unavailable, cannot verify the base audio topology prerequisite before modem startup"
        export AUDIO_REMOTE_PROC_REASON
        return 1
      else
        arpr_topology_path="runtime DT declares no q6apm topology consumer"
      fi
    else
      # Preserve older non-q6apm image layouts and their established check.
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

  audio_alsa_control_names "$aace_card" |
    grep -F -x "$aace_name" >/dev/null 2>&1
}

# audio_alsa_control_names <card>
# Print exact mixer names, one per line. Return failure on inventory errors.
audio_alsa_control_names() {
  aacn_output="$(
    audio_exec_with_timeout 5s env LC_ALL=C amixer -c "$1" controls 2>&1
  )" || {
    printf '%s\n' "ALSA mixer inventory failed for card $1: $aacn_output" >&2
    return 1
  }
  printf '%s\n' "$aacn_output" | sed -n "s/.*name='\(.*\)'$/\1/p"
}

# audio_alsa_pcm_inventory <playback|capture>
# Print card|device|PCM-name records from the image-provided ALSA client.
# Names come from the runtime DAI/topology, never from a card-number table.
audio_alsa_pcm_inventory() {
  case "$1" in
    playback)
      aapi_client=aplay
      ;;
    capture)
      aapi_client=arecord
      ;;
    *)
      return 1
      ;;
  esac
  aapi_output="$(
    audio_exec_with_timeout 5s env LC_ALL=C "$aapi_client" -l 2>&1
  )" || {
    printf '%s\n' "ALSA $1 inventory failed: $aapi_output" >&2
    return 1
  }
  printf '%s\n' "$aapi_output" | sed -n \
    's/^card[[:space:]]*\([0-9][0-9]*\):.*device[[:space:]]*\([0-9][0-9]*\):[[:space:]]*\(.*\)/\1|\2|\3/p'
}

# audio_alsa_route_links <card> <playback|capture>
# Print exposed frontend links for one speaker/DMIC backend, one per line.
# Return 2 for direct-codec cards, 1 on inventory error or competing backends.
audio_alsa_route_links() {
  aarc_names="$(audio_alsa_control_names "$1")" || return 1
  case "$2" in
    playback)
      aarc_pattern='^(PRIMARY_MI2S_RX|SECONDARY_TDM_RX_0) Audio Mixer MultiMedia[0-9]+$'
      ;;
    capture)
      aarc_pattern='^MultiMedia[0-9]+ Mixer (VA_CODEC_DMA_TX_0|TERTIARY_MI2S_TX)$'
      ;;
    *)
      return 1
      ;;
  esac
  aarc_matches="$(printf '%s\n' "$aarc_names" | grep -E "$aarc_pattern")"
  if [ -z "$aarc_matches" ]; then
    return 2
  fi
  aarc_backends="$(
    printf '%s\n' "$aarc_matches" |
      sed -e 's/ Audio Mixer MultiMedia[0-9][0-9]*$//' \
          -e 's/^MultiMedia[0-9][0-9]* Mixer //' | sort -u
  )"
  if [ "$(printf '%s\n' "$aarc_backends" | wc -l)" -ne 1 ]; then
    printf '%s\n' "Conflicting $2 mixer backends on card $1, provision a UCM route: $aarc_matches" >&2
    return 1
  fi
  printf '%s\n' "$aarc_matches"
}

# audio_alsa_route_candidates <card> <playback|capture>
# Print PCM|mixer-link records ordered by runtime PCM number. Direct-codec
# records have an empty mixer field. Reject duplicate mappings for a frontend.
audio_alsa_route_candidates() {
  aarp_card="$1"
  aarp_direction="$2"
  aarp_links="$(audio_alsa_route_links "$aarp_card" "$aarp_direction")"
  aarp_link_rc=$?
  aarp_inventory="$(audio_alsa_pcm_inventory "$aarp_direction")" || return 1
  aarp_records=""
  case "$aarp_link_rc" in
    0)
      ;;
    2)
      # One empty link selects the existing named direct-codec mapping below.
      aarp_links=""
      ;;
    *)
      return 1
      ;;
  esac
  while IFS= read -r aarp_link; do
    if [ -n "$aarp_link" ]; then
      aarp_frontend="$(printf '%s\n' "$aarp_link" | sed -n 's/.*\(MultiMedia[0-9][0-9]*\).*/\1/p')"
      aarp_pattern="(^|[^[:alnum:]])($aarp_frontend|MM${aarp_frontend#MultiMedia})([^[:alnum:]]|$)"
    else
      case "$aarp_direction" in
        playback)
          aarp_pattern='(^|[^[:alnum:]])(wsa.*playback|speaker.*playback|playback.*speaker)([^[:alnum:]]|$)'
          ;;
        capture)
          aarp_pattern='(^|[^[:alnum:]])(va[ _-]*dmic.*capture|dmic.*capture)([^[:alnum:]]|$)'
          ;;
      esac
    fi
    aarp_matches="$(
      printf '%s\n' "$aarp_inventory" |
        awk -F '|' -v card="$aarp_card" -v pattern="$aarp_pattern" '
          $1 == card && tolower($3) ~ tolower(pattern) {
            if (!seen[$2]++) print $2
          }
        '
    )"
    if [ -z "$aarp_matches" ]; then
      printf '%s\n' "No registered $aarp_direction PCM for card=$aarp_card link=${aarp_link:-direct-codec}" >&2
      continue
    fi
    if [ "$(printf '%s\n' "$aarp_matches" | wc -l)" -ne 1 ]; then
      printf '%s\n' "Ambiguous $aarp_direction PCM mapping for card=$aarp_card link=${aarp_link:-direct-codec}" "$aarp_inventory" >&2
      return 1
    fi
    aarp_records="${aarp_records}${aarp_matches}|plughw:${aarp_card},${aarp_matches}|${aarp_link}
"
  done <<EOF
$aarp_links
EOF
  if [ -z "$aarp_records" ]; then
    printf '%s\n' "No mapped $aarp_direction PCM on card $aarp_card, check ALSA registration, topology and mixer links" "$aarp_inventory" >&2
    return 1
  fi
  printf '%s' "$aarp_records" | sort -t '|' -k1,1n | cut -d'|' -f2-
}

# audio_alsa_select_route <card> <playback|capture> [PCM]
# Print one PCM|mixer-link record. Preserve an explicit PCM, otherwise choose
# the lowest registered PCM number for the same backend. Callers must probe it.
audio_alsa_select_route() {
  aasr_candidates="$(audio_alsa_route_candidates "$1" "$2")" || return 1
  aasr_requested="${3:-}"
  case "$aasr_requested" in
    hw:*)
      aasr_requested="plughw:${aasr_requested#hw:}"
      ;;
  esac
  aasr_selected="$(
    printf '%s\n' "$aasr_candidates" |
      awk -F '|' -v requested="$aasr_requested" '
        requested == "" || $1 == requested {
          print
          exit
        }
      '
  )"
  if [ -z "$aasr_selected" ]; then
    printf '%s\n' "Requested $2 PCM '$aasr_requested' is not mapped to the selected route on card $1" "$aasr_candidates" >&2
    return 1
  fi
  printf '%s\n' "ALSA route candidates: direction=$2 card=$1" "$aasr_candidates" \
    "ALSA selected route: $aasr_selected requested=${aasr_requested:-auto-lowest-pcm}" >&2
  printf '%s\n' "$aasr_selected"
}

# audio_alsa_route_control <card> <playback|capture> [PCM]
# Print the mixer link for the selected PCM. Return 2 for direct-codec cards,
# 1 for invalid mappings. Omitting PCM retains deterministic automatic selection.
audio_alsa_route_control() {
  audio_alsa_route_links "$1" "$2" >/dev/null
  aart_rc=$?
  case "$aart_rc" in
    0)
      ;;
    *)
      return "$aart_rc"
      ;;
  esac
  aart_selected="$(audio_alsa_select_route "$1" "$2" "${3:-}")" || return 1
  printf '%s\n' "$aart_selected" | cut -d'|' -f2-
}

# audio_alsa_route_pcm <card> <playback|capture>
# Print the deterministic runtime PCM for the selected speaker/microphone route.
audio_alsa_route_pcm() {
  aarp_selected="$(audio_alsa_select_route "$1" "$2")" || return 1
  printf '%s\n' "$aarp_selected" | cut -d'|' -f1
}

# audio_alsa_card_dt_node <card>
# Print the resolved DT node belonging to an ALSA card, including named cards.
audio_alsa_card_dt_node() {
  aacdn_card="$1"
  if [ -L "/proc/asound/$aacdn_card" ]; then
    aacdn_card="$(basename "$(readlink -f "/proc/asound/$aacdn_card")")"
    aacdn_card="${aacdn_card#card}"
  fi
  aacdn_node="$(readlink -f "/sys/class/sound/card$aacdn_card/device/of_node" 2>/dev/null)"
  [ -d "$aacdn_node" ] || return 1
  printf '%s\n' "$aacdn_node"
}

# audio_alsa_validate_topology <card>
# For a card linked to q6apm in runtime DT, verify the exact image-provided
# topology using the kernel naming contract qcom/<driver>/<model>-tplg.bin.
# Direct-codec cards have no such dependency. Never download or copy firmware.
audio_alsa_validate_topology() {
  aavt_card="$1"
  if [ -L "/proc/asound/$aavt_card" ]; then
    aavt_card="$(basename "$(readlink -f "/proc/asound/$aavt_card")")"
    aavt_card="${aavt_card#card}"
  fi
  aavt_node="$(audio_alsa_card_dt_node "$aavt_card")" || return 0
  audio_dt_requires_topology "$aavt_node" || return 0

  aavt_model="$(dt_property_text "$aavt_node" model)"
  aavt_driver="$(
    awk -v card="$aavt_card" '
      $1 == card {
        sub(/^.*\]:[[:space:]]*/, "")
        sub(/[[:space:]]+- .*/, "")
        print
        exit
      }
    ' /proc/asound/cards 2>/dev/null
  )"
  case "$aavt_driver:$aavt_model" in
    :*|*:|*/*|*..*)
      printf '%s\n' "Cannot derive the q6apm topology filename for ALSA card $aavt_card, DT=$aavt_node" >&2
      return 1
      ;;
  esac
  aavt_name="qcom/$aavt_driver/$aavt_model-tplg.bin"
  aavt_path="$(find_image_firmware "$aavt_name")"
  if [ -z "$aavt_path" ] || [ ! -s "$aavt_path" ]; then
    printf '%s\n' "Required audio topology is missing or empty: $aavt_name, DT=$aavt_node. Include it in the build and boot with the matching audio DT." >&2
    return 1
  fi
  printf '%s\n' "ALSA topology: card=$aavt_card DT=$aavt_node firmware=$aavt_path" >&2
}

# audio_log_phase <label> <monotonic-start> <status>
# Emit elapsed preparation time to stderr, never contaminate discovery stdout.
# Always return 0 so callers explicitly preserve their operation result.
audio_log_phase() {
  alp_elapsed=$(( $(get_monotonic_seconds) - $2 ))
  if [ "$alp_elapsed" -lt 0 ]; then
    alp_elapsed=0
  fi
  printf '%s\n' "[AUDIO-PHASE] $1 rc=$3 elapsed_s=$alp_elapsed" >&2
  return 0
}

# audio_alsa_apply_controls <card> <required|optional> <name|value lines>
# Apply the existing codec policy only to exposed controls. Missing required
# controls and any failed write fail preparation, with command output on stderr.
audio_alsa_apply_controls() {
  aaac_card="$1"
  aaac_policy="$2"
  aaac_rows="$3"
  aaac_names="$(audio_alsa_control_names "$aaac_card")" || return 1
  while IFS='|' read -r aaac_name aaac_value; do
    [ -n "$aaac_name" ] || continue
    if ! printf '%s\n' "$aaac_names" | grep -F -x "$aaac_name" >/dev/null; then
      if [ "$aaac_policy" = required ]; then
        printf '%s\n' "Required ALSA control missing: card=$aaac_card name='$aaac_name'. Check the image codec/topology." >&2
        return 1
      fi
      continue
    fi
    printf '%s\n' "ALSA mixer: card=$aaac_card name='$aaac_name' value='$aaac_value'" >&2
    aaac_start="$(get_monotonic_seconds)"
    if aaac_output="$(
      audio_exec_with_timeout 5s amixer -c "$aaac_card" \
        cset "iface=MIXER,name=$aaac_name" "$aaac_value" 2>&1
    )"; then
      audio_log_phase "mixer-write card=$aaac_card control='$aaac_name'" "$aaac_start" 0
    else
      aaac_rc=$?
      audio_log_phase "mixer-write card=$aaac_card control='$aaac_name'" "$aaac_start" "$aaac_rc"
      printf '%s\n' "ALSA mixer write failed: $aaac_output" >&2
      return 1
    fi
  done <<EOF
$aaac_rows
EOF
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

# audio_write_little_endian <value> <byte-count>
# Write an unsigned integer as binary little-endian bytes to stdout.
audio_write_little_endian() {
  awle_value="$1"
  awle_count="$2"
  awle_index=0

  while [ "$awle_index" -lt "$awle_count" ]; do
    awle_byte=$((awle_value % 256))
    awle_escape="\\$(printf '%03o' "$awle_byte")"
    printf '%b' "$awle_escape"
    awle_value=$((awle_value / 256))
    awle_index=$((awle_index + 1))
  done
}

# audio_generate_u8_stereo_wav <output> <seconds> [rate] [frequency]
# Generate a deterministic unsigned 8-bit stereo square-wave WAV.
audio_generate_u8_stereo_wav() {
  agusw_output="$1"
  agusw_seconds="$2"
  agusw_rate="${3:-48000}"
  agusw_frequency="${4:-1000}"

  if [ -z "$agusw_output" ] ||
     ! is_unsigned_number "$agusw_seconds" ||
     ! is_unsigned_number "$agusw_rate" ||
     ! is_unsigned_number "$agusw_frequency" ||
     [ "$agusw_seconds" -le 0 ] ||
     [ "$agusw_rate" -le 0 ] ||
     [ "$agusw_frequency" -le 0 ]; then
    printf '%s\n' 'invalid WAV output, duration, rate, or frequency' >&2
    return 1
  fi

  agusw_half_period=$((agusw_rate / (agusw_frequency * 2)))
  if [ "$agusw_half_period" -le 0 ]; then
    printf '%s\n' \
      "tone frequency $agusw_frequency is too high for rate $agusw_rate" >&2
    return 1
  fi

  agusw_frames=$((agusw_seconds * agusw_rate))
  agusw_data_bytes=$((agusw_frames * 2))
  agusw_riff_bytes=$((36 + agusw_data_bytes))
  agusw_byte_rate=$((agusw_rate * 2))

  rm -f "$agusw_output"
  if ! {
    printf 'RIFF'
    audio_write_little_endian "$agusw_riff_bytes" 4
    printf 'WAVEfmt '
    audio_write_little_endian 16 4
    audio_write_little_endian 1 2
    audio_write_little_endian 2 2
    audio_write_little_endian "$agusw_rate" 4
    audio_write_little_endian "$agusw_byte_rate" 4
    audio_write_little_endian 2 2
    audio_write_little_endian 8 2
    printf 'data'
    audio_write_little_endian "$agusw_data_bytes" 4
    audio_exec_with_timeout 15s env LC_ALL=C awk \
      -v frames="$agusw_frames" \
      -v half_period="$agusw_half_period" '
        BEGIN {
          cycle_frames = half_period * 2
          cycle = ""
          for (frame = 0; frame < cycle_frames; frame++) {
            value = frame < half_period ? 80 : 176
            cycle = cycle sprintf("%c%c", value, value)
          }

          cycles = int(frames / cycle_frames)
          for (cycle_index = 0; cycle_index < cycles; cycle_index++) {
            printf "%s", cycle
          }

          remaining = frames - (cycles * cycle_frames)
          for (frame = 0; frame < remaining; frame++) {
            value = frame < half_period ? 80 : 176
            printf "%c%c", value, value
          }
        }
      '
  } >"$agusw_output"; then
    rm -f "$agusw_output"
    printf '%s\n' "could not generate WAV reference: $agusw_output" >&2
    return 1
  fi

  agusw_expected_bytes=$((44 + agusw_data_bytes))
  agusw_actual_bytes="$(file_size_bytes "$agusw_output" 2>/dev/null || echo 0)"
  if [ "$agusw_actual_bytes" -ne "$agusw_expected_bytes" ] 2>/dev/null; then
    rm -f "$agusw_output"
    printf '%s\n' \
      "WAV reference size mismatch: expected=$agusw_expected_bytes observed=${agusw_actual_bytes:-0}" >&2
    return 1
  fi

  return 0
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
    sed -n 's/^\(plug\)\{0,1\}hw:\([^,][^,]*\),.*/\2/p'
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
  aapp_controls="$(audio_alsa_control_names "$aapp_card")" || return 1

  if printf '%s\n' "$aapp_controls" |
      grep -Eq '^PRIMARY_MI2S_RX Audio Mixer MultiMedia[0-9]+$'; then
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

  if printf '%s\n' "$aapp_controls" |
      grep -Eq '^SECONDARY_TDM_RX_0 Audio Mixer MultiMedia[0-9]+$'; then
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
    aafpc_profile="$(audio_alsa_playback_profile "$aafpc_card")" || continue
    if [ "$aafpc_profile" != "generic" ]; then
      printf '%s\n' "$aafpc_card"
      return 0
    fi
  done

  return 1
}

# List UCM card identifiers without returning their descriptive comments.
audio_alsa_ucm_cards() {
  command -v alsaucm >/dev/null 2>&1 || return 1

  audio_exec_with_timeout 5s alsaucm listcards 2>/dev/null |
    sed -n 's/^[[:space:]]*[0-9][0-9]*:[[:space:]]*//p'
}

# Run an alsaucm batch without depending on the caller's standard input.
# audio_exec_with_timeout backgrounds commands, and dash redirects an
# asynchronous command's unredirected stdin from /dev/null. Pass the batch as
# a positional parameter so alsaucm still receives every command on Ubuntu.
audio_alsa_ucm_batch() {
  aaub_commands="$1"

  [ -n "$aaub_commands" ] || return 1

  # $1 is expanded by the inner shell from the positional argument below.
  # shellcheck disable=SC2016
  audio_exec_with_timeout 5s sh -c '
    printf "%s\n" "$1" | alsaucm -n -b -
  ' sh "$aaub_commands"
}

# Convert a UCM PCM value into a name safe for a separate aplay or arecord
# process. Remove alsa-lib's private namespace only around standard hardware
# PCMs. Reject other private names because they require the UCM manager's
# generated alsa-lib configuration and are not standalone direct PCM routes.
audio_alsa_direct_pcm_from_ucm_value() {
  aadpfuv_pcm="$(
    printf '%s\n' "$1" |
      sed \
        -e 's/^_ucm[0-9][0-9]*[.]plughw:/plughw:/' \
        -e 's/^_ucm[0-9][0-9]*[.]hw:/hw:/'
  )"

  [ -n "$aadpfuv_pcm" ] || return 1

  if printf '%s\n' "$aadpfuv_pcm" |
      grep -Eq '^_ucm[0-9]+[.]'; then
    return 1
  fi

  printf '%s\n' "$aadpfuv_pcm"
}

# Normalize public playback route aliases to the internal semantic names.
audio_normalize_playback_route() {
  case "$1" in
    auto)
      printf '%s\n' auto
      ;;
    speaker|speakers)
      printf '%s\n' speakers
      ;;
    headphone|headphones|headset)
      printf '%s\n' headphones
      ;;
    null)
      printf '%s\n' null
      ;;
    *)
      printf '%s\n' "unsupported playback route: $1" >&2
      return 1
      ;;
  esac
}

# Normalize public capture route aliases to the internal semantic names.
audio_normalize_capture_route() {
  case "$1" in
    auto)
      printf '%s\n' auto
      ;;
    mic|microphone)
      printf '%s\n' mic
      ;;
    headset-mic|headset_mic|'headset mic')
      printf '%s\n' headset-mic
      ;;
    null)
      printf '%s\n' null
      ;;
    *)
      printf '%s\n' "unsupported capture route: $1" >&2
      return 1
      ;;
  esac
}

# Discover one usable managed-backend playback route and print route|target.
audio_select_managed_playback_route() {
  asmpr_backend="$1"
  asmpr_requested="${2:-auto}"

  case "$asmpr_requested" in
    auto)
      asmpr_routes="speakers headphones"
      ;;
    speakers|headphones|null)
      asmpr_routes="$asmpr_requested"
      ;;
    *)
      printf '%s\n' \
        "unsupported managed playback route: $asmpr_requested" >&2
      return 1
      ;;
  esac

  for asmpr_route in $asmpr_routes; do
    asmpr_target=""
    case "$asmpr_backend:$asmpr_route" in
      pipewire:speakers)
        asmpr_target="$(pw_default_speakers 2>/dev/null || true)"
        ;;
      pipewire:headphones)
        asmpr_target="$(pw_default_headphones 2>/dev/null || true)"
        ;;
      pipewire:null)
        asmpr_target="$(pw_default_null 2>/dev/null || true)"
        ;;
      pulseaudio:speakers)
        asmpr_target="$(pa_default_speakers 2>/dev/null || true)"
        ;;
      pulseaudio:headphones)
        asmpr_target="$(pa_default_headphones 2>/dev/null || true)"
        ;;
      pulseaudio:null)
        asmpr_target="$(pa_default_null 2>/dev/null || true)"
        ;;
      *)
        printf '%s\n' \
          "unsupported managed playback backend: $asmpr_backend" >&2
        return 1
        ;;
    esac

    if [ -n "$asmpr_target" ]; then
      printf '%s|%s\n' "$asmpr_route" "$asmpr_target"
      return 0
    fi

    printf '%s\n' \
      "[AUDIO-ROUTE] managed playback route unavailable: backend=$asmpr_backend route=$asmpr_route" >&2
  done

  return 1
}

# Discover one usable managed-backend capture route and print route|target.
audio_select_managed_capture_route() {
  asmcr_backend="$1"
  asmcr_requested="${2:-auto}"

  case "$asmcr_requested" in
    auto)
      asmcr_routes="mic headset-mic"
      ;;
    mic|headset-mic|null)
      asmcr_routes="$asmcr_requested"
      ;;
    *)
      printf '%s\n' \
        "unsupported managed capture route: $asmcr_requested" >&2
      return 1
      ;;
  esac

  for asmcr_route in $asmcr_routes; do
    asmcr_target=""
    case "$asmcr_backend:$asmcr_route" in
      pipewire:mic)
        asmcr_target="$(pw_default_mic 2>/dev/null || true)"
        ;;
      pipewire:headset-mic)
        asmcr_target="$(pw_default_headset_mic 2>/dev/null || true)"
        ;;
      pipewire:null)
        asmcr_target="$(pw_default_null_source 2>/dev/null || true)"
        ;;
      pulseaudio:mic)
        asmcr_target="$(pa_default_mic 2>/dev/null || true)"
        ;;
      pulseaudio:headset-mic)
        asmcr_target="$(pa_default_headset_mic 2>/dev/null || true)"
        ;;
      pulseaudio:null)
        asmcr_target="$(pa_default_null_source 2>/dev/null || true)"
        ;;
      *)
        printf '%s\n' \
          "unsupported managed capture backend: $asmcr_backend" >&2
        return 1
        ;;
    esac

    if [ -n "$asmcr_target" ]; then
      printf '%s|%s\n' "$asmcr_route" "$asmcr_target"
      return 0
    fi

    printf '%s\n' \
      "[AUDIO-ROUTE] managed capture route unavailable: backend=$asmcr_backend route=$asmcr_route" >&2
  done

  return 1
}

# Select the effective ALSA playback target without changing an explicit user
# override. Auto-discovered raw hardware PCMs use ALSA's plug layer so valid
# WAV formats are converted to the capabilities exposed by the hardware PCM.
audio_playback_effective_alsa_device() {
  apead_device="$1"
  apead_selection="${2:-auto}"

  [ -n "$apead_device" ] || return 1

  case "$apead_selection" in
    auto)
      case "$apead_device" in
        hw:*)
          printf '%s\n' "plughw:${apead_device#hw:}"
          ;;
        *)
          printf '%s\n' "$apead_device"
          ;;
      esac
      ;;
    explicit)
      printf '%s\n' "$apead_device"
      ;;
    *)
      printf '%s\n' \
        "unsupported ALSA playback-device selection: $apead_selection" >&2
      return 1
      ;;
  esac
}

# List the HiFi devices exposed by one UCM card without changing card state.
audio_alsa_ucm_hifi_devices() {
  aauhd_card="$1"
  aauhd_commands=""

  [ -n "$aauhd_card" ] || return 1

  case "$aauhd_card" in
    *\"*)
      return 1
      ;;
  esac

  aauhd_commands="$(
    printf 'open "%s"\nlist _devices/HiFi\n' "$aauhd_card"
  )"
  audio_alsa_ucm_batch "$aauhd_commands" 2>/dev/null |
    sed -n 's/^[[:space:]]*[0-9][0-9]*:[[:space:]]*//p'
}

# Print the exact PlaybackPCM declared for one UCM HiFi device.
audio_alsa_ucm_playback_pcm() {
  aaupp_card="$1"
  aaupp_device="$2"
  aaupp_commands=""
  aaupp_output=""
  aaupp_pcm=""

  [ -n "$aaupp_card" ] && [ -n "$aaupp_device" ] || return 1

  case "$aaupp_card$aaupp_device" in
    *\"*)
      return 1
      ;;
  esac

  aaupp_commands="$(
    printf 'open "%s"\ngetval "=PlaybackPCM/%s/HiFi"\n' \
      "$aaupp_card" "$aaupp_device"
  )"
  aaupp_output="$(
    audio_alsa_ucm_batch "$aaupp_commands" 2>/dev/null
  )" || return 1
  aaupp_pcm="$(
    printf '%s\n' "$aaupp_output" |
      sed -n '/[^[:space:]]/ {
        s/^[[:space:]]*//
        s/[[:space:]]*$//
        p
        q
      }'
  )"
  [ -n "$aaupp_pcm" ] || return 1

  audio_alsa_direct_pcm_from_ucm_value "$aaupp_pcm"
}

# Return the UCM device-name expression for a semantic playback selection.
audio_alsa_ucm_route_pattern() {
  case "$1" in
    speakers)
      printf '%s\n' 'speaker|line[ _-]*out|internal[ _-]*speaker'
      ;;
    headphones)
      printf '%s\n' 'headphone|headset|3[.]5|(^|[^[:alnum:]])hsj([^[:alnum:]]|$)'
      ;;
    *)
      return 1
      ;;
  esac
}

# Resolve semantic route selection to PCM, UCM card, and UCM device fields.
audio_alsa_find_ucm_playback_route() {
  aafur_route="$1"
  aafur_pattern="$(audio_alsa_ucm_route_pattern "$aafur_route")" || return 1
  aafur_cards="$(audio_alsa_ucm_cards)" || return 1
  aafur_old_ifs=$IFS
  IFS='
'

  for aafur_card in $aafur_cards; do
    aafur_devices="$(audio_alsa_ucm_hifi_devices "$aafur_card")"
    for aafur_device in $aafur_devices; do
      if ! printf '%s\n' "$aafur_device" |
          grep -Eiq "$aafur_pattern"; then
        continue
      fi

      aafur_pcm="$(
        audio_alsa_ucm_playback_pcm "$aafur_card" "$aafur_device"
      )"
      if [ -n "$aafur_pcm" ]; then
        IFS=$aafur_old_ifs
        printf '%s|%s|%s\n' \
          "$aafur_pcm" "$aafur_card" "$aafur_device"
        return 0
      fi
    done
  done

  IFS=$aafur_old_ifs
  return 1
}

# Reset UCM and enable one or two exact dynamically discovered HiFi devices.
audio_alsa_enable_ucm_hifi_devices() {
  aaeupr_card="$1"
  aaeupr_device="$2"
  aaeupr_second_device="${3:-}"
  aaeupr_commands=""
  aaeupr_output=""
  aaeupr_enabled_devices=""

  [ -n "$aaeupr_card" ] && [ -n "$aaeupr_device" ] || return 1

  case "$aaeupr_card$aaeupr_device$aaeupr_second_device" in
    *\"*)
      return 1
      ;;
  esac

  if [ -n "$aaeupr_second_device" ]; then
    aaeupr_commands="$(
      printf 'open "%s"\nreset\nset _verb HiFi\nset _enadev "%s"\nset _enadev "%s"\nlist1 _enadevs\n' \
        "$aaeupr_card" "$aaeupr_device" "$aaeupr_second_device"
    )"
  else
    aaeupr_commands="$(
      printf 'open "%s"\nreset\nset _verb HiFi\nset _enadev "%s"\nlist1 _enadevs\n' \
        "$aaeupr_card" "$aaeupr_device"
    )"
  fi

  aaeupr_output="$(
    audio_alsa_ucm_batch "$aaeupr_commands" 2>/dev/null
  )" || return 1
  aaeupr_enabled_devices="$(
    printf '%s\n' "$aaeupr_output" |
      sed -n 's/^[[:space:]]*[0-9][0-9]*:[[:space:]]*//p'
  )"

  if ! printf '%s\n' "$aaeupr_enabled_devices" |
      grep -F -x "$aaeupr_device" >/dev/null 2>&1; then
    printf '%s\n' \
      "UCM device '$aaeupr_device' was not reported enabled on card '$aaeupr_card'" >&2
    return 1
  fi

  if [ -n "$aaeupr_second_device" ] &&
     ! printf '%s\n' "$aaeupr_enabled_devices" |
       grep -F -x "$aaeupr_second_device" >/dev/null 2>&1; then
    printf '%s\n' \
      "UCM device '$aaeupr_second_device' was not reported enabled on card '$aaeupr_card'" >&2
    return 1
  fi

  return 0
}

# Enable the selected UCM route when available, then retain legacy mixer
# preparation only for images without a usable speaker UCM route.
# Args: card, optional UCM card/device, optional selected PCM for mixer matching.
audio_playback_alsa_prepare() {
  ap_card="${1:-}"
  ap_ucm_card="${2:-}"
  ap_ucm_device="${3:-}"
  ap_selected_pcm="${4:-}"
  ap_profile=""
  ap_route_record=""

  if [ "${SINK_CHOICE:-speakers}" = "null" ]; then
    return 0
  fi

  if [ -n "$ap_card" ]; then
    audio_alsa_validate_topology "$ap_card" || return 1
  fi

  if command -v alsaucm >/dev/null 2>&1; then
    if [ -z "$ap_ucm_card" ] || [ -z "$ap_ucm_device" ]; then
      ap_route_record="$(
        audio_alsa_find_ucm_playback_route \
          "${SINK_CHOICE:-speakers}" 2>/dev/null || true
      )"
      ap_ucm_card="$(printf '%s\n' "$ap_route_record" | cut -d'|' -f2)"
      ap_ucm_device="$(printf '%s\n' "$ap_route_record" | cut -d'|' -f3)"
    fi

    if [ -n "$ap_ucm_card" ] && [ -n "$ap_ucm_device" ]; then
      if ! audio_alsa_enable_ucm_hifi_devices \
          "$ap_ucm_card" "$ap_ucm_device"; then
        printf '%s\n' \
          "could not enable UCM device '$ap_ucm_device' on card '$ap_ucm_card'" >&2
        return 1
      fi

      return 0
    fi
  fi

  if [ "${SINK_CHOICE:-speakers}" = "headphones" ]; then
    printf '%s\n' \
      'headphones playback requires a matching UCM HiFi device' >&2
    return 1
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

  ap_profile="$(audio_alsa_playback_profile "$ap_card")" || return 1

  case "$ap_profile" in
    primary-mi2s)
      audio_alsa_apply_controls "$ap_card" optional \
        "Left Speaker Mixer Left DAC Switch|on
Right Speaker Mixer Right DAC Switch|on
Speaker Left Switch|on
Speaker Right Switch|on
Speaker Switch|on
Speaker Volume|10
Speaker Left Mixer Volume|3
Speaker Right Mixer Volume|3
Playback Path DC Blocking|1" || return 1
      ;;
  esac

  ap_route_control="$(audio_alsa_route_control "$ap_card" playback "$ap_selected_pcm")"
  ap_route_rc=$?
  case "$ap_route_rc" in
    0)
      audio_alsa_apply_controls "$ap_card" required \
        "$ap_route_control|1" || return 1
      ap_frontend="${ap_route_control##*MultiMedia}"
      ap_control_names="$(audio_alsa_control_names "$ap_card")" || return 1
      ap_volume_controls="$(
        printf '%s\n' "$ap_control_names" |
          grep -E "^stream[0-9]+[.]vol_ctrl[0-9]+ (MultiMedia${ap_frontend}|MM${ap_frontend}) Playback (Volu|Volume)$"
      )"
      while IFS= read -r ap_volume_control; do
        [ -n "$ap_volume_control" ] || continue
        audio_alsa_apply_controls "$ap_card" required \
          "$ap_volume_control|65535" || return 1
      done <<EOF
$ap_volume_controls
EOF
      ;;
    2)
      ;;
    *)
      return 1
      ;;
  esac

  if [ "$ap_profile" != "primary-mi2s" ]; then
    ap_control_policy=optional
    audio_alsa_apply_controls "$ap_card" "$ap_control_policy" \
      "Rx Slot Mask|3" || return 1

    if audio_alsa_control_exists \
        "$ap_card" "SA1 FU21 Stereo Gain Offset dB"; then
      audio_alsa_apply_controls "$ap_card" "$ap_control_policy" \
        "SA1 FU21 Stereo Gain Offset dB|72" || return 1
    else
      audio_alsa_apply_controls "$ap_card" "$ap_control_policy" \
        "Speaker Volume|72" || return 1
    fi

    if audio_alsa_control_exists "$ap_card" "OT23 Usage Mode"; then
      audio_alsa_apply_controls "$ap_card" "$ap_control_policy" \
        "OT23 Usage Mode|3" || return 1
    else
      audio_alsa_apply_controls "$ap_card" "$ap_control_policy" \
        "Usage Mode|3" || return 1
    fi
  fi

  return 0
}

# Prefer the PCM associated with a detected hardware route, then retain the
# existing default, sysdefault, and first-device fallback order.
audio_playback_pick_legacy_alsa_sink() {
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
        primary-mi2s|secondary-tdm|codec-direct)
          audio_alsa_route_pcm "$ap_card" playback
          return $?
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

# Resolve the selected semantic ALSA route without encoding card or PCM IDs.
audio_playback_resolve_alsa_route() {
  apar_route="${1:-${SINK_CHOICE:-speakers}}"
  apar_record=""
  apar_device=""

  case "$apar_route" in
    null)
      printf '%s\n' 'null||'
      return 0
      ;;
    speakers|headphones)
      ;;
    *)
      printf '%s\n' "unsupported ALSA playback route: $apar_route" >&2
      return 1
      ;;
  esac

  apar_record="$(
    audio_alsa_find_ucm_playback_route "$apar_route" 2>/dev/null || true
  )"
  if [ -n "$apar_record" ]; then
    printf '%s\n' "$apar_record"
    return 0
  fi

  if [ "$apar_route" = "headphones" ]; then
    printf '%s\n' \
      'no UCM HiFi headphones device with a PlaybackPCM value was discovered' >&2
    return 1
  fi

  apar_device="$(audio_playback_pick_legacy_alsa_sink)"
  if [ -n "$apar_device" ]; then
    printf '%s||\n' "$apar_device"
    return 0
  fi

  return 1
}

# Print only the PCM field for existing callers that need a playback device.
audio_playback_pick_alsa_sink() {
  appas_record="$(
    audio_playback_resolve_alsa_route "${SINK_CHOICE:-speakers}"
  )" || return 1

  printf '%s\n' "$appas_record" | cut -d'|' -f1
}

# audio_probe_log_begin <log-file> <label>
# Announce preparation on stderr and print the first new artifact line number
# on stdout. Keep helper return data separate from diagnostics. No execution
# pipelines or process redirection changes are introduced for the media client.
audio_probe_log_begin() {
  aplb_file="$1"
  aplb_label="$2"
  aplb_first=1
  if [ "$aplb_file" != /dev/stderr ]; then
    if ! : >>"$aplb_file"; then
      printf '%s\n' "[$aplb_label] Cannot write probe diagnostics: $aplb_file" >&2
      return 1
    fi
    aplb_lines="$(wc -l <"$aplb_file")"
    aplb_first=$((aplb_lines + 1))
  fi
  printf '%s\n' "[$aplb_label] Preparing route: discover PCM, validate topology, apply mixers, then run a bounded stream probe. Details: $aplb_file" >&2
  printf '%s\n' "$aplb_first"
}

# audio_probe_log_finish <log-file> <label> <first-line> <status> <start-seconds>
# Replay only this attempt's diagnostics to stderr and retain its status and
# preparation-plus-probe elapsed time in the artifact. Always return success,
# callers preserve and return the original probe status explicitly.
audio_probe_log_finish() {
  aplf_file="$1"
  aplf_label="$2"
  aplf_first="$3"
  aplf_rc="$4"
  aplf_start="$5"
  aplf_now="$(get_monotonic_seconds)"
  aplf_elapsed=$((aplf_now - aplf_start))
  if [ "$aplf_elapsed" -lt 0 ]; then
    aplf_elapsed=0
  fi
  if [ "$aplf_file" != /dev/stderr ]; then
    sed -n "${aplf_first},\$p" "$aplf_file" >&2
  fi
  aplf_message="[$aplf_label] Preparation and probe finished: rc=$aplf_rc elapsed_s=$aplf_elapsed. This is not the full media test duration."
  printf '%s\n' "$aplf_message" >&2
  if [ "$aplf_file" != /dev/stderr ]; then
    printf '%s\n' "$aplf_message" >>"$aplf_file"
  fi
  return 0
}

# Prepare the selected card before verifying that its playback PCM can open.
# An explicit device is opened exactly as supplied after semantic-route checks.
# Return 0 for success, 1 for no route, 3 for a selected candidate failure.
audio_playback_alsa_probe() {
  ap_discovery_start="$(get_monotonic_seconds)"
  ap_probe_requested_device="${1:-}"
  ap_probe_selection="auto"
  case "$ap_probe_requested_device" in
    *[[:space:]]*)
      printf '%s\n' \
        "[ALSA-PROBE] explicit playback device contains whitespace: $ap_probe_requested_device" >&2
      return 1
      ;;
  esac
  if ap_probe_route="$(
    audio_playback_resolve_alsa_route "${SINK_CHOICE:-speakers}"
  )"; then
    :
  else
    audio_log_phase playback-discovery "$ap_discovery_start" 1
    return 1
  fi
  ap_probe_route_dev="$(printf '%s\n' "$ap_probe_route" | cut -d'|' -f1)"
  if [ -n "$ap_probe_requested_device" ]; then
    ap_probe_route_dev="$ap_probe_requested_device"
    ap_probe_selection="explicit"
  fi
  ap_probe_dev="$(
    audio_playback_effective_alsa_device \
      "$ap_probe_route_dev" "$ap_probe_selection"
  )"
  ap_probe_ucm_card="$(printf '%s\n' "$ap_probe_route" | cut -d'|' -f2)"
  ap_probe_ucm_device="$(printf '%s\n' "$ap_probe_route" | cut -d'|' -f3)"
  if [ -z "$ap_probe_dev" ]; then
    printf '%s\n' \
      "[ALSA-PROBE] no ${SINK_CHOICE:-speakers} playback route was discovered from UCM or ALSA inventory" >&2
    return 1
  fi

  ap_probe_card="$(audio_alsa_device_card "$ap_probe_dev")"
  ap_probe_profile="generic"
  if [ -n "$ap_probe_card" ]; then
    ap_probe_profile="$(audio_alsa_playback_profile "$ap_probe_card")"
  fi

  if [ -n "$ap_probe_requested_device" ] &&
     [ -n "$ap_probe_ucm_card" ] &&
     [ -n "$ap_probe_card" ] &&
     [ "$ap_probe_ucm_card" != "$ap_probe_card" ]; then
    printf '%s\n' \
      "[ALSA-PROBE] explicit playback device card $ap_probe_card does not match the discovered ${SINK_CHOICE:-speakers} UCM card $ap_probe_ucm_card" >&2
    return 1
  fi

  printf '%s\n' \
    "[ALSA-PROBE] discovered_pcm=$ap_probe_route_dev effective_target=$ap_probe_dev card=${ap_probe_card:-unknown} profile=$ap_probe_profile ucm_card=${ap_probe_ucm_card:-none} ucm_device=${ap_probe_ucm_device:-none}" >&2
  audio_log_phase playback-discovery "$ap_discovery_start" 0
  ap_prepare_start="$(get_monotonic_seconds)"
  if ! audio_playback_alsa_prepare \
      "$ap_probe_card" "$ap_probe_ucm_card" "$ap_probe_ucm_device" "$ap_probe_dev"; then
    audio_log_phase playback-topology-mixers "$ap_prepare_start" 1
    printf '%s\n' \
      "[ALSA-PROBE] route preparation failed: choice=${SINK_CHOICE:-speakers} device=$ap_probe_dev" >&2
    return 3
  fi
  audio_log_phase playback-topology-mixers "$ap_prepare_start" 0

  printf '%s\n' \
    "[ALSA-PROBE] exec: aplay -D $ap_probe_dev -t raw -f S16_LE -r 48000 -c 2 -d 1 /dev/zero" >&2
  ap_probe_start="$(get_monotonic_seconds)"
  audio_exec_with_timeout 5s \
    aplay -D "$ap_probe_dev" -t raw -f S16_LE -r 48000 -c 2 -d 1 \
    /dev/zero >/dev/null
  ap_probe_rc=$?
  ap_probe_end="$(get_monotonic_seconds)"
  printf '%s\n' "[ALSA-PROBE] stream probe finished: device=$ap_probe_dev rc=$ap_probe_rc elapsed_s=$((ap_probe_end - ap_probe_start))" >&2

  if [ "$ap_probe_rc" -eq 0 ]; then
    printf '%s\n' \
      "[ALSA-PROBE] playback candidate opened successfully: $ap_probe_dev" >&2
    AUDIO_ALSA_PLAYBACK_DEVICE="$ap_probe_dev"
    export AUDIO_ALSA_PLAYBACK_DEVICE
    return 0
  fi

  printf '%s\n' \
    "[ALSA-PROBE] playback candidate failed: device=$ap_probe_dev exit_status=$ap_probe_rc" >&2
  return 3
}

# Print the successfully probed ALSA playback device for propagation from a
# desktop Audio-user subprocess back into the root orchestrator.
audio_playback_alsa_probe_device() {
  audio_playback_alsa_probe "${1:-}" || return $?

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
  appawr_requested_device="${1:-}"
  appawr_log="${AUDIO_ALSA_PLAYBACK_PROBE_LOG:-/dev/stderr}"
  appawr_start="$(get_monotonic_seconds)"
  appawr_first="$(audio_probe_log_begin "$appawr_log" ALSA-PLAYBACK-PROBE)" || return 1
  if [ "$appawr_log" != "/dev/stderr" ]; then
    printf '\n%s\n' \
      "[ALSA-PROBE] attempt started at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      >>"$appawr_log"
  fi

  appawr_output="$(
    audio_run_helper_as_test_user audio_playback_alsa_probe_device \
      "$appawr_requested_device" \
      2>>"$appawr_log"
  )"
  appawr_rc=$?
  audio_probe_log_finish "$appawr_log" ALSA-PLAYBACK-PROBE \
    "$appawr_first" "$appawr_rc" "$appawr_start"

  if [ "$appawr_rc" -eq 0 ] && [ -n "$appawr_output" ]; then
    AUDIO_ALSA_PLAYBACK_DEVICE="$(printf '%s\n' "$appawr_output" | tail -n 1)"
    export AUDIO_ALSA_PLAYBACK_DEVICE
    return 0
  fi

  # Keep a failed selected candidate distinct across the user subprocess.
  # Recovery is only for absent inventory, never a failed open or preparation.
  if [ "$appawr_rc" -ne 1 ]; then
    return 3
  fi

  if [ -n "$appawr_requested_device" ]; then
    appawr_candidate="$appawr_requested_device"
  else
    appawr_candidate="$(
      audio_run_helper_as_test_user \
        audio_playback_pick_alsa_sink 2>/dev/null || true
    )"
  fi
  if [ -n "$appawr_candidate" ]; then
    printf '%s\n' \
      "[ALSA-PROBE] candidate remains present after failed open: $appawr_candidate" \
      >>"$appawr_log"
    return 1
  fi

  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ] ||
     [ "${AUDIO_DSP_RECOVERY_ATTEMPTED:-0}" -eq 1 ]; then
    return 1
  fi

  AUDIO_DSP_RECOVERY_ATTEMPTED=1
  export AUDIO_DSP_RECOVERY_ATTEMPTED

  if ! audio_recover_offline_dsp; then
    printf '%s\n' \
      "[ALSA-PROBE] DSP recovery was not performed: ${AUDIO_DSP_RECOVERY_REASON:-not applicable}" \
      >>"$appawr_log"
    return 1
  fi

  printf '%s\n' \
    '[ALSA-PROBE] offline audio DSP was started, retrying playback discovery' \
    >>"$appawr_log"

  appawr_wait=0
  while [ "$appawr_wait" -lt 10 ]; do
    if audio_alsa_playback_inventory_available; then
      break
    fi

    sleep 1
    appawr_wait=$((appawr_wait + 1))
  done

  appawr_start="$(get_monotonic_seconds)"
  appawr_first="$(audio_probe_log_begin "$appawr_log" ALSA-PLAYBACK-RETRY)" || return 1
  appawr_output="$(
    audio_run_helper_as_test_user audio_playback_alsa_probe_device \
      "$appawr_requested_device" \
      2>>"$appawr_log"
  )"
  appawr_rc=$?
  audio_probe_log_finish "$appawr_log" ALSA-PLAYBACK-RETRY \
    "$appawr_first" "$appawr_rc" "$appawr_start"

  if [ "$appawr_rc" -ne 0 ] || [ -z "$appawr_output" ]; then
    if [ "$appawr_rc" -ne 1 ]; then
      return 3
    fi
    return 1
  fi

  AUDIO_ALSA_PLAYBACK_DEVICE="$(printf '%s\n' "$appawr_output" | tail -n 1)"
  export AUDIO_ALSA_PLAYBACK_DEVICE
  return 0
}

# Probe the requested ALSA playback route, or discover speakers then headphones.
audio_playback_probe_selected_alsa_with_recovery() {
  appsawr_requested_device="${1:-}"
  appsawr_requested_route="${SINK_CHOICE:-auto}"
  appsawr_reasons=""

  case "$appsawr_requested_device" in
    *[[:space:]]*)
      AUDIO_ALSA_PLAYBACK_REASON="explicit playback device contains whitespace: $appsawr_requested_device"
      export AUDIO_ALSA_PLAYBACK_REASON
      return 1
      ;;
  esac

  case "$appsawr_requested_route" in
    auto)
      appsawr_routes="speakers headphones"
      ;;
    speakers|headphones)
      appsawr_routes="$appsawr_requested_route"
      ;;
    *)
      AUDIO_ALSA_PLAYBACK_REASON="unsupported ALSA playback route: $appsawr_requested_route"
      export AUDIO_ALSA_PLAYBACK_REASON
      return 1
      ;;
  esac

  for appsawr_route in $appsawr_routes; do
    SINK_CHOICE="$appsawr_route"
    export SINK_CHOICE
    printf '%s\n' \
      "[AUDIO-ROUTE] probing ALSA playback route=$appsawr_route device=${appsawr_requested_device:-auto}" >&2

    if audio_playback_probe_alsa_with_recovery \
        "$appsawr_requested_device"; then
      AUDIO_PLAYBACK_PROBE_FAILED=0
      AUDIO_PLAYBACK_ROUTE_SELECTED="$appsawr_route"
      AUDIO_ALSA_PLAYBACK_REASON=""
      export AUDIO_PLAYBACK_ROUTE_SELECTED AUDIO_ALSA_PLAYBACK_REASON
      return 0
    else
      appsawr_rc=$?
      if [ "$appsawr_rc" -ne 1 ]; then
        AUDIO_PLAYBACK_PROBE_FAILED=1
      fi
    fi

    if [ -n "$appsawr_reasons" ]; then
      appsawr_reasons="$appsawr_reasons, $appsawr_route unavailable"
    else
      appsawr_reasons="$appsawr_route unavailable"
    fi
  done

  SINK_CHOICE="$appsawr_requested_route"
  AUDIO_ALSA_PLAYBACK_REASON="$appsawr_reasons"
  export SINK_CHOICE AUDIO_ALSA_PLAYBACK_REASON
  return 1
}

# Print the exact CapturePCM declared for one UCM HiFi device.
audio_alsa_ucm_capture_pcm() {
  aaucp_card="$1"
  aaucp_device="$2"
  aaucp_commands=""
  aaucp_output=""
  aaucp_pcm=""

  [ -n "$aaucp_card" ] && [ -n "$aaucp_device" ] || return 1

  case "$aaucp_card$aaucp_device" in
    *\"*)
      return 1
      ;;
  esac

  aaucp_commands="$(
    printf 'open "%s"\ngetval "=CapturePCM/%s/HiFi"\n' \
      "$aaucp_card" "$aaucp_device"
  )"
  aaucp_output="$(
    audio_alsa_ucm_batch "$aaucp_commands" 2>/dev/null
  )" || return 1
  aaucp_pcm="$(
    printf '%s\n' "$aaucp_output" |
      sed -n '/[^[:space:]]/ {
        s/^[[:space:]]*//
        s/[[:space:]]*$//
        p
        q
      }'
  )"
  [ -n "$aaucp_pcm" ] || return 1

  audio_alsa_direct_pcm_from_ucm_value "$aaucp_pcm"
}

# Return the UCM device-name expression for a semantic capture selection.
audio_alsa_ucm_capture_route_pattern() {
  case "$1" in
    mic)
      printf '%s\n' 'mic|microphone|dmic|audio[ _-]*input|capture'
      ;;
    headset-mic)
      printf '%s\n' 'headphone|headset|3[.]5|hsj|hsmic'
      ;;
    *)
      return 1
      ;;
  esac
}

# Resolve semantic capture selection to PCM, UCM card, and UCM device fields.
audio_alsa_find_ucm_capture_route() {
  aafuc_route="$1"
  aafuc_pattern="$(
    audio_alsa_ucm_capture_route_pattern "$aafuc_route"
  )" || return 1
  aafuc_cards="$(audio_alsa_ucm_cards)" || return 1
  aafuc_old_ifs=$IFS
  IFS='
'

  for aafuc_card in $aafuc_cards; do
    aafuc_devices="$(audio_alsa_ucm_hifi_devices "$aafuc_card")"
    for aafuc_device in $aafuc_devices; do
      if ! printf '%s\n' "$aafuc_device" |
          grep -Eiq "$aafuc_pattern"; then
        continue
      fi

      if [ "$aafuc_route" = "mic" ] &&
         printf '%s\n' "$aafuc_device" |
           grep -Eiq 'headphone|headset|3[.]5|hsj|hsmic'; then
        continue
      fi

      aafuc_pcm="$(
        audio_alsa_ucm_capture_pcm "$aafuc_card" "$aafuc_device"
      )"
      if [ -n "$aafuc_pcm" ]; then
        IFS=$aafuc_old_ifs
        printf '%s|%s|%s\n' \
          "$aafuc_pcm" "$aafuc_card" "$aafuc_device"
        return 0
      fi
    done
  done

  IFS=$aafuc_old_ifs
  return 1
}

# Enable the selected UCM route when available, then retain legacy mixer
# preparation only for images without a usable built-in microphone UCM route.
# Args: card, optional UCM card/device, optional selected PCM for mixer matching.
audio_record_alsa_prepare_capture() {
  ar_card="${1:-}"
  ar_ucm_card="${2:-}"
  ar_ucm_device="${3:-}"
  ar_selected_pcm="${4:-}"
  ar_route_record=""

  if [ -n "$ar_card" ]; then
    audio_alsa_validate_topology "$ar_card" || return 1
  fi

  if command -v alsaucm >/dev/null 2>&1; then
    if [ -z "$ar_ucm_card" ] || [ -z "$ar_ucm_device" ]; then
      ar_route_record="$(
        audio_alsa_find_ucm_capture_route \
          "${SRC_CHOICE:-mic}" 2>/dev/null || true
      )"
      ar_ucm_card="$(printf '%s\n' "$ar_route_record" | cut -d'|' -f2)"
      ar_ucm_device="$(printf '%s\n' "$ar_route_record" | cut -d'|' -f3)"
    fi

    if [ -n "$ar_ucm_card" ] && [ -n "$ar_ucm_device" ]; then
      if ! audio_alsa_enable_ucm_hifi_devices \
          "$ar_ucm_card" "$ar_ucm_device"; then
        printf '%s\n' \
          "could not enable UCM device '$ar_ucm_device' on card '$ar_ucm_card'" >&2
        return 1
      fi

      return 0
    fi
  fi

  if [ "${SRC_CHOICE:-mic}" = "headset-mic" ]; then
    printf '%s\n' \
      'headset capture requires a matching UCM HiFi device' >&2
    return 1
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

  if audio_alsa_control_exists "$ar_card" "VA DEC0 MUX"; then
    audio_alsa_apply_controls "$ar_card" required \
      "VA DEC0 MUX|VA_DMIC
VA DMIC MUX0|DMIC0
VA_AIF1_CAP Mixer DEC0|1
VA_DEC0 Volume|100" || return 1
  fi
  ar_route_control="$(audio_alsa_route_control "$ar_card" capture "$ar_selected_pcm")"
  ar_route_rc=$?
  case "$ar_route_rc" in
    0)
      audio_alsa_apply_controls "$ar_card" required \
        "$ar_route_control|1" || return 1
      ;;
    2)
      ;;
    *)
      return 1
      ;;
  esac

  return 0
}

# Resolve known microphone routes by runtime link names. Retain the original
# first-device fallback only for cards with other routing schemes.
audio_record_pick_legacy_alsa_capture() {
  ar_dev=""
  ar_card=""

  if command -v arecord >/dev/null 2>&1; then
    for ar_card in $(audio_alsa_card_indexes); do
      if audio_alsa_control_exists "$ar_card" "VA DEC0 MUX"; then
        audio_alsa_route_pcm "$ar_card" capture
        return $?
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

# Resolve the selected semantic ALSA capture route without fixed card/PCM IDs.
audio_record_resolve_alsa_route() {
  arar_route="${1:-${SRC_CHOICE:-mic}}"
  arar_record=""
  arar_device=""

  case "$arar_route" in
    mic|headset-mic)
      ;;
    *)
      printf '%s\n' "unsupported ALSA capture route: $arar_route" >&2
      return 1
      ;;
  esac

  arar_record="$(
    audio_alsa_find_ucm_capture_route "$arar_route" 2>/dev/null || true
  )"
  if [ -n "$arar_record" ]; then
    printf '%s\n' "$arar_record"
    return 0
  fi

  if [ "$arar_route" = "headset-mic" ]; then
    printf '%s\n' \
      'no UCM HiFi headset capture device with a CapturePCM value was discovered' >&2
    return 1
  fi

  arar_device="$(audio_record_pick_legacy_alsa_capture)"
  if [ -n "$arar_device" ]; then
    printf '%s||\n' "$arar_device"
    return 0
  fi

  return 1
}

# Print only the PCM field for existing callers that need a capture device.
audio_record_pick_alsa_capture() {
  arpac_record="$(
    audio_record_resolve_alsa_route "${SRC_CHOICE:-mic}"
  )" || return 1

  printf '%s\n' "$arpac_record" | cut -d'|' -f1
}

audio_record_alsa_capture_probe() {
  ar_probe_dev="$(audio_record_pick_alsa_capture)"
  if [ -z "$ar_probe_dev" ]; then
    return 1
  fi

  ar_probe_card="$(audio_alsa_device_card "$ar_probe_dev")"
  audio_record_alsa_prepare_capture "$ar_probe_card" "" "" "$ar_probe_dev" || return 1

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

# audio_probe_alsa_capture_profile [device]
# Probe a supported capture format on one explicit device or discovered devices.
# Return 0 for success, 1 for absent capability, 3 for preparation/open failure.
# shellcheck disable=SC2120
audio_probe_alsa_capture_profile() {
  capture_discovery_start="$(get_monotonic_seconds)"
  requested_capture_device="${1:-}"
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
    return 3
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
  probe_route_record="$(
    audio_record_resolve_alsa_route "${SRC_CHOICE:-mic}"
  )"
  if [ -z "$probe_route_record" ]; then
    AUDIO_ALSA_CAPTURE_REASON="no unambiguous ${SRC_CHOICE:-mic} PCM route was discovered, check image topology/UCM and ALSA mixer/PCM inventory"
    probe_cleanup
    return 1
  fi
  probe_ucm_card="$(
    printf '%s\n' "$probe_route_record" | cut -d'|' -f2
  )"
  probe_ucm_device="$(
    printf '%s\n' "$probe_route_record" | cut -d'|' -f3
  )"
  if [ -n "$requested_capture_device" ]; then
    case "$requested_capture_device" in
      *[[:space:]]*)
        AUDIO_ALSA_CAPTURE_REASON="explicit capture device contains whitespace: $requested_capture_device"
        probe_cleanup
        return 1
        ;;
    esac

    if [ -z "$probe_route_record" ]; then
      AUDIO_ALSA_CAPTURE_REASON="the ${SRC_CHOICE:-mic} capture route was not discovered for explicit device $requested_capture_device"
      probe_cleanup
      return 1
    fi

    requested_capture_card="$(
      audio_alsa_device_card "$requested_capture_device"
    )"
    if [ -n "$probe_ucm_card" ] &&
       [ -n "$requested_capture_card" ] &&
       [ "$probe_ucm_card" != "$requested_capture_card" ]; then
      AUDIO_ALSA_CAPTURE_REASON="explicit capture device card $requested_capture_card does not match the discovered ${SRC_CHOICE:-mic} UCM card $probe_ucm_card"
      probe_cleanup
      return 1
    fi

    probe_devices="$requested_capture_device"
  else
    cand="$(printf '%s\n' "$probe_route_record" | cut -d'|' -f1)"

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

    extra_devices=""
    probe_route_card="$(audio_alsa_device_card "$cand")"
    if [ -z "$probe_ucm_card" ] && [ "${SRC_CHOICE:-mic}" = "mic" ] &&
       ! audio_alsa_control_exists "$probe_route_card" "VA DEC0 MUX"; then
      extra_devices="$(
        sed -n \
          's/^\([0-9][0-9]*\)-\([0-9][0-9]*\):.*capture.*/hw:\1,\2/p' \
          /proc/asound/pcm 2>/dev/null
      )"
    fi
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
  fi

  if [ -z "$probe_devices" ]; then
    # shellcheck disable=SC2034
    if [ "${SRC_CHOICE:-mic}" = "headset-mic" ]; then
      AUDIO_ALSA_CAPTURE_REASON="no UCM HiFi headset capture device with a CapturePCM value was discovered"
    else
      AUDIO_ALSA_CAPTURE_REASON="no ALSA capture device candidates found"
    fi
    probe_cleanup
    return 1
  fi

  audio_log_phase capture-discovery "$capture_discovery_start" 0
  for dev in $probe_devices; do
    # Mixer controls and PCM devices must come from the same ALSA card.
    probe_card="$(audio_alsa_device_card "$dev")"
    capture_prepare_start="$(get_monotonic_seconds)"
    if ! audio_record_alsa_prepare_capture \
        "$probe_card" "$probe_ucm_card" "$probe_ucm_device" "$dev"; then
      audio_log_phase "capture-topology-mixers device=$dev" "$capture_prepare_start" 1
      AUDIO_ALSA_CAPTURE_REASON="could not prepare the ${SRC_CHOICE:-mic} capture route for $dev"
      probe_cleanup
      return 3
    fi
    audio_log_phase "capture-topology-mixers device=$dev" "$capture_prepare_start" 0

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

      printf '%s\n' "[ALSA-CAPTURE-PROBE] device=$dev format=$fmt rate=$rate channels=$ch duration_s=1 timeout_s=5" >&2
      probe_stream_start="$(get_monotonic_seconds)"
      if audio_exec_with_timeout 5s \
        arecord -q -D "$dev" -f "$fmt" -r "$rate" -c "$ch" -d 1 "$probe_tmp" >/dev/null
      then
        probe_stream_rc=0
      else
        probe_stream_rc=$?
      fi
      probe_stream_end="$(get_monotonic_seconds)"
      bytes="$(file_size_bytes "$probe_tmp" 2>/dev/null || echo 0)"
      printf '%s\n' "[ALSA-CAPTURE-PROBE] Stream probe finished: rc=$probe_stream_rc elapsed_s=$((probe_stream_end - probe_stream_start)) bytes=${bytes:-0}" >&2
      if [ "$probe_stream_rc" -eq 0 ]; then
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
  return 3
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

  audio_card_dt_root="$(dt_runtime_root)" || return 1

  if find "$audio_card_dt_root" -type d \( \
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

  find "$audio_card_dt_root" -name compatible -type f 2>/dev/null |
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

# audio_remoteproc_filter_events <snapshot> <output-directory>
# Reuse a captured kernel snapshot. Retain current-window audio context and
# failures attributed to the selected remoteproc, never another DSP or old boot
# messages. Missing monotonic timestamps cannot establish current-run failures.
audio_remoteproc_filter_events() {
  arfe_snapshot="$1"
  arfe_out="$2"
  : >"$arfe_out/remoteproc_events.log"
  : >"$arfe_out/remoteproc_failures.log"
  [ -r "$arfe_snapshot" ] || return 0
  awk -v since="${AUDIO_REMOTE_PROC_SINCE:-}" \
      -v instance="${AUDIO_REMOTE_PROC_PATH##*/}" \
      -v controller="${AUDIO_REMOTE_PROC_CONTROLLER:-}" \
      -v events="$arfe_out/remoteproc_events.log" \
      -v failures="$arfe_out/remoteproc_failures.log" '
    since ~ /^[0-9]+$/ && /^\[[[:space:]]*[0-9]+([.][0-9]+)?\]/ {
      stamp = $0
      sub(/^\[[[:space:]]*/, "", stamp)
      sub(/\].*$/, "", stamp)
      if (stamp + 0 < since + 0) next
      message = tolower($0)
      selected = (instance != "" && index($0, "remoteproc " instance ":") != 0) ||
                 (controller != "" && index($0, " " controller ":") != 0)
      benign = message ~ /dummy regulator|supply [^ ]+ not found/
      if (selected || (!benign && message ~ /qcom.apm|apr|gpr|asoc|snd-|va_macro|codec|sound|failed to announce new service|failed while handling packet/))
        print $0 > events
      if (selected && message ~ /crash detected|handling crash|recovering |fatal error|watchdog|stalled initialization/)
        print $0 > failures
    }
  ' "$arfe_snapshot"
}

# audio_remoteproc_report_health <captured-output-directory>
# Retain selected remoteproc state and filtered kernel evidence. Return 1 on
# observed current-run crash/recovery or crashed state, 0 otherwise. This does
# not claim kernel-log availability or DSP health solely from state=running.
audio_remoteproc_report_health() {
  arrh_out="$1"
  [ -n "${AUDIO_REMOTE_PROC_PATH:-}" ] || return 0
  mkdir -p "$arrh_out" || return 1
  arrh_state=unavailable
  if [ -r "$AUDIO_REMOTE_PROC_PATH/state" ]; then
    IFS= read -r arrh_state <"$AUDIO_REMOTE_PROC_PATH/state" || true
  fi
  printf '%s\n' \
    "path=$AUDIO_REMOTE_PROC_PATH" \
    "controller=${AUDIO_REMOTE_PROC_CONTROLLER:-unknown}" \
    "initial_state=${AUDIO_REMOTE_PROC_INITIAL_STATE:-unknown}" \
    "current_state=$arrh_state" \
    "since_uptime=${AUDIO_REMOTE_PROC_SINCE:-unavailable}" \
    >"$arrh_out/remoteproc_state.log"
  list_remoteproc_instances >"$arrh_out/remoteproc_inventory.log" 2>&1 || true
  if [ -r /sys/kernel/debug/devices_deferred ]; then
    cat /sys/kernel/debug/devices_deferred >"$arrh_out/devices_deferred.log"
  else
    printf '%s\n' 'Deferred-probe inventory unavailable, debugfs was not mounted by the test' \
      >"$arrh_out/devices_deferred.log"
  fi
  audio_remoteproc_filter_events "$arrh_out/dmesg_snapshot.log" "$arrh_out" || return 1
  if [ -s "$arrh_out/remoteproc_failures.log" ] || [ "$arrh_state" = crashed ]; then
    AUDIO_REMOTE_PROC_REASON="audio remoteproc crash/recovery observed for $AUDIO_REMOTE_PROC_PATH, current_state=$arrh_state, inspect firmware initialization and artifacts in $arrh_out"
    export AUDIO_REMOTE_PROC_REASON
    log_fail "$AUDIO_REMOTE_PROC_REASON"
    log_file_with_label AUDIO-REMOTEPROC "$arrh_out/remoteproc_state.log"
    log_file_with_label AUDIO-REMOTEPROC-FAILURE "$arrh_out/remoteproc_failures.log" 40
    log_file_with_label AUDIO-KERNEL "$arrh_out/remoteproc_events.log" 60
    return 1
  fi
  return 0
}

# audio_collect_remoteproc_diagnostics <output-directory>
# Capture one preflight kernel snapshot through the common provider, retaining
# access diagnostics. --no-dmesg disables capture and kernel-log classification.
# Return the selected remoteproc health status, preserving an existing failure.
audio_collect_remoteproc_diagnostics() {
  acrd_out="$1"
  [ -n "${AUDIO_REMOTE_PROC_PATH:-}" ] || return 0
  mkdir -p "$acrd_out" || return 1
  if [ "${DMESG_SCAN:-1}" -eq 1 ]; then
    KERNEL_LOG_JOURNAL_FALLBACK="${KERNEL_LOG_JOURNAL_FALLBACK:-1}" \
      scan_dmesg_errors "$acrd_out" \
      'remoteproc[^:]*|qcom[-_]q6[^:]*|qcom[-_]apm[^:]*|snd[^:]*|.*codec[^:]*|asoc[^:]*|gpr[^:]*|apr[^:]*' \
      'dummy regulator|supply [^ ]+ not found|using dummy regulator' \
      >"$acrd_out/kernel_capture.log" 2>&1 || true
    log_info "Audio kernel capture status=${DMESG_ACCESS_STATUS:-unavailable}, raw snapshot and provider diagnostics: $acrd_out"
    if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
      log_warn "Audio remoteproc kernel evidence unavailable, current sysfs state alone cannot rule out earlier recovery, see $acrd_out/dmesg_access.log"
    fi
  else
    # Do not reuse a snapshot left by an earlier invocation with the same suffix.
    : >"$acrd_out/dmesg_snapshot.log"
    : >"$acrd_out/dmesg_errors.log"
    log_info "Audio remoteproc kernel capture disabled by --no-dmesg"
  fi
  audio_remoteproc_report_health "$acrd_out" || return 1
  log_file_with_label AUDIO-KERNEL "$acrd_out/remoteproc_events.log" 60
  return 0
}

# audio_wait_for_alsa_registration <playback|capture>
# Wait up to 30 seconds for a card and another 10 seconds for a directional PCM.
# Called only for ALSA after applicable audio remoteproc preparation. Return 1
# with ALSA and remoteproc diagnostics on stdout when registration is incomplete.
# On timeout, retain FAIL and observe for another 15s before capturing late
# watchdog evidence. Successful registration is also checked for prior recovery.
audio_wait_for_alsa_registration() {
  awfar_direction="$1"
  case "$awfar_direction" in
    playback|capture)
      ;;
    *)
      return 1
      ;;
  esac
  if audio_card_wait_for_cards 30 ""; then
    awfar_elapsed=0
    while [ "$awfar_elapsed" -le 10 ]; do
      if grep -E \
          "^[0-9]+-[0-9]+:.*${awfar_direction}[[:space:]]+[1-9][0-9]*" \
          /proc/asound/pcm >/dev/null 2>&1; then
        log_info "ALSA $awfar_direction PCM registration is ready"
        if [ -n "${LOGDIR:-}" ]; then
          audio_collect_remoteproc_diagnostics "$LOGDIR/remoteproc-preflight" || return 1
        fi
        return 0
      fi
      if [ "$awfar_elapsed" -eq 10 ]; then
        break
      fi
      sleep 1
      awfar_elapsed=$((awfar_elapsed + 1))
    done
  fi
  AUDIO_REMOTE_PROC_REASON="ALSA $awfar_direction registration timed out after audio remoteproc preparation, check sound-card probe, DT and image topology"
  export AUDIO_REMOTE_PROC_REASON
  log_fail "$AUDIO_REMOTE_PROC_REASON"
  if [ -n "${LOGDIR:-}" ] && [ -n "${AUDIO_REMOTE_PROC_PATH:-}" ]; then
    if [ "${DMESG_SCAN:-1}" -eq 1 ]; then
      log_info "Registration has failed, observing for 15s to retain late remoteproc watchdog/recovery evidence, late registration will not change this result"
      sleep 15
    fi
    audio_collect_remoteproc_diagnostics "$LOGDIR/remoteproc-preflight" || true
    log_file_with_label AUDIO-DEFERRED "$LOGDIR/remoteproc-preflight/devices_deferred.log" 40
    log_info "Audio remoteproc diagnostic artifacts: $LOGDIR/remoteproc-preflight"
  fi
  audio_card_log_alsa_inventory
  awfar_remoteprocs="$(list_remoteproc_instances 2>/dev/null)"
  log_info "Remoteproc inventory (path|name|firmware|state): $awfar_remoteprocs"
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
  scan_audio_dmesg "${1:-.}"
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

# Print the image's AudioReach heap path. Optional argument 1 requires modem
# audio even if its passthrough node failed to appear. An explicit override wins.
audio_overlay_heap_node() {
  if [ -n "${AUDIO_DMA_HEAP_NODE:-}" ]; then
    printf '%s\n' "$AUDIO_DMA_HEAP_NODE"
  elif [ "${1:-0}" -eq 1 ] || [ -e /dev/aud_pasthru_modem ]; then
    printf '%s\n' /dev/dma_heap/qcom,audio
  else
    printf '%s\n' /dev/dma_heap/system
  fi
}

# Validate image-provided AudioReach device access for the executing user.
# A modem passthrough device selects the dedicated audio heap. Other paths
# retain the system heap, with AUDIO_DMA_HEAP_NODE taking precedence.
#
# The helper is deliberately non-mutating: it never chmods the node and never
# changes users or groups. Packaged udev/group policy must provide access.
#
# Return:
#   0 - node exists and is readable/writable by the current test process
#   1 - node is missing or inaccessible
audio_validate_dma_heap_access() {
  avdha_node="$(audio_overlay_heap_node "${1:-0}")"

  if [ "${1:-0}" -eq 1 ] && [ ! -e /dev/aud_pasthru_modem ]; then
    log_fail "Selected modem audio has no /dev/aud_pasthru_modem, inspect AudioReach driver binding and image device configuration"
    return 1
  fi

  if [ -e /dev/aud_pasthru_modem ] &&
     { [ ! -r /dev/aud_pasthru_modem ] || [ ! -w /dev/aud_pasthru_modem ]; }; then
    log_fail "The audio process cannot access /dev/aud_pasthru_modem, fix the image udev/group policy"
    return 1
  fi

  if [ ! -e "$avdha_node" ]; then
    log_fail "$avdha_node is missing, provision the required AudioReach heap in the image"
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

# Prepare and validate the Debian or CentOS AudioReach overlay runtime.
#
# The preferred execution model keeps the test runner as root and executes only
# user-session or unprivileged device-access commands as the desktop Audio user.
#
# Args:
#   $1 - 0 for base Audio mode
#        1 for an explicit or runtime-detected overlay, no package installation
#
# Prerequisite for the preferred desktop root path:
#   audio_prepare_desktop_audio_environment 1
#
# Platform behavior:
#   Debian and CentOS overlay:
#     - validate dma-heap access as the desktop Audio user
#     - validate ALSA node access as the desktop Audio user
#     - validate PipeWire through the desktop user session
#     - preserve active PipeWire, validate routes separately
#     - one restart for inactive/failed PipeWire or changed overlay packages
#
#   Debian and CentOS base:
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
    debian|centos)
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
      log_fail "Desktop Audio environment has not been prepared"
      log_fail "Call audio_prepare_desktop_audio_environment 1 before overlay runtime preparation"
      return 1
    fi

    log_info "Preparing desktop AudioReach runtime from root orchestration"
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

    log_info "Preparing desktop AudioReach runtime in temporary re-executed-user mode"
  fi

  ###########################################################################
  # dma-heap existence and diagnostic information
  ###########################################################################

  apor_dma_node="$(audio_overlay_heap_node)"
  if [ ! -e "$apor_dma_node" ]; then
    log_fail "$apor_dma_node is missing"
    return 1
  fi

  if command -v stat >/dev/null 2>&1; then
    apor_dma_mode="$(
      stat -c '%a' "$apor_dma_node" 2>/dev/null ||
        echo unknown
    )"

    apor_dma_owner="$(
      stat -c '%U:%G' "$apor_dma_node" 2>/dev/null ||
        echo unknown
    )"

    log_info "$apor_dma_node mode=$apor_dma_mode owner=$apor_dma_owner"
  fi

  ###########################################################################
  # Validate dma-heap access as the desktop Audio user
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
      "$apor_dma_node"

    apor_dma_rc=$?
  else
    if [ -r "$apor_dma_node" ] &&
       [ -w "$apor_dma_node" ]; then
      apor_dma_rc=0
    else
      apor_dma_rc=1
    fi
  fi

  if [ "$apor_dma_rc" -ne 0 ]; then
    log_fail "Desktop Audio user cannot read and write $apor_dma_node"
    return 1
  fi

  log_pass "$apor_dma_node is accessible to the desktop Audio user"

  ###########################################################################
  # Validate ALSA nodes as the desktop Audio user
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
      log_pass "ALSA device nodes are accessible to the desktop Audio user"
      ;;
    2)
      log_fail "No ALSA control or PCM device nodes were found under /dev/snd"
      return 1
      ;;
    *)
      log_fail "ALSA control and PCM nodes are not accessible to the desktop Audio user"

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
    if audio_run_with_timeout_as_test_user \
        --require-session \
        3s sh -c "$apor_pipewire_probe"; then
      apor_pipewire_control_ready=1
    fi
  else
    if audio_exec_with_timeout 3s sh -c "$apor_pipewire_probe"; then
      apor_pipewire_control_ready=1
    fi
  fi

  apor_pipewire_service_ready=0

  apor_unit_dir="$(audio_scratch_dir)" || return 1
  apor_unit_file="$apor_unit_dir/desktop-overlay-units"
  if ! audio_overlay_read_units "$apor_unit_file" --user pipewire.service ||
     [ "$(wc -l <"$apor_unit_file")" -ne 1 ] ||
     ! grep -q '^pipewire.service|' "$apor_unit_file" ||
     ! audio_overlay_units_idle "$apor_unit_file" "$apor_unit_file"; then
    log_fail "Desktop PipeWire unit query failed or has pending/transitional state, inspect $apor_unit_file.raw. No restart attempted"
    return 1
  fi
  log_file_with_label AUDIO-DESKTOP-UNITS "$apor_unit_file" 10
  if [ "$(cut -d '|' -f 2 "$apor_unit_file")" = active ]; then
    apor_pipewire_service_ready=1
  fi

  ###########################################################################
  # Preserve a healthy unchanged PipeWire runtime
  ###########################################################################

  if [ "$apor_packages_changed" -eq 0 ] &&
     [ "$apor_pipewire_service_ready" -eq 1 ]; then
    if [ "$apor_pipewire_control_ready" -eq 1 ]; then
      log_info "PipeWire user service and control plane are already ready"
    else
      log_warn "Active PipeWire control plane is not ready, preserving the service for bounded route discovery"
    fi
    log_info "PipeWire restart is not required, physical route readiness is checked separately"
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
    log_fail "Failed to restart the desktop PipeWire user service"
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
      if audio_run_with_timeout_as_test_user \
          --require-session \
          3s sh -c "$apor_pipewire_probe"; then
        apor_pipewire_control_ready=1
      fi
    else
      if audio_exec_with_timeout 3s sh -c "$apor_pipewire_probe"; then
        apor_pipewire_control_ready=1
      fi
    fi

    if [ "$apor_pipewire_service_ready" -eq 1 ] &&
       [ "$apor_pipewire_control_ready" -eq 1 ]; then
      log_pass "Desktop AudioReach runtime is ready"
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
#   Ubuntu server     - ensure ALSA utilities
#   Ubuntu desktop    - ensure ALSA, PipeWire, PipeWire-Pulse, and WirePlumber
#   Ubuntu overlay    - not enabled, report not applicable without package work
#   CentOS base       - defer client recovery until backend selection
#   CentOS overlay    - ensure the documented Qualcomm AudioReach RPM set
#   other distros     - no-op until their package mappings are verified
#
# Environment:
#   AUDIO_PACKAGE_PROFILE=auto|server|desktop
#   AUDIO_PACKAGE_UPDATE=1 to upgrade installed mapped Ubuntu packages
#
# Return:
#   0 - ready or not applicable
#   1 - package preparation failed
#   2 - AudioReach DKMS package changed; reboot required
#   3 - requested AudioReach overlay is not enabled on this distribution
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
    debian|ubuntu|centos)
      ;;
    *)
      log_info "Audio package preparation is not enabled for os=$atp_os_id"
      return 0
      ;;
  esac

  if [ "$atp_os_id" = "ubuntu" ] &&
     [ "$atp_overlay_requested" -eq 1 ]; then
    log_info "Ubuntu AudioReach overlay is not enabled"
    log_info "Run without --overlay to validate the Ubuntu base Audio stack"
    return 3
  fi
 
  # Host-distribution package preparation must run from root orchestration.
  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    log_fail "Audio package preparation must run as root, os=$atp_os_id"
    return 1
  fi

  if [ "$atp_os_id" = "ubuntu" ]; then
    atp_ubuntu_profile="${AUDIO_PACKAGE_PROFILE:-auto}"

    case "$atp_ubuntu_profile" in
      auto|server|desktop)
        ;;
      *)
        log_fail "Invalid AUDIO_PACKAGE_PROFILE: $atp_ubuntu_profile"
        return 1
        ;;
    esac

    if [ "$atp_ubuntu_profile" = "auto" ]; then
      if command -v systemctl >/dev/null 2>&1 &&
         systemctl is-active --quiet graphical.target 2>/dev/null; then
        atp_ubuntu_profile="desktop"
      else
        atp_ubuntu_profile="server"
      fi
    fi

    if [ "${AUDIO_PACKAGE_UPDATE:-0}" = "1" ]; then
      PKG_PACKAGE_SET_UPGRADE=1
      export PKG_PACKAGE_SET_UPGRADE
      log_info "Ubuntu Audio package update is enabled"
    fi

    if ! command -v pkg_ensure_required_package_set_present \
        >/dev/null 2>&1; then
      log_fail "Required package-set helper is unavailable"
      return 1
    fi

    if ! pkg_ensure_required_package_set_present audio-base; then
      log_fail "Failed to ensure Ubuntu Audio base package set"
      return 1
    fi

    if [ "$atp_ubuntu_profile" = "desktop" ] &&
       ! pkg_ensure_required_package_set_present audio-desktop; then
      log_fail "Failed to ensure Ubuntu desktop Audio package set"
      return 1
    fi

    if command -v modinfo >/dev/null 2>&1 &&
       modinfo snd-soc-wcd938x >/dev/null 2>&1; then
      if [ ! -d /sys/module/snd_soc_wcd938x ]; then
        if command -v modprobe >/dev/null 2>&1; then
          if modprobe snd-soc-wcd938x; then
            log_info "Loaded optional Audio codec module: snd-soc-wcd938x"
          else
            log_warn "Unable to load optional Audio codec module: snd-soc-wcd938x"
          fi
        else
          log_warn "Optional Audio codec module is available but modprobe is unavailable"
        fi
      fi
    fi

    log_pass "Ubuntu Audio package profile is ready: $atp_ubuntu_profile"
    return 0
  fi

  if [ "$atp_os_id" = "centos" ] &&
     [ "$atp_overlay_requested" -eq 0 ]; then
    log_info "CentOS base Audio mode defers client package recovery until backend selection"
    return 0
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
  # Debian and CentOS AudioReach overlay mode
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
 
  case "$atp_os_id" in
    centos)
      atp_plugin_package="audioreach-pipewire-plugin"
      atp_dkms_package="audioreach-dkms"
      atp_support_package="audioreach-pal"
      atp_overlay_source="auto"
      ;;
    *)
      atp_plugin_package="audioreach-pipewire-plugin"
      atp_dkms_package="audioreach-dkms"
      atp_support_package="audioreach-conf"
      atp_overlay_source="qli-staging"
      ;;
  esac

  # Capture AudioReach package versions before package preparation. These
  # values let us distinguish an already-ready target from an install or
  # upgrade performed during this invocation.
  atp_before_plugin="$(
    pkg_installed_package_version \
      "$atp_plugin_package" 2>/dev/null ||
      true
  )"
 
  atp_before_dkms="$(
    pkg_installed_package_version \
      "$atp_dkms_package" 2>/dev/null ||
      true
  )"
 
  atp_before_support="$(
    pkg_installed_package_version \
      "$atp_support_package" 2>/dev/null ||
      true
  )"
 
  # The optional package provider intentionally requires the literal
  # --overlay argument. Passing only the internal value "1" makes the provider
  # treat the request as base mode.
  if ! pkg_ensure_optional_package_set_present \
      audio \
      "$atp_overlay_source" \
      auto \
      --overlay \
      "$@"; then
    log_fail "Failed to ensure $atp_os_id AudioReach package set"
    return 1
  fi
 
  atp_after_plugin="$(
    pkg_installed_package_version \
      "$atp_plugin_package" 2>/dev/null ||
      true
  )"
 
  atp_after_dkms="$(
    pkg_installed_package_version \
      "$atp_dkms_package" 2>/dev/null ||
      true
  )"
 
  atp_after_support="$(
    pkg_installed_package_version \
      "$atp_support_package" 2>/dev/null ||
      true
  )"
 
  if [ "$atp_before_plugin" != "$atp_after_plugin" ] ||
     [ "$atp_before_dkms" != "$atp_after_dkms" ] ||
     [ "$atp_before_support" != "$atp_after_support" ]; then
    AUDIO_OVERLAY_PACKAGES_CHANGED=1
    export AUDIO_OVERLAY_PACKAGES_CHANGED
 
    log_info "AudioReach package state changed during package preparation"
 
    if [ "$atp_before_plugin" != "$atp_after_plugin" ]; then
      log_info "AudioReach PipeWire plugin version changed: ${atp_before_plugin:-not-installed} -> ${atp_after_plugin:-not-installed}"
    fi
 
    if [ "$atp_before_support" != "$atp_after_support" ]; then
      log_info "AudioReach support package changed, package=$atp_support_package version=${atp_before_support:-not-installed}->${atp_after_support:-not-installed}"
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
 
  log_pass "$atp_os_id AudioReach package set is ready"
  return 0
}

# audio_prepare_backend_client_packages <backend>
# Ensure the complete playback and recording client set for one selected
# backend. Debian, Ubuntu, and CentOS use exact package-set mappings. Yocto and
# other image-managed environments retain their preinstalled userspace.
# Successful preparation is cached per backend for the current runner process.
# Produces no machine-readable stdout. Returns 0 when ready and 1 on failure.
audio_prepare_backend_client_packages() {
  apbcp_backend="$1"

  case "$apbcp_backend" in
    pipewire|pulseaudio|alsa)
      apbcp_package_set="audio-client-$apbcp_backend"
      ;;
    *)
      log_fail "Unsupported Audio backend for package preparation: $apbcp_backend"
      return 1
      ;;
  esac

  case " ${AUDIO_PREPARED_CLIENT_BACKENDS:-} " in
    *" $apbcp_backend "*)
      return 0
      ;;
  esac

  if command -v pkg_detect_os_id >/dev/null 2>&1; then
    apbcp_os_id="$(pkg_detect_os_id 2>/dev/null || echo unknown)"
  else
    apbcp_os_id="$(
      sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//;s/"$//' |
        tr '[:upper:]' '[:lower:]'
    )"
  fi

  [ -n "$apbcp_os_id" ] || apbcp_os_id="unknown"

  case "$apbcp_os_id" in
    qcom-distro|poky|openembedded|oe)
      log_info "Native image uses preinstalled $apbcp_backend Audio clients"
      AUDIO_PREPARED_CLIENT_BACKENDS="${AUDIO_PREPARED_CLIENT_BACKENDS:+$AUDIO_PREPARED_CLIENT_BACKENDS }$apbcp_backend"
      return 0
      ;;
    debian|ubuntu|centos)
      ;;
    *)
      log_info "Audio backend client package recovery is not enabled, os=$apbcp_os_id backend=$apbcp_backend"
      AUDIO_PREPARED_CLIENT_BACKENDS="${AUDIO_PREPARED_CLIENT_BACKENDS:+$AUDIO_PREPARED_CLIENT_BACKENDS }$apbcp_backend"
      return 0
      ;;
  esac

  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    log_fail "Audio backend client package preparation must run as root, os=$apbcp_os_id backend=$apbcp_backend"
    return 1
  fi

  if ! command -v pkg_ensure_required_package_set_present >/dev/null 2>&1; then
    log_fail "Required package-set helper is unavailable"
    return 1
  fi

  log_info "Ensuring complete Audio backend client package set, os=$apbcp_os_id backend=$apbcp_backend set=$apbcp_package_set"

  if ! pkg_ensure_required_package_set_present "$apbcp_package_set"; then
    log_fail "Failed to ensure Audio backend client package set, os=$apbcp_os_id backend=$apbcp_backend set=$apbcp_package_set"
    return 1
  fi

  log_pass "Audio backend client package set is ready, os=$apbcp_os_id backend=$apbcp_backend"
  AUDIO_PREPARED_CLIENT_BACKENDS="${AUDIO_PREPARED_CLIENT_BACKENDS:+$AUDIO_PREPARED_CLIENT_BACKENDS }$apbcp_backend"
  return 0
}

# Return success when a user account is suitable for desktop Audio execution.
audio_user_is_regular() {
  auir_user="$1"

  if [ -z "$auir_user" ] || [ "$auir_user" = "root" ]; then
    return 1
  fi

  if ! id "$auir_user" >/dev/null 2>&1; then
    return 1
  fi

  if command -v getent >/dev/null 2>&1; then
    auir_entry="$(getent passwd "$auir_user" 2>/dev/null | sed -n '1p')"
  else
    auir_entry="$(
      awk -F: -v requested_user="$auir_user" \
        '$1 == requested_user { print; exit }' \
        /etc/passwd 2>/dev/null
    )"
  fi

  auir_uid="$(printf '%s\n' "$auir_entry" | awk -F: 'NR == 1 { print $3 }')"
  auir_shell="$(printf '%s\n' "$auir_entry" | awk -F: 'NR == 1 { print $7 }')"

  case "$auir_uid" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  if [ "$auir_uid" -eq 0 ] || [ "$auir_uid" -ge 65534 ]; then
    return 1
  fi

  case "$auir_shell" in
    */false|*/nologin)
      return 1
      ;;
  esac

  return 0
}

# Print the regular user that owns the active desktop session. If no active
# session is visible, use the only regular login account on the image.
# Diagnostics must remain on stderr because callers use command substitution.
audio_find_regular_session_user() {
  afrsu_user="${AUDIO_TEST_USER:-}"
  afrsu_sessions=""
  afrsu_runtime_dir=""
  afrsu_uid=""
  afrsu_candidates=""
  afrsu_count=0

  if audio_user_is_regular "$afrsu_user"; then
    printf '%s\n' "$afrsu_user"
    return 0
  fi

  if command -v loginctl >/dev/null 2>&1; then
    afrsu_sessions="$(
      loginctl list-sessions --no-legend 2>/dev/null |
        awk '{ print $1 }'
    )"

    for afrsu_session in $afrsu_sessions; do
      afrsu_active="$(
        loginctl show-session "$afrsu_session" -p Active --value 2>/dev/null
      )"
      [ "$afrsu_active" = "yes" ] || continue

      afrsu_user="$(
        loginctl show-session "$afrsu_session" -p Name --value 2>/dev/null
      )"
      if audio_user_is_regular "$afrsu_user"; then
        printf '%s\n' "$afrsu_user"
        return 0
      fi
    done
  fi

  for afrsu_runtime_dir in /run/user/[0-9]*; do
    [ -d "$afrsu_runtime_dir" ] || continue

    afrsu_uid="${afrsu_runtime_dir##*/}"
    case "$afrsu_uid" in
      ''|*[!0-9]*)
        continue
        ;;
    esac

    if command -v getent >/dev/null 2>&1; then
      afrsu_user="$(
        getent passwd "$afrsu_uid" 2>/dev/null |
          awk -F: 'NR == 1 { print $1 }'
      )"
    else
      afrsu_user="$(
        awk -F: -v requested_uid="$afrsu_uid" \
          '$3 == requested_uid { print $1; exit }' \
          /etc/passwd 2>/dev/null
      )"
    fi

    if audio_user_is_regular "$afrsu_user"; then
      printf '%s\n' "$afrsu_user"
      return 0
    fi
  done

  if command -v getent >/dev/null 2>&1; then
    afrsu_candidates="$(
      getent passwd 2>/dev/null |
        awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(false|nologin)$/ { print $1 }'
    )"
  else
    afrsu_candidates="$(
      awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(false|nologin)$/ { print $1 }' \
        /etc/passwd 2>/dev/null
    )"
  fi

  afrsu_count="$(printf '%s\n' "$afrsu_candidates" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  if [ "$afrsu_count" -eq 1 ] 2>/dev/null; then
    printf '%s\n' "$afrsu_candidates"
    return 0
  fi

  return 1
}

# Prepare a Debian or CentOS Audio test user and optional systemd user manager.
#
# Unlike audio_prepare_debian_audio_test_user(), this function does not:
#   - re-execute the complete runner
#   - change ownership of result or log directories
#   - create or modify clip directories
#   - invoke runuser
#
# The calling test remains the root orchestrator. Individual audio commands
# will be executed as the prepared desktop Audio user through
# audio_run_as_test_user().
#
# Args:
#   $1 - 1 when a PipeWire systemd user manager is required
#        0 for ALSA-only operations
#
# Platform behavior:
#   Debian and CentOS:
#     - require root orchestration
#     - ensure AUDIO_TEST_USER belongs to audio
#     - optionally start or refresh user@UID.service
#     - export the resolved user-session environment
#
#   Yocto/qcom-distro/other:
#     - strict no-op
#
# Environment exported on applicable desktop distributions:
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
audio_prepare_desktop_audio_environment() {
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
    debian|centos)
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
    log_fail "Desktop Audio environment preparation must run as root"
    return 1
  fi

  case "$apdae_os_id" in
    debian)
      apdae_default_user="debian"
      ;;
    centos)
      apdae_default_user="$(audio_find_regular_session_user 2>/dev/null || true)"
      ;;
  esac

  apdae_user="${AUDIO_TEST_USER:-$apdae_default_user}"

  if [ -z "$apdae_user" ]; then
    log_fail "No regular desktop Audio user could be discovered on os=$apdae_os_id"
    log_fail "Start a regular user session before running the Audio test"
    return 1
  fi

  if ! id "$apdae_user" >/dev/null 2>&1; then
    log_fail "Desktop Audio test user does not exist: $apdae_user"
    return 1
  fi

  if ! audio_user_is_regular "$apdae_user"; then
    log_fail "Desktop Audio test user is not a regular login account: $apdae_user"
    return 1
  fi

  if command -v getent >/dev/null 2>&1; then
    if ! getent group audio >/dev/null 2>&1; then
      log_fail "Required desktop Audio group does not exist: audio"
      return 1
    fi
  elif ! grep -q '^audio:' /etc/group 2>/dev/null; then
    log_fail "Required desktop Audio group does not exist: audio"
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

    log_info "Adding desktop Audio test user to audio group: $apdae_user"

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
        log_info "Restarting desktop user manager after audio-group update: $apdae_user_unit"

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
          log_fail "Failed to restart desktop user manager: $apdae_user_unit"
          return 1
        fi
      else
        log_pass "Desktop user manager is already active: $apdae_user_unit"
      fi
    else
      log_info "Starting desktop user manager: $apdae_user_unit"

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
        log_fail "Failed to start desktop user manager: $apdae_user_unit"

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

    log_info "Waiting for desktop user runtime and D-Bus, timeout=${apdae_wait_timeout}s"

    while [ "$apdae_wait" -lt "$apdae_wait_timeout" ]; do
      if [ -d "$apdae_runtime_dir" ] &&
         [ -S "$apdae_runtime_dir/bus" ]; then
        break
      fi

      sleep 1
      apdae_wait=$((apdae_wait + 1))
    done

    if [ ! -d "$apdae_runtime_dir" ]; then
      log_fail "Desktop user runtime directory is unavailable: $apdae_runtime_dir"
      return 1
    fi

    if [ ! -S "$apdae_runtime_dir/bus" ]; then
      log_fail "Desktop user D-Bus is unavailable: $apdae_runtime_dir/bus"
      return 1
    fi

    log_pass "Desktop user runtime is ready: $apdae_runtime_dir"
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

  log_pass "Desktop Audio environment prepared: os=$apdae_os_id user=$apdae_user uid=$apdae_uid"
  return 0
}

# Compatibility wrapper for existing callers while suites migrate to the
# distribution-neutral helper name.
audio_prepare_debian_audio_environment() {
  audio_prepare_desktop_audio_environment "$@"
}

# Execute one Audio command as the configured desktop Audio user.
#
# The main test runner remains the root orchestrator. Only the supplied command
# is executed as the prepared user.
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
# Return the regular user that owns an active PipeWire or PulseAudio runtime.
# Output is machine-readable so callers can use command substitution safely.
# AUDIO_TEST_USER is preferred when it owns a usable runtime socket.
audio_find_desktop_audio_user() {
  adau_preferred_user="${AUDIO_TEST_USER:-}"
  adau_runtime_dir=""
  adau_uid=""
  adau_user=""
  adau_passwd_entry=""
  adau_shell=""

  if [ -n "$adau_preferred_user" ] && id "$adau_preferred_user" >/dev/null 2>&1; then
    adau_uid="$(id -u "$adau_preferred_user" 2>/dev/null || true)"
    adau_runtime_dir="/run/user/$adau_uid"

    if [ -S "$adau_runtime_dir/pipewire-0" ] ||
       [ -S "$adau_runtime_dir/pulse/native" ]; then
      printf '%s\n' "$adau_preferred_user"
      return 0
    fi
  fi

  for adau_runtime_dir in /run/user/[0-9]*; do
    [ -d "$adau_runtime_dir" ] || continue

    adau_uid="${adau_runtime_dir##*/}"
    case "$adau_uid" in
      ''|*[!0-9]*)
        continue
        ;;
    esac

    if [ ! -S "$adau_runtime_dir/pipewire-0" ] &&
       [ ! -S "$adau_runtime_dir/pulse/native" ]; then
      continue
    fi

    if command -v getent >/dev/null 2>&1; then
      adau_passwd_entry="$(getent passwd "$adau_uid" 2>/dev/null | sed -n '1p')"
    else
      adau_passwd_entry="$(awk -F: -v requested_uid="$adau_uid" '$3 == requested_uid { print; exit }' /etc/passwd 2>/dev/null)"
    fi

    adau_user="$(printf '%s\n' "$adau_passwd_entry" | awk -F: 'NR == 1 { print $1 }')"
    adau_shell="$(printf '%s\n' "$adau_passwd_entry" | awk -F: 'NR == 1 { print $7 }')"
    [ -n "$adau_user" ] || continue

    case "$adau_shell" in
      */false|*/nologin)
        continue
        ;;
    esac

    printf '%s\n' "$adau_user"
    return 0
  done

  return 1
}

# Configure Ubuntu command execution from runtime desktop-session evidence.
# Headless Ubuntu Server stays in the current root context for direct ALSA.
audio_configure_ubuntu_desktop_session() {
  acud_os_id="${1:-unknown}"
  acud_user=""
  acud_uid=""
  acud_home=""
  acud_passwd_entry=""
  acud_runtime_dir=""

  AUDIO_USE_DESKTOP_SESSION=0
  export AUDIO_USE_DESKTOP_SESSION

  if [ "$acud_os_id" != "ubuntu" ] ||
     [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    return 0
  fi

  acud_user="$(audio_find_desktop_audio_user 2>/dev/null || true)"
  if [ -z "$acud_user" ]; then
    log_info "No active Ubuntu desktop Audio session was found, keeping direct system context"
    return 0
  fi

  acud_uid="$(id -u "$acud_user" 2>/dev/null || true)"
  if [ -z "$acud_uid" ]; then
    log_warn "Could not resolve the active Ubuntu Audio user uid: $acud_user"
    return 0
  fi

  acud_runtime_dir="/run/user/$acud_uid"
  if [ ! -d "$acud_runtime_dir" ] ||
     [ ! -S "$acud_runtime_dir/bus" ]; then
    log_info "Ubuntu Audio runtime lacks a desktop D-Bus session, keeping direct system context: $acud_runtime_dir"
    return 0
  fi

  if command -v getent >/dev/null 2>&1; then
    acud_passwd_entry="$(
      getent passwd "$acud_user" 2>/dev/null |
        sed -n '1p'
    )"
  else
    acud_passwd_entry="$(
      awk -F: -v requested_user="$acud_user" \
        '$1 == requested_user { print; exit }' \
        /etc/passwd 2>/dev/null
    )"
  fi

  acud_home="$(
    printf '%s\n' "$acud_passwd_entry" |
      awk -F: 'NR == 1 { print $6 }'
  )"
  [ -n "$acud_home" ] || acud_home="/home/$acud_user"

  AUDIO_TEST_USER="$acud_user"
  AUDIO_TEST_UID="$acud_uid"
  AUDIO_TEST_HOME="$acud_home"
  AUDIO_TEST_RUNTIME_DIR="$acud_runtime_dir"
  AUDIO_TEST_DBUS_ADDRESS="unix:path=$acud_runtime_dir/bus"
  AUDIO_USE_DESKTOP_SESSION=1

  export AUDIO_TEST_USER
  export AUDIO_TEST_UID
  export AUDIO_TEST_HOME
  export AUDIO_TEST_RUNTIME_DIR
  export AUDIO_TEST_DBUS_ADDRESS
  export AUDIO_USE_DESKTOP_SESSION

  log_pass "Using active Ubuntu desktop Audio session: user=$acud_user uid=$acud_uid"
  return 0
}

# Platform behavior:
#   Debian and CentOS:
#     - require the caller to be root
#     - verify the configured Audio user and audio-group membership
#     - execute only the supplied command through runuser
#
#   Ubuntu root playback runs:
#     - when AUDIO_USE_DESKTOP_SESSION=1, discover the active regular user
#       owning PipeWire or PulseAudio and execute through that user session
#
#   Yocto/qcom-distro/other:
#     - execute the command directly as the current user
#
# Prerequisite on Debian and CentOS:
#   audio_prepare_desktop_audio_environment must run before this helper.
#
# Returns:
#   The exact exit status of the supplied command.
#   1 when user/session preparation is invalid.
audio_run_as_test_user() {
  aratu_require_session=0
  aratu_require_audio_group=0
  aratu_desktop_session_mode=0

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
    debian|centos)
      aratu_require_audio_group=1
      ;;
    ubuntu)
      if [ "${AUDIO_USE_DESKTOP_SESSION:-0}" -ne 1 ] ||
         [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        "$@"
        return $?
      fi

      aratu_desktop_session_mode=1
      ;;
    *)
      # Preserve existing native/Yocto execution behavior.
      "$@"
      return $?
      ;;
  esac

  if [ "${AUDIO_TEST_USER_REEXEC:-0}" -eq 1 ] &&
     [ "$(id -un 2>/dev/null || echo unknown)" = "${AUDIO_TEST_USER:-}" ]; then
    "$@"
    return $?
  fi

  ###########################################################################
  # Desktop root orchestration validation
  ###########################################################################

  if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    log_fail "Audio command execution must be initiated by root"
    return 1
  fi

  if ! command -v runuser >/dev/null 2>&1; then
    log_fail "runuser is unavailable, cannot execute an Audio command in the user session"
    return 1
  fi

  if [ "$aratu_desktop_session_mode" -eq 1 ]; then
    aratu_user="$(audio_find_desktop_audio_user)"
    if [ -z "$aratu_user" ]; then
      log_fail "No active regular-user PipeWire or PulseAudio session was found"
      return 1
    fi
  else
    aratu_user="${AUDIO_TEST_USER:-}"
    if [ -z "$aratu_user" ]; then
      log_fail "The prepared Audio test user is unavailable"
      return 1
    fi
  fi

  if ! id "$aratu_user" >/dev/null 2>&1; then
    log_fail "Audio test user does not exist: $aratu_user"
    return 1
  fi

  if [ "$aratu_require_audio_group" -eq 1 ] &&
     ! id -nG "$aratu_user" 2>/dev/null |
      tr ' ' '\n' |
      grep -qx audio; then
    log_fail "Desktop Audio test user is not a member of audio: $aratu_user"
    log_fail "Call audio_prepare_desktop_audio_environment before running user commands"
    return 1
  fi

  ###########################################################################
  # Resolve user account details
  ###########################################################################

  aratu_uid="$(id -u "$aratu_user" 2>/dev/null || true)"

  if [ -z "$aratu_uid" ]; then
    log_fail "Unable to resolve uid for Audio test user: $aratu_user"
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

  if [ "$aratu_desktop_session_mode" -eq 1 ]; then
    aratu_runtime_dir="/run/user/$aratu_uid"
    aratu_bus_address="unix:path=$aratu_runtime_dir/bus"
  else
    aratu_runtime_dir="$(
      printf '%s\n' \
        "${AUDIO_TEST_RUNTIME_DIR:-/run/user/$aratu_uid}"
    )"

    aratu_bus_address="$(
      printf '%s\n' \
        "${AUDIO_TEST_DBUS_ADDRESS:-unix:path=$aratu_runtime_dir/bus}"
    )"
  fi

  ###########################################################################
  # Optional user-session validation
  ###########################################################################

  if [ "$aratu_require_session" -eq 1 ]; then
    if [ ! -d "$aratu_runtime_dir" ]; then
      log_fail "Desktop Audio user runtime directory is unavailable: $aratu_runtime_dir"
      return 1
    fi

    if [ ! -S "$aratu_runtime_dir/bus" ]; then
      log_fail "Desktop Audio user D-Bus socket is unavailable: $aratu_runtime_dir/bus"
      return 1
    fi
  fi

  ###########################################################################
  # Execute only the requested command as the desktop Audio user
  ###########################################################################

  case "${VERBOSE:-0}" in
    1)
      log_info "Running Audio command as user=$aratu_user: $1" >&2
      ;;
  esac

  # Only the dedicated scratch child is writable by the desktop user.
  aratu_tmp_owned=0
  aratu_tmp_dir="${AUDIO_RECORD_USER_CAPTURE_DIR:-}"
  if [ -z "$aratu_tmp_dir" ]; then
    aratu_tmp_base="$(audio_scratch_dir)" || return 1
    aratu_tmp_dir="$(mktemp -d "$aratu_tmp_base/audio-user-tmp.XXXXXX")" || return 1
    aratu_tmp_owned=1
    if ! chown "$aratu_uid" "$aratu_tmp_dir"; then
      rmdir "$aratu_tmp_dir" 2>/dev/null || true
      return 1
    fi
  fi
  if ! runuser -u "$aratu_user" -- test -w "$aratu_tmp_dir"; then
    log_fail "Audio user '$aratu_user' cannot write CWD scratch directory $aratu_tmp_dir, use a launch directory the user can traverse"
    if [ "$aratu_tmp_owned" -eq 1 ]; then
      rmdir "$aratu_tmp_dir" 2>/dev/null || true
    fi
    return 1
  fi

  runuser \
    -u "$aratu_user" \
    -- \
    env \
      HOME="$aratu_home" \
      USER="$aratu_user" \
      LOGNAME="$aratu_user" \
      SHELL="$aratu_shell" \
      TMPDIR="$aratu_tmp_dir" \
      XDG_RUNTIME_DIR="$aratu_runtime_dir" \
      DBUS_SESSION_BUS_ADDRESS="$aratu_bus_address" \
      AUDIO_TEST_USER="$aratu_user" \
      AUDIO_TEST_UID="$aratu_uid" \
      AUDIO_TEST_HOME="$aratu_home" \
      AUDIO_TEST_RUNTIME_DIR="$aratu_runtime_dir" \
      AUDIO_TEST_DBUS_ADDRESS="$aratu_bus_address" \
      AUDIO_TEST_COMMAND_USER_CONTEXT=1 \
      "$@"

  aratu_command_rc=$?
  if [ "$aratu_tmp_owned" -eq 1 ]; then
    rmdir "$aratu_tmp_dir" 2>/dev/null || true
  fi
  return "$aratu_command_rc"
}

# Execute one existing audio_common.sh helper as the desktop Audio user.
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
    debian|centos)
      ;;
    ubuntu)
      if [ "${AUDIO_USE_DESKTOP_SESSION:-0}" -ne 1 ] ||
         [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        "$arhatu_helper" "$@"
        return $?
      fi
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

# Execute one command through audio_exec_with_timeout as the desktop Audio user.
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

# Stop and reap one recorder child owned by the calling shell.
# Argument: child PID. No stdout, diagnostics go to stderr. Return 1 if SIGKILL
# was needed, 2 if the child exited before TERM could be sent, otherwise 0.
# pw-record may return 1 on SIGTERM even when it finalized a valid WAV.
audio_record_stop_child() {
  arsc_pid="$1"
  arsc_forced=0
  if ! kill -TERM "$arsc_pid" 2>/dev/null; then
    arsc_rc=0
    wait "$arsc_pid" 2>/dev/null || arsc_rc=$?
    printf 'AUDIO_CAPTURE recorder_exit_before_stop_rc=%s\n' "$arsc_rc" >&2
    return 2
  fi
  arsc_waited=0
  while kill -0 "$arsc_pid" 2>/dev/null && [ "$arsc_waited" -lt 3 ]; do
    sleep 1
    arsc_waited=$((arsc_waited + 1))
  done
  if kill -0 "$arsc_pid" 2>/dev/null; then
    arsc_forced=1
    kill -KILL "$arsc_pid" 2>/dev/null || true
  fi
  wait "$arsc_pid" 2>/dev/null || true
  return "$arsc_forced"
}

# Monitor a targeted PipeWire capture in the same user session as its child.
# Arguments: WAV path, requested seconds, startup grace, explicit timeout (0=auto),
# optionally --pipewire-links and --until-complete <marker>, then the command.
# A completion marker additionally keeps loopback recording through playback.
# Its absence never extends startup, stall or total capture deadlines.
# Logs go to stderr. Optional pw-link output goes to <WAV path>.links while
# recording, after the first payload. The diagnostic child is killed/reaped
# within two polling intervals or when capture ends, without extending deadlines.
# Auto mode allows requested+grace for startup, then requested+grace for capture.
# Idle progress is bounded by max(grace, 3). Explicit timeout caps the whole
# capture, never triggers a retry, and does not reduce the requested WAV length.
# Return 0 only after collecting the requested PCM duration and a graceful stop.
# Return 1 for startup, stall, deadline, format or child errors. Always reap the
# owned child, allowing at most three additional seconds for WAV finalization.
# Temporarily forwards termination signals to that child, preserving caller
# traps on return and leaving its EXIT cleanup installed throughout.
audio_record_with_progress() {
  arwp_file="$1"
  arwp_seconds="$(audio_parse_secs "$2" 2>/dev/null || echo 0)"
  arwp_grace="$3"
  arwp_limit="$(audio_parse_secs "$4" 2>/dev/null)" || {
    printf '%s\n' 'AUDIO_CAPTURE status=FAIL reason=invalid-capture-timeout' >&2
    return 1
  }
  shift 4
  arwp_links=0
  arwp_completion=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pipewire-links)
        arwp_links=1
        shift
        ;;
      --until-complete)
        [ "$#" -ge 2 ] && [ -n "$2" ] || return 1
        arwp_completion="$2"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  if ! is_unsigned_number "$arwp_seconds" || [ "$arwp_seconds" -eq 0 ] ||
     ! is_unsigned_number "$arwp_grace" || ! is_unsigned_number "$arwp_limit" ||
     [ "$#" -eq 0 ]; then
    printf '%s\n' 'AUDIO_CAPTURE status=FAIL reason=invalid-capture-budget' >&2
    return 1
  fi
  for arwp_tool in dd od awk; do
    if ! command -v "$arwp_tool" >/dev/null 2>&1; then
      printf 'AUDIO_CAPTURE status=FAIL reason=missing-tool tool=%s\n' "$arwp_tool" >&2
      return 1
    fi
  done

  arwp_window=$((arwp_seconds + arwp_grace))
  arwp_idle_limit="$arwp_grace"
  if [ "$arwp_idle_limit" -lt 3 ]; then
    arwp_idle_limit=3
  fi
  arwp_start="$(get_monotonic_seconds)"
  arwp_deadline=$((arwp_start + 2 * arwp_window))
  if [ "$arwp_limit" -gt 0 ]; then
    arwp_deadline=$((arwp_start + arwp_limit))
  fi
  arwp_first=0
  arwp_last="$arwp_start"
  arwp_payload=0
  arwp_previous=0
  arwp_meta=""
  arwp_reason=recorder-exited
  arwp_pid=""
  arwp_links_pid=""
  arwp_links_start=0
  if [ "$arwp_links" -eq 1 ]; then
    if ! printf '%s\n' 'AUDIO_LINKS status=not-started reason=no-payload-yet' >"${arwp_file}.links"; then
      printf '%s\n' 'AUDIO_LINKS status=unavailable reason=output-not-writable' >&2
      arwp_links=0
    fi
  fi
  arwp_saved_traps="$(trap)"
  trap 'if [ -n "$arwp_links_pid" ]; then
    audio_record_finish_link_snapshot "$arwp_links_pid" "${arwp_file}.links"
  fi
  if [ -n "$arwp_pid" ]; then
    audio_record_stop_child "$arwp_pid" || true
  fi
  exit 1' HUP INT TERM
  printf 'AUDIO_CAPTURE requested=%ss startup_limit=%ss idle_limit=%ss total_limit=%ss\n' \
    "$arwp_seconds" "$arwp_window" "$arwp_idle_limit" "$((arwp_deadline - arwp_start))" >&2
  "$@" &
  arwp_pid=$!
  arwp_child_start="$(awk '{sub(/^.*\) /, ""); print $20}' "/proc/$arwp_pid/stat" 2>/dev/null || true)"
  if [ -n "$arwp_child_start" ]; then
    printf '%s|%s\n' "$arwp_pid" "$arwp_child_start" >"$arwp_file.recorder" || true
  fi

  while kill -0 "$arwp_pid" 2>/dev/null; do
    arwp_now="$(get_monotonic_seconds)"
    if [ -n "$arwp_links_pid" ] &&
       { ! kill -0 "$arwp_links_pid" 2>/dev/null ||
         [ "$((arwp_now - arwp_links_start))" -ge 2 ]; }; then
      audio_record_finish_link_snapshot "$arwp_links_pid" "${arwp_file}.links"
      arwp_links_pid=""
    fi
    if [ "$arwp_now" -gt "$arwp_deadline" ]; then
      arwp_reason=capture-deadline
      break
    fi
    if [ -z "$arwp_meta" ]; then
      arwp_meta="$(audio_wav_header_metadata "$arwp_file" 2>/dev/null || true)"
      if [ -n "$arwp_meta" ]; then
        IFS='|' read -r arwp_offset arwp_declared arwp_format arwp_channels \
          arwp_rate arwp_byte_rate arwp_align arwp_bits <<EOF
$arwp_meta
EOF
        if [ "$arwp_channels" -le 0 ] || [ "$arwp_rate" -le 0 ] ||
           [ "$arwp_align" -le 0 ] ||
           [ "$arwp_byte_rate" -ne $((arwp_rate * arwp_align)) ]; then
          arwp_reason=invalid-wav-header
          break
        fi
        case "$arwp_format" in
          1|3)
            ;;
          *)
            arwp_reason=unsupported-wav-format
            break
            ;;
        esac
        arwp_goal=$((arwp_seconds * arwp_byte_rate))
        printf 'AUDIO_CAPTURE header_offset=%s declared=%s format=%s rate=%s channels=%s bits=%s byte_rate=%s goal_bytes=%s\n' \
          "$arwp_offset" "$arwp_declared" "$arwp_format" "$arwp_rate" \
          "$arwp_channels" "$arwp_bits" "$arwp_byte_rate" "$arwp_goal" >&2
      fi
    fi
    if [ -n "$arwp_meta" ]; then
      arwp_size="$(file_size_bytes "$arwp_file" 2>/dev/null || echo 0)"
      # Header inspection and file reads take time too. Do not credit samples
      # against a stale timestamp or extend the startup deadline on a busy DUT.
      arwp_now="$(get_monotonic_seconds)"
      if [ "$arwp_now" -gt "$arwp_deadline" ]; then
        arwp_reason=capture-deadline
        break
      fi
      if [ "$arwp_first" -eq 0 ] &&
         [ "$((arwp_now - arwp_start))" -gt "$arwp_window" ]; then
        arwp_reason=startup-no-payload
        break
      fi
      arwp_payload=$((arwp_size - arwp_offset))
      if [ "$arwp_payload" -lt 0 ]; then
        arwp_payload=0
      fi
      arwp_payload=$((arwp_payload - arwp_payload % arwp_align))
      if [ "$arwp_payload" -gt "$arwp_previous" ]; then
        if [ "$arwp_first" -eq 0 ]; then
          arwp_first=1
          printf 'AUDIO_CAPTURE first_payload_after=%ss\n' "$((arwp_now - arwp_start))" >&2
          if [ "$arwp_limit" -eq 0 ]; then
            arwp_deadline=$((arwp_now + arwp_window))
          fi
          if [ "$arwp_links" -eq 1 ]; then
            printf 'AUDIO_LINKS recorder_pid=%s phase=first-payload\n' "$arwp_pid" >"${arwp_file}.links"
            if command -v pw-link >/dev/null 2>&1; then
              pw-link -l -I >>"${arwp_file}.links" 2>&1 &
              arwp_links_pid=$!
              arwp_links_start="$arwp_now"
            else
              printf '%s\n' 'AUDIO_LINKS status=unavailable reason=pw-link-missing' >>"${arwp_file}.links"
            fi
          fi
        fi
        arwp_last="$arwp_now"
        printf 'AUDIO_CAPTURE elapsed=%ss payload_bytes=%s goal_bytes=%s\n' \
          "$((arwp_now - arwp_start))" "$arwp_payload" "$arwp_goal" >&2
      fi
      arwp_previous="$arwp_payload"
      if [ "$arwp_payload" -ge "$arwp_goal" ] &&
         { [ -z "$arwp_completion" ] || [ -f "$arwp_completion" ]; }; then
        arwp_reason=requested-duration-collected
        break
      fi
    fi
    if [ "$arwp_now" -ge "$arwp_deadline" ]; then
      arwp_reason=capture-deadline
      break
    fi
    if [ "$arwp_first" -eq 0 ] &&
       [ "$((arwp_now - arwp_start))" -ge "$arwp_window" ]; then
      arwp_reason=startup-no-payload
      break
    fi
    if [ "$arwp_first" -eq 1 ] &&
       [ "$((arwp_now - arwp_last))" -ge "$arwp_idle_limit" ]; then
      arwp_reason=payload-stalled
      break
    fi
    sleep 1
  done

  if [ -n "$arwp_links_pid" ]; then
    audio_record_finish_link_snapshot "$arwp_links_pid" "${arwp_file}.links"
    arwp_links_pid=""
  fi
  if [ "$arwp_reason" = "recorder-exited" ]; then
    arwp_rc=0
    wait "$arwp_pid" || arwp_rc=$?
    printf 'AUDIO_CAPTURE recorder_rc=%s\n' "$arwp_rc" >&2
  else
    arwp_stop_rc=0
    audio_record_stop_child "$arwp_pid" || arwp_stop_rc=$?
    case "$arwp_stop_rc" in
      0)
        ;;
      1)
        arwp_reason=recorder-required-sigkill
        ;;
      *)
        arwp_reason=recorder-exited-before-stop
        ;;
    esac
  fi
  arwp_pid=""
  arwp_status=FAIL
  if [ "$arwp_reason" = "requested-duration-collected" ]; then
    arwp_status=COMPLETE
  fi
  printf 'AUDIO_CAPTURE status=%s reason=%s elapsed=%ss payload_bytes=%s\n' \
    "$arwp_status" "$arwp_reason" \
    "$(($(get_monotonic_seconds) - arwp_start))" "$arwp_payload" >&2
  trap - HUP INT TERM
  # This is the shell's own trap snapshot, never command or DUT-provided text.
  eval "$arwp_saved_traps"
  [ "$arwp_status" = "COMPLETE" ]
}

# Finish only the owned, read-only pw-link child. Arguments: PID, output path.
# Reap completed children, kill a still-running snapshot without a grace wait.
# Append completion/truncation status to the artifact, return 0 regardless of
# diagnostic failure. No stdout and no effect on the recording verdict.
audio_record_finish_link_snapshot() {
  arfls_pid="$1"
  arfls_out="$2"
  arfls_status=complete
  if kill -0 "$arfls_pid" 2>/dev/null; then
    kill -KILL "$arfls_pid" 2>/dev/null || true
    arfls_status=truncated
  fi
  arfls_rc=0
  wait "$arfls_pid" 2>/dev/null || arfls_rc=$?
  if [ "$arfls_status" = "complete" ] && [ "$arfls_rc" -ne 0 ]; then
    arfls_status=failed
  fi
  printf 'AUDIO_LINKS status=%s rc=%s\n' "$arfls_status" "$arfls_rc" >>"$arfls_out" 2>/dev/null || true
  return 0
}

# audio_server_journal <system|user> <since> [unit] [pid]
# Print at most 120 current-boot entries within the requested time window.
# Root reads desktop logs by exact UID and user unit from the system journal,
# avoiding unavailable per-user journal files. Other callers retain their scope.
# Optional unit/PID narrow startup evidence to the current service process.
# Return 0 on query success, nonzero on unavailable/failed evidence. Read-only.
audio_server_journal() (
  asj_scope="$1"
  asj_since="$2"
  asj_units="${3:-pipewire.service wireplumber.service pipewire-pulse.service}"
  asj_pid="${4:-}"
  asj_root_user=0
  case "$asj_scope" in
    user)
      case "${AUDIO_TEST_UID:-}" in
        ''|0|*[!0-9]*)
          ;;
        *)
          if [ "$(id -u)" -eq 0 ]; then
            asj_root_user=1
          fi
          ;;
      esac
      ;;
    system)
      ;;
    *)
      printf '%s\n' 'Journal unavailable, invalid service scope'
      return 2
      ;;
  esac
  case "$asj_pid" in
    *[!0-9]*)
      printf '%s\n' 'Journal unavailable, invalid service PID'
      return 2
      ;;
  esac
  set -- -b --no-pager -n 120 --since "$asj_since"
  if [ "$asj_root_user" -eq 1 ]; then
    asj_separator=""
    for asj_unit in $asj_units; do
      case "$asj_unit" in
        pipewire.service|wireplumber.service|pipewire-pulse.service)
          ;;
        *)
          printf '%s\n' 'Journal unavailable, invalid audio service'
          return 2
          ;;
      esac
      if [ -n "$asj_separator" ]; then
        set -- "$@" +
      fi
      set -- "$@" "_UID=$AUDIO_TEST_UID" "_SYSTEMD_USER_UNIT=$asj_unit"
      if [ -n "$asj_pid" ]; then
        set -- "$@" "_PID=$asj_pid"
      fi
      asj_separator=1
    done
    printf 'Journal source: system journal, desktop UID=%s\n' "$AUDIO_TEST_UID"
    if ! command -v journalctl >/dev/null 2>&1; then
      printf '%s\n' 'Journal unavailable, journalctl is not installed'
      return 2
    fi
    audio_exec_with_timeout 3s journalctl "$@"
  else
    [ "$asj_scope" != user ] || set -- "$@" --user
    for asj_unit in $asj_units; do
      case "$asj_unit" in
        pipewire.service|wireplumber.service|pipewire-pulse.service)
          set -- "$@" -u "$asj_unit"
          ;;
        *)
          printf '%s\n' 'Journal unavailable, invalid audio service'
          return 2
          ;;
      esac
    done
    [ -z "$asj_pid" ] || set -- "$@" "_PID=$asj_pid"
    audio_run_with_timeout_as_test_user 3s sh -c '
      if command -v journalctl >/dev/null 2>&1; then
        exec journalctl "$@"
      fi
      printf "%s\n" "Journal unavailable, journalctl is not installed"
      exit 2
    ' sh "$@"
  fi
)

# audio_server_startup_diagnostics <system|user>
# Print bounded startup evidence for each current audio service process. Read
# PID/start time from its manager, including ExecMainPID after a failed start.
# This separate readiness-only history must never become stream-window evidence.
# No state changes. Missing tools or identity are reported, not clean results.
audio_server_startup_diagnostics() (
  assd_scope="$1"
  for assd_unit in pipewire.service wireplumber.service pipewire-pulse.service; do
    set --
    [ "$assd_scope" != user ] || set -- --user
    if ! assd_identity="$(audio_run_with_timeout_as_test_user 3s sh -c '
      command -v systemctl >/dev/null 2>&1 || exit 127
      exec systemctl "$@"
    ' sh "$@" show --no-pager --property=MainPID,ExecMainPID,ExecMainStartTimestamp "$assd_unit" 2>&1)"; then
      printf 'Journal unavailable, startup identity query failed for %s: %s\n' "$assd_unit" "$assd_identity"
      continue
    fi
    assd_pid="$(printf '%s\n' "$assd_identity" | awk -F= '
      $1=="MainPID" { main=$2 }
      $1=="ExecMainPID" { previous=$2 }
      END { if (main ~ /^[1-9][0-9]*$/) print main; else print previous }
    ')"
    assd_since="$(printf '%s\n' "$assd_identity" | sed -n 's/^ExecMainStartTimestamp=//p')"
    case "$assd_pid:$assd_since" in
      :*|0:*|*:|*:n/a)
        printf 'Journal unavailable, no current startup identity for %s\n' "$assd_unit"
        continue
        ;;
    esac
    printf 'Startup identity: unit=%s pid=%s since=%s\n' "$assd_unit" "$assd_pid" "$assd_since"
    audio_server_journal "$assd_scope" "$assd_since" "$assd_unit" "$assd_pid" ||
      printf 'Journal unavailable, startup query failed for %s, rc=%s\n' "$assd_unit" "$?"
  done
)

# audio_check_overlay_initialization_errors <server-artifact> <error-artifact>
# Extract up to 20 distinct ACDB/AGM initialization failures from marked startup
# or operation journals. Preserve runtime paths, never infer board mappings or
# file absence from an open error. No stdout. Return 1 for observed errors,
# 0 for no recognized errors, 2 for missing/incomplete evidence or parser failure.
audio_check_overlay_initialization_errors() {
  [ -r "$1" ] || return 2
  if awk '
    /^---- current-service startup journal ----$/ { journal=1; found=1; next }
    /^---- end current-service startup journal ----$/ { journal=0; next }
    /^---- capture-window journal, last [0-9]+ entries ----$/ { journal=1; found=1; next }
    journal {
      line=tolower($0)
      if (line ~ /journal unavailable|no journal files were found|permission denied|not seeing messages from other users/) incomplete=1
      acdb=(line ~ /get_acdb_files_from_directory:/ && line ~ /cannot open acdb path/)
      graph=(line ~ /session_obj_init:/ && line ~ /error:[ ]*-?[1-9][0-9]* initializing graph/)
      agm=(line ~ /agm_init:/ && line ~ /session_obj_init failed with -?[1-9][0-9]*/)
      if (acdb || graph || agm) {
        message=$0
        sub(/^.*get_acdb_files_from_directory: *[0-9]+ */, "", message)
        sub(/^.*session_obj_init: *[0-9]+ */, "", message)
        sub(/^.*agm_init: *[0-9]+ */, "", message)
        if (!seen[message]++ && count++<20) print message
        errors=1
      }
    }
    END { if (errors) exit 3; if (!found || incomplete) exit 2 }
  ' "$1" >"$2"; then
    return 0
  else
    acoie_rc=$?
    [ "$acoie_rc" -ne 3 ] || return 1
    return 2
  fi
}

# audio_record_server_diagnostics <artifact> [journal-since] [readiness]
# Append bounded PipeWire identity and service evidence, plus at most 120 recent
# journal entries since capture began. Use the same user/system scope as capture.
# Unlike systemd_service_stdout_since, retain stderr/crash messages and bound
# journal size and execution time. Readiness adds current-process startup history
# before the stream-window marker. No stdout data, state changes or verdicts.
audio_record_server_diagnostics() (
  arsd_out="$1"
  arsd_since="${2:-}"
  arsd_history="${3:-}"
  {
    printf '\n---- server snapshot %s ----\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf '%s\n' '---- PipeWire core identity ----'
    audio_run_with_timeout_as_test_user --require-session 3s sh -c '
      if command -v pw-cli >/dev/null 2>&1; then
        exec pw-cli info 0
      fi
      printf "%s\n" "PipeWire identity unavailable, optional pw-cli is not installed"
    ' ||
      printf 'PipeWire identity unavailable, rc=%s\n' "$?"
    set --
    arsd_scope=system
    if [ "${AUDIO_PLAYBACK_DESKTOP_ROOT_MODE:-0}" -eq 1 ] ||
       [ "${AUDIO_RECORD_DESKTOP_ROOT_MODE:-0}" -eq 1 ] ||
       [ "${AUDIO_USE_DESKTOP_SESSION:-0}" -eq 1 ] ||
       [ "${AUDIO_SYSTEMCTL_USER_SCOPE:-0}" -eq 1 ]; then
      set -- --user
      arsd_scope=user
    fi
    printf '%s\n' "---- service scope: ${1:-system} ----"
    audio_run_with_timeout_as_test_user 3s sh -c '
      if command -v systemctl >/dev/null 2>&1; then
        exec systemctl "$@"
      fi
      printf "%s\n" "Service identity unavailable, systemctl is not installed"
    ' sh "$@" show --no-pager \
      --property=Id,ActiveState,SubState,Result,MainPID,InvocationID,NRestarts,ExecMainStartTimestamp,ExecMainCode,ExecMainStatus \
      pipewire.service wireplumber.service pipewire-pulse.service ||
      printf 'Service identity unavailable, rc=%s\n' "$?"
    if [ "$arsd_history" = readiness ]; then
      printf '%s\n' '---- current-service startup journal ----'
      audio_server_startup_diagnostics "$arsd_scope"
      printf '%s\n' '---- end current-service startup journal ----'
    fi
    if [ -n "$arsd_since" ]; then
      printf '%s\n' '---- capture-window journal, last 120 entries ----'
      audio_server_journal "$arsd_scope" "$arsd_since" ||
        printf 'Journal unavailable, rc=%s\n' "$?"
    fi
  } >>"$arsd_out" 2>&1
)

# audio_check_stream_server_errors <server-after-artifact> <error-artifact>
# Inspect only the operation-window journal captured by the existing bounded
# server diagnostic helper. Retain explicit stream-start/graph failures without
# attributing shared-server errors to one direction during duplex operation.
# Return 1 for observed failures, 0 for no recognized failures, 2 for missing or
# incomplete journal evidence. No stdout, service actions or clean-driver claim.
audio_check_stream_server_errors() {
  [ -r "$1" ] || return 2
  if awk '
    /^---- capture-window journal, last [0-9]+ entries ----$/ {
      journal=1
      next
    }
    journal {
      line=tolower($0)
      if (line ~ /journal unavailable/ || line ~ /no journal files were found/ ||
          line ~ /permission denied/ || line ~ /not seeing messages from other users/) {
        incomplete=1
      }
      nonzero=(line ~ /(error|status|ret)[ :=]+-?[1-9][0-9]*/)
      start_failure=(line ~ /pal_stream_start/ && line ~ /fail/ && nonzero)
      session_failure=(line ~ /(rx|tx) session start/ && line ~ /fail/ && nonzero)
      graph_failure=(line ~ /graph_open/ && line ~ /fail/ && nonzero)
      graph_timeout=(line ~ /graph (open|close|open\/close) timeout[. ,]/)
      if (start_failure || session_failure || graph_failure || graph_timeout) {
        print
        failures++
      }
    }
    END {
      if (failures) exit 3
      if (!journal || incomplete) exit 2
    }
  ' "$1" >"$2"; then
    return 0
  else
    acsse_rc=$?
    [ "$acsse_rc" -ne 3 ] || return 1
    return 2
  fi
}

# Preserve bounded failure context beside the recorder log and replay to stdout.
# Arguments: recorder log, backend, selected source, optional WAV path.
# Existing callers default to record_out. No backend state changes.
# Return 0, diagnostic command failures are retained but do not change verdicts.
audio_record_failure_diagnostics() {
  arfd_log="$1"
  arfd_backend="$2"
  arfd_source="$3"
  arfd_wav="${4:-${record_out:-}}"
  arfd_out="${arfd_log}.diagnostics"
  {
    printf 'backend=%s target=%s\n' "$arfd_backend" "$arfd_source"
    printf '%s\n' '---- recorder log (first 40 and last 120 lines) ----'
    head -n 40 "$arfd_log" 2>/dev/null || true
    tail -n 120 "$arfd_log" 2>/dev/null || true
    if [ "$arfd_backend" = "pipewire" ]; then
      printf '%s\n' '---- wpctl status ----'
      audio_run_with_timeout_as_test_user --require-session 3s wpctl status || true
      if [ -n "$arfd_source" ]; then
        printf '%s\n' '---- selected source ----'
        audio_run_with_timeout_as_test_user --require-session 3s wpctl inspect "$arfd_source" || true
      fi
    fi
  } >"$arfd_out" 2>&1
  log_file_with_label AUDIO-RECORD-FAILURE "$arfd_out" 240
  if [ "$arfd_backend" = "pipewire" ]; then
    log_file_with_label AUDIO-RECORD-SERVER-BEFORE "$arfd_log.server-before" 180
    log_file_with_label AUDIO-RECORD-SERVER-AFTER "$arfd_log.server-after" 240
  fi
  if [ "$arfd_backend" = "pipewire" ] && [ -f "${arfd_wav}.links" ]; then
    log_file_with_label AUDIO-RECORD-LIVE-LINKS "${arfd_wav}.links" 160
  fi
  return 0
}

# AudioRecord root-orchestrator helpers
#
# Insert this block into Runner/utils/audio_common.sh after
# audio_run_with_timeout_as_test_user().
#
# These helpers are intentionally shared because they implement backend recovery,
# desktop-user capture workspace handling, mixer collection, and ALSA profile
# propagation. They do not parse AudioRecord CLI options or emit final results.

audio_record_restart_backend_best_effort() {
  arbbe_backend="$1"

  if [ "${AUDIO_RECORD_DESKTOP_ROOT_MODE:-0}" -ne 1 ]; then
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

# On desktop user-mode systems, manual daemon bootstrap is replaced by one user-service recovery
# attempt. Native and minimal Yocto images retain their existing bootstrap path.
audio_record_bootstrap_backend_if_needed() {
  if [ "${AUDIO_RECORD_DESKTOP_ROOT_MODE:-0}" -ne 1 ]; then
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

# Record whether a recovered backend is managed by the desktop user manager or
# by the native/minimal-image bootstrap path.
audio_record_set_recovered_backend_management() {
  if [ "${AUDIO_RECORD_DESKTOP_ROOT_MODE:-0}" -eq 1 ]; then
    AUDIO_SYSTEMD_MANAGED=1
  else
    AUDIO_SYSTEMD_MANAGED=0
  fi

  export AUDIO_SYSTEMD_MANAGED
}

# Resolve the root-owned final WAV and the desktop-user scratch WAV for one case.
audio_record_set_capture_paths() {
  arcsp_case_name="$1"

  record_out="$LOGDIR/${arcsp_case_name}.wav"

  if [ "${AUDIO_RECORD_DESKTOP_ROOT_MODE:-0}" -eq 1 ]; then
    record_user_out="$AUDIO_RECORD_USER_CAPTURE_DIR/${arcsp_case_name}.wav"
  else
    record_user_out="$record_out"
  fi
}

# Remove the previous scratch WAV without pre-creating a root-owned file.
audio_record_reset_capture_output() {
  rm -f "$record_user_out"
  if [ "${AUDIO_BACKEND:-}" = "pipewire" ]; then
    rm -f "${record_user_out}.links"
  fi
}

# Return the current scratch WAV size.
audio_record_capture_size() {
  file_size_bytes "$record_user_out" 2>/dev/null || echo 0
}

# Move the desktop-user scratch WAV into the root-owned final results directory.
# When no scratch file was produced, create an empty final file so the existing
# WAV validator can report the backend failure consistently.
audio_record_promote_capture_output() {
  if [ "$record_user_out" = "$record_out" ]; then
    return 0
  fi

  if [ "${AUDIO_BACKEND:-}" = "pipewire" ]; then
    rm -f "${record_out}.links"
    if [ -f "${record_user_out}.links" ]; then
      if ! mv "${record_user_out}.links" "${record_out}.links" ||
         ! chown 0:0 "${record_out}.links" ||
         ! chmod 0644 "${record_out}.links"; then
        log_warn "Failed to preserve live PipeWire links: ${record_out}.links"
      fi
    fi
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

  if [ "${AUDIO_RECORD_DESKTOP_ROOT_MODE:-0}" -ne 1 ]; then
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
  arpacpo_requested_device="${1:-}"
  arpacpo_log=/dev/stderr
  if [ -n "${LOGDIR:-}" ]; then
    arpacpo_log="$LOGDIR/alsa_capture_probe.log"
  fi
  arpacpo_start="$(get_monotonic_seconds)"
  arpacpo_first="$(audio_probe_log_begin "$arpacpo_log" ALSA-CAPTURE-PROBE)" || return 1

  if [ "${AUDIO_RECORD_DESKTOP_ROOT_MODE:-0}" -ne 1 ]; then
    if audio_probe_alsa_capture_profile "$arpacpo_requested_device" 2>>"$arpacpo_log"; then
      arpacpo_rc=0
    else
      arpacpo_rc=$?
    fi
    audio_probe_log_finish "$arpacpo_log" ALSA-CAPTURE-PROBE \
      "$arpacpo_first" "$arpacpo_rc" "$arpacpo_start"
    return "$arpacpo_rc"
  fi

  arpacp_output="$(
    # Variables in this command script are intentionally expanded by the child shell.
    # shellcheck disable=SC2016
    audio_run_as_test_user \
      sh -c '
        . "$TOOLS/functestlib.sh"
        . "$TOOLS/audio_common.sh"

        audio_probe_alsa_capture_profile "$1" >/dev/null
        probe_rc=$?

        printf "%s\n" \
          "${AUDIO_ALSA_CAPTURE_DEVICE:-}" \
          "${AUDIO_ALSA_CAPTURE_FORMAT:-}" \
          "${AUDIO_ALSA_CAPTURE_RATE:-}" \
          "${AUDIO_ALSA_CAPTURE_CHANNELS:-}" \
          "${AUDIO_ALSA_CAPTURE_REASON:-}"

        exit "$probe_rc"
      ' \
      sh \
      "$arpacpo_requested_device" 2>>"$arpacpo_log"
  )"
  arpacp_rc=$?
  audio_probe_log_finish "$arpacpo_log" ALSA-CAPTURE-PROBE \
    "$arpacpo_first" "$arpacp_rc" "$arpacpo_start"

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
  arpacp_requested_device="${1:-}"

  if audio_record_probe_alsa_capture_profile_once "$arpacp_requested_device"; then
    return 0
  else
    arpacp_probe_rc=$?
    [ "$arpacp_probe_rc" -eq 1 ] || return 3
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

  if audio_record_probe_alsa_capture_profile_once "$arpacp_requested_device"; then
    return 0
  else
    arpacp_probe_rc=$?
    [ "$arpacp_probe_rc" -eq 1 ] || return 3
  fi

  if [ "${AUDIO_ALSA_CAPTURE_REASON:-}" = \
       "no ALSA capture device candidates found" ]; then
    AUDIO_ALSA_CAPTURE_REASON="$AUDIO_ALSA_CAPTURE_REASON after audio DSP startup"
    export AUDIO_ALSA_CAPTURE_REASON
  fi

  return 1
}

# Probe the requested ALSA capture route, or discover mic then headset-mic.
audio_record_probe_selected_alsa_capture_profile() {
  arpsacp_requested_device="${1:-}"
  arpsacp_requested_route="${SRC_CHOICE:-auto}"
  arpsacp_reasons=""

  case "$arpsacp_requested_device" in
    *[[:space:]]*)
      AUDIO_ALSA_CAPTURE_REASON="explicit capture device contains whitespace: $arpsacp_requested_device"
      export AUDIO_ALSA_CAPTURE_REASON
      return 1
      ;;
  esac

  case "$arpsacp_requested_route" in
    auto)
      arpsacp_routes="mic headset-mic"
      ;;
    mic|headset-mic)
      arpsacp_routes="$arpsacp_requested_route"
      ;;
    *)
      AUDIO_ALSA_CAPTURE_REASON="unsupported ALSA capture route: $arpsacp_requested_route"
      export AUDIO_ALSA_CAPTURE_REASON
      return 1
      ;;
  esac

  for arpsacp_route in $arpsacp_routes; do
    SRC_CHOICE="$arpsacp_route"
    export SRC_CHOICE
    printf '%s\n' \
      "[AUDIO-ROUTE] probing ALSA capture route=$arpsacp_route device=${arpsacp_requested_device:-auto}" >&2

    if audio_record_probe_alsa_capture_profile \
        "$arpsacp_requested_device"; then
      AUDIO_CAPTURE_PROBE_FAILED=0
      AUDIO_CAPTURE_ROUTE_SELECTED="$arpsacp_route"
      export AUDIO_CAPTURE_ROUTE_SELECTED
      return 0
    else
      arpsacp_rc=$?
      if [ "$arpsacp_rc" -ne 1 ]; then
        AUDIO_CAPTURE_PROBE_FAILED=1
      fi
    fi

    if [ -n "$arpsacp_reasons" ]; then
      arpsacp_reasons="$arpsacp_reasons, $arpsacp_route: ${AUDIO_ALSA_CAPTURE_REASON:-unavailable}"
    else
      arpsacp_reasons="$arpsacp_route: ${AUDIO_ALSA_CAPTURE_REASON:-unavailable}"
    fi
  done

  SRC_CHOICE="$arpsacp_requested_route"
  AUDIO_ALSA_CAPTURE_REASON="$arpsacp_reasons"
  export SRC_CHOICE AUDIO_ALSA_CAPTURE_REASON
  return 1
}

# Prepare the Debian or CentOS Audio test user and re-execute the current test
# as that user.
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
# Debian and CentOS:
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
# Desktop Audio test user. Debian defaults to `debian`; CentOS discovers the
# active regular user dynamically.
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
# 0 - not applicable or already executing as the prepared desktop Audio user
# 1 - user, output-path, or user-manager preparation failed
#
# A successful root-to-user transition uses exec and therefore does not return.
audio_prepare_desktop_audio_test_user() {
  if [ "$#" -lt 4 ]; then
    log_fail "audio_prepare_desktop_audio_test_user requires runner, result file, log directory, and user-manager mode"
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
    debian|centos)
      ;;
    qcom-distro|poky|openembedded|oe)
      # Preserve all native-image execution behavior.
      return 0
      ;;
    *)
      # Preserve existing execution on Ubuntu and native/minimal images.
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

  case "$apdatu_os_id" in
    debian)
      apdatu_default_user="debian"
      ;;
    centos)
      apdatu_default_user="$(audio_find_regular_session_user 2>/dev/null || true)"
      ;;
  esac

  apdatu_user="${AUDIO_TEST_USER:-$apdatu_default_user}"
  apdatu_current_uid="$(id -u 2>/dev/null || echo 1)"
  apdatu_current_user="$(id -un 2>/dev/null || echo unknown)"

  ###########################################################################
  # Re-executed desktop Audio child
  ###########################################################################

  if [ "${AUDIO_TEST_USER_REEXEC:-0}" -eq 1 ]; then
    if [ "$apdatu_current_user" != "$apdatu_user" ]; then
      log_fail "Audio user re-exec mismatch: expected=$apdatu_user actual=$apdatu_current_user"
      return 1
    fi

    if ! id -nG "$apdatu_user" 2>/dev/null |
        tr ' ' '\n' |
        grep -qx audio; then
      log_fail "Desktop Audio test user is not a member of audio: $apdatu_user"
      return 1
    fi

    apdatu_uid="$(id -u "$apdatu_user" 2>/dev/null || true)"

    if [ -z "$apdatu_uid" ]; then
      log_fail "Unable to resolve uid for desktop Audio test user: $apdatu_user"
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
        log_fail "Desktop user runtime directory is missing: $XDG_RUNTIME_DIR"
        return 1
      fi

      if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
        log_fail "Desktop user D-Bus is unavailable: $XDG_RUNTIME_DIR/bus"
        return 1
      fi
    fi

    log_pass "Audio test is running as desktop user: os=$apdatu_os_id user=$apdatu_user uid=$apdatu_uid"
    return 0
  fi

  ###########################################################################
  # Initial desktop-distribution process must be root
  ###########################################################################

  if [ "$apdatu_current_uid" -ne 0 ]; then
    log_fail "Desktop Audio tests must initially run as root, os=$apdatu_os_id"
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
    log_fail "Desktop Audio test user does not exist: $apdatu_user"
    return 1
  fi

  if ! audio_user_is_regular "$apdatu_user"; then
    log_fail "Desktop Audio test user is not a regular login account: $apdatu_user"
    return 1
  fi

  if command -v getent >/dev/null 2>&1; then
    if ! getent group audio >/dev/null 2>&1; then
      log_fail "Required desktop Audio group does not exist: audio"
      return 1
    fi
  elif ! grep -q '^audio:' /etc/group 2>/dev/null; then
    log_fail "Required desktop Audio group does not exist: audio"
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

    log_info "Adding desktop Audio test user to audio group: $apdatu_user"

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
    log_fail "Unable to resolve uid for desktop Audio test user: $apdatu_user"
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
        log_info "Restarting desktop user manager after audio-group update: $apdatu_user_unit"

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
          log_fail "Failed to restart desktop user manager: $apdatu_user_unit"
          return 1
        fi
      else
        log_pass "Desktop user manager is already active: $apdatu_user_unit"
      fi
    else
      log_info "Starting desktop user manager: $apdatu_user_unit"

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
        log_fail "Failed to start desktop user manager: $apdatu_user_unit"

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

    log_info "Waiting for desktop user runtime and D-Bus, timeout=${apdatu_wait_timeout}s"

    while [ "$apdatu_wait" -lt "$apdatu_wait_timeout" ]; do
      if [ -d "$apdatu_runtime_dir" ] &&
         [ -S "$apdatu_bus_path" ]; then
        break
      fi

      sleep 1
      apdatu_wait=$((apdatu_wait + 1))
    done

    if [ ! -d "$apdatu_runtime_dir" ]; then
      log_fail "Desktop user runtime directory is unavailable: $apdatu_runtime_dir"
      return 1
    fi

    if [ ! -S "$apdatu_bus_path" ]; then
      log_fail "Desktop user D-Bus is unavailable: $apdatu_bus_path"
      return 1
    fi

    log_pass "Desktop user runtime is ready: $apdatu_runtime_dir"
  else
    apdatu_runtime_dir="/run/user/$apdatu_uid"
    apdatu_bus_path="$apdatu_runtime_dir/bus"
  fi

  ###########################################################################
  # Re-execute the test as the desktop Audio user
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
  TEST_RESULT_FILE_PREPARED=1

  # Keep the stdout/stderr capture opened by the privileged launcher. The
  # unprivileged child inherits those descriptors and must not create another
  # suite-directory log. Unlinking the FIFO is safe while both ends remain
  # open and prevents leaving a stale CWD entry after exec replaces this shell.
  apdatu_stdout_active="${__RUN_STDOUT_ACTIVE:-}"
  if [ -n "$apdatu_stdout_active" ] && [ -n "${PIPE:-}" ]; then
    rm -f "$PIPE" 2>/dev/null || true
    if [ -n "${RUN_STDOUT_PIPE_DIR:-}" ]; then
      rmdir "$RUN_STDOUT_PIPE_DIR" 2>/dev/null || true
    fi
  fi

  export AUDIO_TEST_USER
  export AUDIO_TEST_UID
  export AUDIO_TEST_USER_REEXEC
  export AUDIO_PACKAGE_PREPARED
  export AUDIO_SYSTEMCTL_USER_SCOPE
  export AUDIO_TEST_USER_MANAGER_REQUIRED
  export TEST_RESULT_FILE_PREPARED
  
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
      TMPDIR="$apdatu_log_dir" \
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
      TEST_RESULT_FILE_PREPARED=1 \
      __RUN_STDOUT_ACTIVE="$apdatu_stdout_active" \
      LOGDIR="$apdatu_log_dir" \
      "$apdatu_script" \
      "$@"
}

# Compatibility wrapper for callers using the original Debian-specific name.
audio_prepare_debian_audio_test_user() {
  audio_prepare_desktop_audio_test_user "$@"
}

# Read bounded WAV header metadata, including headers not finalized yet.
# Output: offset|declared-bytes|format|channels|rate|byte-rate|block-align|bits.
# This inventories the header only, final WAV/content validation is separate.
audio_wav_header_metadata() {
  command -v od >/dev/null 2>&1 || return 1
  command -v dd >/dev/null 2>&1 || return 1
  [ -s "$1" ] || return 1

  {
    dd if="$1" bs=4096 count=256 2>/dev/null |
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
  ' 2>/dev/null
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
  avrwo_expected_bits="${6:-0}"
  avrwo_scope="${7:-record}"
  avrwo_analyze_bytes="${AUDIO_RECORD_ANALYZE_BYTES:-4194304}"
  avrwo_min_active="${AUDIO_RECORD_MIN_ACTIVE_SAMPLES:-100}"
  avrwo_min_distinct="${AUDIO_RECORD_MIN_DISTINCT_SAMPLES:-4}"
  avrwo_threshold_lsb="${AUDIO_RECORD_SAMPLE_THRESHOLD_LSB:-${AUDIO_RECORD_SAMPLE_THRESHOLD:-8}}"
  avrwo_strict_signal="${AUDIO_RECORD_STRICT_SIGNAL:-0}"
  avrwo_min_rms_dbfs="${AUDIO_RECORD_MIN_RMS_DBFS:--60}"

  avrwo_meta="$(audio_wav_header_metadata "$avrwo_file")" || return 1

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

  if [ "$avrwo_rate" -gt 0 ] 2>/dev/null &&
     [ "$avrwo_actual_rate" != "$avrwo_rate" ]; then
    return 1
  fi
  if [ "$avrwo_channels" -gt 0 ] 2>/dev/null &&
     [ "$avrwo_actual_channels" != "$avrwo_channels" ]; then
    return 1
  fi
  if [ "$avrwo_expected_bits" -gt 0 ] 2>/dev/null &&
     [ "$avrwo_bits" != "$avrwo_expected_bits" ]; then
    return 1
  fi
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
    avrwo_fields="status=PASS reason=valid-null-source-recording validator=od payload_bytes=$avrwo_usable"
    AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION $avrwo_fields"
    AUDIO_VALIDATION_SUMMARY="AUDIO_VALIDATION scope=$avrwo_scope policy=basic-integrity $avrwo_fields"
    export AUDIO_WAV_VALIDATION_SUMMARY AUDIO_VALIDATION_SUMMARY
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
      -v threshold_lsb="$avrwo_threshold_lsb" \
      -v strict_signal="$avrwo_strict_signal" \
      -v min_rms_dbfs="$avrwo_min_rms_dbfs" \
      -v channels="$avrwo_actual_channels" \
      -v rate="$avrwo_actual_rate" '
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
      if (bits == 8) {
        raw -= 128
      } else if (raw >= sign_limit) {
        raw -= full_range
      }

      samples++
      if (raw != 0) nonzero_samples++

      normalized = raw / sign_limit
      sum_values += normalized
      sum_squares += normalized * normalized
      if (abs_value(normalized) >= 0.999) clipped_samples++

      threshold = (threshold_lsb / 32768.0) * sign_limit
      if (threshold < 0) threshold = 0
      channel = ((samples - 1) % channels) + 1
      if (abs_value(raw) > threshold) {
        active_samples++
        channel_active[channel]++
        if (silence_samples >= minimum_silence_samples) silence_runs++
        if (silence_samples > longest_silence_samples) longest_silence_samples = silence_samples
        silence_samples = 0
      } else {
        silence_samples++
      }

      if (channel in previous && abs_value(normalized - previous[channel]) >= 0.8) {
        glitch_candidates++
      }
      previous[channel] = normalized

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
      minimum_silence_samples = int(rate * channels * 0.05)
      if (minimum_silence_samples < 1) minimum_silence_samples = 1
    }
    {
      for (i = 1; i <= NF; i++) {
        if ($i != 0) payload_nonzero_bytes++
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
      rms = samples > 0 ? sqrt(sum_squares / samples) : 0
      rms_dbfs = rms > 0 ? 20 * log(rms) / log(10) : -999
      dc_offset = samples > 0 ? sum_values / samples : 0
      if (silence_samples >= minimum_silence_samples) silence_runs++
      if (silence_samples > longest_silence_samples) longest_silence_samples = silence_samples
      silent_channels = 0
      for (channel = 1; channel <= channels; channel++) {
        if (channel_active[channel] == 0) silent_channels++
      }
      longest_silence_ms = rate > 0 && channels > 0 ? (1000 * longest_silence_samples / (rate * channels)) : 0
      printf "%d|%d|%d|%d|%d|%.2f|%.8f|%d|%d|%.2f|%d|%d\n", samples, payload_nonzero_bytes, nonzero_samples, active_samples, distinct_samples, rms_dbfs, dc_offset, clipped_samples, silence_runs, longest_silence_ms, glitch_candidates, silent_channels
      if (samples <= 0 || payload_nonzero_bytes <= 0 || nonzero_samples <= 0) {
        exit 1
      }
      if (strict_signal == 1 && rms_dbfs < min_rms_dbfs) exit 1
    }
  ')"
  avrwo_stats_rc=$?

  IFS='|' read -r \
    avrwo_samples \
    avrwo_nonzero_storage_bytes \
    avrwo_nonzero_samples \
    avrwo_active_samples \
    avrwo_distinct_samples \
    avrwo_rms_dbfs \
    avrwo_dc_offset \
    avrwo_clipped_samples \
    avrwo_silence_runs \
    avrwo_longest_silence_ms \
    avrwo_glitch_candidates \
    avrwo_silent_channels <<EOF
$avrwo_stats
EOF

  if [ "$avrwo_stats_rc" -ne 0 ]; then
    avrwo_fields="status=FAIL reason=pcm-signal-validation-failed validator=od analyzed_samples=${avrwo_samples:-0} nonzero_storage_bytes=${avrwo_nonzero_storage_bytes:-0} nonzero_samples=${avrwo_nonzero_samples:-0} active_samples=${avrwo_active_samples:-0} distinct_samples=${avrwo_distinct_samples:-0} rms_dbfs=${avrwo_rms_dbfs:--999} dc_offset=${avrwo_dc_offset:-0} clipped_samples=${avrwo_clipped_samples:-0} silence_runs=${avrwo_silence_runs:-0} longest_silence_ms=${avrwo_longest_silence_ms:-0} glitch_candidates=${avrwo_glitch_candidates:-0} silent_channels=${avrwo_silent_channels:-0} strict_signal=$avrwo_strict_signal min_rms_dbfs=$avrwo_min_rms_dbfs"
    AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION $avrwo_fields"
    AUDIO_VALIDATION_SUMMARY="AUDIO_VALIDATION scope=$avrwo_scope policy=basic-integrity $avrwo_fields"
    export AUDIO_WAV_VALIDATION_SUMMARY AUDIO_VALIDATION_SUMMARY
    return 1
  fi

  avrwo_fields="status=PASS reason=pcm-signal-activity-present validator=od analyzed_samples=$avrwo_samples nonzero_storage_bytes=$avrwo_nonzero_storage_bytes nonzero_samples=$avrwo_nonzero_samples active_samples=$avrwo_active_samples distinct_samples=$avrwo_distinct_samples rms_dbfs=$avrwo_rms_dbfs dc_offset=$avrwo_dc_offset clipped_samples=$avrwo_clipped_samples silence_runs=$avrwo_silence_runs longest_silence_ms=$avrwo_longest_silence_ms glitch_candidates=$avrwo_glitch_candidates silent_channels=$avrwo_silent_channels strict_signal=$avrwo_strict_signal min_rms_dbfs=$avrwo_min_rms_dbfs"
  AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION $avrwo_fields"
  AUDIO_VALIDATION_SUMMARY="AUDIO_VALIDATION scope=$avrwo_scope policy=basic-integrity $avrwo_fields"
  export AUDIO_WAV_VALIDATION_SUMMARY AUDIO_VALIDATION_SUMMARY
  return 0
}

# audio_validate_wav_file <file> <source-kind> <rate> <channels> <bits>
#                         <seconds> <log-file> <scope> [min-distinct-samples]
# Validate WAV structure and basic signal integrity. Advanced signal metrics
# remain diagnostic unless strict-signal mode is explicitly enabled.
audio_validate_wav_file() {
  avrw_file="$1"
  avrw_source_kind="${2:-mic}"
  avrw_rate="${3:-0}"
  avrw_channels="${4:-0}"
  avrw_bits="${5:-0}"
  avrw_expected_seconds="${6:-0}"
  avrw_log="${7:-}"
  avrw_scope="${8:-record}"
  avrw_min_distinct="${9:-${AUDIO_RECORD_MIN_DISTINCT_SAMPLES:-4}}"
  avrw_validator="${AUDIO_WAV_VALIDATOR:-${TOOLS:-}/audio_wav_validate.py}"

  AUDIO_WAV_VALIDATION_SUMMARY=""
  AUDIO_VALIDATION_SUMMARY=""
  export AUDIO_WAV_VALIDATION_SUMMARY AUDIO_VALIDATION_SUMMARY

  if command -v python3 >/dev/null 2>&1 && [ -r "$avrw_validator" ]; then
    avrw_output="$(python3 "$avrw_validator" \
      --file "$avrw_file" \
      --source-kind "$avrw_source_kind" \
      --expect-rate "$avrw_rate" \
      --expect-channels "$avrw_channels" \
      --expect-bits "$avrw_bits" \
      --expected-seconds "$avrw_expected_seconds" \
      --analyze-bytes "${AUDIO_RECORD_ANALYZE_BYTES:-4194304}" \
      --min-active-samples "${AUDIO_RECORD_MIN_ACTIVE_SAMPLES:-100}" \
      --sample-threshold-lsb "${AUDIO_RECORD_SAMPLE_THRESHOLD_LSB:-${AUDIO_RECORD_SAMPLE_THRESHOLD:-8}}" \
      --min-distinct-samples "$avrw_min_distinct" \
      --min-duration-ratio "${AUDIO_RECORD_MIN_DURATION_RATIO:-0.70}" \
      --strict-signal "${AUDIO_RECORD_STRICT_SIGNAL:-0}" \
      --min-rms-dbfs "${AUDIO_RECORD_MIN_RMS_DBFS:--60}" \
      --validation-scope "$avrw_scope" \
      2>&1)"
    avrw_rc=$?

    [ -n "$avrw_log" ] && printf '%s\n' "$avrw_output" >>"$avrw_log"
    printf '%s\n' "$avrw_output" |
      while IFS= read -r avrw_line; do
        [ -n "$avrw_line" ] && log_info "$avrw_line"
      done

    AUDIO_WAV_VALIDATION_SUMMARY="$(
      printf '%s\n' "$avrw_output" |
        sed -n '/^AUDIO_WAV_VALIDATION /p' |
        tail -n 1
    )"
    AUDIO_VALIDATION_SUMMARY="$(
      printf '%s\n' "$avrw_output" |
        sed -n '/^AUDIO_VALIDATION /p' |
        tail -n 1
    )"
    if [ -z "$AUDIO_WAV_VALIDATION_SUMMARY" ]; then
      AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION status=ERROR reason=validator-output-missing"
    fi
    if [ -z "$AUDIO_VALIDATION_SUMMARY" ]; then
      AUDIO_VALIDATION_SUMMARY="AUDIO_VALIDATION scope=$avrw_scope policy=basic-integrity status=FAIL reason=validator-output-missing"
    fi
    export AUDIO_WAV_VALIDATION_SUMMARY AUDIO_VALIDATION_SUMMARY
    [ "$avrw_rc" -eq 0 ]
    return $?
  fi

  log_warn "Python WAV validator unavailable, using bounded od/dd fallback"
  if audio_validate_recorded_wav_od \
      "$avrw_file" \
      "$avrw_source_kind" \
      "$avrw_rate" \
      "$avrw_channels" \
      "$avrw_expected_seconds" \
      "$avrw_bits" \
      "$avrw_scope"; then
    if [ -n "$avrw_log" ]; then
      printf '%s\n%s\n' \
        "$AUDIO_WAV_VALIDATION_SUMMARY" \
        "$AUDIO_VALIDATION_SUMMARY" >>"$avrw_log"
    fi
    log_info "$AUDIO_WAV_VALIDATION_SUMMARY"
    log_info "$AUDIO_VALIDATION_SUMMARY"
    return 0
  fi

  if [ -z "$AUDIO_WAV_VALIDATION_SUMMARY" ]; then
    AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION status=FAIL reason=od-fallback-validation-failed"
  fi
  if [ -z "$AUDIO_VALIDATION_SUMMARY" ]; then
    AUDIO_VALIDATION_SUMMARY="AUDIO_VALIDATION scope=$avrw_scope policy=basic-integrity status=FAIL reason=od-fallback-validation-failed"
  fi
  export AUDIO_WAV_VALIDATION_SUMMARY AUDIO_VALIDATION_SUMMARY
  if [ -n "$avrw_log" ]; then
    printf '%s\n%s\n' \
      "$AUDIO_WAV_VALIDATION_SUMMARY" \
      "$AUDIO_VALIDATION_SUMMARY" >>"$avrw_log"
  fi
  log_fail "$AUDIO_WAV_VALIDATION_SUMMARY"
  log_fail "$AUDIO_VALIDATION_SUMMARY"
  return 1
}

# audio_validate_recorded_wav <file> [source-kind] [rate] [channels]
#                             [seconds] [log-file] [scope]
# Validate one recorded WAV using the shared basic-integrity policy. The
# validation scope defaults to record and is preserved in emitted evidence.
audio_validate_recorded_wav() {
  audio_validate_wav_file \
    "$1" \
    "${2:-mic}" \
    "${3:-0}" \
    "${4:-0}" \
    0 \
    "${5:-0}" \
    "${6:-}" \
    "${7:-record}"
}

# audio_validate_playback_wav <file> [log-file]
# Validate a playback asset and emit AUDIO_VALIDATION scope=playback evidence.
audio_validate_playback_wav() {
  avpw_file="$1"
  avpw_log="${2:-}"
  avpw_name="$(basename "$avpw_file")"
  avpw_rate=0
  avpw_channels=0
  avpw_bits=0
  avpw_seconds="$(extract_clip_duration "$avpw_name" 2>/dev/null || echo 0)"
  avpw_metadata="$(parse_clip_metadata "$avpw_name" 2>/dev/null || true)"

  if [ -n "$avpw_metadata" ]; then
    # shellcheck disable=SC2086 # Intentional parsing of helper key=value output.
    set -- $avpw_metadata
    avpw_rate_label="${1#rate=}"
    avpw_bits="${2#bits=}"
    avpw_channels="${3#channels=}"
    avpw_bits="${avpw_bits%b}"
    avpw_channels="${avpw_channels%ch}"

    case "$avpw_rate_label" in
      8KHz) avpw_rate=8000 ;;
      16KHz) avpw_rate=16000 ;;
      22.05KHz) avpw_rate=22050 ;;
      24KHz) avpw_rate=24000 ;;
      32KHz) avpw_rate=32000 ;;
      44.1KHz) avpw_rate=44100 ;;
      48KHz) avpw_rate=48000 ;;
      88.2KHz) avpw_rate=88200 ;;
      96KHz) avpw_rate=96000 ;;
      176.4KHz) avpw_rate=176400 ;;
      192KHz) avpw_rate=192000 ;;
      352.8KHz) avpw_rate=352800 ;;
      384KHz) avpw_rate=384000 ;;
      *) avpw_rate=0 ;;
    esac
  fi

  avpw_had_strict=0
  avpw_saved_strict=""
  if [ "${AUDIO_RECORD_STRICT_SIGNAL+x}" = x ]; then
    avpw_had_strict=1
    avpw_saved_strict="$AUDIO_RECORD_STRICT_SIGNAL"
  fi
  AUDIO_RECORD_STRICT_SIGNAL=0
  export AUDIO_RECORD_STRICT_SIGNAL

  audio_validate_wav_file \
    "$avpw_file" \
    mic \
    "$avpw_rate" \
    "$avpw_channels" \
    "$avpw_bits" \
    "$avpw_seconds" \
    "$avpw_log" \
    playback
  avpw_rc=$?

  if [ "$avpw_had_strict" -eq 1 ]; then
    AUDIO_RECORD_STRICT_SIGNAL="$avpw_saved_strict"
    export AUDIO_RECORD_STRICT_SIGNAL
  else
    unset AUDIO_RECORD_STRICT_SIGNAL
  fi

  return "$avpw_rc"
}

# Validate one recorder result using the existing timeout and file-size helpers
# plus the WAV payload validator above.
#
# Args:
#   $1 file
#   $2 source kind: mic|headset-mic|null
#   $3 expected rate, 0 disables the rate check
#   $4 expected channels, 0 disables the channel check
#   $5 expected recording duration
#   $6 recorder return code
#   $7 watchdog timeout passed to audio_exec_with_timeout
#   $8 optional log file
#   $9 validation scope, default: record
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
  avrr_scope="${9:-record}"

  avrr_bytes="$(file_size_bytes "$avrr_file" 2>/dev/null || echo 0)"
  if [ "${avrr_bytes:-0}" -le 44 ] 2>/dev/null; then
    avrr_fields="status=FAIL reason=file-empty-or-header-only file_bytes=${avrr_bytes:-0}"
    AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION $avrr_fields"
    AUDIO_VALIDATION_SUMMARY="AUDIO_VALIDATION scope=$avrr_scope policy=basic-integrity $avrr_fields"
    export AUDIO_WAV_VALIDATION_SUMMARY AUDIO_VALIDATION_SUMMARY
    if [ -n "$avrr_log" ]; then
      printf '%s\n%s\n' \
        "$AUDIO_WAV_VALIDATION_SUMMARY" \
        "$AUDIO_VALIDATION_SUMMARY" >>"$avrr_log"
    fi
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
      "$avrr_log" \
      "$avrr_scope"; then
    return 1
  fi

  case "$avrr_rc" in
    0)
      ;;
    124|137|143)
      avrr_timeout_seconds="$(audio_parse_secs "$avrr_timeout" 2>/dev/null || echo 0)"
      if [ -z "$avrr_timeout_seconds" ] || [ "$avrr_timeout_seconds" -le 0 ] 2>/dev/null; then
        AUDIO_WAV_VALIDATION_SUMMARY="${AUDIO_WAV_VALIDATION_SUMMARY} recorder_rc=$avrr_rc recorder_status=unexpected-timeout"
        AUDIO_VALIDATION_SUMMARY="${AUDIO_VALIDATION_SUMMARY} recorder_rc=$avrr_rc recorder_status=unexpected-timeout"
        export AUDIO_WAV_VALIDATION_SUMMARY AUDIO_VALIDATION_SUMMARY
        return 1
      fi
      log_info "Recorder ended through expected watchdog timeout rc=$avrr_rc, validated WAV payload is accepted"
      ;;
    *)
      # Valid samples do not make a failed or stalled recorder successful.
      AUDIO_WAV_VALIDATION_SUMMARY="$(printf '%s\n' "$AUDIO_WAV_VALIDATION_SUMMARY" |
        sed 's/status=PASS/status=FAIL/; s/reason=[^ ]*/reason=recorder-failed/') recorder_rc=$avrr_rc recorder_status=failed"
      AUDIO_VALIDATION_SUMMARY="$(printf '%s\n' "$AUDIO_VALIDATION_SUMMARY" |
        sed 's/status=PASS/status=FAIL/; s/reason=[^ ]*/reason=recorder-failed/') recorder_rc=$avrr_rc recorder_status=failed"
      export AUDIO_WAV_VALIDATION_SUMMARY AUDIO_VALIDATION_SUMMARY
      if [ -n "$avrr_log" ]; then
        printf '%s\n%s\n' "$AUDIO_WAV_VALIDATION_SUMMARY" \
          "$AUDIO_VALIDATION_SUMMARY" >>"$avrr_log"
      fi
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
