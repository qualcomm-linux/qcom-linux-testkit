#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# hw-probe orchestrator for Debian/Ubuntu
# POSIX-only, modular, with local and Docker modes.
# Uses functestlib.sh for logging & dependency checks.
# --------- Robustly source init_env and functestlib.sh ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source once (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# --- source our libs (they rely on functestlib logging) ---
# shellcheck disable=SC1091
. "$TOOLS/lib_common.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_apt.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_docker.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_hwprobe.sh"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Modes:
  --mode local|docker Run hw-probe locally or via docker (default: local)
  --upload yes|no Upload results to linux-hardware.org (default: no)
  --out DIR Directory to save reports/logs (default: ./hw-probe_out)
  --extract yes|no Auto-extract saved report into OUT/extracted-<ts> (default: no)

Install / Update:
  --install Install hw-probe (latest) if not present
  --version VER Install a specific version (implies --install)
  --update Update hw-probe to latest available
  --list-versions Show available versions via APT
  --deps-only Install only dependencies (no hw-probe)

Extra:
  --probe-args "ARGS" Extra args passed to hw-probe (both local/docker)
  --dry-run Show planned actions without executing installs/runs
  --verbose Verbose logging
EOF
}

# Defaults
MODE="local"
UPLOAD="no"
OUT_DIR="./hw-probe_out"
EXTRACT="no"
DO_INSTALL=0
DO_UPDATE=0
LIST_VERS=0
DEPS_ONLY=0
VERSION=""
PROBE_ARGS=""
DRY=0
VERBOSE=0

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) shift; MODE="$1" ;;
    --upload) shift; UPLOAD="$1" ;;
    --out) shift; OUT_DIR="$1" ;;
    --extract) shift; EXTRACT="$1" ;;
    --install) DO_INSTALL=1 ;;
    --version) shift; VERSION="$1"; DO_INSTALL=1 ;;
    --update) DO_UPDATE=1 ;;
    --list-versions) LIST_VERS=1 ;;
    --deps-only) DEPS_ONLY=1 ;;
    --probe-args) shift; PROBE_ARGS="$1" ;;
    --dry-run) DRY=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) log_warn "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# --- Verbose handling (pre-run): use maximal hw-probe logging if user didn't set it ---
if [ "$VERBOSE" = "1" ]; then
  case " $PROBE_ARGS " in
    *" -log-level "*|*" -minimal "*|*" -min "*|*" -maximal "*|*" -max "*)
      # user already specified a log level; leave as-is
      :
      ;;
    *)
      # append -log-level maximal, preserving spacing if PROBE_ARGS was non-empty
      PROBE_ARGS="${PROBE_ARGS}${PROBE_ARGS:+ }-log-level maximal"
      log_info "Verbose enabled: adding '-log-level maximal' to hw-probe"
      ;;
  esac
fi

# Quick base dependencies (loggers already available)
check_dependencies grep sed awk tee || { log_skip "Missing basic tools (grep/sed/awk/tee)"; exit 0; }
# If extraction requested, ensure tar exists (xz/bsdtar are optional fallbacks)
if [ "$EXTRACT" = "yes" ]; then
  check_dependencies tar || { log_fail "tar is required for --extract"; exit 1; }
fi

# Sanity: OS
if ! is_debianish; then
  log_fail "This tool supports Debian/Ubuntu only."
  exit 1
fi

# Dry-run wrapper
maybe_run() {
  if [ "$DRY" -eq 1 ]; then
    log_info "[dry-run] $*"
    return 0
  fi
  sh -c "$*"
}

# Actions
if [ "$LIST_VERS" -eq 1 ]; then
  apt_list_versions hw-probe
  [ "$DO_INSTALL" -eq 0 ] && [ "$DO_UPDATE" -eq 0 ] && exit 0
fi

if [ "$DEPS_ONLY" -eq 1 ]; then
  log_info "Installing dependencies only..."
  if [ "$DRY" -eq 1 ]; then
    log_info "[dry-run] would install deps: $HWPROBE_DEPS"
  else
    apt_ensure_deps "$HWPROBE_DEPS"
  fi
  [ "$DO_INSTALL" -eq 0 ] && [ "$DO_UPDATE" -eq 0 ] && [ "$MODE" = "local" ] && exit 0
fi

# Install / Update logic
if [ "$DO_INSTALL" -eq 1 ]; then
  if [ -n "$VERSION" ]; then
    if [ "$DRY" -eq 1 ]; then log_info "[dry-run] would install hw-probe version: $VERSION"; else hwprobe_install_version "$VERSION"; fi
  else
    if [ "$DRY" -eq 1 ]; then log_info "[dry-run] would install hw-probe latest"; else hwprobe_install_latest; fi
  fi
fi
if [ "$DO_UPDATE" -eq 1 ]; then
  if [ "$DRY" -eq 1 ]; then log_info "[dry-run] would update hw-probe to latest"; else hwprobe_update; fi
fi

# Run
log_info "Mode=$MODE | Upload=$UPLOAD | Out=$OUT_DIR | Extract=$EXTRACT"
if [ "$DRY" -eq 1 ]; then
  log_info "[dry-run] would run hw-probe now"
  exit 0
fi

case "$MODE" in
  local) hwprobe_run_local "$UPLOAD" "$OUT_DIR" "$PROBE_ARGS" "$EXTRACT" ;;
  docker) hwprobe_run_docker "$UPLOAD" "$OUT_DIR" "$PROBE_ARGS" "$EXTRACT" ;;
  *) log_fail "Unknown mode: $MODE"; exit 1 ;;
esac

log_pass "Done."
