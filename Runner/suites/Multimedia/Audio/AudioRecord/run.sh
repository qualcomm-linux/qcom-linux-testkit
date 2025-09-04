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

# Source shared libraries						 
. "$TOOLS/functestlib.sh"
. "$TOOLS/libaudio.sh"

# Set TESTNAME
TESTNAME="AudioRecord"

# Usage help
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --backend {pulseaudio|pipewire}
  --loops N
  --timeout SECS
  --rec-file PATH				 
EOF
}

# Parse CLI args
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) export AUDIO_BACKEND="$2"; shift 2 ;;
    --loops) export RECORD_LOOPS="$2"; shift 2 ;;
    --timeout) export RECORD_TIMEOUT="$2"; shift 2 ;;
    --rec-file) export RECORD_FILE="$2"; shift 2 ;;												   
    --help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Fallback to env if not set
export AUDIO_BACKEND="${AUDIO_BACKEND:-pulseaudio}"

log_info "---------------- Starting $TESTNAME Testcase ----------------"
log_info "Using audio backend: $AUDIO_BACKEND"

init_audio_env "$TESTNAME" "$AUDIO_BACKEND"
audio_record

log_info "---------------- Completed $TESTNAME Testcase ----------------"
