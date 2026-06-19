#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

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
  echo "[ERROR] init_env not found" >&2
  exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
  # shellcheck disable=SC1090
  . "$INIT_ENV"
  __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_module_reload.sh"

TESTNAME="Module_Reload_Validation"
PROFILE_DIR_DEFAULT="$SCRIPT_DIR/profiles"
PROFILE_LIST_DEFAULT="$PROFILE_DIR_DEFAULT/enabled.list"

TARGET_MODULE=""
ITERATIONS="3"
TIMEOUT_UNLOAD="30"
TIMEOUT_LOAD="30"
TIMEOUT_SETTLE="20"
ENABLE_SYSRQ_HANG_DUMP="1"
PROFILE_MODE=""
PROFILE_DIR="$PROFILE_DIR_DEFAULT"
PROFILE_LIST_FILE="$PROFILE_LIST_DEFAULT"
VERBOSE=0
PROFILE_TMP_LIST=""

usage() {
  cat <<EOF
Usage: $0 [options]
  --module NAME Run only NAME.profile from profiles/
  --iterations N Reload iterations per profile (default: 3)
  --timeout-unload SEC Timeout for unload command (default: 30)
  --timeout-load SEC Timeout for load command (default: 30)
  --timeout-settle SEC Timeout for settle checks (default: 20)
  --mode MODE Profile mode override
  --profile-dir PATH Override profile directory
  --profile-list FILE Override enabled profile list file
  --enable-sysrq-hang-dump Enable sysrq dump on timeout paths
  --disable-sysrq-hang-dump Disable sysrq dump on timeout paths
  --verbose Enable verbose shell logging
  --help|-h Show this help
EOF
}

# shellcheck disable=SC2317  # invoked via trap
cleanup() {
  if [ -n "$PROFILE_TMP_LIST" ]; then
    rm -f "$PROFILE_TMP_LIST" 2>/dev/null
  fi
}

trap 'cleanup' EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --module)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        log_error "Missing value for --module"
        usage
        exit 1
      fi
      TARGET_MODULE="$2"
      shift 2
      ;;
    --iterations)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        log_error "Missing value for --iterations"
        usage
        exit 1
      fi
      ITERATIONS="$2"
      shift 2
      ;;
    --timeout-unload)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        log_error "Missing value for --timeout-unload"
        usage
        exit 1
      fi
      TIMEOUT_UNLOAD="$2"
      shift 2
      ;;
    --timeout-load)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        log_error "Missing value for --timeout-load"
        usage
        exit 1
      fi
      TIMEOUT_LOAD="$2"
      shift 2
      ;;
    --timeout-settle)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        log_error "Missing value for --timeout-settle"
        usage
        exit 1
      fi
      TIMEOUT_SETTLE="$2"
      shift 2
      ;;
    --mode)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        log_error "Missing value for --mode"
        usage
        exit 1
      fi
      PROFILE_MODE="$2"
      shift 2
      ;;
    --profile-dir)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        log_error "Missing value for --profile-dir"
        usage
        exit 1
      fi
      PROFILE_DIR="$2"
      shift 2
      ;;
    --profile-list)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        log_error "Missing value for --profile-list"
        usage
        exit 1
      fi
      PROFILE_LIST_FILE="$2"
      shift 2
      ;;
    --enable-sysrq-hang-dump)
      ENABLE_SYSRQ_HANG_DUMP=1
      shift
      ;;
    --disable-sysrq-hang-dump)
      ENABLE_SYSRQ_HANG_DUMP=0
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [ "$VERBOSE" -eq 1 ] 2>/dev/null; then
  set -x
fi

case "$ITERATIONS" in
  ''|*[!0-9]*) log_error "Invalid --iterations: $ITERATIONS"; exit 1 ;;
esac
case "$TIMEOUT_UNLOAD" in
  ''|*[!0-9]*) log_error "Invalid --timeout-unload: $TIMEOUT_UNLOAD"; exit 1 ;;
