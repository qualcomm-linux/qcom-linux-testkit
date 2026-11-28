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

TESTNAME="Modules_Firmware_Validation"
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

mod_state="$(kernel_config_state CONFIG_MODULES)" || mod_state=""
case "$mod_state" in
    n)
        test_result_record "SKIP" "CONFIG_MODULES is disabled; module listing is not expected"
        ;;
    y|m)
        if [ -r /proc/modules ]; then
            test_result_record "PASS" "/proc/modules is readable"
            mod_count="$(kernel_count_lines < /proc/modules)"
            log_info "loaded modules=$mod_count"
        else
            test_result_record "FAIL" "/proc/modules is not readable"
        fi
        if command -v lsmod >/dev/null 2>&1; then
            if lsmod >/dev/null 2>&1; then
                test_result_record "PASS" "lsmod runs successfully"
            else
                test_result_record "FAIL" "lsmod failed"
            fi
        fi
        ;;
    *)
        if [ -r /proc/modules ]; then
            test_result_record "PASS" "/proc/modules is readable"
        else
            test_result_record "SKIP" "CONFIG_MODULES state is unavailable and /proc/modules is absent"
        fi
        ;;
esac

if [ -d /sys/module ]; then
    test_result_record "PASS" "/sys/module directory exists"
else
    test_result_record "FAIL" "/sys/module is not present"
fi

if [ -d /lib/firmware ] || [ -d /usr/lib/firmware ]; then
    test_result_record "PASS" "firmware directory exists under /lib or /usr/lib"
else
    test_result_record "SKIP" "no firmware directory found"
fi

if [ -e /sys/class/firmware ]; then
    test_result_record "PASS" "/sys/class/firmware exists"
else
    test_result_record "SKIP" "/sys/class/firmware not present"
fi

test_result_finish
