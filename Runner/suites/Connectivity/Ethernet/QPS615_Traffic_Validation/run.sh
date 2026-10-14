#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Fixture-gated QPS615 Ethernet traffic validation.

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

TESTNAME="QPS615_Traffic_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

QPS615_TRAFFIC_FIXTURE=0
QPS615_INTERFACES=""
QPS615_PEER=""
QPS615_PING_COUNT=10
QPS615_PING_WAIT=2
QPS615_ARGUMENT_ERROR=""
SHOW_HELP=0
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
ethv_failure_diagnostics_init "$RESULT_DIR/failure_diagnostics"
QPS_RUNTIME_DIR="$RESULT_DIR/qps615_runtime"
AVAILABLE_INTERFACES="$RESULT_DIR/qps615_interfaces.log"
SELECTED_INTERFACES="$RESULT_DIR/selected_interfaces.log"
QPS_TRAFFIC_PASS_COUNT=0

# usage
#   Print the command-line contract. stdout: usage text. return: 0.
#   Side effects: none.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --fixture [0|1]   Confirm reachable external Ethernet peers" \
        "  --interfaces LIST Comma-separated QPS615 netdevs, or all" \
        "  --peer IP|HOST    Override interface gateway with IPv4, IPv6 or hostname" \
        "  --ping-count N    Echo requests per interface, default 10, maximum 20" \
        "  --ping-wait N     Per-request wait in seconds, default 2, maximum 5" \
        "  -h, --help" \
        "QPS615 topology and eligible interface names are discovered at runtime." \
        "Automatic gateway and hostname selection prefer IPv4, then IPv6." \
        "Supply IPv6 literals without a %scope, the selected interface provides scope."
}

# parse_args <arguments...>
#   Parse traffic and fixture policy into QPS615_* globals. stdout: none.
#   return: 0 on success or 2 for invalid input. Side effects: updates globals.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fixture)
                if [ "$#" -ge 2 ]; then
                    case "$2" in
                        0|1)
                            QPS615_TRAFFIC_FIXTURE="$2"
                            shift 2
                            continue
                            ;;
                    esac
                fi
                QPS615_TRAFFIC_FIXTURE=1
                shift
                ;;
            --interfaces)
                if ! ethv_require_option_value "$1" "$#"; then
                    QPS615_ARGUMENT_ERROR="--interfaces requires a value"
                    return 2
                fi
                QPS615_INTERFACES="$2"
                shift 2
                ;;
            --peer)
                if ! ethv_require_option_value "$1" "$#"; then
                    QPS615_ARGUMENT_ERROR="--peer requires a value"
                    return 2
                fi
                QPS615_PEER="$2"
                shift 2
                ;;
            --ping-count)
                if ! ethv_require_option_value "$1" "$#"; then
                    QPS615_ARGUMENT_ERROR="--ping-count requires a value"
                    return 2
                fi
                QPS615_PING_COUNT="$2"
                shift 2
                ;;
            --ping-wait)
                if ! ethv_require_option_value "$1" "$#"; then
                    QPS615_ARGUMENT_ERROR="--ping-wait requires a value"
                    return 2
                fi
                QPS615_PING_WAIT="$2"
                shift 2
                ;;
            -h|--help)
                SHOW_HELP=1
                shift
                ;;
            *)
                QPS615_ARGUMENT_ERROR="unknown argument: $1"
                return 2
                ;;
        esac
    done
}

if ! test_result_init "$TESTNAME" "$RES_FILE"; then
    log_error "Could not initialize the result file: $RES_FILE"
    exit 1
fi

if ! parse_args "$@"; then
    usage >&2
    test_result_record \
        "FAIL" \
        "QPS615 traffic command-line configuration is invalid, ${QPS615_ARGUMENT_ERROR:-review ./run.sh --help}"
    ethv_failure_diagnostics "$TESTNAME failure"
    test_result_finish "FAIL"
fi

if [ "$SHOW_HELP" -eq 1 ]; then
    usage
    exit 0
fi

