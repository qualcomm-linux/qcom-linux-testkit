#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Ethernet packet-counter and error-delta validation using bounded ping traffic.

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

TESTNAME="Ethernet_Statistics_Validation"
RES_FILE="./$TESTNAME.res"
ethv_failure_diagnostics_init "$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$/failure_diagnostics"

test_path="$(find_test_case_by_name "$TESTNAME")"

if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

RESULT_TABLE="./$TESTNAME.results.tsv"

LINK_TIMEOUT_S="${LINK_TIMEOUT_S:-10}"
IP_TIMEOUT_S="${IP_TIMEOUT_S:-15}"
ETH_INTERFACE="${ETH_INTERFACE:-}"
PING_TARGET="${PING_TARGET:-}"
PING_COUNT="${PING_COUNT:-10}"
PING_WAIT_S="${PING_WAIT_S:-2}"
MAX_RX_ERROR_DELTA="${MAX_RX_ERROR_DELTA:-0}"
MAX_TX_ERROR_DELTA="${MAX_TX_ERROR_DELTA:-0}"
MAX_RX_DROP_DELTA="${MAX_RX_DROP_DELTA:-}"
MAX_TX_DROP_DELTA="${MAX_TX_DROP_DELTA:-}"
DROP_THRESHOLDS_ENABLED=0

usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --link-timeout SECONDS" \
        "  --ip-timeout SECONDS" \
        "  --interface IFACE" \
        "  --ping-target ADDRESS" \
        "  --ping-count COUNT" \
        "  --ping-wait SECONDS" \
        "  --max-rx-error-delta COUNT" \
        "  --max-tx-error-delta COUNT" \
        "  --max-rx-drop-delta COUNT" \
        "  --max-tx-drop-delta COUNT" \
        "  -h, --help" \
        "CLI options override environment variables."
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --link-timeout)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            LINK_TIMEOUT_S="$2"
            shift 2
            ;;
        --ip-timeout)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            IP_TIMEOUT_S="$2"
            shift 2
            ;;
        --interface)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_INTERFACE="$2"
            shift 2
            ;;
        --ping-target)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            PING_TARGET="$2"
            shift 2
            ;;
        --ping-count)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            PING_COUNT="$2"
            shift 2
            ;;
        --ping-wait)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            PING_WAIT_S="$2"
            shift 2
            ;;
        --max-rx-error-delta)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            MAX_RX_ERROR_DELTA="$2"
            shift 2
            ;;
        --max-tx-error-delta)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            MAX_TX_ERROR_DELTA="$2"
            shift 2
            ;;
        --max-rx-drop-delta)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            MAX_RX_DROP_DELTA="$2"
            shift 2
            ;;
        --max-tx-drop-delta)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            MAX_TX_DROP_DELTA="$2"
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
log_info "Configuration: interface=${ETH_INTERFACE:-auto} PING_TARGET=${PING_TARGET:-auto} PING_COUNT=$PING_COUNT MAX_RX_ERROR_DELTA=$MAX_RX_ERROR_DELTA MAX_TX_ERROR_DELTA=$MAX_TX_ERROR_DELTA MAX_RX_DROP_DELTA=${MAX_RX_DROP_DELTA:-disabled} MAX_TX_DROP_DELTA=${MAX_TX_DROP_DELTA:-disabled}"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies \
    ip \
    ping \
    awk \
    sed \
    grep \
    cat \
    sleep; then

    log_skip "$TESTNAME SKIP: missing runtime dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

for value in \
    "$LINK_TIMEOUT_S" \
    "$IP_TIMEOUT_S" \
    "$PING_COUNT" \
    "$PING_WAIT_S" \
    "$MAX_RX_ERROR_DELTA" \
    "$MAX_TX_ERROR_DELTA"; do

    if ! ethv_is_uint "$value"; then
        log_fail "$TESTNAME FAIL: all numeric configuration values must be unsigned integers"
        ethv_failure_diagnostics "$TESTNAME failure"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
done

if [ -n "$MAX_RX_DROP_DELTA" ] && [ -n "$MAX_TX_DROP_DELTA" ]; then
    if ! ethv_is_uint "$MAX_RX_DROP_DELTA" \
       || ! ethv_is_uint "$MAX_TX_DROP_DELTA"; then

        log_fail "$TESTNAME FAIL: drop thresholds must be unsigned integers"
        ethv_failure_diagnostics "$TESTNAME failure"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi

    DROP_THRESHOLDS_ENABLED=1
