#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Non-disruptive Ethernet MAC, PHY, and platform inventory validation.

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

ETHERNET_LIB="$TOOLS/lib_ethernet.sh"

if [ ! -f "$ETHERNET_LIB" ]; then
    log_error "Missing Ethernet helper library: $ETHERNET_LIB"
    exit 1
fi

# shellcheck source=../../../../utils/lib_ethernet.sh
# shellcheck disable=SC1091
. "$ETHERNET_LIB"

TESTNAME="Ethernet_Inventory_Validation"
RES_FILE="./$TESTNAME.res"

test_path="$(find_test_case_by_name "$TESTNAME")"

if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

RESULT_TABLE="./$TESTNAME.results.tsv"
ETH_INTERFACE="${ETH_INTERFACE:-}"

usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --interface IFACE" \
        "  -h, --help" \
        "CLI options override environment variables."
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --interface)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_INTERFACE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '[ERROR] Unknown option: %s\n' "$1" >&2
            usage
            exit 2
            ;;
        esac
    done
}

parse_args "$@"

rm -f "$RES_FILE" "$RESULT_TABLE"
: >"$RESULT_TABLE"

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Configuration: interface=${ETH_INTERFACE:-auto}"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies \
    awk \
    sed \
    grep \
    cat \
    find \
    head \
    readlink \
    uname; then

    log_skip "$TESTNAME SKIP: missing runtime dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform
fi

log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='$(uname -r 2>/dev/null || echo unknown)' arch='$(uname -m 2>/dev/null || echo unknown)'"

QPS615_RESULT_DIR="./qps615_runtime"
ethv_qps615_collect_runtime "$QPS615_RESULT_DIR"
qps615_status=$?

case "$qps615_status" in
    0|1)
        if [ -n "$QPS615_TOPOLOGY_FAILURE_REASON" ]; then
            ethv_record_result \
                "$RESULT_TABLE" \
                "QPS615 PCIe topology and firmware" \
                "FAIL" \
                "$QPS615_TOPOLOGY_FAILURE_REASON"
        else
            ethv_record_result \
                "$RESULT_TABLE" \
                "QPS615 PCIe topology and firmware" \
                "PASS" \
                "bridge_functions=$QPS615_SWITCH_COUNT downstream=$QPS615_DOWNSTREAM_COUNT firmware=$QPS615_FIRMWARE_PATH"
        fi

        if [ -n "$QPS615_ETHERNET_FAILURE_REASON" ]; then
            ethv_record_result \
                "$RESULT_TABLE" \
                "QPS615 Ethernet endpoint readiness" \
                "FAIL" \
                "$QPS615_ETHERNET_FAILURE_REASON"
        elif [ -n "$QPS615_ETHERNET_SKIP_REASON" ]; then
            ethv_record_result \
                "$RESULT_TABLE" \
                "QPS615 Ethernet endpoint readiness" \
                "SKIP" \
                "$QPS615_ETHERNET_SKIP_REASON"
        else
            ethv_record_result \
                "$RESULT_TABLE" \
                "QPS615 Ethernet endpoint readiness" \
                "PASS" \
                "devices=$QPS615_ETHERNET_DEVICE_COUNT declared_ports=$QPS615_ETHERNET_DECLARED_COUNT bound_declared_ports=$QPS615_DECLARED_DRIVER_DEVICE_COUNT declared_port_netdevs=$QPS615_DECLARED_NETDEV_COUNT module_state=$QPS615_MODULE_STATE pci_driver_state=$QPS615_PCI_DRIVER_STATE module_path=${QPS615_MODULE_PATH:-built-in-or-unexposed}"
        fi
        ;;
    2)
        log_info "QPS615 PCIe switch is not present, preserving generic Ethernet inventory validation"
        ;;
    *)
        ethv_record_result \
            "$RESULT_TABLE" \
            "QPS615 runtime collection" \
            "FAIL" \
            "runtime topology collection could not complete"
        ;;
esac

if [ -n "$ETH_INTERFACE" ]; then
    ETH_IFACES="$ETH_INTERFACE"
else
    ETH_IFACES="$(ethv_get_physical_interfaces)"
fi

if [ -z "$ETH_IFACES" ]; then
    case "$qps615_status" in
        0)
            if [ -n "$QPS615_ETHERNET_SKIP_REASON" ]; then
                ethv_record_result \
                    "$RESULT_TABLE" \
                    "Physical Ethernet inventory" \
                    "SKIP" \
                    "no runtime-provisioned Ethernet interface is present"
            else
                ethv_record_result \
                    "$RESULT_TABLE" \
                    "Physical Ethernet inventory" \
                    "FAIL" \
                    "QPS615 reported $QPS615_NETDEV_COUNT netdev(s), but physical Ethernet discovery returned none"
            fi
            ;;
        2)
            ethv_record_result \
                "$RESULT_TABLE" \
                "Physical Ethernet inventory" \
                "SKIP" \
                "no physical Ethernet interfaces are currently enumerated"
            ;;
    esac
