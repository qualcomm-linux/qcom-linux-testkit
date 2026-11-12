#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# qrtr_classify_kernel_failures <captured-directory>
# Separate local QRTR/GLINK/RPMSG transport faults from remoteproc platform
# diagnostics using one retained snapshot. Preserve attributable fault blocks.
# Write qrtr_failures.log and remoteproc_errors.log. No target mutation or new
# kernel read occurs. Return 0 for transport faults, 1 for clean, 2 for unavailable.
qrtr_classify_kernel_failures() (
    qck_dir="$1"
    [ -s "$qck_dir/dmesg_snapshot.log" ] && [ -r "$qck_dir/dmesg_errors.log" ] || return 2
    : >"$qck_dir/remoteproc_errors.log" || return 2
    awk -v platform="$qck_dir/remoteproc_errors.log" '
        {
            text=tolower($0)
            sub(/^[[:space:]]*/, "", text)
            while (text ~ /^\[[^]]*\]/) sub(/^\[[^]]*\][[:space:]]*/, "", text)
            if (text ~ /^(tqftp|qrtr|qcom_glink|glink|rpmsg)[^[:space:]:]*([[:space:]][^:]*)?:/) {
                print
            } else if (text ~ /^(remoteproc|qcom_q6v5|qcom.*pas)[^[:space:]:]*([[:space:]][^:]*)?:/) {
                if (text ~ /(^|[^[:alnum:]_])(tqftp|qrtr|glink|rpmsg)([^[:alnum:]_]|$)/) print
                else print $0 >> platform
            }
        }
    ' "$qck_dir/dmesg_errors.log" >"$qck_dir/qrtr_failures.log" || return 2
    kernel_log_filter_faults "$qck_dir/dmesg_snapshot.log" \
        'tqftp|qrtr|qcom_glink|glink|rpmsg' >"$qck_dir/qrtr_fault_blocks.log" || return 2
    cat "$qck_dir/qrtr_fault_blocks.log" >>"$qck_dir/qrtr_failures.log" || return 2
    kernel_log_filter_faults "$qck_dir/dmesg_snapshot.log" \
        'remoteproc|qcom_q6v5|qcom.*pas' >"$qck_dir/remoteproc_fault_blocks.log" || return 2
    cat "$qck_dir/remoteproc_fault_blocks.log" >>"$qck_dir/remoteproc_errors.log" || return 2
    [ -s "$qck_dir/qrtr_failures.log" ] && return 0
    return 1
)

