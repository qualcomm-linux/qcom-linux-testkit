#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Shared helpers for Ethernet functional validation.

# ethv_sanitize_text <text>
#   Normalize text for a single-line, pipe-delimited result record.
#   stdout: sanitized text with repeated whitespace collapsed.
#   return: 0 on successful filtering, nonzero if a filter command fails.
ethv_sanitize_text() {
    printf '%s' "${1:-}" \
        | tr '\n\r\t|' '    ' \
        | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

# ethv_record_result <result-file> <check-name> <PASS|FAIL|SKIP> [details]
#   Append one result record and emit the matching functest log message.
#   stdout: logging output from log_pass, log_fail, or log_skip.
#   return: 1 when result-file is empty, otherwise the logging helper status.
ethv_record_result() {
    ethv_rr_file="${1:-}"
    ethv_rr_check="$(ethv_sanitize_text "${2:-unknown}")"
    ethv_rr_result="${3:-SKIP}"
    ethv_rr_details="$(ethv_sanitize_text "${4:-}")"

    [ -n "$ethv_rr_file" ] || return 1

    case "$ethv_rr_result" in
        PASS|FAIL|SKIP)
            ;;
        *)
            ethv_rr_result="FAIL"
            ;;
    esac

    printf '%s|%s|%s\n' \
        "$ethv_rr_check" \
        "$ethv_rr_result" \
        "$ethv_rr_details" >>"$ethv_rr_file"

    case "$ethv_rr_result" in
        PASS)
            log_pass "$ethv_rr_check: $ethv_rr_details"
            ;;
        FAIL)
            log_fail "$ethv_rr_check: $ethv_rr_details"
            ;;
        SKIP)
            log_skip "$ethv_rr_check: $ethv_rr_details"
            ;;
    esac
}

# ethv_result_count <result-file> <PASS|FAIL|SKIP>
#   Count records whose second pipe-delimited field matches the requested state.
#   stdout: unsigned decimal count, including zero.
#   return: awk status, nonzero when the result file cannot be processed.
ethv_result_count() {
    ethv_rc_file="${1:-}"
    ethv_rc_status="${2:-}"

    awk -F '|' -v wanted="$ethv_rc_status" '
        $2 == wanted {
            count++
        }
        END {
            print count + 0
        }
    ' "$ethv_rc_file" 2>/dev/null
}

# ethv_print_summary <result-file> [title]
#   Print a formatted table and PASS, FAIL, and SKIP totals for a result file.
#   stdout: summary title, table, and totals.
#   return: status of the final printf operation.
ethv_print_summary() {
    ethv_ps_file="${1:-}"
    ethv_ps_title="${2:-Ethernet Validation Summary}"
    ethv_ps_passed="$(ethv_result_count "$ethv_ps_file" PASS)"
    ethv_ps_failed="$(ethv_result_count "$ethv_ps_file" FAIL)"
    ethv_ps_skipped="$(ethv_result_count "$ethv_ps_file" SKIP)"

    log_info "$ethv_ps_title"
    printf '%s\n' "----------------------------------------------------------------------------------------------------"
    printf '%-38s %-7s %s\n' "Check" "Result" "Details"
    printf '%s\n' "----------------------------------------------------------------------------------------------------"

    while IFS='|' read -r ethv_ps_check ethv_ps_result ethv_ps_details; do
        [ -n "$ethv_ps_check" ] || continue
        printf '%-38s %-7s %s\n' \
            "$ethv_ps_check" \
            "$ethv_ps_result" \
            "$ethv_ps_details"
    done <"$ethv_ps_file"

    printf '%s\n' "----------------------------------------------------------------------------------------------------"
    printf 'Passed: %s  Failed: %s  Skipped: %s\n' \
        "$ethv_ps_passed" \
        "$ethv_ps_failed" \
        "$ethv_ps_skipped"
}

# ethv_compute_overall_result <result-file>
#   Resolve the aggregate state, prioritizing FAIL, then PASS, then SKIP.
#   stdout: exactly one of PASS, FAIL, or SKIP.
#   return: 0 after printing the aggregate state.
ethv_compute_overall_result() {
    ethv_cor_file="${1:-}"
    ethv_cor_passed="$(ethv_result_count "$ethv_cor_file" PASS)"
    ethv_cor_failed="$(ethv_result_count "$ethv_cor_file" FAIL)"

    if [ "$ethv_cor_failed" -gt 0 ]; then
        printf '%s\n' "FAIL"
    elif [ "$ethv_cor_passed" -gt 0 ]; then
        printf '%s\n' "PASS"
    else
        printf '%s\n' "SKIP"
    fi
}

# ethv_is_uint <value>
#   Test whether value contains one or more decimal digits and no sign.
#   stdout: none.
#   return: 0 for an unsigned integer, 1 otherwise.
ethv_is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ethv_is_positive_integer <value>
#   Test whether value is an unsigned decimal integer greater than zero.
#   stdout: none.
#   return: 0 for a positive integer, 1 otherwise.
ethv_is_positive_integer() {
    ethv_ipi_value="${1:-}"

    ethv_is_uint "$ethv_ipi_value" || return 1
    [ "$ethv_ipi_value" -gt 0 ]
}

# ethv_is_nonnegative_decimal <value>
#   Accept an unsigned integer or decimal with digits on both sides of the dot.
#   stdout: none.
#   return: 0 for a valid nonnegative decimal, 1 otherwise.
ethv_is_nonnegative_decimal() {
    ethv_ind_value="${1:-}"

    case "$ethv_ind_value" in
        ''|*[!0-9.]*|.*|*.|*.*.*)
            return 1
            ;;
        *.*)
            ethv_ind_whole="${ethv_ind_value%%.*}"
            ethv_ind_fraction="${ethv_ind_value#*.}"
            [ -n "$ethv_ind_whole" ] || return 1
            [ -n "$ethv_ind_fraction" ] || return 1
            ;;
    esac

    return 0
}

