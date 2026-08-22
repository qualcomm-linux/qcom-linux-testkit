#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Source init_env & tools ----
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
  echo "[ERROR] init_env not found" >&2
  exit 1
fi

# Only source once (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
  # shellcheck disable=SC1090
  . "$INIT_ENV"
  __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/audio_common.sh"

# audio_prepare_test_packages() in audio_common.sh reuses these helpers.
# Source the provider only when it was not already loaded by a shared library.
if ! command -v pkg_detect_os_id >/dev/null 2>&1 &&
   [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$TOOLS/lib_pkg_provider.sh"
fi

SYSTEMD_AVAILABLE=0
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  SYSTEMD_AVAILABLE=1
fi

TESTNAME="AudioRecord"
RESULT_TESTNAME="$TESTNAME"
RES_SUFFIX="" # Optional suffix for unique result files (e.g., "Config1")
# RES_FILE and LOGDIR are resolved by the early non-consuming pre-parser

# Pre-parse the options required by privileged Audio preparation without
# consuming the original argument list. The complete original "$@" must remain
# available for the root-to-debian re-exec performed below.
AUDIO_OVERLAY_REQUESTED=0
AUDIO_EARLY_HELP_REQUESTED=0
AUDIO_EARLY_EXPECT=""

for arg in "$@"; do
  case "$AUDIO_EARLY_EXPECT" in
    res-suffix)
      RES_SUFFIX="$arg"
      AUDIO_EARLY_EXPECT=""
      continue
      ;;
    lava-testcase-id)
      RESULT_TESTNAME="$arg"
      AUDIO_EARLY_EXPECT=""
      continue
      ;;
  esac

  case "$arg" in
    --overlay)
      AUDIO_OVERLAY_REQUESTED=1
      ;;
    --res-suffix)
      AUDIO_EARLY_EXPECT="res-suffix"
      ;;
    --lava-testcase-id)
      AUDIO_EARLY_EXPECT="lava-testcase-id"
      ;;
    --help|-h)
      AUDIO_EARLY_HELP_REQUESTED=1
      ;;
  esac
done

export AUDIO_OVERLAY_REQUESTED

# ---------------- Defaults / CLI ----------------
AUDIO_BACKEND="${AUDIO_BACKEND:-}"
SRC_CHOICE="${SRC_CHOICE:-mic}" # mic|null
DURATIONS="" # Will be set to default only if using legacy mode
RECORD_SECONDS="${RECORD_SECONDS:-30s}" # DEFAULT: 30s; 'auto' maps short/med/long
LOOPS="${LOOPS:-1}"
TIMEOUT="${TIMEOUT:-0}" # 0 = no watchdog
STRICT="${STRICT:-0}"
DMESG_SCAN="${DMESG_SCAN:-1}"
VERBOSE=0
JUNIT_OUT=""

# Capture paths are assigned by audio_record_set_capture_paths() from
# audio_common.sh before every recording attempt. Declare them here so the
# runner owns the shared state explicitly and static analysis can track it.
record_out=""
record_user_out=""

# Explicit AudioReach overlay selection and WAV signal policy.
# AUDIO_OVERLAY_REQUESTED was derived above without consuming the CLI.
AUDIO_RECORD_STRICT_SIGNAL="${AUDIO_RECORD_STRICT_SIGNAL:-auto}"
export AUDIO_OVERLAY_REQUESTED AUDIO_RECORD_STRICT_SIGNAL

# Minimal ramdisk audio bootstrap options
AUDIO_BOOTSTRAP_MODE="${AUDIO_BOOTSTRAP_MODE:-auto}" # auto|true|false
AUDIO_RUNTIME_DIR="${AUDIO_RUNTIME_DIR:-}" # optional override
MINIMAL_RAMDISK_MODE=0
AUDIO_STARTED_PIDS=""
AUDIO_CREATED_RUNTIME_DIR=0
AUDIO_SYSTEMD_MANAGED=0
export AUDIO_BOOTSTRAP_MODE AUDIO_RUNTIME_DIR MINIMAL_RAMDISK_MODE AUDIO_STARTED_PIDS AUDIO_CREATED_RUNTIME_DIR AUDIO_SYSTEMD_MANAGED

# New config-based testing options
CONFIG_NAMES="" # Explicit config names to test (e.g., "record_config1 record_config2")
CONFIG_FILTER="" # Filter pattern for configs (e.g., "48KHz" or "2ch")
USE_CONFIG_DISCOVERY="${USE_CONFIG_DISCOVERY:-auto}" # auto|true|false

usage() {
  cat <<EOF
Usage: $0 [options]
  --backend {pipewire|pulseaudio|alsa}
  --source {mic|null}
  --overlay              Prepare the Debian Qualcomm AudioReach overlay
                         Without this flag, use the native/base stack.
  --config-name "record_config1" # Test specific config(s) by name (space-separated)
                                 # Also supports record_config1, record_config2, ..., record_config10
  --config-filter "48KHz" # Filter configs by pattern
  --res-suffix SUFFIX # Suffix for unique result file (e.g., "Config1")
                      # Generates AudioRecord_SUFFIX.res instead of AudioRecord.res
  --record-seconds SECS|auto (default: 30s; 'auto' maps short=5s, medium=15s, long=30s)
  --durations "short [medium] [long] [10s] [35secs]" (used when --record-seconds auto)
  --audio-bootstrap {auto|true|false}
                      # auto = bootstrap backend only when systemd is absent
                      # true = always allow manual backend bootstrap
                      # false = never bootstrap manually
  --runtime-dir PATH # Override XDG_RUNTIME_DIR for minimal ramdisk mode
  --loops N
  --timeout SECS
  --strict [0|1]
  --no-dmesg
  --junit FILE.xml
  --verbose
  --help

Examples:
  # Test all 10 record configs
  $0

  # Test specific configs by name
  $0 --config-name "record_config1 record_config2 record_config3"

  # Test specific configs by descriptive name
  $0 --config-name "record_48KHz_2ch record_8KHz_1ch"

  # Filter configs by pattern
  $0 --config-filter "48KHz"
EOF
}

# Keep Debian service recovery inside the prepared user manager. Preserve the
# existing broad best-effort recovery only for native/Yocto execution.
# --help must not install packages, change user groups, create output files, or
# start a systemd user manager.
if [ "$AUDIO_EARLY_HELP_REQUESTED" -eq 1 ]; then
  usage
  exit 0
fi

# Resolve root-owned result and log paths before privileged preparation.
if [ -n "$RES_SUFFIX" ]; then
  RES_FILE="$SCRIPT_DIR/${TESTNAME}_${RES_SUFFIX}.res"
  LOGDIR="$SCRIPT_DIR/results/${TESTNAME}_${RES_SUFFIX}"
  log_info "Using unique result file: $RES_FILE"
  log_info "Using unique log directory: $LOGDIR"
else
  RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
  LOGDIR="$SCRIPT_DIR/results/${TESTNAME}"
fi

# Package and udev preparation remain privileged. The complete runner stays
# the root orchestrator on Debian.
if ! command -v audio_prepare_test_packages >/dev/null 2>&1; then
  log_fail "$TESTNAME FAIL - required helper is unavailable: audio_prepare_test_packages"
  echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
  exit 1
fi

audio_prepare_test_packages \
  "$AUDIO_OVERLAY_REQUESTED"
audio_prepare_rc=$?

case "$audio_prepare_rc" in
  0)
    ;;
  2)
    log_skip "$TESTNAME SKIP - AudioReach kernel package changed, reboot required"
    echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
    exit 0
    ;;
  *)
    log_fail "$TESTNAME FAIL - audio package preparation failed"
    echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
    exit 1
    ;;
esac

# Root owns the final result, logs, summaries, diagnostics, and WAV artifacts.
if ! mkdir -p "$LOGDIR"; then
  log_fail "$TESTNAME FAIL - failed to create log directory: $LOGDIR"
  echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
  exit 1
fi

# The Debian Audio user needs traverse-only access to reach its dedicated
# scratch capture directory. Final logs and WAV artifacts remain root-owned.
if ! chmod 0755 "$LOGDIR"; then
  log_fail "$TESTNAME FAIL - failed to set log directory traversal mode: $LOGDIR"
  echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
  exit 1
fi

