#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# hw-probe helpers. Requires lib_common.sh, lib_apt.sh, lib_docker.sh

HWPROBE_PKG="hw-probe"
HWPROBE_DEPS="lshw smartmontools nvme-cli hdparm pciutils usbutils dmidecode ethtool lsscsi iproute2"
# Flag for callers (e.g., run.sh) to know if we installed hw-probe in this run.
# shellcheck disable=SC2034 # used by run.sh; not read within this file
HWPROBE_INSTALLED_THIS_RUN=${HWPROBE_INSTALLED_THIS_RUN:-0}
export HWPROBE_INSTALLED_THIS_RUN

hwprobe_installed() { apt_pkg_installed "$HWPROBE_PKG"; }

# Mark if we installed hw-probe in this run (for optional uninstall)
HWPROBE_INSTALLED_THIS_RUN=0

hwprobe_offline_ready_local() {
  if ! hwprobe_installed; then
    return 1
  fi
  for p in $HWPROBE_DEPS; do
    if ! apt_pkg_installed "$p"; then
      return 1
    fi
  done
  return 0
}

hwprobe_install_latest() {
  apt_ensure_deps "$HWPROBE_DEPS" || return $?
  if ! hwprobe_installed; then
    apt_install_pkgs "$HWPROBE_PKG" || return $?
    # shellcheck disable=SC2034 # consumed by run.sh; assignment intentional
    HWPROBE_INSTALLED_THIS_RUN=1
    export HWPROBE_INSTALLED_THIS_RUN
  fi
  return 0
}

hwprobe_install_version() {
  ver="$1"
  apt_ensure_deps "$HWPROBE_DEPS" || return $?
  if ! hwprobe_installed; then
    apt_install_pkg_version "$HWPROBE_PKG" "$ver" || return $?
    # shellcheck disable=SC2034 # consumed by run.sh; assignment intentional
    HWPROBE_INSTALLED_THIS_RUN=1
    export HWPROBE_INSTALLED_THIS_RUN
  else
    apt_install_pkg_version "$HWPROBE_PKG" "$ver" || return $?
  fi
  return 0
}

hwprobe_update() { apt_upgrade_pkg "$HWPROBE_PKG"; }
hwprobe_list_versions() { apt_list_versions "$HWPROBE_PKG"; }

hwprobe_build_local_cmd() {
  upload="$1"; out="$2"; extra="$3"
  cmd="hw-probe -all -save \"$out\""
  [ "$upload" = "yes" ] && cmd="$cmd -upload"
  [ -n "$extra" ] && cmd="$cmd $extra"
  printf '%s\n' "$cmd"
}

_hwprobe_extract_txz() {
  saved="$1"; dest="$2"
  case "$saved" in
    *.txz|*.tar.xz) : ;;
    *) log_warn "Not a txz/tar.xz, skipping extract: $saved"; return 1 ;;
  esac
  [ -f "$saved" ] || { log_warn "Cannot extract: file not found: $saved"; return 1; }
  ensure_dir "$dest" || { log_warn "Cannot create extract dir: $dest"; return 1; }

  if tar -tJf "$saved" >/dev/null 2>&1 && tar -xJf "$saved" -C "$dest"; then
    log_info "Extracted to: $dest"; return 0
  fi
  if command -v bsdtar >/dev/null 2>&1 && bsdtar -xf "$saved" -C "$dest"; then
    log_info "Extracted to: $dest"; return 0
  fi
  if command -v xz >/dev/null 2>&1 && xz -dc "$saved" | tar -xf - -C "$dest"; then
    log_info "Extracted to: $dest"; return 0
  fi
  log_warn "Failed to extract '$saved' (need tar -J, or bsdtar, or xz)."
  return 1
}

