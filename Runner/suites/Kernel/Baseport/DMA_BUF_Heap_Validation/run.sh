#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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
. "$TOOLS/lib_dmabuf.sh"

TESTNAME="DMA_BUF_Heap_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

if [ "${DMABUF_HEAPS+x}" = "x" ]; then
    DMABUF_HEAPS_SOURCE="environment"
else
    DMABUF_HEAPS="auto"
    DMABUF_HEAPS_SOURCE="default"
fi
if [ "${DMABUF_ALLOCATION_BYTES+x}" = "x" ]; then
    DMABUF_ALLOCATION_SOURCE="environment"
else
    DMABUF_ALLOCATION_BYTES="65536"
    DMABUF_ALLOCATION_SOURCE="default"
fi
if [ "${DMABUF_TIMEOUT+x}" = "x" ]; then
    DMABUF_TIMEOUT_SOURCE="environment"
else
    DMABUF_TIMEOUT="15"
    DMABUF_TIMEOUT_SOURCE="default"
fi

DMABUF_MAX_ALLOCATION_BYTES=16777216
DMABUF_MAX_TIMEOUT=300
DMABUF_MAX_SELECTED_HEAPS=64
DMABUF_MAX_TOTAL_SECONDS=300
DMABUF_DEVICE_ROOT="/dev/dma_heap"
DMABUF_RUNNER="$TOOLS/dmabuf_heap_runner.py"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
HEAP_INVENTORY="$RESULT_DIR/dmabuf_heaps.tsv"
SELECTED_HEAPS="$RESULT_DIR/selected_heaps.log"
DMABUF_PASS_COUNT=0

# usage
# Takes no arguments, prints the supported CLI contract to stdout, returns 0,
# and has no target-side effects.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --heaps POLICY       auto or exact whitespace-separated heap names" \
        "  --size BYTES         Page-aligned allocation size, maximum 16777216" \
        "  --timeout SECONDS    Per-heap watchdog, 1..300, default: 15" \
        "  -h, --help" \
        "Automatic mode selects only public Linux CPU-mappable heap names." \
        "Vendor, secure, and protected heaps require exact product-policy names." \
        "CLI options override environment variables. No packages are installed."
}

# parse_args <suite-arguments...>
# Applies CLI values to DMABUF_* globals and records their source. It produces
# no stdout, returns 0 on success or 2 for invalid input, and has no target-side
# effects beyond diagnostic logging for an unknown option.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --heaps)
                [ "$#" -ge 2 ] || return 2
                DMABUF_HEAPS="$2"
                DMABUF_HEAPS_SOURCE="cli"
                shift 2
                ;;
            --heaps=*)
                DMABUF_HEAPS=${1#*=}
                DMABUF_HEAPS_SOURCE="cli"
                shift
                ;;
            --size)
                [ "$#" -ge 2 ] || return 2
                DMABUF_ALLOCATION_BYTES="$2"
                DMABUF_ALLOCATION_SOURCE="cli"
                shift 2
                ;;
            --size=*)
                DMABUF_ALLOCATION_BYTES=${1#*=}
                DMABUF_ALLOCATION_SOURCE="cli"
                shift
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                DMABUF_TIMEOUT="$2"
                DMABUF_TIMEOUT_SOURCE="cli"
                shift 2
                ;;
            --timeout=*)
                DMABUF_TIMEOUT=${1#*=}
                DMABUF_TIMEOUT_SOURCE="cli"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                return 2
                ;;
        esac
    done
}

parse_args "$@" || {
    usage >&2
    exit 2
}

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "DMA-BUF heap validation performs allocation, shared mapping, zero checks, synchronized deterministic read/write, and verified release"
log_info "[DMABUF-POLICY] heaps=$DMABUF_HEAPS heaps_source=$DMABUF_HEAPS_SOURCE allocation_bytes=$DMABUF_ALLOCATION_BYTES allocation_source=$DMABUF_ALLOCATION_SOURCE per_heap_timeout=${DMABUF_TIMEOUT}s timeout_source=$DMABUF_TIMEOUT_SOURCE maximum_total_timeout=${DMABUF_MAX_TOTAL_SECONDS}s network=not-required package_install=disabled"

case "$DMABUF_ALLOCATION_BYTES" in
    ''|*[!0-9]*|0)
        test_result_record \
            "FAIL" \
            "DMA-BUF allocation size must be a positive integer"
        test_result_finish
        ;;
    0[0-9]*)
        test_result_record \
            "FAIL" \
            "DMA-BUF allocation size must use canonical decimal notation"
        test_result_finish
        ;;
esac
case "$DMABUF_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record \
            "FAIL" \
            "DMA-BUF timeout must be a positive integer"
        test_result_finish
        ;;
    0[0-9]*)
        test_result_record \
            "FAIL" \
            "DMA-BUF timeout must use canonical decimal notation"
        test_result_finish
        ;;