if ! : >"$LOGDIR/summary.txt"; then
  log_fail "$TESTNAME FAIL - failed to initialize summary file: $LOGDIR/summary.txt"
  echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --overlay)
      AUDIO_OVERLAY_REQUESTED=1
      export AUDIO_OVERLAY_REQUESTED
      shift
      ;;
    --backend)
      AUDIO_BACKEND="$2"
      shift 2
      ;;
    --source)
      SRC_CHOICE="$2"
      shift 2
      ;;
    --config-name)
      CONFIG_NAMES="$2"
      USE_CONFIG_DISCOVERY=true
      shift 2
      ;;
    --config-filter)
      CONFIG_FILTER="$2"
      USE_CONFIG_DISCOVERY=true
      shift 2
      ;;
    --res-suffix)
      RES_SUFFIX="$2"
      shift 2
      ;;
    --lava-testcase-id)
      RESULT_TESTNAME="$2"
      shift 2
      ;;
    --durations)
      DURATIONS="$2"
      USE_CONFIG_DISCOVERY=false # Explicit durations = use old matrix mode
      shift 2
      ;;
    --record-seconds)
      RECORD_SECONDS="$2"
      shift 2
      ;;
    --audio-bootstrap)
      AUDIO_BOOTSTRAP_MODE="$2"
      export AUDIO_BOOTSTRAP_MODE
      shift 2
      ;;
    --runtime-dir)
      AUDIO_RUNTIME_DIR="$2"
      export AUDIO_RUNTIME_DIR
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
    --junit)
      JUNIT_OUT="$2"
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

# Preserve an explicit backend request. Automatic fallback is only appropriate
# when backend selection was left in auto mode.
AUDIO_BACKEND_REQUESTED="$AUDIO_BACKEND"
export AUDIO_BACKEND_REQUESTED

case "$AUDIO_RECORD_STRICT_SIGNAL" in
  auto)
    AUDIO_RECORD_STRICT_SIGNAL="$STRICT"
    ;;
  0|1)
    ;;
  *)
    log_warn "Invalid AUDIO_RECORD_STRICT_SIGNAL='$AUDIO_RECORD_STRICT_SIGNAL', using 0"
    AUDIO_RECORD_STRICT_SIGNAL=0
    ;;
esac
export AUDIO_RECORD_STRICT_SIGNAL

# Prepare only the Debian user capabilities required by the selected mode.
# Explicit base ALSA capture needs group membership but no systemd user
# manager. Overlay and managed backends require the user session.
AUDIO_RECORD_USER_MANAGER_REQUIRED=1
if [ "$AUDIO_OVERLAY_REQUESTED" -eq 0 ] &&
   [ "$AUDIO_BACKEND" = "alsa" ]; then
  AUDIO_RECORD_USER_MANAGER_REQUIRED=0
fi

for audio_required_helper in \
  audio_prepare_debian_audio_environment \
  audio_run_as_test_user \
  audio_run_helper_as_test_user \
  audio_run_with_timeout_as_test_user
do
  if ! command -v "$audio_required_helper" >/dev/null 2>&1; then
    log_fail "$TESTNAME FAIL - required helper is unavailable: $audio_required_helper"
    echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
    exit 1
  fi
done

if ! audio_prepare_debian_audio_environment \
    "$AUDIO_RECORD_USER_MANAGER_REQUIRED"; then
  log_fail "$TESTNAME FAIL - Debian Audio environment preparation failed"
  echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
  exit 1
fi

AUDIO_RECORD_DEBIAN_ROOT_MODE=0
if command -v pkg_detect_os_id >/dev/null 2>&1; then
  AUDIO_RECORD_OS_ID="$(pkg_detect_os_id 2>/dev/null || echo unknown)"
else
  AUDIO_RECORD_OS_ID="$(
    sed -n 's/^ID=//p' /etc/os-release 2>/dev/null |
      sed -n '1p' |
      sed 's/^"//;s/"$//' |
      tr '[:upper:]' '[:lower:]'
  )"
fi

if [ "$AUDIO_RECORD_OS_ID" = "debian" ]; then
  AUDIO_RECORD_DEBIAN_ROOT_MODE=1
fi

export AUDIO_RECORD_DEBIAN_ROOT_MODE

# Only this scratch directory is writable by the Debian Audio user. Root keeps
# ownership of the final LOGDIR, logs, summary, JUnit data, and promoted WAVs.
AUDIO_RECORD_USER_CAPTURE_DIR="$LOGDIR/.user-capture"
export AUDIO_RECORD_USER_CAPTURE_DIR

if [ "$AUDIO_RECORD_DEBIAN_ROOT_MODE" -eq 1 ]; then
  rm -rf "$AUDIO_RECORD_USER_CAPTURE_DIR"

  if ! mkdir -p "$AUDIO_RECORD_USER_CAPTURE_DIR"; then
    log_fail "$TESTNAME FAIL - failed to create Audio user capture directory"
    echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
    exit 1
  fi

  if ! chown "${AUDIO_TEST_USER:-debian}:audio" \
      "$AUDIO_RECORD_USER_CAPTURE_DIR"; then
    log_fail "$TESTNAME FAIL - failed to assign Audio user capture directory"
    echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
    exit 1
  fi

  if ! chmod 0770 "$AUDIO_RECORD_USER_CAPTURE_DIR"; then
    log_fail "$TESTNAME FAIL - failed to set Audio user capture directory mode"
    echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
    exit 1
  fi

  log_pass "Prepared Debian Audio capture workspace: $AUDIO_RECORD_USER_CAPTURE_DIR"
fi

# Debian overlay runtime preparation runs from the root orchestrator after
# normal CLI parsing. Only its device and PipeWire probes execute as debian.
if [ "$AUDIO_OVERLAY_REQUESTED" -eq 1 ]; then
  if ! command -v audio_prepare_overlay_runtime >/dev/null 2>&1; then
    log_fail "$TESTNAME FAIL - required helper is unavailable: audio_prepare_overlay_runtime"
    echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
    exit 1
  fi

  audio_prepare_overlay_runtime "$AUDIO_OVERLAY_REQUESTED"
  audio_runtime_rc=$?

  case "$audio_runtime_rc" in
    0)
      ;;
    2)
      log_skip "$TESTNAME SKIP - AudioReach kernel package changed, reboot required"
      echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
      exit 0
      ;;
    *)
      log_fail "$TESTNAME FAIL - AudioReach runtime preparation failed"
      echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
      exit 1
      ;;
  esac
elif [ "$SYSTEMD_AVAILABLE" -eq 1 ] &&
     [ "$AUDIO_RECORD_DEBIAN_ROOT_MODE" -ne 1 ]; then
  # Preserve the existing native/Yocto validation path. Debian base mode uses
  # command-level user probes during backend discovery instead.
  if ! setup_overlay_audio_environment; then
    log_warn "Existing overlay audio environment validation failed, continuing with backend recovery flow"
  fi
else
  log_info "systemd not available, skipping legacy overlay environment check"
fi

# Start an image-provisioned audio remoteproc before backend and device
# discovery. Platforms without an applicable remoteproc continue unchanged.
audio_prepare_audio_remoteproc
audio_remoteproc_rc=$?

case "$audio_remoteproc_rc" in
  0)
    ;;
  2)
    log_info "Audio remoteproc preflight not applicable: ${AUDIO_REMOTE_PROC_REASON:-no matching remoteproc}"
    ;;
  *)
    log_skip "$TESTNAME SKIP - audio remoteproc preflight failed: ${AUDIO_REMOTE_PROC_REASON:-unknown remoteproc error}"
    echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
    exit 0
    ;;
esac

# Minimal ramdisk detection and cleanup trap (kills any manually bootstrapped daemons)
if [ "$SYSTEMD_AVAILABLE" -eq 0 ]; then
  MINIMAL_RAMDISK_MODE=1
  export MINIMAL_RAMDISK_MODE
  log_info "Detected minimal ramdisk environment (systemd unavailable)"
else
  log_info "Detected standard userspace environment (systemd available)"
fi

trap 'audio_cleanup_started_daemons' EXIT HUP INT TERM

# Ensure we run from the testcase dir
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
if ! cd "$test_path"; then
  log_error "cd failed: $test_path"
  echo "$RESULT_TESTNAME FAIL" > "$RES_FILE"
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

# ------------- Mode Detection and Validation -------------

# Check for conflicting parameters (discovery vs legacy mode)
if { [ -n "$CONFIG_NAMES" ] || [ -n "$CONFIG_FILTER" ]; } && [ -n "$DURATIONS" ]; then
  log_error "Cannot mix config discovery parameters (--config-name, --config-filter) with legacy matrix parameters (--durations)"
  log_error "Please use either config discovery mode OR legacy matrix mode, not both"
  echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