# ethv_is_boolean <value>
#   Validate the numeric boolean representation used by suite parameters.
#   stdout: none.
#   return: 0 for 0 or 1, 1 otherwise.
ethv_is_boolean() {
    case "${1:-}" in
        0|1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ethv_require_option_value <option-name> <remaining-argument-count>
#   Check that a CLI option has at least one following argument available.
#   stderr: an error identifying the option when its value is missing.
#   return: 0 when a value can follow, 1 when fewer than two arguments remain.
ethv_require_option_value() {
    ethv_rov_option="${1:-option}"
    ethv_rov_count="${2:-0}"

    if [ "$ethv_rov_count" -ge 2 ]; then
        return 0
    fi

    printf '[ERROR] %s requires a value\n' "$ethv_rov_option" >&2
    return 1
}

# ethv_read_first_line <file>
#   Read the first line from a readable sysfs, procfs, or regular file.
#   stdout: first line, followed by a newline.
#   return: 0 when the file is readable, 1 when it is not readable.
ethv_read_first_line() {
    ethv_rfl_file="${1:-}"

    [ -r "$ethv_rfl_file" ] || return 1
    IFS= read -r ethv_rfl_value <"$ethv_rfl_file" || true
    printf '%s\n' "$ethv_rfl_value"
}

# ethv_get_interfaces
#   Discover non-loopback, non-wireless Ethernet interfaces using the shared
#   repository helper first and a sysfs fallback when needed.
#   stdout: one unique interface name per line.
#   return: pipeline status, normally 0 even when no interface is found.
ethv_get_interfaces() {
    ethv_gi_interfaces=""

    if command -v get_ethernet_interfaces >/dev/null 2>&1; then
        ethv_gi_interfaces="$(get_ethernet_interfaces 2>/dev/null || true)"
    fi

    if [ -z "$ethv_gi_interfaces" ]; then
        for ethv_gi_path in /sys/class/net/*; do
            [ -e "$ethv_gi_path" ] || continue

            ethv_gi_iface="${ethv_gi_path##*/}"
            [ "$ethv_gi_iface" != "lo" ] || continue
            [ ! -d "$ethv_gi_path/wireless" ] || continue

            ethv_gi_type="$(ethv_read_first_line "$ethv_gi_path/type" 2>/dev/null || true)"
            [ "$ethv_gi_type" = "1" ] || continue
            [ -e "$ethv_gi_path/device" ] || continue

            ethv_gi_interfaces="$ethv_gi_interfaces $ethv_gi_iface"
        done
    fi

    for ethv_gi_iface in $ethv_gi_interfaces; do
        [ -d "/sys/class/net/$ethv_gi_iface" ] || continue
        [ "$ethv_gi_iface" != "lo" ] || continue
        [ ! -d "/sys/class/net/$ethv_gi_iface/wireless" ] || continue
        printf '%s\n' "$ethv_gi_iface"
    done | awk '!seen[$0]++'
}

# ethv_get_physical_interfaces
#   Restrict discovered Ethernet interfaces to entries backed by a sysfs device.
#   stdout: one physical interface name per line.
#   return: status of the discovery and filtering pipeline.
ethv_get_physical_interfaces() {
    ethv_get_interfaces |
    while IFS= read -r ethv_gpi_iface; do
        [ -n "$ethv_gpi_iface" ] || continue
        [ -e "/sys/class/net/$ethv_gpi_iface/device" ] || continue
        printf '%s\n' "$ethv_gpi_iface"
    done
}