# qrtr_analyze_topology <raw-file> <normalized-file> <summary-file>
# Validates qrtr-lookup rows, rejects duplicate endpoint tuples, writes a stable
# TSV representation, and exports bounded topology counts and failure detail.
# Inputs: readable raw topology and two destination paths. Output: no stdout.
# Returns: 0 when valid, 1 on processing failure, 3 for invalid input.
# Side effects: replaces normalized and summary artifacts and exports QRTR_TOPOLOGY_*.
qrtr_analyze_topology() {
    qat_raw_file="$1"
    qat_normalized_file="$2"
    qat_summary_file="$3"

    QRTR_TOPOLOGY_ROW_COUNT=0
    QRTR_TOPOLOGY_SERVICE_COUNT=0
    QRTR_TOPOLOGY_NODE_COUNT=0
    QRTR_TOPOLOGY_FAILURE_REASON=""

    if [ ! -r "$qat_raw_file" ] ||
       [ -z "$qat_normalized_file" ] ||
       [ -z "$qat_summary_file" ]; then
        QRTR_TOPOLOGY_FAILURE_REASON="invalid-input"
        export QRTR_TOPOLOGY_ROW_COUNT QRTR_TOPOLOGY_SERVICE_COUNT
        export QRTR_TOPOLOGY_NODE_COUNT QRTR_TOPOLOGY_FAILURE_REASON
        return 3
    fi

    mkdir -p "$(dirname "$qat_normalized_file")" || return 1
    rm -f "$qat_normalized_file" "$qat_summary_file"

    awk -v normalized="$qat_normalized_file" -v summary="$qat_summary_file" '
        BEGIN {
            OFS="\t"
            print "service", "version", "instance", "node", "port" > normalized
        }
        NR == 1 {
            if ($1 != "Service" || $2 != "Version" || $3 != "Instance" ||
                $4 != "Node" || $5 != "Port") {
                reason="invalid-header"
                exit 1
            }
            next
        }
        NF == 0 {
            next
        }
        {
            for (field=1; field<=5; field++) {
                if (field == 2 && $1 == 4097 && $2 == "N/A") {
                    continue
                }
                if ($field !~ /^[0-9]+$/) {
                    reason="non-numeric-field-at-line-" NR
                    exit 1
                }
            }
            if (($4 + 0) == 0 || ($5 + 0) == 0) {
                reason="zero-node-or-port-at-line-" NR
                exit 1
            }
            tuple=$1 SUBSEP $2 SUBSEP $3 SUBSEP $4 SUBSEP $5
            if (tuple in tuples) {
                reason="duplicate-endpoint-at-line-" NR
                exit 1
            }
            tuples[tuple]=1
            services[$1 SUBSEP $2 SUBSEP $3]=1
            nodes[$4]=1
            rows++
            print $1, $2, $3, $4, $5 >> normalized
        }
        END {
            if (reason == "" && rows == 0) {
                reason="no-service-rows"
            }
            service_count=0
            node_count=0
            for (key in services) {
                service_count++
            }
            for (key in nodes) {
                node_count++
            }
            print "rows=" rows > summary
            print "services=" service_count >> summary
            print "nodes=" node_count >> summary
            print "reason=" reason >> summary
            if (reason != "") {
                exit 1
            }
        }
    ' "$qat_raw_file"
    qat_rc=$?

    if [ -r "$qat_summary_file" ]; then
        QRTR_TOPOLOGY_ROW_COUNT=$(
            sed -n 's/^rows=//p' "$qat_summary_file" | sed -n '1p'
        )
        QRTR_TOPOLOGY_SERVICE_COUNT=$(
            sed -n 's/^services=//p' "$qat_summary_file" | sed -n '1p'
        )
        QRTR_TOPOLOGY_NODE_COUNT=$(
            sed -n 's/^nodes=//p' "$qat_summary_file" | sed -n '1p'
        )
        QRTR_TOPOLOGY_FAILURE_REASON=$(
            sed -n 's/^reason=//p' "$qat_summary_file" | sed -n '1p'
        )
    fi

    export QRTR_TOPOLOGY_ROW_COUNT QRTR_TOPOLOGY_SERVICE_COUNT
    export QRTR_TOPOLOGY_NODE_COUNT QRTR_TOPOLOGY_FAILURE_REASON
    return "$qat_rc"
}

# qrtr_log_runtime_evidence
# Logs the runtime indicators and lookup command used for applicability.
# Inputs: QRTR runtime sysfs, procfs, modules, and optional lookup overrides.
# Output: no machine-readable stdout. Returns: 0. Side effects: emits one log line.
qrtr_log_runtime_evidence() {
    qlre_sysfs=absent
    qlre_proc=absent
    qlre_module=absent
    qlre_lookup=not-found

    [ -d /sys/bus/qrtr ] && qlre_sysfs=present
    [ -r /proc/net/qrtr ] && qlre_proc=present
    if [ -d /sys/module/qrtr ] || is_module_loaded qrtr; then
        qlre_module=loaded-or-built-in
    fi
    qlre_lookup=$(command -v "${QRTR_LOOKUP_BIN:-qrtr-lookup}" 2>/dev/null || true)
    qlre_python=$(command -v python3 2>/dev/null || true)
    qlre_fallback="${QRTR_LOOKUP_FALLBACK_BIN:-$TOOLS/qrtr_lookup.py}"
    qlre_fallback_state=unavailable
    if [ -n "$qlre_python" ] && [ -r "$qlre_fallback" ]; then
        qlre_fallback_state=available
    fi
    log_info "[QRTR-RUNTIME] sys_bus=$qlre_sysfs proc_net=$qlre_proc module=$qlre_module native_lookup=${qlre_lookup:-not-found} fallback=$qlre_fallback_state python=${qlre_python:-not-found}"
}