# Set defaults for legacy mode parameters only if using legacy mode
if [ "$USE_CONFIG_DISCOVERY" = "false" ]; then
  DURATIONS="${DURATIONS:-short}" # label set OR numeric tokens when RECORD_SECONDS=auto
fi

# Determine whether to use config discovery or legacy matrix mode
if [ "$USE_CONFIG_DISCOVERY" = "auto" ]; then
  # Auto mode: use config discovery by default (no external dependencies needed)
  USE_CONFIG_DISCOVERY=true
  log_info "Auto-detected config discovery mode (testing all 10 record configs)"
fi

# Validate CLI option conflicts
if [ -n "$CONFIG_NAMES" ] && [ -n "$CONFIG_FILTER" ]; then
  log_warn "Both --config-name and --config-filter specified"
  log_info "Using --config-name (ignoring --config-filter)"
  CONFIG_FILTER=""
fi

log_info "Args: backend=${AUDIO_BACKEND:-auto} source=$SRC_CHOICE overlay=$AUDIO_OVERLAY_REQUESTED loops=$LOOPS durations='$DURATIONS' record_seconds=$RECORD_SECONDS timeout=$TIMEOUT strict=$STRICT signal_strict=$AUDIO_RECORD_STRICT_SIGNAL dmesg=$DMESG_SCAN bootstrap=$AUDIO_BOOTSTRAP_MODE runtime_dir=${AUDIO_RUNTIME_DIR:-auto}"

# Resolve backend (allow minimal-build ALSA capture fallback)
if [ -z "$AUDIO_BACKEND" ]; then
  AUDIO_BACKEND="$(audio_run_helper_as_test_user --require-session detect_audio_backend 2>/dev/null || echo "")"
fi

AUDIO_SYSTEMD_MANAGED=0
if [ -n "$AUDIO_BACKEND" ]; then
  if audio_backend_is_systemd_managed "$AUDIO_BACKEND"; then
    AUDIO_SYSTEMD_MANAGED=1
  fi
fi
export AUDIO_SYSTEMD_MANAGED

BACKENDS_TO_TRY="$(build_backend_chain 2>/dev/null || echo "")"
log_info "Backend fallback chain: ${BACKENDS_TO_TRY:-unknown}"

ALSA_CAPTURE_PROBED=0
AUDIO_ALSA_CAPTURE_DEVICE=""
AUDIO_ALSA_CAPTURE_FORMAT=""
AUDIO_ALSA_CAPTURE_RATE=""
AUDIO_ALSA_CAPTURE_CHANNELS=""
AUDIO_ALSA_CAPTURE_REASON=""

if [ -z "$AUDIO_BACKEND" ]; then
  if audio_record_bootstrap_backend_if_needed; then
    AUDIO_BACKEND="$(audio_run_helper_as_test_user --require-session detect_audio_backend 2>/dev/null || echo "")"
    audio_record_set_recovered_backend_management
  else
    if audio_record_probe_alsa_capture_profile; then
      ALSA_CAPTURE_PROBED=1
      AUDIO_BACKEND="alsa"
      AUDIO_SYSTEMD_MANAGED=0
      export AUDIO_SYSTEMD_MANAGED
      log_warn "$TESTNAME: no managed audio backend running - using direct ALSA capture path"
    else
      log_skip "$TESTNAME SKIP - no audio backend running and ALSA capture probe failed: ${AUDIO_ALSA_CAPTURE_REASON:-capture path unavailable}"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    fi
  fi
fi

log_info "Using backend: $AUDIO_BACKEND"

backend_ok=0
if [ "$AUDIO_BACKEND" = "alsa" ]; then
  if [ "$ALSA_CAPTURE_PROBED" -eq 1 ]; then
    backend_ok=1
  else
    if audio_record_probe_alsa_capture_profile; then
      ALSA_CAPTURE_PROBED=1
      backend_ok=1
    fi
  fi
else
  if audio_run_helper_as_test_user --require-session audio_backend_ready "$AUDIO_BACKEND"; then
    backend_ok=1
  else
    if audio_run_helper_as_test_user --require-session check_audio_daemon "$AUDIO_BACKEND"; then
      backend_ok=1
    fi
  fi
fi

if [ "$backend_ok" -ne 1 ] && [ -z "$AUDIO_BACKEND_REQUESTED" ] &&
   [ "$AUDIO_BACKEND" != "alsa" ]; then
  if [ "$SYSTEMD_AVAILABLE" -eq 1 ] && [ "${AUDIO_SYSTEMD_MANAGED:-0}" -eq 1 ]; then
    log_warn "$TESTNAME: backend not available ($AUDIO_BACKEND) - attempting restart+retry once"
    audio_record_restart_backend_best_effort "$AUDIO_BACKEND" >/dev/null 2>&1 || true
    audio_run_helper_as_test_user --require-session audio_wait_audio_ready 20 "$AUDIO_BACKEND" >/dev/null 2>&1 || true
    if audio_run_helper_as_test_user --require-session audio_backend_ready "$AUDIO_BACKEND"; then
      backend_ok=1
    else
      if audio_run_helper_as_test_user --require-session check_audio_daemon "$AUDIO_BACKEND"; then
        backend_ok=1
      fi
    fi
  else
    log_warn "$TESTNAME: backend not available ($AUDIO_BACKEND) - attempting manual bootstrap"
    if audio_record_bootstrap_backend_if_needed; then
      backend_ok=1
      audio_record_set_recovered_backend_management
      AUDIO_BACKEND="$(audio_run_helper_as_test_user --require-session detect_audio_backend 2>/dev/null || echo "$AUDIO_BACKEND")"
    fi
  fi
fi

if [ "$backend_ok" -ne 1 ] && [ "$AUDIO_BACKEND" != "alsa" ]; then
  if audio_record_probe_alsa_capture_profile; then
    ALSA_CAPTURE_PROBED=1
    AUDIO_BACKEND="alsa"
    AUDIO_SYSTEMD_MANAGED=0
    export AUDIO_SYSTEMD_MANAGED
    backend_ok=1
    log_warn "$TESTNAME: falling back to ALSA direct capture path"
  fi
fi

if [ "$backend_ok" -ne 1 ]; then
  if [ "$AUDIO_BACKEND" = "alsa" ] || [ "$ALSA_CAPTURE_PROBED" -eq 1 ]; then
    log_skip "$TESTNAME SKIP - ALSA capture path unavailable: ${AUDIO_ALSA_CAPTURE_REASON:-capture device could not be opened}"
  else
    log_skip "$TESTNAME SKIP - backend not available: $AUDIO_BACKEND"
  fi
  echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

# Dependencies per backend (include ALSA)
case "$AUDIO_BACKEND" in
  pipewire)
    if ! check_dependencies wpctl pw-record; then
      log_skip "$TESTNAME SKIP - missing PipeWire utils"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    fi
    ;;
  pulseaudio)
    if ! check_dependencies pactl parecord; then
      log_skip "$TESTNAME SKIP - missing PulseAudio utils"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    fi
    ;;
  alsa)
    if ! check_dependencies arecord; then
      log_skip "$TESTNAME SKIP - missing arecord"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    fi
    ;;
  *)
    log_skip "$TESTNAME SKIP - unsupported backend: $AUDIO_BACKEND"
    echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
    exit 0
    ;;
esac

# ----- Control-plane sanity (prevents wpctl/pactl hangs during source selection) -----
if [ "$AUDIO_BACKEND" = "pipewire" ]; then
  if ! audio_run_helper_as_test_user --require-session audio_pw_ctl_ok 2>/dev/null; then
    if [ "$SYSTEMD_AVAILABLE" -eq 1 ] && [ "${AUDIO_SYSTEMD_MANAGED:-0}" -eq 1 ]; then
      log_warn "$TESTNAME: wpctl not responsive - attempting restart+retry once"
      audio_record_restart_backend_best_effort "$AUDIO_BACKEND" >/dev/null 2>&1 || true
      audio_run_helper_as_test_user --require-session audio_wait_audio_ready 20 "$AUDIO_BACKEND" >/dev/null 2>&1 || true
    else
      log_warn "$TESTNAME: wpctl not responsive - attempting manual bootstrap"
      audio_record_bootstrap_backend_if_needed >/dev/null 2>&1 || true
      audio_record_set_recovered_backend_management
    fi
    if ! audio_run_helper_as_test_user --require-session audio_pw_ctl_ok 2>/dev/null; then
      log_skip "$TESTNAME SKIP - PipeWire control-plane not responsive"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    fi
  fi