# ethv_qps615_collect_runtime <result-dir> [pci-devices-root]
#   Collect and validate the runtime QPS615/TC956x PCIe Ethernet topology.
#   QPS615 applicability comes from the enumerated Toshiba 1179:0623 switch,
#   not from an installed package or module alone. Exported QPS615_* values
#   summarize the result for PCIe and Ethernet suite orchestration.
#   return: 0 when applicable and healthy, 1 when declared hardware is broken,
#   2 when QPS615 is not present, and 3 for invalid arguments.
ethv_qps615_collect_runtime() {
    ethv_qcr_result_dir="${1:-}"
    ethv_qcr_pci_root="${2:-/sys/bus/pci/devices}"
    ethv_qcr_inventory="$ethv_qcr_result_dir/qps615_runtime.tsv"
    ethv_qcr_switches="$ethv_qcr_result_dir/qps615_switches.log"

    [ -n "$ethv_qcr_result_dir" ] || return 3
    mkdir -p "$ethv_qcr_result_dir" || return 1
    : >"$ethv_qcr_inventory" || return 1
    : >"$ethv_qcr_switches" || return 1

    QPS615_SWITCH_COUNT=0
    QPS615_DOWNSTREAM_COUNT=0
    QPS615_ETHERNET_DEVICE_COUNT=0
    QPS615_ETHERNET_DECLARED_COUNT=0
    QPS615_DRIVER_DEVICE_COUNT=0
    QPS615_DECLARED_DRIVER_DEVICE_COUNT=0
    QPS615_UNBOUND_ETHERNET_COUNT=0
    QPS615_NETDEV_COUNT=0
    QPS615_DECLARED_NETDEV_COUNT=0
    QPS615_ETHERNET_OF_NODE_COUNT=0
    QPS615_ETHERNET_OVERRIDE_COUNT=0
    QPS615_FIRMWARE_PATH=""
    QPS615_MODULE_PATH=""
    QPS615_MODULE_STATE="absent"
    QPS615_MODULE_PORT_BDFS=""
    QPS615_MODULE_PORT_CONFIG="unavailable"
    QPS615_PCI_DRIVER_PATH=""
    QPS615_PCI_DRIVER_STATE="absent"
    QPS615_PCI_AUTOPROBE="unknown"
    QPS615_TOPOLOGY_FAILURE_REASON=""
    QPS615_ETHERNET_FAILURE_REASON=""
    QPS615_ETHERNET_SKIP_REASON=""
    QPS615_FAILURE_REASON=""

    log_info "QPS615 validation: scanning PCI devices under $ethv_qcr_pci_root for switch 1179:0623"

    if [ ! -d "$ethv_qcr_pci_root" ]; then
        log_info "QPS615 validation is not applicable because the PCI sysfs inventory is not exposed"
        export QPS615_SWITCH_COUNT QPS615_DOWNSTREAM_COUNT QPS615_ETHERNET_DEVICE_COUNT
        export QPS615_ETHERNET_DECLARED_COUNT QPS615_DRIVER_DEVICE_COUNT
        export QPS615_DECLARED_DRIVER_DEVICE_COUNT QPS615_UNBOUND_ETHERNET_COUNT QPS615_NETDEV_COUNT
        export QPS615_DECLARED_NETDEV_COUNT
        export QPS615_ETHERNET_OF_NODE_COUNT QPS615_ETHERNET_OVERRIDE_COUNT
        export QPS615_FIRMWARE_PATH QPS615_MODULE_PATH QPS615_MODULE_STATE
        export QPS615_MODULE_PORT_BDFS QPS615_MODULE_PORT_CONFIG
        export QPS615_PCI_DRIVER_PATH QPS615_PCI_DRIVER_STATE
        export QPS615_PCI_AUTOPROBE
        export QPS615_TOPOLOGY_FAILURE_REASON QPS615_ETHERNET_FAILURE_REASON
        export QPS615_ETHERNET_SKIP_REASON QPS615_FAILURE_REASON
        return 2
    fi

    for ethv_qcr_device in "$ethv_qcr_pci_root"/*; do
        [ -d "$ethv_qcr_device" ] || continue
        ethv_qcr_vendor="$(ethv_read_first_line "$ethv_qcr_device/vendor" 2>/dev/null || true)"
        ethv_qcr_id="$(ethv_read_first_line "$ethv_qcr_device/device" 2>/dev/null || true)"

        if [ "$ethv_qcr_vendor" = "0x1179" ] && \
           [ "$ethv_qcr_id" = "0x0623" ]; then
            ethv_qcr_resolved="$(readlink -f "$ethv_qcr_device" 2>/dev/null || true)"
            QPS615_SWITCH_COUNT=$((QPS615_SWITCH_COUNT + 1))
            if [ -n "$ethv_qcr_resolved" ]; then
                printf '%s\n' "$ethv_qcr_resolved" >>"$ethv_qcr_switches"
            fi
            printf 'switch\t%s\t%s\t%s\t%s\n' \
                "${ethv_qcr_device##*/}" \
                "$ethv_qcr_vendor" \
                "$ethv_qcr_id" \
                "${ethv_qcr_resolved:-unresolved}" >>"$ethv_qcr_inventory"
            log_info "[QPS615] switch=${ethv_qcr_device##*/} vendor=$ethv_qcr_vendor device=$ethv_qcr_id path=${ethv_qcr_resolved:-unresolved}"
        fi
    done

    if [ "$QPS615_SWITCH_COUNT" -eq 0 ]; then
        log_info "QPS615 validation is not applicable because switch 1179:0623 was not enumerated"
        export QPS615_SWITCH_COUNT QPS615_DOWNSTREAM_COUNT QPS615_ETHERNET_DEVICE_COUNT
        export QPS615_ETHERNET_DECLARED_COUNT QPS615_DRIVER_DEVICE_COUNT
        export QPS615_DECLARED_DRIVER_DEVICE_COUNT QPS615_UNBOUND_ETHERNET_COUNT QPS615_NETDEV_COUNT
        export QPS615_DECLARED_NETDEV_COUNT
        export QPS615_ETHERNET_OF_NODE_COUNT QPS615_ETHERNET_OVERRIDE_COUNT
        export QPS615_FIRMWARE_PATH QPS615_MODULE_PATH QPS615_MODULE_STATE
        export QPS615_MODULE_PORT_BDFS QPS615_MODULE_PORT_CONFIG
        export QPS615_PCI_DRIVER_PATH QPS615_PCI_DRIVER_STATE
        export QPS615_PCI_AUTOPROBE
        export QPS615_TOPOLOGY_FAILURE_REASON QPS615_ETHERNET_FAILURE_REASON
        export QPS615_ETHERNET_SKIP_REASON QPS615_FAILURE_REASON
        return 2
    fi

    for ethv_qcr_device in "$ethv_qcr_pci_root"/*; do
        [ -d "$ethv_qcr_device" ] || continue
        ethv_qcr_resolved="$(readlink -f "$ethv_qcr_device" 2>/dev/null || true)"
        ethv_qcr_is_downstream=0

        while IFS= read -r ethv_qcr_switch_path; do
            [ -n "$ethv_qcr_switch_path" ] || continue
            case "$ethv_qcr_resolved" in
                "$ethv_qcr_switch_path"/*)
                    ethv_qcr_is_downstream=1
                    break
                    ;;
            esac
        done <"$ethv_qcr_switches"

        [ "$ethv_qcr_is_downstream" -eq 1 ] || continue
        QPS615_DOWNSTREAM_COUNT=$((QPS615_DOWNSTREAM_COUNT + 1))

        ethv_qcr_driver=""
        if [ -L "$ethv_qcr_device/driver" ]; then
            ethv_qcr_driver="$(basename "$(readlink -f "$ethv_qcr_device/driver" 2>/dev/null)" 2>/dev/null || true)"
        fi
        ethv_qcr_vendor="$(ethv_read_first_line "$ethv_qcr_device/vendor" 2>/dev/null || true)"
        ethv_qcr_id="$(ethv_read_first_line "$ethv_qcr_device/device" 2>/dev/null || true)"
        printf 'downstream\t%s\t%s\t%s\t%s\t%s\n' \
            "${ethv_qcr_device##*/}" \
            "${ethv_qcr_vendor:-unknown}" \
            "${ethv_qcr_id:-unknown}" \
            "${ethv_qcr_driver:-unbound}" \
            "${ethv_qcr_resolved:-unknown}" >>"$ethv_qcr_inventory"
        log_info "[QPS615] downstream=${ethv_qcr_device##*/} vendor=${ethv_qcr_vendor:-unknown} device=${ethv_qcr_id:-unknown} driver=${ethv_qcr_driver:-unbound}"

        if [ "$ethv_qcr_vendor" = "0x1179" ] && \
           [ "$ethv_qcr_id" = "0x0220" ]; then
            QPS615_ETHERNET_DEVICE_COUNT=$((QPS615_ETHERNET_DEVICE_COUNT + 1))
            ethv_qcr_modalias="$(ethv_read_first_line "$ethv_qcr_device/modalias" 2>/dev/null || true)"
            ethv_qcr_driver_override="$(ethv_read_first_line "$ethv_qcr_device/driver_override" 2>/dev/null || true)"
            ethv_qcr_of_node="$(readlink -f "$ethv_qcr_device/of_node" 2>/dev/null || true)"
            ethv_qcr_runtime_status="$(ethv_read_first_line "$ethv_qcr_device/power/runtime_status" 2>/dev/null || true)"
            ethv_qcr_port_declaration="absent"
            case "$ethv_qcr_driver_override" in
                ''|'(null)')
                    ethv_qcr_driver_override="none"
                    ;;
                *)
                    QPS615_ETHERNET_OVERRIDE_COUNT=$((QPS615_ETHERNET_OVERRIDE_COUNT + 1))
                    ;;
            esac
            if [ -n "$ethv_qcr_of_node" ]; then
                QPS615_ETHERNET_OF_NODE_COUNT=$((QPS615_ETHERNET_OF_NODE_COUNT + 1))
                if [ -e "$ethv_qcr_of_node/phy-reset-gpios" ] || \
                   [ -e "$ethv_qcr_of_node/qcom,phy-rst-gpio" ]; then
                    ethv_qcr_port_declaration="declared"
                    QPS615_ETHERNET_DECLARED_COUNT=$((QPS615_ETHERNET_DECLARED_COUNT + 1))
                fi
            fi
            printf 'ethernet-function\t%s\tdriver=%s\tmodalias=%s\tdriver_override=%s\tof_node=%s\tport_configuration=%s\truntime_status=%s\n' \
                "${ethv_qcr_device##*/}" \
                "${ethv_qcr_driver:-unbound}" \
                "${ethv_qcr_modalias:-unavailable}" \
                "$ethv_qcr_driver_override" \
                "${ethv_qcr_of_node:-unavailable}" \
                "$ethv_qcr_port_declaration" \
                "${ethv_qcr_runtime_status:-unknown}" >>"$ethv_qcr_inventory"
            log_info "[QPS615-ETH] function=${ethv_qcr_device##*/} driver=${ethv_qcr_driver:-unbound} port_configuration=$ethv_qcr_port_declaration driver_override=$ethv_qcr_driver_override of_node=${ethv_qcr_of_node:-unavailable} runtime_status=${ethv_qcr_runtime_status:-unknown} modalias=${ethv_qcr_modalias:-unavailable}"

            case "$ethv_qcr_driver" in
                tc956x*)
                QPS615_DRIVER_DEVICE_COUNT=$((QPS615_DRIVER_DEVICE_COUNT + 1))
                if [ "$ethv_qcr_port_declaration" = "declared" ]; then
                    QPS615_DECLARED_DRIVER_DEVICE_COUNT=$((QPS615_DECLARED_DRIVER_DEVICE_COUNT + 1))
                fi
                for ethv_qcr_netdev in "$ethv_qcr_device"/net/*; do
                    [ -d "$ethv_qcr_netdev" ] || continue
                    QPS615_NETDEV_COUNT=$((QPS615_NETDEV_COUNT + 1))
                    if [ "$ethv_qcr_port_declaration" = "declared" ]; then
                        QPS615_DECLARED_NETDEV_COUNT=$((QPS615_DECLARED_NETDEV_COUNT + 1))
                    fi
                    printf 'netdev\t%s\t%s\n' \
                        "${ethv_qcr_device##*/}" \
                        "${ethv_qcr_netdev##*/}" >>"$ethv_qcr_inventory"
                    log_info "[QPS615] ethernet_function=${ethv_qcr_device##*/} netdev=${ethv_qcr_netdev##*/}"
                done
                    ;;
                "")
                    QPS615_UNBOUND_ETHERNET_COUNT=$((QPS615_UNBOUND_ETHERNET_COUNT + 1))
                    ;;
                *)
                    QPS615_UNBOUND_ETHERNET_COUNT=$((QPS615_UNBOUND_ETHERNET_COUNT + 1))
                    log_warn "[QPS615-ETH] function=${ethv_qcr_device##*/} is bound to unexpected driver=$ethv_qcr_driver"
                    ;;
            esac
        fi
    done

    QPS615_FIRMWARE_PATH="$(find_image_firmware TC956X_Firmware_PCIeBridge.bin 2>/dev/null || true)"
    if [ -n "$QPS615_FIRMWARE_PATH" ]; then
        log_info "[QPS615] firmware=$QPS615_FIRMWARE_PATH"
    else
        log_warn "[QPS615] firmware TC956X_Firmware_PCIeBridge.bin was not found"
    fi

    ethv_qcr_module_candidate="$(find_kernel_module tc956x_pcie_eth 2>/dev/null | awk '/^\// { print; exit }' || true)"
    ethv_qcr_running_kernel="$(uname -r 2>/dev/null || true)"
    case "$ethv_qcr_module_candidate" in
        "/lib/modules/$ethv_qcr_running_kernel/"*)
            QPS615_MODULE_PATH="$ethv_qcr_module_candidate"
            QPS615_MODULE_STATE="available"
            ;;
        "")
            ;;
        *)
            log_warn "[QPS615-ETH] tc956x_pcie_eth exists only outside the running-kernel module tree: $ethv_qcr_module_candidate"
            ;;
    esac

    if [ -d /sys/module/tc956x_pcie_eth ]; then
        QPS615_MODULE_STATE="loaded-or-built-in"
    fi

    if [ -r /sys/module/tc956x_pcie_eth/parameters/tc956x_eth_ports_bdf ]; then
        QPS615_MODULE_PORT_BDFS="$(
            ethv_read_first_line \
                /sys/module/tc956x_pcie_eth/parameters/tc956x_eth_ports_bdf \
                2>/dev/null || true
        )"
        ethv_qcr_nonzero_bdfs="$(
            printf '%s' "$QPS615_MODULE_PORT_BDFS" |
                tr -d '0,[:space:]'
        )"
        if [ -n "$QPS615_MODULE_PORT_BDFS" ] && \
           [ -z "$ethv_qcr_nonzero_bdfs" ]; then
            QPS615_MODULE_PORT_CONFIG="driver-defaults"
        elif [ -n "$QPS615_MODULE_PORT_BDFS" ]; then
            QPS615_MODULE_PORT_CONFIG="configured"
        fi
        printf 'module-configuration\ttc956x_eth_ports_bdf=%s\tstate=%s\n' \
            "${QPS615_MODULE_PORT_BDFS:-unreadable}" \
            "$QPS615_MODULE_PORT_CONFIG" >>"$ethv_qcr_inventory"
        log_info "[QPS615-ETH] module_parameter=tc956x_eth_ports_bdf value=${QPS615_MODULE_PORT_BDFS:-unreadable} state=$QPS615_MODULE_PORT_CONFIG"
    fi

    if [ -d /sys/bus/pci/drivers/tc956x_pci-eth ]; then
        QPS615_PCI_DRIVER_PATH="/sys/bus/pci/drivers/tc956x_pci-eth"
        QPS615_PCI_DRIVER_STATE="registered"
        log_info "[QPS615-ETH] pci_driver=tc956x_pci-eth state=registered path=$QPS615_PCI_DRIVER_PATH"
    elif [ "$QPS615_MODULE_STATE" = "loaded-or-built-in" ]; then
        log_warn "[QPS615-ETH] module is loaded but PCI driver tc956x_pci-eth is not registered"
    fi
    printf 'pci-driver\tname=tc956x_pci-eth\tstate=%s\tpath=%s\n' \
        "$QPS615_PCI_DRIVER_STATE" \
        "${QPS615_PCI_DRIVER_PATH:-unavailable}" >>"$ethv_qcr_inventory"

    QPS615_PCI_AUTOPROBE="$(
        ethv_read_first_line /sys/bus/pci/drivers_autoprobe 2>/dev/null || true
    )"
    [ -n "$QPS615_PCI_AUTOPROBE" ] || QPS615_PCI_AUTOPROBE="unknown"
    printf 'pci-autoprobe\tstate=%s\n' \
        "$QPS615_PCI_AUTOPROBE" >>"$ethv_qcr_inventory"
    log_info "[QPS615-ETH] pci_drivers_autoprobe=$QPS615_PCI_AUTOPROBE"

    if [ -n "$QPS615_MODULE_PATH" ]; then
        log_info "[QPS615-ETH] module=tc956x_pcie_eth state=$QPS615_MODULE_STATE path=$QPS615_MODULE_PATH"
    elif [ "$QPS615_MODULE_STATE" = "loaded-or-built-in" ]; then
        log_info "[QPS615-ETH] module=tc956x_pcie_eth state=$QPS615_MODULE_STATE path=built-in-or-unexposed"
    else
        log_warn "[QPS615-ETH] module=tc956x_pcie_eth was not found for the running kernel"
    fi

    log_info "[QPS615] summary bridge_functions=$QPS615_SWITCH_COUNT downstream=$QPS615_DOWNSTREAM_COUNT ethernet_devices=$QPS615_ETHERNET_DEVICE_COUNT declared_ethernet_ports=$QPS615_ETHERNET_DECLARED_COUNT bound_ethernet_devices=$QPS615_DRIVER_DEVICE_COUNT bound_declared_ports=$QPS615_DECLARED_DRIVER_DEVICE_COUNT unbound_ethernet_devices=$QPS615_UNBOUND_ETHERNET_COUNT of_nodes=$QPS615_ETHERNET_OF_NODE_COUNT driver_overrides=$QPS615_ETHERNET_OVERRIDE_COUNT netdevs=$QPS615_NETDEV_COUNT declared_port_netdevs=$QPS615_DECLARED_NETDEV_COUNT artifact=$ethv_qcr_inventory"

    if [ "$QPS615_DOWNSTREAM_COUNT" -eq 0 ]; then
        QPS615_TOPOLOGY_FAILURE_REASON="QPS615 bridge is enumerated but exposes no downstream PCIe functions"
    elif [ -z "$QPS615_FIRMWARE_PATH" ]; then
        QPS615_TOPOLOGY_FAILURE_REASON="required TC956X_Firmware_PCIeBridge.bin is not readable in a standard firmware root"
    fi

    if [ "$QPS615_ETHERNET_DEVICE_COUNT" -eq 0 ]; then
        QPS615_ETHERNET_SKIP_REASON="QPS615 is enumerated but exposes no Toshiba 1179:0220 Ethernet functions"
    elif [ "$QPS615_ETHERNET_DECLARED_COUNT" -eq 0 ] && \
         [ "$QPS615_DRIVER_DEVICE_COUNT" -eq 0 ]; then
        QPS615_ETHERNET_SKIP_REASON="$QPS615_ETHERNET_DEVICE_COUNT embedded Ethernet function(s) are enumerated, but no runtime DT port configuration declares them for Ethernet use"
    elif [ "$QPS615_DECLARED_DRIVER_DEVICE_COUNT" -lt "$QPS615_ETHERNET_DECLARED_COUNT" ]; then
        if [ "$QPS615_PCI_AUTOPROBE" = "0" ]; then
            QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not ready because PCI driver autoprobe is disabled"
        elif [ "$QPS615_ETHERNET_OVERRIDE_COUNT" -gt 0 ]; then
            QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not ready and $QPS615_ETHERNET_OVERRIDE_COUNT function(s) have a driver override"
        elif [ "$QPS615_MODULE_STATE" = "loaded-or-built-in" ]; then
            if [ "$QPS615_PCI_DRIVER_STATE" != "registered" ]; then
                QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not bound, tc956x_pcie_eth is loaded but PCI driver tc956x_pci-eth is not registered"
            else
                QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) did not bind after automatic matching, PCI driver tc956x_pci-eth is registered and endpoint probe did not complete"
            fi
        elif [ -n "$QPS615_MODULE_PATH" ]; then
            QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not bound although module $QPS615_MODULE_PATH is available"
        else
            QPS615_ETHERNET_FAILURE_REASON="$QPS615_ETHERNET_DECLARED_COUNT declared QPS615 Ethernet port(s) are not bound and tc956x_pcie_eth is not available for the running kernel"
        fi
    elif [ "$QPS615_DECLARED_NETDEV_COUNT" -lt "$QPS615_DECLARED_DRIVER_DEVICE_COUNT" ]; then
        QPS615_ETHERNET_FAILURE_REASON="$QPS615_DECLARED_DRIVER_DEVICE_COUNT declared TC956x Ethernet port(s) are bound but only $QPS615_DECLARED_NETDEV_COUNT netdev(s) are exposed"
    elif [ "$QPS615_ETHERNET_DECLARED_COUNT" -eq 0 ] && \
         [ "$QPS615_NETDEV_COUNT" -lt "$QPS615_DRIVER_DEVICE_COUNT" ]; then
        QPS615_ETHERNET_FAILURE_REASON="$QPS615_DRIVER_DEVICE_COUNT TC956x Ethernet function(s) are bound without an explicit runtime DT port declaration, but only $QPS615_NETDEV_COUNT netdev(s) are exposed"
    fi

    if [ -n "$QPS615_TOPOLOGY_FAILURE_REASON" ]; then
        QPS615_FAILURE_REASON="$QPS615_TOPOLOGY_FAILURE_REASON"
    else
        QPS615_FAILURE_REASON="$QPS615_ETHERNET_FAILURE_REASON"
    fi

    export QPS615_SWITCH_COUNT QPS615_DOWNSTREAM_COUNT QPS615_ETHERNET_DEVICE_COUNT
    export QPS615_ETHERNET_DECLARED_COUNT QPS615_DRIVER_DEVICE_COUNT
    export QPS615_DECLARED_DRIVER_DEVICE_COUNT QPS615_UNBOUND_ETHERNET_COUNT QPS615_NETDEV_COUNT
    export QPS615_DECLARED_NETDEV_COUNT
    export QPS615_ETHERNET_OF_NODE_COUNT QPS615_ETHERNET_OVERRIDE_COUNT
    export QPS615_FIRMWARE_PATH QPS615_MODULE_PATH QPS615_MODULE_STATE
    export QPS615_MODULE_PORT_BDFS QPS615_MODULE_PORT_CONFIG
    export QPS615_PCI_DRIVER_PATH QPS615_PCI_DRIVER_STATE
    export QPS615_PCI_AUTOPROBE
    export QPS615_TOPOLOGY_FAILURE_REASON QPS615_ETHERNET_FAILURE_REASON
    export QPS615_ETHERNET_SKIP_REASON QPS615_FAILURE_REASON

    [ -z "$QPS615_FAILURE_REASON" ]
}