esac
case "$TIMEOUT_LOAD" in
  ''|*[!0-9]*) log_error "Invalid --timeout-load: $TIMEOUT_LOAD"; exit 1 ;;
esac
case "$TIMEOUT_SETTLE" in
  ''|*[!0-9]*) log_error "Invalid --timeout-settle: $TIMEOUT_SETTLE"; exit 1 ;;
esac

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
if ! cd "$test_path"; then
  log_error "cd failed: $test_path"
  exit 1
fi

RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
RESULT_ROOT="$SCRIPT_DIR/results/$TESTNAME"
SUMMARY_FILE="$RESULT_ROOT/summary.txt"
mkdir -p "$RESULT_ROOT"
: > "$SUMMARY_FILE"

log_info "---------------- Starting $TESTNAME ----------------"
if command -v detect_platform >/dev/null 2>&1; then
  detect_platform >/dev/null 2>&1 || true
  log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='${PLATFORM_KERNEL:-}' arch='${PLATFORM_ARCH:-}'"
else
  log_info "Platform Details: unknown"
fi

log_info "Args: module='${TARGET_MODULE:-all-enabled}' iterations=$ITERATIONS unload_timeout=$TIMEOUT_UNLOAD load_timeout=$TIMEOUT_LOAD settle_timeout=$TIMEOUT_SETTLE mode='${PROFILE_MODE:-profile-default}' sysrq_dump=$ENABLE_SYSRQ_HANG_DUMP"

if [ "$ENABLE_SYSRQ_HANG_DUMP" -eq 1 ] 2>/dev/null; then
  log_info "Sysrq hang dump policy: enabled on timeout paths only"
else
  log_info "Sysrq hang dump policy: disabled"
fi

PROFILE_FILES="$(mrv_resolve_profiles "$TARGET_MODULE" "$PROFILE_DIR" "$PROFILE_LIST_FILE")"
resolve_rc=$?
if [ "$resolve_rc" -ne 0 ]; then
  echo "$TESTNAME FAIL" > "$RES_FILE"
  exit 1
fi

if [ -z "$PROFILE_FILES" ]; then
  log_skip "$TESTNAME SKIP - no profiles selected"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 0
fi

PROFILE_TMP_LIST="$RESULT_ROOT/.profiles_to_run.list"
printf '%s\n' "$PROFILE_FILES" > "$PROFILE_TMP_LIST"

pass_count=0
fail_count=0
skip_count=0

while IFS= read -r profile_path || [ -n "$profile_path" ]; do
  [ -n "$profile_path" ] || continue

  mrv_run_one_profile "$profile_path" "$PROFILE_MODE"
  rc=$?
  base_name="$(basename "$profile_path" .profile)"

  if [ "$rc" -eq 0 ]; then
    log_pass "[$base_name] profile PASS"
    printf '%s PASS\n' "$base_name" >> "$SUMMARY_FILE"
    pass_count=$((pass_count + 1))
  elif [ "$rc" -eq 2 ]; then
    log_skip "[$base_name] profile SKIP"
    printf '%s SKIP\n' "$base_name" >> "$SUMMARY_FILE"
    skip_count=$((skip_count + 1))
  else
    log_fail "[$base_name] profile FAIL"
    printf '%s FAIL\n' "$base_name" >> "$SUMMARY_FILE"
    fail_count=$((fail_count + 1))
  fi
done < "$PROFILE_TMP_LIST"

log_info "Summary: pass=$pass_count fail=$fail_count skip=$skip_count"

if [ "$fail_count" -gt 0 ] 2>/dev/null; then
  log_fail "$TESTNAME FAIL"
  echo "$TESTNAME FAIL" > "$RES_FILE"
  exit 1
fi

if [ "$pass_count" -gt 0 ] 2>/dev/null; then
  log_pass "$TESTNAME PASS"
  echo "$TESTNAME PASS" > "$RES_FILE"
  exit 0
fi

log_skip "$TESTNAME SKIP"
echo "$TESTNAME SKIP" > "$RES_FILE"
exit 0
