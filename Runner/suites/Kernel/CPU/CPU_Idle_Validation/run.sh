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

TESTNAME="CPU_Idle_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
# shellcheck disable=SC2034
CHECK_DEPS_RECOVER=0

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

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

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

deps_list="cat grep sed awk tr sleep mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

idle_root="/sys/devices/system/cpu/cpuidle"
if [ -d "$idle_root" ]; then
    if [ -r "$idle_root/current_driver" ]; then
        kernel_record_attribute "cpuidle driver" "$idle_root/current_driver"
    fi
    if [ -r "$idle_root/current_governor" ]; then
        kernel_record_attribute "cpuidle governor" "$idle_root/current_governor"
    elif [ -r "$idle_root/current_governor_ro" ]; then
        kernel_record_attribute "cpuidle governor" "$idle_root/current_governor_ro"
    fi
    if [ -r "$idle_root/available_governors" ]; then
        kernel_record_attribute "cpuidle available_governors" "$idle_root/available_governors"
    fi
else
    test_result_record "SKIP" "global cpuidle sysfs is not present"
fi

sampled=0
idle_sample="$KERNEL_EVIDENCE_DIR/idle-usage.txt"
: > "$idle_sample"
for cpu_id in $(get_online_cpus); do
    cpu_name="cpu${cpu_id}"
    sdir="/sys/devices/system/cpu/$cpu_name/cpuidle"
    [ -d "$sdir" ] || continue
    for state in "$sdir"/state[0-9]*; do
        [ -d "$state" ] || continue
        sampled=$((sampled + 1))
        kernel_record_attribute "$cpu_name $(basename "$state") name" "$state/name"
        if [ -e "$state/disable" ]; then
            idle_disable="$(kernel_attribute_value "$state/disable")" || idle_disable=""
            if [ "$idle_disable" != "0" ] && [ "$idle_disable" != "1" ]; then
                test_result_record "FAIL" "$state/disable is not 0 or 1 ('${idle_disable:-unreadable}')"
                continue
            fi
            test_result_record "PASS" "$state/disable=$idle_disable"
            [ "$idle_disable" = "0" ] || continue
        fi
        idle_usage="$(kernel_attribute_value "$state/usage")" || idle_usage=""
        if ! is_unsigned_number "$idle_usage"; then
            test_result_record "FAIL" "$state/usage is not an unsigned counter ('${idle_usage:-unreadable}')"
            continue
        fi
        printf '%s %s\n' "$state/usage" "$idle_usage" >> "$idle_sample"
    done
done

if [ "$sampled" -eq 0 ]; then
    test_result_record "SKIP" "no per-CPU cpuidle states found on online CPUs"
    test_result_finish "SKIP"
fi

if [ -s "$idle_sample" ]; then
    sleep 1
    while read -r idle_path idle_before; do
        idle_after="$(kernel_attribute_value "$idle_path")" || idle_after=""
        if ! is_unsigned_number "$idle_before" || ! is_unsigned_number "$idle_after"; then
            test_result_record "FAIL" "$idle_path counter is invalid ('${idle_before:-unreadable}' -> '${idle_after:-unreadable}')"
        elif [ "$idle_after" -lt "$idle_before" ]; then
            test_result_record "FAIL" "$idle_path went backwards ($idle_before -> $idle_after)"
        else
            test_result_record "PASS" "$idle_path is monotonic ($idle_before -> $idle_after); equality only means this state was not entered"
        fi
    done < "$idle_sample"
else
    test_result_record "SKIP" "online CPUs expose no enabled cpuidle usage counters"
fi

test_result_finish