# ethv_get_driver <interface>
#   Query the bound network driver through ethtool or the sysfs driver link.
#   stdout: driver name, or an empty line when unavailable.
#   return: 0 after printing the best-effort result.
ethv_get_driver() {
    ethv_gd_iface="${1:-}"
    ethv_gd_driver=""

    if command -v ethtool >/dev/null 2>&1; then
        ethv_gd_driver="$(
            ethtool -i "$ethv_gd_iface" 2>/dev/null \
                | sed -n 's/^driver:[[:space:]]*//p' \
                | head -n 1
        )"
    fi

    if [ -z "$ethv_gd_driver" ] && \
       [ -L "/sys/class/net/$ethv_gd_iface/device/driver" ]; then
        ethv_gd_driver="$(
            readlink "/sys/class/net/$ethv_gd_iface/device/driver" 2>/dev/null \
                | sed 's#/$##; s#.*/##'
        )"
    fi

    printf '%s\n' "$ethv_gd_driver"
}

# ethv_get_driver_module <interface>
#   Resolve the kernel module backing the interface driver through sysfs.
#   stdout: module name, or an empty line when no module link is exposed.
#   return: 0 after printing the best-effort result.
ethv_get_driver_module() {
    ethv_gdm_iface="${1:-}"
    ethv_gdm_module=""

    if [ -L "/sys/class/net/$ethv_gdm_iface/device/driver/module" ]; then
        ethv_gdm_module="$(
            readlink "/sys/class/net/$ethv_gdm_iface/device/driver/module" 2>/dev/null \
                | sed 's#/$##; s#.*/##'
        )"
    fi

    printf '%s\n' "$ethv_gdm_module"
}

