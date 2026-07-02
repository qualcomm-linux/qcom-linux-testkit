#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

TESTNAME="Memory_Map"
RES_FILE="./${TESTNAME}.res"

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

OUT_DIR="${OUT_DIR:-./logs_${TESTNAME}}"
COLLECT_DELAY_SECS="${COLLECT_DELAY_SECS:-0}"
TOP_PROCESS_COUNT="${TOP_PROCESS_COUNT:-20}"
MOUNT_DEBUGFS="${MOUNT_DEBUGFS:-1}"
VERBOSE="${VERBOSE:-0}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --out DIR Output directory for collected logs
  --delay S Wait before collecting memory data, default: ${COLLECT_DELAY_SECS}
  --top-process-count N Number of top PSS processes to print to console, default: ${TOP_PROCESS_COUNT}
  --no-debugfs-mount Do not attempt to mount debugfs
  --verbose Print additional collected summaries to console
  -h, --help Show this help and exit

Environment:
  OUT_DIR Output directory, default: ./logs_Memory_Map
  COLLECT_DELAY_SECS Optional delay before collecting data
  TOP_PROCESS_COUNT Number of top PSS processes to print
  MOUNT_DEBUGFS 1 to mount debugfs if possible, 0 to skip
  VERBOSE 1 to print extra debug summaries
EOF
}

case "${1:-}" in
  -h|--help)
    usage >&2
    exit 0
    ;;
esac

INIT_ENV=""
SEARCH="$SCRIPT_DIR"

while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then
    INIT_ENV="$SEARCH/init_env"
    break
  fi
  SEARCH="$(dirname "$SEARCH")"
done

if [ -z "$INIT_ENV" ]; then
  echo "[ERROR] Could not find init_env starting from $SCRIPT_DIR" >&2
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

# shellcheck disable=SC1091
. "$TOOLS/lib_performance.sh"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      if [ "$#" -lt 2 ]; then
        log_fail "--out requires a directory"
        usage >&2
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_fail "--out requires a directory"
        usage >&2
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
      fi
      OUT_DIR="$1"
      ;;
    --delay)
      if [ "$#" -lt 2 ]; then
        log_fail "--delay requires seconds"
        usage >&2
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_fail "--delay requires seconds"
        usage >&2
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
      fi
      COLLECT_DELAY_SECS="$1"
      ;;
    --top-process-count)
      if [ "$#" -lt 2 ]; then
        log_fail "--top-process-count requires a number"
        usage >&2
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_fail "--top-process-count requires a number"
        usage >&2
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
      fi
      TOP_PROCESS_COUNT="$1"
      ;;
    --no-debugfs-mount)
      MOUNT_DEBUGFS=0
      ;;
    --verbose)
      VERBOSE=1
      ;;
    -h|--help)
      usage >&2
      exit 0
      ;;
    *)
      log_warn "Unknown option: $1"
      usage >&2
      echo "$TESTNAME FAIL" >"$RES_FILE"
      exit 1
      ;;
  esac
  shift
done

case "$COLLECT_DELAY_SECS" in
  ''|*[!0-9]*)
    log_warn "Invalid COLLECT_DELAY_SECS='$COLLECT_DELAY_SECS'; using 0"
    COLLECT_DELAY_SECS=0
    ;;
esac

case "$TOP_PROCESS_COUNT" in
  ''|*[!0-9]*)
    log_warn "Invalid TOP_PROCESS_COUNT='$TOP_PROCESS_COUNT'; using 20"
    TOP_PROCESS_COUNT=20
    ;;
esac

case "$MOUNT_DEBUGFS" in
  0|1)
    ;;
  *)
    log_warn "Invalid MOUNT_DEBUGFS='$MOUNT_DEBUGFS'; using 1"
    MOUNT_DEBUGFS=1
    ;;
esac

case "$VERBOSE" in
  0|1)
    ;;
  *)
    log_warn "Invalid VERBOSE='$VERBOSE'; using 0"
    VERBOSE=0
    ;;
esac

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting ${TESTNAME} Testcase----------------------------"

check_dependencies cat awk sed sort head grep wc tr mkdir rm dirname basename || {
  log_skip "$TESTNAME SKIP - basic dependencies missing"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
}

if perf_mem_collect_all "$OUT_DIR" "$COLLECT_DELAY_SECS" "$TOP_PROCESS_COUNT" "$MOUNT_DEBUGFS" "$VERBOSE"; then
  log_pass "$TESTNAME: PASS"
  echo "$TESTNAME PASS" >"$RES_FILE"
  exit 0
fi

log_fail "$TESTNAME: FAIL"
echo "$TESTNAME FAIL" >"$RES_FILE"
exit 0
