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
. "$TOOLS/lib_ethernet.sh"

TESTNAME="PCIe"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
QPS615_RESULT_DIR="$SCRIPT_DIR/qps615_runtime"
PCIE_RESULT_DIR="$SCRIPT_DIR/pcie_runtime"
PCIE_DMESG_STRICT="${PCIE_DMESG_STRICT:-0}"

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"

case "$PCIE_DMESG_STRICT" in
    0|1)
        ;;
    *)
        log_warn "Invalid PCIE_DMESG_STRICT='$PCIE_DMESG_STRICT', using 0"
        PCIE_DMESG_STRICT=0
        ;;
esac

log_info "Configuration: PCIE_DMESG_STRICT=$PCIE_DMESG_STRICT"

if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies \
    awk \
    basename \
    cat \
    find \
    grep \
    head \
    lspci \
    mkdir \
    readlink \
    rm \
    tr \
    uname; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

if ! lspci_output="$(lspci -vvv 2>&1)"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: lspci inventory command failed"
fi

pcie_dt_association=0
for pcie_of_node in /sys/bus/pci/devices/*/of_node; do
    [ -e "$pcie_of_node" ] || continue
    pcie_dt_association=1
    break
done

if printf '%s\n' "$lspci_output" | grep -q "Device tree node:" ||
   [ "$pcie_dt_association" -eq 1 ]; then
    test_result_record "PASS" "PCIe inventory exposes device-tree node information"
else
    test_result_record "SKIP" "PCIe device-tree association is not exposed by pciutils or sysfs"
fi

if printf '%s\n' "$lspci_output" | grep -q "Capabilities:"; then
    test_result_record "PASS" "PCIe capabilities are exposed"
else
    test_result_record "FAIL" "PCIe capabilities are not exposed"
fi

if printf '%s\n' "$lspci_output" | grep -q "Kernel driver in use:"; then
    test_result_record "PASS" "At least one PCIe device has a bound kernel driver"
else
    test_result_record "FAIL" "No bound PCIe kernel driver was reported"
fi

pcie_collect_runtime_health "$PCIE_RESULT_DIR"
pcie_runtime_status=$?

case "$pcie_runtime_status" in
    0)
        test_result_record \
            "PASS" \
            "PCIe runtime inventory is readable: devices=$PCIE_RUNTIME_DEVICE_COUNT link_records=$PCIE_RUNTIME_LINK_COUNT power_records=$PCIE_RUNTIME_POWER_COUNT"
        if [ "$PCIE_RUNTIME_INACTIVE_PORT_COUNT" -gt 0 ]; then
            test_result_record \
                "SKIP" \
                "$PCIE_RUNTIME_INACTIVE_PORT_COUNT unused PCIe bridge port(s) currently have no negotiated downstream link"
        fi
        if [ "$PCIE_RUNTIME_MSI_DEVICE_COUNT" -gt 0 ]; then
            test_result_record \
                "PASS" \
                "PCIe MSI/MSI-X runtime evidence is present for $PCIE_RUNTIME_MSI_DEVICE_COUNT device(s)"
        else
            test_result_record "SKIP" "No PCIe MSI/MSI-X IRQ directories are exposed"
        fi
        ;;
    1)
        test_result_record \
            "FAIL" \
            "PCIe runtime health validation failed: ${PCIE_RUNTIME_FAILURE_REASON:-malformed sysfs evidence}"
        ;;
    2)
        test_result_record "FAIL" "lspci reports PCI devices but PCI sysfs inventory is empty"
        ;;
    *)
        test_result_record "FAIL" "PCIe runtime health inventory could not complete"
        ;;
esac

ethv_qps615_collect_runtime "$QPS615_RESULT_DIR"
qps615_status=$?

case "$qps615_status" in
    0|1)
        if [ -n "$QPS615_TOPOLOGY_FAILURE_REASON" ]; then
            test_result_record \
                "FAIL" \
                "QPS615 PCIe topology or firmware validation failed: $QPS615_TOPOLOGY_FAILURE_REASON"
        else
            test_result_record \
                "PASS" \
                "QPS615 PCIe topology and firmware are healthy: bridge_functions=$QPS615_SWITCH_COUNT downstream=$QPS615_DOWNSTREAM_COUNT ethernet_devices=$QPS615_ETHERNET_DEVICE_COUNT firmware=$QPS615_FIRMWARE_PATH"
        fi

        if [ -n "$QPS615_ETHERNET_FAILURE_REASON" ]; then
            test_result_record \
                "SKIP" \
                "QPS615 Ethernet readiness is reported by Ethernet_Inventory_Validation: $QPS615_ETHERNET_FAILURE_REASON"
        elif [ -n "$QPS615_ETHERNET_SKIP_REASON" ]; then
            test_result_record \
                "SKIP" \
                "QPS615 Ethernet is not runtime-provisioned: $QPS615_ETHERNET_SKIP_REASON"
        else
            log_info "QPS615 Ethernet evidence: devices=$QPS615_ETHERNET_DEVICE_COUNT declared_ports=$QPS615_ETHERNET_DECLARED_COUNT bound_declared_ports=$QPS615_DECLARED_DRIVER_DEVICE_COUNT declared_port_netdevs=$QPS615_DECLARED_NETDEV_COUNT module_state=$QPS615_MODULE_STATE module_path=${QPS615_MODULE_PATH:-built-in-or-unexposed}"
        fi
        ;;
    2)
        log_info "QPS615 PCIe switch is not present, preserving generic PCIe validation"
        ;;
    3)
        test_result_record \
            "FAIL" \
            "QPS615 topology validation could not complete because its arguments or runtime paths were invalid"
        ;;
    *)
        test_result_record "FAIL" "QPS615 topology validation could not complete"
        ;;
esac

log_info "PCIe kernel-health validation: capturing link-training, controller, and AER errors"
scan_dmesg_errors \
    "$PCIE_RESULT_DIR" \
    'pcieport.*|qcom-pcie.*|pci.*' \
    'AER: Corrected|corrected error|deferred probe|EPROBE_DEFER|using dummy regulator|supply [^ ]+ not found'
pcie_dmesg_status=$?

if [ ! -s "$PCIE_RESULT_DIR/dmesg_snapshot.log" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for PCIe health validation"
elif [ "$pcie_dmesg_status" -eq 0 ] && [ "$PCIE_DMESG_STRICT" -eq 1 ]; then
    test_result_record "FAIL" "PCIe link, controller, or uncorrected AER errors were found in $PCIE_RESULT_DIR/dmesg_errors.log"
elif [ "$pcie_dmesg_status" -eq 0 ]; then
    test_result_record "SKIP" "PCIe kernel errors were retained as advisory evidence, set PCIE_DMESG_STRICT=1 to gate them"
else
    test_result_record "PASS" "No non-benign PCIe controller or AER errors were found in the captured kernel log"
fi

test_result_finish
