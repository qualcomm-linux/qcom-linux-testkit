#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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
    echo "[ERROR] Could not find init_env, starting at $SCRIPT_DIR" >&2
    exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Kubernetes_Kernel_Config"
test_path="$(find_test_case_by_name "$TESTNAME")" || {
    log_fail "$TESTNAME, test directory not found"
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}

cd "$test_path" || exit 1
RES_FILE="./${TESTNAME}.res"
rm -f "$RES_FILE"

CONFIGS="
CONFIG_CGROUP_FAVOR_DYNMODS=y
CONFIG_CFS_BANDWIDTH=y
CONFIG_CGROUP_HUGETLB=y
CONFIG_NETFILTER_XT_MATCH_COMMENT=m
CONFIG_IP_NF_TARGET_REDIRECT=m
CONFIG_HUGETLBFS=y
"

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase ----------------------------"
log_info "==== Test Initialization ===="

log_info "Checking required Kubernetes kernel configs"
if ! check_kernel_config "$CONFIGS"; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

log_pass "$TESTNAME, all required Kubernetes kernel configs are present with expected values"
echo "$TESTNAME PASS" > "$RES_FILE"
log_info "------------------- Completed ${TESTNAME} Testcase ----------------------------"
exit 0
