#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc.
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

TESTNAME="Stress-ng"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
test_result_init "$TESTNAME" "$RES_FILE"
RUN_DIR=$(test_create_run_directory "$SCRIPT_DIR/logs") ||
    test_result_finish FAIL "Cannot create stress evidence directory"
P1_SECS=60
P2_SECS=60
MEM_FRAC=15
DISK_FRAC=5
MEM_HEADROOM=256
MEM_CAP=""
DISK_CAP=""
CPU_LIST=""
TEMP_LIMIT=""
SCRATCH_PATH=""
SETS=cpu,vmhdd
REPEAT=1
STABILITY_HOURS=""
BY_CLASS=""
AUTOSIZE=0
APPEND_DEFAULTS=0
DRYRUN=0
VM_KEEP=1
COMMAND_TIMEOUT=""
TIMEOUT_MARGIN=120
ARG_FILE="$RUN_DIR/arguments"
: >"$ARG_FILE"
SCRATCH_DIR=""
# shellcheck disable=SC2034  # Shared timeout helper configuration.
MANAGED_TIMEOUT_USE_SESSION=1

usage() {
    cat <<EOF
Usage: $0 [options] [-- native stress-ng arguments]
  --sets cpu,vmhdd|vm|io|mixed   Workloads, default cpu,vmhdd
  --p1 SECONDS                  CPU phase, default 60
  --p2 SECONDS                  Other phases, default 60
  --repeat N | --stability HOURS
  --mem-frac PERCENT            Total memory budget, default 15
  --mem-headroom-mb MB          Reserve, default 256
  --mem-cap-mb MB               Optional total memory cap
  --disk-frac PERCENT           Free scratch-space budget, default 5
  --disk-cap-mb MB              Optional scratch-space cap
  --scratch-dir DIRECTORY       Writable disk-backed scratch location
  --cpu-list LIST               Subset of allowed online CPUs
  --vm-keep 0|1                 Mapping churn or reuse, default 1
  --stressng-args STRING        Quoted argument list, no shell evaluation
  --by-class CSV                Explicit native class selection
  --autosize --append-defaults  Native argument defaults
  --command-timeout SECONDS     Overall bound for each custom invocation
  --timeout-margin SECONDS      Setup/cleanup margin, default 120
  --temp-limit DEGREES          Requires this option in the installed tool
  --dry-run                    Validate options without claiming load PASS
EOF
}

# parse_native_arguments STRING
# Tokenize quotes and escapes as argument syntax without executing shell text.
parse_native_arguments() {
    printf '%s\n' "$1" | awk '
        NR>1 {bad=1}
        {
            for (i=1; i<=length($0); i++) {
                c=substr($0,i,1)
                if (escaped) {word=word c; escaped=0; active=1; continue}
                if (c=="\\" && quote!="\047") {escaped=1; active=1; continue}
                if (quote!="") {
                    if (c==quote) quote=""
                    else word=word c
                    continue
                }
                if (c=="\047" || c=="\042") {quote=c; active=1; continue}
                if (c ~ /[ \t]/) {
                    if (active) {print word; word=""; active=0}
                } else {word=word c; active=1}
            }
        }
        END {
            if (bad || quote!="" || escaped) exit 1
            if (active) print word
        }' >"$ARG_FILE"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --autosize)
                AUTOSIZE=1
                ;;
            --append-defaults)
                APPEND_DEFAULTS=1
                ;;
            --dryrun|--dry-run)
                DRYRUN=1
                ;;
            --)
                shift
                if [ "$#" -gt 0 ]; then
                    printf '%s\n' "$@" >"$ARG_FILE"
                fi
                return 0
                ;;
            *)
                [ "$#" -ge 2 ] || return 1
                case "$1" in
                    --p1)
                        P1_SECS=$2
                        ;;
                    --p2)
                        P2_SECS=$2
                        ;;
                    --mem-frac)
                        MEM_FRAC=$2
                        ;;
                    --disk-frac)
                        DISK_FRAC=$2
                        ;;
                    --cpu-list)
                        CPU_LIST=$2
                        ;;
                    --temp-limit)
                        TEMP_LIMIT=$2
                        ;;
                    --sets)
                        SETS=$2
                        ;;
                    --repeat)
                        REPEAT=$2
                        ;;
                    --stability)
                        STABILITY_HOURS=$2
                        ;;
                    --by-class)
                        BY_CLASS=$2
                        ;;
                    --stressng-args)
                        parse_native_arguments "$2" || return 1
                        ;;
                    --scratch-dir)
                        SCRATCH_PATH=$2
                        ;;
                    --mem-headroom-mb)
                        MEM_HEADROOM=$2
                        ;;
                    --mem-cap-mb)
                        MEM_CAP=$2
                        ;;
                    --disk-cap-mb)
                        DISK_CAP=$2
                        ;;
                    --vm-keep)
                        VM_KEEP=$2
                        ;;
                    --command-timeout)
                        COMMAND_TIMEOUT=$2
                        ;;
                    --timeout-margin)
                        TIMEOUT_MARGIN=$2
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
    if [ -n "$SCRATCH_DIR" ]; then
        # Only the unique directory created by this invocation is owned.
        rm -rf -- "$SCRATCH_DIR" || return 1
        SCRATCH_DIR=""
    fi
}
# shellcheck disable=SC2034  # Shared result finalizer invokes cleanup.
TEST_RESULT_CLEANUP=cleanup
trap 'test_result_finish FAIL "Stress load interrupted"' HUP INT TERM
trap cleanup EXIT

