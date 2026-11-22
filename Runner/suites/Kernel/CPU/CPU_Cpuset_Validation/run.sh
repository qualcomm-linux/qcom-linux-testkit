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

TESTNAME="CPU_Cpuset_Validation"
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

deps_list="cat grep sed awk tr mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

cpuset_path=""
if [ -e /sys/fs/cgroup/cpuset.cpus.effective ]; then
    cpuset_path="/sys/fs/cgroup/cpuset.cpus.effective"
elif [ -e /sys/fs/cgroup/cpuset.cpus ]; then
    cpuset_path="/sys/fs/cgroup/cpuset.cpus"
elif [ -e /sys/fs/cgroup/cpuset/cpuset.cpus ]; then
    cpuset_path="/sys/fs/cgroup/cpuset/cpuset.cpus"
elif [ -e /proc/self/cpuset ]; then
    test_result_record "SKIP" "only /proc/self/cpuset is present; cpuset mask was not checked"
    test_result_finish
else
    test_result_record "SKIP" "cpuset ABI is not present"
    test_result_finish "SKIP"
fi

if kernel_record_attribute "cpuset mask" "$cpuset_path"; then
    cpuset_cpus="$(kernel_attribute_value "$cpuset_path")" || cpuset_cpus=""
    online="$(kernel_attribute_value /sys/devices/system/cpu/online)" || online=""
    if ! kernel_cpu_list_valid "$cpuset_cpus"; then
        test_result_record "FAIL" "cpuset mask is empty or malformed ('$cpuset_cpus')"
    elif ! kernel_cpu_list_valid "$online"; then
        test_result_record "FAIL" "online CPU mask is empty or malformed ('$online')"
    else
        cpuset_bad=0
        for cpu in $(expand_cpu_list "$online"); do
            if ! cpu_in_list "$cpu" "$cpuset_cpus"; then
                test_result_record "FAIL" "online CPU$cpu is outside cpuset mask ($cpuset_cpus)"
                cpuset_bad=1
            fi
        done
        if [ "$cpuset_bad" -eq 0 ]; then
            test_result_record "PASS" "online CPUs are members of $cpuset_path ($cpuset_cpus)"
        fi
    fi
fi

if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
    if grep -qw cpuset /sys/fs/cgroup/cgroup.controllers; then
        test_result_record "PASS" "cpuset is listed in cgroup.controllers"
    else
        test_result_record "SKIP" "cpuset controller is not enabled in cgroup v2"
    fi
fi

test_result_finish
