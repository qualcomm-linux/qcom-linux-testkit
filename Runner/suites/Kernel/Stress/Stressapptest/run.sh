#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# stressapptest/run.sh
# Safe wrapper around stressapptest for embedded/CI use.
# Memory-safety features: --mem-pct, --mem-cap-mb, --mem-headroom-mb,
# --require-mem-mb, cgroup-aware sizing, JSON summaries, loops, NUMA, etc.

###############################################################################
# Boilerplate: locate and source init_env + functestlib.sh
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

TESTNAME="Stressapptest"
RES_FILE="./${TESTNAME}.res"
LOG_FILE="./${TESTNAME}.log"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
cd "$test_path" || exit 1

log_info "----------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------"
log_info "=== Test Initialization ==="

###############################################################################
# Usage
###############################################################################
print_usage() {
cat <<EOF
Usage: $0 [options]

Forwarded to stressapptest:
  -M <MB> Memory to test (default: ~60% MemAvailable or --mem-pct)
  -s <sec> Duration seconds (default: 300; safe: 120)
  -m <thr> Memory copy threads (default: online CPUs; safe: ~half)
  -W More CPU-stressful memory copy
  -n <ip> Network client thread to <ip>
  --listen Run a listen thread for network tests
  -f <file> Add a disk thread using tempfile <file>
  -F Use libc memcpy (skip per-transaction result check)
  -l <file> Log file (default: ./Stressapptest.log)
  -v <lvl> Verbosity 0-20 (default: 8)

Wrapper-specific (CLI flags and/or ENV equivalents):
  --safe (SAFE=1) Conservative limits
  --dry-run (DRYRUN=1) Print command and exit
  --strict (STRICT=1) Fail on critical dmesg issues
  --auto-net[=mode] (AUTO_NET=1, AUTO_NET_MODE=primary|loopback)
  --auto-disk (AUTO_DISK=1)
  --auto shorthand for --auto-net --auto-disk

Memory sizing (cgroup-aware):
  --mem-pct=<P> (MEM_PCT) Percent of MemAvailable (def 60; safe 35)
  --mem-cap-mb=<MB> (MEM_CAP_MB) Hard upper cap in MB
  --mem-headroom-mb=<MB> (MEM_HEADROOM_MB) Reserve MB from available
  --require-mem-mb=<MB> (REQUIRE_MEM_MB) Require at least MB or FAIL

Control / reporting:
  --loops=<N> (LOOPS) Repeat N times (def 1)
  --loop-delay=<S> (LOOP_DELAY) Sleep S sec between loops (def 0)
  --json=<file> (JSON_OUT) Write JSON per loop + aggregate
EOF
}

###############################################################################
# Parse CLI (+ allow ENV defaults)
###############################################################################
# ENV defaults first (so CLI can override)
SAFE="${SAFE:-0}"; DRYRUN="${DRYRUN:-0}"; STRICT="${STRICT:-0}"
AUTO_NET="${AUTO_NET:-0}"; AUTO_NET_MODE="${AUTO_NET_MODE:-primary}"
AUTO_DISK="${AUTO_DISK:-0}"
MEM_PCT="${MEM_PCT:-}"; MEM_CAP_MB="${MEM_CAP_MB:-}"; MEM_HEADROOM_MB="${MEM_HEADROOM_MB:-}"
REQUIRE_MEM_MB="${REQUIRE_MEM_MB:-}"
LOOPS="${LOOPS:-1}"; LOOP_DELAY="${LOOP_DELAY:-0}"
JSON_OUT="${JSON_OUT:-}"

USER_M="" USER_S="" USER_m="" USER_W=0 USER_n="" USER_listen=0 USER_f="" USER_F=0 USER_l="" USER_v=""