parse_args "$@" || test_result_finish FAIL "Invalid or incomplete argument, use --help"
for value in "$P1_SECS" "$P2_SECS" "$REPEAT" "$TIMEOUT_MARGIN"; do
    perf_uint_in_range "$value" 1 2147483647 ||
        test_result_finish FAIL "Duration, repeat and timeout values must be positive decimal integers"
done
for value in "$MEM_FRAC" "$DISK_FRAC"; do
    perf_uint_in_range "$value" 1 99 || test_result_finish FAIL "Resource percentages must be 1 through 99"
done
perf_uint_in_range "$MEM_HEADROOM" 0 2147483647 || test_result_finish FAIL "Invalid memory headroom"
perf_uint_in_range "$VM_KEEP" 0 1 || test_result_finish FAIL "--vm-keep must be 0 or 1"
for value in "$MEM_CAP" "$DISK_CAP" "$COMMAND_TIMEOUT" "$TEMP_LIMIT"; do
    [ -z "$value" ] && continue
    perf_uint_in_range "$value" 1 2147483647 || test_result_finish FAIL "Invalid resource or timeout override"
done
if [ -n "$STABILITY_HOURS" ]; then
    perf_uint_in_range "$STABILITY_HOURS" 1 596000 || test_result_finish FAIL "Invalid stability duration in hours"
fi
case "$SETS" in
    ''|,*|*,|*,,*)
        test_result_finish FAIL "Empty workload selection"
        ;;
esac
for workload in $(printf '%s' "$SETS" | tr ',' ' '); do
    case "$workload" in
        cpu|vmhdd|vm|io|mixed) ;;
        *)
            test_result_finish FAIL "Unknown workload $workload"
            ;;
    esac
done
for tool in stress-ng awk grep sed sort tr df taskset setsid; do
    command -v "$tool" >/dev/null 2>&1 ||
        test_result_finish SKIP "Image-provided $tool is required for bounded stress execution"
done
CPUS=$(perf_allowed_cpus "$CPU_LIST") || test_result_finish FAIL "Cannot select allowed online CPUs"
CPU_COUNT=$(printf '%s\n' "$CPUS" | awk -F, '{print NF}')
taskset -c "$CPUS" true || test_result_finish FAIL "Cannot apply CPU affinity $CPUS"
stress-ng --help >"$RUN_DIR/help.log" 2>&1
if [ -n "$TEMP_LIMIT" ] && ! grep -q -- '--temp-limit' "$RUN_DIR/help.log"; then
    test_result_finish SKIP "Installed stress-ng has no --temp-limit, omit it or provide a tool with that capability"
fi
if [ -n "$BY_CLASS" ]; then
    case "$BY_CLASS" in
        *[!a-zA-Z0-9_,-]*|,*|*,|*,,*)
            test_result_finish FAIL "Invalid class list"
            ;;
    esac
fi
CUSTOM=0
if [ -s "$ARG_FILE" ] || [ -n "$BY_CLASS" ]; then
    CUSTOM=1
fi
START_UPTIME=$(awk '{print $1}' /proc/uptime)
START_TIME=$(awk '{print int($1)}' /proc/uptime)
END_TIME=0
if [ -n "$STABILITY_HOURS" ]; then
    END_TIME=$((START_TIME + STABILITY_HOURS * 3600))
