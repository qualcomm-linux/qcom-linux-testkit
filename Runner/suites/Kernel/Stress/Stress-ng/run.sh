#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc.
# SPDX-License-Identifier: BSD-3-Clause#
# stress-ng validation runner:
# - Default: auto-sized CPU + VM/HDD sets with strict FAIL criteria
# - Custom: pass any stress-ng CLI via --stressng-args "…" or after "--"
# - --autosize: when user references vm/hdd/cpu without sizes, add safe values
# - --append-defaults: add --times --metrics-brief --verify if not present
# - --repeat N: run the chosen workload(s) N iterations
# - --stability H: repeat chosen workload(s) for H hours (takes precedence)
# - --dryrun / --dry-run: validate via stress-ng --dry-run (no load), PASS on 0 exit
#
# Uses helpers from functestlib.sh:
# cpu_get_online_list_str, cpu_expand_list, cpu_snapshot_stat, cpu_get_active_ticks,
# mem_bytes_from_percent, disk_bytes_from_percent_free, file_has_pattern,
# test_finalize_result, scan_dmesg_errors, find_test_case_by_name, log_*

###############################################################################
# Source init_env + functestlib.sh
###############################################################################
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

TESTNAME="Stress-ng"
RES_FILE="./${TESTNAME}.res"
test_path=$(find_test_case_by_name "$TESTNAME") || { echo "$TESTNAME SKIP" >"$RES_FILE"; exit 0; }
cd "$test_path" || exit 1

log_info "----------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------"

###############################################################################
# Defaults / CLI
###############################################################################
P1_SECS=60
P2_SECS=60
MEM_FRAC=15
DISK_FRAC=5
CPU_LIST=""
TEMP_LIMIT=""
SETS="cpu,vmhdd"
STABILITY_HOURS=""
REPEAT=1
STRESSNG_ARGS=""
BY_CLASS=""
AUTOSIZE=0
APPEND_DEFAULTS=0
DRYRUN=0
SHOW_HELP=0

print_usage() {
cat <<EOF
Usage: $0 [--p1 <sec>] [--p2 <sec>] [--mem-frac <pct>] [--disk-frac <pct>]
          [--cpu-list <list>] [--temp-limit <degC>] [--sets <csv>]
          [--repeat <N>] [--stability <hours>] [--by-class <csv>]
          [--autosize] [--append-defaults] [--dryrun|--dry-run]
          [--stressng-args "<args>"] [--help]
          [-- <args passed verbatim to stress-ng>]
EOF
}

# Parse CLI (support pass-through after "--")
PASSTHRU=""
while [ $# -gt 0 ]; do
  case "$1" in
    --p1) shift; P1_SECS="$1" ;;
    --p2) shift; P2_SECS="$1" ;;
    --mem-frac) shift; MEM_FRAC="$1" ;;
    --disk-frac) shift; DISK_FRAC="$1" ;;
    --cpu-list) shift; CPU_LIST="$1" ;;
    --temp-limit) shift; TEMP_LIMIT="$1" ;;
    --sets) shift; SETS="$1" ;;
    --repeat) shift; REPEAT="$1" ;;
    --stability) shift; STABILITY_HOURS="$1" ;;
    --by-class) shift; BY_CLASS="$1" ;;
    --stressng-args) shift; STRESSNG_ARGS="$1" ;;
    --autosize) AUTOSIZE=1 ;;
    --append-defaults) APPEND_DEFAULTS=1 ;;
    --dryrun|--dry-run) DRYRUN=1 ;;
    --help) SHOW_HELP=1 ;;
    --) shift; PASSTHRU="$*"; break ;;
    *) log_error "Unknown argument: $1"; SHOW_HELP=1; shift; break ;;
  esac
  shift
done
[ "$SHOW_HELP" -eq 1 ] && { print_usage; exit 0; }
[ -n "$PASSTHRU" ] && STRESSNG_ARGS="$PASSTHRU"

# Validate numeric flags
if [ -n "$STABILITY_HOURS" ]; then
    case "$STABILITY_HOURS" in *[!0-9]*|"") log_error "Invalid --stability: $STABILITY_HOURS"; exit 1 ;; esac
fi
case "$REPEAT" in *[!0-9]*|"") log_error "Invalid --repeat: $REPEAT"; exit 1 ;; esac

###############################################################################
# Dependencies
###############################################################################
check_dependencies stress-ng awk grep sed cut df stat sleep date getconf || {
  test_finalize_result SKIP "$TESTNAME" "$RES_FILE" ""
}