if ! ethv_validate_qps615_traffic_config \
    "$QPS615_TRAFFIC_FIXTURE" \
    "$QPS615_INTERFACES" \
    "$QPS615_PEER" \
    "$QPS615_PING_COUNT" \
    "$QPS615_PING_WAIT"; then
    test_result_record \
        "FAIL" \
        "QPS615 traffic configuration is invalid, reason=${QPS615_CONFIG_ERROR:-invalid-input} fixture=$QPS615_TRAFFIC_FIXTURE interfaces=${QPS615_INTERFACES:-auto} peer=${QPS615_PEER:-auto} ping_count=$QPS615_PING_COUNT ping_wait=$QPS615_PING_WAIT"
    ethv_failure_diagnostics "$TESTNAME failure"
    test_result_finish "FAIL"
fi

if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies \
    awk \
    basename \
    date \
    dirname \
    find \
    grep \
    mkdir \
    readlink \
    sed \
    sort \
    tr \
    uname \
    wc; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: image-provided base utilities required for QPS615 discovery are unavailable"
fi

if ! mkdir -p "$RESULT_DIR"; then
    test_result_record "FAIL" "Could not create QPS615 traffic evidence directory $RESULT_DIR"
    ethv_failure_diagnostics "$TESTNAME failure"
    test_result_finish "FAIL"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "Configuration: fixture=$QPS615_TRAFFIC_FIXTURE interfaces=${QPS615_INTERFACES:-auto-unique} peer=${QPS615_PEER:-auto-gateway} ping_count=$QPS615_PING_COUNT ping_wait=${QPS615_PING_WAIT}s"
log_info "[QPS615-POLICY] topology=dynamic interface_policy=${QPS615_INTERFACES:-auto-unique} peer_policy=${QPS615_PEER:-auto-gateway} fixture_opt_in=$QPS615_TRAFFIC_FIXTURE"

ethv_qps615_collect_runtime "$QPS_RUNTIME_DIR"
qps_runtime_status=$?
log_file_with_label "QPS615-RUNTIME" "$QPS_RUNTIME_DIR/qps615_runtime.tsv" 60

case "$qps_runtime_status" in
    0)
        ;;
    2)
        if [ "$QPS615_TRAFFIC_FIXTURE" -eq 1 ]; then
            test_result_record \
                "FAIL" \
                "QPS615 traffic fixture was selected but no enabled QPS615 DT node or switch 1179:0623 was discovered, verify board support, the active DT and PCIe enumeration on either base or overlay images"
            ethv_failure_diagnostics "$TESTNAME failure"
            test_result_finish "FAIL"
        fi
        test_result_finish \
            "SKIP" \
            "$TESTNAME SKIP: no enabled QPS615 DT node or enumerated switch 1179:0623 was discovered"
        ;;
    *)
        test_result_record \
            "FAIL" \
            "QPS615 traffic prerequisites are not ready: ${QPS615_FAILURE_REASON:-runtime discovery failed}"
        ethv_failure_diagnostics "$TESTNAME failure"
        test_result_finish "FAIL"
        ;;
esac

if ! ethv_qps615_list_netdevs \
    "$QPS_RUNTIME_DIR/qps615_runtime.tsv" >"$AVAILABLE_INTERFACES"; then
    test_result_record \
        "FAIL" \
        "Could not parse QPS615 netdev correlation from $QPS_RUNTIME_DIR/qps615_runtime.tsv"
    ethv_failure_diagnostics "$TESTNAME failure"
    test_result_finish "FAIL"
fi

available_count=$(wc -l <"$AVAILABLE_INTERFACES" | tr -d '[:space:]')
log_file_with_label "QPS615-AVAILABLE-INTERFACE" "$AVAILABLE_INTERFACES" 16

if [ "$available_count" -eq 0 ]; then
    if [ "$QPS615_TRAFFIC_FIXTURE" -eq 1 ]; then
        test_result_record \
            "FAIL" \
            "QPS615 traffic fixture was selected but no traffic-capable QPS615 netdev is exposed: ${QPS615_ETHERNET_SKIP_REASON:-no correlated netdev}"
        ethv_failure_diagnostics "$TESTNAME failure"
        test_result_finish "FAIL"
    fi
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: QPS615 is present but exposes no traffic-capable netdev"
fi

