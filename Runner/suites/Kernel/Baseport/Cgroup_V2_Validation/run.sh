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

TESTNAME="Cgroup_V2_Validation"
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

deps_list="cat grep sed awk tr mount mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
    kernel_record_attribute "cgroup.controllers" "/sys/fs/cgroup/cgroup.controllers"
    for ctrl in cpu cpuset memory pids; do
        if grep -qw "$ctrl" /sys/fs/cgroup/cgroup.controllers; then
            test_result_record "PASS" "cgroup v2 controller '$ctrl' is available"
        else
            test_result_record "SKIP" "cgroup v2 controller '$ctrl' is not enabled"
        fi
    done
    if [ -r /sys/fs/cgroup/cgroup.subtree_control ]; then
        kernel_record_attribute "cgroup.subtree_control" "/sys/fs/cgroup/cgroup.subtree_control"
    fi
    test_result_finish
fi

if mount | grep -q 'type cgroup2'; then
    test_result_record "SKIP" "cgroup2 is mounted but /sys/fs/cgroup/cgroup.controllers is missing"
    test_result_finish "SKIP"
fi

if [ -d /sys/fs/cgroup/cpu ] || [ -d /sys/fs/cgroup/memory ]; then
    test_result_record "SKIP" "legacy cgroup v1 hierarchy detected"
    test_result_finish "SKIP"
fi

test_result_record "SKIP" "cgroup v2 ABI is not present"
test_result_finish "SKIP"