while [ $# -gt 0 ]; do
    case "$1" in
        -M) shift; USER_M="$1" ;;
        -s) shift; USER_S="$1" ;;
        -m) shift; USER_m="$1" ;;
        -W) USER_W=1 ;;
        -n) shift; USER_n="$1" ;;
        --listen) USER_listen=1 ;;
        -f) shift; USER_f="$1" ;;
        -F) USER_F=1 ;;
        -l) shift; USER_l="$1" ;;
        -v) shift; USER_v="$1" ;;
        --safe) SAFE=1 ;;
        --dry-run) DRYRUN=1 ;;
        --strict) STRICT=1 ;;
        --auto-net) AUTO_NET=1 ;;
        --auto-net=*) AUTO_NET=1; AUTO_NET_MODE="${1#--auto-net=}";;
        --auto-disk) AUTO_DISK=1 ;;
        --auto) AUTO_NET=1; AUTO_DISK=1 ;;
        --mem-pct=*) MEM_PCT="${1#--mem-pct=}" ;;
        --mem-cap-mb=*) MEM_CAP_MB="${1#--mem-cap-mb=}" ;;
        --mem-headroom-mb=*) MEM_HEADROOM_MB="${1#--mem-headroom-mb=}" ;;
        --require-mem-mb=*) REQUIRE_MEM_MB="${1#--require-mem-mb=}" ;;
        --loops=*) LOOPS="${1#--loops=}" ;;
        --loop-delay=*) LOOP_DELAY="${1#--loop-delay=}" ;;
        --json=*) JSON_OUT="${1#--json=}" ;;
        --help) print_usage; exit 0 ;;
        *) log_warn "Ignoring unknown option: $1" ;;
    esac
    shift
done

# Validate simple enums
case "$AUTO_NET_MODE" in primary|loopback) : ;; *) log_warn "Unknown --auto-net mode '$AUTO_NET_MODE', using 'primary'"; AUTO_NET_MODE="primary";; esac

###############################################################################
# Dependencies (getconf optional; fallback if missing)
###############################################################################
check_dependencies stressapptest awk grep sed || {
    log_skip "$TESTNAME SKIP - required tools missing"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
}
for t in df cut head tail sort tr stat ip hostname nproc getconf taskset; do
    command -v "$t" >/dev/null 2>&1 || true
done

###############################################################################
# Helpers
###############################################################################
# Expand "0-3,5,7" into "0 1 2 3 5 7"
expand_list() {
    in="$1"; oldIFS=$IFS; IFS=,; out=""
    for part in $in; do
        part=$(printf "%s" "$part" | tr -d ' ')
        case "$part" in
            *-*) a=${part%-*}; b=${part#*-}; i="$a"; while [ "$i" -le "$b" ] 2>/dev/null; do out="$out $i"; i=$((i+1)); done;;
            '') ;;
            *) out="$out $part" ;;
        esac
    done
    IFS=$oldIFS; printf "%s\n" "$out"
}

# Detect online CPUs (prefer /sys; else getconf; else nproc; else /proc/cpuinfo)
detect_online_cpus() {
    ONLINE_STR=""
    if [ -r /sys/devices/system/cpu/online ]; then
        ONLINE_STR=$(cat /sys/devices/system/cpu/online 2>/dev/null)
    fi
    if [ -z "$ONLINE_STR" ]; then
        n=""
        if command -v getconf >/dev/null 2>&1; then n=$(getconf _NPROCESSORS_ONLN 2>/dev/null); fi
        if [ -z "$n" ] || ! [ "$n" -gt 0 ] 2>/dev/null; then
            if command -v nproc >/dev/null 2>&1; then n=$(nproc 2>/dev/null); fi
        fi
        if [ -z "$n" ] || ! [ "$n" -gt 0 ] 2>/dev/null; then
            n=$(awk -F: '/^processor[ \t]*:/{c++} END{print c+0}' /proc/cpuinfo 2>/dev/null)
        fi
        [ -z "$n" ] && n=1
        i=0; out=""
        while [ "$i" -lt "$n" ]; do out="$out,$i"; i=$((i+1)); done
        ONLINE_STR="${out#,}"
    fi
    ONLINE_CPUS=$(expand_list "$ONLINE_STR")
    [ -n "$ONLINE_CPUS" ] || ONLINE_CPUS="0"
    CPU_COUNT=$(printf "%s\n" $ONLINE_CPUS | wc -l | tr -d ' ')
}
detect_online_cpus

# Return online NUMA nodes as CSV (e.g. "0,1")
nodes_online() {
    if [ -r /sys/devices/system/node/online ]; then
        sed 's/-/,/g' /sys/devices/system/node/online
    else
        echo 0
    fi
}