if [ "$QPS615_TRAFFIC_FIXTURE" -ne 1 ]; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: external traffic was not authorized, rerun with --fixture only when selected ports have reachable peers"
fi

if ! command -v ping >/dev/null 2>&1 && ! command -v ping6 >/dev/null 2>&1; then
    test_result_record \
        "FAIL" \
        "QPS615 traffic was explicitly requested but neither ping nor ping6 is image-provided"
    ethv_failure_diagnostics "$TESTNAME failure"
    test_result_finish "FAIL"
fi

if ! command -v ip >/dev/null 2>&1 &&
   ! command -v ifconfig >/dev/null 2>&1; then
    test_result_record \
        "FAIL" \
        "QPS615 traffic needs image-provided ip for IPv4/IPv6 discovery, IPv4 also supports ifconfig"
    ethv_failure_diagnostics "$TESTNAME failure"
    test_result_finish "FAIL"
fi

if [ -z "$QPS615_PEER" ] && ! command -v ip >/dev/null 2>&1; then
    test_result_record \
        "FAIL" \
        "QPS615 automatic peer discovery requires image-provided ip, or provide --peer IP|HOST"
    ethv_failure_diagnostics "$TESTNAME failure"
    test_result_finish "FAIL"
fi

: >"$SELECTED_INTERFACES"
case "$QPS615_INTERFACES" in
    "")
        if [ "$available_count" -ne 1 ]; then
            test_result_record \
                "FAIL" \
                "QPS615 exposes $available_count netdevs and the fixture was selected, identify fixture-connected ports with --interfaces"
            ethv_failure_diagnostics "$TESTNAME failure"
            test_result_finish "FAIL"
        fi
        sed -n '1p' "$AVAILABLE_INTERFACES" >"$SELECTED_INTERFACES"
        selection_source="auto-unique"
        ;;
    all)
        awk 'NF { print }' "$AVAILABLE_INTERFACES" >"$SELECTED_INTERFACES"
        selection_source="explicit-all"
        ;;
    *)
        printf '%s\n' "$QPS615_INTERFACES" \
            | tr ',' '\n' \
            | sort -u >"$SELECTED_INTERFACES"
        selection_source="explicit-list"
        ;;
esac

log_info "[QPS615-SELECTION] source=$selection_source count=$(wc -l <"$SELECTED_INTERFACES" | tr -d '[:space:]') artifact=$SELECTED_INTERFACES"
log_file_with_label "QPS615-SELECTED-INTERFACE" "$SELECTED_INTERFACES" 16

