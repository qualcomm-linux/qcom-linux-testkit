#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Systemd boot KPI + validation (single run).

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Boot_Systemd_Validate"
RES_FILE="./${TESTNAME}.res"

# Defaults (env may override; CLI parsing later overrides again)
OUT_DIR="${OUT_DIR:-./logs_${TESTNAME}}"
REQ_UNITS_FILE="${REQ_UNITS_FILE:-}"
REQUIRED_UNITS="${REQUIRED_UNITS:-}"
TIMEOUT_PER_UNIT="${TIMEOUT_PER_UNIT:-30}"
SVG="${SVG:-yes}"
BOOT_TYPE="${BOOT_TYPE:-unknown}"
DISABLE_GETTY="${DISABLE_GETTY:-0}"
DISABLE_SSHD="${DISABLE_SSHD:-0}"
EXCLUDE_NETWORKD_WAIT_ONLINE="${EXCLUDE_NETWORKD_WAIT_ONLINE:-0}"
EXCLUDE_SERVICES="${EXCLUDE_SERVICES:-}"
BOOT_KPI_ITERATIONS="${BOOT_KPI_ITERATIONS:-1}"
VERBOSE="${VERBOSE:-0}"
BOOT_NOT_FINISHED=0

# Optional: make boot-complete wait configurable
WAIT_FOR_BOOT_COMPLETE_TIMEOUT="${WAIT_FOR_BOOT_COMPLETE_TIMEOUT:-300}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --out DIR Output directory for logs (default: ${OUT_DIR})
  --required FILE File listing systemd units that must become active
  --timeout S Timeout per required unit (seconds, default: ${TIMEOUT_PER_UNIT})
  --no-svg Skip systemd-analyze plot SVG generation
  --boot-type TYPE Tag boot type (e.g. cold, warm, unknown)
  --disable-getty Disable serial-getty@ttyS0.service for this KPI run
  --disable-sshd Disable sshd.service for this KPI run
  --exclude-networkd-wait-online
                                Exclude systemd-networkd-wait-online.service time from userspace/total
  --exclude-services "A B" Exclude one or more services (from systemd-analyze blame) from userspace/total
  --iterations N Hint for KPI iterations (wrapper/LAVA metadata; this script still runs once)
  --verbose Dump key .txt artifacts from OUT_DIR to console for LAVA debugging
  -h, --help Show this help and exit

Artifacts in OUT:
  - platform.txt, platform.json
  - boot_type.txt, clocksource.txt
  - sysinit_deps.txt, basic_deps.txt
  - units.list, unit_states.csv
  - critical_chain.txt, blame.txt, blame_top20.txt, failed_units.txt
  - analyze_time.txt
  - journal_boot.txt, journal_warn.txt, journal_err.txt (if journalctl present)
  - boot_analysis.svg (unless --no-svg)
  - boot.dot
  - boot_kpi_this_run.txt
EOF
}

write_skip_and_exit0() {
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
}

# EARLY help handling: do this BEFORE init_env/functestlib stdout capture
case "${1:-}" in
  -h|--help)
    usage >&2
    exit 0
    ;;
esac

# --- locate and source init_env → functestlib.sh + lib_performance.sh ---
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
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_performance.sh"

# --- CLI parsing (with arg validation) ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      if [ "$#" -lt 2 ]; then
        log_error "--out requires a DIR argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--out requires a DIR argument"
        usage >&2
        write_skip_and_exit0
      fi
      OUT_DIR="$1"
      ;;
    --required)
      if [ "$#" -lt 2 ]; then
        log_error "--required requires a FILE argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--required requires a FILE argument"
        usage >&2
        write_skip_and_exit0
      fi
      REQ_UNITS_FILE="$1"
      ;;
    --timeout)
      if [ "$#" -lt 2 ]; then
        log_error "--timeout requires a numeric argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--timeout requires a numeric argument"
        usage >&2
        write_skip_and_exit0
      fi
      TIMEOUT_PER_UNIT="$1"
      ;;
    --no-svg)
      SVG="no"
      ;;
    --boot-type)
      if [ "$#" -lt 2 ]; then
        log_error "--boot-type requires a TYPE argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--boot-type requires a TYPE argument"
        usage >&2
        write_skip_and_exit0
      fi
      BOOT_TYPE="$1"
      ;;
    --disable-getty)
      DISABLE_GETTY=1
      ;;
    --disable-sshd)
      DISABLE_SSHD=1
      ;;
    --exclude-networkd-wait-online)
      EXCLUDE_NETWORKD_WAIT_ONLINE=1
      ;;
    --exclude-services)
      if [ "$#" -lt 2 ]; then
        log_error "--exclude-services requires a quoted service list argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--exclude-services requires a quoted service list argument"
        usage >&2
        write_skip_and_exit0
      fi
      EXCLUDE_SERVICES="$1"
      ;;
    --iterations)
      if [ "$#" -lt 2 ]; then
        log_error "--iterations requires a numeric argument"
        usage >&2
        write_skip_and_exit0
      fi
      shift
      if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        log_error "--iterations requires a numeric argument"
        usage >&2
        write_skip_and_exit0
      fi
      BOOT_KPI_ITERATIONS="$1"
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