# Detect cpuset controller availability (cgroup v2 or v1)
cpuset_supported() {
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        grep -qw cpuset /sys/fs/cgroup/cgroup.controllers
        return $?
    fi
    [ -d /sys/fs/cgroup/cpuset ]
}

# Run a command confined to a CPU list via cpuset cgroups (v2 or v1).
# Usage: run_with_cpuset "0-3,6" 'sh -c "your cmd"'
run_with_cpuset() {
    cpus="$1"; shift
    cmd="$*"

    # cgroup v2
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        cg="/sys/fs/cgroup/sat.$$"
        mkdir "$cg" 2>/dev/null || return 1
        mems="$(nodes_online)"
        echo "$cpus" > "$cg/cpuset.cpus" 2>/dev/null || { rmdir "$cg" 2>/dev/null; return 1; }
        echo "$mems" > "$cg/cpuset.mems" 2>/dev/null || { rmdir "$cg" 2>/dev/null; return 1; }

        sh -c "$cmd" &
        pid=$!
        echo "$pid" > "$cg/cgroup.procs" 2>/dev/null || true
        wait "$pid"; ret=$?
        rmdir "$cg" 2>/dev/null || true
        return $ret
    fi

    # cgroup v1
    if [ -d /sys/fs/cgroup/cpuset ]; then
        cg="/sys/fs/cgroup/cpuset/sat.$$"
        mkdir "$cg" 2>/dev/null || return 1
        if [ -r /sys/fs/cgroup/cpuset/cpuset.mems ]; then
            parent_mems=$(cat /sys/fs/cgroup/cpuset/cpuset.mems)
        else
            parent_mems="0"
        fi
        echo "$cpus" > "$cg/cpuset.cpus" 2>/dev/null || { rmdir "$cg" 2>/dev/null; return 1; }
        echo "$parent_mems" > "$cg/cpuset.mems" 2>/dev/null || { rmdir "$cg" 2>/dev/null; return 1; }

        sh -c "$cmd" &
        pid=$!
        echo "$pid" > "$cg/tasks" 2>/dev/null || true
        wait "$pid"; ret=$?
        rmdir "$cg" 2>/dev/null || true
        return $ret
    fi

    # Fallback: cpuset not supported
    sh -c "$cmd"
}

###############################################################################
# Core configuration (duration, memory, threads)
###############################################################################
if [ -n "$USER_S" ]; then DURATION="$USER_S"; else DURATION=$([ "$SAFE" -eq 1 ] && echo 120 || echo 300); fi

# cgroup-aware available memory (kB), prefer v2; fallback to meminfo
cgroup_available_kb() {
    # v2
    if [ -r /sys/fs/cgroup/memory.max ] && [ -r /sys/fs/cgroup/memory.current ]; then
        max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
        if [ "$max" != "max" ] && [ -n "$max" ] && [ -n "$cur" ]; then
            awk -v max="$max" -v cur="$cur" 'BEGIN{d=max-cur; if(d<0)d=0; print int(d/1024)}'
            return
        fi
    fi
    # v1
    if [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ] && [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
        max=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        cur=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)
        if [ -n "$max" ] && [ -n "$cur" ] && [ "$max" -gt 0 ] 2>/dev/null; then
            awk -v max="$max" -v cur="$cur" 'BEGIN{d=max-cur; if(d<0)d=0; print int(d/1024)}'
            return
        fi
    fi
    echo ""
}