elif [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
  if ! audio_run_helper_as_test_user --require-session audio_pa_ctl_ok 2>/dev/null; then
    if [ "$SYSTEMD_AVAILABLE" -eq 1 ] && [ "${AUDIO_SYSTEMD_MANAGED:-0}" -eq 1 ]; then
      log_warn "$TESTNAME: pactl not responsive - attempting restart+retry once"
      audio_record_restart_backend_best_effort "$AUDIO_BACKEND" >/dev/null 2>&1 || true
      audio_run_helper_as_test_user --require-session audio_wait_audio_ready 20 "$AUDIO_BACKEND" >/dev/null 2>&1 || true
    else
      log_warn "$TESTNAME: pactl not responsive - attempting manual bootstrap"
      audio_record_bootstrap_backend_if_needed >/dev/null 2>&1 || true
      audio_record_set_recovered_backend_management
    fi
    if ! audio_run_helper_as_test_user --require-session audio_pa_ctl_ok 2>/dev/null; then
      log_skip "$TESTNAME SKIP - PulseAudio control-plane not responsive"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    fi
  fi
fi

# ----- Route source (set default; recorder uses default source) -----
SRC_ID=""
case "$AUDIO_BACKEND:$SRC_CHOICE" in
  pipewire:null)
    SRC_ID="$(audio_run_helper_as_test_user --require-session pw_default_null_source)"
    ;;
  pipewire:*)
    SRC_ID="$(audio_run_helper_as_test_user --require-session pw_default_mic)"
    ;;
  pulseaudio:null)
    SRC_ID="$(audio_run_helper_as_test_user --require-session pa_default_null_source)"
    ;;
  pulseaudio:*)
    SRC_ID="$(audio_run_helper_as_test_user --require-session pa_default_mic)"
    ;;
  alsa:null)
    SRC_ID=""
    ;;
  alsa:*)
    if [ "$ALSA_CAPTURE_PROBED" -eq 1 ] && [ -n "$AUDIO_ALSA_CAPTURE_DEVICE" ]; then
      SRC_ID="$AUDIO_ALSA_CAPTURE_DEVICE"
    else
      SRC_ID="$(audio_run_helper_as_test_user alsa_pick_capture)"
    fi
    ;;
esac

# ---- Dynamic fallback when mic is missing on the chosen backend ----
# For real mic capture, do not allow PipeWire to record from an implicit
# default source when no concrete source was discovered. On systems without
# a real capture source, this can record from dummy/null/default paths or fail
# after creating empty files.
if [ -z "$SRC_ID" ] && [ -z "$AUDIO_BACKEND_REQUESTED" ] &&
   [ "$SRC_CHOICE" = "mic" ] && [ "$AUDIO_BACKEND" = "pipewire" ]; then
  log_warn "$TESTNAME: no concrete PipeWire mic source found, probing direct ALSA capture path"

  if audio_record_probe_alsa_capture_profile; then
    ALSA_CAPTURE_PROBED=1
    AUDIO_BACKEND="alsa"
    AUDIO_SYSTEMD_MANAGED=0
    export AUDIO_SYSTEMD_MANAGED

    SRC_ID="$AUDIO_ALSA_CAPTURE_DEVICE"
    SRC_LABEL="$SRC_ID"

    log_warn "$TESTNAME: falling back to direct ALSA capture device: $SRC_ID"
  else
    log_skip "$TESTNAME SKIP - no real capture source available, PipeWire mic source missing and ALSA capture probe failed: ${AUDIO_ALSA_CAPTURE_REASON:-capture path unavailable}"
    echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
    exit 0
  fi
fi

if [ -z "$SRC_ID" ] && [ -z "$AUDIO_BACKEND_REQUESTED" ] &&
   [ "$SRC_CHOICE" = "mic" ] && [ "$AUDIO_BACKEND" != "pipewire" ]; then
  for b in $BACKENDS_TO_TRY; do
    [ "$b" = "$AUDIO_BACKEND" ] && continue

    case "$b" in
      pipewire)
        cand="$(audio_run_helper_as_test_user --require-session pw_default_mic)"
        if [ -n "$cand" ]; then
          AUDIO_BACKEND="pipewire"
          SRC_ID="$cand"
          log_info "Falling back to backend: pipewire (source id=$SRC_ID)"
          break
        fi
        ;;
      pulseaudio)
        cand="$(audio_run_helper_as_test_user --require-session pa_default_mic)"
        if [ -n "$cand" ]; then
          AUDIO_BACKEND="pulseaudio"
          SRC_ID="$cand"
          log_info "Falling back to backend: pulseaudio (source=$SRC_ID)"
          break
        fi
        ;;
      alsa)
        if audio_record_probe_alsa_capture_profile; then
          ALSA_CAPTURE_PROBED=1
          AUDIO_BACKEND="alsa"
          AUDIO_SYSTEMD_MANAGED=0
          export AUDIO_SYSTEMD_MANAGED

          SRC_ID="$AUDIO_ALSA_CAPTURE_DEVICE"
          SRC_LABEL="$SRC_ID"

          log_info "Falling back to backend: alsa (device=$SRC_ID)"
          break
        fi
        ;;
    esac
  done
fi

if [ -z "$SRC_ID" ]; then
  log_skip "$TESTNAME SKIP - requested source '$SRC_CHOICE' not available on any backend (${BACKENDS_TO_TRY:-unknown})"
  echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

# Only skip if no source AND not on PipeWire.
if [ -z "$SRC_ID" ] && [ "$AUDIO_BACKEND" != "pipewire" ]; then
  log_skip "$TESTNAME SKIP - requested source '$SRC_CHOICE' not available on any backend (${BACKENDS_TO_TRY:-unknown})"
  echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

# ---- Normalize ALSA device id (fix "hw:0 1," → "hw:0,1") ----
if [ "$AUDIO_BACKEND" = "alsa" ]; then
  case "$SRC_ID" in
    hw:*" "*,)
      SRC_ID=$(printf '%s' "$SRC_ID" | sed 's/^hw:\([0-9][0-9]*\) \([0-9][0-9]*\),$/hw:\1,\2/')
      ;;
    hw:*" "*)
      SRC_ID=$(printf '%s' "$SRC_ID" | sed 's/^hw:\([0-9][0-9]*\) \([0-9][0-9]*\)$/hw:\1,\2/')
      ;;
  esac
fi

# ---- Validate/auto-pick ALSA device if invalid (prevents "hw:,") ----
if [ "$AUDIO_BACKEND" = "alsa" ]; then
  case "$SRC_ID" in
    hw:[0-9]*,[0-9]*|plughw:[0-9]*,[0-9]*)
      : ;;
    *)
      cand="$(audio_run_as_test_user arecord -l 2>/dev/null |
        sed -n 's/^card[[:space:]]*\([0-9][0-9]*\).*device[[:space:]]*\([0-9][0-9]*\).*/hw:\1,\2/p' |
        head -n 1)"
      if [ -z "$cand" ]; then
        cand="$(sed -n 's/^\([0-9][0-9]*\)-\([0-9][0-9]*\):.*capture.*/hw:\1,\2/p' /proc/asound/pcm 2>/dev/null | head -n 1)"
      fi
      if [ -n "$cand" ] && printf '%s\n' "$cand" | grep -Eq '^hw:[0-9][0-9]*,[0-9][0-9]*$'; then
        SRC_ID="$cand"
        log_info "ALSA auto-pick: using $SRC_ID"
      else
        log_skip "$TESTNAME SKIP - no valid ALSA capture device found"
        echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
        exit 0
      fi
      ;;
  esac
fi

# ---- Routing log / defaults per backend ----
if [ "$AUDIO_BACKEND" = "pipewire" ]; then
  if [ -n "$SRC_ID" ]; then
    SRC_LABEL="$(audio_run_helper_as_test_user --require-session pw_source_label_safe "$SRC_ID")"
    audio_run_helper_as_test_user --require-session pw_set_default_source "$SRC_ID" >/dev/null 2>&1 || true
    [ -z "$SRC_LABEL" ] && SRC_LABEL="unknown"
    log_info "Routing to source: id/name=$SRC_ID label='$SRC_LABEL' choice=$SRC_CHOICE"
  else
    SRC_LABEL="default"
    log_info "Routing to source: id/name=default label='default' choice=$SRC_CHOICE"
  fi
elif [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
  SRC_LABEL="$(audio_run_helper_as_test_user --require-session pa_source_name "$SRC_ID" 2>/dev/null || echo "$SRC_ID")"
  audio_run_helper_as_test_user --require-session pa_set_default_source "$SRC_ID" >/dev/null 2>&1 || true
  log_info "Routing to source: name='$SRC_LABEL' choice=$SRC_CHOICE"
else # ALSA
  SRC_LABEL="${SRC_ID:-default}"
  log_info "Routing to source: name='$SRC_LABEL' choice=$SRC_CHOICE"
fi

# If fallback changed backend, ensure deps are present (non-fatal → SKIP)
case "$AUDIO_BACKEND" in
  pipewire)
    if ! check_dependencies wpctl pw-record; then
      log_skip "$TESTNAME SKIP - missing PipeWire utils"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    fi
    ;;
  pulseaudio)
    if ! check_dependencies pactl parecord; then
      log_skip "$TESTNAME SKIP - missing PulseAudio utils"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    fi
    ;;
  alsa)
    if ! check_dependencies arecord; then
      log_skip "$TESTNAME SKIP - missing arecord"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    fi
    ;;
esac

# Watchdog info
dur_s="$(duration_to_secs "$TIMEOUT" 2>/dev/null || echo 0)"
[ -z "$dur_s" ] && dur_s=0
if [ "$dur_s" -gt 0 ] 2>/dev/null; then
  log_info "Watchdog/timeout: ${TIMEOUT}"
else
  log_info "Watchdog/timeout: disabled (no timeout)"
fi

# JUnit init (optional)
if [ -n "$JUNIT_OUT" ]; then
  JUNIT_TMP="$LOGDIR/.junit_cases.xml"
  : > "$JUNIT_TMP"
fi

append_junit() {
  name="$1"
  elapsed="$2"
  status="$3"
  logf="$4"

  if [ -z "$JUNIT_OUT" ]; then
    return 0
  fi

  safe_msg="$(
    tail -n 50 "$logf" 2>/dev/null \
      | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g'
  )"

  {
    printf ' <testcase classname="%s" name="%s" time="%s">\n' "Audio.Record" "$name" "$elapsed"
    case "$status" in
      PASS) : ;;
      SKIP) printf ' <skipped/>\n' ;;
      FAIL)
        printf ' <failure message="%s">\n' "failed"
        printf '%s\n' "$safe_msg"
        printf ' </failure>\n'
        ;;
    esac
    printf ' </testcase>\n'
  } >> "$JUNIT_TMP"
}

# Auto map if RECORD_SECONDS=auto, and accept numeric tokens like 35s/35sec/35secs/35seconds
auto_secs_for() {
  case "$1" in
    short) echo "5s" ;;
    medium) echo "15s" ;;
    long) echo "30s" ;;
    *) echo "5s" ;;
  esac
}

# Validate the final capture selected by the existing backend/retry flow.
# Size remains useful only for deciding whether compatibility fallbacks should
# run; PASS requires a structurally valid WAV with acceptable sample content.
audio_record_validate_final_output() {
  recording_valid=0
  validation_expected_duration="$secs"
  validation_requested_seconds="$(audio_parse_secs "$secs" 2>/dev/null || echo 0)"
  validation_timeout_seconds="$(audio_parse_secs "$effective_timeout" 2>/dev/null || echo 0)"

  [ -n "$validation_requested_seconds" ] || validation_requested_seconds=0
  [ -n "$validation_timeout_seconds" ] || validation_timeout_seconds=0

  if [ "$validation_timeout_seconds" -gt 0 ] 2>/dev/null &&
     { [ "$validation_requested_seconds" -le 0 ] 2>/dev/null ||
       [ "$validation_timeout_seconds" -lt "$validation_requested_seconds" ] 2>/dev/null; }; then
    validation_expected_duration="$effective_timeout"
  fi

  AUDIO_WAV_VALIDATION_SUMMARY="AUDIO_WAV_VALIDATION status=FAIL reason=not-run"
  export AUDIO_WAV_VALIDATION_SUMMARY

  if audio_validate_recording_result \
      "$record_out" \
      "$SRC_CHOICE" \
      "${validation_rate:-0}" \
      "${validation_channels:-0}" \
      "$validation_expected_duration" \
      "$rc" \
      "$effective_timeout" \
      "$logf"; then
    recording_valid=1

    case "$rc" in
      124|137|143)
        # Normalize an expected watchdog stop only after WAV validation passes.
        rc=0
        ;;
    esac
  fi
}

# ------------- Test Execution (Matrix or Config Discovery) -------------
total=0
pass=0
fail=0
skip=0
suite_rc=0