fi
ITERATION=1
while [ "$ITERATION" -le "$REPEAT" ] || [ "$END_TIME" -gt 0 ]; do
    if [ "$END_TIME" -gt 0 ] && [ "$(awk '{print int($1)}' /proc/uptime)" -ge "$END_TIME" ]; then
        break
    fi
    WORKLOADS=$(printf '%s' "$SETS" | tr ',' ' ')
    if [ "$CUSTOM" -eq 1 ]; then
        WORKLOADS=${BY_CLASS:-custom}
        WORKLOADS=$(printf '%s' "$WORKLOADS" | tr ',' ' ')
    fi
    for workload in $WORKLOADS; do
        LOG="$RUN_DIR/iteration-${ITERATION}-${workload}.log"
        LOAD_SECONDS=$P2_SECS
        NEED_MEMORY=0
        NEED_DISK=0
        if [ "$CUSTOM" -eq 0 ]; then
            case "$workload" in
                cpu)
                    LOAD_SECONDS=$P1_SECS
                    ;;
                vm)
                    NEED_MEMORY=1
                    ;;
                vmhdd|mixed)
                    NEED_MEMORY=1
                    NEED_DISK=1
                    ;;
                io)
                    NEED_DISK=1
                    ;;
            esac
        elif [ "$AUTOSIZE" -eq 1 ]; then
            if grep -Eq '^(--vm|-m)(=|$)' "$ARG_FILE"; then
                NEED_MEMORY=1
            fi
            if grep -Eq '^(--hdd|-d)(=|$)' "$ARG_FILE"; then
                NEED_DISK=1
            fi
        fi
        if [ "$NEED_MEMORY" -eq 1 ]; then
            AVAILABLE=$(perf_available_memory_kb) || test_result_finish FAIL "Cannot determine the effective memory budget"
            MEMORY=$(perf_memory_budget_mib "$AVAILABLE" "$MEM_FRAC" "$MEM_HEADROOM" "$MEM_CAP") ||
                test_result_finish FAIL "Insufficient available memory after reserving ${MEM_HEADROOM} MiB"
        fi
        if [ "$NEED_DISK" -eq 1 ]; then
            if [ -z "$SCRATCH_DIR" ]; then
                SCRATCH_BASE=$(perf_stress_scratch "$SCRATCH_PATH") ||
                    test_result_finish SKIP "File I/O requires a writable disk-backed --scratch-dir"
                SCRATCH_DIR=$(mktemp -d "$SCRATCH_BASE/testkit-stress.XXXXXX") ||
                    test_result_finish FAIL "Cannot create test-owned scratch directory"
            fi
            DISK_BYTES=$(perf_disk_budget_bytes "$SCRATCH_DIR" "$DISK_FRAC" "$DISK_CAP") ||
                test_result_finish FAIL "Insufficient free scratch space after headroom"
        fi
        set --
        if [ "$CUSTOM" -eq 1 ]; then
            while IFS= read -r argument; do
                set -- "$@" "$argument"
            done <"$ARG_FILE"
            if [ -n "$BY_CLASS" ]; then
                set -- "$@" --class "$workload"
            fi
            if [ "$APPEND_DEFAULTS" -eq 1 ]; then
                set -- "$@" --times --metrics-brief --verify
            fi
            if [ "$AUTOSIZE" -eq 1 ]; then
                if [ "$NEED_MEMORY" -eq 1 ] && ! grep -q '^--vm-bytes' "$ARG_FILE"; then
                    VM_INSTANCES=$(awk '
                        value {print; exit}
                        /^--vm=/ {sub(/^--vm=/, ""); print; exit}
                        /^(--vm|-m)$/ {value=1}' "$ARG_FILE")
                    [ "$VM_INSTANCES" = 1 ] || test_result_finish FAIL "Multi-worker custom VM load needs explicit --vm-bytes for the installed tool semantics"
                    set -- "$@" --vm-bytes "${MEMORY}m"
                fi
                if [ "$NEED_DISK" -eq 1 ] && ! grep -q '^--hdd-bytes' "$ARG_FILE"; then
                    HDD_INSTANCES=$(awk '
                        value {print; exit}
                        /^--hdd=/ {sub(/^--hdd=/, ""); print; exit}
                        /^(--hdd|-d)$/ {value=1}' "$ARG_FILE")
                    [ "$HDD_INSTANCES" = 1 ] || test_result_finish FAIL "Multi-worker custom HDD load needs explicit --hdd-bytes for the installed tool semantics"
                    set -- "$@" --hdd-bytes "$DISK_BYTES"
                fi
                if [ "$NEED_DISK" -eq 1 ] && ! grep -q '^--temp-path' "$ARG_FILE"; then
                    set -- "$@" --temp-path "$SCRATCH_DIR"
                fi
            fi
            NATIVE_DURATION=$(awk '
                next_timeout {print; exit}
                /^--timeout=/ {sub(/^--timeout=/, ""); print; exit}
                /^(--timeout|-t)$/ {next_timeout=1}
            ' "$ARG_FILE")
            if [ -n "$NATIVE_DURATION" ]; then
                LOAD_SECONDS=$(printf '%s\n' "$NATIVE_DURATION" | awk '
                    /^[0-9]+[smhd]?$/ {
                        multiplier=1
                        if ($0 ~ /m$/) multiplier=60
                        if ($0 ~ /h$/) multiplier=3600
                        if ($0 ~ /d$/) multiplier=86400
                        printf "%.0f\n", $0*multiplier
                    }')
                perf_uint_in_range "$LOAD_SECONDS" 1 2147483647 ||
                    test_result_finish FAIL "Custom native timeout must be positive seconds, minutes, hours or days"
            else
                set -- "$@" --timeout "${LOAD_SECONDS}s"
            fi
        else
            case "$workload" in
                cpu)
                    set -- --cpu "$CPU_COUNT" --cpu-method all --matrix "$CPU_COUNT"
                    ;;
                vm|vmhdd)
                    set -- --vm 1 --vm-bytes "${MEMORY}m"
                    ;;
                mixed)
                    set -- --cpu "$CPU_COUNT" --cpu-method all --vm 1 --vm-bytes "${MEMORY}m"
                    ;;
            esac
            if [ "$NEED_MEMORY" -eq 1 ] && [ "$VM_KEEP" -eq 1 ]; then
                set -- "$@" --vm-keep
            fi
            if [ "$NEED_DISK" -eq 1 ]; then
                set -- "$@" --hdd 1 --hdd-bytes "$DISK_BYTES" --temp-path "$SCRATCH_DIR"
            fi
            set -- "$@" --timeout "${LOAD_SECONDS}s" --times --metrics-brief --verify
        fi
        [ -z "$TEMP_LIMIT" ] || set -- "$@" --temp-limit "$TEMP_LIMIT"
        DEADLINE=${COMMAND_TIMEOUT:-$((LOAD_SECONDS + TIMEOUT_MARGIN))}
        if [ "$END_TIME" -gt 0 ]; then
            REMAINING=$((END_TIME - $(awk '{print int($1)}' /proc/uptime)))
            [ "$REMAINING" -gt 0 ] || break
            if [ "$LOAD_SECONDS" -gt "$REMAINING" ]; then
                set -- "$@" --timeout "${REMAINING}s"
                DEADLINE=$((REMAINING + TIMEOUT_MARGIN))
            fi
        fi
        if [ "$DRYRUN" -eq 1 ]; then
            set -- "$@" --dry-run
        fi
        log_info "Iteration=$ITERATION workload=$workload cpus=$CPUS deadline=${DEADLINE}s"
        log_info "Command: stress-ng $*"
        perf_run_stress_load "$DEADLINE" "$RUN_DIR" "$LOG" \
            taskset -c "$CPUS" stress-ng "$@"
        RET=$?
        [ "$RET" -eq 0 ] || test_result_finish FAIL "stress-ng exited $RET, evidence $LOG"
        if [ "$DRYRUN" -eq 0 ]; then
            if grep -Ei 'fail:|failed:[[:space:]]*[1-9]|skipped:[[:space:]]*[1-9]|out of memory|cannot allocate|no space left|I/O error' "$LOG"; then
                test_result_finish FAIL "Selected workload failed or did not execute fully, evidence $LOG"
            fi
            if ! grep -Eq 'successful run completed|passed:[[:space:]]*[1-9]' "$LOG"; then
                test_result_finish FAIL "Missing native completion evidence in $LOG"
            fi
            if [ "$CUSTOM" -eq 0 ]; then
                case "$workload" in
                    cpu)
                        EXPECTED_STRESSORS="cpu matrix"
                        ;;
                    vm)
                        EXPECTED_STRESSORS=vm
                        ;;
                    vmhdd)
                        EXPECTED_STRESSORS="vm hdd"
                        ;;
                    io)
                        EXPECTED_STRESSORS=hdd
                        ;;
                    mixed)
                        EXPECTED_STRESSORS="cpu vm hdd"
                        ;;
                esac
                for stressor in $EXPECTED_STRESSORS; do
                    awk -v stressor="$stressor" '
                        /metrc:/ {
                            for (i=1; i<NF; i++) if ($i==stressor && $(i+1)+0>0) found=1
                        }
                        END {exit !found}' "$LOG" ||
                        test_result_finish FAIL "No completed $stressor operations in $LOG"
                done
            fi
            perf_stress_kernel_errors "$RUN_DIR/kernel-${ITERATION}-${workload}" "$START_UPTIME"
            KERNEL_RC=$?
            case "$KERNEL_RC" in
                0)
                    test_result_finish FAIL "Kernel fault during stress, inspect $RUN_DIR/kernel-${ITERATION}-${workload}"
                    ;;
                2)
                    test_result_finish FAIL "Kernel log unavailable, cannot exclude OOM or kernel faults during stress"
                    ;;
            esac
            test_result_record PASS "Completed iteration $ITERATION workload $workload"
        fi
    done
    [ "$DRYRUN" -eq 0 ] || test_result_finish SKIP "Arguments validated, no stress load executed"
    ITERATION=$((ITERATION + 1))
done
test_result_finish