MEM_DEBUG=""
calc_mem_mb() {
    avail_kb=$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    [ -z "$avail_kb" ] && avail_kb=$(awk '/MemFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    [ -z "$avail_kb" ] && avail_kb=262144

    cg_kb="$(cgroup_available_kb)"
    if [ -n "$cg_kb" ] && [ "$cg_kb" -gt 0 ] 2>/dev/null; then
        avail_kb="$cg_kb"; cg_note="(cgroup)"
    else
        cg_note=""
    fi

    pct="$MEM_PCT"; [ -z "$pct" ] && pct=$([ "$SAFE" -eq 1 ] && echo 35 || echo 60)
    # default headroom
    if [ -z "$MEM_HEADROOM_MB" ]; then head_mb=$([ "$SAFE" -eq 1 ] && echo 512 || echo 256); else head_mb="$MEM_HEADROOM_MB"; fi

    use_kb=$(( avail_kb * pct / 100 ))
    max_usable_kb=$(( avail_kb - head_mb * 1024 )); [ "$max_usable_kb" -lt 0 ] && max_usable_kb=0
    [ "$use_kb" -gt "$max_usable_kb" ] && use_kb="$max_usable_kb"

    if [ -n "$MEM_CAP_MB" ]; then
        cap_kb=$(( MEM_CAP_MB * 1024 ))
        [ "$use_kb" -gt "$cap_kb" ] && use_kb="$cap_kb"
        cap_note="$MEM_CAP_MB MB"
    else
        cap_note="none"
    fi

    # Final sanity: floor 16MB, and never above max_usable
    [ "$use_kb" -lt 16384 ] && use_kb=16384
    [ "$use_kb" -gt "$max_usable_kb" ] && use_kb="$max_usable_kb"

    MEM_DEBUG="MemAvailable=${avail_kb}kB${cg_note} pct=${pct}% headroom=${head_mb}MB cap=${cap_note}"
    echo $(( use_kb / 1024 ))
}

if [ -n "$USER_M" ]; then
    MEM_MB="$USER_M"
    MEM_DEBUG="(user override) $MEM_MB MB"
else
    MEM_MB="$(calc_mem_mb)"
fi

# Hard requirement: require at least N MB or FAIL
if [ -n "$REQUIRE_MEM_MB" ]; then
    if [ "$MEM_MB" -lt "$REQUIRE_MEM_MB" ] 2>/dev/null; then
        log_fail "Memory target $MEM_MB MB < required $REQUIRE_MEM_MB MB; refusing to run"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
fi

# Threads
if [ -n "$USER_m" ]; then
    MEM_THREADS="$USER_m"
else
    if [ "$CPU_COUNT" -gt 1 ] && [ "$SAFE" -eq 1 ]; then
        half=$(( (CPU_COUNT + 1) / 2 )); [ "$half" -lt 1 ] && half=1; [ "$half" -gt 4 ] && half=4
        MEM_THREADS="$half"
    else
        MEM_THREADS="$CPU_COUNT"
    fi
fi

# CPU subset for SAFE mode
SUBSET_STR="$ONLINE_STR"
if [ "$SAFE" -eq 1 ]; then
    i=0; subset=""
    for c in $ONLINE_CPUS; do subset="$subset,$c"; i=$((i+1)); [ "$i" -ge "$MEM_THREADS" ] && break; done
    SUBSET_STR="${subset#,}"
fi

VERBOSITY="${USER_v:-8}"
LOG_FILE="${USER_l:-$LOG_FILE}"

###############################################################################
# Auto NET + listener
###############################################################################
pick_primary_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src"){print $(i+1); exit}}'
    else
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}
LISTENER_PID=""; LISTEN_LOG=""
if [ "$AUTO_NET" -eq 1 ]; then
    if [ "$USER_listen" -eq 0 ]; then
        LISTEN_LOG="./stressapptest-listener.log"
        log_info "Auto-net: starting local listener for ${DURATION}s"
        stressapptest --listen -s $((DURATION + 15)) -l "$LISTEN_LOG" >/dev/null 2>&1 &
        LISTENER_PID=$!; USER_listen=1
    fi
    if [ -z "$USER_n" ]; then
        if [ "$AUTO_NET_MODE" = "primary" ]; then
            ip_addr="$(pick_primary_ip)"
            if [ -n "$ip_addr" ]; then USER_n="$ip_addr"; log_info "Auto-net: primary IP detected: $USER_n"; else USER_n="127.0.0.1"; log_warn "Auto-net: primary IP unavailable; using loopback"; fi
        else
            USER_n="127.0.0.1"; log_info "Auto-net: using loopback (127.0.0.1)"
        fi
    fi
fi

