#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# ---------- Repo env + helpers ----------
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

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_performance.sh"

TESTNAME="Stressapptest"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
test_result_init "$TESTNAME" "$RES_FILE"
RUN_DIR=$(test_create_run_directory "$SCRIPT_DIR/logs") || test_result_finish FAIL "Cannot create evidence directory"
SAFE=${SAFE:-0}
DRYRUN=${DRYRUN:-0}
STRICT=${STRICT:-0}
AUTO_NET=${AUTO_NET:-0}
AUTO_NET_MODE=${AUTO_NET_MODE:-primary}
AUTO_DISK=${AUTO_DISK:-0}
MEM_PCT=${MEM_PCT:-}
MEM_CAP_MB=${MEM_CAP_MB:-}
MEM_HEADROOM_MB=${MEM_HEADROOM_MB:-}
REQUIRE_MEM_MB=${REQUIRE_MEM_MB:-}
LOOPS=${LOOPS:-1}
LOOP_DELAY=${LOOP_DELAY:-0}
JSON_OUT=${JSON_OUT:-}
MEMORY_OVERRIDE=""
DURATION=""
THREADS=""
WARM=0
UNCHECKED=0
PEER=""
LISTEN=0
FILE=""
FILE_BYTES=""
SCRATCH_PATH=""
SCRATCH_DIR=""
OWNED_FILE=""
LOG_FILE="$SCRIPT_DIR/Stressapptest.log"
VERBOSITY=8
INVERT=0
CHECK=0
EXTRA_CPU=0
CPU_LIST=""
TIMEOUT_MARGIN=120
LISTENER_PID=""
JSON_ACTIVE=0
JSON_FINALIZED=0
RUN_COMPLETED=0
# shellcheck disable=SC2034  # Shared timeout helper configuration.
MANAGED_TIMEOUT_USE_SESSION=1

usage() {
    cat <<EOF
Usage: $0 [options]
  -s SECONDS                   Load duration, default 300 or safe 120
  -M MIB -m THREADS             Optional memory and copy-worker overrides
  -W                           Checked warm copying
  -i THREADS -c THREADS -C THREADS  Invert, check-only and CPU workers
  -f FILE --filesize BYTES      New scratch file and bounded size
  -n IPV4 --listen              Remote client or standalone listener
  -F                           Legacy unchecked-copy mode, reduced coverage
  -l FILE -v LEVEL              Combined log and verbosity
  --safe --strict --dry-run
  --auto-net[=primary|loopback]  Local listener, does not validate a physical NIC
  --auto-disk --auto            Disk-backed scratch selection
  --scratch-dir DIRECTORY --cpu-list LIST
  --mem-pct=P --mem-cap-mb=MB --mem-headroom-mb=MB --require-mem-mb=MB
  --loops=N --loop-delay=SECONDS --json=FILE
  --timeout-margin SECONDS      Setup/cleanup allowance, default 120
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --safe)
                SAFE=1
                ;;
            --strict)
                STRICT=1
                ;;
            --dry-run)
                DRYRUN=1
                ;;
            -W)
                WARM=1
                ;;
            -F)
                UNCHECKED=1
                ;;
            --listen)
                LISTEN=1
                ;;
            --auto-net)
                AUTO_NET=1
                ;;
            --auto-net=*)
                AUTO_NET=1
                AUTO_NET_MODE=${1#*=}
                ;;
            --auto-disk)
                AUTO_DISK=1
                ;;
            --auto)
                AUTO_NET=1
                AUTO_DISK=1
                ;;
            --mem-pct=*)
                MEM_PCT=${1#*=}
                ;;
            --mem-cap-mb=*)
                MEM_CAP_MB=${1#*=}
                ;;
            --mem-headroom-mb=*)
                MEM_HEADROOM_MB=${1#*=}
                ;;
            --require-mem-mb=*)
                REQUIRE_MEM_MB=${1#*=}
                ;;
            --loops=*)
                LOOPS=${1#*=}
                ;;
            --loop-delay=*)
                LOOP_DELAY=${1#*=}
                ;;
            --json=*)
                JSON_OUT=${1#*=}
                ;;
            *)
                [ "$#" -ge 2 ] || return 1
                case "$1" in
                    -s)
                        DURATION=$2
                        ;;
                    -M)
                        MEMORY_OVERRIDE=$2
                        ;;
                    -m)
                        THREADS=$2
                        ;;
                    -i)
                        INVERT=$2
                        ;;
                    -c)
                        CHECK=$2
                        ;;
                    -C)
                        EXTRA_CPU=$2
                        ;;
                    -f)
                        FILE=$2
                        ;;
                    -n)
                        PEER=$2
                        ;;
                    -l)
                        LOG_FILE=$2
                        ;;
                    -v)
                        VERBOSITY=$2
                        ;;
                    --filesize)
                        FILE_BYTES=$2
                        ;;
                    --scratch-dir)
                        SCRATCH_PATH=$2
                        ;;
                    --cpu-list)
                        CPU_LIST=$2
                        ;;
                    --timeout-margin)
                        TIMEOUT_MARGIN=$2
                        ;;
                    --loops)
                        LOOPS=$2
                        ;;
                    --mem-pct)
                        MEM_PCT=$2
                        ;;
                    --mem-headroom-mb)
                        MEM_HEADROOM_MB=$2
                        ;;
                    --mem-cap-mb)
                        MEM_CAP_MB=$2
                        ;;
                    *)
                        return 1
                        ;;
                esac
                shift
                ;;
        esac
        shift
    done
}

