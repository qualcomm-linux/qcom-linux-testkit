#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# APT helpers for Debian/Ubuntu. Requires lib_common.sh + functestlib logging.

require_apt() {
  have_cmd apt-get && have_cmd apt-cache && return 0
  die "apt-get/apt-cache not found. This script targets Debian/Ubuntu."
}

apt_update_if_needed() {
  require_apt
  need=1
  if [ -d /var/lib/apt/lists ]; then
    set -- /var/lib/apt/lists/*_Packages
    if [ -e "$1" ]; then
      if find /var/lib/apt/lists -name '*_Packages' -mtime -1 2>/dev/null | grep -q .; then
        need=0
      fi
    fi
  fi
  if [ "$need" -eq 1 ]; then
    if ! need_root_or_skip; then
      return 2
    fi
    if ! network_is_ok; then
      log_skip "Offline: cannot run 'apt-get update'."
      return 2
    fi
    log_info "cmd(root): apt-get update"
    sh -c "$SUDO apt-get update"
    return $?
  fi
  log_info "APT lists look fresh (<24h); skipping apt-get update"
  return 0
}

apt_install_pkgs() {
  require_apt
  apt_update_if_needed || rc=$?; rc=${rc:-0}; [ "$rc" -eq 2 ] && return 2
  pkgs="$*"
  [ -n "$pkgs" ] || return 0
  if ! need_root_or_skip; then
    return 2
  fi
  if ! network_is_ok; then
    log_skip "Offline: cannot install $pkgs."
    return 2
  fi
  log_info "cmd(root): DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs"
  sh -c "$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs"
  return $?
}

apt_install_pkg_version() {
  pkg="$1"; ver="$2"
  if [ -z "$pkg" ] || [ -z "$ver" ]; then
    die "apt_install_pkg_version: need pkg and version"
  fi
  require_apt
  apt_update_if_needed || rc=$?; rc=${rc:-0}; [ "$rc" -eq 2 ] && return 2
  if ! need_root_or_skip; then
    return 2
  fi
  if ! network_is_ok; then
    log_skip "Offline: cannot install ${pkg}=${ver}."
    return 2
  fi
  log_info "cmd(root): DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkg}=${ver}"
  sh -c "$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkg}=${ver}"
  return $?
}

apt_upgrade_pkg() {
  pkg="$1"
  if [ -z "$pkg" ]; then
    die "apt_upgrade_pkg: need pkg name"
  fi
  require_apt
  apt_update_if_needed || rc=$?; rc=${rc:-0}; [ "$rc" -eq 2 ] && return 2
  if ! need_root_or_skip; then
    return 2
  fi
  if ! network_is_ok; then
    log_skip "Offline: cannot upgrade $pkg."
    return 2
  fi
  log_info "cmd(root): apt-get install -y --only-upgrade $pkg || apt-get install -y $pkg"
  sh -c "$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade $pkg || $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg"
  return $?
}

apt_pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

apt_list_versions() {
  require_apt
  pkg="$1"
  log_info "Available versions for $pkg:"
  if have_cmd apt-cache; then
    apt-cache policy "$pkg" | sed -n 's/ *Candidate: /candidate: /p; s/ *Installed: /installed: /p; s/ *Version table://p'
    apt-cache madison "$pkg" 2>/dev/null | awk '{print $1" "$2" "$3}' || true
  fi
}

apt_ensure_deps() {
  deps="$*"
  miss=""
  for p in $deps; do
    if ! apt_pkg_installed "$p"; then
      miss="$miss $p"
    fi
  done
  if [ -n "$miss" ]; then
    apt_install_pkgs "$miss"
    return $?
  fi
  log_info "All deps already installed"
  return 0
}

# ---- New: uninstall helpers (non-interactive; no network required) ----
apt_remove_pkgs() {
  pkgs="$*"
  [ -n "$pkgs" ] || return 0
  if ! need_root_or_skip; then
    return 2
  fi
  log_info "cmd(root): DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs"
  sh -c "$SUDO DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs"
  return $?
}

apt_autoremove() {
  if ! need_root_or_skip; then
    return 2
  fi
  log_info "cmd(root): DEBIAN_FRONTEND=noninteractive apt-get autoremove -y"
  sh -c "$SUDO DEBIAN_FRONTEND=noninteractive apt-get autoremove -y"
  return $?
}