hwprobe_run_local() {
  upload="$1"; out="$2"; extra="$3"; extract="$4"

  ensure_dir "$out" || return 1

  if ! hwprobe_installed; then
    if network_is_ok; then
      log_warn "hw-probe not installed; installing latest..."
      hwprobe_install_latest || return $?
    else
      log_skip "Offline: hw-probe not installed; skipping local run."
      return 2
    fi
  fi

  if ! need_root_or_skip; then
    return 2
  fi

  cmd="$(hwprobe_build_local_cmd "$upload" "$out" "$extra")"
  log_info "cmd(root): $cmd"
  tmp="${out%/}/.hw-probe-run-$(nowstamp).log"

  sh -c "$SUDO $cmd" >"$tmp" 2>&1
  rc=$?
  cat "$tmp"

  url="$(sed -n 's/^.*Probe URL: *\([^ ]*linux-hardware\.org[^ ]*\).*$/\1/p' "$tmp" | tail -n 1)"
  [ -n "$url" ] && log_info "Probe uploaded: $url"

  saved="$(sed -n 's/^Saved to:[[:space:]]*//p' "$tmp" | tail -n 1)"
  if [ -z "$saved" ] || [ ! -f "$saved" ]; then
    newest="$(find "$out" -mindepth 1 -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)"
    [ -n "$newest" ] && saved="$newest"
  fi

  if [ "$rc" -eq 0 ] && [ -n "$saved" ] && [ -f "$saved" ]; then
    log_info "Latest saved artifact: $saved"
    log_info "List: tar -tJf \"$saved\""
    log_info "Extract: mkdir -p \"$out/extracted\" && tar -xJf \"$saved\" -C \"$out/extracted\""
    if [ "$extract" = "yes" ]; then
      dest="${out%/}/extracted-$(nowstamp)"
      _hwprobe_extract_txz "$saved" "$dest" || true
    fi
  fi

  log_info "Local report directory: $out"
  return "$rc"
}

