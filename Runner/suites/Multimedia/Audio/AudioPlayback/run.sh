#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Locate and source init_env
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then
    INIT_ENV="$SEARCH/init_env"
    break
  fi
  SEARCH=$(dirname "$SEARCH")
done
[ -z "$INIT_ENV" ] && echo "[ERROR] init_env not found" && exit 1
# shellcheck source=/dev/null
[ -z "$__INIT_ENV_LOADED" ] && . "$INIT_ENV"

. "$TOOLS/functestlib.sh"
. "$TOOLS/libaudio.sh"

# Override with BusyBox-compatible version
check_network_status() {
    ip addr | awk '/state UP/ {iface=$2} /inet / {if (iface) print iface; iface=""}' | cut -d: -f1 | head -n 1
}

# Set TESTNAME
TESTNAME="AudioPlayback"

# Usage help
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --backend {pulseaudio|pipewire}
  --loops N
  --timeout SECS
  --volume VAL (PA: 0-65536, PW: 0.0-1.0)
EOF
}

# Parse CLI args
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) export AUDIO_BACKEND="$2"; shift 2 ;;
    --loops) export PLAYBACK_LOOPS="$2"; shift 2 ;;
    --timeout) export PLAYBACK_TIMEOUT="$2"; shift 2 ;;
    --volume) export PLAYBACK_VOLUME="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Fallback to env if not set
export AUDIO_BACKEND="${AUDIO_BACKEND:-pipewire}"

log_info "---------------- Starting $TESTNAME Testcase ----------------"
log_info "Using audio backend: $AUDIO_BACKEND"

init_audio_env "$TESTNAME" "$AUDIO_BACKEND"
audio_playback

log_info "---------------- Completed $TESTNAME Testcase ----------------"