cleanup() {
    managed_timeout_cancel_bounded || return 1
    if [ -n "$LISTENER_PID" ]; then
        BOUNDED_TIMEOUT_PID=$LISTENER_PID
        bounded_timeout_cancel
        cleanup_status=$?
        LISTENER_PID=$BOUNDED_TIMEOUT_PID
        [ "$cleanup_status" -eq 0 ] || return 1
    fi
    if [ -n "$SCRATCH_DIR" ]; then
        rm -rf -- "$SCRATCH_DIR" || return 1
        SCRATCH_DIR=""
    fi
    if [ -n "$OWNED_FILE" ]; then
        rm -f -- "$OWNED_FILE" || return 1
        OWNED_FILE=""
    fi
    if [ -n "$JSON_OUT" ] && [ "$JSON_ACTIVE" -eq 1 ] && [ "$JSON_FINALIZED" -eq 0 ]; then
        JSON_FINALIZED=1
        aggregate_fail=$((1 - RUN_COMPLETED))
        printf '{"aggregate":{"loops":%s,"pass":%s,"fail":%s,"strict_fail":%s}}\n' \
            "$LOOPS" "$TEST_RESULT_PASS_COUNT" "$aggregate_fail" "${STRICT_FAILURE:-0}" >>"$JSON_OUT" || return 1
    fi
}
# shellcheck disable=SC2034  # Shared result finalizer invokes cleanup.
TEST_RESULT_CLEANUP=cleanup
trap 'test_result_finish FAIL "Memory stress interrupted"' HUP INT TERM
trap cleanup EXIT
parse_args "$@" || test_result_finish FAIL "Invalid or incomplete argument, use --help"
for value in "$SAFE" "$DRYRUN" "$STRICT" "$AUTO_NET" "$AUTO_DISK"; do
    perf_uint_in_range "$value" 0 1 || test_result_finish FAIL "Boolean options must be 0 or 1"
done
if [ "$SAFE" -eq 1 ]; then
    DURATION=${DURATION:-120}
    MEM_PCT=${MEM_PCT:-35}
    MEM_HEADROOM_MB=${MEM_HEADROOM_MB:-512}
else
    DURATION=${DURATION:-300}
    MEM_PCT=${MEM_PCT:-60}
    MEM_HEADROOM_MB=${MEM_HEADROOM_MB:-256}
