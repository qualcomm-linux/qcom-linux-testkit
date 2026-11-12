#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="IPCC"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Qualcomm PAS and PIL remoteprocs; the bare names also match children
# (qcom,qmi-cooling-cdsp) and interconnects (qcom,sa8775p-gpdsp-anoc).
RPROC_DT_RE='(^| )qcom,[^ ]*-(pas|pil)( |$)'

rproc_list="./remoteproc_instances.log"
dt_list="./remoteproc_dt_nodes.log"
: >"$rproc_list"
list_remoteproc_instances "$rproc_list" || true
dt_list_compatible_nodes "$RPROC_DT_RE" regex >"$dt_list" 2>/dev/null || true

total=0
count=0
missing=0
rproc_devices=""
while IFS='|' read -r rp_path rp_name rp_firmware rp_state; do
    [ -n "$rp_path" ] || continue
    total=$((total + 1))
    case "$rp_state" in
        running|attached)
            count=$((count + 1))
            ;;
        *)
            log_info "remoteproc $rp_name ($rp_firmware) is $rp_state"
            ;;
    esac
    rp_device=$(readlink -f "$rp_path/device" 2>/dev/null || true)
    rproc_devices="$rproc_devices|$rp_device|"
done <"$rproc_list"

expected=0
while IFS= read -r dt_node; do
    [ -n "$dt_node" ] || continue
    expected=$((expected + 1))
    dt_device=$(find_platform_device_for_dt_node "$dt_node" 2>/dev/null || true)
    dt_device=$(readlink -f "$dt_device" 2>/dev/null || true)
    case "$rproc_devices" in
        *"|$dt_device|"*)
            [ -n "$dt_device" ] && continue
            ;;
    esac
    log_info "DT remoteproc ${dt_node##*/} ($(dt_property_text "$dt_node" compatible 2>/dev/null)) has no registered remoteproc"
    missing=$((missing + 1))
done <"$dt_list"
log_info "$count of $total registered remoteprocs running, $missing of $expected DT remoteprocs not registered"

if [ "$total" -eq 0 ] && [ "$expected" -eq 0 ]; then
    log_skip "$TESTNAME : no remoteproc in the device tree"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

if [ "$missing" -eq 0 ] && [ "$count" -eq "$total" ]; then
    log_pass "$TESTNAME : Test Passed"
    log_info "Writing to file $res_file"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    log_info "Writing to file $res_file"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
