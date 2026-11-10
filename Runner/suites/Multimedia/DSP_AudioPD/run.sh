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

TESTNAME="DSP_AudioPD"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# usage
# Describe the readiness-only contract and supported invocation.
usage() {
    printf '%s\n' "Usage: $0 [--help], validates ADSP allocator and daemon readiness, not an AudioPD transaction"
}

# parse_args <arguments...>
# Reject unsupported options before daemon startup.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *)
                test_result_finish FAIL "Unsupported AudioPD option: $1"
                ;;
        esac
    done
}
parse_args "$@"

# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies adsprpcd find cat awk readlink grep sed tr mkdir mktemp date sleep; then
    test_result_finish SKIP "Image-provided AudioPD daemon or inventory utilities are unavailable"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || test_result_finish FAIL "Cannot create AudioPD evidence in CWD"
OWNED_ADSPRPC_PID=""

# cleanup
# Stop only the exact child started by this runner, never all adsprpcd PIDs.
cleanup() {
    if [ -n "$OWNED_ADSPRPC_PID" ]; then
        # shellcheck disable=SC2034 # Consumed by the shared bounded cancellation.
        MANAGED_TIMEOUT_CMD_PID="$OWNED_ADSPRPC_PID"
        if ! managed_timeout_cancel_bounded 2; then
            printf '%s FAIL\n' "$TESTNAME" >"$RES_FILE"
            log_fail "Test-owned adsprpcd did not stop"
            return 1
        fi
        OWNED_ADSPRPC_PID=""
    fi
}
# shellcheck disable=SC2034 # Consumed by shared finalization.
TEST_RESULT_CLEANUP=cleanup
trap cleanup 0
trap 'test_result_finish FAIL "AudioPD validation interrupted"' HUP INT TERM

# check_adsprpcd_wait_state <pid>
# Inspect an already alive daemon, return 0 for observed readiness or 2 for unavailable evidence.
check_adsprpcd_wait_state() {
    pid="$1"
    pid=$(sanitize_pid "$pid")

    case "$pid" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    # Prefer /proc/<pid>/wchan (more commonly available)
    if [ -r "/proc/$pid/wchan" ]; then
        wchan=$(tr -d '\r\n' <"/proc/$pid/wchan" 2>/dev/null)

        # Keep wchan for debug. It is timing-sensitive and may move between
        # poll/epoll/nanosleep while the daemon is alive and healthy.
        case "$wchan" in
            do_sys_poll*|ep_poll*|do_epoll_wait*|poll_schedule_timeout*)
                log_info "adsprpcd PID $pid wchan='$wchan' (accepted)"
                return 0
                ;;
            *)
                log_info "adsprpcd PID $pid wchan='$wchan' (debug only, not used as failure gate)"
                return 0
                ;;
        esac
    fi

    # Fallback: /proc/<pid>/stack (may be missing depending on kernel config)
    if [ -r "/proc/$pid/stack" ]; then
        if grep -qE "(do_sys_poll|ep_poll|do_epoll_wait|poll_schedule_timeout)" "/proc/$pid/stack" 2>/dev/null; then
            log_info "adsprpcd PID $pid stack contains expected wait symbol"
            return 0
        fi

        log_info "adsprpcd PID $pid stack does not contain expected wait symbols (debug only)"
        return 0
    fi

    # Neither interface is available -> SKIP
    log_skip "Kernel does not expose /proc/$pid/(wchan|stack), cannot validate adsprpcd wait state"
    return 2
}

adsp_entries=$(get_remoteproc_by_firmware adsp "" all) || adsp_entries=""
[ -n "$adsp_entries" ] || test_result_finish SKIP "No registered ADSP runtime instance"
adsp_ready=0
while IFS='|' read -r adsp_path adsp_state adsp_firmware adsp_name; do
    log_info "ADSP instance=$adsp_path state=$adsp_state firmware=$adsp_firmware name=$adsp_name"
    [ "$adsp_state" = running ] && adsp_ready=1
done <<ADSP_INSTANCES
$adsp_entries
ADSP_INSTANCES
[ "$adsp_ready" -eq 1 ] || test_result_finish FAIL "Registered ADSP is not running"
adsp_endpoint=""
for adsp_node in /dev/fastrpc-adsp-secure /dev/fastrpc-adsp; do
    if [ -c "$adsp_node" ]; then
        adsp_endpoint="$adsp_node"
        break
    fi
