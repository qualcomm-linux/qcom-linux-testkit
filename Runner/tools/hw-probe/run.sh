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
  --deps-only Install only dependencies (no hw-probe)

Cleanup (optional):
  --uninstall yes|no After run, uninstall what we installed in this run (hw-probe and/or docker). Default: no

Extra:
  --probe-args "ARGS" Extra args passed to hw-probe (both local/docker)
  --dry-run Show planned actions without executing installs/runs
  --verbose Verbose logging
  -h|--help Show help
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
UNINSTALL="no"

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
    --uninstall) shift; UNINSTALL="$1" ;;
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
      :
      ;;
    *)
      PROBE_ARGS="${PROBE_ARGS}${PROBE_ARGS:+ }-log-level maximal"
      log_info "Verbose enabled: adding '-log-level maximal' to hw-probe"
      ;;
  esac
fi

# Quick base dependencies
check_dependencies grep sed awk tee || { log_skip "Missing basic tools (grep/sed/awk/tee)"; echo "hw-probe SKIP" > ./hw-probe.res 2>/dev/null; exit 2; }
if [ "$EXTRACT" = "yes" ]; then
  check_dependencies tar || { log_fail "tar is required for --extract"; echo "hw-probe FAIL" > ./hw-probe.res 2>/dev/null; exit 1; }
fi

# Sanity: OS
if ! is_debianish; then
  log_fail "This tool supports Debian/Ubuntu only."
  echo "hw-probe FAIL" > ./hw-probe.res 2>/dev/null
  exit 1
fi

# -------- Early network gate (as requested) --------
ONLINE=0
if network_is_ok; then ONLINE=1; fi
log_info "Network: $( [ "$ONLINE" -eq 1 ] && echo online || echo offline )"

# Docker requires network (unless preloaded), but per patch we hard-gate to online only
if [ "$MODE" = "docker" ] && [ "$ONLINE" -ne 1 ]; then
  log_skip "Docker mode requires network (to pull image unless preloaded)."
  echo "hw-probe SKIP" > ./hw-probe.res
  exit 2
fi

# Local offline allowed only if hw-probe already present
if [ "$MODE" = "local" ] && [ "$ONLINE" -ne 1 ] && ! hwprobe_installed; then
  log_skip "Offline and hw-probe not installed locally; skipping."
  echo "hw-probe SKIP" > ./hw-probe.res
  exit 2
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
  if [ "$DO_INSTALL" -eq 0 ] && [ "$DO_UPDATE" -eq 0 ]; then
    echo "hw-probe PASS" > ./hw-probe.res 2>/dev/null
    exit 0
  fi
fi

if [ "$DEPS_ONLY" -eq 1 ]; then
  log_info "Installing dependencies only..."
  if [ "$DRY" -eq 1 ]; then
    log_info "[dry-run] would install deps: $HWPROBE_DEPS"
  else
    apt_ensure_deps "$HWPROBE_DEPS" || true
  fi
  if [ "$DO_INSTALL" -eq 0 ] && [ "$DO_UPDATE" -eq 0 ] && [ "$MODE" = "local" ]; then
    echo "hw-probe PASS" > ./hw-probe.res 2>/dev/null
    exit 0
  fi
fi

# Install / Update logic (local package path)
if [ "$DO_INSTALL" -eq 1 ]; then
  if [ -n "$VERSION" ]; then
    if [ "$DRY" -eq 1 ]; then
      log_info "[dry-run] would install hw-probe version: $VERSION"
    else
      hwprobe_install_version "$VERSION" || true
    fi
  else
    if [ "$DRY" -eq 1 ]; then
      log_info "[dry-run] would install hw-probe latest"
    else
      hwprobe_install_latest || true
    fi
  fi
fi
if [ "$DO_UPDATE" -eq 1 ]; then
  if [ "$DRY" -eq 1 ]; then
    log_info "[dry-run] would update hw-probe to latest"
  else
    hwprobe_update || true
  fi
fi

# Run
log_info "Mode=$MODE | Upload=$UPLOAD | Out=$OUT_DIR | Extract=$EXTRACT | Online=$ONLINE"

RC=0
if [ "$DRY" -eq 1 ]; then
  log_info "[dry-run] would run hw-probe now"
  RC=0
else
  case "$MODE" in
    local)
      hwprobe_run_local "$UPLOAD" "$OUT_DIR" "$PROBE_ARGS" "$EXTRACT"
      RC=$?
      ;;
    docker)
      hwprobe_run_docker "$UPLOAD" "$OUT_DIR" "$PROBE_ARGS" "$EXTRACT"
      RC=$?
      ;;
    *)
      log_fail "Unknown mode: $MODE"
      RC=1
      ;;
  esac
fi

# ----- Post-run uninstall/cleanup as per patch -----
if [ "$MODE" = "docker" ] && [ "$UNINSTALL" = "yes" ]; then
  docker_image_prune_hwprobe || true
fi

if [ "$UNINSTALL" = "yes" ] && [ "$MODE" = "local" ]; then
  hwprobe_uninstall || true
fi

# (Existing result handling retained)
if [ "$RC" -eq 0 ]; then
  log_pass "hw-probe PASS"
  echo "hw-probe PASS" > ./hw-probe.res 2>/dev/null
  exit 0
elif [ "$RC" -eq 2 ]; then
  log_skip "hw-probe SKIP"
  echo "hw-probe SKIP" > ./hw-probe.res 2>/dev/null
  exit 2
else
  log_fail "hw-probe FAIL"
  echo "hw-probe FAIL" > ./hw-probe.res 2>/dev/null
  exit 1
fi