fi
for value in "$DURATION" "$LOOPS" "$TIMEOUT_MARGIN"; do
    perf_uint_in_range "$value" 1 2147483647 || test_result_finish FAIL "Duration, loops and timeout must be positive integers"
done
for value in "$MEM_HEADROOM_MB" "$LOOP_DELAY" "$INVERT" "$CHECK" "$EXTRA_CPU"; do
    perf_uint_in_range "$value" 0 2147483647 || test_result_finish FAIL "Invalid memory, delay or worker count"
done
for value in "$MEMORY_OVERRIDE" "$MEM_CAP_MB" "$REQUIRE_MEM_MB" "$FILE_BYTES"; do
    [ -z "$value" ] && continue
    perf_uint_in_range "$value" 1 9007199254740991 || test_result_finish FAIL "Explicit memory, size and worker overrides must be positive"
done
if [ -n "$THREADS" ]; then
    perf_uint_in_range "$THREADS" 0 1048576 || test_result_finish FAIL "Invalid copy-worker count"
fi
perf_uint_in_range "$MEM_PCT" 1 99 || test_result_finish FAIL "Memory percentage must be 1 through 99"
perf_uint_in_range "$VERBOSITY" 4 20 || test_result_finish FAIL "Verbosity must retain native result evidence, use 4 through 20"
case "$AUTO_NET_MODE" in
    primary|loopback) ;;
    *)
        test_result_finish FAIL "Unknown local-network mode $AUTO_NET_MODE"
        ;;
esac
if [ -n "$PEER" ]; then
    is_valid_ipv4 "$PEER" || test_result_finish FAIL "stressapptest requires a numeric IPv4 peer"
fi
if [ "$AUTO_NET" -eq 1 ] && { [ -n "$PEER" ] || [ "$LISTEN" -eq 1 ]; }; then
    test_result_finish FAIL "Use --auto-net for a local peer, or -n/--listen for a separately managed peer"
fi
for tool in stressapptest awk grep sed sort tr taskset setsid; do
    command -v "$tool" >/dev/null 2>&1 ||
        test_result_finish SKIP "Image-provided $tool is required for bounded memory stress"
done
CPUS=$(perf_allowed_cpus "$CPU_LIST") || test_result_finish FAIL "Cannot select allowed online CPUs"
CPU_COUNT=$(printf '%s\n' "$CPUS" | awk -F, '{print NF}')
if [ -z "$THREADS" ]; then
    THREADS=$CPU_COUNT
    if [ "$SAFE" -eq 1 ] && [ "$CPU_COUNT" -gt 1 ]; then
        THREADS=$(((CPU_COUNT + 1) / 2))
        [ "$THREADS" -le 4 ] || THREADS=4
    fi
    AUTO_THREADS=1
else
    AUTO_THREADS=0