elif [ -n "$MAX_RX_DROP_DELTA" ] || [ -n "$MAX_TX_DROP_DELTA" ]; then
    log_fail "$TESTNAME FAIL: both RX and TX drop thresholds must be configured together"
    ethv_failure_diagnostics "$TESTNAME failure"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ -n "$ETH_INTERFACE" ]; then
    ETH_IFACES="$ETH_INTERFACE"
else
    ETH_IFACES="$(ethv_get_physical_interfaces)"
fi

if [ -z "$ETH_IFACES" ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "Ethernet statistics validation" \
        "SKIP" \
        "no physical Ethernet interfaces detected"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Statistics Summary"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

for iface in $ETH_IFACES; do
    ethv_failure_diagnostics_watch "$iface"
    log_info "---- Statistics validation for $iface ----"

    ethv_prepare_interface "$iface" "$LINK_TIMEOUT_S" "$IP_TIMEOUT_S"
    prepare_rc=$?

    case "$prepare_rc" in
        0)
            ;;
        1)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface traffic readiness" \
                "FAIL" \
                "interface could not be brought up"
            continue
            ;;
        2)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface traffic readiness" \
                "SKIP" \
                "no carrier or link partner detected"
            continue
            ;;
        3)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface traffic readiness" \
                "SKIP" \
                "no valid IPv4 address is available"
            continue
            ;;
    esac

    ip_addr="$(ethv_get_ipv4 "$iface")"
    target="$(ethv_select_ping_target "$iface" "$PING_TARGET")"

    rx_bytes_before="$(ethv_get_counter "$iface" rx_bytes)"
    tx_bytes_before="$(ethv_get_counter "$iface" tx_bytes)"
    rx_packets_before="$(ethv_get_counter "$iface" rx_packets)"
    tx_packets_before="$(ethv_get_counter "$iface" tx_packets)"
    rx_errors_before="$(ethv_get_counter "$iface" rx_errors)"
    tx_errors_before="$(ethv_get_counter "$iface" tx_errors)"
    rx_dropped_before="$(ethv_get_counter "$iface" rx_dropped)"
    tx_dropped_before="$(ethv_get_counter "$iface" tx_dropped)"

    stats_prefix="$SCRIPT_DIR/results/$TESTNAME/driver-$$/$iface"
    driver_stats_status=0
    ethv_capture_driver_statistics "$iface" "${stats_prefix}_before" || driver_stats_status=$?
    log_info "$ETHV_DRIVER_STATS_REASON"

    log_info "$iface baseline: rx_bytes=$rx_bytes_before tx_bytes=$tx_bytes_before rx_packets=$rx_packets_before tx_packets=$tx_packets_before rx_errors=$rx_errors_before tx_errors=$tx_errors_before rx_dropped=$rx_dropped_before tx_dropped=$tx_dropped_before"

    traffic_status=0
    ethv_ping_interface "$iface" "$target" "$PING_COUNT" "$PING_WAIT_S" || traffic_status=$?
    if [ "$driver_stats_status" -eq 0 ]; then
        if ethv_capture_driver_statistics "$iface" "${stats_prefix}_after" &&
           ethv_compare_driver_statistics "${stats_prefix}_before.tsv" "${stats_prefix}_after.tsv" "${stats_prefix}_changes.tsv"; then
            log_file_with_label "ETHERNET-DRIVER-COUNTERS-$iface" "${stats_prefix}_changes.tsv" 60
        else
            log_warn "Optional driver-counter comparison is unavailable: $ETHV_DRIVER_STATS_REASON"
        fi
    fi
    if [ "$traffic_status" -ne 0 ]; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface bounded traffic" \
            "FAIL" \
            "ping to $target failed from $ip_addr"
        continue
    fi

    sleep 1

    rx_bytes_after="$(ethv_get_counter "$iface" rx_bytes)"
    tx_bytes_after="$(ethv_get_counter "$iface" tx_bytes)"
    rx_packets_after="$(ethv_get_counter "$iface" rx_packets)"
    tx_packets_after="$(ethv_get_counter "$iface" tx_packets)"
    rx_errors_after="$(ethv_get_counter "$iface" rx_errors)"
    tx_errors_after="$(ethv_get_counter "$iface" tx_errors)"
    rx_dropped_after="$(ethv_get_counter "$iface" rx_dropped)"
    tx_dropped_after="$(ethv_get_counter "$iface" tx_dropped)"

    rx_bytes_delta="$(ethv_counter_delta "$rx_bytes_before" "$rx_bytes_after")"
    tx_bytes_delta="$(ethv_counter_delta "$tx_bytes_before" "$tx_bytes_after")"
    rx_packets_delta="$(ethv_counter_delta "$rx_packets_before" "$rx_packets_after")"
    tx_packets_delta="$(ethv_counter_delta "$tx_packets_before" "$tx_packets_after")"
    rx_errors_delta="$(ethv_counter_delta "$rx_errors_before" "$rx_errors_after")"
    tx_errors_delta="$(ethv_counter_delta "$tx_errors_before" "$tx_errors_after")"
    rx_dropped_delta="$(ethv_counter_delta "$rx_dropped_before" "$rx_dropped_after")"
    tx_dropped_delta="$(ethv_counter_delta "$tx_dropped_before" "$tx_dropped_after")"

    log_info "$iface delta: rx_bytes=$rx_bytes_delta tx_bytes=$tx_bytes_delta rx_packets=$rx_packets_delta tx_packets=$tx_packets_delta rx_errors=$rx_errors_delta tx_errors=$tx_errors_delta rx_dropped=$rx_dropped_delta tx_dropped=$tx_dropped_delta"

    if [ "$rx_bytes_delta" -gt 0 ] \
       && [ "$tx_bytes_delta" -gt 0 ] \
       && [ "$rx_packets_delta" -gt 0 ] \
       && [ "$tx_packets_delta" -gt 0 ]; then

        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface packet counters" \
            "PASS" \
            "rx_bytes_delta=$rx_bytes_delta tx_bytes_delta=$tx_bytes_delta rx_packets_delta=$rx_packets_delta tx_packets_delta=$tx_packets_delta"
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface packet counters" \
            "FAIL" \
            "traffic succeeded but RX/TX packet or byte counters did not all increase"
    fi

    if [ "$rx_errors_delta" -ge 0 ] \
       && [ "$tx_errors_delta" -ge 0 ] \
       && [ "$rx_errors_delta" -le "$MAX_RX_ERROR_DELTA" ] \
       && [ "$tx_errors_delta" -le "$MAX_TX_ERROR_DELTA" ]; then

        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface error counters" \
            "PASS" \
            "rx_errors_delta=$rx_errors_delta tx_errors_delta=$tx_errors_delta"
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface error counters" \
            "FAIL" \
            "rx_errors_delta=$rx_errors_delta tx_errors_delta=$tx_errors_delta thresholds=$MAX_RX_ERROR_DELTA/$MAX_TX_ERROR_DELTA"
    fi

    if [ "$DROP_THRESHOLDS_ENABLED" -eq 0 ]; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface drop counters" \
            "SKIP" \
            "thresholds are disabled, observed rx_dropped_delta=$rx_dropped_delta tx_dropped_delta=$tx_dropped_delta"
    elif [ "$rx_dropped_delta" -ge 0 ] \
       && [ "$tx_dropped_delta" -ge 0 ] \
       && [ "$rx_dropped_delta" -le "$MAX_RX_DROP_DELTA" ] \
       && [ "$tx_dropped_delta" -le "$MAX_TX_DROP_DELTA" ]; then

        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface drop counters" \
            "PASS" \
            "rx_dropped_delta=$rx_dropped_delta tx_dropped_delta=$tx_dropped_delta"
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface drop counters" \
            "FAIL" \
            "rx_dropped_delta=$rx_dropped_delta tx_dropped_delta=$tx_dropped_delta thresholds=$MAX_RX_DROP_DELTA/$MAX_TX_DROP_DELTA"
    fi

done

OVERALL_RESULT="$(ethv_compute_overall_result "$RESULT_TABLE")"

ethv_print_summary "$RESULT_TABLE" "Ethernet Statistics Summary"

case "$OVERALL_RESULT" in
    PASS)
        log_pass "$TESTNAME PASS"
        echo "$TESTNAME PASS" >"$RES_FILE"
        ;;
    FAIL)
        log_fail "$TESTNAME FAIL"
        ethv_failure_diagnostics "$TESTNAME failure"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        ;;
    *)
        log_skip "$TESTNAME SKIP"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        ;;
esac

exit 0
