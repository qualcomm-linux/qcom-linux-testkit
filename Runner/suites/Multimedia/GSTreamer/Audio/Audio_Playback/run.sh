#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Audio Playback validation using GStreamer (auto backend: PipeWire/Pulse/ALSA)
# Logs everything to console and also to local log files.
# PASS/FAIL/SKIP is emitted to .res. Always exits 0 (LAVA-friendly).

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
  exit 0
fi

# shellcheck disable=SC1090
. "$INIT_ENV"

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

# NOTE: lib_gstreamer.sh is under Runner/utils only
# shellcheck disable=SC1091
. "$TOOLS/lib_gstreamer.sh"

# Optional wrapper/aliases for audio-specific helpers (if present)
# shellcheck disable=SC1091
[ -f "$TOOLS/audio_common.sh" ] && . "$TOOLS/audio_common.sh"

TESTNAME="Audio_Playback"
RES_FILE="./${TESTNAME}.res"
LOG_DIR="./logs"
OUTDIR="$LOG_DIR/$TESTNAME"
GST_LOG="$OUTDIR/gst.log"
MIXER_LOG="$OUTDIR/mixers.txt"
DMESG_DIR="$OUTDIR/dmesg"
META_LOG="$OUTDIR/clip_meta.txt"

mkdir -p "$OUTDIR" "$DMESG_DIR" >/dev/null 2>&1 || true
: >"$RES_FILE"
: >"$GST_LOG"
: >"$META_LOG"

AUDIO_LOGCTX="$GST_LOG"
export AUDIO_LOGCTX

result="FAIL"
reason="unknown"
finalBackend=""
finalPipe=""
gstRc=1

# -------------------- Defaults (LAVA env vars -> defaults; CLI overrides) --------------------
# LAVA job can set these via the job "environment:" section.
backend="${AUDIO_BACKEND:-${AUDIO_PLAYBACK_BACKEND:-auto}}"
stack="${AUDIO_STACK:-${AUDIO_PLAYBACK_STACK:-auto}}"
format="${AUDIO_FORMAT:-${AUDIO_PLAYBACK_FORMAT:-wav}}"
duration="${AUDIO_DURATION:-${AUDIO_PLAYBACK_DURATION:-${RUNTIMESEC:-10s}}}"
clipDur="${AUDIO_CLIPDUR:-${AUDIO_PLAYBACK_CLIPDUR:-short}}"
clipPath="${AUDIO_CLIP:-${AUDIO_PLAYBACK_CLIP:-}}"

clipsDir="${AUDIO_CLIPS_DIR:-${AUDIO_PLAYBACK_CLIPS_DIR:-}}"
assetsPath="${AUDIO_ASSETS:-${AUDIO_PLAYBACK_ASSETS:-}}"
assetsUrl="${AUDIO_ASSETS_URL:-${AUDIO_PLAYBACK_ASSETS_URL:-${AUDIO_TAR_URL:-}}}"

rate="${AUDIO_RATE:-${AUDIO_PLAYBACK_RATE:-}}"
channels="${AUDIO_CHANNELS:-${AUDIO_PLAYBACK_CHANNELS:-}}"
sinkSel="${AUDIO_SINK:-${AUDIO_PLAYBACK_SINK:-}}"
useNullSink="${AUDIO_NULL_SINK:-${AUDIO_PLAYBACK_NULL_SINK:-0}}"

alsaDevice="${AUDIO_ALSA_DEVICE:-${AUDIO_PLAYBACK_ALSA_DEVICE:-}}"

gstDebugLevel="${AUDIO_GST_DEBUG:-${AUDIO_PLAYBACK_GST_DEBUG:-2}}"

rateUser="0"
channelsUser="0"
rateInferred="0"
channelsInferred="0"

# If env provided rate/channels, treat as "user provided"
if [ -n "$rate" ]; then
  rateUser="1"
fi
if [ -n "$channels" ]; then
  channelsUser="1"
fi