###############################################################################
# Helpers
###############################################################################
# Run stress-ng (argv style)
run_stress() {
    logf="$1"; shift
    if [ "$DRYRUN" -eq 1 ]; then
        stress-ng --dry-run "$@" 2> "$logf" 1>/dev/null
    else
        stress-ng "$@" 2> "$logf" 1>/dev/null
    fi
    return $?
}

# Run stress-ng given a single string of args (keeps user quoting)
run_stress_str() {
    logf="$1"; shift
    args_str="$1"
    # shellcheck disable=SC2086
    eval "set -- $args_str"
    if [ "$DRYRUN" -eq 1 ]; then
        stress-ng --dry-run "$@" 2> "$logf" 1>/dev/null
    else
        stress-ng "$@" 2> "$logf" 1>/dev/null
    fi
    return $?
}

# Autosize helpers for pass-through
autosize_args() {
    args="$1"; logtmpdir="$2"; mem_pct="$3"; disk_pct="$4"
    ONLINE_STR_LOCAL=$(cpu_get_online_list_str)
    ONLINE_CPUS_LOCAL=$(cpu_expand_list "$ONLINE_STR_LOCAL")
    num_cpus=$(printf "%s\n" "$ONLINE_CPUS_LOCAL" | wc -w | tr -d ' ')
    [ "$num_cpus" -lt 1 ] && num_cpus=1

    case " $args " in
      *" --vm "*|*" -m "*)
          printf "%s" "$args" | grep -Eq -- '(^|[[:space:]])--vm-bytes([[:space:]]|=)' || {
              vm_bytes=$(mem_bytes_from_percent "$mem_pct")
              args="$args --vm-bytes $vm_bytes"
          }
          ;;
    esac
    case " $args " in
      *" --hdd "*|*" -d "*|*" --io "*|*" -i "*|*" --iomix "*)
          printf "%s" "$args" | grep -Eq -- '(^|[[:space:]])--hdd-bytes([[:space:]]|=)' || {
              hdd_bytes=$(disk_bytes_from_percent_free "$disk_pct" "$logtmpdir")
              args="$args --hdd-bytes $hdd_bytes"
          }
          printf "%s" "$args" | grep -Eq -- '(^|[[:space:]])--temp-path([[:space:]]|=)' || {
              args="$args --temp-path $logtmpdir"
          }
          ;;
    esac
    case " $args " in
      *" --cpu "*|*" -c "*)
          printf "%s" "$args" | grep -Eq -- '(^|[[:space:]])--cpu([[:space:]]+[0-9]+|=[0-9]+)' || {
              args="$args --cpu $num_cpus"
          }
          ;;
    esac

    if [ -n "$TEMP_LIMIT" ]; then
        case " $args " in *" --temp-limit "*) : ;; *) args="$args --temp-limit $TEMP_LIMIT" ;; esac
    fi

    printf "%s" "$args"
}

append_defaults() {
    args="$1"
    printf "%s" "$args" | grep -Eq -- '(^|[[:space:]])--times([[:space:]]|$)' || args="$args --times"
    printf "%s" "$args" | grep -Eq -- '(^|[[:space:]])--metrics-brief([[:space:]]|$)' || args="$args --metrics-brief"
    printf "%s" "$args" | grep -Eq -- '(^|[[:space:]])--verify([[:space:]]|$)' || args="$args --verify"
    printf "%s" "$args"
}

check_logs() {
    bad=0
    for f in "$@"; do
        [ -s "$f" ] || continue
        if file_has_pattern "$f" '0\.00[[:space:]]+ops/sec|bogo-ops:[[:space:]]*0\b'; then
            log_fail "[metrics] Zero throughput in $(basename "$f")"; bad=1
        fi
        if file_has_pattern "$f" 'out of memory|cannot allocate|disk full|no space left|I/O error|filesystem error|timer slack'; then
            log_fail "[metrics] Resource error in $(basename "$f")"; bad=1
        fi
    done
    return $bad
}