# qrtr_log_topology <normalized-file> [max-rows] [label]
# Replays normalized endpoint tuples as bounded, human-readable live evidence.
# Inputs: normalized TSV, positive row limit, and optional label. Output: logs only.
# Returns: 0 when replayed, 1 when unreadable, 3 for an invalid limit.
qrtr_log_topology() {
    qlt_file="$1"
    qlt_max_rows="${2:-64}"
    qlt_label="${3:-QRTR-SERVICE}"
    qlt_total=0
    qlt_emitted=0

    [ -r "$qlt_file" ] || return 1
    case "$qlt_max_rows" in
        ''|*[!0-9]*|0)
            return 3
            ;;
    esac

    qlt_total=$(awk 'NR > 1 && NF >= 5 { count++ } END { print count + 0 }' "$qlt_file")
    while IFS="$(printf '\t')" read -r qlt_service qlt_version qlt_instance qlt_node qlt_port; do
        [ "$qlt_service" = "service" ] && continue
        [ -n "$qlt_port" ] || continue
        if [ "$qlt_emitted" -ge "$qlt_max_rows" ]; then
            break
        fi
        log_info "[$qlt_label] service=$qlt_service version=$qlt_version instance=$qlt_instance node=$qlt_node port=$qlt_port"
        qlt_emitted=$((qlt_emitted + 1))
    done <"$qlt_file"

    if [ "$qlt_total" -gt "$qlt_emitted" ]; then
        log_info "[$qlt_label] omitted=$((qlt_total - qlt_emitted)) total=$qlt_total artifact=$qlt_file"
    fi
}

# qrtr_log_service_matches <topology-file> <service> <version> <instance> [label]
# Logs every endpoint matching one protocol tuple, including its node and port.
# Inputs: normalized topology, decimal tuple fields, and optional label.
# Output: logs only. Returns: 0 when readable, 1 otherwise. Side effects: none.
qrtr_log_service_matches() {
    qlsm_file="$1"
    qlsm_service="$2"
    qlsm_version="$3"
    qlsm_instance="$4"
    qlsm_label="${5:-QRTR-MATCH}"

    [ -r "$qlsm_file" ] || return 1
    awk -v service="$qlsm_service" -v version="$qlsm_version" \
        -v instance="$qlsm_instance" '
        NR > 1 && $1 == service && $2 == version && $3 == instance {
            print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5
        }
    ' "$qlsm_file" |
    while IFS="$(printf '\t')" read -r qlsm_s qlsm_v qlsm_i qlsm_node qlsm_port; do
        log_info "[$qlsm_label] service=$qlsm_s version=$qlsm_v instance=$qlsm_i node=$qlsm_node port=$qlsm_port"
    done
}

# qrtr_find_service_endpoint <topology-file> <service> <version> <instance>
# Prints a unique matching node and port as two tab-separated decimal values.
# Returns 2 when multiple endpoints match so callers do not select by order.
# Inputs: normalized topology and decimal tuple fields. Side effects: none.
# Returns: 0 for one match, 1 for none/unreadable input, 2 for multiple matches.
qrtr_find_service_endpoint() {
    qfse_file="$1"
    qfse_service="$2"
    qfse_version="$3"
    qfse_instance="$4"

    [ -r "$qfse_file" ] || return 1
    awk -v service="$qfse_service" -v version="$qfse_version" \
        -v instance="$qfse_instance" '
        NR > 1 && $1 == service && $2 == version && $3 == instance {
            node=$4
            port=$5
            count++
        }
        END {
            if (count == 1) {
                print node "\t" port
                exit 0
            }
            if (count > 1) {
                exit 2
            }
            exit 1
        }
    ' "$qfse_file"
}