###############################################################################
# Auto DISK: pick writable mount
###############################################################################
TMPF=""
if [ "$AUTO_DISK" -eq 1 ] && [ -z "$USER_f" ]; then
    if command -v df >/dev/null 2>&1; then
        best_mp=""; best_free=0
        while read -r _dev mp fstype opts _; do
            case "$fstype" in proc|sysfs|devtmpfs|devpts|cgroup*|pstore|debugfs|tracefs|configfs|securityfs|overlay) continue ;; esac
            echo "$opts" | grep -qw ro && continue
            free=$(df -Pm "$mp" 2>/dev/null | awk 'NR==2 {print $4+0}')
            [ -z "$free" ] && free=0
            if [ "$free" -gt "$best_free" ]; then best_free="$free"; best_mp="$mp"; fi
        done < /proc/mounts
        if [ -n "$best_mp" ] && [ "$best_free" -gt 128 ]; then
            TMPF="$best_mp/stressapptest.$$.tmp"; USER_f="$TMPF"
            log_info "Auto-disk: '${best_mp}' (free=${best_free}M), file=$TMPF"
        else
            log_warn "Auto-disk: no suitable writable mount"
        fi
    else
        log_warn "Auto-disk requested but 'df' not available; skipping"
    fi
fi

cleanup_auto_bits() {
    [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null
    [ -n "$TMPF" ] && rm -f "$TMPF" 2>/dev/null
}
trap cleanup_auto_bits EXIT INT TERM

###############################################################################
# dmesg patterns (always scan; STRICT decides fatal vs warn)
###############################################################################
DMESG_MODULES='oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error|AER|EDAC|Machine check'
DMESG_EXCLUDE='using dummy regulator|not found|No NUMA|EEXIST|AER: Corrected error'
DMESG_MODULES_STRICT='(Out of memory|oom-killer|invoked oom-killer|Kernel panic|panic|BUG:|Oops|general protection fault|Unable to handle kernel NULL pointer|Call Trace:|hung task|soft lockup|hard lockup|rcu_sched self-detected stall|page allocation failure|I/O error|EXT4-fs error|BTRFS: error|XFS .* Internal error|EDAC|Machine check|AER: Uncorrected)'
DMESG_EXCLUDE_STRICT='thermal throttle|probe deferred|Bluetooth: hci0: advertising data|irq .* affinity broken|AER: Corrected'

###############################################################################
# Build SAT command
###############################################################################
build_sat_cmd() {
    c="stressapptest -s $DURATION -M $MEM_MB -m $MEM_THREADS -v $VERBOSITY"
    [ "$USER_W" -eq 1 ] && c="$c -W"
    [ -n "$USER_n" ] && c="$c -n $USER_n"
    [ "$USER_listen" -eq 1 ] && c="$c --listen"
    [ -n "$USER_f" ] && c="$c -f $USER_f"
    [ "$USER_F" -eq 1 ] && c="$c -F"
    [ -n "$LOG_FILE" ] && c="$c -l $LOG_FILE"
    echo "$c"
}

# Keep wrap_affinity minimal: only taskset if present; cpuset fallback.
wrap_affinity() {
    c="$1"
    if command -v taskset >/dev/null 2>&1; then
        masklist="$( [ "$SAFE" -eq 1 ] && echo "$SUBSET_STR" || echo "$ONLINE_STR" )"
        echo "taskset -a -c \"$masklist\" sh -c \"$c\""
    else
        echo "sh -c \"$c\""
    fi
}

###############################################################################
# Looped execution
###############################################################################
PASS_COUNT=0 FAIL_COUNT=0 STRICT_FAIL=0
RUN=1
while [ "$RUN" -le "$LOOPS" ]; do
    [ "$LOOPS" -gt 1 ] && log_info "===== Loop $RUN/$LOOPS ====="

    log_info "Mode: $( [ "$SAFE" -eq 1 ] && echo SAFE || echo NORMAL )"
    log_info "Online CPUs: $ONLINE_STR (count=$CPU_COUNT)"
    [ "$SAFE" -eq 1 ] && log_info "CPU subset: $SUBSET_STR"
    log_info "Config: duration=${DURATION}s mem=${MEM_MB}MB threads=${MEM_THREADS} verbosity=$VERBOSITY"
    log_info "Memory sizing: $MEM_DEBUG"
    [ -n "$USER_n" ] && log_info "Network: client to $USER_n (listener=$( [ "$USER_listen" -eq 1 ] && echo yes || echo no ))"
    [ -n "$USER_f" ] && log_info "Disk: tempfile $USER_f"

    CMD="$(build_sat_cmd)"
    WRAPPED_CMD="$(wrap_affinity "$CMD")"
    log_info "Command: $CMD"

    if [ "$DRYRUN" -eq 1 ]; then
        log_info "[Dry-run] Command that would execute (wrapped):"
        echo "$WRAPPED_CMD"
        echo "$TESTNAME DRY-RUN" >"$RES_FILE"
        exit 0
    fi

    START_TS=$(date +%s)

    masklist="$( [ "$SAFE" -eq 1 ] && echo "$SUBSET_STR" || echo "$ONLINE_STR" )"
    if command -v taskset >/dev/null 2>&1; then
        log_info "CPU pinning method: taskset ($masklist)"
        sh -c "$WRAPPED_CMD" >>"$LOG_FILE" 2>&1
        RET=$?
    else
        if cpuset_supported; then
            log_info "CPU pinning method: cgroup cpuset ($masklist)"
            run_with_cpuset "$masklist" "sh -c \"$CMD\" >>\"$LOG_FILE\" 2>&1"
            RET=$?
        else
            log_info "CPU pinning method: none (no taskset/cpuset)"
            sh -c "$CMD" >>"$LOG_FILE" 2>&1
            RET=$?
        fi
    fi

    END_TS=$(date +%s)
    ELAPSED=$((END_TS - START_TS))

    if [ $RET -eq 0 ]; then
        log_pass "$TESTNAME: completed OK in ${ELAPSED}s"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        log_fail "$TESTNAME: returned $RET (see $LOG_FILE)"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi

    # Always scan dmesg; STRICT decides whether to fail or warn.
    if [ "$STRICT" -eq 1 ]; then
        if scan_dmesg_errors "$SCRIPT_DIR" "$DMESG_MODULES_STRICT" "$DMESG_EXCLUDE_STRICT"; then
            log_fail "Strict mode: critical kernel issues detected (see dmesg_errors*.log)"
            STRICT_FAIL=1
        else
            log_info "Strict mode: no critical kernel issues detected"
        fi
    else
        if scan_dmesg_errors "$SCRIPT_DIR" "$DMESG_MODULES" "$DMESG_EXCLUDE"; then
            log_warn "Potential kernel messages detected (see dmesg_errors*.log)"
        else
            log_info "No concerning kernel messages in dmesg (non-strict)"
        fi
    fi

    if [ -n "$JSON_OUT" ]; then
        {
            printf '{'
            printf '"loop":%s,' "$RUN"
            printf '"start_ts":%s,' "$START_TS"
            printf '"end_ts":%s,' "$END_TS"
            printf '"elapsed":%s,' "$ELAPSED"
            printf '"ret":%s,' "$RET"
            printf '"mem_mb":%s,' "$MEM_MB"
            printf '"threads":%s,' "$MEM_THREADS"
            printf '"duration_s":%s,' "$DURATION"
            printf '"mode":"%s",' "$( [ "$SAFE" -eq 1 ] && echo SAFE || echo NORMAL )"
            printf '"mem_debug":"%s",' "$MEM_DEBUG"
            printf '"log":"%s"' "$LOG_FILE"
            printf '}\n'
        } >> "$JSON_OUT"
    fi

    [ "$RUN" -lt "$LOOPS" ] && [ "$LOOP_DELAY" -gt 0 ] && sleep "$LOOP_DELAY"
    RUN=$((RUN+1))
done

if [ -n "$JSON_OUT" ]; then
    {
        printf '{'
        printf '"aggregate":{"loops":%s,"pass":%s,"fail":%s,"strict_fail":%s}\n' "$LOOPS" "$PASS_COUNT" "$FAIL_COUNT" "$STRICT_FAIL"
        printf '}\n'
    } >> "$JSON_OUT"
fi

###############################################################################
# Final result
###############################################################################
if [ "$FAIL_COUNT" -gt 0 ] || [ "$STRICT_FAIL" -ne 0 ]; then
    FINAL_FAIL=1
else
    FINAL_FAIL=0
fi

if [ $FINAL_FAIL -eq 0 ] ; then
    echo "$TESTNAME PASS" >"$RES_FILE"
    exit 0
else
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi
