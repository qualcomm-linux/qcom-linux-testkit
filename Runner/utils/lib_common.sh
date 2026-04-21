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

# --- root / sudo (non-interactive aware) ---
SUDO=""
is_root() { [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]; }

# Returns:
# 0 => we can escalate non-interactively (sets $SUDO or empty when already root)
# 2 => escalation would PROMPT (caller should SKIP gracefully)
ensure_root_noprompt() {
  if is_root; then
    SUDO=""
    return 0
  fi

  if have_cmd sudo; then
    if sudo -n true >/dev/null 2>&1; then
      SUDO="sudo -E"
      return 0
    fi
    if [ -n "${SUDO_ASKPASS:-}" ] && [ -x "${SUDO_ASKPASS:-/nonexistent}" ]; then
      if sudo -A -n true >/dev/null 2>&1; then
        SUDO="sudo -A -E"
        return 0
      fi
    fi
  fi

  if have_cmd doas; then
    if doas -n true >/dev/null 2>&1; then
      SUDO="doas"
      return 0
    fi
  fi

  return 2
}

need_root() {
  ensure_root_noprompt
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  die "Root privileges required but non-interactive sudo/doas is unavailable (would prompt). Re-run as root or configure passwordless sudo."
}

need_root_or_skip() {
  ensure_root_noprompt
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  log_skip "Root required but sudo/doas would prompt (no passwordless method)."
  return 2
}

# --- ensure dir ---
ensure_dir() {
  d="$1"
  if [ -d "$d" ]; then
    return 0
  fi
  mkdir -p "$d" 2>/dev/null && return 0
  if need_root_or_skip; then
    $SUDO mkdir -p "$d" || return 1
    return 0
  fi
  return 1
}

# --- OS detect (Debian/Ubuntu) ---
detect_os_like() {
  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    printf '%s\n' "${ID_LIKE:-$ID}"
    return 0
  fi
  printf '%s\n' "unknown"
}

is_debianish() {
  like="$(detect_os_like | tr '[:upper:]' '[:lower:]')"
  echo "$like" | grep -Eq 'debian|ubuntu'
}

# --- network check: prefer functestlib’s richer checks if present ---
network_is_ok() {
  if command -v check_network_status >/dev/null 2>&1; then
    check_network_status
    return $?
  fi
  ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1
}

ensure_network_online() {
  if command -v ensure_network_online >/dev/null 2>&1; then
    command ensure_network_online
    return $?
  fi
  return 1
}

# --- timestamp helper ---
nowstamp() { date +%Y%m%d%H%M%S 2>/dev/null || printf '%s\n' "now"; }
