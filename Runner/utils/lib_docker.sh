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
  apt_install_pkgs docker.io
  if have_cmd systemctl; then
    need_root
    log_info "cmd(root): systemctl enable --now docker"
    sh -c "$SUDO systemctl enable --now docker"
  fi
}

docker_can_run() {
  if is_root; then
    docker version >/dev/null 2>&1
  else
    sudo -n docker version >/dev/null 2>&1 || docker version >/dev/null 2>&1
  fi
}

docker_cmd() {
  if is_root; then
    printf '%s\n' "docker"
  else
    if have_cmd sudo; then printf '%s\n' "sudo -E docker"; else printf '%s\n' "docker"; fi
  fi
}

docker_image_exists() {
  img="$1"
  DCMD="$(docker_cmd)"
  $DCMD image inspect "$img" >/dev/null 2>&1
}

