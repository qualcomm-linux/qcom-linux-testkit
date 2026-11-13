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
# shellcheck disable=SC1091
. "$TOOLS/lib_optee.sh"

TESTNAME="OPTEE_Regression_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

TEST_RUN_TIMEOUT="60"
TEST_RUN_EXERCISE="0"
TEST_RUN_CASES="1003,1004,1005,1006"
TEST_RUN_XTEST="xtest"
TEST_RUN_TA_DIR=""

# usage
# Show the suite options and safe defaults.
usage() {
    cat <<EOF
Usage: $0 [options]
Opt-in reviewed OP-TEE mutex, crypto, multi-session and basic OS regressions beyond native smoke.
  --timeout <value> (default: 60)
  --exercise <value> (default: 0)
  --cases <value> (default: 1003,1004,1005,1006)
  --xtest <value> (default: xtest)
  --ta-dir <value> (default: unset)
  --help
EOF
}

# parse_args <arguments>...
# Reject malformed overrides before runtime discovery or state changes.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_record FAIL "Missing value for $1"
            test_result_finish
        fi
        case "$2" in
            --*)
                test_result_record FAIL "Missing value for $1 before option=$2"
                test_result_finish
                ;;
        esac
        case "$1" in
            --timeout)
                TEST_RUN_TIMEOUT="$2"
                ;;
            --exercise)
                TEST_RUN_EXERCISE="$2"
                ;;
            --cases)
                TEST_RUN_CASES="$2"
                ;;
            --xtest)
                TEST_RUN_XTEST="$2"
                ;;
            --ta-dir)
                TEST_RUN_TA_DIR="$2"
                ;;
            *)
                test_result_record FAIL "Unknown option: $1"
                test_result_finish
                ;;
        esac
        shift 2
    done
    if ! {
        is_bounded_positive_integer "$TEST_RUN_TIMEOUT" 600
    }; then
        test_result_record FAIL "Invalid value for --timeout: $TEST_RUN_TIMEOUT"
        test_result_finish
    fi
    if ! {
        [ "$TEST_RUN_EXERCISE" = 0 ] || [ "$TEST_RUN_EXERCISE" = 1 ]
    }; then
        test_result_record FAIL "Invalid value for --exercise: $TEST_RUN_EXERCISE"
        test_result_finish
    fi
    if ! {
        printf '%s\n' "$TEST_RUN_CASES" | awk '/^100[3-6](,100[3-6])*$/ {ok=1} END {exit !ok}'
    }; then
        test_result_record FAIL "Invalid value for --cases: $TEST_RUN_CASES"
        test_result_finish
    fi
}

parse_args "$@"
test_run_start
log_info "[OPTIONS] --xtest=$TEST_RUN_XTEST"
log_info "[OPTIONS] --ta-dir=$TEST_RUN_TA_DIR"

# ---------- Runtime validation ----------
if [ "$TEST_RUN_EXERCISE" != 1 ] || [ -z "$TEST_RUN_CASES" ]; then
    test_result_record SKIP "Additional TA regressions require --exercise --cases with reviewed case IDs, native smoke defaults remain separate"
    test_run_finish
fi
test_require_commands awk cat cut find grep readlink sort tr || test_run_finish
optee_capture_device_inventory "$TEST_RUN_DIR/tee-devices.tsv" || test_run_finish FAIL "OPTEE_Regression_Validation could not complete, inspect artifacts=$TEST_RUN_DIR"
optee_log_device_inventory "$TEST_RUN_DIR/tee-devices.tsv" 16
selection=$(optee_select_device "$TEST_RUN_DIR/tee-devices.tsv")
if [ -z "$selection" ]; then
    test_result_record SKIP "No native public OP-TEE device was discovered"
    test_run_finish
fi
device=$(printf '%s\n' "$selection" | cut -f1)
test_require_commands "$TEST_RUN_XTEST" || test_run_finish
binary=$(command -v "$TEST_RUN_XTEST" 2>/dev/null)
if [ -z "$binary" ]; then
    test_result_record SKIP "Native OP-TEE device=$device has no image-provided xtest binary"
    test_run_finish
fi
# The supplied case list is a job/operator-reviewed test-tier contract.
# Never run the entire catalogue or expand the native smoke allowlist.
case_list=$(printf '%s\n' "$TEST_RUN_CASES" | tr ',' '\n' | sort -u)
test_capture_kernel_log kernel-before || true
for case_id in $case_list; do
    uuid=""
    case "$case_id" in
        1003)
            ;;
        1004)
            uuid=cb3e5ba0-adf1-11e0-998b-0002a5d5c51b
            ;;
        1005)
            uuid=e13010e0-2ae1-11e5-896a-0002a5d5c51b
            ;;
        1006)
            uuid=5b9e0e40-2636-11e1-ad9e-0002a5d5c51b
            ;;
        *)
            test_result_record FAIL "Case=$case_id is outside the reviewed non-provisioning tier: 1003,1004,1005,1006"
            continue
            ;;
    esac
    if [ -n "$uuid" ]; then
        asset=""
        for root in /lib/optee_armtz /usr/lib/optee_armtz "$TEST_RUN_TA_DIR"; do
            if [ -n "$root" ] && [ -r "$root/$uuid.ta" ]; then
                asset="$root/$uuid.ta"
                break
            fi
        done
        if [ -z "$asset" ]; then
            test_result_record SKIP "Case=$case_id requires image-provided TA=$uuid.ta, supply --ta-dir for an installed alternate directory"
            continue
        fi
    fi
    log_info "[OPTEE-REGRESSION] selected_case=$case_id device=$device prerequisites=matching-image-provided-TAs"
    test_run_command "xtest-$case_id" "$binary" -d optee-tz -t regression -l 0 "$case_id"
    status=$?
    optee_regression_summary "$TEST_RUN_DIR/xtest-$case_id.log" "$case_id"
    summary=$?
    if [ "$status" = 0 ] && [ "$summary" = 0 ]; then
        # shellcheck disable=SC2034 # Required by test_run_finish.
        TEST_RUN_VALIDATED=1
        test_result_record PASS "OP-TEE regression case=$case_id completed with zero failures"
    elif [ "$status" = 0 ] && [ "$summary" = 2 ]; then
        test_result_record SKIP "OP-TEE regression case=$case_id was explicitly skipped by xtest, inspect optional PTA/TA prerequisites"
    else
        test_result_record FAIL "OP-TEE regression case=$case_id failed or lacks complete selected-case evidence, process_status=$status"
    fi
done
test_capture_kernel_log kernel-after || true
test_check_kernel_delta kernel-before kernel-after \
    'BUG:|WARNING:|Oops:|panic|Call trace:|optee.*(failed|error)|mem_reclaim:' || true
test_run_finish
