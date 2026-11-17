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
TESTNAME="PD_Mapper_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

PD_MAPPER_TIMEOUT="${PD_MAPPER_TIMEOUT:-10}"
PD_MAPPER_SERVICE="${PD_MAPPER_SERVICE:-}"
PD_MAPPER_SERVICE_SOURCE="dynamic-registry"
if [ -n "$PD_MAPPER_SERVICE" ]; then
    PD_MAPPER_SERVICE_SOURCE="environment"
fi
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
TOPOLOGY_FILE="$RESULT_DIR/qrtr_lookup.log"
KERNEL_REPORT="$RESULT_DIR/pd_mapper_kernel.tsv"
REGISTRY_LIST="$RESULT_DIR/service_registry_files.log"
REGISTRY_REPORT="$RESULT_DIR/service_registry_validation.tsv"
FUNCTIONAL_LOG="$RESULT_DIR/pd_mapper_functional.log"
FUNCTIONAL_REPORT="$RESULT_DIR/pd_mapper_domains.tsv"
PD_MAPPER_CORE_UNVERIFIED=0

# usage
# Takes no arguments, prints the supported CLI contract to stdout, and has no
# side effects.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --timeout SECONDS   Bound runtime probes, default: 10" \
        "  --service NAME      Select a registry-provided service for the functional query" \
        "  -h, --help" \
        "Kernel and userspace PD Mapper applicability, endpoints, and service data are discovered automatically." \
        "CLI options override environment variables."
}

# parse_args <suite-arguments...>
# Applies option values and selection provenance to suite globals. Produces no
# stdout, returns 0 on success or 2 for a missing or unknown argument, and does
# not probe QRTR or mutate target state.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout)
                [ "$#" -ge 2 ] || return 2
                PD_MAPPER_TIMEOUT="$2"
                shift 2
                ;;
            --service)
                [ "$#" -ge 2 ] || return 2
                PD_MAPPER_SERVICE="$2"
                if [ -n "$PD_MAPPER_SERVICE" ]; then
                    PD_MAPPER_SERVICE_SOURCE="cli"
                else
                    PD_MAPPER_SERVICE_SOURCE="dynamic-registry"
                fi
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
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "PD Mapper validation: selecting the kernel implementation first, falling back to userspace, and querying a discovered service through QMI"
log_info "[PD-MAPPER-POLICY] applicability=dynamic implementation=kernel-first-userspace-fallback service_tuple=64:1:1 qmi_version=0x101 source=public-protocol timeout=${PD_MAPPER_TIMEOUT}s functional_service=${PD_MAPPER_SERVICE:-auto} service_source=$PD_MAPPER_SERVICE_SOURCE"

case "$PD_MAPPER_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "PD Mapper configuration is invalid, timeout must be a positive integer"
        test_result_finish
        ;;
esac

pd_mapper_capture_kernel_runtime "$KERNEL_REPORT"
pd_mapper_log_kernel_runtime "$KERNEL_REPORT" 32

qrtr_service_discover pd-mapper.service pd-mapper pd-mapper
log_info "[PD-MAPPER-USERSPACE] fallback_candidate=yes unit=pd-mapper.service unit_exists=$QRTR_SERVICE_UNIT_EXISTS active=$QRTR_SERVICE_ACTIVE pids=${QRTR_SERVICE_PIDS:-none} binary=${QRTR_SERVICE_BINARY_PATH:-not-found}"
if [ "$PD_MAPPER_AUX_COUNT" -eq 0 ] && [ "$QRTR_SERVICE_APPLICABLE" -eq 1 ]; then
    qrtr_capture_service_evidence \
        pd-mapper.service \
        pd-mapper \
        "$RESULT_DIR/service" \
        "$PD_MAPPER_TIMEOUT"
    log_file_with_label "PD-MAPPER-SERVICE-STATUS" "$RESULT_DIR/service/systemd-status.log" 15
    log_file_with_label "PD-MAPPER-PROCESS" "$RESULT_DIR/service/process.log" 10
fi

