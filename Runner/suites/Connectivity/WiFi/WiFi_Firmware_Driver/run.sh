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
. "$TOOLS/lib_connectivity.sh"

TESTNAME="WiFi_Firmware_Driver"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
WIFI_READY_TIMEOUT=60

usage() {
    echo "Usage: $0 [--wait-timeout SECONDS]"
    echo "Wait for each discovered WiFi family to register a PHY, default 60 seconds."
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --wait-timeout)
                if [ "$#" -lt 2 ]; then
                    log_error "--wait-timeout requires a value in seconds"
                    return 1
                fi
                WIFI_READY_TIMEOUT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                return 1
                ;;
        esac
    done
    if ! is_unsigned_number "$WIFI_READY_TIMEOUT" ||
       ! [ "$WIFI_READY_TIMEOUT" -gt 0 ] 2>/dev/null ||
       ! [ "$WIFI_READY_TIMEOUT" -le 3600 ] 2>/dev/null; then
        log_error "--wait-timeout must be a whole number from 1 to 3600 seconds"
        return 1
    fi
}

if ! parse_args "$@"; then
    test_result_finish FAIL "Invalid WiFi readiness options"
fi
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! check_dependencies find grep cat stat awk readlink sort mktemp tr; then
    test_result_finish SKIP "Image lacks utilities required for WiFi runtime discovery"
fi
RESULT_DIR=$(mktemp -d "$PWD/wifi-firmware.XXXXXX") || test_result_finish FAIL "Cannot create WiFi evidence directory in CWD"
WIFI_FW_PROBE_LOG_DIR="${WIFI_FW_PROBE_LOG_DIR:-$RESULT_DIR}"
WIFI_FW_PROBE_LOG_TAG="${WIFI_FW_PROBE_LOG_TAG:-WiFi_Firmware_Driver/probe}"
WIFI_FW_LOAD_LOG_TAG="${WIFI_FW_LOAD_LOG_TAG:-WiFi_Firmware_Driver/firmware}"
WIFI_HEALTH_UNVERIFIED=0
wifi_has_probe_failures "$WIFI_FW_PROBE_LOG_DIR/initial" "$WIFI_FW_PROBE_LOG_TAG" initial
probe_rc=$?
case "$probe_rc" in
    0)
        wifi_dump_runtime_info "$RESULT_DIR/runtime" || true
        test_result_finish FAIL "WiFi driver probe/runtime errors captured in $WIFI_FW_PROBE_LOG_DIR/initial"
        ;;
    2)
        WIFI_HEALTH_UNVERIFIED=1
        test_result_record SKIP "Initial WiFi kernel health is unverified, inspect capture diagnostics"
        ;;
esac
if ! wifi_families=$(wifi_runtime_families); then
    test_result_finish FAIL "WiFi runtime discovery did not complete within its budget"
fi
wifi_families=$(printf '%s\n' "$wifi_families" | sort -u)
if [ -z "$wifi_families" ]; then
    if [ -s "$WIFI_FW_PROBE_LOG_DIR/initial/wifi_fallbacks.log" ]; then
        wifi_dump_runtime_info "$RESULT_DIR/runtime" || true
        test_result_finish FAIL "WiFi boot fallback has no matching runtime driver or PHY"
    fi
    test_result_finish SKIP "No supported WiFi family identified from runtime drivers or device modaliases, firmware directories alone do not identify hardware"
fi
for wifi_family in $wifi_families; do
    log_info "Runtime WiFi family: $wifi_family"
    if ! wifi_detect_firmware_info "$wifi_family"; then
        test_result_record FAIL "Runtime family $wifi_family has no runtime consumed-firmware evidence or readable image firmware candidate"
        continue
    fi
    log_info "Firmware evidence=${WIFI_FW_EVIDENCE:-asset} path=$WIFI_FW_FILE size=$WIFI_FW_SIZE"
    if ! wifi_handle_firmware_family "$wifi_family" "$WIFI_FW_BASENAME"; then
        test_result_record FAIL "Cannot prepare runtime WiFi driver for $wifi_family"
        continue
    fi
    if wifi_firmware_loaded "$wifi_family" "$WIFI_FW_LOAD_LOG_TAG" "$WIFI_READY_TIMEOUT" && wifi_verify_family_modules "$wifi_family"; then
        test_result_record PASS "WiFi $wifi_family driver has a registered wireless PHY"
    else
        test_result_record FAIL "WiFi $wifi_family has no bound wireless PHY, inspect firmware and driver initialization"
    fi
done
# Validate retained boot candidates even if preparation changed the ring buffer.
wifi_classify_probe_failures "$WIFI_FW_PROBE_LOG_DIR/initial"
probe_rc=$?
case "$probe_rc" in
    0)
        test_result_record FAIL "Retained WiFi boot errors or fallback readiness failed"
        ;;
    2)
        WIFI_HEALTH_UNVERIFIED=1
        ;;
esac
wifi_has_probe_failures "$WIFI_FW_PROBE_LOG_DIR/final" "$WIFI_FW_PROBE_LOG_TAG"
probe_rc=$?
case "$probe_rc" in
    0)
        test_result_record FAIL "WiFi probe/runtime errors found after driver validation"
        ;;
    2)
        WIFI_HEALTH_UNVERIFIED=1
        test_result_record SKIP "Final WiFi kernel health is unverified, inspect capture diagnostics"
        ;;
esac
if [ "$TEST_RESULT_FAIL_COUNT" -gt 0 ] || [ "$WIFI_HEALTH_UNVERIFIED" -eq 1 ]; then
    wifi_dump_runtime_info "$RESULT_DIR/runtime" || true
fi
if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$WIFI_HEALTH_UNVERIFIED" -eq 1 ]; then
    test_result_finish SKIP "WiFi driver checks completed but required kernel or fallback health evidence is unavailable"
fi
test_result_finish
