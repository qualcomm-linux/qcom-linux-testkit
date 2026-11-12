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

TESTNAME="WiFi_OnOff"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0

# usage
# Print the supported options without changing hardware.
usage() {
    printf '%s\n' "Usage: $0 [--help]"
}

# parse_args <arguments...>
# Reject unsupported arguments before test setup.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *)
                test_result_finish FAIL "Unsupported option: $1"
                ;;
        esac
    done
}
parse_args "$@"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies ip iw cat awk readlink sort grep sed tr mkdir mktemp date sleep; then
    test_result_finish SKIP "Image-provided WiFi_OnOff validation utilities are unavailable"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create evidence under CWD=$PWD"
log_info "Evidence: $OUT_DIR"

# shellcheck disable=SC1091
. "$TOOLS/lib_connectivity.sh"
WIFI_STATE_FILE="$OUT_DIR/rfkill-state.log"
wifi_iface=""
wifi_initial_state=""

# cleanup
# Restore original administration/rfkill states, including failure and signals.
cleanup() {
    cleanup_failed=0
    # Stop an interrupted toggle before changing the same interface again.
    if ! managed_timeout_cancel_bounded 2; then
        log_fail "WiFi toggle command is still active, state restoration is deferred"
        printf '%s FAIL\n' "$TESTNAME" >"$RES_FILE"
        return 1
    fi
    if [ -n "$wifi_iface" ] && [ -n "$wifi_initial_state" ]; then
        net_restore_interface_admin "$wifi_iface" "$wifi_initial_state" || cleanup_failed=1
    fi
    radio_restore_rfkill "$WIFI_STATE_FILE" || cleanup_failed=1
    if [ "$cleanup_failed" -ne 0 ]; then
        log_fail "WiFi initial state restoration failed"
        printf '%s FAIL\n' "$TESTNAME" >"$RES_FILE"
        return 1
    fi
}
radio_snapshot_rfkill wlan "$WIFI_STATE_FILE" || test_result_finish FAIL "Cannot snapshot WiFi rfkill state"
# shellcheck disable=SC2034 # Consumed by shared finalization.
TEST_RESULT_CLEANUP=cleanup
trap cleanup 0
trap 'test_result_finish FAIL "WiFi toggle interrupted"' HUP INT TERM
wifi_iface=$(get_wifi_interface || true)
if [ -n "$wifi_iface" ]; then
    wifi_initial_state=$(net_interface_admin_state "$wifi_iface") || test_result_finish FAIL "Cannot read original WiFi interface flags"
fi
wifi_families=$(wifi_runtime_families) || test_result_finish FAIL "WiFi runtime discovery failed"
if [ -z "$wifi_families" ] && [ -z "$wifi_iface" ]; then
    if [ -n "${WIFI_IFACE:-}" ]; then
        test_result_finish FAIL "Requested WiFi interface is unavailable: $WIFI_IFACE"
    fi
    test_result_finish SKIP "No runtime WiFi hardware or driver modalias identifies an applicable device"
fi
# Configuration is supplementary runtime evidence. Definite disabled settings
# fail applicable hardware, unavailable build configuration is reported separately.
wifi_cfgs="CONFIG_WIRELESS CONFIG_WLAN CONFIG_CFG80211 CONFIG_MAC80211 $(infer_wifi_driver_cfgs)"
for wifi_cfg in $wifi_cfgs; do
    wifi_cfg_entry=$(kernel_config_value "$wifi_cfg" || true)
    case "$wifi_cfg_entry" in
        "$wifi_cfg="*)
            wifi_cfg_value=${wifi_cfg_entry#"$wifi_cfg="}
            ;;
        *)
            wifi_cfg_value="unavailable"
            ;;
    esac
    case "$wifi_cfg_value" in
        n|not-set)
            test_result_record FAIL "Applicable WiFi configuration is disabled: $wifi_cfg"
            ;;
        *)
            log_info "$wifi_cfg=${wifi_cfg_value:-unavailable}"
            ;;
    esac
done
# Preserve caller-provided diagnostic patterns and module visibility overrides.
if [ -n "${WIFI_DT_PATTERNS:-}" ]; then
    set --
    while IFS= read -r wifi_pattern; do
        [ -n "$wifi_pattern" ] || continue
        set -- "$@" "$wifi_pattern"
    done <<WIFI_DT_DIAGNOSTICS
$WIFI_DT_PATTERNS
WIFI_DT_DIAGNOSTICS
    wifi_dt_present "$@" || log_warn "Configured WiFi DT patterns did not match enabled hardware"
