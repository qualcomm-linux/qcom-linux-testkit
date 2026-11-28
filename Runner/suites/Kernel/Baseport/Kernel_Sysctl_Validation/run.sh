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

TESTNAME="Kernel_Sysctl_Validation"
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

kernel_record_attribute "pid_max" "/proc/sys/kernel/pid_max" 1
kernel_record_attribute "threads-max" "/proc/sys/kernel/threads-max" 1
printk_val="$(kernel_attribute_value /proc/sys/kernel/printk)" || printk_val=""
if printf '%s\n' "$printk_val" | awk 'NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^-?[0-9]+$/) bad = 1; ok = !bad } END { exit !ok }'; then
    test_result_record "PASS" "printk has four integer fields ($printk_val)"
else
    test_result_record "FAIL" "printk is not four integers ('${printk_val:-unreadable}')"
fi

if [ -e /proc/sys/kernel/panic ]; then
    kernel_record_attribute "panic" "/proc/sys/kernel/panic" signed
fi
if [ -r /proc/sys/kernel/panic_on_oops ]; then
    kernel_record_attribute "panic_on_oops" "/proc/sys/kernel/panic_on_oops" 1
fi
if [ -r /proc/sys/kernel/sysrq ]; then
    kernel_record_attribute "sysrq" "/proc/sys/kernel/sysrq" 1
fi
if [ -r /proc/sys/kernel/hostname ]; then
    kernel_record_attribute "hostname" "/proc/sys/kernel/hostname"
fi
if [ -r /proc/sys/kernel/osrelease ]; then
    osr="$(kernel_attribute_value /proc/sys/kernel/osrelease)"
    ur="$(uname -r)"
    if [ "$osr" = "$ur" ]; then
        test_result_record "PASS" "osrelease matches uname -r ($ur)"
    else
        test_result_record "FAIL" "osrelease ($osr) != uname -r ($ur)"
    fi
fi

test_result_finish