# Validate timeout/iterations are numeric-ish (best effort; keep behavior lenient)
case "$TIMEOUT_PER_UNIT" in
  ''|*[!0-9]*)
    log_warn "Non-numeric --timeout; defaulting to 30"
    TIMEOUT_PER_UNIT=30
    ;;
esac
case "$BOOT_KPI_ITERATIONS" in
  ''|*[!0-9]*)
    BOOT_KPI_ITERATIONS=1
    ;;
esac

# Create OUT_DIR (review-friendly: infra failure -> SKIP)
if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
  log_warn "Cannot create OUT_DIR: $OUT_DIR"
  write_skip_and_exit0
fi

# If REQUIRED_UNITS is provided (space/comma-separated) and no file given, materialize it.
if [ -z "$REQ_UNITS_FILE" ] && [ -n "$REQUIRED_UNITS" ]; then
  REQ_UNITS_FILE="$OUT_DIR/required_units.txt"
  if ! printf '%s\n' "$REQUIRED_UNITS" | tr ',' ' ' | tr ' ' '\n' | sed '/^$/d' >"$REQ_UNITS_FILE" 2>/dev/null; then
    log_warn "Failed to write required units file: $REQ_UNITS_FILE"
    write_skip_and_exit0
  fi
fi

# Basic tools check (keep light; others are optional)
check_dependencies systemctl systemd-analyze uname sed awk grep find sort || {
  log_skip "$TESTNAME SKIP - basic tools missing"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
}

# --- ensure CPU governors restored on exit (only if we changed it) ---
GOV_CHANGED=0
cleanup() {
  if [ "$GOV_CHANGED" -eq 1 ] 2>/dev/null; then
    restore_governor
  fi
}
trap cleanup EXIT

# --- Set performance governor for KPI run ---
if set_performance_governor; then
  GOV_CHANGED=1
else
  log_warn "Failed to set performance governor; continuing KPI capture"
fi

# --- Clocksource + boot type tagging ---
capture_clocksource "$OUT_DIR/clocksource.txt"
capture_boot_type "$BOOT_TYPE" "$OUT_DIR/boot_type.txt"

# --- Optionally disable heavy services (getty/sshd) ---
disable_heavy_services_if_requested "$DISABLE_GETTY" "$DISABLE_SSHD"

# --- Wait for boot complete (multi-user.target) if possible ---
if command -v wait_for_boot_complete >/dev/null 2>&1; then
  wait_for_boot_complete "$WAIT_FOR_BOOT_COMPLETE_TIMEOUT"
else
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet multi-user.target; then
      log_info "Boot complete: multi-user.target is active"
    else
      log_warn "multi-user.target not active; continuing KPI capture anyway"
    fi
  else
    log_warn "systemctl not found; cannot verify boot-complete target"
  fi
fi

# ---------- Platform snapshot ----------
detect_platform

{
  echo "timestamp=$(nowstamp)"
  echo "kernel=$PLATFORM_KERNEL"
  echo "arch=$PLATFORM_ARCH"
  echo "uname_s=$PLATFORM_UNAME_S"
  echo "hostname=$PLATFORM_HOSTNAME"
  echo "soc_machine=$PLATFORM_SOC_MACHINE"
  echo "soc_id=$PLATFORM_SOC_ID"
  echo "soc_family=$PLATFORM_SOC_FAMILY"
  echo "dt_model=$PLATFORM_DT_MODEL"
  echo "dt_compatible=$PLATFORM_DT_COMPAT"
  echo "os_like=$PLATFORM_OS_LIKE"
  echo "os_name=$PLATFORM_OS_NAME"
  echo "target=$PLATFORM_TARGET"
  echo "machine=$PLATFORM_MACHINE"
} >"$OUT_DIR/platform.txt"
log_info "Platform info → $OUT_DIR/platform.txt"

