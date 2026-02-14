#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Docker helpers. Requires lib_common.sh and lib_apt.sh

docker_is_installed() { have_cmd docker; }

docker_install() {
  if docker_is_installed; then
    log_info "Docker already installed"
    return 0
  fi
 
  log_info "Installing docker.io via apt"
  apt_install_pkgs docker.io || return $?
 
  if have_cmd systemctl; then
    if ! need_root_or_skip; then
      log_skip "Cannot enable docker service (root escalation would prompt)."
      return 2
    fi
    log_info "cmd(root): systemctl enable --now docker"
    sh -c "$SUDO systemctl enable --now docker"
  fi
 
  # Add current user to 'docker' group (best-effort), so future runs won't need sudo
  if have_cmd usermod; then
    if ! id -nG 2>/dev/null | grep -qw docker; then
      if need_root_or_skip; then
        log_info "cmd(root): usermod -aG docker $(id -un) || true"
        sh -c "$SUDO usermod -aG docker $(id -un) || true"
        log_info "You may need to re-login for docker group membership to apply."
      else
        log_skip "Cannot add user to 'docker' group (root escalation would prompt)."
      fi
    fi
  fi
 
  return 0
}

docker_can_run() {
  DCMD="$(docker_cmd)"
  # shellcheck disable=SC2086
  $DCMD version >/dev/null 2>&1
}
 
docker_cmd() {
  if is_root; then
    printf '%s\n' "docker"
    return
  fi
 
  # If the user is in the docker group, no sudo needed
  if id -nG 2>/dev/null | grep -qw docker; then
    printf '%s\n' "docker"
    return
  fi
 
  # Fall back to sudo, but strictly non-interactive to avoid hangs
  if have_cmd sudo && sudo -n true >/dev/null 2>&1; then
    printf '%s\n' "sudo -n -E docker"
  else
    # Last resort: plain docker (will fail in docker_can_run if unusable)
    printf '%s\n' "docker"
  fi
}

docker_image_exists() {
  img="$1"
  DCMD="$(docker_cmd)"
  $DCMD image inspect "$img" >/dev/null 2>&1
}

# ---- New: uninstall docker (package) + optional disable service ----
docker_uninstall_pkg() {
  if ! docker_is_installed; then
    return 0
  fi
  apt_remove_pkgs docker.io || return $?
  if have_cmd systemctl; then
    if need_root_or_skip; then
      log_info "cmd(root): systemctl disable --now docker || true"
      sh -c "$SUDO systemctl disable --now docker || true"
    fi
  fi
  return 0
}
