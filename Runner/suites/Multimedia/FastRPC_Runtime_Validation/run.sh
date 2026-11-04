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

TESTNAME="FastRPC_Runtime_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! check_dependencies cat grep awk tr basename readlink mkdir; then
    test_result_finish SKIP "Image lacks FastRPC inventory tools"
fi
RESULT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || test_result_finish FAIL "Cannot create FastRPC evidence directory"
scan_dmesg_errors "$RESULT_DIR" 'fastrpc.*|remoteproc.*|qcom.*pas.*' 'deferred probe|EPROBE_DEFER' || true
if [ -s "$RESULT_DIR/dmesg_errors.log" ]; then
    test_result_record FAIL "FastRPC or remoteproc kernel errors were captured"
fi
endpoint_count=0
for endpoint in /dev/fastrpc-*; do
    [ -e "$endpoint" ] || continue
    endpoint_count=$((endpoint_count + 1))
    if [ -c "$endpoint" ] && [ -r "$endpoint" ] && [ -w "$endpoint" ] &&
       [ -r "/sys/class/misc/${endpoint##*/}/dev" ]; then
        test_result_record PASS "FastRPC runtime endpoint is accessible: $endpoint"
    else
        test_result_record FAIL "FastRPC endpoint is not a registered accessible character device: $endpoint"
    fi
done
if [ "$endpoint_count" -eq 0 ]; then
    test_result_record SKIP "No FastRPC endpoint registered, inspect the separate remoteproc and probe checks"
fi
qrtr_capture_topology "$RESULT_DIR/qrtr.log" 10
qrtr_status=$?
case "$qrtr_status" in
    0)
        log_file_with_label QRTR "$RESULT_DIR/qrtr.log"
        test_result_record PASS "QRTR topology query completed, it does not prove an AudioPD transaction"
        ;;
    2)
        test_result_record SKIP "QRTR runtime or image-provided topology client unavailable"
        ;;
    *)
        log_file_with_label QRTR "$RESULT_DIR/qrtr.log"
        test_result_record FAIL "QRTR runtime query failed"
        ;;
esac
if [ "$endpoint_count" -eq 0 ] && [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ]; then
    test_result_finish SKIP "No FastRPC endpoint was available, QRTR-only evidence is insufficient for FastRPC readiness"
fi
test_result_finish