find_newest_log_dir() {
    prefix="$1"
    LAST_LOG=""
    last_mtime=0
    list_file="./.logscan_${TESTNAME}_$$.lst"
    find . -maxdepth 1 -type d -name "${prefix}*" -print 2>/dev/null > "$list_file"
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        if stat -c %Y "$d" >/dev/null 2>&1; then
            mtime=$(stat -c %Y "$d")
        elif stat -f %m "$d" >/dev/null 2>&1; then
            mtime=$(stat -f %m "$d")
        else
            mtime=0
        fi
        case "$mtime" in *[!0-9]*|"") mtime=0 ;; esac
        if [ "$mtime" -ge "$last_mtime" ] 2>/dev/null; then
            last_mtime="$mtime"; LAST_LOG="$d"
        fi
    done < "$list_file"
    rm -f "$list_file"
    [ -n "$LAST_LOG" ] && printf "%s\n" "$LAST_LOG" || printf ".\n"
}

###############################################################################
# Built-in “auto sets”
###############################################################################
run_auto_set() {
    name="$1" LOG_DIR="$2" NUM_CPUS="$3" VM_WORKERS="$4" HDD_WORKERS="$5" VM_BYTES="$6" HDD_BYTES="$7"

    case "$name" in
      cpu)
        log_info "[cpu] --cpu $NUM_CPUS --matrix $NUM_CPUS --timeout ${P1_SECS}s"
        if [ -n "$TEMP_LIMIT" ]; then
          run_stress "$LOG_DIR/cpu.log" \
            --cpu "$NUM_CPUS" --cpu-method all \
            --matrix "$NUM_CPUS" \
            --timeout "${P1_SECS}s" --times --metrics-brief \
            --temp-limit "$TEMP_LIMIT" \
            --verify
        else
          run_stress "$LOG_DIR/cpu.log" \
            --cpu "$NUM_CPUS" --cpu-method all \
            --matrix "$NUM_CPUS" \
            --timeout "${P1_SECS}s" --times --metrics-brief \
            --verify
        fi
        return $?
        ;;
      vmhdd)
        log_info "[vmhdd] --vm $VM_WORKERS --vm-bytes $VM_BYTES --hdd $HDD_WORKERS --hdd-bytes $HDD_BYTES --timeout ${P2_SECS}s"
        if [ -n "$TEMP_LIMIT" ]; then
          run_stress "$LOG_DIR/vmhdd.log" \
            --vm "$VM_WORKERS" --vm-bytes "$VM_BYTES" --vm-keep \
            --hdd "$HDD_WORKERS" --hdd-bytes "$HDD_BYTES" \
            --timeout "${P2_SECS}s" --times --metrics-brief \
            --temp-limit "$TEMP_LIMIT" \
            --verify --temp-path "$LOG_DIR/tmp"
        else
          run_stress "$LOG_DIR/vmhdd.log" \
            --vm "$VM_WORKERS" --vm-bytes "$VM_BYTES" --vm-keep \
            --hdd "$HDD_WORKERS" --hdd-bytes "$HDD_BYTES" \
            --timeout "${P2_SECS}s" --times --metrics-brief \
            --verify --temp-path "$LOG_DIR/tmp"
        fi
        return $?
        ;;
      io)
        log_info "[io] --hdd $HDD_WORKERS --hdd-bytes $HDD_BYTES --timeout ${P2_SECS}s"
        if [ -n "$TEMP_LIMIT" ]; then
          run_stress "$LOG_DIR/io.log" \
            --hdd "$HDD_WORKERS" --hdd-bytes "$HDD_BYTES" \
            --timeout "${P2_SECS}s" --times --metrics-brief \
            --temp-limit "$TEMP_LIMIT" \
            --verify --temp-path "$LOG_DIR/tmp"
        else
          run_stress "$LOG_DIR/io.log" \
            --hdd "$HDD_WORKERS" --hdd-bytes "$HDD_BYTES" \
            --timeout "${P2_SECS}s" --times --metrics-brief \
            --verify --temp-path "$LOG_DIR/tmp"
        fi
        return $?
        ;;
      *) log_warn "Unknown set '$name' (skipping)"; return 0 ;;
    esac
}

