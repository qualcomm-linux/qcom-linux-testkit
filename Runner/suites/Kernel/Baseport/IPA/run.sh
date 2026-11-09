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

TESTNAME="IPA"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0

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
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat grep awk find head readlink uname mkdir mktemp date cp sed wc tr; then
    test_result_finish SKIP "Image-provided IPA validation utilities are unavailable"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create evidence under CWD=$PWD"
log_info "Evidence: $OUT_DIR"

MODNAME="ipa"
LOADED_BY_TEST=0

# cleanup
# Restore only a module loaded by this runner and retain restoration failures.
cleanup() {
    if [ "$LOADED_BY_TEST" -eq 1 ]; then
        if unload_kernel_module "$MODNAME" false; then
            LOADED_BY_TEST=0
        else
            log_fail "Could not unload test-owned module $MODNAME"
            return 1
        fi
    fi
}
# shellcheck disable=SC2034 # Consumed by shared finalization.
TEST_RESULT_CLEANUP=cleanup
trap cleanup 0
trap 'test_result_finish FAIL "Driver validation interrupted"' HUP INT TERM

origin=$(kernel_module_runtime_origin "$MODNAME" || true)
config_value=$(kernel_config_value CONFIG_QCOM_IPA || true)
log_info "Driver=$MODNAME origin=${origin:-unavailable} config=${config_value:-unknown}"
if is_module_loaded "$MODNAME" || [ "$origin" = builtin ]; then
    test_result_record PASS "Image driver $MODNAME is active, origin=$origin"
else
    case "$config_value" in
        CONFIG_QCOM_IPA=n)
            test_result_finish SKIP "CONFIG_QCOM_IPA is disabled"
            ;;
        '')
            if [ -z "$origin" ]; then
                test_result_finish SKIP "No runtime driver or readable configuration identifies $MODNAME"
            fi
            ;;
    esac
    MODPATH=$(find_kernel_module "$MODNAME" running)
    if [ -z "$MODPATH" ] || [ ! -f "$MODPATH" ]; then
        test_result_record FAIL "Applicable driver $MODNAME has no module for $(uname -r)"
    elif load_kernel_module "$MODPATH" && is_module_loaded "$MODNAME"; then
        LOADED_BY_TEST=1
        test_result_record PASS "Loaded running-kernel module $MODPATH"
    else
        if is_module_loaded "$MODNAME"; then
            LOADED_BY_TEST=1
        fi
        test_result_record FAIL "Could not load or verify $MODNAME from $MODPATH"
    fi
fi
scan_dmesg_errors "$OUT_DIR" 'ipa' 'not a crash|non-fatal' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_record SKIP "Kernel health unverified, inspect $OUT_DIR/dmesg_access.log"
elif [ -s "$OUT_DIR/dmesg_errors.log" ]; then
    log_file_with_label DRIVER-ERROR "$OUT_DIR/dmesg_errors.log"
    test_result_record FAIL "Captured $MODNAME driver errors"
else
    test_result_record PASS "No captured $MODNAME kernel errors"
fi
cleanup || test_result_record FAIL "Test-owned driver cleanup failed"
if [ "$LOADED_BY_TEST" -eq 1 ]; then
    test_result_record FAIL "Test-owned driver state was not restored"
fi
test_result_finish
