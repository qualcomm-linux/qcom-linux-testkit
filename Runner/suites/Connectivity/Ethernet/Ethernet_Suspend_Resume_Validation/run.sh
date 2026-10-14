#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Opt-in Ethernet suspend/resume link and connectivity validation.

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

TESTNAME="Ethernet_Suspend_Resume_Validation"
RES_FILE="./$TESTNAME.res"
ethv_failure_diagnostics_init "$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$/failure_diagnostics"

test_path="$(find_test_case_by_name "$TESTNAME")"

if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

RESULT_TABLE="./$TESTNAME.results.tsv"
RTCWAKE_LOG="./rtcwake.log"
DMESG_DIR="./dmesg"

ETH_SUSPEND_ENABLE="${ETH_SUSPEND_ENABLE:-0}"
ETH_SUSPEND_INTERFACE="${ETH_SUSPEND_INTERFACE:-}"
ETH_SUSPEND_SECONDS="${ETH_SUSPEND_SECONDS:-30}"
ETH_SUSPEND_MODE="${ETH_SUSPEND_MODE:-mem}"
ETH_RTC_DEVICE="${ETH_RTC_DEVICE:-/dev/rtc0}"
ETH_RESUME_TIMEOUT_S="${ETH_RESUME_TIMEOUT_S:-30}"
LINK_TIMEOUT_S="${LINK_TIMEOUT_S:-10}"
IP_TIMEOUT_S="${IP_TIMEOUT_S:-20}"
PING_TARGET="${PING_TARGET:-}"
PING_COUNT="${PING_COUNT:-5}"
PING_WAIT_S="${PING_WAIT_S:-2}"

usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --enable 0|1" \
        "  --interface IFACE" \
        "  --suspend-seconds SECONDS" \
        "  --suspend-mode MODE" \
        "  --rtc-device PATH" \
        "  --resume-timeout SECONDS" \
        "  --link-timeout SECONDS" \
        "  --ip-timeout SECONDS" \
        "  --ping-target ADDRESS" \
        "  --ping-count COUNT" \
        "  --ping-wait SECONDS" \
        "  -h, --help" \
        "CLI options override environment variables."
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --enable)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_SUSPEND_ENABLE="$2"
            shift 2
            ;;
        --interface)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_SUSPEND_INTERFACE="$2"
            shift 2
            ;;
        --suspend-seconds)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_SUSPEND_SECONDS="$2"
            shift 2
            ;;
        --suspend-mode)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_SUSPEND_MODE="$2"
            shift 2
            ;;
        --rtc-device)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_RTC_DEVICE="$2"
            shift 2
            ;;
        --resume-timeout)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            ETH_RESUME_TIMEOUT_S="$2"
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

rm -f "$RES_FILE" "$RESULT_TABLE" "$RTCWAKE_LOG"
mkdir -p "$DMESG_DIR"
: >"$RESULT_TABLE"

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Configuration: enable=$ETH_SUSPEND_ENABLE interface=${ETH_SUSPEND_INTERFACE:-auto} mode=$ETH_SUSPEND_MODE duration=${ETH_SUSPEND_SECONDS}s rtc=$ETH_RTC_DEVICE resume_timeout=${ETH_RESUME_TIMEOUT_S}s"

if ! ethv_is_boolean "$ETH_SUSPEND_ENABLE"; then
    log_fail "$TESTNAME FAIL: ETH_SUSPEND_ENABLE must be 0 or 1"
    ethv_failure_diagnostics "$TESTNAME failure"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ "$ETH_SUSPEND_ENABLE" != "1" ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "Ethernet suspend/resume" \
        "SKIP" \
        "disabled by default, set ETH_SUSPEND_ENABLE=1 on a serial-controlled or otherwise recoverable target"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Suspend/Resume Summary"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies \
    ip \
    ping \
    rtcwake \
    awk \
    sed \
    grep \
    cat \
    sleep \
    sync \
    id \
    wc; then

    log_skip "$TESTNAME SKIP: missing runtime dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

for value in \
    "$ETH_SUSPEND_SECONDS" \
    "$ETH_RESUME_TIMEOUT_S" \
    "$LINK_TIMEOUT_S" \
    "$IP_TIMEOUT_S" \
    "$PING_COUNT" \
    "$PING_WAIT_S"; do

    if ! ethv_is_positive_integer "$value"; then
        log_fail "$TESTNAME FAIL: timeout, duration, and ping values must be positive integers"
        ethv_failure_diagnostics "$TESTNAME failure"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