# ethv_get_bus_info <interface>
#   Read the ethtool bus-info field for an interface.
#   stdout: bus identifier when ethtool reports one, otherwise no output.
#   return: 0 for best-effort discovery.
ethv_get_bus_info() {
    ethv_gbi_iface="${1:-}"

    if command -v ethtool >/dev/null 2>&1; then
        ethtool -i "$ethv_gbi_iface" 2>/dev/null \
            | sed -n 's/^bus-info:[[:space:]]*//p' \
            | head -n 1
    fi
}

# ethv_get_firmware_version <interface>
#   Read the driver firmware-version field reported by ethtool.
#   stdout: firmware version when available, otherwise no output.
#   return: 0 for best-effort discovery.
ethv_get_firmware_version() {
    ethv_gfv_iface="${1:-}"

    if command -v ethtool >/dev/null 2>&1; then
        ethtool -i "$ethv_gfv_iface" 2>/dev/null \
            | sed -n 's/^firmware-version:[[:space:]]*//p' \
            | head -n 1
    fi
}

# ethv_get_device_path <interface>
#   Resolve the canonical sysfs device path for an interface.
#   stdout: absolute device path when resolvable, otherwise no output.
#   return: 0 for best-effort discovery.
ethv_get_device_path() {
    ethv_gdp_iface="${1:-}"

    if command -v readlink >/dev/null 2>&1; then
        readlink -f "/sys/class/net/$ethv_gdp_iface/device" 2>/dev/null || true
    fi
}

