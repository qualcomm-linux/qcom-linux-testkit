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
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_pkg_provider.sh"

TESTNAME="RMTFS_QMI_Service_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
SERVICE_ID="${RMTFS_QMI_SERVICE:-14}"
SERVICE_VERSION="${RMTFS_QMI_VERSION:-1}"
SERVICE_INSTANCE="${RMTFS_QMI_INSTANCE:-0}"
QRTR_LOOKUP_TIMEOUT="${QRTR_LOOKUP_TIMEOUT:-10}"
rm -f "$RES_FILE"

# shellcheck disable=SC2317
cleanup_on_exit() {
    rmtfs_runtime_cleanup >/dev/null 2>&1 || true
}

finish_result() {
    final_result="$1"

    if ! rmtfs_runtime_cleanup; then
        log_fail "$TESTNAME FAIL: unable to restore the initial RMTFS module or service state"
        final_result="FAIL"
    fi

    echo "$TESTNAME $final_result" > "$RES_FILE"

    if [ "$final_result" = "FAIL" ]; then
        exit 1
    fi

    exit 0
}

trap cleanup_on_exit 0
trap 'exit 1' 1 2 15

OS_ID=$(pkg_detect_os_id 2>/dev/null || echo unknown)
RUN_LOG="$SCRIPT_DIR/qrtr_lookup_rmtfs.log"
rm -f "$RUN_LOG"
log_info "Starting $TESTNAME on OS=$OS_ID"
log_info "Configuration: RMTFS_QMI_SERVICE=$SERVICE_ID RMTFS_QMI_VERSION=$SERVICE_VERSION RMTFS_QMI_INSTANCE=$SERVICE_INSTANCE QRTR_LOOKUP_TIMEOUT=${QRTR_LOOKUP_TIMEOUT}s"
log_info "Validation target: public linux-msm/rmtfs service=$SERVICE_ID version=$SERVICE_VERSION instance=$SERVICE_INSTANCE"

RMTFS_RUNTIME_DIR="$SCRIPT_DIR/rmtfs_runtime"
rmtfs_runtime_prepare "$RMTFS_RUNTIME_DIR"
PREPARE_RC=$?

if [ "$PREPARE_RC" -eq 2 ]; then
    log_skip "$TESTNAME SKIP: RMTFS is not applicable on this platform"
    finish_result SKIP
fi

if [ "$PREPARE_RC" -ne 0 ]; then
    log_fail "$TESTNAME FAIL: unable to prepare the RMTFS runtime snapshot"
    finish_result FAIL
fi

if [ "$RMTFS_MAINLINE_APPLICABLE" -eq 0 ] && \
   [ "$RMTFS_LEGACY_APPLICABLE" -eq 1 ]; then
    log_skip "$TESTNAME SKIP: the legacy RMTFS stack does not publish the public QRTR service"
    finish_result SKIP
fi

if [ "$RMTFS_MODULE_LOAD_ATTEMPTED" -eq 1 ] && \
   [ "$RMTFS_MODULE_LOAD_FAILED" -eq 1 ]; then
    log_fail "$TESTNAME FAIL: the initially unloaded rmtfs_mem module could not be loaded"
    finish_result FAIL
fi

if ! rmtfs_start_service_if_available || \
   ! rmtfs_process_running rmtfs; then
    log_fail "$TESTNAME FAIL: applicable RMTFS hardware was found but the rmtfs daemon did not start"
    finish_result FAIL
fi

log_info "Validating public linux-msm/rmtfs registration: service=$SERVICE_ID version=$SERVICE_VERSION instance=$SERVICE_INSTANCE"

qrtr_capture_topology "$RUN_LOG" "$QRTR_LOOKUP_TIMEOUT"
LOOKUP_RC=$?

case "$LOOKUP_RC" in
    0)
        log_file_with_label "qrtr-lookup" "$RUN_LOG"
        ;;
    2)
        log_skip "$TESTNAME SKIP: QRTR runtime or qrtr-lookup is unavailable"
        finish_result SKIP
        ;;
    *)
        log_file_with_label "qrtr-lookup" "$RUN_LOG"
        log_fail "$TESTNAME FAIL: bounded QRTR topology query failed"
        finish_result FAIL
        ;;
esac

if qrtr_topology_has_service \
    "$RUN_LOG" \
    "$SERVICE_ID" \
    "$SERVICE_VERSION" \
    "$SERVICE_INSTANCE"; then
    log_pass "$TESTNAME PASS: RMTFS QMI service registration found"
    finish_result PASS
fi

log_fail "$TESTNAME FAIL: service $SERVICE_ID version $SERVICE_VERSION instance $SERVICE_INSTANCE was not registered"
finish_result FAIL
