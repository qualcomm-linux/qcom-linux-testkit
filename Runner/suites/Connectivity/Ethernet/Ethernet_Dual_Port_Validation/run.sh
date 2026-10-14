#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Concurrent dual-port Ethernet connectivity and counter validation.

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

TESTNAME="Ethernet_Dual_Port_Validation"
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
ETH_DUAL_INTERFACES="${ETH_DUAL_INTERFACES:-}"
ETH_DUAL_TARGET_A="${ETH_DUAL_TARGET_A:-}"
ETH_DUAL_TARGET_B="${ETH_DUAL_TARGET_B:-}"
PING_COUNT="${PING_COUNT:-10}"
PING_WAIT_S="${PING_WAIT_S:-2}"

usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --link-timeout SECONDS" \
        "  --ip-timeout SECONDS" \
        "  --interfaces \"IFACE_A IFACE_B\"" \
        "  --target-a ADDRESS" \
        "  --target-b ADDRESS" \
        "  --ping-count COUNT" \
        "  --ping-wait SECONDS" \
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
        --interfaces)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_DUAL_INTERFACES="$2"
            shift 2
            ;;
        --target-a)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_DUAL_TARGET_A="$2"
            shift 2
            ;;
        --target-b)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_DUAL_TARGET_B="$2"
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

PING_LOG_A=""
PING_LOG_B=""
PING_PID_A=""
PING_PID_B=""

# shellcheck disable=SC2317
cleanup_dual_port() {
    if [ -n "$PING_PID_A" ]; then
        kill "$PING_PID_A" >/dev/null 2>&1 || true
    fi
    if [ -n "$PING_PID_B" ]; then
        kill "$PING_PID_B" >/dev/null 2>&1 || true
    fi
    if [ -n "$PING_LOG_A" ]; then
        rm -f "$PING_LOG_A" >/dev/null 2>&1 || true
    fi
    if [ -n "$PING_LOG_B" ]; then
        rm -f "$PING_LOG_B" >/dev/null 2>&1 || true
    fi
}

trap 'cleanup_dual_port' EXIT HUP INT TERM

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Configuration: ETH_DUAL_INTERFACES=${ETH_DUAL_INTERFACES:-auto} PING_COUNT=$PING_COUNT PING_WAIT_S=$PING_WAIT_S"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies \
    ip \
    ping \
    awk \
    sed \
    grep \
    cat \
    sleep \
    mktemp; then

    log_skip "$TESTNAME SKIP: missing runtime dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if ! ethv_is_positive_integer "$LINK_TIMEOUT_S" \
   || ! ethv_is_positive_integer "$IP_TIMEOUT_S" \
   || ! ethv_is_positive_integer "$PING_COUNT" \
   || ! ethv_is_positive_integer "$PING_WAIT_S"; then

    log_fail "$TESTNAME FAIL: numeric configuration values must be positive integers"
    ethv_failure_diagnostics "$TESTNAME failure"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ -n "$ETH_DUAL_INTERFACES" ]; then
    ETH_IFACES="$ETH_DUAL_INTERFACES"
else
    ETH_IFACES="$(
        ethv_get_physical_interfaces \
            | sed -n '1,2p'
    )"
fi

ETH_IFACE_LINES="$(
    printf '%s\n' "$ETH_IFACES" \
        | tr ' ' '\n' \
        | sed '/^[[:space:]]*$/d'
)"

IFACE_A="$(printf '%s\n' "$ETH_IFACE_LINES" | sed -n '1p')"
IFACE_B="$(printf '%s\n' "$ETH_IFACE_LINES" | sed -n '2p')"
ethv_failure_diagnostics_watch "$IFACE_A" "$IFACE_B"

if [ -z "$IFACE_A" ] || [ -z "$IFACE_B" ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "Dual-port interface selection" \
        "SKIP" \
        "two physical Ethernet interfaces are required, selected=${ETH_IFACES:-none}"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Dual-Port Summary"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ "$IFACE_A" = "$IFACE_B" ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "Dual-port interface selection" \
        "FAIL" \
        "the selected interface names are identical: $IFACE_A"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Dual-Port Summary"
    ethv_failure_diagnostics "$TESTNAME failure"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

for iface in "$IFACE_A" "$IFACE_B"; do
    ethv_failure_diagnostics_watch "$iface"
    if [ ! -d "/sys/class/net/$iface" ]; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface interface selection" \
            "FAIL" \
            "selected interface does not exist"
        continue
    fi

    ethv_prepare_interface "$iface" "$LINK_TIMEOUT_S" "$IP_TIMEOUT_S"
    prepare_rc=$?

    case "$prepare_rc" in
        0)
            ip_addr="$(ethv_get_ipv4 "$iface")"
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface readiness" \
                "PASS" \
                "ip=$ip_addr carrier=$(ethv_get_carrier "$iface") speed=$(ethv_get_speed "$iface")Mb/s"
            ;;
        1)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface readiness" \
                "FAIL" \
                "unable to bring the interface up"
            ;;
        2)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface readiness" \
                "SKIP" \
                "no carrier or link partner detected"
            ;;
        3)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface readiness" \
                "SKIP" \
                "no valid IPv4 address available"
            ;;
    esac
done