esac
if [ "${#DMABUF_ALLOCATION_BYTES}" -gt 8 ] ||
   [ "$DMABUF_ALLOCATION_BYTES" -gt "$DMABUF_MAX_ALLOCATION_BYTES" ]; then
    test_result_record \
        "FAIL" \
        "DMA-BUF allocation size exceeds the safe 16777216-byte limit"
    test_result_finish
fi
if [ "${#DMABUF_TIMEOUT}" -gt 3 ] ||
   [ "$DMABUF_TIMEOUT" -gt "$DMABUF_MAX_TIMEOUT" ]; then
    test_result_record \
        "FAIL" \
        "DMA-BUF timeout exceeds the safe 300-second limit"
    test_result_finish
fi

dmabuf_missing_commands=""
for dmabuf_required_command in awk date dirname mkdir mv rm tr wc; do
    if ! command -v "$dmabuf_required_command" >/dev/null 2>&1; then
        dmabuf_missing_commands="$dmabuf_missing_commands $dmabuf_required_command"
    fi
done
if [ -n "$dmabuf_missing_commands" ]; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: required image-provided commands are unavailable:$dmabuf_missing_commands"
fi

if [ ! -r "$DMABUF_RUNNER" ]; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: repository DMA-BUF UAPI runner is missing: $DMABUF_RUNNER"
fi

dmabuf_heap_config=$(kernel_config_value CONFIG_DMABUF_HEAPS 2>/dev/null || true)
dmabuf_system_config=$(
    kernel_config_value CONFIG_DMABUF_HEAPS_SYSTEM 2>/dev/null || true
)
log_info "[DMABUF-DISCOVERY] device_root=$DMABUF_DEVICE_ROOT config=${dmabuf_heap_config:-unknown} system_config=${dmabuf_system_config:-unknown}"

if [ ! -d "$DMABUF_DEVICE_ROOT" ]; then
    case "$dmabuf_system_config" in
        CONFIG_DMABUF_HEAPS_SYSTEM=y|CONFIG_DMABUF_HEAPS_SYSTEM=m)
            test_result_record \
                "FAIL" \
                "Kernel enables the system DMA heap but $DMABUF_DEVICE_ROOT is absent"
            ;;
        *)
            test_result_record \
                "SKIP" \
                "DMA-BUF heap devices are not exposed on this target"
            ;;
    esac
    test_result_finish
fi

if ! dmabuf_heap_capture_inventory "$DMABUF_DEVICE_ROOT" "$HEAP_INVENTORY"; then
    test_result_record \
        "FAIL" \
        "DMA-BUF heap inventory could not be captured in $HEAP_INVENTORY"
    test_result_finish
fi
log_file_with_label "DMABUF-HEAP" "$HEAP_INVENTORY" 64
dmabuf_heap_count=$(
    awk 'NR > 1 { count++ } END { print count + 0 }' "$HEAP_INVENTORY"
)
if [ "$dmabuf_heap_count" -eq 0 ]; then
    test_result_record \
        "FAIL" \
        "$DMABUF_DEVICE_ROOT exists but exposes no heap device nodes"
    test_result_finish
fi

case "$dmabuf_system_config" in
    CONFIG_DMABUF_HEAPS_SYSTEM=y|CONFIG_DMABUF_HEAPS_SYSTEM=m)
        if ! awk -F '\t' '
            NR > 1 && $1 == "system" && $3 == 1 {
                found = 1
            }
            END {
                exit !found
            }
        ' "$HEAP_INVENTORY"; then
            test_result_record \
                "FAIL" \
                "Kernel enables the system DMA heap but /dev/dma_heap/system is not a character device"
            test_result_finish
        fi
        ;;
esac

if ! dmabuf_heap_select "$HEAP_INVENTORY" "$DMABUF_HEAPS" "$SELECTED_HEAPS"; then
    test_result_record \
        "FAIL" \
        "DMA-BUF heap selection is invalid, reason=${DMABUF_SELECTION_REASON:-unknown}"
    test_result_finish
fi
dmabuf_selected_count=$(wc -l <"$SELECTED_HEAPS" | tr -d '[:space:]')
if [ "$dmabuf_selected_count" -eq 0 ]; then
    test_result_record \
        "SKIP" \
        "No public CPU-mappable DMA-BUF heap name was discovered, exact vendor heap names require a product contract"
    test_result_finish
fi
if [ "$dmabuf_selected_count" -gt "$DMABUF_MAX_SELECTED_HEAPS" ]; then
    test_result_record \
        "FAIL" \
        "DMA-BUF selection exceeds the safe $DMABUF_MAX_SELECTED_HEAPS-heap limit, selected=$dmabuf_selected_count"
    test_result_finish
fi
dmabuf_timeout_budget=$((dmabuf_selected_count * DMABUF_TIMEOUT))
if [ "$dmabuf_timeout_budget" -gt "$DMABUF_MAX_TOTAL_SECONDS" ]; then
    test_result_record \
        "FAIL" \
        "DMA-BUF timeout budget exceeds ${DMABUF_MAX_TOTAL_SECONDS}s, selected=$dmabuf_selected_count per_heap_timeout=${DMABUF_TIMEOUT}s total=${dmabuf_timeout_budget}s"
    test_result_finish
