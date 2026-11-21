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
. "$TOOLS/lib_kernel.sh"

TESTNAME="CPU_Accounting_Validation"
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

deps_list="cat grep sed awk tr sleep mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
if ! k_kernel_evidence_init "."; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ ! -r /proc/stat ]; then
    test_result_record "FAIL" "/proc/stat is not readable"
    test_result_finish "FAIL"
fi

s1="$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8}' /proc/stat)"
sleep 1
s2="$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8}' /proc/stat)"
if is_unsigned_number "$s1" && is_unsigned_number "$s2"; then
    if [ "$s2" -gt "$s1" ]; then
        test_result_record "PASS" "/proc/stat cpu aggregate increased ($s1 -> $s2)"
    else
        test_result_record "FAIL" "/proc/stat cpu aggregate did not increase ($s1 -> $s2)"
    fi
else
    test_result_record "FAIL" "could not parse /proc/stat cpu counters"
fi

online_count="$(get_online_cpus | k_count_lines)"
stat_cpu_lines="$(grep -cE '^cpu[0-9]+' /proc/stat || true)"
log_info "online_cpus=$online_count proc_stat_cpu_lines=$stat_cpu_lines"
if is_unsigned_number "$stat_cpu_lines" && [ "$stat_cpu_lines" -ge 1 ]; then
    test_result_record "PASS" "/proc/stat has $stat_cpu_lines per-CPU rows"
else
    test_result_record "FAIL" "/proc/stat has no per-CPU rows"
fi

if [ -r /proc/loadavg ]; then
    la="$(k_sysfs_read /proc/loadavg)"
    log_info "loadavg=$la"
    test_result_record "PASS" "/proc/loadavg is readable"
else
    test_result_record "FAIL" "/proc/loadavg is not readable"
fi

if [ -r /proc/pressure/cpu ]; then
    k_record_readable "PSI cpu" "/proc/pressure/cpu"
else
    test_result_record "SKIP" "PSI /proc/pressure/cpu not present"
fi

if [ -r /proc/schedstat ]; then
    if grep -q '^version' /proc/schedstat; then
        test_result_record "PASS" "/proc/schedstat has a version header"
    else
        test_result_record "FAIL" "/proc/schedstat missing version header"
    fi
else
    test_result_record "SKIP" "/proc/schedstat not present"
fi

test_result_finish
