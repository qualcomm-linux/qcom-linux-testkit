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
. "$TOOLS/lib_performance.sh"

TESTNAME="Freq_Scaling"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
trap 'test_result_finish FAIL "CPUFreq interrupted, inspect policy restoration logs"' HUP INT TERM

# usage
# Print supported invocation, no mutation.
usage() {
    echo "Usage: $0 [--help]"
}

# parse_args <arguments...>
# Reject unsupported options before policy mutation.
parse_args() {
    case "${1:-}" in
        --help|-h)
            usage
            exit 0
            ;;
        "")
            ;;
        *)
            test_result_finish FAIL "Unsupported CPUFreq option: $1"
            ;;
    esac
}
parse_args "$@"
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || test_result_finish FAIL "Cannot create evidence directory in $PWD"
log_info "CPUFreq evidence: $OUT_DIR"
for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy_dir" ] || continue
    policy_name=${policy_dir##*/}
    mkdir "$OUT_DIR/$policy_name" || test_result_finish FAIL "Cannot create policy evidence"
    cpufreq_validate_policy "$policy_dir" "$OUT_DIR/$policy_name" load >"$OUT_DIR/$policy_name/validation.log" 2>&1
    policy_rc=$?
    cat "$OUT_DIR/$policy_name/validation.log"
    case "$policy_rc" in
        0)
            test_result_record PASS "$policy_name supported controls validated and restored"
            ;;
        4)
            test_result_record SKIP "$policy_name has no eligible online CPU or supported control within its original limits"
            ;;
        *)
            test_result_record FAIL "$policy_name control or restoration failed, see $OUT_DIR/$policy_name"
            ;;
    esac
done
if [ "$TEST_RESULT_PASS_COUNT" -eq 0 ] && [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ]; then
    test_result_record SKIP "No exercisable CPUFreq policy, image must expose writable cpufreq controls"
fi
test_result_finish
