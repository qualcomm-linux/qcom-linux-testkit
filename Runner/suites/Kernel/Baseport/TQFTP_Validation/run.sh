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
. "$TOOLS/lib_qrtr.sh"
TESTNAME="TQFTP_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

TQFTP_TIMEOUT="${TQFTP_TIMEOUT:-10}"
TQFTP_STATE_DIR="${TQFTP_STATE_DIR:-/var/lib/tqftpserv}"
TQFTP_E2E_ENABLE="${TQFTP_E2E_ENABLE:-1}"
RESULT_DIR="$PWD/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
TOPOLOGY_FILE="$RESULT_DIR/qrtr_lookup.log"
REQUEST_REPORT="$RESULT_DIR/request_markers.log"
TQFTP_CORE_UNVERIFIED=0
TQFTP_TEST_SOURCE=""

# cleanup
# Remove only the temporary TQFTP source created by this run and close stdout capture.
# Inputs: trap status and TQFTP_TEST_SOURCE. Output: logs only.
# Returns: exits through _runner_stdout_cleanup. Side effects: removes the staged file.
cleanup() {
    cleanup_status=$?
    if [ -n "$TQFTP_TEST_SOURCE" ] && [ -f "$TQFTP_TEST_SOURCE" ]; then
        log_warn "[TQFTP-E2E] phase=cleanup action=remove-temporary-source path=$TQFTP_TEST_SOURCE trigger=exit-or-signal"
        rm -f "$TQFTP_TEST_SOURCE" || true
    fi
    [ "$cleanup_status" -eq 0 ]
    _runner_stdout_cleanup
}

# usage
# Print TQFTP CLI options, automatic discovery behavior, and precedence.
# Inputs: none. Output: help text on stdout. Returns: 0. Side effects: none.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --timeout SECONDS   Bound runtime probes, default: 10" \
        "  --state-dir PATH    Override a custom TQFTP read-write directory" \
        "  --e2e 0|1           Local QRTR read-transfer validation, default: 1" \
        "  -h, --help" \
        "Service applicability and QRTR endpoints are discovered automatically." \
        "CLI options override environment variables."
}

# parse_args ARG...
# Parse CLI overrides into TQFTP timeout, state-directory, and E2E policy globals.
# Inputs: command-line arguments. Output: no stdout.
# Returns: 0 on success, 2 for invalid input, or exits after help. Side effects: globals.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout)
                [ "$#" -ge 2 ] || return 2
                TQFTP_TIMEOUT="$2"
                shift 2
                ;;
            --state-dir)
                [ "$#" -ge 2 ] || return 2
                TQFTP_STATE_DIR="$2"
                shift 2
                ;;
            --e2e)
                [ "$#" -ge 2 ] || return 2
                TQFTP_E2E_ENABLE="$2"
                shift 2
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

test_result_init "$TESTNAME" "$RES_FILE"
trap cleanup EXIT HUP INT TERM
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "TQFTP validation: checking server readiness and an optional exact local-host file transfer over QRTR service 4096:1:0"
log_info "[TQFTP-POLICY] applicability=dynamic service_tuple=4096:1:0 source=public-runtime-contract state_dir=$TQFTP_STATE_DIR timeout=${TQFTP_TIMEOUT}s e2e=$TQFTP_E2E_ENABLE transport=local-AF_QIPCRTR"

case "$TQFTP_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "TQFTP configuration is invalid, timeout must be a positive integer"
        test_result_finish
        ;;
esac

case "$TQFTP_E2E_ENABLE" in
    0|1)
        ;;
    *)
        test_result_record "FAIL" "TQFTP E2E enable must be 0 or 1, observed=$TQFTP_E2E_ENABLE"
        test_result_finish
        ;;
esac

