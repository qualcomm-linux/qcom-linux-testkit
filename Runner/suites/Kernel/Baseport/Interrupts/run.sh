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

TESTNAME="Interrupts"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
WORKLOAD_SECONDS="${INTERRUPTS_POLL_INTERVAL_S:-2}"
RETRIES=2
BUDGET_SECONDS="${INTERRUPTS_WAIT_TIMEOUT_S:-auto}"
SKIP_ISOLATED=1

# usage
# Describe the bounded runtime CPU selection. No side effects.
usage() {
    echo "Usage: $0 [--workload-seconds N] [--retries N] [--timeout auto|N] [--include-isolated]"
}

# parse_args <arguments...>
# Validate options before starting CPU workloads. Return nonzero on invalid input.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 1
                BUDGET_SECONDS="$2"
                shift 2
                ;;
            --workload-seconds|--retries)
                [ "$#" -ge 2 ] || return 1
                is_unsigned_number "$2" && [ "$2" -gt 0 ] || return 1
                case "$1" in
                    --workload-seconds)
                        WORKLOAD_SECONDS="$2"
                        ;;
                    --retries)
                        RETRIES="$2"
                        ;;
                esac
                shift 2
                ;;
            --include-isolated)
                SKIP_ISOLATED=0
                shift
                ;;
            *)
                return 1
                ;;
        esac
    done
    for irq_value in "$WORKLOAD_SECONDS" "$RETRIES"; do
        is_unsigned_number "$irq_value" && [ "$irq_value" -gt 0 ] || return 1
    done
    [ "$BUDGET_SECONDS" = auto ] || {
        is_unsigned_number "$BUDGET_SECONDS" && [ "$BUDGET_SECONDS" -gt 0 ]
    }
}
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
parse_args "$@" || test_result_finish FAIL "Invalid interrupt validation options"
trap 'test_result_finish FAIL "Interrupt validation interrupted"' HUP INT TERM
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || test_result_finish FAIL "Cannot create evidence directory"
validate_per_cpu_interrupt_active arch_timer "$WORKLOAD_SECONDS" "$RETRIES" "$SKIP_ISOLATED" "$BUDGET_SECONDS" >"$OUT_DIR/interrupts.log" 2>&1
irq_rc=$?
log_file_with_label IRQ "$OUT_DIR/interrupts.log"
case "$irq_rc" in
    0)
        test_result_record PASS "Timer interrupts incremented under pinned work on $IRQ_ACTIVE_TESTED eligible CPUs"
        ;;
    2)
        test_result_record SKIP "$IRQ_ACTIVE_SKIP_REASON"
        ;;
    *)
        test_result_record FAIL "Active interrupt validation failed, see $OUT_DIR/interrupts.log"
        ;;
esac
test_result_finish