pd_mapper_tuple_present=0
qrtr_capture_topology "$TOPOLOGY_FILE" "$PD_MAPPER_TIMEOUT"
topology_rc=$?
if [ "$topology_rc" -eq 0 ]; then
    log_info "[PD-MAPPER-QRTR] lookup_provider=$QRTR_LOOKUP_PROVIDER command=$QRTR_LOOKUP_COMMAND artifact=$TOPOLOGY_FILE"
fi
case "$topology_rc" in
    0)
        if qrtr_topology_has_service "$TOPOLOGY_FILE" 64 1 1; then
            pd_mapper_tuple_present=1
            log_info "[PD-MAPPER-QRTR] expected=64:1:1 qmi_version=0x101 observed=present artifact=$TOPOLOGY_FILE"
            qrtr_log_service_matches "$TOPOLOGY_FILE" 64 1 1 "PD-MAPPER-QRTR-ENDPOINT"
        else
            log_fail "[PD-MAPPER-QRTR] expected=64:1:1 qmi_version=0x101 observed=missing artifact=$TOPOLOGY_FILE"
        fi
        ;;
    2)
        log_info "[PD-MAPPER-QRTR] expected=64:1:1 qmi_version=0x101 observed=unavailable reason=qrtr-runtime-or-lookup-unavailable"
        ;;
    *)
        log_fail "[PD-MAPPER-QRTR] expected=64:1:1 qmi_version=0x101 observed=query-failed rc=$topology_rc artifact=$TOPOLOGY_FILE"
        log_file_with_label "PD-MAPPER-QRTR-RAW" "$TOPOLOGY_FILE" 25
        ;;
esac

if [ "$PD_MAPPER_AUX_COUNT" -gt 0 ]; then
    PD_MAPPER_IMPLEMENTATION="kernel"
    log_info "[PD-MAPPER-SELECTION] implementation=kernel source=runtime-auxiliary-device userspace_fallback=not-selected"
elif [ "$QRTR_SERVICE_APPLICABLE" -eq 1 ]; then
    PD_MAPPER_IMPLEMENTATION="userspace"
    log_info "[PD-MAPPER-SELECTION] implementation=userspace source=service-or-process-discovery reason=no-kernel-auxiliary-device"
elif [ "$pd_mapper_tuple_present" -eq 1 ]; then
    PD_MAPPER_IMPLEMENTATION="protocol-only"
    log_info "[PD-MAPPER-SELECTION] implementation=unattributed source=live-qrtr-advertisement reason=no-kernel-auxiliary-or-userspace-owner-evidence"
else
    PD_MAPPER_IMPLEMENTATION="none"
fi

if [ "$PD_MAPPER_IMPLEMENTATION" = "none" ]; then
    test_result_record "SKIP" "No runtime kernel PD Mapper auxiliary device, userspace service or process, or service 64:1:1 advertisement was discovered, config=$PD_MAPPER_KERNEL_CONFIG driver=$PD_MAPPER_DRIVER_STATE binary=${QRTR_SERVICE_BINARY_PATH:-not-found}"
    test_result_finish
fi

if [ "$PD_MAPPER_IMPLEMENTATION" = "kernel" ]; then
    if [ "$PD_MAPPER_UNBOUND_COUNT" -gt 0 ] ||
       [ "$PD_MAPPER_WRONG_DRIVER_COUNT" -gt 0 ]; then
        test_result_record "FAIL" "Kernel PD Mapper exposes $PD_MAPPER_AUX_COUNT auxiliary device(s), unbound=$PD_MAPPER_UNBOUND_COUNT wrong_driver=$PD_MAPPER_WRONG_DRIVER_COUNT artifact=$KERNEL_REPORT"
    else
        test_result_record "PASS" "All $PD_MAPPER_BOUND_COUNT kernel PD Mapper auxiliary device(s) are bound to the registered qcom-pdm-mapper auxiliary driver"
    fi
fi

