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

TESTNAME="CPU_Topology_Validation"
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

cpu_count=0
for cpu_name in $(kernel_list_all_cpus); do
    topo="/sys/devices/system/cpu/$cpu_name/topology"
    if [ ! -d "$topo" ]; then
        test_result_record "SKIP" "$cpu_name has no topology directory"
        continue
    fi
    cpu_count=$((cpu_count + 1))
    for node in physical_package_id core_id thread_siblings core_siblings; do
        if [ -r "$topo/$node" ]; then
            kernel_record_attribute "$cpu_name $node" "$topo/$node"
        else
            # Some kernels use _list variants only.
            if [ -r "$topo/${node}_list" ]; then
                kernel_record_attribute "$cpu_name ${node}_list" "$topo/${node}_list"
            else
                test_result_record "SKIP" "$topo/$node not exported"
            fi
        fi
    done
    if [ -e "$topo/thread_siblings_list" ]; then
        sib="$(kernel_attribute_value "$topo/thread_siblings_list")" || sib=""
        cpu_idx="${cpu_name#cpu}"
        if kernel_cpu_list_valid "$sib" && cpu_in_list "$cpu_idx" "$sib"; then
            test_result_record "PASS" "$cpu_name is listed in thread_siblings_list ($sib)"
        else
            test_result_record "FAIL" "$cpu_name missing from thread_siblings_list ($sib)"
        fi
    fi
done

if [ "$cpu_count" -eq 0 ]; then
    test_result_record "FAIL" "no CPU topology directories found"
    test_result_finish "FAIL"
fi

test_result_finish
