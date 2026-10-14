#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Basic Ethernet link, IPv4, and connectivity validation.

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

TESTNAME="Ethernet_Basic_Validation"
RES_FILE="./$TESTNAME.res"

test_path="$(find_test_case_by_name "$TESTNAME")"

if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

SUMMARY_FILE="./$TESTNAME.summary"
RESULT_TABLE="./$TESTNAME.results.tsv"

LINK_TIMEOUT_S="${LINK_TIMEOUT_S:-10}"
IP_TIMEOUT_S="${IP_TIMEOUT_S:-15}"
ETH_INTERFACE="${ETH_INTERFACE:-}"
PING_TARGET="${PING_TARGET:-}"
PING_COUNT="${PING_COUNT:-4}"
PING_WAIT_S="${PING_WAIT_S:-2}"
PING_RETRIES="${PING_RETRIES:-3}"

usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --link-timeout SECONDS" \
        "  --ip-timeout SECONDS" \
        "  --interface IFACE" \
        "  --ping-target ADDRESS" \
        "  --ping-count COUNT" \
        "  --ping-wait SECONDS" \
        "  --ping-retries COUNT" \
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
        --ping-retries)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            PING_RETRIES="$2"
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

rm -f "$RES_FILE" "$SUMMARY_FILE" "$RESULT_TABLE"
: >"$SUMMARY_FILE"
: >"$RESULT_TABLE"

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Configuration: interface=${ETH_INTERFACE:-auto} LINK_TIMEOUT_S=$LINK_TIMEOUT_S IP_TIMEOUT_S=$IP_TIMEOUT_S PING_TARGET=${PING_TARGET:-auto} PING_COUNT=$PING_COUNT PING_WAIT_S=$PING_WAIT_S PING_RETRIES=$PING_RETRIES"

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

if ! ethv_is_positive_integer "$LINK_TIMEOUT_S" \
   || ! ethv_is_positive_integer "$IP_TIMEOUT_S" \
   || ! ethv_is_positive_integer "$PING_COUNT" \
   || ! ethv_is_positive_integer "$PING_WAIT_S" \
   || ! ethv_is_positive_integer "$PING_RETRIES"; then

    log_fail "$TESTNAME FAIL: timeout, count, and retry values must be positive integers"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ -n "$ETH_INTERFACE" ]; then
    ETH_IFACES="$ETH_INTERFACE"
else
    ETH_IFACES="$(ethv_get_physical_interfaces)"
fi

if [ -z "$ETH_IFACES" ]; then
    log_skip "No physical Ethernet interfaces detected"
    echo "No physical Ethernet interfaces detected." >"$SUMMARY_FILE"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_info "Detected Ethernet interfaces: $(printf '%s' "$ETH_IFACES" | tr '\n' ' ')"

ANY_PASS=0
ANY_FAIL=0
ANY_TESTED=0

for iface in $ETH_IFACES; do
    driver="$(ethv_get_driver "$iface")"
    carrier="$(ethv_get_carrier "$iface")"
    operstate="$(ethv_get_operstate "$iface")"

    ethv_record_result \
        "$RESULT_TABLE" \
        "$iface interface presence" \
        "PASS" \
        "driver=${driver:-unknown} carrier=$carrier operstate=$operstate"

    log_info "---- Testing interface: $iface ----"

    ethv_prepare_interface "$iface" "$LINK_TIMEOUT_S" "$IP_TIMEOUT_S"
    prepare_rc=$?

    case "$prepare_rc" in
        0)
            ip_addr="$(ethv_get_ipv4 "$iface")"
            speed="$(ethv_get_speed "$iface")"
            duplex="$(ethv_get_duplex "$iface")"
            target="$(ethv_select_ping_target "$iface" "$PING_TARGET")"

            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface link and IPv4" \
                "PASS" \
                "ip=$ip_addr speed=${speed:-unknown}Mb/s duplex=${duplex:-unknown}"

            ANY_TESTED=1
            attempt=1
            ping_ok=0

            while [ "$attempt" -le "$PING_RETRIES" ]; do
                log_info "$iface ping attempt $attempt/$PING_RETRIES: target=$target"

                if ethv_ping_interface \
                    "$iface" \
                    "$target" \
                    "$PING_COUNT" \
                    "$PING_WAIT_S"; then

                    ping_ok=1
                    break
                fi

                attempt=$((attempt + 1))
                [ "$attempt" -le "$PING_RETRIES" ] && sleep 1
            done

            if [ "$ping_ok" -eq 1 ]; then
                ethv_record_result \
                    "$RESULT_TABLE" \
                    "$iface connectivity" \
                    "PASS" \
                    "ping to $target succeeded from $ip_addr"

                echo "$iface: PASS (IP: $ip_addr, target: $target, ping OK)" >>"$SUMMARY_FILE"
                ANY_PASS=1
            else
                ethv_record_result \
                    "$RESULT_TABLE" \
                    "$iface connectivity" \
                    "FAIL" \
                    "ping to $target failed after $PING_RETRIES attempt(s)"

                echo "$iface: FAIL (IP: $ip_addr, target: $target, ping failed)" >>"$SUMMARY_FILE"
                ANY_FAIL=1
            fi
            ;;
        1)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface link and IPv4" \
                "FAIL" \
                "unable to bring the interface administratively up"

            echo "$iface: FAIL (interface bring-up failed)" >>"$SUMMARY_FILE"
            ANY_FAIL=1
            ANY_TESTED=1
            ;;
        2)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface link and IPv4" \
                "SKIP" \
                "no carrier or link partner detected"

            echo "$iface: SKIP (no cable/link)" >>"$SUMMARY_FILE"
            ;;
        3)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface link and IPv4" \
                "SKIP" \
                "carrier is present but no valid non-link-local IPv4 was obtained"

            echo "$iface: SKIP (no valid IPv4)" >>"$SUMMARY_FILE"
            ;;
    esac
done

ethv_print_summary "$RESULT_TABLE" "Ethernet Basic Connectivity Summary"

log_info "Per-interface summary:"
cat "$SUMMARY_FILE"

if [ "$ANY_PASS" -eq 1 ]; then
    log_pass "$TESTNAME PASS"
    echo "$TESTNAME PASS" >"$RES_FILE"
elif [ "$ANY_TESTED" -eq 1 ] || [ "$ANY_FAIL" -eq 1 ]; then
    log_fail "$TESTNAME FAIL"
    echo "$TESTNAME FAIL" >"$RES_FILE"
else
    log_skip "$TESTNAME SKIP"
    echo "$TESTNAME SKIP" >"$RES_FILE"
fi

exit 0