if [ "$USE_CONFIG_DISCOVERY" = "true" ]; then
  # ========== NEW: Config Discovery Mode ==========
  log_info "Using config discovery mode"

  # Discover and filter configs
  if [ -n "$CONFIG_NAMES" ] || [ -n "$CONFIG_FILTER" ]; then
    CONFIGS_TO_TEST="$(discover_and_filter_record_configs "$CONFIG_NAMES" "$CONFIG_FILTER")" || {
      log_skip "$TESTNAME SKIP - Invalid config name(s) provided"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    }
  else
    CONFIGS_TO_TEST="$(discover_record_configs)" || {
      log_skip "$TESTNAME SKIP - No record configs found"
      echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
      exit 0
    }
  fi

  if [ -z "$CONFIGS_TO_TEST" ]; then
    log_skip "$TESTNAME SKIP - No valid record configs found"
    echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
    exit 0
  fi

  # Count configs
  config_count=0
  for config in $CONFIGS_TO_TEST; do
    config_count=$((config_count + 1))
  done

  log_info "Discovered $config_count configs to test"

  # Test each config
  for config in $CONFIGS_TO_TEST; do
    case_name="$(generate_record_testcase_name "$config")" || {
      log_warn "Skipping config with invalid name: $config"
      echo "$config SKIP (invalid config name)" >> "$LOGDIR/summary.txt"
      skip=$((skip + 1))
      continue
    }

    params="$(get_record_config_params "$config")" || {
      log_warn "Skipping config with invalid parameters: $config"
      echo "$config SKIP (invalid config parameters)" >> "$LOGDIR/summary.txt"
      skip=$((skip + 1))
      continue
    }

    rate="$(printf '%s' "$params" | awk '{print $1}')"
    channels="$(printf '%s' "$params" | awk '{print $2}')"

    total=$((total + 1))
    logf="$LOGDIR/${case_name}.log"
    : > "$logf"
    export AUDIO_LOGCTX="$logf"

    log_info "[$case_name] Using config: $config (rate=${rate}Hz channels=$channels)"

    # Determine recording duration
    secs="$RECORD_SECONDS"
    if [ "$secs" = "auto" ]; then
      secs="5s" # Default for config discovery mode
    fi

    i=1
    ok_runs=0
    last_elapsed=0

    while [ "$i" -le "$LOOPS" ]; do
      iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      effective_timeout="$secs"
      if [ -n "$TIMEOUT" ] && [ "$TIMEOUT" != "0" ]; then
        effective_timeout="$TIMEOUT"
      fi

      loop_hdr="source=$SRC_CHOICE"
      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        if [ -n "$SRC_ID" ]; then
          loop_hdr="$loop_hdr($SRC_ID)"
        else
          loop_hdr="$loop_hdr(default)"
        fi
      else
        loop_hdr="$loop_hdr($SRC_LABEL)"
      fi

      log_info "[$case_name] loop $i/$LOOPS start=$iso rate=${rate}Hz channels=$channels backend=$AUDIO_BACKEND $loop_hdr"

      audio_record_set_capture_paths "$case_name"
      audio_record_reset_capture_output
      start_s="$(date +%s 2>/dev/null || echo 0)"
      validation_rate="$rate"
      validation_channels="$channels"

      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        log_info "[$case_name] exec: pw-record -v --rate=$rate --channels=$channels \"$record_user_out\""
        audio_run_with_timeout_as_test_user --require-session "$effective_timeout" pw-record -v --rate="$rate" --channels="$channels" "$record_user_out" >> "$logf" 2>&1
        rc=$?
        bytes="$(audio_record_capture_size)"

        # Restart/bootstrap only for an unexpected pw-record failure when the
        # PipeWire control plane is also unresponsive. Watchdog termination is
        # expected and must proceed to WAV validation without restarting.
        record_command_failed=0

        case "$rc" in
          0|124|137|143)
            ;;
          *)
            record_command_failed=1
            ;;
        esac

        if [ "$record_command_failed" -eq 1 ] &&
           ! audio_run_helper_as_test_user \
               --require-session \
               audio_pw_ctl_ok 2>/dev/null; then
          if [ "$SYSTEMD_AVAILABLE" -eq 1 ] && [ "${AUDIO_SYSTEMD_MANAGED:-0}" -eq 1 ]; then
            log_warn "[$case_name] pw-record rc=$rc and wpctl not responsive - restarting and retrying once"
            audio_record_restart_backend_best_effort "$AUDIO_BACKEND" >/dev/null 2>&1 || true
            audio_run_helper_as_test_user --require-session audio_wait_audio_ready 20 "$AUDIO_BACKEND" >/dev/null 2>&1 || true
          else
            log_warn "[$case_name] pw-record rc=$rc and wpctl not responsive - attempting bootstrap and retrying once"
            audio_record_bootstrap_backend_if_needed >/dev/null 2>&1 || true
            audio_record_set_recovered_backend_management
          fi

          audio_record_set_capture_paths "$case_name"
          audio_record_reset_capture_output
          log_info "[$case_name] retry: pw-record -v --rate=$rate --channels=$channels \"$record_user_out\""
          audio_run_with_timeout_as_test_user --require-session "$effective_timeout" pw-record -v --rate="$rate" --channels="$channels" "$record_user_out" >> "$logf" 2>&1
          rc=$?
          bytes="$(audio_record_capture_size)"
        fi

        # A non-trivial file skips compatibility fallbacks. Content and
        # recorder status are validated after the backend flow completes.
        if [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
          :
        else
          # Only if output is tiny/empty do we try a virtual PCM
          if command -v arecord >/dev/null 2>&1; then
            pcm="$(audio_run_helper_as_test_user alsa_pick_virtual_pcm || true)"
            if [ -n "$pcm" ]; then
              secs_int="$(audio_parse_secs "$secs" 2>/dev/null || echo 0)"
              [ -z "$secs_int" ] && secs_int=0
              audio_record_reset_capture_output
              log_info "[$case_name] fallback: arecord -D $pcm -f S16_LE -r $rate -c $channels -d $secs_int \"$record_user_out\""
              audio_run_with_timeout_as_test_user "$effective_timeout" \
                arecord -D "$pcm" -f S16_LE -r "$rate" -c "$channels" -d "$secs_int" "$record_user_out" >> "$logf" 2>&1
              rc=$?
              bytes="$(audio_record_capture_size)"
            fi
          fi

          # As a last resort, retry pw-record with --target (only if we have a source id)
          retry_target=0
          if [ "$rc" -ne 0 ]; then
            retry_target=1
          else
            if [ "${bytes:-0}" -le 1024 ] 2>/dev/null; then
              retry_target=1
            fi
          fi
          if [ "$retry_target" -eq 1 ] && [ -n "$SRC_ID" ]; then
            audio_record_reset_capture_output
            log_info "[$case_name] exec: pw-record -v --rate=$rate --channels=$channels --target \"$SRC_ID\" \"$record_user_out\""
            audio_run_with_timeout_as_test_user --require-session "$effective_timeout" pw-record -v --rate="$rate" --channels="$channels" --target "$SRC_ID" "$record_user_out" >> "$logf" 2>&1
            rc=$?
            bytes="$(audio_record_capture_size)"
          fi
        fi

      else
        if [ "$AUDIO_BACKEND" = "alsa" ]; then
          secs_int="$(audio_parse_secs "$secs" 2>/dev/null || echo 0)"
          [ -z "$secs_int" ] && secs_int=0
          log_info "[$case_name] exec: arecord -D \"$SRC_ID\" -f S16_LE -r $rate -c $channels -d $secs_int \"$record_user_out\""
          audio_run_with_timeout_as_test_user "$effective_timeout" \
            arecord -D "$SRC_ID" -f S16_LE -r "$rate" -c "$channels" -d "$secs_int" "$record_user_out" >> "$logf" 2>&1
          rc=$?
          bytes="$(audio_record_capture_size)"

          retry_alsa=0
          if [ "$rc" -ne 0 ]; then
            retry_alsa=1
          else
            if [ "${bytes:-0}" -le 1024 ] 2>/dev/null; then
              retry_alsa=1
            fi
          fi

          if [ "$retry_alsa" -eq 1 ]; then
            if printf '%s\n' "$SRC_ID" | grep -q '^hw:'; then
              alt_dev="plughw:${SRC_ID#hw:}"
            else
              alt_dev="$SRC_ID"
            fi

            audio_record_reset_capture_output
            log_info "[$case_name] retry: arecord -D \"$alt_dev\" -f S16_LE -r $rate -c $channels -d $secs_int \"$record_user_out\""
            audio_run_with_timeout_as_test_user "$effective_timeout" \
              arecord -D "$alt_dev" -f S16_LE -r "$rate" -c "$channels" -d "$secs_int" "$record_user_out" >> "$logf" 2>&1
            rc=$?
            bytes="$(audio_record_capture_size)"

            retry_fallback=0
            if [ "$rc" -ne 0 ]; then
              retry_fallback=1
            else
              if [ "${bytes:-0}" -le 1024 ] 2>/dev/null; then
                retry_fallback=1
              fi
            fi

            if [ "$retry_fallback" -eq 1 ]; then
              for combo in \
                "${AUDIO_ALSA_CAPTURE_FORMAT:-S16_LE} ${AUDIO_ALSA_CAPTURE_RATE:-48000} ${AUDIO_ALSA_CAPTURE_CHANNELS:-2}" \
                "S16_LE 48000 2" \
                "S16_LE 44100 2" \
                "S16_LE 16000 1"
              do
                fmt="$(printf '%s\n' "$combo" | awk '{print $1}')"
                fallback_rate="$(printf '%s\n' "$combo" | awk '{print $2}')"
                fallback_ch="$(printf '%s\n' "$combo" | awk '{print $3}')"
                [ -z "$fmt" ] || [ -z "$fallback_rate" ] || [ -z "$fallback_ch" ] && continue

                audio_record_reset_capture_output
                log_info "[$case_name] fallback: arecord -D \"$alt_dev\" -f $fmt -r $fallback_rate -c $fallback_ch -d $secs_int \"$record_user_out\""
                audio_run_with_timeout_as_test_user "$effective_timeout" \
                  arecord -D "$alt_dev" -f "$fmt" -r "$fallback_rate" -c "$fallback_ch" -d "$secs_int" "$record_user_out" >> "$logf" 2>&1
                rc=$?
                bytes="$(audio_record_capture_size)"
                validation_rate="$fallback_rate"
                validation_channels="$fallback_ch"
                if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
                  break
                fi
              done
            fi
          fi

        else
          # PulseAudio
          log_info "[$case_name] exec: parecord --rate=$rate --channels=$channels --file-format=wav \"$record_user_out\""
          audio_run_with_timeout_as_test_user --require-session "$effective_timeout" parecord --rate="$rate" --channels="$channels" --file-format=wav "$record_user_out" >> "$logf" 2>&1
          rc=$?
          bytes="$(audio_record_capture_size)"

          # If parecord failed AND PulseAudio control-plane is broken, restart/bootstrap and retry once
          if [ "$rc" -ne 0 ] &&
             ! audio_run_helper_as_test_user --require-session audio_pa_ctl_ok 2>/dev/null; then
            if [ "$SYSTEMD_AVAILABLE" -eq 1 ] && [ "${AUDIO_SYSTEMD_MANAGED:-0}" -eq 1 ]; then
              log_warn "[$case_name] parecord rc=$rc and pactl not responsive - restarting and retrying once"
              audio_record_restart_backend_best_effort "$AUDIO_BACKEND" >/dev/null 2>&1 || true
              audio_run_helper_as_test_user --require-session audio_wait_audio_ready 20 "$AUDIO_BACKEND" >/dev/null 2>&1 || true
            else
              log_warn "[$case_name] parecord rc=$rc and pactl not responsive - attempting bootstrap and retrying once"
              audio_record_bootstrap_backend_if_needed >/dev/null 2>&1 || true
              audio_record_set_recovered_backend_management
            fi

            audio_record_set_capture_paths "$case_name"
            audio_record_reset_capture_output
            log_info "[$case_name] retry: parecord --rate=$rate --channels=$channels --file-format=wav \"$record_user_out\""
            audio_run_with_timeout_as_test_user --require-session "$effective_timeout" parecord --rate="$rate" --channels="$channels" --file-format=wav "$record_user_out" >> "$logf" 2>&1
            rc=$?
            bytes="$(audio_record_capture_size)"
          fi

        fi
      fi

      if ! audio_record_promote_capture_output; then
        rc=1
        bytes=0
      fi

      end_s="$(date +%s 2>/dev/null || echo 0)"
      last_elapsed=$((end_s - start_s))
      [ "$last_elapsed" -lt 0 ] && last_elapsed=0

      audio_record_validate_final_output

      # Evidence
      pw_ev="$(audio_run_helper_as_test_user --require-session audio_evidence_pw_streaming || echo 0)"
      pa_ev="$(audio_run_helper_as_test_user --require-session audio_evidence_pa_streaming || echo 0)"
      if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 0 ]; then
        if [ "$recording_valid" -eq 1 ]; then
          pa_ev=1
        fi
      fi
      alsa_ev="$(audio_evidence_alsa_running_any || echo 0)"
      asoc_ev="$(audio_evidence_asoc_path_on || echo 0)"
      pwlog_ev="$(audio_run_helper_as_test_user --require-session audio_evidence_pw_log_seen || echo 0)"
      if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
        pwlog_ev=0
      fi

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

      log_info "[$case_name] evidence: pw_streaming=$pw_ev pa_streaming=$pa_ev alsa_running=$alsa_ev asoc_path_on=$asoc_ev bytes=${bytes:-0} pw_log=$pwlog_ev validation='${AUDIO_WAV_VALIDATION_SUMMARY:-unavailable}'"

      if [ "$recording_valid" -eq 1 ]; then
        log_pass "[$case_name] loop $i OK (rc=$rc, ${last_elapsed}s, bytes=$bytes, WAV payload validated)"
        ok_runs=$((ok_runs + 1))
      else
        log_fail "[$case_name] loop $i FAILED (rc=$rc, ${last_elapsed}s, bytes=${bytes:-0}, validation='${AUDIO_WAV_VALIDATION_SUMMARY:-unavailable}') - see $logf"
      fi

      i=$((i + 1))
    done

    # Aggregate result for this config
    status="FAIL"
    if [ "$ok_runs" -ge 1 ]; then
      status="PASS"
    fi

    append_junit "$case_name" "$last_elapsed" "$status" "$logf"

    case "$status" in
      PASS)
        pass=$((pass + 1))
        echo "$case_name PASS" >> "$LOGDIR/summary.txt"
        ;;
      SKIP)
        skip=$((skip + 1))
        echo "$case_name SKIP" >> "$LOGDIR/summary.txt"
        ;;
      FAIL)
        fail=$((fail + 1))
        echo "$case_name FAIL" >> "$LOGDIR/summary.txt"
        suite_rc=1
        ;;
    esac
  done