cleanup() {
  pkill -x gst-launch-1.0 >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

# -------------------- Arg parse (SC2015-clean) --------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --backend)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --backend"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      backend="$2"
      shift 2
      ;;

    --stack)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --stack"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      stack="$2"
      shift 2
      ;;

    --format)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --format"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      format="$2"
      shift 2
      ;;

    --duration)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --duration"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      duration="$2"
      shift 2
      ;;

    --clipdur)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clipdur"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      clipDur="$2"
      shift 2
      ;;

    --clip)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clip"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      clipPath="$2"
      shift 2
      ;;

    --clips-dir)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clips-dir"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      clipsDir="$2"
      shift 2
      ;;

    --assets)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --assets"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      assetsPath="$2"
      shift 2
      ;;

    --assets-url)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --assets-url"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      assetsUrl="$2"
      shift 2
      ;;

    --rate)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --rate"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      rate="$2"
      rateUser="1"
      shift 2
      ;;

    --channels)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --channels"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      channels="$2"
      channelsUser="1"
      shift 2
      ;;

    --sink)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --sink"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      sinkSel="$2"
      shift 2
      ;;

    --null-sink)
      useNullSink="1"
      shift 1
      ;;

    --alsa-device)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --alsa-device"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      alsaDevice="$2"
      shift 2
      ;;

    --gst-debug)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --gst-debug"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      gstDebugLevel="$2"
      shift 2
      ;;

    -h|--help)
      cat <<EOF
Usage:
  $0 [options]

Options:
  --backend <auto|pipewire|pulseaudio|alsa>
      Default: auto (tries pipewire -> pulseaudio -> alsa)

  --stack <auto|base|overlay>
      Default: auto
        auto : detect overlay (audioreach modules) and apply setup only if detected
        base : force base (do not run overlay setup even if audioreach modules present)
        overlay : force overlay setup (fails if setup_overlay_audio_environment fails)

  --format <wav|aac|mp3|flac>
      Default: ${format}

  --duration <N|Ns|Nm|Nh|MM:SS|HH:MM:SS>
      Default: ${duration}

  --clipdur <short|medium|long>
      Used with resolve_clip(). Default: ${clipDur}

  --clip <path>
      Override resolved clip path.

  --clips-dir <dir>
      Untarred clips directory on device. Sets AUDIO_CLIPS_BASE_DIR.

  --assets <path>
      Device-provided assets (no network):
        - directory: treated as --clips-dir
        - file: .tar/.tar.gz/.tgz extracted into clips-dir (or default AudioClips under script dir)

  --assets-url <url>
      Optional remote tarball URL (only used if clip missing).

  --rate <Hz>
      Force caps rate after decode/resample. Example: 48000

  --channels <N>
      Force caps channels after decode/resample. Example: 1 or 2

  --sink <idOrName>
      For PipeWire: numeric id or substring match in wpctl status.
      For PulseAudio: sink name or numeric index.

  --null-sink
      Prefer null/dummy sink if available (for non-audible CI runs).

  --alsa-device <hw:C,D|default>
      Override ALSA device used when backend falls back to alsasink.

  --gst-debug <level>
      Sets GST_DEBUG=<level> (single numeric level only).
        1 ERROR
        2 WARNING
        3 FIXME
        4 INFO
        5 DEBUG
        6 LOG
        7 TRACE
        9 MEMDUMP
      Default: ${gstDebugLevel}

LAVA env defaults:
  AUDIO_BACKEND/AUDIO_STACK/AUDIO_FORMAT/AUDIO_DURATION/AUDIO_CLIPDUR/AUDIO_CLIP
  AUDIO_CLIPS_DIR/AUDIO_ASSETS/AUDIO_ASSETS_URL/AUDIO_RATE/AUDIO_CHANNELS
  AUDIO_SINK/AUDIO_NULL_SINK/AUDIO_ALSA_DEVICE/AUDIO_GST_DEBUG
  (or AUDIO_PLAYBACK_* equivalents)

EOF
      echo "SKIP" >"$RES_FILE"
      exit 0
      ;;

    *)
      log_warn "Unknown argument: $1"
      echo "SKIP" >"$RES_FILE"
      exit 0
      ;;
  esac