case "$TQFTP_STATE_DIR" in
    /*)
        ;;
    *)
        test_result_record "FAIL" "TQFTP state directory must be an absolute path, observed=$TQFTP_STATE_DIR"
        test_result_finish
        ;;
esac

qrtr_service_discover tqftpserv.service tqftpserv tqftpserv
log_info "[TQFTP-DISCOVERY] unit=tqftpserv.service unit_exists=$QRTR_SERVICE_UNIT_EXISTS active=$QRTR_SERVICE_ACTIVE pids=${QRTR_SERVICE_PIDS:-none} binary=${QRTR_SERVICE_BINARY_PATH:-not-found} state_dir=$TQFTP_STATE_DIR"

if [ "$QRTR_SERVICE_APPLICABLE" -eq 0 ]; then
    test_result_record "SKIP" "TQFTP has no installed service unit or running process, binary=${QRTR_SERVICE_BINARY_PATH:-not-found}"
    test_result_finish
fi

qrtr_capture_service_evidence \
    tqftpserv.service \
    tqftpserv \
    "$RESULT_DIR/service" \
    "$TQFTP_TIMEOUT"

if [ "$QRTR_SERVICE_ACTIVE" -ne 1 ]; then
    log_file_with_label "TQFTP-SERVICE-STATUS" "$RESULT_DIR/service/systemd-status.log" 25
    log_file_with_label "TQFTP-PROCESS" "$RESULT_DIR/service/process.log" 10
    test_result_record "FAIL" "TQFTP is provisioned but not active, unit_exists=$QRTR_SERVICE_UNIT_EXISTS binary=${QRTR_SERVICE_BINARY_PATH:-not-found} status_artifact=$RESULT_DIR/service/systemd-status.log"
else
    test_result_record "PASS" "TQFTP runtime is active, pids=${QRTR_SERVICE_PIDS:-systemd-confirmed}"
fi

if [ "$QRTR_SERVICE_ACTIVE" -eq 1 ]; then
    qrtr_capture_topology "$TOPOLOGY_FILE" "$TQFTP_TIMEOUT"
    topology_rc=$?
    case "$topology_rc" in
        0)
            log_info "[TQFTP-QRTR] lookup_provider=$QRTR_LOOKUP_PROVIDER command=$QRTR_LOOKUP_COMMAND artifact=$TOPOLOGY_FILE"
            if qrtr_topology_has_service "$TOPOLOGY_FILE" 4096 1 0; then
                log_info "[TQFTP-QRTR] expected=4096:1:0 observed=present artifact=$TOPOLOGY_FILE"
                qrtr_log_service_matches "$TOPOLOGY_FILE" 4096 1 0 "TQFTP-QRTR-ENDPOINT"
                test_result_record "PASS" "TQFTP advertises QRTR service 4096 version 1 instance 0"
            else
                log_fail "[TQFTP-QRTR] expected=4096:1:0 observed=missing artifact=$TOPOLOGY_FILE"
                log_file_with_label "TQFTP-QRTR-RAW" "$TOPOLOGY_FILE" 25
                test_result_record "FAIL" "Active TQFTP does not advertise QRTR service 4096 version 1 instance 0"
            fi
            ;;
        2)
            test_result_record "SKIP" "TQFTP is active but neither QRTR lookup provider nor QRTR runtime evidence is available"
            TQFTP_CORE_UNVERIFIED=1
            ;;
        *)
            log_file_with_label "TQFTP-QRTR-RAW" "$TOPOLOGY_FILE" 25
            test_result_record "FAIL" "TQFTP QRTR topology query failed, rc=$topology_rc artifact=$TOPOLOGY_FILE"
            ;;
    esac
fi

if [ -d "$TQFTP_STATE_DIR" ]; then
    if [ -r "$TQFTP_STATE_DIR" ] && [ -w "$TQFTP_STATE_DIR" ]; then
        state_listing="$RESULT_DIR/state_directory.log"
        ls -la "$TQFTP_STATE_DIR" >"$state_listing" 2>&1
        state_entries=$(find "$TQFTP_STATE_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d '[:space:]')
        log_info "[TQFTP-STATE] path=$TQFTP_STATE_DIR access=read-write entries=${state_entries:-unknown} artifact=$state_listing"
        log_file_with_label "TQFTP-STATE-ENTRY" "$state_listing" 20
        test_result_record "PASS" "TQFTP state directory is accessible at $TQFTP_STATE_DIR"
    else
        log_fail "[TQFTP-STATE] path=$TQFTP_STATE_DIR access=insufficient"
        test_result_record "FAIL" "TQFTP state directory exists but is not readable and writable by the test user"
    fi
else
    test_result_record "SKIP" "TQFTP state directory is not present at $TQFTP_STATE_DIR"
fi

if [ "$TQFTP_E2E_ENABLE" = "1" ] &&
   [ "$QRTR_SERVICE_ACTIVE" -eq 1 ] &&
   [ "${topology_rc:-1}" -eq 0 ] &&
   qrtr_topology_has_service "$TOPOLOGY_FILE" 4096 1 0; then
    if ! command -v python3 >/dev/null 2>&1; then
        test_result_record "SKIP" "TQFTP E2E requires image-provided Python"
    elif [ ! -d "$TQFTP_STATE_DIR" ] || [ ! -w "$TQFTP_STATE_DIR" ]; then
        test_result_record "SKIP" "TQFTP E2E cannot stage its temporary read-only payload in $TQFTP_STATE_DIR"
    else
        endpoint=$(qrtr_find_service_endpoint "$TOPOLOGY_FILE" 4096 1 0 2>/dev/null)
        endpoint_rc=$?
        if [ "$endpoint_rc" -eq 2 ]; then
            log_info "[TQFTP-E2E] phase=selection action=skip reason=multiple-service-endpoints"
            qrtr_log_service_matches "$TOPOLOGY_FILE" 4096 1 0 "TQFTP-E2E-CANDIDATE"
            test_result_record "SKIP" "Multiple TQFTP service endpoints are advertised, local server ownership cannot be selected safely by enumeration order"
            endpoint=""
        elif [ "$endpoint_rc" -ne 0 ]; then
            test_result_record "FAIL" "TQFTP service endpoint could not be resolved from the validated topology, rc=$endpoint_rc"
            endpoint=""
        fi
        e2e_node=$(printf '%s\n' "$endpoint" | awk '{ print $1 }')
        e2e_port=$(printf '%s\n' "$endpoint" | awk '{ print $2 }')
        e2e_received="$RESULT_DIR/tqftp_e2e_received.bin"
        e2e_log="$RESULT_DIR/tqftp_e2e.log"
        e2e_ready=1
        if [ "$endpoint_rc" -ne 0 ]; then
            e2e_ready=0
        fi
        if [ "$e2e_ready" -eq 1 ]; then
            case "$e2e_node" in
                ''|*[!0-9]*)
                    test_result_record "FAIL" "TQFTP endpoint discovery returned an invalid node or port, observed=${endpoint:-empty}"
                    e2e_ready=0
                    ;;
            esac
            case "$e2e_port" in
                ''|*[!0-9]*)
                    if [ "$e2e_ready" -eq 1 ]; then
                        test_result_record "FAIL" "TQFTP endpoint discovery returned an invalid node or port, observed=${endpoint:-empty}"
                    fi
                    e2e_ready=0
                    ;;
            esac
        fi
        if [ "$e2e_ready" -eq 1 ]; then
            if ! command -v mktemp >/dev/null 2>&1; then
                test_result_record "SKIP" "TQFTP E2E cannot stage a collision-safe temporary payload because mktemp is unavailable"
                e2e_ready=0
            else
                TQFTP_TEST_SOURCE=$(mktemp "$TQFTP_STATE_DIR/qli_tqftp_e2e.XXXXXX" 2>/dev/null || true)
                if [ -z "$TQFTP_TEST_SOURCE" ]; then
                    test_result_record "FAIL" "TQFTP E2E could not create a temporary source payload in $TQFTP_STATE_DIR"
                    e2e_ready=0
                elif ! chmod 0644 "$TQFTP_TEST_SOURCE"; then
                    test_result_record "FAIL" "TQFTP E2E could not make its temporary source payload readable by the server"
                    e2e_ready=0
                fi
            fi
        fi
        e2e_name=${TQFTP_TEST_SOURCE##*/}
        if [ "$e2e_ready" -eq 1 ] && ! awk 'BEGIN {
            for (line = 0; line < 64; line++) {
                printf "QLI_TQFTP_E2E_%04d_0123456789abcdef\n", line
            }
        }' >"$TQFTP_TEST_SOURCE"; then
            test_result_record "FAIL" "TQFTP E2E could not stage its temporary source payload at $TQFTP_TEST_SOURCE"
            e2e_ready=0
        fi
        if [ "$e2e_ready" -eq 1 ]; then
            e2e_source_bytes=$(wc -c <"$TQFTP_TEST_SOURCE" | tr -d '[:space:]')
            e2e_outer_timeout=$((TQFTP_TIMEOUT + 5))
            log_info "[TQFTP-E2E] phase=start client=python-AF_QIPCRTR server_node=$e2e_node service_port=$e2e_port remote_path=/readwrite/$e2e_name source_bytes=$e2e_source_bytes protocol_timeout=${TQFTP_TIMEOUT}s watchdog=${e2e_outer_timeout}s network=not-required"
            run_with_timeout_log \
                "$e2e_outer_timeout" \
                "$e2e_log" \
                python3 "$TOOLS/tqftp_client.py" \
                    --node "$e2e_node" \
                    --port "$e2e_port" \
                    --remote-path "/readwrite/$e2e_name" \
                    --expected-file "$TQFTP_TEST_SOURCE" \
                    --output-file "$e2e_received" \
                    --timeout "$TQFTP_TIMEOUT"
            e2e_rc=$?
            log_file_with_label "TQFTP-E2E" "$e2e_log" 25
            if [ "$e2e_rc" -eq 0 ]; then
                test_result_record "PASS" "TQFTP completed an exact local-host RRQ transfer over QRTR, bytes=$e2e_source_bytes artifact=$e2e_received"
            elif [ "$e2e_rc" -eq 2 ]; then
                test_result_record "SKIP" "The TQFTP E2E client reported that no functional registry input was selectable"
            else
                test_result_record "FAIL" "TQFTP local-host RRQ transfer failed, rc=$e2e_rc artifact=$e2e_log"
            fi
        fi
        if [ -f "$TQFTP_TEST_SOURCE" ]; then
            if rm -f "$TQFTP_TEST_SOURCE"; then
                log_info "[TQFTP-E2E] phase=cleanup action=removed-temporary-source path=$TQFTP_TEST_SOURCE"
                TQFTP_TEST_SOURCE=""
            else
                test_result_record "FAIL" "TQFTP E2E could not remove its temporary source file at $TQFTP_TEST_SOURCE"
            fi
        else
            TQFTP_TEST_SOURCE=""
        fi
    fi
