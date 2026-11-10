#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Probe failure / deferred probe detector using kernel logs + devices_deferred

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
# shellcheck disable=SC1091
. "$TOOLS/lib_bluetooth.sh"

TESTNAME="Probe_Failure_Check"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by the shared dependency helper.
CHECK_DEPS_RECOVER=0
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat grep awk sort wc tr id cp sed date mktemp head; then
    test_result_finish SKIP "Probe inventory tools are absent from the image"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create probe diagnostics under CWD=$PWD"

scan_dmesg_errors "$OUT_DIR" '.*' \
    'dummy regulator|supply [^ ]+ not found|using dummy regulator' || true
LOG_FILE="$OUT_DIR/probe_failures.log"
probe_status=2
if [ "${DMESG_ACCESS_STATUS:-unavailable}" = "available" ]; then
    probe_classify_kernel_failures "$OUT_DIR"
    probe_status=$?
    case "$probe_status" in
        0|1)
            log_file_with_label PROBE-RUNTIME "$OUT_DIR/probe_runtime.tsv" 60
            if [ -s "$OUT_DIR/probe_warnings.log" ]; then
                log_warn "Supported firmware lookup fallbacks have runtime evidence, patched Bluetooth firmware was not verified"
                log_file_with_label PROBE-WARNING "$OUT_DIR/probe_warnings.log" 60
            fi
            ;;
        *)
            test_result_record FAIL "Probe classification could not complete, inspect $OUT_DIR"
            ;;
    esac
else
    test_result_record SKIP "Kernel probe log unavailable, inspect $OUT_DIR/dmesg_access.log"
fi

DEFERRED_FILE="/sys/kernel/debug/devices_deferred"
if [ -r "$DEFERRED_FILE" ]; then
    if ! cat "$DEFERRED_FILE" >"$OUT_DIR/devices_deferred.log"; then
        test_result_record FAIL "Cannot read the runtime deferred-probe list"
    elif [ -s "$OUT_DIR/devices_deferred.log" ]; then
        log_file_with_label DEFERRED-PROBE "$OUT_DIR/devices_deferred.log"
        test_result_record FAIL "DT devices still have unresolved probe suppliers, inspect $OUT_DIR/devices_deferred.log"
    fi
else
    log_info "Deferred-probe debugfs evidence is unavailable, retaining the kernel-log check"
