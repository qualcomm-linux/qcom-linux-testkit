#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# hw-probe helpers. Requires lib_common.sh, lib_apt.sh, lib_docker.sh

HWPROBE_PKG="hw-probe"
HWPROBE_DEPS="lshw smartmontools nvme-cli hdparm pciutils usbutils dmidecode ethtool lsscsi iproute2"

hwprobe_installed() { apt_pkg_installed "$HWPROBE_PKG"; }

hwprobe_install_latest() {
  apt_ensure_deps "$HWPROBE_DEPS"
  apt_install_pkgs "$HWPROBE_PKG"
}

hwprobe_install_version() {
  ver="$1"
  apt_ensure_deps "$HWPROBE_DEPS"
  apt_install_pkg_version "$HWPROBE_PKG" "$ver"
}

hwprobe_update() { apt_upgrade_pkg "$HWPROBE_PKG"; }
hwprobe_list_versions() { apt_list_versions "$HWPROBE_PKG"; }

# Build command for local exec
hwprobe_build_local_cmd() {
  # $1=upload yes|no, $2=outdir, $3=extra
  upload="$1"; out="$2"; extra="$3"
  cmd="hw-probe -all -save \"$out\""
  [ "$upload" = "yes" ] && cmd="$cmd -upload"
  [ -n "$extra" ] && cmd="$cmd $extra"
  printf '%s\n' "$cmd"
}

# Extract a .txz (xz-compressed tar) to an output dir, with fallbacks.
# $1=saved_archive $2=dest_dir
_hwprobe_extract_txz() {
  saved="$1"; dest="$2"
  [ -f "$saved" ] || { log_warn "Cannot extract: file not found: $saved"; return 1; }
  ensure_dir "$dest" || { log_warn "Cannot create extract dir: $dest"; return 1; }

  # Prefer tar -J; fall back to bsdtar; then xz | tar
  if tar -tJf "$saved" >/dev/null 2>&1; then
    tar -xJf "$saved" -C "$dest" && { log_info "Extracted to: $dest"; return 0; }
  fi
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "$saved" -C "$dest" && { log_info "Extracted to: $dest"; return 0; }
  fi
  if command -v xz >/dev/null 2>&1; then
    xz -dc "$saved" | tar -xf - -C "$dest" && { log_info "Extracted to: $dest"; return 0; }
  fi
  log_warn "Failed to extract '$saved' (need tar with -J, or bsdtar, or xz)."
  return 1
}

# Local run (auto-disable -upload when offline)
# $4=extract yes|no
hwprobe_run_local() {
  upload="$1"; out="$2"; extra="$3"; extract="$4"
  ensure_dir "$out" || die "Cannot create output dir: $out"
 
  if [ "$upload" = "yes" ] && ! network_is_ok; then
    log_warn "No network. Disabling upload for this run."
    upload="no"
  fi
  if ! hwprobe_installed; then
    log_warn "hw-probe not installed; installing latest..."
    hwprobe_install_latest
  fi
 
  cmd="$(hwprobe_build_local_cmd "$upload" "$out" "$extra")"
  log_info "cmd(root): $cmd"
  need_root
  tmp="${out%/}/.hw-probe-run-$(nowstamp).log"
  sh -c "$SUDO $cmd" 2>&1 | tee "$tmp"
 
  # Extract URL if uploaded
  url="$(sed -n 's/^.*Probe URL: *\([^ ]*linux-hardware\.org[^ ]*\).*$/\1/p' "$tmp" | tail -n 1)"
  [ -n "$url" ] && log_info "Probe uploaded: $url"
 
  # Parse saved artifact
  saved="$(sed -n 's/^Saved to:[[:space:]]*//p' "$tmp" | tail -n 1)"
  if [ -z "$saved" ] || [ ! -f "$saved" ]; then
    # Robust newest file selection (avoid parsing ls) — handles spaces in paths
    newest="$(find "$out" -mindepth 1 -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr | head -n 1 | cut -d' ' -f2-)"
    [ -n "$newest" ] && saved="$newest"
  fi
 
  if [ -n "$saved" ] && [ -f "$saved" ]; then
    log_info "Latest saved artifact: $saved"
    log_info "List:    tar -tJf \"$saved\""
    log_info "Extract: mkdir -p \"$out/extracted\" && tar -xJf \"$saved\" -C \"$out/extracted\""
 
    if [ "$extract" = "yes" ]; then
      dest="${out%/}/extracted-$(nowstamp)"
      _hwprobe_extract_txz "$saved" "$dest" || true
    fi
  fi
 
  log_info "Local report directory: $out"
}

# Docker run (respects offline: skip pull if offline; require image present)
# $4=extract yes|no
hwprobe_run_docker() {
  upload="$1"; out="$2"; extra="$3"; extract="$4"
  ensure_dir "$out" || die "Cannot create output dir: $out"

  if [ "$upload" = "yes" ] && ! network_is_ok; then
    log_warn "No network. Disabling upload for this Docker run."
    upload="no"
  fi

  docker_install
  docker_can_run || die "Docker installed but cannot run. Check permissions."

  DCMD="$(docker_cmd)"
  IMAGE="linuxhw/hw-probe"

  if network_is_ok; then
    log_info "cmd: $DCMD pull $IMAGE || true"
    sh -c "$DCMD pull $IMAGE || true"
  else
    if ! docker_image_exists "$IMAGE"; then
      die "Offline and Docker image '$IMAGE' not present locally."
    fi
    log_warn "Offline: skipping docker pull; using local image '$IMAGE'."
  fi

  inner="hw-probe -all -save /out"
  [ "$upload" = "yes" ] && inner="$inner -upload"
  [ -n "$extra" ] && inner="$inner $extra"

  TS="$(nowstamp)"
  DLOG="${out%/}/.hw-probe-docker-${TS}.log"

  sh -c "$DCMD run --rm -it \
    -v /dev:/dev:ro \
    -v /lib/modules:/lib/modules:ro \
    -v /etc/os-release:/etc/os-release:ro \
    -v /var/log:/var/log:ro \
    -v \"$out\":/out \
    --privileged --net=host --pid=host \
    \"$IMAGE\" sh -lc \"$inner\" 2>&1 | tee \"$DLOG\""

  # Extract URL if uploaded
  url="$(sed -n 's/^.*Probe URL: *\([^ ]*linux-hardware\.org[^ ]*\).*$/\1/p' "$DLOG" | tail -n 1)"
  [ -n "$url" ] && log_info "Probe uploaded: $url"

  # Parse saved artifact path from docker log or fallback
  saved="$(sed -n 's/^Saved to:[[:space:]]*\/out/\/out/p' "$DLOG" | tail -n 1 | sed "s|^/out|$out|")"
  if [ -z "$saved" ] || [ ! -f "$saved" ]; then
    newest="$(find "$out" -mindepth 1 -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr | head -n 1 | cut -d' ' -f2-)"
    [ -n "$newest" ] && saved="$newest"
  fi

  if [ -n "$saved" ] && [ -f "$saved" ]; then
    log_info "Latest saved artifact: $saved"
    log_info "List:    tar -tJf \"$saved\""
    log_info "Extract: mkdir -p \"$out/extracted\" && tar -xJf \"$saved\" -C \"$out/extracted\""

    if [ "$extract" = "yes" ]; then
      dest="${out%/}/extracted-$(nowstamp)"
      _hwprobe_extract_txz "$saved" "$dest" || true
    fi
  fi

  log_info "Docker run complete. Report directory: $out"
}