fi
log_info "[DMABUF-SELECTION] source=$DMABUF_SELECTION_REASON count=$dmabuf_selected_count timeout_budget=${dmabuf_timeout_budget}s artifact=$SELECTED_HEAPS"
log_file_with_label "DMABUF-SELECTED" "$SELECTED_HEAPS" 64

dmabuf_python_command=$(dmabuf_heap_find_python || true)
if [ -z "$dmabuf_python_command" ]; then
    test_result_record \
        "SKIP" \
        "Image-provided Python 3 is unavailable, the dependency-free DMA-BUF UAPI runner cannot execute"
    test_result_finish
fi

dmabuf_page_size=$(
    "$dmabuf_python_command" -c 'import mmap; print(mmap.PAGESIZE)' \
        2>/dev/null || true
)
case "$dmabuf_page_size" in
    ''|*[!0-9]*|0)
        test_result_finish \
            "FAIL" \
            "$TESTNAME FAIL: Python 3 could not report the runtime page size"
        ;;
esac
if [ $((DMABUF_ALLOCATION_BYTES % dmabuf_page_size)) -ne 0 ]; then
    test_result_record \
        "FAIL" \
        "DMA-BUF allocation size must be page aligned, size=$DMABUF_ALLOCATION_BYTES page_size=$dmabuf_page_size"
    test_result_finish
fi
log_info "[DMABUF-RUNTIME] python=$dmabuf_python_command page_size=$dmabuf_page_size runner=$DMABUF_RUNNER"

dmabuf_case_index=0
while IFS= read -r dmabuf_heap_name; do
    [ -n "$dmabuf_heap_name" ] || continue
    dmabuf_case_index=$((dmabuf_case_index + 1))
    dmabuf_heap_path="$DMABUF_DEVICE_ROOT/$dmabuf_heap_name"
    dmabuf_safe_name=$(
        printf '%s' "$dmabuf_heap_name" | tr -c 'A-Za-z0-9._-' '-'
    )
    dmabuf_case_prefix=$(printf '%02d-%s' "$dmabuf_case_index" "$dmabuf_safe_name")
    dmabuf_log="$RESULT_DIR/heap-${dmabuf_case_prefix}.log"
    dmabuf_report="$RESULT_DIR/heap-${dmabuf_case_prefix}.tsv"

    log_info "[DMABUF-FUNCTIONAL] phase=start index=$dmabuf_case_index heap=$dmabuf_heap_name path=$dmabuf_heap_path bytes=$DMABUF_ALLOCATION_BYTES timeout=${DMABUF_TIMEOUT}s"
    run_with_timeout_log \
        "$DMABUF_TIMEOUT" \
        "$dmabuf_log" \
        "$dmabuf_python_command" "$DMABUF_RUNNER" \
            --heap "$dmabuf_heap_path" \
            --size "$DMABUF_ALLOCATION_BYTES" \
            --report "$dmabuf_report"
    dmabuf_run_rc=$?
    log_file_with_label "DMABUF-FUNCTIONAL" "$dmabuf_log" 20
    log_file_with_label "DMABUF-REPORT" "$dmabuf_report" 40

    dmabuf_report_status="missing"
    if [ -r "$dmabuf_report" ]; then
        dmabuf_report_status=$(
            awk -F '\t' '$1 == "status" { print $2; exit }' \
                "$dmabuf_report"
        )
        [ -n "$dmabuf_report_status" ] || dmabuf_report_status="missing"
    fi

    if [ "$dmabuf_run_rc" -eq 0 ] &&
       [ "$dmabuf_report_status" = "PASS" ]; then
        test_result_record \
            "PASS" \
            "DMA-BUF heap $dmabuf_heap_name completed allocate, shared-map, zero-check, synchronized deterministic write/read, unmap, and fd-release validation"
        DMABUF_PASS_COUNT=$((DMABUF_PASS_COUNT + 1))
    else
        test_result_record \
            "FAIL" \
            "DMA-BUF heap $dmabuf_heap_name functional validation failed, rc=$dmabuf_run_rc report_status=$dmabuf_report_status log=$dmabuf_log report=$dmabuf_report"
    fi
done <"$SELECTED_HEAPS"

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'dma[-_ ]?(heap|buf)' \
    'dma_buf:.*debugfs statistics unavailable'
dmabuf_dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record \
        "SKIP" \
        "Kernel log access is unavailable for DMA-BUF health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$dmabuf_dmesg_rc" -eq 0 ]; then
    log_file_with_label \
        "DMABUF-KERNEL-ERROR" \
        "$RESULT_DIR/kernel/dmesg_errors.log" \
        25
    test_result_record \
        "FAIL" \
        "DMA-BUF kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record \
        "PASS" \
        "No relevant DMA-BUF kernel errors were found in the captured kernel log"
fi

if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] &&
   [ "$DMABUF_PASS_COUNT" -eq 0 ]; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: no selected DMA-BUF heap completed the functional transaction"
fi

test_result_finish