# qrtr_validate_expected_services <topology-file> <selectors> <report-file>
# Validates comma-separated service[:version[:instance]] selectors and records
# one stable report row per requested selector.
# Inputs: normalized topology, selector list, and destination report path.
# Output: no stdout. Returns: 0 when present, 1 when missing, 3 for invalid input.
# Side effects: replaces the report and exports QRTR_EXPECTED_* counters/reason.
qrtr_validate_expected_services() {
    qves_topology_file="$1"
    qves_selectors="$2"
    qves_report_file="$3"
    qves_list_file="${qves_report_file}.selectors"

    QRTR_EXPECTED_SERVICE_COUNT=0
    QRTR_MISSING_SERVICE_COUNT=0
    QRTR_EXPECTED_FAILURE_REASON=""

    if [ ! -r "$qves_topology_file" ] || [ -z "$qves_report_file" ]; then
        QRTR_EXPECTED_FAILURE_REASON="invalid-input"
        export QRTR_EXPECTED_SERVICE_COUNT QRTR_MISSING_SERVICE_COUNT
        export QRTR_EXPECTED_FAILURE_REASON
        return 3
    fi

    : >"$qves_report_file" || return 1
    if [ -z "$qves_selectors" ]; then
        rm -f "$qves_list_file"
        export QRTR_EXPECTED_SERVICE_COUNT QRTR_MISSING_SERVICE_COUNT
        export QRTR_EXPECTED_FAILURE_REASON
        return 0
    fi

    printf '%s\n' "$qves_selectors" | tr ',' '\n' >"$qves_list_file" || return 1

    while IFS= read -r qves_selector; do
        if [ -z "$qves_selector" ]; then
            QRTR_EXPECTED_FAILURE_REASON="empty-selector"
            break
        fi

        qves_colon_count=$(
            printf '%s' "$qves_selector" | tr -cd ':' | wc -c | tr -d '[:space:]'
        )
        case "$qves_colon_count" in
            0|1|2)
                ;;
            *)
                QRTR_EXPECTED_FAILURE_REASON="invalid-selector-$qves_selector"
                break
                ;;
        esac

        qves_service=${qves_selector%%:*}
        qves_remainder=${qves_selector#*:}
        qves_version=""
        qves_instance=""

        if [ "$qves_remainder" != "$qves_selector" ]; then
            qves_version=${qves_remainder%%:*}
            if [ "${qves_remainder#*:}" != "$qves_remainder" ]; then
                qves_instance=${qves_remainder#*:}
            fi
        fi

        case "$qves_service" in
            ''|*[!0-9]*)
                QRTR_EXPECTED_FAILURE_REASON="invalid-selector-$qves_selector"
                break
                ;;
        esac

        if [ "$qves_colon_count" -ge 1 ]; then
            case "$qves_version" in
                ''|*[!0-9]*)
                    QRTR_EXPECTED_FAILURE_REASON="invalid-selector-$qves_selector"
                    break
                    ;;
            esac
        fi
        if [ "$qves_colon_count" -eq 2 ]; then
            case "$qves_instance" in
                ''|*[!0-9]*)
                    QRTR_EXPECTED_FAILURE_REASON="invalid-selector-$qves_selector"
                    break
                    ;;
            esac
        fi

        QRTR_EXPECTED_SERVICE_COUNT=$((QRTR_EXPECTED_SERVICE_COUNT + 1))
        if qrtr_topology_has_service \
            "$qves_topology_file" \
            "$qves_service" \
            "$qves_version" \
            "$qves_instance"; then
            printf '%s\tpresent\n' "$qves_selector" >>"$qves_report_file"
        else
            QRTR_MISSING_SERVICE_COUNT=$((QRTR_MISSING_SERVICE_COUNT + 1))
            printf '%s\tmissing\n' "$qves_selector" >>"$qves_report_file"
        fi
    done <"$qves_list_file"

    rm -f "$qves_list_file"
    export QRTR_EXPECTED_SERVICE_COUNT QRTR_MISSING_SERVICE_COUNT
    export QRTR_EXPECTED_FAILURE_REASON

    if [ -n "$QRTR_EXPECTED_FAILURE_REASON" ]; then
        return 3
    fi

    [ "$QRTR_MISSING_SERVICE_COUNT" -eq 0 ]
}