###############################################################################
# One iteration (auto / pass-through / by-class)
###############################################################################
run_iteration() {
    ITER_TAG="$1"
    FAIL=0

    LOG_ROOT="./logs_${TESTNAME}_${ITER_TAG}"
    mkdir -p "$LOG_ROOT/tmp" || { log_error "Cannot create $LOG_ROOT/tmp"; return 1; }

    ONLINE_STR=$(cpu_get_online_list_str)
    ONLINE_CPUS=$(cpu_expand_list "$ONLINE_STR")
    [ -n "$ONLINE_CPUS" ] || { log_fail "Cannot determine online CPUs"; return 1; }

    if [ -n "$CPU_LIST" ]; then REQ=$(cpu_expand_list "$CPU_LIST"); else REQ="$ONLINE_CPUS"; fi
    USE_SET=""
    for c in $REQ; do
        printf "%s\n" "$ONLINE_CPUS" | grep -Eq "(^|[[:space:]])$c($|[[:space:]])" && USE_SET="$USE_SET $c"
    done
    USE_SET=$(printf "%s\n" "$USE_SET")
    [ -n "$USE_SET" ] || { log_skip "$TESTNAME SKIP – no valid CPUs from requested set"; return 1; }
    NUM_CPUS=$(printf "%s\n" "$USE_SET" | wc -w | tr -d ' ')
    [ "$NUM_CPUS" -lt 1 ] && NUM_CPUS=1

    VM_WORKERS=$(( (NUM_CPUS + 1) / 2 ))
    HDD_WORKERS=1
    VM_BYTES=$(mem_bytes_from_percent "$MEM_FRAC")
    HDD_BYTES=$(disk_bytes_from_percent_free "$DISK_FRAC" "$LOG_ROOT/tmp")
    CLK_TCK=$(getconf CLK_TCK 2>/dev/null); [ -z "$CLK_TCK" ] && CLK_TCK=100

    log_info "Iteration: $ITER_TAG"
    log_info "CPUs online: $ONLINE_STR"
    log_info "Using CPUs: $(printf "%s " "$USE_SET")"
    log_info "VM per-worker: $VM_BYTES | HDD per-worker: $HDD_BYTES"
    [ -n "$TEMP_LIMIT" ] && log_info "Temp limit: ${TEMP_LIMIT}°C"
    [ "$DRYRUN" -eq 1 ] && log_info "Mode: DRY-RUN (validation only; no load)"
    log_info "Logs: $LOG_ROOT"

    if [ "$DRYRUN" -eq 0 ]; then
        cpu_snapshot_stat "$LOG_ROOT/stat_before"
    fi

    if [ -n "$BY_CLASS" ]; then
        classes=$(printf "%s" "$BY_CLASS" | tr ',' ' ')
        for cls in $classes; do
            args="$STRESSNG_ARGS --class $cls"
            [ "$APPEND_DEFAULTS" -eq 1 ] && args=$(append_defaults "$args")
            [ "$AUTOSIZE" -eq 1 ] && args=$(autosize_args "$args" "$LOG_ROOT/tmp" "$MEM_FRAC" "$DISK_FRAC")
            log_info "[class:$cls] stress-ng $args"
            run_stress_str "$LOG_ROOT/class_$cls.log" "$args"
            rc=$?; [ "$rc" -eq 0 ] || { log_fail "[class:$cls] exited $rc"; FAIL=1; break; }
        done
        if [ "$DRYRUN" -eq 0 ]; then check_logs "$LOG_ROOT"/class_*.log || FAIL=1; fi

    elif [ -n "$STRESSNG_ARGS" ]; then
        args="$STRESSNG_ARGS"
        [ "$APPEND_DEFAULTS" -eq 1 ] && args=$(append_defaults "$args")
        [ "$AUTOSIZE" -eq 1 ] && args=$(autosize_args "$args" "$LOG_ROOT/tmp" "$MEM_FRAC" "$DISK_FRAC")
        log_info "[custom] stress-ng $args"
        run_stress_str "$LOG_ROOT/custom.log" "$args"
        rc=$?; [ "$rc" -eq 0 ] || { log_fail "[custom] exited $rc"; FAIL=1; }
        if [ "$DRYRUN" -eq 0 ]; then check_logs "$LOG_ROOT/custom.log" || FAIL=1; fi

    else
        for s in $(printf "%s" "$SETS" | tr ',' ' '); do
            if run_auto_set "$s" "$LOG_ROOT" "$NUM_CPUS" "$VM_WORKERS" "$HDD_WORKERS" "$VM_BYTES" "$HDD_BYTES"; then
                log_pass "Set '$s' PASS"
            else
                log_fail "Set '$s' FAIL"; FAIL=1; break
            fi
        done
        if [ "$DRYRUN" -eq 0 ]; then
            check_logs "$LOG_ROOT"/cpu.log "$LOG_ROOT"/vmhdd.log "$LOG_ROOT"/io.log || FAIL=1
        fi
    fi

    if [ "$DRYRUN" -eq 0 ]; then
        cpu_snapshot_stat "$LOG_ROOT/stat_after"

        # Compute TOTAL_SECS based on sets actually configured (cpu adds P1, vmhdd/io add P2)
        TOTAL_SECS=0
        case ",$SETS," in
          *,cpu,*) TOTAL_SECS=$((TOTAL_SECS + P1_SECS)) ;;
        esac
        case ",$SETS," in
          *,vmhdd,*) TOTAL_SECS=$((TOTAL_SECS + P2_SECS)) ;;
        esac
        case ",$SETS," in
          *,io,*) TOTAL_SECS=$((TOTAL_SECS + P2_SECS)) ;;
        esac
        [ "$TOTAL_SECS" -le 0 ] && TOTAL_SECS=$((P1_SECS + P2_SECS))

        # Heuristic CPU activity check only for auto sets
        if [ -z "$STRESSNG_ARGS" ] && [ -z "$BY_CLASS" ]; then
            THRESH=$(( (TOTAL_SECS * CLK_TCK) / 8 )); [ "$THRESH" -lt 5 ] && THRESH=5
            ok=0; total=0
            for c in $USE_SET; do
              b=$(cpu_get_active_ticks "$c" "$LOG_ROOT/stat_before")
              a=$(cpu_get_active_ticks "$c" "$LOG_ROOT/stat_after")
              [ -z "$b" ] || [ -z "$a" ] && continue
              d=$((a-b)); total=$((total+1))
              log_info "[load] cpu$c delta=$d (thr=$THRESH)"
              [ "$d" -ge "$THRESH" ] && ok=$((ok+1))
            done
            need=$(( (total*50 + 99) / 100 )) # >= 50%
            if [ "$ok" -lt "$need" ]; then log_fail "[load] Insufficient CPU activity ($ok/$total)"; FAIL=1
            else log_pass "[load] CPU activity sufficient ($ok/$total)"; fi
        fi

        DMESG_MODULES='BUG:|WARNING:|rcu|lockdep|hung task|soft lockup|hard lockup|oops|stack trace|call trace'
        DMESG_EXCLUDE='dummy regulator|not found|-EEXIST|thermal throttle'
        if scan_dmesg_errors "$SCRIPT_DIR" "$DMESG_MODULES" "$DMESG_EXCLUDE"; then
            log_fail "Concerning kernel messages during stress (logs in $LOG_ROOT)"; FAIL=1
        else
            log_pass "No concerning kernel messages during stress"
        fi
    else
        log_info "Dry-run: skipped CPU activity and dmesg checks"
    fi

    [ "$FAIL" -eq 0 ]
    return $?
}