else
  # ========== LEGACY: Matrix Mode ==========
  for dur in $DURATIONS; do
    case_name="record_${dur}"
    total=$((total + 1))
    logf="$LOGDIR/${case_name}.log"
    : > "$logf"
    export AUDIO_LOGCTX="$logf"

    secs="$RECORD_SECONDS"
    if [ "$secs" = "auto" ]; then
      tok="$(printf '%s' "$dur" | tr '[:upper:]' '[:lower:]')"
      tok_secs="$(printf '%s' "$tok" | sed -n 's/^\([0-9][0-9]*\)\(s\|sec\|secs\|seconds\)$/\1s/p')"
      if [ -n "$tok_secs" ]; then
        secs="$tok_secs"
      else
        secs="$(auto_secs_for "$dur")"
      fi
    fi

    i=1
    ok_runs=0
    last_elapsed=0

    while [ "$i" -le "$LOOPS" ]; do
      iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      effective_timeout="$secs"
      if [ -n "$TIMEOUT" ] && [ "$TIMEOUT" != "0" ]; then
        effective_timeout="$TIMEOUT"
      fi

      loop_hdr="source=$SRC_CHOICE"
      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        if [ -n "$SRC_ID" ]; then
          loop_hdr="$loop_hdr($SRC_ID)"
        else
          loop_hdr="$loop_hdr(default)"
        fi
      else
        loop_hdr="$loop_hdr($SRC_LABEL)"
      fi

      log_info "[$case_name] loop $i/$LOOPS start=$iso secs=$secs backend=$AUDIO_BACKEND $loop_hdr"

      audio_record_set_capture_paths "$case_name"
      audio_record_reset_capture_output
      start_s="$(date +%s 2>/dev/null || echo 0)"
      validation_rate=0
      validation_channels=0

      if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        log_info "[$case_name] exec: pw-record -v \"$record_user_out\""
        audio_run_with_timeout_as_test_user --require-session "$effective_timeout" pw-record -v "$record_user_out" >> "$logf" 2>&1
        rc=$?
        bytes="$(audio_record_capture_size)"

        # Restart/bootstrap only for an unexpected pw-record failure when the
        # PipeWire control plane is also unresponsive. Watchdog termination is
        # expected and must proceed to WAV validation without restarting.
        record_command_failed=0

        case "$rc" in
          0|124|137|143)
            ;;
          *)
            record_command_failed=1
            ;;
        esac

        if [ "$record_command_failed" -eq 1 ] &&
           ! audio_run_helper_as_test_user \
               --require-session \
               audio_pw_ctl_ok 2>/dev/null; then
          if [ "$SYSTEMD_AVAILABLE" -eq 1 ] && [ "${AUDIO_SYSTEMD_MANAGED:-0}" -eq 1 ]; then
            log_warn "[$case_name] pw-record rc=$rc and wpctl not responsive - restarting and retrying once"
            audio_record_restart_backend_best_effort "$AUDIO_BACKEND" >/dev/null 2>&1 || true
            audio_run_helper_as_test_user --require-session audio_wait_audio_ready 20 "$AUDIO_BACKEND" >/dev/null 2>&1 || true
          else
            log_warn "[$case_name] pw-record rc=$rc and wpctl not responsive - attempting bootstrap and retrying once"
            audio_record_bootstrap_backend_if_needed >/dev/null 2>&1 || true
            audio_record_set_recovered_backend_management
          fi

          audio_record_set_capture_paths "$case_name"
          audio_record_reset_capture_output
          log_info "[$case_name] retry: pw-record -v \"$record_user_out\""
          audio_run_with_timeout_as_test_user --require-session "$effective_timeout" pw-record -v "$record_user_out" >> "$logf" 2>&1
          rc=$?
          bytes="$(audio_record_capture_size)"
        fi

        # A non-trivial file skips compatibility fallbacks. Content and
        # recorder status are validated after the backend flow completes.
        if [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
          :
        else
          # Only if output is tiny/empty do we try a virtual PCM
          if command -v arecord >/dev/null 2>&1; then
            pcm="$(audio_run_helper_as_test_user alsa_pick_virtual_pcm || true)"
            if [ -n "$pcm" ]; then
              secs_int="$(audio_parse_secs "$secs" 2>/dev/null || echo 0)"
              [ -z "$secs_int" ] && secs_int=0
              audio_record_reset_capture_output
              log_info "[$case_name] fallback: arecord -D $pcm -f S16_LE -r 48000 -c 2 -d $secs_int \"$record_user_out\""
              audio_run_with_timeout_as_test_user "$effective_timeout" \
                arecord -D "$pcm" -f S16_LE -r 48000 -c 2 -d "$secs_int" "$record_user_out" >> "$logf" 2>&1
              rc=$?
              bytes="$(audio_record_capture_size)"
              validation_rate=48000
              validation_channels=2
            fi
          fi

          # As a last resort, retry pw-record with --target (only if we have a source id)
          retry_target=0
          if [ "$rc" -ne 0 ]; then
            retry_target=1
          else
            if [ "${bytes:-0}" -le 1024 ] 2>/dev/null; then
              retry_target=1
            fi
          fi
          if [ "$retry_target" -eq 1 ] && [ -n "$SRC_ID" ]; then
            audio_record_reset_capture_output
            log_info "[$case_name] exec: pw-record -v --target \"$SRC_ID\" \"$record_user_out\""
            audio_run_with_timeout_as_test_user --require-session "$effective_timeout" pw-record -v --target "$SRC_ID" "$record_user_out" >> "$logf" 2>&1
            rc=$?
            bytes="$(audio_record_capture_size)"
          fi
        fi

      else
        if [ "$AUDIO_BACKEND" = "alsa" ]; then
          secs_int="$(audio_parse_secs "$secs" 2>/dev/null || echo 0)"
          [ -z "$secs_int" ] && secs_int=0
          log_info "[$case_name] exec: arecord -D \"$SRC_ID\" -f S16_LE -r 48000 -c 2 -d $secs_int \"$record_user_out\""
          audio_run_with_timeout_as_test_user "$effective_timeout" \
            arecord -D "$SRC_ID" -f S16_LE -r 48000 -c 2 -d "$secs_int" "$record_user_out" >> "$logf" 2>&1
          rc=$?
          bytes="$(audio_record_capture_size)"
          validation_rate=48000
          validation_channels=2

          retry_alsa=0
          if [ "$rc" -ne 0 ]; then
            retry_alsa=1
          else
            if [ "${bytes:-0}" -le 1024 ] 2>/dev/null; then
              retry_alsa=1
            fi
          fi

          if [ "$retry_alsa" -eq 1 ]; then
            if printf '%s\n' "$SRC_ID" | grep -q '^hw:'; then
              alt_dev="plughw:${SRC_ID#hw:}"
            else
              alt_dev="$SRC_ID"
            fi

            for combo in \
              "${AUDIO_ALSA_CAPTURE_FORMAT:-S16_LE} ${AUDIO_ALSA_CAPTURE_RATE:-48000} ${AUDIO_ALSA_CAPTURE_CHANNELS:-2}" \
              "S16_LE 48000 2" \
              "S16_LE 44100 2" \
              "S16_LE 16000 1"
            do
              fmt="$(printf '%s\n' "$combo" | awk '{print $1}')"
              rate="$(printf '%s\n' "$combo" | awk '{print $2}')"
              ch="$(printf '%s\n' "$combo" | awk '{print $3}')"
              [ -z "$fmt" ] || [ -z "$rate" ] || [ -z "$ch" ] && continue

              audio_record_reset_capture_output
              log_info "[$case_name] retry: arecord -D \"$alt_dev\" -f $fmt -r $rate -c $ch -d $secs_int \"$record_user_out\""
              audio_run_with_timeout_as_test_user "$effective_timeout" \
                arecord -D "$alt_dev" -f "$fmt" -r "$rate" -c "$ch" -d "$secs_int" "$record_user_out" >> "$logf" 2>&1
              rc=$?
              bytes="$(audio_record_capture_size)"
              validation_rate="$rate"
              validation_channels="$ch"
              if [ "$rc" -eq 0 ] && [ "${bytes:-0}" -gt 1024 ] 2>/dev/null; then
                break
              fi
            done
          fi

        else
          # PulseAudio
          log_info "[$case_name] exec: parecord --file-format=wav \"$record_user_out\""
          audio_run_with_timeout_as_test_user --require-session "$effective_timeout" parecord --file-format=wav "$record_user_out" >> "$logf" 2>&1
          rc=$?
          bytes="$(audio_record_capture_size)"

          # If parecord failed AND PulseAudio control-plane is broken, restart/bootstrap and retry once
          if [ "$rc" -ne 0 ] &&
             ! audio_run_helper_as_test_user --require-session audio_pa_ctl_ok 2>/dev/null; then
            if [ "$SYSTEMD_AVAILABLE" -eq 1 ] && [ "${AUDIO_SYSTEMD_MANAGED:-0}" -eq 1 ]; then
              log_warn "[$case_name] parecord rc=$rc and pactl not responsive - restarting and retrying once"
              audio_record_restart_backend_best_effort "$AUDIO_BACKEND" >/dev/null 2>&1 || true
              audio_run_helper_as_test_user --require-session audio_wait_audio_ready 20 "$AUDIO_BACKEND" >/dev/null 2>&1 || true
            else
              log_warn "[$case_name] parecord rc=$rc and pactl not responsive - attempting bootstrap and retrying once"
              audio_record_bootstrap_backend_if_needed >/dev/null 2>&1 || true
              audio_record_set_recovered_backend_management
            fi

            audio_record_set_capture_paths "$case_name"
            audio_record_reset_capture_output
            log_info "[$case_name] retry: parecord --file-format=wav \"$record_user_out\""
            audio_run_with_timeout_as_test_user --require-session "$effective_timeout" parecord --file-format=wav "$record_user_out" >> "$logf" 2>&1
            rc=$?
            bytes="$(audio_record_capture_size)"
          fi

        fi
      fi

      if ! audio_record_promote_capture_output; then
        rc=1
        bytes=0
      fi

      end_s="$(date +%s 2>/dev/null || echo 0)"
      last_elapsed=$((end_s - start_s))
      [ "$last_elapsed" -lt 0 ] && last_elapsed=0

      audio_record_validate_final_output

      # Evidence
      pw_ev="$(audio_run_helper_as_test_user --require-session audio_evidence_pw_streaming || echo 0)"
      pa_ev="$(audio_run_helper_as_test_user --require-session audio_evidence_pa_streaming || echo 0)"
      if [ "$AUDIO_BACKEND" = "pulseaudio" ] && [ "$pa_ev" -eq 0 ]; then
        if [ "$recording_valid" -eq 1 ]; then
          pa_ev=1
        fi
      fi
      alsa_ev="$(audio_evidence_alsa_running_any || echo 0)"
      asoc_ev="$(audio_evidence_asoc_path_on || echo 0)"
      pwlog_ev="$(audio_run_helper_as_test_user --require-session audio_evidence_pw_log_seen || echo 0)"
      if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
        pwlog_ev=0
      fi

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

      log_info "[$case_name] evidence: pw_streaming=$pw_ev pa_streaming=$pa_ev alsa_running=$alsa_ev asoc_path_on=$asoc_ev bytes=${bytes:-0} pw_log=$pwlog_ev validation='${AUDIO_WAV_VALIDATION_SUMMARY:-unavailable}'"

      if [ "$recording_valid" -eq 1 ]; then
        log_pass "[$case_name] loop $i OK (rc=$rc, ${last_elapsed}s, bytes=$bytes, WAV payload validated)"
        ok_runs=$((ok_runs + 1))
      else
        log_fail "[$case_name] loop $i FAILED (rc=$rc, ${last_elapsed}s, bytes=${bytes:-0}, validation='${AUDIO_WAV_VALIDATION_SUMMARY:-unavailable}') - see $logf"
      fi

      i=$((i + 1))
    done

    # Aggregate result for this duration
    status="FAIL"
    if [ "$ok_runs" -ge 1 ]; then
      status="PASS"
    fi

    append_junit "$case_name" "$last_elapsed" "$status" "$logf"

    case "$status" in
      PASS)
        pass=$((pass + 1))
        echo "$case_name PASS" >> "$LOGDIR/summary.txt"
        ;;
      SKIP)
        skip=$((skip + 1))
        echo "$case_name SKIP" >> "$LOGDIR/summary.txt"
        ;;
      FAIL)
        fail=$((fail + 1))
        echo "$case_name FAIL" >> "$LOGDIR/summary.txt"
        suite_rc=1
        ;;
    esac
  done
