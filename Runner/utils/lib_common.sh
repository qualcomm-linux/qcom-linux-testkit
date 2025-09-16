#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# POSIX helpers that defer to functestlib.sh where available.

# --- fallbacks only if functestlib wasn't sourced ---
if ! command -v log_info >/dev/null 2>&1; then
  log_info() { printf '[INFO] %s\n' "$*"; }
fi
if ! command -v log_warn >/dev/null 2>&1; then
  log_warn() { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! command -v log_error >/dev/null 2>&1; then
  log_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! command -v log_fail >/dev/null 2>&1; then
  log_fail() { printf '[FAIL] %s\n' "$*" >&2; }
fi
if ! command -v log_skip >/dev/null 2>&1; then
  log_skip() { printf '[SKIP] %s\n' "$*"; }
fi

die() { log_error "$*"; exit 1; }

# --- cmd exists ---
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- root / sudo (kept tiny; functestlib may not provide them) ---
SUDO=""
is_root() { [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]; }
need_root() {
  if ! is_root; then
    if have_cmd sudo; then SUDO="sudo -E"; else die "Root required and 'sudo' not found."; fi
  fi
}

# --- ensure dir ---
ensure_dir() {
  d="$1"
  if [ ! -d "$d" ]; then
    mkdir -p "$d" 2>/dev/null || { need_root; $SUDO mkdir -p "$d" || return 1; }
  fi
}

# --- OS detect (Debian/Ubuntu) ---
detect_os_like() {
  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    # shellcheck disable=SC2154
    printf '%s\n' "${ID_LIKE:-$ID}"
    return 0
  fi
  printf '%s\n' "unknown"
}

is_debianish() {
  like="$(detect_os_like | tr '[:upper:]' '[:lower:]')"
  echo "$like" | grep -Eq 'debian|ubuntu'
}

# --- network check: use functestlib's check_network_status if present ---
network_is_ok() {
  if command -v check_network_status >/dev/null 2>&1; then
    check_network_status
    return $?
  fi
  log_warn "check_network_status not found; skipping strict network check"
  return 0
}
require_network() {
  network_is_ok || die "Network unavailable (check_network_status failed)."
}

# --- timestamp helper ---
nowstamp() { date +%Y%m%d%H%M%S 2>/dev/null || printf '%s\n' "now"; }