###############################################################################
# Single run / repeat loop / stability loop
###############################################################################
NEWEST_LOG="."
if [ -n "$STABILITY_HOURS" ]; then
    END_TS=$(( $(date +%s) + STABILITY_HOURS*3600 ))
    ITER=1
    ANY_FAIL=0
    while : ; do
        now=$(date +%s)
        [ "$now" -ge "$END_TS" ] && break
        TAG="iter${ITER}_$(date +%Y%m%d-%H%M%S)"
        log_info "===== Stability: $TESTNAME iteration $ITER ====="
        if run_iteration "$TAG"; then
            log_pass "Iteration $ITER PASS"
        else
            log_fail "Iteration $ITER FAIL"; ANY_FAIL=1; break
        fi
        ITER=$((ITER+1))
    done
    NEWEST_LOG=$(find_newest_log_dir "logs_${TESTNAME}_")
    if [ "$ANY_FAIL" -eq 0 ]; then
        test_finalize_result PASS "$TESTNAME" "$RES_FILE" "$NEWEST_LOG"
    else
        test_finalize_result FAIL "$TESTNAME" "$RES_FILE" "$NEWEST_LOG"
    fi
else
    i=1
    ANY_FAIL=0
    while [ "$i" -le "$REPEAT" ]; do
        TAG="iter${i}_$(date +%Y%m%d-%H%M%S)"
        log_info "===== Repeat: $TESTNAME iteration $i/$REPEAT ====="
        if run_iteration "$TAG"; then
            log_pass "Iteration $i PASS"
        else
            log_fail "Iteration $i FAIL"; ANY_FAIL=1; break
        fi
        i=$((i+1))
    done
    NEWEST_LOG=$(find_newest_log_dir "logs_${TESTNAME}_")
    if [ "$ANY_FAIL" -eq 0 ]; then
        test_finalize_result PASS "$TESTNAME" "$RES_FILE" "$NEWEST_LOG"
    else
        test_finalize_result FAIL "$TESTNAME" "$RES_FILE" "$NEWEST_LOG"
    fi
fi