done
[ -n "$adsp_endpoint" ] || test_result_finish SKIP "Image exposes no ADSP FastRPC character endpoint"
adsp_owner=$(readlink -f "/sys/class/misc/${adsp_endpoint##*/}/device") || adsp_owner=""
allocator_ready=0
while [ -n "$adsp_owner" ] && [ "$adsp_owner" != / ]; do
    allocator_node=$(readlink -f "$adsp_owner/of_node" 2>/dev/null || true)
    if [ -d "$allocator_node" ] && dt_node_enabled "$allocator_node"; then
        allocator_compat=$(dt_property_text "$allocator_node" compatible 2>/dev/null || true)
        if printf '%s\n' "$allocator_compat" | grep -Fxq qcom,fastrpc; then
            if [ -s "$allocator_node/memory-region" ] && [ -s "$allocator_node/qcom,vmids" ]; then
                allocator_ready=1
                log_info "ADSP endpoint=$adsp_endpoint enabled allocator=$allocator_node"
                break
            fi
            test_result_finish FAIL "ADSP endpoint allocator lacks memory-region or qcom,vmids"
        fi
    fi
    adsp_owner=${adsp_owner%/*}
done
if [ "$allocator_ready" -eq 0 ]; then
    allocator_candidates="$OUT_DIR/adsp-allocator-nodes.log"
    : >"$allocator_candidates"
    while IFS='|' read -r adsp_path adsp_state adsp_firmware adsp_name; do
        adsp_runtime=$(readlink -f "$adsp_path") || continue
        adsp_controller=${adsp_runtime%/remoteproc/*}
        adsp_dt=$(readlink -f "$adsp_controller/of_node" 2>/dev/null || true)
        [ -d "$adsp_dt" ] || continue
        find "$adsp_dt" -type d >>"$allocator_candidates" || test_result_finish FAIL "ADSP allocator traversal failed"
    done <<ADSP_ALLOCATOR_INSTANCES
$adsp_entries
ADSP_ALLOCATOR_INSTANCES
    while IFS= read -r allocator_node; do
        dt_node_enabled "$allocator_node" || continue
        allocator_compat=$(dt_property_text "$allocator_node" compatible 2>/dev/null || true)
        if printf '%s\n' "$allocator_compat" | grep -Fxq qcom,fastrpc; then
            if [ -s "$allocator_node/memory-region" ] && [ -s "$allocator_node/qcom,vmids" ]; then
                allocator_ready=1
                log_info "Registered ADSP owns enabled allocator=$allocator_node"
                break
            fi
            test_result_finish FAIL "ADSP allocator DT is exposed but lacks memory-region or qcom,vmids"
        fi
    done <"$allocator_candidates"
fi
# Older ADSP stacks can expose only their reserved remote heap. Keep that
# documented fallback only when no owned FastRPC parent was found.
if [ "$allocator_ready" -eq 0 ]; then
    adsp_dt_root=$(dt_runtime_root || true)
    if [ -d "$adsp_dt_root/reserved-memory" ]; then
        find "$adsp_dt_root/reserved-memory" -type d >"$OUT_DIR/adsp-reserved-nodes.log" || test_result_finish FAIL "Reserved-memory traversal failed"
        while IFS= read -r adsp_heap; do
            dt_node_enabled "$adsp_heap" || continue
            case "${adsp_heap##*/}" in
                *adsp*rpc*remote*heap*)
                    if [ -s "$adsp_heap/reg" ]; then
                        allocator_ready=1
                        log_info "Legacy ADSP endpoint=$adsp_endpoint reserved heap=$adsp_heap"
                        break
                    fi
                    ;;
            esac
        done <"$OUT_DIR/adsp-reserved-nodes.log"
    fi
fi
[ "$allocator_ready" -eq 1 ] || test_result_finish SKIP "ADSP endpoint has no exposed enabled allocator DT with memory-region and qcom,vmids"
scan_dmesg_errors "$OUT_DIR" 'fastrpc|remoteproc|qcom.*pas|qcom_q6v5' 'not a crash|non-fatal' || true
if [ -s "$OUT_DIR/dmesg_errors.log" ]; then
    log_file_with_label AUDIOPD-ERROR "$OUT_DIR/dmesg_errors.log"
    test_result_finish FAIL "Captured FastRPC or ADSP kernel errors"
fi
PIDS=$(get_one_pid_by_name adsprpcd all 2>/dev/null || true)
if [ -z "$PIDS" ]; then
    adsprpcd >"$OUT_DIR/adsprpcd.log" 2>&1 &
    OWNED_ADSPRPC_PID=$!
    PIDS="$OWNED_ADSPRPC_PID"
fi
for daemon_pid in $PIDS; do
    if ! wait_pid_alive "$daemon_pid" 2; then
        test_result_record FAIL "adsprpcd PID $daemon_pid did not remain alive, no unrelated daemon substituted"
        continue
    fi
    check_adsprpcd_wait_state "$daemon_pid"
    daemon_rc=$?
    case "$daemon_rc" in
        0)
            test_result_record PASS "adsprpcd PID $daemon_pid readiness observed, no RPC transaction was exercised"
            ;;
        2)
            test_result_record SKIP "Daemon wait-state evidence unavailable"
            ;;
        *)
            test_result_record FAIL "Daemon readiness failed"
            ;;
    esac
done
cleanup || test_result_record FAIL "AudioPD daemon cleanup failed"
test_result_finish
