#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Ethernet link-mode, offload, queue, pause, and timestamp capability validation.

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

TESTNAME="Ethernet_Capability_Validation"
RES_FILE="./$TESTNAME.res"
ethv_failure_diagnostics_init "$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$/failure_diagnostics"

test_path="$(find_test_case_by_name "$TESTNAME")"

if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

RESULT_TABLE="./$TESTNAME.results.tsv"

REQUIRE_FULL_DUPLEX="${REQUIRE_FULL_DUPLEX:-1}"
MIN_LINK_SPEED_MBPS="${MIN_LINK_SPEED_MBPS:-0}"
ETH_INTERFACE="${ETH_INTERFACE:-}"

usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --interface IFACE" \
        "  --require-full-duplex 0|1" \
        "  --min-link-speed MBPS" \
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
        --require-full-duplex)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            REQUIRE_FULL_DUPLEX="$2"
            shift 2
            ;;
        --min-link-speed)
            ethv_require_option_value "$1" "$#" || {
                usage
                exit 2
            }
            MIN_LINK_SPEED_MBPS="$2"
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
log_info "Configuration: interface=${ETH_INTERFACE:-auto} REQUIRE_FULL_DUPLEX=$REQUIRE_FULL_DUPLEX MIN_LINK_SPEED_MBPS=$MIN_LINK_SPEED_MBPS"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies \
    ip \
    ethtool \
    awk \
    sed \
    grep \
    cat \
    find; then

    log_skip "$TESTNAME SKIP: missing runtime dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if ! ethv_is_boolean "$REQUIRE_FULL_DUPLEX" \
   || ! ethv_is_uint "$MIN_LINK_SPEED_MBPS"; then

    log_fail "$TESTNAME FAIL: invalid configuration"
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
        "Ethernet capability inventory" \
        "SKIP" \
        "no physical Ethernet interfaces detected"

    ethv_print_summary "$RESULT_TABLE" "Ethernet Capability Summary"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