done

# -------------------- Validate parsed values --------------------
case "$backend" in auto|pipewire|pulseaudio|alsa) : ;; *)
  log_warn "Invalid --backend '$backend'"
  echo "SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$stack" in auto|base|overlay) : ;; *)
  log_warn "Invalid --stack '$stack'"
  echo "SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$format" in wav|aac|mp3|flac) : ;; *)
  log_warn "Invalid --format '$format'"
  echo "SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$clipDur" in short|medium|long) : ;; *)
  log_warn "Invalid --clipdur '$clipDur'"
  echo "SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$gstDebugLevel" in 1|2|3|4|5|6|7|9) : ;; *)
  log_warn "Invalid --gst-debug '$gstDebugLevel' (allowed: 1 2 3 4 5 6 7 9)"
  echo "SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

if [ -n "$rate" ]; then
  case "$rate" in *[!0-9]*)
    log_warn "Invalid --rate '$rate' (expected integer Hz)"
    echo "SKIP" >"$RES_FILE"
    exit 0
    ;;
  esac
fi

if [ -n "$channels" ]; then
  case "$channels" in *[!0-9]*)
    log_warn "Invalid --channels '$channels' (expected integer)"
    echo "SKIP" >"$RES_FILE"
    exit 0
    ;;
  esac
  if [ "$channels" -lt 1 ] 2>/dev/null || [ "$channels" -gt 8 ] 2>/dev/null; then
    log_warn "Invalid --channels '$channels' (expected 1..8)"
    echo "SKIP" >"$RES_FILE"
    exit 0
  fi
fi

# -------------------- Pre-checks --------------------
check_dependencies "gst-launch-1.0" "gst-inspect-1.0" >/dev/null 2>&1 || {
  log_warn "Missing gstreamer runtime (gst-launch-1.0/gst-inspect-1.0)"
  echo "SKIP" >"$RES_FILE"
  exit 0
}

log_info "Test: $TESTNAME"
log_info "Requested: backend=$backend stack=$stack format=$format duration=$duration clipDur=$clipDur clip=${clipPath:-<auto>}"
log_info "Options: rate=${rate:-<unset>} channels=${channels:-<unset>} nullSink=$useNullSink sinkSel=${sinkSel:-<none>}"
log_info "GST debug: GST_DEBUG=$gstDebugLevel (to file: $GST_LOG)"
log_info "Assets: clipsDir=${clipsDir:-<none>} assets=${assetsPath:-<none>} assetsUrl=${assetsUrl:-<none>}"
log_info "Logs: $OUTDIR"

# -------------------- Stack handling (base/overlay/auto) --------------------
if command -v setup_overlay_audio_environment >/dev/null 2>&1; then
  if [ "$stack" = "overlay" ]; then
    log_info "Stack=overlay: applying overlay audio environment setup"
    if ! setup_overlay_audio_environment; then
      log_warn "Overlay audio environment setup failed (forced overlay)"
      echo "SKIP" >"$RES_FILE"
      exit 0
    fi
  elif [ "$stack" = "auto" ]; then
    if lsmod 2>/dev/null | awk '$1 ~ /^audioreach/ { found=1; exit } END { exit !found }'; then
      log_info "Stack=auto: overlay detected (audioreach modules present); applying overlay setup"
      if ! setup_overlay_audio_environment; then
        log_warn "Overlay audio environment setup failed (auto)"
      fi
    else
      log_info "Stack=auto: base detected; skipping overlay setup"
    fi
  else
    log_info "Stack=base: skipping overlay setup"
  fi
else
  if [ "$stack" = "overlay" ]; then
    log_warn "setup_overlay_audio_environment not available but stack=overlay requested"
    echo "SKIP" >"$RES_FILE"
    exit 0
  fi
fi