else
    log_info "Detected physical Ethernet interfaces: $(printf '%s' "$ETH_IFACES" | tr '\n' ' ')"
fi

for iface in $ETH_IFACES; do
    driver="$(ethv_get_driver "$iface")"
    module="$(ethv_get_driver_module "$iface")"
    device_path="$(ethv_get_device_path "$iface")"
    bus_info="$(ethv_get_bus_info "$iface")"
    firmware="$(ethv_get_firmware_version "$iface")"
    compatible="$(ethv_get_of_compatible "$iface")"
    phy_id="$(ethv_get_phy_id "$iface")"
    carrier="$(ethv_get_carrier "$iface")"
    operstate="$(ethv_get_operstate "$iface")"
    speed="$(ethv_get_speed "$iface")"
    duplex="$(ethv_get_duplex "$iface")"
    mac="$(ethv_read_first_line "/sys/class/net/$iface/address" 2>/dev/null || true)"
    mtu="$(ethv_read_first_line "/sys/class/net/$iface/mtu" 2>/dev/null || true)"
    rx_queues="$(find "/sys/class/net/$iface/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l | awk '{print $1 + 0}')"
    tx_queues="$(find "/sys/class/net/$iface/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l | awk '{print $1 + 0}')"

    log_info "---- Inventory for $iface ----"
    log_info "driver=${driver:-unknown} module=${module:-builtin-or-unknown} device=${device_path:-unknown}"
    log_info "bus=${bus_info:-unknown} firmware=${firmware:-unknown} compatible=${compatible:-not-exposed}"
    log_info "phy_id=${phy_id:-not-exposed} carrier=$carrier operstate=$operstate speed=${speed:-unknown} duplex=${duplex:-unknown}"
    log_info "mac=${mac:-unknown} mtu=${mtu:-unknown} rx_queues=$rx_queues tx_queues=$tx_queues"

    ethv_record_result \
        "$RESULT_TABLE" \
        "$iface enumeration" \
        "PASS" \
        "device=${device_path:-unknown} mac=${mac:-unknown} mtu=${mtu:-unknown}"

    if [ -n "$driver" ]; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface driver binding" \
            "PASS" \
            "driver=$driver module=${module:-built-in} bus=${bus_info:-unknown}"
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface driver binding" \
            "FAIL" \
            "physical interface is present but its bound driver could not be identified"
    fi

    if [ "$rx_queues" -gt 0 ] && [ "$tx_queues" -gt 0 ]; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface queue inventory" \
            "PASS" \
            "rx_queues=$rx_queues tx_queues=$tx_queues"
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface queue inventory" \
            "FAIL" \
            "missing RX or TX queue entries under sysfs"
    fi

    if [ -n "$compatible" ]; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface device-tree identity" \
            "PASS" \
            "compatible=$compatible"
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface device-tree identity" \
            "SKIP" \
            "interface is not represented by an exposed OF compatible property"
    fi

    if [ -n "$phy_id" ]; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface PHY identity" \
            "PASS" \
            "phy_id=$phy_id"
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface PHY identity" \
            "SKIP" \
            "phydev/phy_id is not exposed for this interface"
    fi

    if command -v ethtool >/dev/null 2>&1; then
        log_info "[$iface ethtool -i]"
        ethtool -i "$iface" 2>&1 \
            | while IFS= read -r line; do
                [ -n "$line" ] && log_info "[$iface] $line"
            done
    fi
done

log_info "---- Ethernet-related kernel messages ----"

if command -v get_kernel_log >/dev/null 2>&1; then
    get_kernel_log 2>/dev/null \
        | grep -iE \
            'ethqos|stmmac|dwmac|gmac|emac|tc956|qps615|phylink|mdio|sgmii|hsgmii|2500base|rgmii|qca808|marvell|aquantia|aqr|dp83867|ptp' \
        | tail -n 200 \
        | while IFS= read -r line; do
            [ -n "$line" ] && log_info "[eth-kernel] $line"
        done
fi

OVERALL_RESULT="$(ethv_compute_overall_result "$RESULT_TABLE")"

ethv_print_summary "$RESULT_TABLE" "Ethernet Inventory Summary"

case "$OVERALL_RESULT" in
    PASS)
        log_pass "$TESTNAME PASS"
        echo "$TESTNAME PASS" >"$RES_FILE"
        ;;
    FAIL)
        log_fail "$TESTNAME FAIL"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        ;;
    *)
        log_skip "$TESTNAME SKIP"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        ;;
esac

exit 0