elif [ "$TQFTP_E2E_ENABLE" = "0" ]; then
    test_result_record "SKIP" "TQFTP E2E transfer is disabled by policy, set --e2e 1 to enable it"
fi

qrtr_capture_service_evidence \
    tqftpserv.service \
    tqftpserv \
    "$RESULT_DIR/service" \
    "$TQFTP_TIMEOUT"

if grep -Ei '\[TQFTP\].*(WRQ|RRQ)|Remote returned END OF TRANSFER|opened for (reading|writing)' \
    "$RESULT_DIR/service/journal.log" >"$REQUEST_REPORT" 2>/dev/null; then
    request_count=$(wc -l <"$REQUEST_REPORT" | tr -d '[:space:]')
    log_info "[TQFTP-REQUEST] observed=$request_count artifact=$REQUEST_REPORT"
    log_file_with_label "TQFTP-REQUEST-MARKER" "$REQUEST_REPORT" 20
    test_result_record "PASS" "Observed $request_count historical TQFTP request or transfer marker(s)"
else
    : >"$REQUEST_REPORT"
    journal_lines=$(wc -l <"$RESULT_DIR/service/journal.log" 2>/dev/null | tr -d '[:space:]')
    log_info "[TQFTP-REQUEST] observed=0 action=none reason=no-remote-request-in-retained-journal journal_rc=${QCSE_JOURNAL_RC:-unknown} journal_lines=${journal_lines:-0} journal=$RESULT_DIR/service/journal.log readiness=passed"
    test_result_record "SKIP" "No TQFTP firmware request was observed in the retained journal window"