fi
if [ -s "$LOG_FILE" ] || [ -s "$OUT_DIR/probe_warnings.log" ]; then
    if CHECK_DEPS_NO_EXIT=1 check_dependencies awk sort uname readlink basename; then
        # Requested filenames and current bindings explain image/setup failures.
        # Current asset presence never erases a confirmed captured failure.
        sed -n 's/.*Direct firmware load for \(.*\) failed.*/\1/p' "$OUT_DIR/probe_candidates.log" |
            sort -u >"$OUT_DIR/requested_firmware.list"
        : >"$OUT_DIR/firmware_assets.tsv"
        while IFS= read -r probe_firmware; do
            [ -n "$probe_firmware" ] || continue
            if probe_asset=$(find_image_firmware "$probe_firmware"); then
                printf '%s|present|%s\n' "$probe_firmware" "$probe_asset"
            else
                printf '%s|not-found-in-current-image|missing\n' "$probe_firmware"
            fi
        done <"$OUT_DIR/requested_firmware.list" >"$OUT_DIR/firmware_assets.tsv"
        # Only device-bearing probe messages provide device identities. Fault
        # blocks remain separate, stack metadata is not a sysfs device name.
        if ! awk '
            {
                text = $0
                sub(/^[[:space:]]*/, "", text)
                while (text ~ /^\[[^]]*\]/) {
                    sub(/^\[[^]]*\][[:space:]]*/, "", text)
                }
                device = ""
                if (match(text, /(^|:[[:space:]]+)probe of [^[:space:]]+ failed/)) {
                    device = substr(text, RSTART, RLENGTH)
                    sub(/^.*probe of /, "", device)
                    sub(/[[:space:]]+failed$/, "", device)
                } else if (match(text, /:[[:space:]]/)) {
                    prefix = substr(text, 1, RSTART - 1)
                    detail = substr(text, RSTART + RLENGTH)
                    sub(/[[:space:]]+$/, "", prefix)
                    sub(/^[[:space:]]+/, "", detail)
                    count = split(prefix, words, /[[:space:]]+/)
                    if (count > 1) {
                        device = words[count]
                    } else if (tolower(prefix) == "bluetooth" &&
                               match(detail, /^hci[0-9]+:[[:space:]]/)) {
                        # Bluetooth uses a subsystem prefix before the HCI ID.
                        device = substr(detail, 1, RSTART + RLENGTH - 1)
                        sub(/:[[:space:]]*$/, "", device)
                    } else if (detail ~ /^(probe with driver |Direct firmware load for |deferred probe |ASoC: )/) {
                        # Kernel core messages can expose a device without a
                        # driver prefix, including devices absent from sysfs.
                        device = prefix
                    }
                }
                if (device != "." && device != ".." &&
                    device ~ /^[A-Za-z0-9_.:@+-]+$/ && !seen[device]++) {
                    print device
                }
            }
        ' "$OUT_DIR/probe_candidates.log" >"$OUT_DIR/probe_devices.list"; then
            log_warn "Probe device-context parsing failed, retaining the captured fault verdict"
            : >"$OUT_DIR/probe_devices.list"
        fi
        : >"$OUT_DIR/probe_devices.tsv"
        while IFS= read -r probe_device; do
            probe_found=0
            for probe_path in /sys/bus/*/devices/"$probe_device" /sys/class/*/"$probe_device"; do
                [ -d "$probe_path" ] || continue
                probe_found=1
                probe_driver="unbound"
                probe_dt="unexposed"
                probe_driver_owner="none"
                probe_dt_owner="none"
                probe_owner=$(readlink -f "$probe_path" 2>/dev/null) || probe_owner=""
                # Class devices can inherit their transport driver and DT
                # identity from an ancestor. Record the owner, not a binding
                # on the class child. These fields do not change the verdict.
                while [ -d "$probe_owner" ]; do
                    case "$probe_owner" in
                        /sys/devices/*)
                            ;;
                        *)
                            break
                            ;;
                    esac
                    if [ "$probe_driver_owner" = "none" ] &&
                       probe_bound_driver=$(platform_device_driver_name "$probe_owner"); then
                        probe_driver="$probe_bound_driver"
                        probe_driver_owner="$probe_owner"
                    fi
                    if [ "$probe_dt_owner" = "none" ] && [ -d "$probe_owner/of_node" ]; then
                        probe_dt=$(readlink -f "$probe_owner/of_node" 2>/dev/null) || probe_dt="unexposed"
                        if [ -d "$probe_dt" ]; then
                            probe_dt_owner="$probe_owner"
                        fi
                    fi
                    if [ "$probe_driver_owner" != "none" ] && [ "$probe_dt_owner" != "none" ]; then
                        break
                    fi
                    probe_owner=${probe_owner%/*}
                done
                printf '%s|%s|%s|%s|%s|%s\n' "$probe_device" "$probe_path" \
                    "$probe_driver" "$probe_dt" "$probe_driver_owner" "$probe_dt_owner"
            done
            if [ "$probe_found" -eq 0 ]; then
                printf '%s|missing|unbound|unexposed|none|none\n' "$probe_device"
            fi
        done <"$OUT_DIR/probe_devices.list" >"$OUT_DIR/probe_devices.tsv"
        log_file_with_label FIRMWARE-ASSET "$OUT_DIR/firmware_assets.tsv" 60
        log_file_with_label PROBE-DEVICE "$OUT_DIR/probe_devices.tsv" 60
    else
        log_warn "Additional probe context tools are unavailable, retaining captured failure evidence"
    fi
fi
if [ -s "$LOG_FILE" ]; then
    log_file_with_label PROBE-ERROR "$LOG_FILE" 60
    test_result_record FAIL "Confirmed probe, firmware-load or kernel faults detected, inspect $LOG_FILE and the image firmware/DT"
elif [ "$probe_status" -eq 1 ]; then
    test_result_record PASS "No confirmed probe, firmware, bind or kernel fault found in the captured log"
fi
test_result_finish