# ethv_get_of_compatible <interface>
#   Read and comma-join NUL-separated device-tree compatible strings.
#   stdout: compatible strings when the interface exposes an OF node.
#   return: 0 for best-effort discovery.
ethv_get_of_compatible() {
    ethv_goc_iface="${1:-}"
    ethv_goc_node="/sys/class/net/$ethv_goc_iface/device/of_node"

    if [ -r "$ethv_goc_node/compatible" ]; then
        tr '\000' ',' <"$ethv_goc_node/compatible" 2>/dev/null \
            | sed 's/,$//'
    fi
}

# ethv_get_phy_id <interface>
#   Read the PHY identifier exported through the interface phydev link.
#   stdout: PHY identifier when exposed, otherwise no output.
#   return: 0 for best-effort discovery, or the file-reader status.
ethv_get_phy_id() {
    ethv_gpi_iface="${1:-}"

    if [ -r "/sys/class/net/$ethv_gpi_iface/phydev/phy_id" ]; then
        ethv_read_first_line "/sys/class/net/$ethv_gpi_iface/phydev/phy_id"
    fi
}

# ethv_get_ipv4 <interface>
#   Return the first global IPv4 address assigned to an interface.
#   stdout: address without CIDR prefix, or no output when none is assigned.
#   return: 0 for best-effort discovery.
ethv_get_ipv4() {
    ethv_gip_iface="${1:-}"

    if command -v get_ip_address >/dev/null 2>&1; then
        get_ip_address "$ethv_gip_iface" 2>/dev/null || true
        return 0
    fi

    ip -4 -o addr show dev "$ethv_gip_iface" scope global 2>/dev/null \
        | awk 'NR == 1 { split($4, a, "/"); print a[1] }'
}

# ethv_valid_ipv4 <address>
#   Validate an IPv4 address and reject unspecified and link-local addresses.
#   stdout: none.
#   return: 0 for a usable IPv4 address, nonzero otherwise.
ethv_valid_ipv4() {
    ethv_vi_addr="${1:-}"

    if command -v is_valid_ipv4 >/dev/null 2>&1; then
        is_valid_ipv4 "$ethv_vi_addr"
        return $?
    fi

    case "$ethv_vi_addr" in
        ""|0.0.0.0|169.254.*)
            return 1
            ;;
    esac

    printf '%s\n' "$ethv_vi_addr" |
    awk -F. '
        NF != 4 {
            exit 1
        }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {
                    exit 1
                }
            }
        }
    '
}

# ethv_get_carrier <interface>
#   Read the kernel carrier state for an interface.
#   stdout: 1, 0, or unknown when the attribute cannot be read.
#   return: 0 after printing a value.
ethv_get_carrier() {
    ethv_gc_iface="${1:-}"

    ethv_read_first_line "/sys/class/net/$ethv_gc_iface/carrier" 2>/dev/null \
        || printf '%s\n' "unknown"
}

# ethv_get_operstate <interface>
#   Read the kernel operational state for an interface.
#   stdout: sysfs operstate value, or unknown when unavailable.
#   return: 0 after printing a value.
ethv_get_operstate() {
    ethv_go_iface="${1:-}"

    ethv_read_first_line "/sys/class/net/$ethv_go_iface/operstate" 2>/dev/null \
        || printf '%s\n' "unknown"
}

# ethv_get_speed <interface>
#   Read negotiated speed from sysfs, falling back to ethtool.
#   stdout: integer speed in Mbit/s, or an empty line when unavailable.
#   return: 0 after printing the best-effort result.
ethv_get_speed() {
    ethv_gs_iface="${1:-}"
    ethv_gs_speed=""

    if [ -r "/sys/class/net/$ethv_gs_iface/speed" ]; then
        ethv_gs_speed="$(ethv_read_first_line "/sys/class/net/$ethv_gs_iface/speed" 2>/dev/null || true)"
    fi

    if ! ethv_is_uint "$ethv_gs_speed"; then
        ethv_gs_speed="$(
            ethtool "$ethv_gs_iface" 2>/dev/null \
                | sed -n 's/^[[:space:]]*Speed:[[:space:]]*\([0-9][0-9]*\)Mb\/s.*/\1/p' \
                | head -n 1
        )"
    fi

    printf '%s\n' "$ethv_gs_speed"
}