fi
if [ "$SAFE" -eq 1 ] && [ "$THREADS" -gt 0 ]; then
    CPUS=$(printf '%s\n' "$CPUS" | awk -F, -v count="$THREADS" '
        {for (i=1; i<=NF && i<=count; i++) printf "%s%s", (i>1 ? "," : ""), $i; print ""}')
fi
taskset -c "$CPUS" true || test_result_finish FAIL "Cannot apply CPU affinity $CPUS"
stressapptest --help >"$RUN_DIR/help.log" 2>&1
if ! grep -q -- '--no_affinity' "$RUN_DIR/help.log"; then
    test_result_finish SKIP "Installed stressapptest lacks --no_affinity required to preserve the selected CPU mask"
fi
if [ -n "$FILE" ] || [ "$AUTO_DISK" -eq 1 ]; then
    if [ -n "$FILE" ]; then
        if [ -e "$FILE" ] || [ -L "$FILE" ]; then
            test_result_finish FAIL "Refusing to overwrite existing scratch path $FILE"
        fi
        SCRATCH_PATH=$(dirname "$FILE")
    fi
    SCRATCH_BASE=$(perf_stress_scratch "$SCRATCH_PATH") ||
        test_result_finish SKIP "File stress requires a writable disk-backed --scratch-dir or -f parent"
    DISK_BUDGET=$(perf_disk_budget_bytes "$SCRATCH_BASE" 5) || test_result_finish FAIL "Insufficient scratch space"
    if [ -z "$FILE_BYTES" ]; then
        # Preserve the native eight 1 MiB file blocks, bounded by free space.
        FILE_BYTES=8388608
        [ "$FILE_BYTES" -le "$DISK_BUDGET" ] || FILE_BYTES=$DISK_BUDGET
    fi
    [ "$FILE_BYTES" -ge 1048576 ] || test_result_finish FAIL "File size must hold at least one 1 MiB pattern block"
    [ "$FILE_BYTES" -le "$DISK_BUDGET" ] || test_result_finish FAIL "Requested file exceeds the scratch-space budget"
    if [ -n "$FILE" ]; then
        FILE="$SCRATCH_BASE/$(basename "$FILE")"
        (
            set -C
            : >"$FILE"
        ) || test_result_finish FAIL "Cannot exclusively create scratch file $FILE"
        OWNED_FILE=$FILE
    else
        SCRATCH_DIR=$(mktemp -d "$SCRATCH_BASE/testkit-sat.XXXXXX") || test_result_finish FAIL "Cannot create scratch directory"
        FILE="$SCRATCH_DIR/data"
    fi
fi
if [ "$AUTO_NET" -eq 1 ]; then
    command -v readlink >/dev/null 2>&1 || test_result_finish SKIP "readlink is required to verify listener ownership"
    PEER=127.0.0.1
    if [ "$AUTO_NET_MODE" = primary ] && command -v ip >/dev/null 2>&1; then
        ADDRESS=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')
        PEER=${ADDRESS:-127.0.0.1}
    fi
    log_info "Auto-network uses local address $PEER, physical NIC coverage is not claimed"
fi
if [ "$UNCHECKED" -eq 1 ]; then
    log_warn "-F disables checking in several native paths, this run has reduced integrity coverage"
fi
: >"$LOG_FILE" || test_result_finish FAIL "Cannot create requested log $LOG_FILE"
START_UPTIME=$(awk '{print $1}' /proc/uptime)
ITERATION=1
while [ "$ITERATION" -le "$LOOPS" ]; do
    AVAILABLE=$(perf_available_memory_kb) || test_result_finish FAIL "Cannot determine effective available memory"
    if [ "$AUTO_NET" -eq 1 ]; then
        AVAILABLE=$((AVAILABLE - 32768))
    fi
    MEMORY=$(perf_memory_budget_mib "$AVAILABLE" "$MEM_PCT" "$MEM_HEADROOM_MB" "$MEM_CAP_MB") ||
        test_result_finish FAIL "Insufficient memory after reserving ${MEM_HEADROOM_MB} MiB and listener resources"
    if [ -n "$MEMORY_OVERRIDE" ]; then
        CEILING=$(perf_memory_budget_mib "$AVAILABLE" 100 "$MEM_HEADROOM_MB" "$MEM_CAP_MB") ||
            test_result_finish FAIL "No memory remains for the requested load"
        [ "$MEMORY_OVERRIDE" -le "$CEILING" ] || test_result_finish FAIL "-M exceeds available memory, headroom or cap"
        MEMORY=$MEMORY_OVERRIDE
    fi
    [ "$MEMORY" -ge 16 ] || test_result_finish FAIL "Memory budget is ${MEMORY} MiB, need at least 16 MiB"
    if [ -n "$REQUIRE_MEM_MB" ] && [ "$MEMORY" -lt "$REQUIRE_MEM_MB" ]; then
        test_result_finish FAIL "Memory budget $MEMORY MiB is below required $REQUIRE_MEM_MB MiB"
    fi
    # A 1 MiB pattern block fixes the native page-count contract across builds.
    # Preserve native InitializePages rounding: (pages / 5) * 2.
    # shellcheck disable=SC2017
    WORKER_BUDGET=$((MEMORY / 5 * 2 - INVERT - CHECK))
    [ -z "$PEER" ] || WORKER_BUDGET=$((WORKER_BUDGET - 1))
    [ -z "$FILE" ] || WORKER_BUDGET=$((WORKER_BUDGET - 1))
    if [ "$AUTO_THREADS" -eq 1 ] && [ "$THREADS" -gt "$WORKER_BUDGET" ]; then
        THREADS=$WORKER_BUDGET
    fi
    if [ "$THREADS" -lt 0 ] || [ "$THREADS" -gt "$WORKER_BUDGET" ]; then
        test_result_finish FAIL "Memory budget cannot supply the requested copy/invert/check/I/O workers"
    fi
    if [ "$THREADS" -eq 0 ] && [ "$INVERT" -eq 0 ] && [ "$CHECK" -eq 0 ] &&
       [ -z "$PEER" ] && [ -z "$FILE" ] && [ "$LISTEN" -eq 0 ]; then
        test_result_finish FAIL "Select at least one memory, file or network worker"
    fi
    LOG="$RUN_DIR/iteration-${ITERATION}.log"
    set -- stressapptest -s "$DURATION" -M "$MEMORY" -m "$THREADS" \
        -p 1048576 --no_affinity -v "$VERBOSITY"
    [ "$WARM" -eq 0 ] || set -- "$@" -W
    [ "$UNCHECKED" -eq 0 ] || set -- "$@" -F
    [ "$INVERT" -eq 0 ] || set -- "$@" -i "$INVERT"
    [ "$CHECK" -eq 0 ] || set -- "$@" -c "$CHECK"
    [ "$EXTRA_CPU" -eq 0 ] || set -- "$@" -C "$EXTRA_CPU"
    [ "$LISTEN" -eq 0 ] || set -- "$@" --listen
    [ -z "$PEER" ] || set -- "$@" -n "$PEER"
    [ -z "$FILE" ] || set -- "$@" -f "$FILE" --filesize "$FILE_BYTES"
    log_info "Iteration=$ITERATION/$LOOPS cpus=$CPUS effective_available=${AVAILABLE}kB memory=${MEMORY}MiB"
    log_info "Command: $*"
    [ "$DRYRUN" -eq 0 ] || test_result_finish SKIP "Command prepared, no memory stress executed"
    JSON_ACTIVE=1
    if [ "$AUTO_NET" -eq 1 ]; then
        LISTENER_LOG="$RUN_DIR/listener-${ITERATION}.log"
        taskset -c "$CPUS" stressapptest --listen --no_affinity -M 32 -m 0 \
            -s "$((DURATION + TIMEOUT_MARGIN + 30))" >"$LISTENER_LOG" 2>&1 &
        LISTENER_PID=$!
        READY=0
        WAITED=0
        while [ "$WAITED" -lt 30 ] && bounded_timeout_pid_running "$LISTENER_PID"; do
            for descriptor in /proc/"$LISTENER_PID"/fd/*; do
                socket=$(readlink "$descriptor" 2>/dev/null) || continue
                case "$socket" in
                    socket:\[*\])
                        inode=${socket#socket:[}
                        inode=${inode%]}
                        if awk -v inode="$inode" '$4=="0A" && $10==inode {found=1} END {exit !found}' /proc/net/tcp; then
                            READY=1
                        fi
                        ;;
                esac
            done
            [ "$READY" -eq 0 ] || break
            sleep 1
            WAITED=$((WAITED + 1))
        done
        [ "$READY" -eq 1 ] || test_result_finish FAIL "Owned local listener did not become ready, inspect $LISTENER_LOG"
    fi
    START_TIME=$(date +%s)
    perf_run_stress_load "$((DURATION + TIMEOUT_MARGIN))" "$RUN_DIR" "$LOG" \
        taskset -c "$CPUS" "$@"
    RET=$?
    END_TIME=$(date +%s)
    cat "$LOG" >>"$LOG_FILE" || test_result_finish FAIL "Cannot retain the combined log"
    if [ -n "$LISTENER_PID" ]; then
        BOUNDED_TIMEOUT_PID=$LISTENER_PID
        bounded_timeout_cancel || test_result_finish FAIL "Local listener did not stop"
        LISTENER_PID=""
        if grep -Eq 'Process Error:|Hardware Error:|Status: FAIL' "$LISTENER_LOG"; then
            test_result_finish FAIL "Local listener reported errors, inspect $LISTENER_LOG"
        fi
    fi
    if [ -n "$JSON_OUT" ]; then
        MODE=NORMAL
        [ "$SAFE" -eq 0 ] || MODE=SAFE
        printf '{"loop":%s,"start_ts":%s,"end_ts":%s,"elapsed":%s,"ret":%s,"mem_mb":%s,"threads":%s,"duration_s":%s,"mode":"%s","mem_debug":"available=%skB headroom=%sMiB","log":"%s"}\n' \
            "$ITERATION" "$START_TIME" "$END_TIME" "$((END_TIME - START_TIME))" "$RET" "$MEMORY" "$THREADS" "$DURATION" \
            "$MODE" "$AVAILABLE" "$MEM_HEADROOM_MB" "$(esc "$LOG")" \
            >>"$JSON_OUT" || test_result_finish FAIL "Cannot write JSON evidence"
    fi
    if [ "$RET" -ne 0 ] || ! grep -q 'Status: PASS' "$LOG" ||
       grep -Eq 'Status: FAIL|Process Error:|Hardware Error:' "$LOG"; then
        test_result_finish FAIL "Native memory stress failed or lacks completion evidence, rc=$RET log=$LOG"
    fi
    METRICS=""
    [ "$THREADS" -eq 0 ] || METRICS=Memory_Copy
    [ -z "$FILE" ] || METRICS="$METRICS File_Copy"
    [ -z "$PEER" ] || METRICS="$METRICS Net_Copy"
    [ "$LISTEN" -eq 0 ] || METRICS="$METRICS Net_Copy"
    [ "$INVERT" -eq 0 ] || METRICS="$METRICS Invert_Data"
    [ "$CHECK" -eq 0 ] || METRICS="$METRICS Data_Check"
    for metric in $METRICS; do
        LABEL=$(printf '%s' "$metric" | tr '_' ' ')
        awk -v label="Stats: $LABEL:" '
            index($0,label) {value=substr($0,index($0,label)+length(label)); if(value+0>0) found=1}
            END {exit !found}' "$LOG" || test_result_finish FAIL "No completed $LABEL work in $LOG"
    done
    perf_stress_kernel_errors "$RUN_DIR/kernel-$ITERATION" "$START_UPTIME"
    KERNEL_RC=$?
    case "$KERNEL_RC" in
        0)
            STRICT_FAILURE=1
            test_result_finish FAIL "Kernel fault during memory stress, inspect $RUN_DIR/kernel-$ITERATION"
            ;;
        2)
            if [ "$STRICT" -eq 1 ]; then
                STRICT_FAILURE=1
                test_result_finish FAIL "Kernel log unavailable for strict memory validation"
            fi
            log_warn "Native memory checks completed, kernel health evidence is unavailable"
            ;;
    esac
    test_result_record PASS "Completed memory stress iteration $ITERATION"
    if [ "$ITERATION" -lt "$LOOPS" ] && [ "$LOOP_DELAY" -gt 0 ]; then
        sleep "$LOOP_DELAY"
    fi
    ITERATION=$((ITERATION + 1))
done
RUN_COMPLETED=1
test_result_finish