fi

# Collect evidence once at end
if [ "$DMESG_SCAN" -eq 1 ]; then
  scan_audio_dmesg "$LOGDIR"
  audio_record_dump_mixers "$LOGDIR/mixer_dump.txt"
fi

# JUnit finalize (optional)
if [ -n "$JUNIT_OUT" ]; then
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites>\n'
    printf '<testsuite name="%s" tests="%d" failures="%d" skipped="%d">\n' "Audio.Record" "$total" "$fail" "$skip"
    cat "$JUNIT_TMP"
    printf '</testsuite>\n'
    printf '</testsuites>\n'
  } > "$JUNIT_OUT"
  rm -f "$JUNIT_TMP"
fi

log_info "Summary: total=$total pass=$pass fail=$fail skip=$skip"

# --- Proper exit codes: PASS=0, FAIL=1, SKIP-only=0 ---
if [ "$total" -eq 0 ] && [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then
  log_skip "$TESTNAME SKIP - no runnable record testcases"
  echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ] && [ "$skip" -gt 0 ]; then
  log_skip "$TESTNAME SKIP"
  echo "$RESULT_TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

if [ "$suite_rc" -eq 0 ]; then
  log_pass "$TESTNAME PASS"
  echo "$RESULT_TESTNAME PASS" > "$RES_FILE"
  exit 0
fi

log_fail "$TESTNAME FAIL"
echo "$RESULT_TESTNAME FAIL" > "$RES_FILE"
exit 1
