#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Ethernet TCP, reverse, UDP, and optional bidirectional throughput validation.

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

TESTNAME="Ethernet_Throughput_Validation"
RES_FILE="./$TESTNAME.res"
ethv_failure_diagnostics_init "$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$/failure_diagnostics"

test_path="$(find_test_case_by_name "$TESTNAME")"

if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

RESULT_TABLE="./$TESTNAME.results.tsv"
LOG_DIR="./iperf_logs"

LINK_TIMEOUT_S="${LINK_TIMEOUT_S:-10}"
IP_TIMEOUT_S="${IP_TIMEOUT_S:-15}"
ETH_IPERF_SERVER="${ETH_IPERF_SERVER:-}"
ETH_IPERF_MODE="${ETH_IPERF_MODE:-auto}"
ETH_IPERF_PORT="${ETH_IPERF_PORT:-5201}"
ETH_IPERF_INTERFACE="${ETH_IPERF_INTERFACE:-}"
ETH_IPERF_DURATION="${ETH_IPERF_DURATION:-20}"
ETH_IPERF_STREAMS="${ETH_IPERF_STREAMS:-1}"
ETH_IPERF_MIN_TCP_MBPS="${ETH_IPERF_MIN_TCP_MBPS:-0}"
ETH_IPERF_MIN_REVERSE_MBPS="${ETH_IPERF_MIN_REVERSE_MBPS:-0}"
ETH_IPERF_REVERSE_ENABLE="${ETH_IPERF_REVERSE_ENABLE:-1}"
ETH_IPERF_UDP_ENABLE="${ETH_IPERF_UDP_ENABLE:-0}"
ETH_IPERF_UDP_BITRATE="${ETH_IPERF_UDP_BITRATE:-100M}"
ETH_IPERF_MIN_UDP_MBPS="${ETH_IPERF_MIN_UDP_MBPS:-0}"
ETH_IPERF_BIDIR_ENABLE="${ETH_IPERF_BIDIR_ENABLE:-0}"
ETH_IPERF_MIN_BIDIR_MBPS="${ETH_IPERF_MIN_BIDIR_MBPS:-0}"
LOCAL_SERVER_PID=""

usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --mode auto|external|local" \
        "  --iperf-server ADDRESS" \
        "  --port PORT" \
        "  --interface IFACE" \
        "  --link-timeout SECONDS" \
        "  --ip-timeout SECONDS" \
        "  --duration SECONDS" \
        "  --streams COUNT" \
        "  --min-tcp-mbps MBPS" \
        "  --reverse-enable 0|1" \
        "  --min-reverse-mbps MBPS" \
        "  --udp-enable 0|1" \
        "  --udp-bitrate RATE" \
        "  --min-udp-mbps MBPS" \
        "  --bidir-enable 0|1" \
        "  --min-bidir-mbps MBPS" \
        "  -h, --help" \
        "CLI options override environment variables."
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --mode)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_MODE="$2"
            shift 2
            ;;
        --iperf-server)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_SERVER="$2"
            shift 2
            ;;
        --port)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_PORT="$2"
            shift 2
            ;;
        --interface)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_INTERFACE="$2"
            shift 2
            ;;
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
        --duration)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_DURATION="$2"
            shift 2
            ;;
        --streams)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_STREAMS="$2"
            shift 2
            ;;
        --min-tcp-mbps)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_MIN_TCP_MBPS="$2"
            shift 2
            ;;
        --reverse-enable)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_REVERSE_ENABLE="$2"
            shift 2
            ;;
        --min-reverse-mbps)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_MIN_REVERSE_MBPS="$2"
            shift 2
            ;;
        --udp-enable)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_UDP_ENABLE="$2"
            shift 2
            ;;
        --udp-bitrate)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_UDP_BITRATE="$2"
            shift 2
            ;;
        --min-udp-mbps)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_MIN_UDP_MBPS="$2"
            shift 2
            ;;
        --bidir-enable)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_BIDIR_ENABLE="$2"
            shift 2
            ;;
        --min-bidir-mbps)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_IPERF_MIN_BIDIR_MBPS="$2"
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
mkdir -p "$LOG_DIR" || {
    ethv_failure_diagnostics "$TESTNAME failure"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
}
rm -f "$LOG_DIR"/*.log
: >"$RESULT_TABLE"

# shellcheck disable=SC2317
cleanup_local_iperf_server() {
    if [ -n "$LOCAL_SERVER_PID" ] \
       && kill -0 "$LOCAL_SERVER_PID" >/dev/null 2>&1; then

        kill "$LOCAL_SERVER_PID" >/dev/null 2>&1 || true
        wait "$LOCAL_SERVER_PID" >/dev/null 2>&1 || true
    fi
}

trap 'cleanup_local_iperf_server' EXIT
trap 'exit 1' HUP INT TERM

run_iperf_case() {
    iperf_case_label="${1:-iperf}"
    iperf_case_mode="${2:-forward}"
    iperf_case_threshold="${3:-0}"
    iperf_case_log="${4:-$LOG_DIR/iperf.log}"

    set -- \
        iperf3 \
        -c "$ETH_IPERF_SERVER" \
        -B "$ETH_LOCAL_IP" \
        -p "$ETH_IPERF_PORT" \
        -t "$ETH_IPERF_DURATION" \
        -P "$ETH_IPERF_STREAMS" \
        -f m

    case "$iperf_case_mode" in
        reverse)
            set -- "$@" -R
            ;;
        udp)
            set -- "$@" -u -b "$ETH_IPERF_UDP_BITRATE"
            ;;
        bidir)
            set -- "$@" --bidir
            ;;
    esac

    log_info "Running $iperf_case_label"
    printf '[INFO] command:'
    for iperf_case_arg in "$@"; do
        printf ' %s' "$iperf_case_arg"
    done
    printf '\n'

    "$@" >"$iperf_case_log" 2>&1
    iperf_case_rc=$?

    while IFS= read -r iperf_case_line; do
        [ -n "$iperf_case_line" ] && log_info "[$iperf_case_label] $iperf_case_line"
    done <"$iperf_case_log"

    if [ "$iperf_case_rc" -ne 0 ]; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iperf_case_label" \
            "FAIL" \
            "iperf3 exited with rc=$iperf_case_rc log=$iperf_case_log"
        return 1
    fi

    iperf_case_mbps="$(ethv_parse_iperf_mbps "$iperf_case_log" || true)"

    if [ -z "$iperf_case_mbps" ]; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iperf_case_label" \
            "FAIL" \
            "iperf3 succeeded but receiver throughput could not be parsed"
        return 1
    fi

    if ethv_float_ge "$iperf_case_mbps" "$iperf_case_threshold"; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iperf_case_label" \
            "PASS" \
            "minimum_receiver_throughput=${iperf_case_mbps}Mb/s threshold=${iperf_case_threshold}Mb/s"
        return 0
    fi

    ethv_record_result \
        "$RESULT_TABLE" \
        "$iperf_case_label" \
        "FAIL" \
        "minimum_receiver_throughput=${iperf_case_mbps}Mb/s below threshold=${iperf_case_threshold}Mb/s"

    return 1
}

start_local_iperf_server() {
    local_server_log="$LOG_DIR/local_server.log"

    log_info "Starting local iperf3 server on $ETH_LOCAL_IP:$ETH_IPERF_PORT"

    iperf3 \
        -s \
        -B "$ETH_LOCAL_IP" \
        -p "$ETH_IPERF_PORT" \
        >"$local_server_log" 2>&1 &
    LOCAL_SERVER_PID=$!

    sleep 1

    if kill -0 "$LOCAL_SERVER_PID" >/dev/null 2>&1; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "Local iperf3 server" \
            "PASS" \
            "listening on $ETH_LOCAL_IP:$ETH_IPERF_PORT pid=$LOCAL_SERVER_PID"
        return 0
    fi

    wait "$LOCAL_SERVER_PID" >/dev/null 2>&1 || true
    LOCAL_SERVER_PID=""

    while IFS= read -r local_server_line; do
        [ -n "$local_server_line" ] \
            && log_info "[local iperf3 server] $local_server_line"
    done <"$local_server_log"

    ethv_record_result \
        "$RESULT_TABLE" \
        "Local iperf3 server" \
        "FAIL" \
        "server failed to start on $ETH_LOCAL_IP:$ETH_IPERF_PORT log=$local_server_log"

    return 1
}

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Configuration: mode=$ETH_IPERF_MODE server=${ETH_IPERF_SERVER:-unset} port=$ETH_IPERF_PORT interface=${ETH_IPERF_INTERFACE:-auto} duration=$ETH_IPERF_DURATION streams=$ETH_IPERF_STREAMS"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies \
    ip \
    iperf3 \
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
    "$ETH_IPERF_PORT" \
    "$ETH_IPERF_DURATION" \
    "$ETH_IPERF_STREAMS"; do

    if ! ethv_is_positive_integer "$value"; then
        log_fail "$TESTNAME FAIL: timeout, port, duration, and stream values must be positive integers"
        ethv_failure_diagnostics "$TESTNAME failure"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
done

for bool_value in \
    "$ETH_IPERF_REVERSE_ENABLE" \
    "$ETH_IPERF_UDP_ENABLE" \
    "$ETH_IPERF_BIDIR_ENABLE"; do

    if ! ethv_is_boolean "$bool_value"; then
        log_fail "$TESTNAME FAIL: enable controls must be 0 or 1"
        ethv_failure_diagnostics "$TESTNAME failure"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
done

case "$ETH_IPERF_MODE" in
    auto)
        if [ -n "$ETH_IPERF_SERVER" ]; then
            RESOLVED_IPERF_MODE="external"
        else
            RESOLVED_IPERF_MODE="local"
        fi
        ;;
    external)
        if [ -z "$ETH_IPERF_SERVER" ]; then
            log_fail "$TESTNAME FAIL: external mode requires --iperf-server or ETH_IPERF_SERVER"
            ethv_failure_diagnostics "$TESTNAME failure"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi
        RESOLVED_IPERF_MODE="external"
        ;;
    local)
        if [ -n "$ETH_IPERF_SERVER" ]; then
            log_fail "$TESTNAME FAIL: local mode cannot be combined with an external iperf3 server"
            ethv_failure_diagnostics "$TESTNAME failure"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi
        RESOLVED_IPERF_MODE="local"
        ;;
    *)
        log_fail "$TESTNAME FAIL: mode must be auto, external, or local"
        ethv_failure_diagnostics "$TESTNAME failure"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
        ;;
esac

for threshold_value in \
    "$ETH_IPERF_MIN_TCP_MBPS" \
    "$ETH_IPERF_MIN_REVERSE_MBPS" \
    "$ETH_IPERF_MIN_UDP_MBPS" \
    "$ETH_IPERF_MIN_BIDIR_MBPS"; do

    if ! ethv_is_nonnegative_decimal "$threshold_value"; then
        log_fail "$TESTNAME FAIL: throughput thresholds must be nonnegative decimal numbers"
        ethv_failure_diagnostics "$TESTNAME failure"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
done

if [ -n "$ETH_IPERF_INTERFACE" ]; then
    ETH_IFACE="$ETH_IPERF_INTERFACE"
else
    ETH_IFACE="$(ethv_get_physical_interfaces | sed -n '1p')"
fi

if [ -z "$ETH_IFACE" ] || [ ! -d "/sys/class/net/$ETH_IFACE" ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "Throughput interface selection" \
        "SKIP" \
        "no valid physical Ethernet interface selected"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Throughput Summary"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

ethv_failure_diagnostics_watch "$ETH_IFACE"
ethv_prepare_interface "$ETH_IFACE" "$LINK_TIMEOUT_S" "$IP_TIMEOUT_S"
prepare_rc=$?

case "$prepare_rc" in
    0)
        ;;
    1)
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE throughput readiness" \
            "FAIL" \
            "interface could not be brought up"
        ;;
    2)
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE throughput readiness" \
            "SKIP" \
            "no carrier or link partner detected"
        ;;
    3)
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE throughput readiness" \
            "SKIP" \
            "no valid IPv4 address available"
        ;;
esac

if [ "$prepare_rc" -ne 0 ]; then
    OVERALL_RESULT="$(ethv_compute_overall_result "$RESULT_TABLE")"
    ethv_print_summary "$RESULT_TABLE" "Ethernet Throughput Summary"

    case "$OVERALL_RESULT" in
        FAIL)
            ethv_failure_diagnostics "$TESTNAME failure"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            ;;
        *)
            echo "$TESTNAME SKIP" >"$RES_FILE"
            ;;
    esac

    exit 0
fi

ETH_LOCAL_IP="$(ethv_get_ipv4 "$ETH_IFACE")"

if [ "$RESOLVED_IPERF_MODE" = "local" ]; then
    ETH_IPERF_SERVER="$ETH_LOCAL_IP"

    if ! start_local_iperf_server; then
        ethv_print_summary "$RESULT_TABLE" "Ethernet Throughput Summary"
        ethv_failure_diagnostics "$TESTNAME failure"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi

    SERVER_MODE="local-host-stack-self-test"
else
    SERVER_MODE="external-peer-link-test"
fi

ethv_record_result \
    "$RESULT_TABLE" \
    "$ETH_IFACE throughput readiness" \
    "PASS" \
    "local_ip=$ETH_LOCAL_IP server=$ETH_IPERF_SERVER port=$ETH_IPERF_PORT mode=$SERVER_MODE"

run_iperf_case \
    "$ETH_IFACE TCP forward" \
    forward \
    "$ETH_IPERF_MIN_TCP_MBPS" \
    "$LOG_DIR/tcp_forward.log" || true

if [ "$ETH_IPERF_REVERSE_ENABLE" = "1" ]; then
    run_iperf_case \
        "$ETH_IFACE TCP reverse" \
        reverse \
        "$ETH_IPERF_MIN_REVERSE_MBPS" \
        "$LOG_DIR/tcp_reverse.log" || true
else
    ethv_record_result \
        "$RESULT_TABLE" \
        "$ETH_IFACE TCP reverse" \
        "SKIP" \
        "disabled by ETH_IPERF_REVERSE_ENABLE"
fi

if [ "$ETH_IPERF_UDP_ENABLE" = "1" ]; then
    run_iperf_case \
        "$ETH_IFACE UDP forward" \
        udp \
        "$ETH_IPERF_MIN_UDP_MBPS" \
        "$LOG_DIR/udp_forward.log" || true
else
    ethv_record_result \
        "$RESULT_TABLE" \
        "$ETH_IFACE UDP forward" \
        "SKIP" \
        "disabled by ETH_IPERF_UDP_ENABLE"
fi

if [ "$ETH_IPERF_BIDIR_ENABLE" = "1" ]; then
    if iperf3 --help 2>&1 | grep -q -- '--bidir'; then
        run_iperf_case \
            "$ETH_IFACE TCP bidirectional" \
            bidir \
            "$ETH_IPERF_MIN_BIDIR_MBPS" \
            "$LOG_DIR/tcp_bidir.log" || true
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE TCP bidirectional" \
            "SKIP" \
            "installed iperf3 does not support --bidir"
    fi
else
    ethv_record_result \
        "$RESULT_TABLE" \
        "$ETH_IFACE TCP bidirectional" \
        "SKIP" \
        "disabled by ETH_IPERF_BIDIR_ENABLE"
fi

OVERALL_RESULT="$(ethv_compute_overall_result "$RESULT_TABLE")"

ethv_print_summary "$RESULT_TABLE" "Ethernet Throughput Summary"

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