{
  printf '{'
  printf '"timestamp":"%s",' "$(nowstamp)"
  printf '"kernel":"%s",' "$(esc "$PLATFORM_KERNEL")"
  printf '"arch":"%s",' "$(esc "$PLATFORM_ARCH")"
  printf '"uname_s":"%s",' "$(esc "$PLATFORM_UNAME_S")"
  printf '"hostname":"%s",' "$(esc "$PLATFORM_HOSTNAME")"
  printf '"soc_machine":"%s",' "$(esc "$PLATFORM_SOC_MACHINE")"
  printf '"soc_id":"%s",' "$(esc "$PLATFORM_SOC_ID")"
  printf '"soc_family":"%s",' "$(esc "$PLATFORM_SOC_FAMILY")"
  printf '"dt_model":"%s",' "$(esc "$PLATFORM_DT_MODEL")"
  printf '"dt_compatible":"%s",' "$(esc "$PLATFORM_DT_COMPAT")"
  printf '"os_like":"%s",' "$(esc "$PLATFORM_OS_LIKE")"
  printf '"os_name":"%s",' "$(esc "$PLATFORM_OS_NAME")"
  printf '"target":"%s",' "$(esc "$PLATFORM_TARGET")"
  printf '"machine":"%s"' "$(esc "$PLATFORM_MACHINE")"
  printf '}\n'
} >"$OUT_DIR/platform.json"
log_info "Platform JSON → $OUT_DIR/platform.json"

# ---------- systemd dependency trees ----------
if command -v systemctl >/dev/null 2>&1; then
  systemctl list-dependencies sysinit.target --plain --all >"$OUT_DIR/sysinit_deps.txt" 2>&1 || true
  systemctl list-dependencies basic.target --plain --all >"$OUT_DIR/basic_deps.txt" 2>&1 || true
else
  log_warn "systemctl not found; skipping dependency trees"
fi

# ---------- units + states CSV ----------
units_file="$OUT_DIR/units.list"
: >"$units_file"
if command -v systemctl >/dev/null 2>&1; then
  systemctl list-dependencies sysinit.target --plain --all 2>/dev/null \
    | sed '1d' | tr -d '●' | sed 's/^[[:space:]]*//' >>"$units_file" || true
  systemctl list-dependencies basic.target --plain --all 2>/dev/null \
    | sed '1d' | tr -d '●' | sed 's/^[[:space:]]*//' >>"$units_file" || true
  systemctl list-units --type=service --state=active --no-legend 2>/dev/null \
    | awk '{print $1}' >>"$units_file" || true
  sort -u "$units_file" | grep -E '\.(service|target|mount|socket|path|timer)$' >"$units_file.tmp" 2>/dev/null || true
  mv -f "$units_file.tmp" "$units_file" 2>/dev/null || true

  csv="$OUT_DIR/unit_states.csv"
  echo "unit,active_state,sub_state,load_state,enabled,start_usec,fragment_path,source_path,default_deps" >"$csv"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    show_out="$(systemctl show "$u" \
      -p Id -p ActiveState -p SubState -p LoadState -p UnitFileState \
      -p ActiveEnterTimestampMonotonic -p FragmentPath -p SourcePath -p DefaultDependencies 2>/dev/null || true)"
    id=$(printf '%s\n' "$show_out" | sed -n 's/^Id=//p' | head -n 1)
    act=$(printf '%s\n' "$show_out" | sed -n 's/^ActiveState=//p' | head -n 1)
    sub=$(printf '%s\n' "$show_out" | sed -n 's/^SubState=//p' | head -n 1)
    load=$(printf '%s\n' "$show_out" | sed -n 's/^LoadState=//p' | head -n 1)
    en=$(printf '%s\n' "$show_out" | sed -n 's/^UnitFileState=//p' | head -n 1)
    usec=$(printf '%s\n' "$show_out" | sed -n 's/^ActiveEnterTimestampMonotonic=//p' | head -n 1)
    frag=$(printf '%s\n' "$show_out" | sed -n 's/^FragmentPath=//p' | head -n 1)
    src=$(printf '%s\n' "$show_out" | sed -n 's/^SourcePath=//p' | head -n 1)
    ddef=$(printf '%s\n' "$show_out" | sed -n 's/^DefaultDependencies=//p' | head -n 1)

    id=$(printf '%s' "$id" | tr '"' "'")
    act=$(printf '%s' "$act" | tr '"' "'")
    sub=$(printf '%s' "$sub" | tr '"' "'")
    load=$(printf '%s' "$load" | tr '"' "'")
    en=$(printf '%s' "$en" | tr '"' "'")
    usec=$(printf '%s' "$usec" | tr '"' "'")
    frag=$(printf '%s' "$frag" | tr '"' "'")
    src=$(printf '%s' "$src" | tr '"' "'")
    ddef=$(printf '%s' "$ddef" | tr '"' "'")

    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
      "$id" "$act" "$sub" "$load" "$en" "$usec" "$frag" "$src" "$ddef" >>"$csv"
  done <"$units_file"
  log_info "Wrote unit states CSV → $csv"