while IFS= read -r qps_iface; do
    [ -n "$qps_iface" ] || continue
    ethv_failure_diagnostics_watch "$qps_iface"

    if ! grep -Fxq "$qps_iface" "$AVAILABLE_INTERFACES"; then
        test_result_record \
            "FAIL" \
            "Requested interface $qps_iface is not correlated with a QPS615 Ethernet function"
        ethv_failure_diagnostics "$TESTNAME failure"
        continue
    fi

    if [ ! -d "/sys/class/net/$qps_iface" ]; then
        test_result_record "FAIL" "QPS615 interface $qps_iface disappeared before traffic validation"
        ethv_failure_diagnostics "$TESTNAME failure"
        continue
    fi

    qps_carrier=$(ethv_get_carrier "$qps_iface")
    qps_ipv4=$(ethv_get_ipv4 "$qps_iface")
    log_info "[QPS615-TRAFFIC] interface=$qps_iface selection=$selection_source carrier=${qps_carrier:-unknown} ipv4=${qps_ipv4:-none} requested_peer=${QPS615_PEER:-auto-gateway}"

    if [ "$qps_carrier" != "1" ]; then
        test_result_record \
            "FAIL" \
            "QPS615 interface $qps_iface has no carrier although the external fixture was confirmed"
        ethv_failure_diagnostics "$TESTNAME failure"
        continue
    fi
    if ! ethv_resolve_traffic_peer "$qps_iface" "$QPS615_PEER" "$RESULT_DIR/${qps_iface}_peer"; then
        test_result_record \
            "FAIL" \
            "QPS615 peer discovery failed on $qps_iface: $ETHV_PEER_REASON"
        ethv_failure_diagnostics "$TESTNAME failure"
        continue
    fi
    qps_target="$ETHV_PEER_ADDRESS"
    if [ "$ETHV_PEER_FAMILY" = 4 ] && ! ethv_valid_unicast_ipv4 "$qps_ipv4"; then
        test_result_record "FAIL" "QPS615 interface $qps_iface has no usable IPv4 address for selected peer $qps_target, configure DHCP or static addressing"
        ethv_failure_diagnostics "$TESTNAME failure"
        continue
    fi
    log_info "[QPS615-PEER] interface=$qps_iface source=$ETHV_PEER_SOURCE family=IPv$ETHV_PEER_FAMILY requested=${QPS615_PEER:-auto} resolved_address=$qps_target artifact_prefix=$RESULT_DIR/${qps_iface}_peer"

    if ! ethv_counters_available \
        "$qps_iface" \
        rx_packets \
        tx_packets \
        rx_errors \
        tx_errors \
        rx_crc_errors \
        tx_carrier_errors; then
        test_result_record \
            "FAIL" \
            "QPS615 interface $qps_iface does not expose usable $ETHV_COUNTER_FAILURE statistics before traffic"
        ethv_failure_diagnostics "$TESTNAME failure"
        continue
    fi

    before_rx=$(ethv_get_counter "$qps_iface" rx_packets)
    before_tx=$(ethv_get_counter "$qps_iface" tx_packets)
    before_rx_errors=$(ethv_get_counter "$qps_iface" rx_errors)
    before_tx_errors=$(ethv_get_counter "$qps_iface" tx_errors)
    before_crc=$(ethv_get_counter "$qps_iface" rx_crc_errors)
    before_carrier_errors=$(ethv_get_counter "$qps_iface" tx_carrier_errors)

    qps_driver_stats_status=0
    ethv_capture_driver_statistics "$qps_iface" "$RESULT_DIR/${qps_iface}_driver_before" || qps_driver_stats_status=$?
    log_info "$ETHV_DRIVER_STATS_REASON"

    ping_log="$RESULT_DIR/${qps_iface}_ping.log"
    if ethv_ping_interface \
        "$qps_iface" \
        "$qps_target" \
        "$QPS615_PING_COUNT" \
        "$QPS615_PING_WAIT" \
        "$ETHV_PEER_FAMILY" >"$ping_log" 2>&1; then
        ping_status=0
    else
        ping_status=$?
    fi

    if [ "$qps_driver_stats_status" -eq 0 ]; then
        if ethv_capture_driver_statistics "$qps_iface" "$RESULT_DIR/${qps_iface}_driver_after" &&
           ethv_compare_driver_statistics \
               "$RESULT_DIR/${qps_iface}_driver_before.tsv" \
               "$RESULT_DIR/${qps_iface}_driver_after.tsv" \
               "$RESULT_DIR/${qps_iface}_driver_changes.tsv"; then
            log_file_with_label "QPS615-DRIVER-COUNTERS-$qps_iface" "$RESULT_DIR/${qps_iface}_driver_changes.tsv" 60
        else
            log_warn "Optional driver-counter comparison is unavailable: $ETHV_DRIVER_STATS_REASON"
        fi
    fi

    if ! ethv_counters_available \
        "$qps_iface" \
        rx_packets \
        tx_packets \
        rx_errors \
        tx_errors \
        rx_crc_errors \
        tx_carrier_errors; then
        log_file_with_label "QPS615-PING-$qps_iface" "$ping_log" 20
        test_result_record \
            "FAIL" \
            "QPS615 interface $qps_iface lost usable $ETHV_COUNTER_FAILURE statistics after traffic"
        ethv_failure_diagnostics "$TESTNAME failure"
        continue
    fi

    after_rx=$(ethv_get_counter "$qps_iface" rx_packets)
    after_tx=$(ethv_get_counter "$qps_iface" tx_packets)
    after_rx_errors=$(ethv_get_counter "$qps_iface" rx_errors)
    after_tx_errors=$(ethv_get_counter "$qps_iface" tx_errors)
    after_crc=$(ethv_get_counter "$qps_iface" rx_crc_errors)
    after_carrier_errors=$(ethv_get_counter "$qps_iface" tx_carrier_errors)
    rx_delta=$(ethv_counter_delta "$before_rx" "$after_rx")
    tx_delta=$(ethv_counter_delta "$before_tx" "$after_tx")
    rx_error_delta=$(ethv_counter_delta "$before_rx_errors" "$after_rx_errors")
    tx_error_delta=$(ethv_counter_delta "$before_tx_errors" "$after_tx_errors")
    crc_delta=$(ethv_counter_delta "$before_crc" "$after_crc")
    carrier_error_delta=$(ethv_counter_delta "$before_carrier_errors" "$after_carrier_errors")

    log_info "[QPS615-COUNTERS] interface=$qps_iface rx_packets_before=$before_rx rx_packets_after=$after_rx rx_packets_delta=$rx_delta tx_packets_before=$before_tx tx_packets_after=$after_tx tx_packets_delta=$tx_delta rx_errors_delta=$rx_error_delta tx_errors_delta=$tx_error_delta rx_crc_delta=$crc_delta tx_carrier_delta=$carrier_error_delta artifact=$ping_log"
    log_file_with_label "QPS615-PING-$qps_iface" "$ping_log" 20

    if [ "$ping_status" -ne 0 ]; then
        test_result_record \
            "FAIL" \
            "QPS615 traffic to $qps_target failed on $qps_iface, rc=$ping_status artifact=$ping_log"
        ethv_failure_diagnostics "$TESTNAME failure"
    elif ! grep -Eq '(^|[[:space:],])0% packet loss' "$ping_log"; then
        test_result_record \
            "FAIL" \
            "QPS615 traffic to $qps_target completed with packet loss on $qps_iface, artifact=$ping_log"
        ethv_failure_diagnostics "$TESTNAME failure"
    elif [ "$rx_delta" -le 0 ] || [ "$tx_delta" -le 0 ]; then
        test_result_record \
            "FAIL" \
            "QPS615 ping succeeded on $qps_iface but counters did not prove bidirectional traffic, rx_delta=$rx_delta tx_delta=$tx_delta"
        ethv_failure_diagnostics "$TESTNAME failure"
    elif [ "$rx_error_delta" -ne 0 ] || [ "$tx_error_delta" -ne 0 ] ||
         [ "$crc_delta" -ne 0 ] || [ "$carrier_error_delta" -ne 0 ]; then
        test_result_record \
            "FAIL" \
            "QPS615 traffic increased hardware error counters on $qps_iface"
        ethv_failure_diagnostics "$TESTNAME failure"
    else
        test_result_record \
            "PASS" \
            "QPS615 interface $qps_iface transferred bidirectional traffic to $qps_target without packet loss or error-counter growth"
        QPS_TRAFFIC_PASS_COUNT=$((QPS_TRAFFIC_PASS_COUNT + 1))
    fi
done <"$SELECTED_INTERFACES"

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'tc956|qps615|stmmac|phylink|mdio' \
    'Link is Down|Link down|carrier lost|no carrier|deferred probe|EPROBE_DEFER'
qps_dmesg_status=$?

if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record \
        "SKIP" \
        "Kernel log access is unavailable for QPS615 traffic health validation, artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$qps_dmesg_status" -eq 0 ]; then
    log_file_with_label "QPS615-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 30
    test_result_record \
        "FAIL" \
        "QPS615 or Ethernet kernel errors were detected after traffic, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
    ethv_failure_diagnostics "$TESTNAME failure"
else
    test_result_record "PASS" "No QPS615 traffic-related kernel errors were found"
fi

if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$QPS_TRAFFIC_PASS_COUNT" -eq 0 ]; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: no selected QPS615 interface completed a traffic transfer"
fi

test_result_finish