hwprobe_run_docker() {
  upload="$1"; out="$2"; extra="$3"; extract="$4"

  ensure_dir "$out" || return 1
  OUT_ABS="$(cd "$out" 2>/dev/null && pwd)" || return 1

  # Track whether docker existed before, so the caller can optionally uninstall.
  if docker_is_installed; then export __DOCKER_WAS_INSTALLED=1; else export __DOCKER_WAS_INSTALLED=0; fi

  docker_install || return $?
  if ! docker_can_run; then
    log_skip "Docker present but cannot run (needs group or passwordless sudo)."
    return 2
  fi

  DCMD="$(docker_cmd)"
  IMAGE="linuxhw/hw-probe"
  CNAME="hwprobe-$(nowstamp)-$$"

  # Ensure we have the image (best-effort pull if online)
  if network_is_ok; then
    log_info "cmd: $DCMD pull $IMAGE || true"
    $DCMD pull "$IMAGE" || true
  else
    if ! docker_image_exists "$IMAGE"; then
      log_skip "Offline and Docker image '$IMAGE' not present locally; skipping docker run."
      return 2
    fi
    log_warn "Offline: skipping docker pull; using local image '$IMAGE'."
  fi

  # Build a tiny script on the HOST, inside the bind mount, to avoid quoting issues.
  INNER="$OUT_ABS/.inner.sh"
  {
    echo 'set -ex'
    echo 'echo "--- container: whoami ---"; whoami || true'
    echo 'echo "--- container: uname -a ---"; uname -a || true'
    echo 'echo "--- container: pre-touch ---"; touch /out/__pre_touch_from_container || true'
    echo 'echo "--- container: hw-probe -V ---"; hw-probe -V || true'
    echo 'if [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1; then'
    echo ' apk add --no-cache kmod-libs 2>/dev/null || true'
    echo 'fi'
    printf 'echo "--- container: run hw-probe ---"; env DDCUTIL_DISABLE=1 hw-probe -all -save /out -log-level maximal'
    [ "$upload" = "yes" ] && printf ' -upload'
    [ -n "$extra" ] && printf ' %s' "$extra"
    echo
    echo 'echo "--- container: list /out ---"; ls -la /out || true'
    echo 'echo "--- container: post-touch ---"; touch /out/__post_touch_from_container || true'
    echo 'echo "--- container: done ---"'
  } > "$INNER"
  chmod 755 "$INNER" 2>/dev/null || true

  TS="$(nowstamp)"
  DLOG="${OUT_ABS%/}/.hw-probe-docker-${TS}.log"

  # Preview exact docker run (multi-line, readable)
  log_info "cmd:"
  log_info " $DCMD run --name $CNAME \\"
  log_info " --privileged --net=host --pid=host \\"
  log_info " -v /dev:/dev \\"
  log_info " -v /sys:/sys:ro \\"
  log_info " -v /run/udev:/run/udev:ro \\"
  log_info " -v /lib/modules:/lib/modules:ro \\"
  log_info " -v /etc/os-release:/etc/os-release:ro \\"
  log_info " -v /var/log:/var/log:ro \\"
  log_info " -v \"$OUT_ABS\":/out \\"
  log_info " --entrypoint /bin/sh \\"
  log_info " \"$IMAGE\" -lc \"/out/.inner.sh 2>&1 | tee -a /out/container.log\""

  # Run (no --rm so we can inspect/cp afterwards). Capture all stdout/stderr to DLOG.
  (
    echo "== docker run start: $(date -u) =="
    $DCMD run --name "$CNAME" \
      --privileged --net=host --pid=host \
      -v /dev:/dev \
      -v /sys:/sys:ro \
      -v /run/udev:/run/udev:ro \
      -v /lib/modules:/lib/modules:ro \
      -v /etc/os-release:/etc/os-release:ro \
      -v /var/log:/var/log:ro \
      -v "$OUT_ABS":/out \
      --entrypoint /bin/sh \
      "$IMAGE" -lc "/out/.inner.sh 2>&1 | tee -a /out/container.log"
    rc=$?
    echo "== docker run end: $(date -u) rc=$rc =="
    exit $rc
  ) >"$DLOG" 2>&1

  run_rc=$?

  # Always show docker logs if available (helpful, but container.log is authoritative).
  log_info "--- docker logs ($CNAME) ---"
  $DCMD logs "$CNAME" 2>/dev/null | sed 's/^/[docker] /' || log_warn "No docker logs (possibly empty)."

  # Show container state
  log_info "--- docker inspect state ($CNAME) ---"
  $DCMD inspect --format='[state] Status={{.State.Status}} ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} Error={{.State.Error}}' "$CNAME" 2>/dev/null | sed 's/^/[inspect] /' || true

  # Mirror our captured host log + the container.log written via tee inside container
  if [ -s "$DLOG" ]; then
    sed -e 's/^/[runner] /' "$DLOG" || true
  fi
  if [ -s "$OUT_ABS/container.log" ]; then
    log_info "--- container.log (host copy) ---"
    sed -e 's/^/[container] /' "$OUT_ABS/container.log" | tail -n 200 || true
  else
    log_warn "container.log not found in $OUT_ABS (script may not have run)."
  fi

  # Locate artifacts on the host
  saved="$(find "$OUT_ABS" -maxdepth 1 -type f -name '*.txz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  pre_marker="$OUT_ABS/__pre_touch_from_container"
  post_marker="$OUT_ABS/__post_touch_from_container"

  # If nothing visible on the host, try docker cp of /out
  if [ -z "$saved" ] && [ ! -e "$pre_marker" ] && [ ! -e "$post_marker" ]; then
    log_warn "No .txz and no markers on host. Trying docker cp fallback from container /out ..."
    TMP_EXTRACT="$OUT_ABS/.from_container_$TS"
    mkdir -p "$TMP_EXTRACT" 2>/dev/null || true
    if $DCMD cp "$CNAME":/out/. "$TMP_EXTRACT"/ >/dev/null 2>&1; then
      log_info "Copied /out from container to $TMP_EXTRACT"
      find "$TMP_EXTRACT" -mindepth 1 -maxdepth 1 -printf '%p\n' 2>/dev/null | sed 's/^/[cp] /' || true
      saved="$(find "$TMP_EXTRACT" -maxdepth 1 -type f -name '*.txz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
      [ -n "$saved" ] && { mv -f "$saved" "$OUT_ABS"/ 2>/dev/null || true; saved="$OUT_ABS/$(basename "$saved")"; }
      for m in "$TMP_EXTRACT"/__pre_touch_from_container "$TMP_EXTRACT"/__post_touch_from_container; do
        if [ -e "$m" ]; then
          mv -f "$m" "$OUT_ABS"/ 2>/dev/null || true
        fi
      done
      if [ -s "$TMP_EXTRACT/container.log" ]; then
        cp -f "$TMP_EXTRACT/container.log" "$OUT_ABS"/ 2>/dev/null || true
      fi
    else
      log_warn "docker cp failed or /out was empty."
    fi
  fi

  # Show marker status so we know if container could write to the mount
  if [ -e "$pre_marker" ] || [ -e "$post_marker" ]; then
    log_info "Mount sanity: pre_marker=$( [ -e "$pre_marker" ] && echo present || echo missing ), post_marker=$( [ -e "$post_marker" ] && echo present || echo missing )"
  fi

  # Parse possible Probe URL (container.log usually has it)
  url=""
  [ -f "$OUT_ABS/container.log" ] && url="$(sed -n 's/^.*Probe URL: *\([^ ]*linux-hardware\.org[^ ]*\).*$/\1/p' "$OUT_ABS/container.log" | tail -n 1)"
  [ -z "$url" ] && url="$(sed -n 's/^.*Probe URL: *\([^ ]*linux-hardware\.org[^ ]*\).*$/\1/p' "$DLOG" | tail -n 1)"
  [ -n "$url" ] && log_info "Probe uploaded: $url"

  # Tidy up container (image cleanup handled elsewhere if --uninstall yes)
  $DCMD rm -f "$CNAME" >/dev/null 2>&1 || true

  # Best-effort chown to current user so artifacts aren’t root-owned on host
  if command -v id >/dev/null 2>&1; then
    uid="$(id -u 2>/dev/null || echo)"
    gid="$(id -g 2>/dev/null || echo)"
    if [ -n "$uid" ] && [ -n "$gid" ]; then
      if need_root_or_skip; then
        log_info "Fixing ownership of $OUT_ABS -> $uid:$gid"
        sh -c "$SUDO chown -R \"$uid\":\"$gid\" \"$OUT_ABS\" 2>/dev/null || true"
      else
        log_warn "Outputs are root-owned. re-run with sudo to chown, or copy elsewhere."
      fi
    fi
  fi

  if [ -n "$saved" ] && [ -f "$saved" ]; then
    log_info "Latest saved artifact: $saved"
    log_info "List: tar -tJf \"$saved\""
    log_info "Extract: mkdir -p \"$OUT_ABS/extracted\" && tar -xJf \"$saved\" -C \"$OUT_ABS/extracted\""
    if [ "$extract" = "yes" ]; then
      dest="${OUT_ABS%/}/extracted-$(nowstamp)"
      _hwprobe_extract_txz "$saved" "$dest" || true
    fi
    log_info "Docker run complete. Report directory: $OUT_ABS"
    return 0
  fi

  log_fail "No .txz artifact produced (docker run rc=$run_rc)."
  log_info "Docker run complete. Report directory: $OUT_ABS"
  return 1
}

# ---- New: uninstall hw-probe package ----
hwprobe_uninstall_pkg() {
  if ! hwprobe_installed; then
    return 0
  fi
  apt_remove_pkgs "$HWPROBE_PKG" || return $?
  apt_autoremove || true
  return 0
}

hwprobe_uninstall() {
  if apt_pkg_installed "$HWPROBE_PKG"; then
    need_root
    log_info "cmd(root): apt-get remove -y $HWPROBE_PKG"
    sh -c "$SUDO DEBIAN_FRONTEND=noninteractive apt-get remove -y $HWPROBE_PKG"
  else
    log_info "hw-probe not installed; nothing to uninstall."
  fi
}

docker_image_prune_hwprobe() {
  DCMD="$(docker_cmd)"
  if docker_image_exists "linuxhw/hw-probe"; then
    log_info "Cleaning up Docker image linuxhw/hw-probe (best-effort)"
    # shellcheck disable=SC2086
    $DCMD rmi -f linuxhw/hw-probe >/dev/null 2>&1 || true
  fi
}