# ethv_get_duplex <interface>
#   Read negotiated duplex from sysfs, falling back to ethtool.
#   stdout: duplex value, or an empty line when unavailable.
#   return: 0 after printing the best-effort result.
ethv_get_duplex() {
    ethv_gdpx_iface="${1:-}"
    ethv_gdpx_duplex=""

    if [ -r "/sys/class/net/$ethv_gdpx_iface/duplex" ]; then
        ethv_gdpx_duplex="$(ethv_read_first_line "/sys/class/net/$ethv_gdpx_iface/duplex" 2>/dev/null || true)"
    fi

    if [ -z "$ethv_gdpx_duplex" ]; then
        ethv_gdpx_duplex="$(
            ethtool "$ethv_gdpx_iface" 2>/dev/null \
                | sed -n 's/^[[:space:]]*Duplex:[[:space:]]*//p' \
                | head -n 1
        )"
    fi

    printf '%s\n' "$ethv_gdpx_duplex"
}

# ethv_get_link_detected <interface>
#   Query ethtool's Link detected field.
#   stdout: normally yes or no, or no output when unsupported.
#   return: status of the ethtool and filtering pipeline.
ethv_get_link_detected() {
    ethv_gld_iface="${1:-}"

    ethtool "$ethv_gld_iface" 2>/dev/null \
        | sed -n 's/^[[:space:]]*Link detected:[[:space:]]*//p' \
        | head -n 1
}

# ethv_network_manager_active
#   Detect an active NetworkManager or systemd-networkd service.
#   stdout: none.
#   return: 0 when either manager is active, 1 otherwise.
ethv_network_manager_active() {
    command -v systemctl >/dev/null 2>&1 || return 1

    systemctl is-active --quiet NetworkManager 2>/dev/null \
        || systemctl is-active --quiet systemd-networkd 2>/dev/null
}

# ethv_wait_for_carrier <interface> [timeout-seconds]
#   Poll sysfs and optional ethtool link state until carrier is detected.
#   stdout: none.
#   return: 0 when carrier appears before timeout, 1 otherwise.
ethv_wait_for_carrier() {
    ethv_wfc_iface="${1:-}"
    ethv_wfc_timeout="${2:-10}"
    ethv_wfc_waited=0

    ethv_is_uint "$ethv_wfc_timeout" || ethv_wfc_timeout=10

    while [ "$ethv_wfc_waited" -le "$ethv_wfc_timeout" ]; do
        if [ "$(ethv_get_carrier "$ethv_wfc_iface")" = "1" ]; then
            return 0
        fi

        if command -v ethtool >/dev/null 2>&1 && \
           [ "$(ethv_get_link_detected "$ethv_wfc_iface")" = "yes" ]; then
            return 0
        fi

        [ "$ethv_wfc_waited" -lt "$ethv_wfc_timeout" ] || break
        sleep 1
        ethv_wfc_waited=$((ethv_wfc_waited + 1))
    done

    return 1
}

# ethv_wait_for_ipv4 <interface> [timeout-seconds]
#   Wait for a usable global IPv4 address using shared helpers and polling.
#   stdout: the first valid IPv4 address when found.
#   return: 0 when an address is found before timeout, 1 otherwise.
ethv_wait_for_ipv4() {
    ethv_wfi_iface="${1:-}"
    ethv_wfi_timeout="${2:-10}"
    ethv_wfi_waited=0

    ethv_is_uint "$ethv_wfi_timeout" || ethv_wfi_timeout=10

    if command -v wait_for_ip_address >/dev/null 2>&1; then
        ethv_wfi_ip="$(wait_for_ip_address "$ethv_wfi_iface" "$ethv_wfi_timeout" 2>/dev/null || true)"
        if ethv_valid_ipv4 "$ethv_wfi_ip"; then
            printf '%s\n' "$ethv_wfi_ip"
            return 0
        fi
    fi

    while [ "$ethv_wfi_waited" -le "$ethv_wfi_timeout" ]; do
        ethv_wfi_ip="$(ethv_get_ipv4 "$ethv_wfi_iface")"

        if ethv_valid_ipv4 "$ethv_wfi_ip"; then
            printf '%s\n' "$ethv_wfi_ip"
            return 0
        fi

        [ "$ethv_wfi_waited" -lt "$ethv_wfi_timeout" ] || break
        sleep 1
        ethv_wfi_waited=$((ethv_wfi_waited + 1))
    done

    return 1
}

# ethv_prepare_interface <interface> [link-timeout] [ip-timeout]
#   Bring an interface administratively up, recover link when helpers exist,
#   and obtain or wait for a usable IPv4 without fighting active managers.
#   stdout: none.
#   return: 0 when carrier and IPv4 are ready, 1 on interface bring-up failure,
#   2 when carrier is unavailable, or 3 when no valid IPv4 is obtained.
ethv_prepare_interface() {
    ethv_pi_iface="${1:-}"
    ethv_pi_link_timeout="${2:-10}"
    ethv_pi_ip_timeout="${3:-15}"

    [ -d "/sys/class/net/$ethv_pi_iface" ] || return 1

    ip link set dev "$ethv_pi_iface" up >/dev/null 2>&1 || return 1

    if ! ethv_wait_for_carrier "$ethv_pi_iface" 1; then
        if command -v ethEnsureLinkUpWithFallback >/dev/null 2>&1 && \
           command -v ethtool >/dev/null 2>&1; then
            ethEnsureLinkUpWithFallback "$ethv_pi_iface" "$ethv_pi_link_timeout" >/dev/null 2>&1 || true
        fi
    fi

    ethv_wait_for_carrier "$ethv_pi_iface" "$ethv_pi_link_timeout" || return 2

    ethv_pi_ip="$(ethv_get_ipv4 "$ethv_pi_iface")"
    if ethv_valid_ipv4 "$ethv_pi_ip"; then
        return 0
    fi

    if ethv_network_manager_active; then
        ethv_wait_for_ipv4 "$ethv_pi_iface" "$ethv_pi_ip_timeout" >/dev/null 2>&1 || true
    elif command -v try_dhcp_client_safe >/dev/null 2>&1; then
        try_dhcp_client_safe "$ethv_pi_iface" "$ethv_pi_ip_timeout" >/dev/null 2>&1 || true
    fi

    ethv_pi_ip="$(ethv_get_ipv4 "$ethv_pi_iface")"
    ethv_valid_ipv4 "$ethv_pi_ip" || return 3

    return 0
}

