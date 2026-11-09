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
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0

SUMMARY_FILE="./$TESTNAME.summary"
RESULT_TABLE="./$TESTNAME.results.tsv"

LINK_TIMEOUT_S="${LINK_TIMEOUT_S:-10}"
IP_TIMEOUT_S="${IP_TIMEOUT_S:-15}"
ETH_INTERFACE="${ETH_INTERFACE:-}"
PING_TARGET="${PING_TARGET:-8.8.8.8}"
PING_COUNT="${PING_COUNT:-4}"
PING_WAIT_S="${PING_WAIT_S:-2}"
PING_RETRIES="${PING_RETRIES:-3}"

# usage
# Print supported options and the ping-target default to stdout. Returns 0.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --link-timeout SECONDS" \
        "  --ip-timeout SECONDS" \
        "  --interface IFACE" \
        "  --ping-target ADDRESS (default: PING_TARGET or 8.8.8.8)" \
        "  --ping-count COUNT" \
        "  --ping-wait SECONDS" \
        "  --ping-retries COUNT" \
        "  -h, --help" \
        "CLI options override environment variables."
}

# parse_args [OPTIONS...]
# Apply CLI overrides to suite settings. Empty ping-target values preserve the
# environment/default target. No stdout except help, exits 2 on invalid options.
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
            if [ -n "$2" ]; then
                PING_TARGET="$2"
            fi
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

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies \
    ip ping awk sed grep cat sleep tr mkdir mktemp date rm readlink cp wc; then

    log_skip "$TESTNAME SKIP: missing runtime dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

rm -f "$SUMMARY_FILE" "$RESULT_TABLE"
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || test_result_finish FAIL "Cannot create Ethernet evidence in CWD"
STATE_FILE="$OUT_DIR/interface-state.log"
: >"$STATE_FILE"

# cleanup
# Restore only selected interfaces and settings captured before preparation.
cleanup() {
    eth_cleanup_failed=0
    while IFS='|' read -r saved_iface saved_admin saved_autoneg saved_speed saved_duplex; do
        [ -n "$saved_iface" ] || continue
        if [ "$saved_autoneg" = on ] || [ "$saved_autoneg" = off ]; then
            current_autoneg=$(ethGetAutonegState "$saved_iface" 2>/dev/null || true)
            current_speed=$(ethv_get_speed "$saved_iface")
            current_duplex=$(ethv_get_duplex "$saved_iface")
            if [ "$current_autoneg" != "$saved_autoneg" ] ||
               { [ "$saved_autoneg" = off ] && { [ "$current_speed" != "$saved_speed" ] || [ "$current_duplex" != "$saved_duplex" ]; }; }; then
                if [ "$saved_autoneg" = on ]; then
                    run_with_managed_timeout 5 "$PWD" ethernet-restore ethtool -s "$saved_iface" autoneg on || eth_cleanup_failed=1
                elif ethv_is_positive_integer "$saved_speed" && { [ "$saved_duplex" = full ] || [ "$saved_duplex" = half ]; }; then
                    run_with_managed_timeout 5 "$PWD" ethernet-restore ethtool -s "$saved_iface" speed "$saved_speed" duplex "$saved_duplex" autoneg off || eth_cleanup_failed=1
                else
                    eth_cleanup_failed=1
                fi
            fi
            [ "$(ethGetAutonegState "$saved_iface" 2>/dev/null)" = "$saved_autoneg" ] || eth_cleanup_failed=1
            if [ "$saved_autoneg" = off ] && ethv_is_positive_integer "$saved_speed"; then
                [ "$(ethv_get_speed "$saved_iface")" = "$saved_speed" ] || eth_cleanup_failed=1
                [ "$(ethv_get_duplex "$saved_iface")" = "$saved_duplex" ] || eth_cleanup_failed=1
            fi
        fi
        net_restore_interface_admin "$saved_iface" "$saved_admin" || eth_cleanup_failed=1
    done <"$STATE_FILE"
    if [ "$eth_cleanup_failed" -ne 0 ]; then
        log_fail "Ethernet initial state restoration failed"
        printf '%s FAIL\n' "$TESTNAME" >"$RES_FILE"
        return 1
    fi
}
# shellcheck disable=SC2034 # Consumed by shared finalization.
TEST_RESULT_CLEANUP=cleanup
trap cleanup 0
trap 'test_result_finish FAIL "Ethernet validation interrupted"' HUP INT TERM
: >"$SUMMARY_FILE"
: >"$RESULT_TABLE"

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Configuration: interface=${ETH_INTERFACE:-auto} LINK_TIMEOUT_S=$LINK_TIMEOUT_S IP_TIMEOUT_S=$IP_TIMEOUT_S PING_TARGET=$PING_TARGET PING_COUNT=$PING_COUNT PING_WAIT_S=$PING_WAIT_S PING_RETRIES=$PING_RETRIES"


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