for iface in $ETH_IFACES; do
    ethv_failure_diagnostics_watch "$iface"
    driver="$(ethv_get_driver "$iface")"
    carrier="$(ethv_get_carrier "$iface")"
    speed="$(ethv_get_speed "$iface")"
    duplex="$(ethv_get_duplex "$iface")"

    log_info "---- Capability validation for $iface ----"

    if ethtool -i "$iface" >/dev/null 2>&1; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface driver query" \
            "PASS" \
            "driver=${driver:-unknown}"

        ethtool -i "$iface" 2>&1 \
            | while IFS= read -r line; do
                [ -n "$line" ] && log_info "[$iface driver] $line"
            done
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface driver query" \
            "FAIL" \
            "ethtool -i failed"
    fi

    if ethtool "$iface" >/dev/null 2>&1; then
        supported_modes="$(
            ethtool "$iface" 2>/dev/null \
                | sed -n '/Supported link modes:/,/Supported pause frame use:/p' \
                | tr '\n' ' ' \
                | sed 's/[[:space:]][[:space:]]*/ /g'
        )"

        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface link capabilities" \
            "PASS" \
            "${supported_modes:-ethtool link query succeeded}"

        ethtool "$iface" 2>&1 \
            | while IFS= read -r line; do
                [ -n "$line" ] && log_info "[$iface link] $line"
            done
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface link capabilities" \
            "FAIL" \
            "base ethtool query failed"
    fi

    if ethtool -k "$iface" >/dev/null 2>&1; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface offload features" \
            "PASS" \
            "ethtool feature query succeeded"

        ethtool -k "$iface" 2>&1 \
            | while IFS= read -r line; do
                [ -n "$line" ] && log_info "[$iface features] $line"
            done
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface offload features" \
            "FAIL" \
            "ethtool -k failed"
    fi

    stats_prefix="$SCRIPT_DIR/results/$TESTNAME/driver-$$/$iface"
    if ethv_capture_driver_statistics "$iface" "$stats_prefix"; then
        stat_count="$(wc -l <"$stats_prefix.tsv" | tr -d '[:space:]')"

        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface driver statistics" \
            "PASS" \
            "$stat_count driver statistic(s) exposed, artifact=$stats_prefix.tsv"
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface driver statistics" \
            "SKIP" \
            "$ETHV_DRIVER_STATS_REASON"
    fi

    if ethtool -a "$iface" >/dev/null 2>&1; then
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface pause capability" \
            "PASS" \
            "pause parameters are queryable"

        ethtool -a "$iface" 2>&1 \
            | while IFS= read -r line; do
                [ -n "$line" ] && log_info "[$iface pause] $line"
            done
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface pause capability" \
            "SKIP" \
            "pause parameters are not supported"
    fi

    if ethtool -T "$iface" >/dev/null 2>&1; then
        ptp_clock="$(ethv_get_ptp_clock "$iface")"
        hw_timestamp=0

        if ethtool -T "$iface" 2>/dev/null \
            | grep -qE 'hardware-transmit|hardware-receive|hardware-raw-clock'; then
            hw_timestamp=1
        fi

        if [ "$hw_timestamp" -eq 1 ]; then
            case "$ptp_clock" in
                ""|"none"|"-1")
                    ethv_record_result \
                        "$RESULT_TABLE" \
                        "$iface hardware timestamping" \
                        "SKIP" \
                        "hardware timestamping is advertised but no PTP hardware clock is exposed"
                    ;;
                *)
                    ethv_record_result \
                        "$RESULT_TABLE" \
                        "$iface hardware timestamping" \
                        "PASS" \
                        "PTP hardware clock=$ptp_clock"
                    ;;
            esac
        else
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface hardware timestamping" \
                "SKIP" \
                "hardware timestamping is not advertised"
        fi

        ethtool -T "$iface" 2>&1 \
            | while IFS= read -r line; do
                [ -n "$line" ] && log_info "[$iface timestamp] $line"
            done
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface timestamp capability" \
            "SKIP" \
            "timestamp query is not supported"
    fi

    for capability in channels rings coalesce eee private-flags; do
        case "$capability" in
            channels)
                capability_option="-l"
                ;;
            rings)
                capability_option="-g"
                ;;
            coalesce)
                capability_option="-c"
                ;;
            eee)
                capability_option="--show-eee"
                ;;
            private-flags)
                capability_option="--show-priv-flags"
                ;;
        esac

        if ethtool "$capability_option" "$iface" >/dev/null 2>&1; then
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface $capability capability" \
                "PASS" \
                "query supported"
        else
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface $capability capability" \
                "SKIP" \
                "query not supported by this driver"
        fi
    done

    if [ "$carrier" = "1" ]; then
        if ethv_is_uint "$speed" && [ "$speed" -gt 0 ]; then
            if [ "$MIN_LINK_SPEED_MBPS" -gt 0 ] && \
               [ "$speed" -lt "$MIN_LINK_SPEED_MBPS" ]; then

                ethv_record_result \
                    "$RESULT_TABLE" \
                    "$iface negotiated speed" \
                    "FAIL" \
                    "speed=${speed}Mb/s below required ${MIN_LINK_SPEED_MBPS}Mb/s"
            else
                ethv_record_result \
                    "$RESULT_TABLE" \
                    "$iface negotiated speed" \
                    "PASS" \
                    "speed=${speed}Mb/s"
            fi
        else
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface negotiated speed" \
                "FAIL" \
                "carrier is present but negotiated speed is unavailable"
        fi

        if [ "$REQUIRE_FULL_DUPLEX" = "1" ]; then
            case "$duplex" in
                full|Full|FULL)
                    ethv_record_result \
                        "$RESULT_TABLE" \
                        "$iface negotiated duplex" \
                        "PASS" \
                        "full duplex"
                    ;;
                *)
                    ethv_record_result \
                        "$RESULT_TABLE" \
                        "$iface negotiated duplex" \
                        "FAIL" \
                        "expected full duplex, observed ${duplex:-unknown}"
                    ;;
            esac
        else
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface negotiated duplex" \
                "PASS" \
                "duplex=${duplex:-unknown}, strict full-duplex check disabled"
        fi
    else
        ethv_record_result \
            "$RESULT_TABLE" \
            "$iface negotiated link state" \
            "SKIP" \
            "no carrier, speed and duplex requirements were not evaluated"
    fi
done

OVERALL_RESULT="$(ethv_compute_overall_result "$RESULT_TABLE")"

ethv_print_summary "$RESULT_TABLE" "Ethernet Capability Summary"

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