if [ "$(ethv_result_count "$RESULT_TABLE" FAIL)" -gt 0 ]; then
    ethv_print_summary "$RESULT_TABLE" "Ethernet Dual-Port Summary"
    ethv_failure_diagnostics "$TESTNAME failure"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ "$(ethv_result_count "$RESULT_TABLE" PASS)" -lt 2 ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "Concurrent dual-port traffic" \
        "SKIP" \
        "both selected interfaces must have carrier and IPv4"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Dual-Port Summary"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

IP_A="$(ethv_get_ipv4 "$IFACE_A")"
IP_B="$(ethv_get_ipv4 "$IFACE_B")"
TARGET_A="$(ethv_select_ping_target "$IFACE_A" "$ETH_DUAL_TARGET_A")"
TARGET_B="$(ethv_select_ping_target "$IFACE_B" "$ETH_DUAL_TARGET_B")"

TX_A_BEFORE="$(ethv_get_counter "$IFACE_A" tx_packets)"
RX_A_BEFORE="$(ethv_get_counter "$IFACE_A" rx_packets)"
TX_B_BEFORE="$(ethv_get_counter "$IFACE_B" tx_packets)"
RX_B_BEFORE="$(ethv_get_counter "$IFACE_B" rx_packets)"

PING_LOG_A="$(mktemp "/tmp/${TESTNAME}.${IFACE_A}.XXXXXX")"
PING_LOG_B="$(mktemp "/tmp/${TESTNAME}.${IFACE_B}.XXXXXX")"

log_info "Starting concurrent ping: $IFACE_A($IP_A) -> $TARGET_A"
ping -I "$IFACE_A" -c "$PING_COUNT" -W "$PING_WAIT_S" "$TARGET_A" \
    >"$PING_LOG_A" 2>&1 &
PING_PID_A=$!

log_info "Starting concurrent ping: $IFACE_B($IP_B) -> $TARGET_B"
ping -I "$IFACE_B" -c "$PING_COUNT" -W "$PING_WAIT_S" "$TARGET_B" \
    >"$PING_LOG_B" 2>&1 &
PING_PID_B=$!

wait "$PING_PID_A"
PING_RC_A=$?
PING_PID_A=""

wait "$PING_PID_B"
PING_RC_B=$?
PING_PID_B=""

while IFS= read -r line; do
    [ -n "$line" ] && log_info "[$IFACE_A ping] $line"
done <"$PING_LOG_A"

while IFS= read -r line; do
    [ -n "$line" ] && log_info "[$IFACE_B ping] $line"
done <"$PING_LOG_B"

TX_A_AFTER="$(ethv_get_counter "$IFACE_A" tx_packets)"
RX_A_AFTER="$(ethv_get_counter "$IFACE_A" rx_packets)"
TX_B_AFTER="$(ethv_get_counter "$IFACE_B" tx_packets)"
RX_B_AFTER="$(ethv_get_counter "$IFACE_B" rx_packets)"

TX_A_DELTA="$(ethv_counter_delta "$TX_A_BEFORE" "$TX_A_AFTER")"
RX_A_DELTA="$(ethv_counter_delta "$RX_A_BEFORE" "$RX_A_AFTER")"
TX_B_DELTA="$(ethv_counter_delta "$TX_B_BEFORE" "$TX_B_AFTER")"
RX_B_DELTA="$(ethv_counter_delta "$RX_B_BEFORE" "$RX_B_AFTER")"

if [ "$PING_RC_A" -eq 0 ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "$IFACE_A concurrent connectivity" \
        "PASS" \
        "target=$TARGET_A tx_packets_delta=$TX_A_DELTA rx_packets_delta=$RX_A_DELTA"
else
    ethv_record_result \
        "$RESULT_TABLE" \
        "$IFACE_A concurrent connectivity" \
        "FAIL" \
        "ping target=$TARGET_A rc=$PING_RC_A"
fi

if [ "$PING_RC_B" -eq 0 ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "$IFACE_B concurrent connectivity" \
        "PASS" \
        "target=$TARGET_B tx_packets_delta=$TX_B_DELTA rx_packets_delta=$RX_B_DELTA"
else
    ethv_record_result \
        "$RESULT_TABLE" \
        "$IFACE_B concurrent connectivity" \
        "FAIL" \
        "ping target=$TARGET_B rc=$PING_RC_B"
fi

if [ "$PING_RC_A" -eq 0 ] \
   && [ "$PING_RC_B" -eq 0 ] \
   && [ "$TX_A_DELTA" -gt 0 ] \
   && [ "$RX_A_DELTA" -gt 0 ] \
   && [ "$TX_B_DELTA" -gt 0 ] \
   && [ "$RX_B_DELTA" -gt 0 ]; then

    ethv_record_result \
        "$RESULT_TABLE" \
        "Concurrent dual-port traffic" \
        "PASS" \
        "both interfaces passed simultaneously with RX/TX counter movement"
else
    ethv_record_result \
        "$RESULT_TABLE" \
        "Concurrent dual-port traffic" \
        "FAIL" \
        "both ports did not complete concurrent ping with RX/TX counter movement"
fi

OVERALL_RESULT="$(ethv_compute_overall_result "$RESULT_TABLE")"

ethv_print_summary "$RESULT_TABLE" "Ethernet Dual-Port Summary"

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