# pd_mapper_capture_kernel_runtime <report-file>
# Captures kernel PD Mapper configuration, driver registration, module state,
# and each runtime auxiliary device without assuming a SoC-specific instance.
# Input: destination TSV path. Output: no stdout.
# Returns: 0 on capture, 1 on artifact failure, 3 for invalid input.
# Side effects: replaces the report and exports PD_MAPPER_* runtime counters.
pd_mapper_capture_kernel_runtime() {
    pmckr_report_file="$1"

    [ -n "$pmckr_report_file" ] || return 3
    : >"$pmckr_report_file" || return 1

    PD_MAPPER_KERNEL_CONFIG="unknown"
    PD_MAPPER_MODULE_STATE="not-exposed"
    PD_MAPPER_DRIVER_STATE="not-registered"
    PD_MAPPER_REGISTERED_DRIVER="none"
    PD_MAPPER_AUX_COUNT=0
    PD_MAPPER_BOUND_COUNT=0
    PD_MAPPER_UNBOUND_COUNT=0
    PD_MAPPER_WRONG_DRIVER_COUNT=0

    pmckr_config_line=$(kernel_config_value CONFIG_QCOM_PD_MAPPER 2>/dev/null || true)
    if [ -n "$pmckr_config_line" ]; then
        PD_MAPPER_KERNEL_CONFIG=${pmckr_config_line#CONFIG_QCOM_PD_MAPPER=}
    fi
    if [ -d /sys/module/qcom_pd_mapper ]; then
        PD_MAPPER_MODULE_STATE="loaded"
    elif [ "$PD_MAPPER_KERNEL_CONFIG" = "y" ]; then
        PD_MAPPER_MODULE_STATE="built-in-or-not-instantiated"
    fi
    for pmckr_driver_path in \
        /sys/bus/auxiliary/drivers/qcom-pdm-mapper \
        /sys/bus/auxiliary/drivers/*.qcom-pdm-mapper; do
        [ -d "$pmckr_driver_path" ] || continue
        PD_MAPPER_DRIVER_STATE="registered"
        PD_MAPPER_REGISTERED_DRIVER=${pmckr_driver_path##*/}
        break
    done

    printf 'kind\tname\tdriver\tparent\tstate\n' >"$pmckr_report_file"
    for pmckr_device in /sys/bus/auxiliary/devices/qcom_common.pd-mapper.*; do
        [ -e "$pmckr_device" ] || continue
        PD_MAPPER_AUX_COUNT=$((PD_MAPPER_AUX_COUNT + 1))
        pmckr_name=${pmckr_device##*/}
        pmckr_resolved=$(readlink -f "$pmckr_device" 2>/dev/null || true)
        pmckr_parent=$(dirname "${pmckr_resolved:-$pmckr_device}")
        pmckr_driver="unbound"
        pmckr_state="unbound"
        if [ -L "$pmckr_device/driver" ]; then
            pmckr_driver=$(basename "$(readlink -f "$pmckr_device/driver")")
            pmckr_state="bound"
            PD_MAPPER_BOUND_COUNT=$((PD_MAPPER_BOUND_COUNT + 1))
            case "$pmckr_driver" in
                qcom-pdm-mapper|*.qcom-pdm-mapper)
                    ;;
                *)
                    pmckr_state="wrong-driver"
                    PD_MAPPER_WRONG_DRIVER_COUNT=$((PD_MAPPER_WRONG_DRIVER_COUNT + 1))
                    ;;
            esac
        else
            PD_MAPPER_UNBOUND_COUNT=$((PD_MAPPER_UNBOUND_COUNT + 1))
        fi
        printf 'aux\t%s\t%s\t%s\t%s\n' \
            "$pmckr_name" \
            "$pmckr_driver" \
            "$pmckr_parent" \
            "$pmckr_state" >>"$pmckr_report_file"
    done

    export PD_MAPPER_KERNEL_CONFIG PD_MAPPER_MODULE_STATE
    export PD_MAPPER_REGISTERED_DRIVER
    export PD_MAPPER_DRIVER_STATE PD_MAPPER_AUX_COUNT
    export PD_MAPPER_BOUND_COUNT PD_MAPPER_UNBOUND_COUNT
    export PD_MAPPER_WRONG_DRIVER_COUNT
}