fi

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'tqftp[^[:space:]:]*|qrtr[^[:space:]:]*|qcom_glink[^[:space:]:]*|glink[^[:space:]:]*|rpmsg[^[:space:]:]*|remoteproc|qcom_q6v5[^[:space:]:]*' \
    'endpoint is not connected'
dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    TQFTP_CORE_UNVERIFIED=1
    test_result_record "SKIP" "Kernel log access is unavailable for TQFTP health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
else
    qrtr_classify_kernel_failures "$RESULT_DIR/kernel"
    dmesg_rc=$?
    if [ -s "$RESULT_DIR/kernel/remoteproc_errors.log" ]; then
        log_warn "DSP/modem platform faults were captured, inspect remoteproc suites independently of the local TQFTP transfer"
        log_file_with_label "TQFTP-PLATFORM-ERROR" "$RESULT_DIR/kernel/remoteproc_errors.log" 25
    fi
    case "$dmesg_rc" in
        0)
            log_file_with_label "TQFTP-KERNEL-ERROR" "$RESULT_DIR/kernel/qrtr_failures.log" 25
            test_result_record "FAIL" "TQFTP or QRTR/GLINK/RPMSG transport errors were detected, artifact=$RESULT_DIR/kernel/qrtr_failures.log"
            ;;
        1)
            test_result_record "PASS" "No attributable TQFTP or QRTR/GLINK/RPMSG transport errors were found"
            ;;
        *)
            TQFTP_CORE_UNVERIFIED=1
            test_result_record "SKIP" "TQFTP transport kernel health could not be classified, inspect retained kernel evidence"
            ;;
    esac
fi

if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$TQFTP_CORE_UNVERIFIED" -eq 1 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: TQFTP is active but required QRTR advertisement or kernel health evidence is unverified"
fi

test_result_finish