if [ "$PD_MAPPER_IMPLEMENTATION" = "userspace" ]; then
    if [ "$QRTR_SERVICE_ACTIVE" -eq 1 ]; then
        test_result_record "PASS" "Userspace PD Mapper fallback is active, pids=${QRTR_SERVICE_PIDS:-systemd-confirmed} binary=${QRTR_SERVICE_BINARY_PATH:-not-in-path}"
    else
        test_result_record "FAIL" "Userspace PD Mapper is provisioned but inactive, unit_exists=$QRTR_SERVICE_UNIT_EXISTS binary=${QRTR_SERVICE_BINARY_PATH:-not-found} status_artifact=$RESULT_DIR/service/systemd-status.log"
    fi
fi

if [ "$pd_mapper_tuple_present" -eq 1 ]; then
    test_result_record "PASS" "PD Mapper advertises QRTR service 64 version 1 instance 1, representing QMI version 0x101"
elif [ "$PD_MAPPER_IMPLEMENTATION" != "protocol-only" ] && [ "$topology_rc" -eq 2 ]; then
    test_result_record "SKIP" "PD Mapper runtime is present but neither QRTR lookup provider nor QRTR runtime evidence is available"
    PD_MAPPER_CORE_UNVERIFIED=1
elif [ "$PD_MAPPER_IMPLEMENTATION" != "protocol-only" ]; then
    test_result_record "FAIL" "$PD_MAPPER_IMPLEMENTATION PD Mapper is present but does not advertise QRTR service 64 version 1 instance 1 for QMI version 0x101"
fi

pd_mapper_capture_registry_files "$REGISTRY_LIST"
pd_mapper_registry_valid=0
if pd_mapper_validate_registry_files \
    "$REGISTRY_LIST" \
    "$REGISTRY_REPORT" \
    "$PD_MAPPER_TIMEOUT"; then
    log_info "[PD-MAPPER-REGISTRY] files=$PD_MAPPER_REGISTRY_COUNT validated=$PD_MAPPER_REGISTRY_VALIDATED_COUNT validator=$PD_MAPPER_REGISTRY_VALIDATOR list=$REGISTRY_LIST report=$REGISTRY_REPORT"
    log_file_with_label "PD-MAPPER-REGISTRY-FILE" "$REGISTRY_REPORT" 32
    if [ "$PD_MAPPER_REGISTRY_COUNT" -eq 0 ]; then
        test_result_record "SKIP" "No service-registry .jsn files were discovered from running remoteproc firmware paths"
    elif [ "$PD_MAPPER_REGISTRY_VALIDATOR" = "unavailable" ]; then
        test_result_record "SKIP" "$PD_MAPPER_REGISTRY_COUNT service-registry file(s) were discovered but no image-provided JSON validator is available"
    elif [ "$PD_MAPPER_REGISTRY_VALIDATED_COUNT" -eq 0 ]; then
        test_result_record "SKIP" "$PD_MAPPER_REGISTRY_COUNT service-registry file(s) were discovered but none could be validated (xz without Python lzma)"
    else
        test_result_record "PASS" "Validated $PD_MAPPER_REGISTRY_VALIDATED_COUNT service-registry file(s)"
        pd_mapper_registry_valid=1
    fi
else
    log_fail "[PD-MAPPER-REGISTRY] files=$PD_MAPPER_REGISTRY_COUNT invalid=$PD_MAPPER_REGISTRY_INVALID_COUNT report=$REGISTRY_REPORT"
    log_file_with_label "PD-MAPPER-REGISTRY-FILE" "$REGISTRY_REPORT" 32
    test_result_record "FAIL" "$PD_MAPPER_REGISTRY_INVALID_COUNT discovered service-registry file(s) are malformed"
fi

pd_mapper_functional_ready=0
if [ "$pd_mapper_tuple_present" -eq 1 ] &&
   [ "$pd_mapper_registry_valid" -eq 1 ]; then
    pd_mapper_functional_ready=1
elif [ "$pd_mapper_tuple_present" -eq 1 ] &&
     [ "$PD_MAPPER_IMPLEMENTATION" = "kernel" ] &&
     [ "$PD_MAPPER_REGISTRY_COUNT" -eq 0 ]; then
    pd_mapper_functional_ready=1