# -------------------- Device-provided assets provisioning --------------------
if [ -n "$assetsPath" ] || [ -n "$clipsDir" ]; then
  finalClipsDir="$(gstreamer_assets_provision "$assetsPath" "$clipsDir" "$SCRIPT_DIR")"
  if [ -n "$finalClipsDir" ]; then
    clipsDir="$finalClipsDir"
    export AUDIO_CLIPS_BASE_DIR="$clipsDir"
    log_info "AUDIO_CLIPS_BASE_DIR=$AUDIO_CLIPS_BASE_DIR"
  fi
fi

# -------------------- Resolve clip --------------------
if [ -z "$clipPath" ]; then
  clipPath="$(resolve_clip "$format" "$clipDur")"
fi

if [ -z "$clipPath" ]; then
  log_warn "No clip mapping for format=$format clipDur=$clipDur"
  echo "SKIP" >"$RES_FILE"
  exit 0
fi

log_info "Selected clip: $clipPath"

if [ ! -s "$clipPath" ]; then
  if [ -n "$assetsPath" ] || [ -n "$clipsDir" ]; then
    log_warn "Clip missing/empty after local provisioning: $clipPath"
    echo "SKIP" >"$RES_FILE"
    exit 0
  fi

  if [ -n "$assetsUrl" ] && command -v audio_ensure_clip_ready >/dev/null 2>&1; then
    log_info "Clip missing; attempting fetch via assetsUrl"
    audio_ensure_clip_ready "$clipPath" "$assetsUrl"
    clipRc=$?
    if [ "$clipRc" -ne 0 ] 2>/dev/null; then
      log_warn "Clip not ready (fetch/extract failed). SKIP."
      echo "SKIP" >"$RES_FILE"
      exit 0
    fi
  else
    log_warn "Clip missing/empty: $clipPath"
    echo "SKIP" >"$RES_FILE"
    exit 0
  fi
fi

# -------------------- Clip metadata + infer missing caps --------------------
# Only infer if user didn't provide.
if [ "$rateUser" = "0" ] || [ "$channelsUser" = "0" ]; then
  if gstreamer_log_clip_metadata "$clipPath" "$META_LOG"; then
    inferred="$(gstreamer_infer_audio_params_from_meta "$META_LOG")"
    set -- "$inferred"
    infRate="${1:-}"
    infCh="${2:-}"

    if [ "$rateUser" = "0" ] && [ -z "$rate" ] && [ -n "$infRate" ]; then
      rate="$infRate"
      rateInferred="1"
    fi
    if [ "$channelsUser" = "0" ] && [ -z "$channels" ] && [ -n "$infCh" ]; then
      channels="$infCh"
      channelsInferred="1"
    fi
  fi
fi

# -------------------- Normalize duration seconds --------------------
secs=""
if command -v audio_parse_secs >/dev/null 2>&1; then
  secs="$(audio_parse_secs "$duration" 2>/dev/null || true)"
fi
if [ -z "$secs" ]; then
  case "$duration" in
    '' ) secs="10" ;;
    *[!0-9]* ) secs="10" ;;
    * ) secs="$duration" ;;
  esac
fi
log_info "Normalized duration seconds: $secs"

# -------------------- Caps filter (ONLY if user asked OR inference succeeded) --------------------
useCaps="0"
if [ "$rateUser" = "1" ] || [ "$channelsUser" = "1" ] || [ "$rateInferred" = "1" ] || [ "$channelsInferred" = "1" ]; then
  useCaps="1"
fi

capsStr=""
if [ "$useCaps" = "1" ]; then
  capsStr="$(gstreamer_build_capsfilter_string "$rate" "$channels")"
  if [ -n "$capsStr" ]; then
    log_info "Playback caps: $capsStr (forced)"
  else
    log_info "Playback caps: <negotiated> (no caps forced)"
    useCaps="0"
  fi
else
  log_info "Playback caps: <negotiated> (no caps forced)"
fi
# -------------------- Backend chain --------------------
chain=""
if [ "$backend" = "auto" ] && command -v build_backend_chain >/dev/null 2>&1; then
  chain="$(build_backend_chain)"
else
  chain="$backend"
fi
log_info "Backend chain: $chain"