# pd_mapper_log_kernel_runtime <report-file> [max-devices]
# Replays bounded auxiliary-device binding evidence to the live log.
# Inputs: PD Mapper TSV and optional device limit. Output: logs only.
# Returns: 0 when readable, 1 otherwise. Side effects: none.
pd_mapper_log_kernel_runtime() {
    pmlkr_report_file="$1"
    pmlkr_max_devices="${2:-32}"
    pmlkr_emitted=0

    [ -r "$pmlkr_report_file" ] || return 1
    log_info "[PD-MAPPER-KERNEL] config=$PD_MAPPER_KERNEL_CONFIG module=$PD_MAPPER_MODULE_STATE driver_state=$PD_MAPPER_DRIVER_STATE registered_driver=$PD_MAPPER_REGISTERED_DRIVER auxiliary_devices=$PD_MAPPER_AUX_COUNT bound=$PD_MAPPER_BOUND_COUNT unbound=$PD_MAPPER_UNBOUND_COUNT wrong_driver=$PD_MAPPER_WRONG_DRIVER_COUNT artifact=$pmlkr_report_file"
    while IFS="$(printf '\t')" read -r pmlkr_kind pmlkr_name pmlkr_driver pmlkr_parent pmlkr_state; do
        [ "$pmlkr_kind" = "kind" ] && continue
        if [ "$pmlkr_emitted" -ge "$pmlkr_max_devices" ]; then
            break
        fi
        log_info "[PD-MAPPER-AUX] device=$pmlkr_name driver=$pmlkr_driver parent=$pmlkr_parent state=$pmlkr_state"
        pmlkr_emitted=$((pmlkr_emitted + 1))
    done <"$pmlkr_report_file"
    if [ "$PD_MAPPER_AUX_COUNT" -gt "$pmlkr_emitted" ]; then
        log_info "[PD-MAPPER-AUX] omitted=$((PD_MAPPER_AUX_COUNT - pmlkr_emitted)) total=$PD_MAPPER_AUX_COUNT artifact=$pmlkr_report_file"
    fi
}

# runtime_process_pids <process-name>
# Prints a space-separated PID list for exact executable names.
# Input: exact process name. Output: PID list on stdout.
# Returns: provider status, or 2 for invalid input/no supported process tool.
# Side effects: none.
runtime_process_pids() {
    rpp_name="$1"

    [ -n "$rpp_name" ] || return 2

    if command -v pidof >/dev/null 2>&1; then
        pidof "$rpp_name" 2>/dev/null
        return $?
    fi

    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x "$rpp_name" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//'
        return $?
    fi

    return 2
}

# qrtr_service_discover <unit> <process-name> <binary-name>
# Exports read-only provisioning and runtime state for a QRTR userspace service.
# Inputs: optional systemd unit, exact process name, and executable name.
# Output: no stdout. Returns: 0.
# Side effects: exports QRTR_SERVICE_* applicability and runtime fields.
qrtr_service_discover() {
    qsd_unit="$1"
    qsd_process="$2"
    qsd_binary="$3"

    QRTR_SERVICE_UNIT_EXISTS=0
    QRTR_SERVICE_ACTIVE=0
    QRTR_SERVICE_PIDS=""
    QRTR_SERVICE_BINARY_PATH=""
    QRTR_SERVICE_APPLICABLE=0

    if [ -n "$qsd_unit" ] && systemd_service_exists "$qsd_unit"; then
        QRTR_SERVICE_UNIT_EXISTS=1
        QRTR_SERVICE_APPLICABLE=1
        if systemd_service_is_active "$qsd_unit"; then
            QRTR_SERVICE_ACTIVE=1
        fi
    fi

    QRTR_SERVICE_PIDS=$(runtime_process_pids "$qsd_process" 2>/dev/null || true)
    if [ -n "$QRTR_SERVICE_PIDS" ]; then
        QRTR_SERVICE_ACTIVE=1
        QRTR_SERVICE_APPLICABLE=1
    fi

    QRTR_SERVICE_BINARY_PATH=$(command -v "$qsd_binary" 2>/dev/null || true)

    export QRTR_SERVICE_UNIT_EXISTS QRTR_SERVICE_ACTIVE QRTR_SERVICE_PIDS
    export QRTR_SERVICE_BINARY_PATH QRTR_SERVICE_APPLICABLE
}