else
  log_warn "systemctl not found; skipping unit state CSV"
fi

# ---------- systemd-analyze artifacts ----------
an_time="$OUT_DIR/analyze_time.txt"
an_blame="$OUT_DIR/blame.txt"
an_blame_top="$OUT_DIR/blame_top20.txt"
an_chain="$OUT_DIR/critical_chain.txt"
jobs_unfinished="$OUT_DIR/list_jobs_when_boot_unfinished.txt"

BOOT_NOT_FINISHED=0

if command -v systemd-analyze >/dev/null 2>&1; then
  : >"$jobs_unfinished"

  if command -v wait_analyze_ready >/dev/null 2>&1; then
    # Preferred path: shared helper from lib_performance.sh
    max_wait="${WAIT_ANALYZE_FINISH_TIMEOUT:-240}" # bump default to 240s
    interval="${WAIT_ANALYZE_FINISH_INTERVAL:-5}"

    if wait_analyze_ready "$an_time" "$jobs_unfinished" \
         "$max_wait" "$interval"; then
      BOOT_NOT_FINISHED=0
    else
      BOOT_NOT_FINISHED=1
      log_warn "systemd-analyze did not report finished boot within ${max_wait}s, KPIs may stay 'unknown'. See $an_time and $jobs_unfinished."
    fi
  else
    # Fallback: original inline loop, with larger default timeout
    wait_analyze="${WAIT_ANALYZE_FINISH_TIMEOUT:-240}"
    i=0
    got_finish=0

    while [ "$i" -le "$wait_analyze" ]; do
      systemd-analyze time >"$an_time" 2>&1 || true

      if grep -q 'Startup finished in' "$an_time" 2>/dev/null; then
        got_finish=1
        BOOT_NOT_FINISHED=0
        break
      fi

      if grep -q 'Bootup is not yet finished' "$an_time" 2>/dev/null; then
        BOOT_NOT_FINISHED=1
        systemctl list-jobs >"$jobs_unfinished" 2>&1 || true
      fi

      i=$((i+1))
      sleep 1
    done

    if [ "$got_finish" -eq 1 ]; then
      first_line=$(sed -n '1p' "$an_time" 2>/dev/null || true)
      if [ -n "$first_line" ]; then
        log_info "systemd-analyze time: $first_line"
      else
        log_info "systemd-analyze time written to $an_time"
      fi
    else
      log_warn "systemd-analyze reports boot not finished even after ${wait_analyze}s KPI breakdown may remain 'unknown'. See $an_time and $jobs_unfinished."
    fi
  fi

  systemd-analyze critical-chain >"$an_chain" 2>&1 || true
  log_info "systemd-analyze critical-chain → $an_chain"

  systemd-analyze blame >"$an_blame" 2>&1 || true
  head -n 20 "$an_blame" >"$an_blame_top" 2>/dev/null \
    || cp "$an_blame" "$an_blame_top" 2>/dev/null || true
  log_info "Top 20 services by time (systemd-analyze blame) → $an_blame_top"

  if [ "$SVG" = "yes" ]; then
    systemd-analyze plot >"$OUT_DIR/boot_analysis.svg" 2>/dev/null || true
    log_info "Boot SVG timeline → $OUT_DIR/boot_analysis.svg"
  else
    log_info "SVG plot disabled via --no-svg"
  fi

  systemd-analyze dot >"$OUT_DIR/boot.dot" 2>/dev/null || true
  log_info "Boot dependency DOT graph → $OUT_DIR/boot.dot"