done

if [ "$(id -u)" -ne 0 ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "Suspend privilege" \
        "SKIP" \
        "root privilege is required for rtcwake suspend"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Suspend/Resume Summary"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ ! -e "$ETH_RTC_DEVICE" ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "RTC wake source" \
        "SKIP" \
        "RTC device not found: $ETH_RTC_DEVICE"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Suspend/Resume Summary"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ -n "$ETH_SUSPEND_INTERFACE" ]; then
    ETH_IFACE="$ETH_SUSPEND_INTERFACE"
else
    ETH_IFACE="$(ethv_get_physical_interfaces | sed -n '1p')"
fi

if [ -z "$ETH_IFACE" ] || [ ! -d "/sys/class/net/$ETH_IFACE" ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "Suspend interface selection" \
        "SKIP" \
        "no valid physical Ethernet interface selected"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Suspend/Resume Summary"
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
            "$ETH_IFACE pre-suspend readiness" \
            "FAIL" \
            "interface could not be brought up"
        ;;
    2)
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE pre-suspend readiness" \
            "SKIP" \
            "no carrier or link partner detected"
        ;;
    3)
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE pre-suspend readiness" \
            "SKIP" \
            "no valid IPv4 address available"
        ;;
esac

if [ "$prepare_rc" -ne 0 ]; then
    OVERALL_RESULT="$(ethv_compute_overall_result "$RESULT_TABLE")"
    ethv_print_summary "$RESULT_TABLE" "Ethernet Suspend/Resume Summary"

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

BEFORE_DRIVER="$(ethv_get_driver "$ETH_IFACE")"
BEFORE_DEVICE="$(ethv_get_device_path "$ETH_IFACE")"
BEFORE_IP="$(ethv_get_ipv4 "$ETH_IFACE")"
BEFORE_CARRIER="$(ethv_get_carrier "$ETH_IFACE")"
BEFORE_SPEED="$(ethv_get_speed "$ETH_IFACE")"
BEFORE_RX_PACKETS="$(ethv_get_counter "$ETH_IFACE" rx_packets)"
BEFORE_TX_PACKETS="$(ethv_get_counter "$ETH_IFACE" tx_packets)"
TARGET="$(ethv_select_ping_target "$ETH_IFACE" "$PING_TARGET")"

ethv_record_result \
    "$RESULT_TABLE" \
    "$ETH_IFACE pre-suspend readiness" \
    "PASS" \
    "driver=${BEFORE_DRIVER:-unknown} ip=$BEFORE_IP carrier=$BEFORE_CARRIER speed=${BEFORE_SPEED:-unknown}Mb/s target=$TARGET"

log_info "Suspending target using: rtcwake -d $ETH_RTC_DEVICE -m $ETH_SUSPEND_MODE -s $ETH_SUSPEND_SECONDS"
sync

rtcwake \
    -d "$ETH_RTC_DEVICE" \
    -m "$ETH_SUSPEND_MODE" \
    -s "$ETH_SUSPEND_SECONDS" \
    >"$RTCWAKE_LOG" 2>&1

RTCWAKE_RC=$?

while IFS= read -r line; do
    [ -n "$line" ] && log_info "[rtcwake] $line"
done <"$RTCWAKE_LOG"