fi

if [ "$pd_mapper_functional_ready" -eq 1 ]; then
    endpoint=$(qrtr_find_service_endpoint "$TOPOLOGY_FILE" 64 1 1 2>/dev/null)
    endpoint_rc=$?
    if [ "$endpoint_rc" -eq 2 ]; then
        log_info "[PD-MAPPER-FUNCTIONAL] phase=selection action=skip reason=multiple-service-endpoints"
        qrtr_log_service_matches "$TOPOLOGY_FILE" 64 1 1 "PD-MAPPER-FUNCTIONAL-CANDIDATE"
        test_result_record "SKIP" "Multiple PD Mapper endpoints are advertised, the functional client will not select one by enumeration order"
    elif [ "$endpoint_rc" -ne 0 ]; then
        test_result_record "FAIL" "PD Mapper endpoint could not be resolved from the validated topology, rc=$endpoint_rc"
    elif ! command -v python3 >/dev/null 2>&1; then
        test_result_record "SKIP" "PD Mapper functional query requires image-provided Python"
    else
        functional_node=$(printf '%s\n' "$endpoint" | awk '{ print $1 }')
        functional_port=$(printf '%s\n' "$endpoint" | awk '{ print $2 }')
        functional_outer_timeout=$((PD_MAPPER_TIMEOUT + 5))
        log_info "[PD-MAPPER-FUNCTIONAL] phase=start implementation=$PD_MAPPER_IMPLEMENTATION operation=get-domain-list message_id=0x21 service=${PD_MAPPER_SERVICE:-auto} service_source=$PD_MAPPER_SERVICE_SOURCE node=$functional_node port=$functional_port protocol_timeout=${PD_MAPPER_TIMEOUT}s watchdog=${functional_outer_timeout}s"
        run_with_timeout_log \
            "$functional_outer_timeout" \
            "$FUNCTIONAL_LOG" \
            python3 "$TOOLS/pd_mapper_client.py" \
                --node "$functional_node" \
                --port "$functional_port" \
                --registry-list "$REGISTRY_LIST" \
                --report-file "$FUNCTIONAL_REPORT" \
                --service "$PD_MAPPER_SERVICE" \
                --implementation "$PD_MAPPER_IMPLEMENTATION" \
                --timeout "$PD_MAPPER_TIMEOUT"
        functional_rc=$?
        log_file_with_label "PD-MAPPER-FUNCTIONAL" "$FUNCTIONAL_LOG" 25
        log_file_with_label "PD-MAPPER-DOMAIN" "$FUNCTIONAL_REPORT" 32
        if [ "$functional_rc" -eq 0 ]; then
            test_result_record "PASS" "PD Mapper completed a QMI get-domain-list request with validated domain data, implementation=$PD_MAPPER_IMPLEMENTATION report=$FUNCTIONAL_REPORT"
        elif [ "$functional_rc" -eq 2 ]; then
            test_result_record "SKIP" "The PD Mapper functional client found no selectable registry service"
        else
            test_result_record "FAIL" "PD Mapper QMI get-domain-list functional validation failed, implementation=$PD_MAPPER_IMPLEMENTATION rc=$functional_rc artifact=$FUNCTIONAL_LOG"
        fi
    fi
elif [ "$pd_mapper_tuple_present" -eq 1 ]; then
    test_result_record "SKIP" "PD Mapper functional query needs at least one validated runtime service-registry file to derive a portable service and expected domain set"
fi

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'pd-mapper|servreg|qrtr|qcom_glink|glink|rpmsg' \
    'endpoint is not connected'
dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for PD Mapper health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$dmesg_rc" -eq 0 ]; then
    log_file_with_label "PD-MAPPER-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 25
    test_result_record "FAIL" "PD Mapper or QRTR kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No persistent PD Mapper or QRTR kernel errors were found"
fi

if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$PD_MAPPER_CORE_UNVERIFIED" -eq 1 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: PD Mapper is present but its required QRTR service advertisement could not be verified"
fi

test_result_finish