else
  log_warn "systemd-analyze not found, skipping timing/critical-chain/blame/plot"
fi

# ---------- Bootchart (optional) ----------
if bootchart_enabled; then
  for p in /run/log/bootchart.tgz /run/log/bootchart/bootchart.tgz; do
    if [ -f "$p" ]; then
      cp "$p" "$OUT_DIR/bootchart.tgz" 2>/dev/null || true
      if [ -f "$OUT_DIR/bootchart.tgz" ]; then
        log_info "Bootchart archive → $OUT_DIR/bootchart.tgz"
      fi
      break
    fi
  done
else
  log_skip "systemd-bootchart not enabled in cmdline; skipping bootchart-specific collection"
fi

# ---------- Failed units + journal ----------
if command -v systemctl >/dev/null 2>&1; then
  systemctl --failed >"$OUT_DIR/failed_units.txt" 2>&1 || true
fi

if command -v journalctl >/dev/null 2>&1; then
  journalctl -b >"$OUT_DIR/journal_boot.txt" 2>&1 || true
  journalctl -b -p warning..alert >"$OUT_DIR/journal_warn.txt" 2>&1 || true
  journalctl -b -p err..alert >"$OUT_DIR/journal_err.txt" 2>&1 || true
else
  log_warn "journalctl not found; skipping boot journal capture"
fi

# ---------- required units gating ----------
suite_rc=0
if [ -n "$REQ_UNITS_FILE" ]; then
  if [ -f "$REQ_UNITS_FILE" ]; then
    if command -v systemctl >/dev/null 2>&1; then
      rc=0
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        if ! systemctl is-active --quiet "$u"; then
          log_info "Waiting for $u (up to ${TIMEOUT_PER_UNIT}s)..."
          i=0
          while [ "$i" -lt "$TIMEOUT_PER_UNIT" ]; do
            systemctl is-active --quiet "$u" && break
            sleep 1
            i=$((i+1))
          done
        fi
        if systemctl is-active --quiet "$u"; then
          log_info "[ok] $u is active"
        else
          log_fail "[fail] $u not active after ${TIMEOUT_PER_UNIT}s"
          rc=1
        fi
      done <"$REQ_UNITS_FILE"
      [ "$rc" -eq 0 ] || suite_rc=1
    else
      log_warn "systemctl not found; cannot verify required units"
    fi
  else
    log_warn "Required units file not found: $REQ_UNITS_FILE"
  fi
else
  log_warn "No --required file provided; not gating PASS/FAIL on specific units"
fi

# ---------- KPI breakdown (this run) ----------
CLOCKSOURCE="unknown"
if [ -f "$OUT_DIR/clocksource.txt" ]; then
  CLOCKSOURCE=$(
    grep '^clocksource=' "$OUT_DIR/clocksource.txt" 2>/dev/null \
      | sed 's/^clocksource=//' | head -n 1
  )
  [ -n "$CLOCKSOURCE" ] || CLOCKSOURCE="unknown"
fi

# Read UEFI loader times (efivars)
perf_read_uefi_loader_times
UEFI_INITs="${PERF_UEFI_INIT_SEC:-unknown}"
UEFI_EXECs="${PERF_UEFI_EXEC_SEC:-unknown}"
UEFI_TOTAL="${PERF_UEFI_TOTAL_SEC:-unknown}"

# Parse systemd-analyze time/blame
FIRMWARE_SEC=""
LOADER_SEC=""
KERNEL_SEC=""
USERSPACE_SEC=""
TOTAL_SEC=""
USERSPACE_EFF=""
TOTAL_EFF=""

if [ "$BOOT_NOT_FINISHED" -eq 0 ]; then
  perf_parse_boot_times "$an_time" "$an_blame" "$EXCLUDE_NETWORKD_WAIT_ONLINE"

  FIRMWARE_SEC="${PERF_FIRMWARE_SEC:-}"
  LOADER_SEC="${PERF_LOADER_SEC:-}"
  KERNEL_SEC="${PERF_KERNEL_SEC:-}"
  USERSPACE_SEC="${PERF_USERSPACE_SEC:-}"
  TOTAL_SEC="${PERF_TOTAL_SEC:-}"

  USERSPACE_EFF="${PERF_USERSPACE_EFFECTIVE_SEC:-$USERSPACE_SEC}"
  TOTAL_EFF="${PERF_TOTAL_EFFECTIVE_SEC:-$TOTAL_SEC}"
