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
# shellcheck disable=SC1091
. "$TOOLS/lib_pkg_provider.sh"

TESTNAME="AI_ML_QNN_Net_Run_Version"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
QNN_VERSION_TIMEOUT_SOURCE="default"
QNN_NET_RUN_OVERRIDE="${QNN_NET_RUN_BINARY:-}"
QNN_NET_RUN_SOURCE="dynamic"

if [ -n "${QNN_VERSION_TIMEOUT:-}" ]; then
    QNN_VERSION_TIMEOUT_SOURCE="environment"
else
    QNN_VERSION_TIMEOUT=10
fi
if [ -n "$QNN_NET_RUN_OVERRIDE" ]; then
    QNN_NET_RUN_SOURCE="environment"
fi

# usage
# Prints the qnn-net-run version-check CLI contract without target changes.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --qnn-net-run PATH_OR_NAME" \
        "  --timeout SECONDS" \
        "  -h, --help" \
        "CLI options override QNN_NET_RUN_BINARY and QNN_VERSION_TIMEOUT."
}

# parse_args <suite-arguments...>
# Applies CLI overrides and returns 2 for invalid syntax.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --qnn-net-run)
                [ "$#" -ge 2 ] || return 2
                QNN_NET_RUN_OVERRIDE="$2"
                if [ -n "$QNN_NET_RUN_OVERRIDE" ]; then
                    QNN_NET_RUN_SOURCE="cli"
                else
                    QNN_NET_RUN_SOURCE="dynamic"
                fi
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                QNN_VERSION_TIMEOUT="$2"
                QNN_VERSION_TIMEOUT_SOURCE="cli"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                return 2
                ;;
        esac
    done
}

# resolve_qnn_net_run
# Resolves an explicit executable or qnn-net-run from PATH into QNN_NET_RUN.
resolve_qnn_net_run() {
    QNN_NET_RUN=""
    if [ -n "$QNN_NET_RUN_OVERRIDE" ]; then
        case "$QNN_NET_RUN_OVERRIDE" in
            */*)
                if [ -x "$QNN_NET_RUN_OVERRIDE" ]; then
                    QNN_NET_RUN="$QNN_NET_RUN_OVERRIDE"
                    return 0
                fi
                return 1
                ;;
        esac
        if command -v "$QNN_NET_RUN_OVERRIDE" >/dev/null 2>&1; then
            QNN_NET_RUN=$(command -v "$QNN_NET_RUN_OVERRIDE")
            return 0
        fi
        return 1
    fi
    if command -v qnn-net-run >/dev/null 2>&1; then
        QNN_NET_RUN=$(command -v qnn-net-run)
        return 0
    fi
    return 1
}

parse_args "$@" || {
    usage >&2
    exit 2
}

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
VERSION_LOG="$RESULT_DIR/qnn-net-run-version.log"
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: cannot create evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "[QNN-VERSION-POLICY] configuration=config2 timeout=${QNN_VERSION_TIMEOUT}s timeout_source=$QNN_VERSION_TIMEOUT_SOURCE executable=${QNN_NET_RUN_OVERRIDE:-auto} executable_source=$QNN_NET_RUN_SOURCE network=not-required package_install=disabled"
QNN_VERSION_OS_ID=$(pkg_detect_os_id)
QNN_VERSION_MAPPED_PACKAGES=""
case "$QNN_VERSION_OS_ID" in
    debian|ubuntu)
        QNN_VERSION_MAPPED_PACKAGES=$(
            pkg_lookup_packages_for_command qnn-net-run || true
        )
        ;;
esac
log_info "[QNN-VERSION-PACKAGES] os=$QNN_VERSION_OS_ID mapped_packages=${QNN_VERSION_MAPPED_PACKAGES:-not-defined} package_install=disabled"

case "$QNN_VERSION_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "qnn-net-run version timeout must be a positive integer"
        test_result_finish
        ;;
esac
if [ "$QNN_VERSION_TIMEOUT" -gt 60 ]; then
    test_result_record "FAIL" "qnn-net-run version timeout must not exceed 60s"
    test_result_finish
fi

if ! resolve_qnn_net_run; then
    if [ -n "$QNN_NET_RUN_OVERRIDE" ]; then
        test_result_record "FAIL" "Explicit qnn-net-run executable is unavailable, value=$QNN_NET_RUN_OVERRIDE source=$QNN_NET_RUN_SOURCE"
    else
        test_result_record "SKIP" "qnn-net-run is not installed, expected image package=qnn-tools"
    fi
    test_result_finish
fi

run_with_timeout_log \
    "$QNN_VERSION_TIMEOUT" \
    "$VERSION_LOG" \
    "$QNN_NET_RUN" --version
qnn_version_rc=$?
log_file_with_label "QNN-NET-RUN-VERSION" "$VERSION_LOG" 20

if [ "$qnn_version_rc" -ne 0 ]; then
    test_result_record "FAIL" "qnn-net-run --version failed or timed out, rc=$qnn_version_rc artifact=$VERSION_LOG"
    test_result_finish
fi
if ! grep -q '[^[:space:]]' "$VERSION_LOG" 2>/dev/null; then
    test_result_record "FAIL" "qnn-net-run --version returned no version evidence, artifact=$VERSION_LOG"
    test_result_finish
fi

test_result_record "PASS" "qnn-net-run --version completed successfully, executable=$QNN_NET_RUN artifact=$VERSION_LOG"
test_result_finish
