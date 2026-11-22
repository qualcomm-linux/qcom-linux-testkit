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
for cpu_name in $(kernel_list_all_cpus); do
    sdir="/sys/devices/system/cpu/$cpu_name/cpuidle"
    [ -d "$sdir" ] || continue
    for state in "$sdir"/state[0-9]*; do
        [ -d "$state" ] || continue
        sampled=$((sampled + 1))
        kernel_record_attribute "$cpu_name $(basename "$state") name" "$state/name"
        kernel_record_attribute "$cpu_name $(basename "$state") usage" "$state/usage" 1
        if [ -r "$state/time" ]; then
            kernel_record_attribute "$cpu_name $(basename "$state") time" "$state/time" 1
        fi
        if [ -r "$state/disable" ]; then
            kernel_record_attribute "$cpu_name $(basename "$state") disable" "$state/disable" 1
        fi
        break
    done
    [ "$sampled" -ge 1 ] && break
done

if [ "$sampled" -eq 0 ]; then
    test_result_record "SKIP" "no per-CPU cpuidle states found"
    test_result_finish "SKIP"
fi

# Pick first idle state's usage and confirm it can stay readable across a short idle window.
state0=""
for cpu_name in $(kernel_list_all_cpus); do
    cand="/sys/devices/system/cpu/$cpu_name/cpuidle/state0/usage"
    if [ -r "$cand" ]; then
        state0="$cand"
        break
    fi
done
if [ -n "$state0" ]; then
    u1="$(kernel_attribute_value "$state0")"
    sleep 1
    u2="$(kernel_attribute_value "$state0")"
    if is_unsigned_number "$u1" && is_unsigned_number "$u2"; then
        if [ "$u2" -ge "$u1" ]; then
            test_result_record "PASS" "cpuidle usage is monotonic ($u1 -> $u2)"
        else
            test_result_record "FAIL" "cpuidle usage went backwards ($u1 -> $u2)"
        fi
    fi
fi

test_result_finish