# pd_mapper_capture_registry_files <output-file>
# Lists service-registry files from the firmware directories selected by the
# running remoteproc instances. It does not recursively scan all firmware.
# Input: destination list path. Output: no stdout.
# Returns: 0 on capture, 1 on artifact failure, 3 for invalid input.
# Side effects: replaces and sorts the retained file list.
pd_mapper_capture_registry_files() {
    pmcrf_output_file="$1"
    pmcrf_firmware_override=""

    [ -n "$pmcrf_output_file" ] || return 3
    : >"$pmcrf_output_file" || return 1

    if [ -r /sys/module/firmware_class/parameters/path ]; then
        pmcrf_firmware_override=$(
            sed -n '1p' /sys/module/firmware_class/parameters/path 2>/dev/null
        )
    fi

    for pmcrf_remoteproc in /sys/class/remoteproc/remoteproc*; do
        [ -r "$pmcrf_remoteproc/firmware" ] || continue
        pmcrf_firmware=$(sed -n '1p' "$pmcrf_remoteproc/firmware" 2>/dev/null)
        [ -n "$pmcrf_firmware" ] || continue
        pmcrf_relative_dir=${pmcrf_firmware%/*}
        if [ "$pmcrf_relative_dir" = "$pmcrf_firmware" ]; then
            pmcrf_relative_dir=""
        fi

        for pmcrf_root in "$pmcrf_firmware_override" /lib/firmware /vendor/firmware; do
            [ -n "$pmcrf_root" ] || continue
            pmcrf_directory="$pmcrf_root"
            if [ -n "$pmcrf_relative_dir" ]; then
                pmcrf_directory="$pmcrf_root/$pmcrf_relative_dir"
            fi
            [ -d "$pmcrf_directory" ] || continue

            find "$pmcrf_directory" -maxdepth 1 -type f \
                \( -name '*.jsn' -o -name '*.jsn.xz' \) \
                -print 2>/dev/null >>"$pmcrf_output_file"
        done
    done

    if [ -s "$pmcrf_output_file" ]; then
        sort -u "$pmcrf_output_file" -o "$pmcrf_output_file"
    fi
}

# pd_mapper_validate_registry_files <list-file> <report-file> [timeout]
# Uses image-provided Python when available to parse plain or xz-compressed
# service-registry JSON files. Missing Python leaves the files informational.
# Inputs: registry list, report destination, and positive per-file timeout.
# Output: no stdout. Returns: 0 when no invalid files are found, 1 otherwise,
# or 3 for invalid input. Exports PD_MAPPER_REGISTRY_* counters and validator.
pd_mapper_validate_registry_files() {
    pmvrf_list_file="$1"
    pmvrf_report_file="$2"
    pmvrf_timeout="${3:-5}"

    PD_MAPPER_REGISTRY_COUNT=0
    PD_MAPPER_REGISTRY_VALIDATED_COUNT=0
    PD_MAPPER_REGISTRY_INVALID_COUNT=0
    PD_MAPPER_REGISTRY_VALIDATOR="unavailable"

    [ -r "$pmvrf_list_file" ] && [ -n "$pmvrf_report_file" ] || return 3
    : >"$pmvrf_report_file" || return 1

    if command -v python3 >/dev/null 2>&1; then
        PD_MAPPER_REGISTRY_VALIDATOR="python3"
    fi

    while IFS= read -r pmvrf_file; do
        [ -n "$pmvrf_file" ] || continue
        PD_MAPPER_REGISTRY_COUNT=$((PD_MAPPER_REGISTRY_COUNT + 1))

        if [ "$PD_MAPPER_REGISTRY_VALIDATOR" = "unavailable" ]; then
            printf '%s\tnot-validated\n' "$pmvrf_file" >>"$pmvrf_report_file"
            continue
        fi

        if run_with_timeout "$pmvrf_timeout" python3 -c '
import json, lzma, pathlib, sys
path = pathlib.Path(sys.argv[1])
opener = lzma.open if path.name.endswith(".xz") else open
with opener(path, "rt", encoding="utf-8") as stream:
    root = json.load(stream)
if not isinstance(root, dict):
    raise ValueError("root is not an object")
domain = root.get("sr_domain")
services = root.get("sr_service")
if not isinstance(domain, dict) or not isinstance(services, list):
    raise ValueError("sr_domain or sr_service has the wrong type")
for key in ("soc", "domain", "subdomain"):
    if not isinstance(domain.get(key), str) or not domain[key]:
        raise ValueError("sr_domain.%s is missing or invalid" % key)
instance = domain.get("qmi_instance_id")
if not isinstance(instance, (int, float)) or isinstance(instance, bool):
    raise ValueError("sr_domain.qmi_instance_id is missing or invalid")
for entry in services:
    if not isinstance(entry, dict):
        raise ValueError("sr_service entry is not an object")
    for key in ("provider", "service"):
        if not isinstance(entry.get(key), str) or not entry[key]:
            raise ValueError("sr_service.%s is missing or invalid" % key)
' "$pmvrf_file" >/dev/null 2>&1; then
            PD_MAPPER_REGISTRY_VALIDATED_COUNT=$((PD_MAPPER_REGISTRY_VALIDATED_COUNT + 1))
            printf '%s\tvalid\n' "$pmvrf_file" >>"$pmvrf_report_file"
        else
            PD_MAPPER_REGISTRY_INVALID_COUNT=$((PD_MAPPER_REGISTRY_INVALID_COUNT + 1))
            printf '%s\tinvalid\n' "$pmvrf_file" >>"$pmvrf_report_file"
        fi
    done <"$pmvrf_list_file"

    export PD_MAPPER_REGISTRY_COUNT PD_MAPPER_REGISTRY_VALIDATED_COUNT
    export PD_MAPPER_REGISTRY_INVALID_COUNT PD_MAPPER_REGISTRY_VALIDATOR

    [ "$PD_MAPPER_REGISTRY_INVALID_COUNT" -eq 0 ]
}

# qrtr_capture_service_evidence <unit> <process> <result-dir> [timeout]
# Captures bounded systemd and process evidence without changing service state.
# Inputs: optional unit, exact process name, result directory, and timeout seconds.
# Output: no stdout. Returns: 0 after capture, 1 if artifacts cannot be created.
# Side effects: replaces service evidence and exports QCSE_STATUS_RC/QCSE_JOURNAL_RC.
qrtr_capture_service_evidence() {
    qcse_unit="$1"
    qcse_process="$2"
    qcse_result_dir="$3"
    qcse_timeout="${4:-10}"
    qcse_process_file="$qcse_result_dir/process.log"

    mkdir -p "$qcse_result_dir" || return 1
    : >"$qcse_process_file" || return 1

    if command -v ps >/dev/null 2>&1; then
        ps 2>&1 | awk -v name="$qcse_process" '
            NR == 1 || $0 ~ "(^|[ /])" name "([[:space:]]|$)" { print }
        ' >"$qcse_process_file"
    fi

    if [ -n "$qcse_unit" ] && systemd_service_exists "$qcse_unit"; then
        run_with_timeout_log \
            "$qcse_timeout" \
            "$qcse_result_dir/systemd-status.log" \
            systemctl --no-pager --full --lines=20 status "$qcse_unit"
        QCSE_STATUS_RC=$?

        if command -v journalctl >/dev/null 2>&1; then
            run_with_timeout_log \
                "$qcse_timeout" \
                "$qcse_result_dir/journal.log" \
                journalctl --no-pager -q -b -u "$qcse_unit" -n 200
            QCSE_JOURNAL_RC=$?
        else
            QCSE_JOURNAL_RC=127
            : >"$qcse_result_dir/journal.log"
        fi
    else
        QCSE_STATUS_RC=127
        QCSE_JOURNAL_RC=127
        : >"$qcse_result_dir/systemd-status.log"
        : >"$qcse_result_dir/journal.log"
    fi

    export QCSE_STATUS_RC QCSE_JOURNAL_RC
    return 0
}