# ethv_get_default_gateway <interface>
#   Find the first IPv4 default gateway routed through an interface.
#   stdout: gateway IPv4 address, or no output when no route exists.
#   return: status of the route and awk pipeline.
ethv_get_default_gateway() {
    ethv_gdg_iface="${1:-}"

    ip -4 route show default dev "$ethv_gdg_iface" 2>/dev/null \
        | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }'
}

# ethv_select_ping_target <interface> [requested-target]
#   Select an explicit target, then the interface gateway, then 8.8.8.8.
#   stdout: selected ping target.
#   return: 0 after printing the target.
ethv_select_ping_target() {
    ethv_spt_iface="${1:-}"
    ethv_spt_requested="${2:-}"
    ethv_spt_gateway=""

    if [ -n "$ethv_spt_requested" ]; then
        printf '%s\n' "$ethv_spt_requested"
        return 0
    fi

    ethv_spt_gateway="$(ethv_get_default_gateway "$ethv_spt_iface")"

    if [ -n "$ethv_spt_gateway" ]; then
        printf '%s\n' "$ethv_spt_gateway"
    else
        printf '%s\n' "8.8.8.8"
    fi
}

# ethv_ping_interface <interface> <target> [count] [wait-seconds]
#   Run ping with traffic explicitly bound to the requested interface.
#   stdout/stderr: unmodified ping output.
#   return: ping command exit status.
ethv_ping_interface() {
    ethv_pi_iface="${1:-}"
    ethv_pi_target="${2:-}"
    ethv_pi_count="${3:-4}"
    ethv_pi_wait="${4:-2}"

    ping -I "$ethv_pi_iface" \
        -c "$ethv_pi_count" \
        -W "$ethv_pi_wait" \
        "$ethv_pi_target"
}

# ethv_get_counter <interface> <statistics-counter>
#   Read an unsigned standard network counter from sysfs.
#   stdout: counter value, or 0 when unavailable or malformed.
#   return: 0 after printing a value.
ethv_get_counter() {
    ethv_gc_iface="${1:-}"
    ethv_gc_counter="${2:-}"
    ethv_gc_file="/sys/class/net/$ethv_gc_iface/statistics/$ethv_gc_counter"

    if [ -r "$ethv_gc_file" ]; then
        ethv_gc_value="$(ethv_read_first_line "$ethv_gc_file" 2>/dev/null || true)"
        if ethv_is_uint "$ethv_gc_value"; then
            printf '%s\n' "$ethv_gc_value"
            return 0
        fi
    fi

    printf '%s\n' 0
}

# ethv_counter_delta <before> <after>
#   Calculate a monotonic unsigned counter delta.
#   stdout: after minus before, or -1 for invalid input or counter rollback.
#   return: awk status, normally 0.
ethv_counter_delta() {
    ethv_cd_before="${1:-0}"
    ethv_cd_after="${2:-0}"

    awk -v before="$ethv_cd_before" -v after="$ethv_cd_after" '
        BEGIN {
            if (before !~ /^[0-9]+$/ || after !~ /^[0-9]+$/ || after < before) {
                print -1
            } else {
                print after - before
            }
        }
    '
}

# ethv_get_ptp_clock <interface>
#   Query the PTP hardware clock index advertised by ethtool timestamping data.
#   stdout: clock index, none, -1, or an empty line when unavailable.
#   return: 0 after printing the best-effort result.
ethv_get_ptp_clock() {
    ethv_gpc_iface="${1:-}"
    ethv_gpc_clock=""

    if command -v ethtool >/dev/null 2>&1; then
        ethv_gpc_clock="$(
            ethtool -T "$ethv_gpc_iface" 2>/dev/null \
                | sed -n 's/^[[:space:]]*PTP Hardware Clock:[[:space:]]*//p' \
                | head -n 1
        )"
    fi

    printf '%s\n' "$ethv_gpc_clock"
}

# ethv_command_supports <command> <grep-pattern>
#   Search a command's --help output for a required option or feature pattern.
#   stdout: none.
#   return: 0 when the pattern is present, 1 when inputs or support are absent.
ethv_command_supports() {
    ethv_cs_command="${1:-}"
    ethv_cs_pattern="${2:-}"

    [ -n "$ethv_cs_command" ] || return 1
    [ -n "$ethv_cs_pattern" ] || return 1

    "$ethv_cs_command" --help 2>&1 \
        | grep -q -- "$ethv_cs_pattern"
}

# ethv_parse_iperf_mbps <iperf-log>
#   Parse receiver summary lines, normalize bit-rate units to Mbit/s, and use
#   the minimum aggregate result when SUM lines exist or minimum stream result.
#   stdout: normalized receiver throughput in Mbit/s.
#   return: 0 when a receiver result is parsed, nonzero when none is found.
ethv_parse_iperf_mbps() {
    ethv_pim_file="${1:-}"

    awk '
        function convert_to_mbps(value, unit) {
            if (unit == "bits/sec") {
                return value / 1000000
            }
            if (unit == "Kbits/sec") {
                return value / 1000
            }
            if (unit == "Gbits/sec") {
                return value * 1000
            }
            return value
        }
        $NF == "receiver" {
            value = ""

            for (field = 2; field <= NF; field++) {
                if ($field ~ /^(bits|Kbits|Mbits|Gbits)\/sec$/) {
                    value = convert_to_mbps($(field - 1) + 0, $field)
                    break
                }
            }

            if (value == "") {
                next
            }

            if (index($0, "[SUM]") > 0) {
                if (!sum_found || value < sum_minimum) {
                    sum_minimum = value
                }
                sum_found = 1
            } else {
                if (!stream_found || value < stream_minimum) {
                    stream_minimum = value
                }
                stream_found = 1
            }
        }
        END {
            if (sum_found) {
                print sum_minimum
            } else if (stream_found) {
                print stream_minimum
            } else {
                exit 1
            }
        }
    ' "$ethv_pim_file" 2>/dev/null
}

# ethv_float_ge <left> <right>
#   Compare two validated nonnegative decimal values.
#   stdout: none.
#   return: 0 when left is greater than or equal to right, 1 otherwise or when
#   either operand is malformed.
ethv_float_ge() {
    ethv_fg_left="${1:-0}"
    ethv_fg_right="${2:-0}"

    ethv_is_nonnegative_decimal "$ethv_fg_left" || return 1
    ethv_is_nonnegative_decimal "$ethv_fg_right" || return 1

    awk -v left="$ethv_fg_left" -v right="$ethv_fg_right" '
        BEGIN {
            exit !(left + 0 >= right + 0)
        }
    '
}