fi
if [ -n "${WIFI_DRIVER_MODULES:-}" ]; then
    set --
    while IFS= read -r wifi_module; do
        [ -n "$wifi_module" ] || continue
        set -- "$@" "$wifi_module"
    done <<WIFI_MODULE_DIAGNOSTICS
$WIFI_DRIVER_MODULES
WIFI_MODULE_DIAGNOSTICS
    wifi_log_module_info "$@"
fi
WIFI_HEALTH_UNVERIFIED=0
WIFI_INITIAL_LOG_DIR="${WIFI_PROBE_LOG_DIR:-$OUT_DIR/initial}"
wifi_has_probe_failures "$WIFI_INITIAL_LOG_DIR" "${WIFI_PROBE_LOG_TAG:-$TESTNAME}" initial
probe_rc=$?
case "$probe_rc" in
    0)
        wifi_dump_runtime_info "$OUT_DIR/runtime" || true
        test_result_finish FAIL "Captured WiFi probe/runtime errors"
        ;;
    2)
        WIFI_HEALTH_UNVERIFIED=1
        test_result_record SKIP "Initial WiFi kernel health is unverified, inspect capture diagnostics"
        ;;
esac
discovered_iface=$(wait_for_wifi_interface "${WIFI_WAIT_SECS:-60}" "${WIFI_WAIT_STEP_SECS:-2}")
discovery_rc=$?
if [ "$discovery_rc" -eq 3 ]; then
    test_result_finish FAIL "WiFi recovery or module restoration failed"
fi
if [ "$discovery_rc" -ne 0 ] || [ -z "$discovered_iface" ]; then
    wifi_dump_runtime_info "$OUT_DIR/runtime" || true
    test_result_finish FAIL "Applicable WiFi runtime has no usable interface after bounded discovery"
fi
if [ -n "${WIFI_IFACE:-}" ] && [ "$discovered_iface" != "$WIFI_IFACE" ]; then
    test_result_finish FAIL "Discovery did not return the requested WiFi interface"
fi
wifi_iface="$discovered_iface"
if [ -z "$wifi_initial_state" ]; then
    wifi_initial_state=$(net_interface_admin_state "$wifi_iface") || test_result_finish FAIL "Cannot snapshot discovered interface flags"
fi
log_info "Selected WiFi interface=$wifi_iface original_admin=$wifi_initial_state"
# ip is an image prerequisite. Track the executable directly so cancellation
# reaches the netlink operation rather than only a shell-function wrapper.
if ! run_with_managed_timeout 10 "$OUT_DIR" wifi-down ip link set dev "$wifi_iface" down; then
    test_result_record FAIL "Could not bring $wifi_iface down"
elif [ "$(net_interface_admin_state "$wifi_iface")" != down ]; then
    test_result_record FAIL "$wifi_iface did not reach administrative down after a successful command"
elif ! run_with_managed_timeout 10 "$OUT_DIR" wifi-up ip link set dev "$wifi_iface" up; then
    test_result_record FAIL "Could not bring $wifi_iface up after toggle"
elif [ "$(net_interface_admin_state "$wifi_iface")" != up ]; then
    test_result_record FAIL "$wifi_iface did not reach administrative up after a successful command"
else
    test_result_record PASS "$wifi_iface toggled down/up successfully"
fi
wifi_classify_probe_failures "$WIFI_INITIAL_LOG_DIR"
probe_rc=$?
case "$probe_rc" in
    0)
        test_result_record FAIL "Retained WiFi boot errors or fallback readiness failed"
        ;;
    2)
        WIFI_HEALTH_UNVERIFIED=1
        ;;
esac
wifi_has_probe_failures "$OUT_DIR/final" "$TESTNAME"
probe_rc=$?
case "$probe_rc" in
    0)
        test_result_record FAIL "Captured WiFi errors after interface toggle"
        ;;
    2)
        WIFI_HEALTH_UNVERIFIED=1
        test_result_record SKIP "Final kernel health is unverified, inspect capture diagnostics"
        ;;
esac
cleanup || test_result_record FAIL "WiFi restoration was incomplete"
if [ "$TEST_RESULT_FAIL_COUNT" -gt 0 ] || [ "$WIFI_HEALTH_UNVERIFIED" -eq 1 ]; then
    wifi_dump_runtime_info "$OUT_DIR/runtime" || true
fi
if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$WIFI_HEALTH_UNVERIFIED" -eq 1 ]; then
    test_result_finish SKIP "WiFi down/up completed but required kernel or fallback health evidence is unavailable"
fi
test_result_finish