if [ "$RTCWAKE_RC" -ne 0 ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "System suspend/resume" \
        "FAIL" \
        "rtcwake failed with rc=$RTCWAKE_RC"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Suspend/Resume Summary"
    ethv_failure_diagnostics "$TESTNAME failure"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

ethv_record_result \
    "$RESULT_TABLE" \
    "System suspend/resume" \
    "PASS" \
    "rtcwake returned after ${ETH_SUSPEND_SECONDS}s suspend interval"

if [ ! -d "/sys/class/net/$ETH_IFACE" ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "$ETH_IFACE post-resume enumeration" \
        "FAIL" \
        "interface disappeared after resume"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Suspend/Resume Summary"
    ethv_failure_diagnostics "$TESTNAME failure"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

AFTER_DRIVER="$(ethv_get_driver "$ETH_IFACE")"
AFTER_DEVICE="$(ethv_get_device_path "$ETH_IFACE")"

if [ "$BEFORE_DRIVER" = "$AFTER_DRIVER" ] && \
   [ "$BEFORE_DEVICE" = "$AFTER_DEVICE" ]; then

    ethv_record_result \
        "$RESULT_TABLE" \
        "$ETH_IFACE post-resume binding" \
        "PASS" \
        "driver=${AFTER_DRIVER:-unknown} device=${AFTER_DEVICE:-unknown}"
else
    ethv_record_result \
        "$RESULT_TABLE" \
        "$ETH_IFACE post-resume binding" \
        "FAIL" \
        "before_driver=${BEFORE_DRIVER:-unknown} after_driver=${AFTER_DRIVER:-unknown} before_device=${BEFORE_DEVICE:-unknown} after_device=${AFTER_DEVICE:-unknown}"
fi

POST_LINK_TIMEOUT="$ETH_RESUME_TIMEOUT_S"
POST_IP_TIMEOUT="$ETH_RESUME_TIMEOUT_S"

ethv_prepare_interface "$ETH_IFACE" "$POST_LINK_TIMEOUT" "$POST_IP_TIMEOUT"
resume_rc=$?

case "$resume_rc" in
    0)
        AFTER_IP="$(ethv_get_ipv4 "$ETH_IFACE")"
        AFTER_CARRIER="$(ethv_get_carrier "$ETH_IFACE")"
        AFTER_SPEED="$(ethv_get_speed "$ETH_IFACE")"

        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE post-resume readiness" \
            "PASS" \
            "ip=$AFTER_IP carrier=$AFTER_CARRIER speed=${AFTER_SPEED:-unknown}Mb/s"
        ;;
    1)
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE post-resume readiness" \
            "FAIL" \
            "interface could not be brought administratively up after resume"
        ;;
    2)
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE post-resume readiness" \
            "FAIL" \
            "carrier did not recover within ${ETH_RESUME_TIMEOUT_S}s"
        ;;
    3)
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE post-resume readiness" \
            "FAIL" \
            "IPv4 did not recover within ${ETH_RESUME_TIMEOUT_S}s"
        ;;
esac

if [ "$resume_rc" -eq 0 ]; then
    if ethv_ping_interface "$ETH_IFACE" "$TARGET" "$PING_COUNT" "$PING_WAIT_S"; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE post-resume connectivity" \
            "PASS" \
            "ping to $TARGET succeeded"
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$ETH_IFACE post-resume connectivity" \
            "FAIL" \
            "ping to $TARGET failed"
    fi
fi

AFTER_RX_PACKETS="$(ethv_get_counter "$ETH_IFACE" rx_packets)"
AFTER_TX_PACKETS="$(ethv_get_counter "$ETH_IFACE" tx_packets)"

ethv_record_result \
    "$RESULT_TABLE" \
    "$ETH_IFACE post-resume statistics" \
    "PASS" \
    "rx_packets_before=$BEFORE_RX_PACKETS rx_packets_after=$AFTER_RX_PACKETS tx_packets_before=$BEFORE_TX_PACKETS tx_packets_after=$AFTER_TX_PACKETS"

scan_dmesg_errors \
    "$DMESG_DIR" \
    "ethqos|stmmac|dwmac|gmac|emac|phylink|mdio|sgmii|hsgmii|2500base|rgmii|phy" \
    "Link is Down|Link down|carrier lost|no carrier|Network is down"
DMESG_SCAN_RC=$?

if [ ! -s "$DMESG_DIR/dmesg_snapshot.log" ]; then
    ethv_record_result \
        "$RESULT_TABLE" \
        "$ETH_IFACE post-resume kernel log" \
        "SKIP" \
        "kernel log is unavailable or empty, retained $DMESG_DIR/dmesg_snapshot.log"
elif [ "$DMESG_SCAN_RC" -eq 0 ]; then

    ethv_record_result \
        "$RESULT_TABLE" \
        "$ETH_IFACE post-resume kernel log" \
        "FAIL" \
        "Ethernet-related failure messages detected after resume, see $DMESG_DIR/dmesg_errors.log"
else
    ethv_record_result \
        "$RESULT_TABLE" \
        "$ETH_IFACE post-resume kernel log" \
        "PASS" \
        "no Ethernet-related failure messages detected in $DMESG_DIR/dmesg_snapshot.log"
fi

OVERALL_RESULT="$(ethv_compute_overall_result "$RESULT_TABLE")"

ethv_print_summary "$RESULT_TABLE" "Ethernet Suspend/Resume Summary"

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