# ALSA device: allow explicit override, else pick dynamically (audio_common-aware)
if [ -n "$alsaDevice" ]; then
  GST_ALSA_PLAYBACK_DEVICE="$alsaDevice"
  export GST_ALSA_PLAYBACK_DEVICE
fi
alsaPick="$(gstreamer_alsa_pick_playback_hw)"
log_info "ALSA playback device (best-effort): $alsaPick"

# -------------------- GStreamer debug capture (single level only) --------------------
export GST_DEBUG_NO_COLOR=1
export GST_DEBUG="$gstDebugLevel"
export GST_DEBUG_FILE="$GST_LOG"

# -------------------- Attempt playback across backends --------------------
for b in $chain; do
  [ -n "$b" ] || continue

  case "$b" in
    pipewire|pulseaudio|alsa) : ;;
    auto) continue ;;
    *)
      log_warn "Unsupported backend: $b"
      continue
      ;;
  esac

  if command -v check_audio_daemon >/dev/null 2>&1; then
    if [ "$b" = "pipewire" ] || [ "$b" = "pulseaudio" ]; then
      if ! check_audio_daemon "$b"; then
        log_warn "Audio daemon not running for backend=$b; trying next backend"
        continue
      fi
    fi
  fi

  # Default routing selection (pipewire/pulseaudio), best-effort only
  gstreamer_select_default_sink "$b" "$sinkSel" "$useNullSink" || true

  # Build pipeline via lib (explicit decode chains + optional caps + backend sink)
  pipe="$(gstreamer_build_playback_pipeline "$b" "$format" "$clipPath" "$capsStr" "$alsaPick")"
  if [ -z "$pipe" ]; then
    log_warn "No usable sink element/pipeline for backend=$b; trying next backend"
    continue
  fi

  finalBackend="$b"
  finalPipe="$pipe"

  log_info "Selected backend: $finalBackend"

  : >"$GST_LOG"

  # Run gst-launch with timeout (shared lib runner)
  gstreamer_run_gstlaunch_timeout "$secs" "$finalPipe"
  gstRc=$?

  log_info "gst-launch exit code: $gstRc"

  # Evidence after run (backend + optional asoc fallback centralized in lib)
  ev="$(gstreamer_backend_evidence_sampled "$finalBackend" 3)"
  log_info "Evidence streaming/path_on: $ev"

  okRc="0"
  if [ "$gstRc" -eq 0 ] 2>/dev/null; then
    okRc="1"
  elif [ "$secs" -gt 0 ] 2>/dev/null; then
    # tolerate timeout exit codes when we intentionally stop playback
    if [ "$gstRc" -eq 124 ] 2>/dev/null || [ "$gstRc" -eq 143 ] 2>/dev/null; then
      okRc="1"
    fi
  fi

  if [ "$okRc" = "1" ] && [ "$ev" = "1" ]; then
    result="PASS"
    reason="backend=$finalBackend rc=$gstRc evidence=$ev"
    break
  fi

  log_warn "Playback attempt did not meet PASS criteria on backend=$finalBackend (rc=$gstRc evidence=$ev). Trying next."
done

# -------------------- Post validation --------------------
if command -v dump_mixers >/dev/null 2>&1; then
  dump_mixers "$MIXER_LOG" || true
fi

if command -v scan_audio_dmesg >/dev/null 2>&1; then
  scan_audio_dmesg "$DMESG_DIR" || true
fi

# -------------------- Emit result --------------------
case "$result" in
  PASS)
    log_pass "$TESTNAME PASS: $reason"
    echo "PASS" >"$RES_FILE"
    ;;
  *)
    if [ -z "$finalBackend" ]; then
      log_warn "$TESTNAME SKIP: no usable backend found"
      echo "SKIP" >"$RES_FILE"
    else
      log_fail "$TESTNAME FAIL: backend=$finalBackend rc=$gstRc"
      log_fail "Pipeline: $finalPipe"
      echo "FAIL" >"$RES_FILE"
    fi
    ;;
esac

exit 0
