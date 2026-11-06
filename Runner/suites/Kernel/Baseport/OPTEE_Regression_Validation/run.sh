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
. "$TOOLS/lib_scenario.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_optee.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_optee_regression.sh"

TESTNAME="OPTEE_Regression_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

SCENARIO_TIMEOUT="60"
SCENARIO_EXERCISE="0"
SCENARIO_CASES="1003,1004,1005,1006"
SCENARIO_XTEST="xtest"
SCENARIO_TA_DIR=""

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
                SCENARIO_TIMEOUT="$2"
                ;;
            --exercise)
                SCENARIO_EXERCISE="$2"
                ;;
            --cases)
                SCENARIO_CASES="$2"
                ;;
            --xtest)
                SCENARIO_XTEST="$2"
                ;;
            --ta-dir)
                SCENARIO_TA_DIR="$2"
                ;;
            *)
                test_result_record FAIL "Unknown option: $1"
                test_result_finish
                ;;
        esac
        shift 2
    done
    if ! {
        scenario_positive_integer "$SCENARIO_TIMEOUT" 600
    }; then
        test_result_record FAIL "Invalid value for --timeout: $SCENARIO_TIMEOUT"
        test_result_finish
    fi
    if ! {
        [ "$SCENARIO_EXERCISE" = 0 ] || [ "$SCENARIO_EXERCISE" = 1 ]
    }; then
        test_result_record FAIL "Invalid value for --exercise: $SCENARIO_EXERCISE"
        test_result_finish
    fi
    if ! {
        printf '%s\n' "$SCENARIO_CASES" | awk '/^100[3-6](,100[3-6])*$/ {ok=1} END {exit !ok}'
    }; then
        test_result_record FAIL "Invalid value for --cases: $SCENARIO_CASES"
        test_result_finish
    fi
}

parse_args "$@"
scenario_start
log_info "[OPTIONS] --xtest=$SCENARIO_XTEST"
log_info "[OPTIONS] --ta-dir=$SCENARIO_TA_DIR"
if ! optee_regression_run; then
    test_result_record FAIL "Scenario could not complete, inspect artifacts=$SCENARIO_DIR"
fi
scenario_finish