else
  log_warn "Boot not finished according to systemd-analyze; leaving KPI time fields as 'unknown'. See $an_time and $jobs_unfinished."
fi

# Extra service exclusions (beyond networkd-wait-online)
EXCL_SVC_SEC=""
EXCL_SVC_DETAIL=""
if [ -n "$EXCLUDE_SERVICES" ] && [ -f "$an_blame" ]; then
  sum="0"
  detail=""
  for svc in $EXCLUDE_SERVICES; do
    line=$(grep "[[:space:]]$svc\$" "$an_blame" 2>/dev/null | head -n 1 || true)
    [ -n "$line" ] || continue
    seg=$(printf '%s\n' "$line" | awk '{NF--; print}')
    t=$(perf_time_segment_to_sec "$seg")
    [ -n "$t" ] || continue
    detail="${detail}${svc}=${t}s; "
    sum=$(printf '%s %s\n' "$sum" "$t" | awk '{printf("%.3f\n", $1+$2)}')
  done
  if [ "$sum" != "0" ]; then
    EXCL_SVC_SEC="$sum"
    EXCL_SVC_DETAIL="$detail"
    if [ -n "$USERSPACE_EFF" ]; then
      USERSPACE_EFF=$(printf '%s %s\n' "$USERSPACE_EFF" "$sum" \
        | awk '{d=$1-$2; if (d<0) d=0; printf("%.3f\n", d)}')
    fi
    if [ -n "$TOTAL_EFF" ]; then
      TOTAL_EFF=$(printf '%s %s\n' "$TOTAL_EFF" "$sum" \
        | awk '{d=$1-$2; if (d<0) d=0; printf("%.3f\n", d)}')
    fi
  fi
fi

# Log exclusions clearly
if [ "$EXCLUDE_NETWORKD_WAIT_ONLINE" -eq 1 ] && [ -n "${PERF_NETWORKD_WAIT_ONLINE_SEC:-}" ]; then
  log_info "Excluded systemd-networkd-wait-online.service=${PERF_NETWORKD_WAIT_ONLINE_SEC}s from userspace/total; boot_total_effective_sec=$TOTAL_EFF"
fi
if [ -n "$EXCL_SVC_SEC" ]; then
  log_info "Excluded services from userspace/total (sum=${EXCL_SVC_SEC}s): $EXCL_SVC_DETAIL boot_total_effective_sec=$TOTAL_EFF"
fi

# KPI printout (console + file)
kpi_file="$OUT_DIR/boot_kpi_this_run.txt"
{
  echo "Boot KPI (this run)"
  echo " boot_type : $BOOT_TYPE"
  echo " iterations : $BOOT_KPI_ITERATIONS"
  echo " clocksource : $CLOCKSOURCE"
  echo " uefi_time_sec : $UEFI_TOTAL (Init=$UEFI_INITs, Exec=$UEFI_EXECs)"
  echo " firmware_time_sec : ${FIRMWARE_SEC:-unknown}"
  echo " bootloader_time_sec : ${LOADER_SEC:-unknown}"
  echo " kernel_time_sec : ${KERNEL_SEC:-unknown}"
  echo " userspace_time_sec : ${USERSPACE_SEC:-unknown}"
  echo " userspace_effective_time_sec : ${USERSPACE_EFF:-unknown}"
  echo " boot_total_sec : ${TOTAL_SEC:-unknown}"
  echo " boot_total_effective_sec : ${TOTAL_EFF:-unknown}"
} | tee "$kpi_file"

log_info "Boot KPI breakdown (this run) → $kpi_file"

# ---------- VERBOSE: dump key .txt artifacts to console ----------
if [ "$VERBOSE" -eq 1 ]; then
  log_info "Verbose mode: dumping text artifacts from $OUT_DIR (excluding journal_*.txt)"
  for f in "$OUT_DIR"/*.txt; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      journal_*.txt)
        # Skip huge journal files in verbose mode
        continue
        ;;
    esac
    echo "===== $base ====="
    cat "$f"
    echo
  done
fi

# ---------- final PASS/FAIL ----------
if [ "$suite_rc" -eq 0 ]; then
  log_pass "$TESTNAME: PASS"
  echo "$TESTNAME PASS" >"$RES_FILE"
else
  log_fail "$TESTNAME: FAIL"
  echo "$TESTNAME FAIL" >"$RES_FILE"
fi

# restore_governor via trap (if GOV_CHANGED=1)
exit "$suite_rc"