for iface in $ETH_IFACES; do
    if [ ! -d "/sys/class/net/$iface" ]; then
        ethv_record_result "$RESULT_TABLE" "$iface presence" FAIL "Requested interface is absent"
        continue
    fi
    initial_admin=$(net_interface_admin_state "$iface") || {
        ethv_record_result "$RESULT_TABLE" "$iface state snapshot" FAIL "Cannot read interface flags before mutation"
        continue
    }
    initial_autoneg=$(ethGetAutonegState "$iface" 2>/dev/null || true)
    initial_speed=$(ethv_get_speed "$iface")
    initial_duplex=$(ethv_get_duplex "$iface")
    printf '%s|%s|%s|%s|%s\n' "$iface" "$initial_admin" "$initial_autoneg" "$initial_speed" "$initial_duplex" >>"$STATE_FILE"
    # shellcheck disable=SC2034 # Consumed by ethv_prepare_interface.
    # shellcheck disable=SC2034 # Public result consumed by another script.
    ETHV_PRESERVE_LINK_SETTINGS=0
    case "$initial_autoneg" in
        on)
            ;;
        off)
            if ! ethv_is_positive_integer "$initial_speed" || { [ "$initial_duplex" != full ] && [ "$initial_duplex" != half ]; }; then
                # shellcheck disable=SC2034 # Public result consumed by another script.
                ETHV_PRESERVE_LINK_SETTINGS=1
            fi
            ;;
        *)
            # shellcheck disable=SC2034 # Public result consumed by another script.
            ETHV_PRESERVE_LINK_SETTINGS=1
            ;;
    esac
    driver="$(ethv_get_driver "$iface")"
    carrier="$(ethv_get_carrier "$iface")"
    operstate="$(ethv_get_operstate "$iface")"

    ethv_record_result \
        "$RESULT_TABLE" \
        "$iface interface presence" \
        "SKIP" \
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
            else
                ethv_record_result \
                    "$RESULT_TABLE" \
                    "$iface connectivity" \
                    "FAIL" \
                    "ping to $target failed after $PING_RETRIES attempt(s)"

                echo "$iface: FAIL (IP: $ip_addr, target: $target, ping failed)" >>"$SUMMARY_FILE"
                ethv_capture_failure "$iface" "$OUT_DIR/$iface"
            fi
            ;;
        1)
            ethv_record_result \
                "$RESULT_TABLE" \
                "$iface link and IPv4" \
                "FAIL" \
                "unable to bring the interface administratively up"

            echo "$iface: FAIL (interface bring-up failed)" >>"$SUMMARY_FILE"
            ethv_capture_failure "$iface" "$OUT_DIR/$iface"
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

if ! cleanup; then
    ethv_record_result "$RESULT_TABLE" "Initial state restoration" FAIL "See restoration diagnostics"
fi
overall=$(ethv_compute_overall_result "$RESULT_TABLE")
test_result_finish "$overall" "Ethernet result=$overall, per-interface evidence=$OUT_DIR"
