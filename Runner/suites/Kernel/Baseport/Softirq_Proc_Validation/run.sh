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

TESTNAME="Softirq_Proc_Validation"
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
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ ! -r /proc/softirqs ]; then
    test_result_record "FAIL" "/proc/softirqs is not readable"
    test_result_finish "FAIL"
fi

softirq_copy="$KERNEL_EVIDENCE_DIR/softirqs.first"
cp /proc/softirqs "$softirq_copy" || {
    test_result_record "FAIL" "could not snapshot /proc/softirqs"
    test_result_finish "FAIL"
}
sleep 1
softirq_copy2="$KERNEL_EVIDENCE_DIR/softirqs.second"
cp /proc/softirqs "$softirq_copy2" || {
    test_result_record "FAIL" "could not snapshot /proc/softirqs again"
    test_result_finish "FAIL"
}

softirq_sum() {
    awk -v row="$1" '
        $1 == row {
            found = 1
            if (NF < 2) bad = 1
            for (i = 2; i <= NF; i++) {
                if ($i !~ /^[0-9]+$/) bad = 1
                else total += $i
            }
        }
        END {
            if (!found || bad) exit 1
            print total + 0
        }
    ' "$2"
}

for soft_row in "TIMER:" "SCHED:" "RCU:"; do
    soft_before="$(softirq_sum "$soft_row" "$softirq_copy")" || soft_before=""
    soft_after="$(softirq_sum "$soft_row" "$softirq_copy2")" || soft_after=""
    if [ -z "$soft_before" ] || [ -z "$soft_after" ]; then
        test_result_record "FAIL" "$soft_row row is missing or contains a non-numeric counter"
        continue
    fi
    soft_delta="$(interrupt_counter_delta "$soft_before" "$soft_after")"
    if [ "$soft_delta" = "-1" ]; then
        test_result_record "FAIL" "$soft_row went backwards ($soft_before -> $soft_after)"
    else
        test_result_record "PASS" "$soft_row is monotonic ($soft_before -> $soft_after, delta=$soft_delta)"
    fi
done

test_result_finish
