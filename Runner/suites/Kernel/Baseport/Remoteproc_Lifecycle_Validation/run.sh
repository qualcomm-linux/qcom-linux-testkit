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

TESTNAME="Remoteproc_Lifecycle_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

TEST_RUN_TIMEOUT="60"
TEST_RUN_PROCESSORS="auto"

# usage
# Show the suite options and safe defaults.
usage() {
    cat <<EOF
Usage: $0 [options]
Runtime lifecycle expectations and retained evidence of recovered remoteproc crashes.
  --timeout <value> (default: 60)
  --processors <value> (default: auto)
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
            --processors)
                TEST_RUN_PROCESSORS="$2"
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
        printf '%s\n' "$TEST_RUN_PROCESSORS" | awk '/^[A-Za-z0-9_.:@-]+(,[A-Za-z0-9_.:@-]+)*$/ {ok=1} END {exit !ok}'
    }; then
        test_result_record FAIL "Invalid value for --processors: $TEST_RUN_PROCESSORS"
        test_result_finish
    fi
}

parse_args "$@"
test_run_start

# ---------- Runtime validation ----------
if ! remoteproc_inventory; then
    test_result_record SKIP "No selected runtime remoteproc, check enabled DT and firmware"
    test_run_finish
fi
test_capture_kernel_log kernel-boot || true
while IFS='|' read -r path name firmware state owner; do
    identifier="${path##*/} ($name, owner=${owner##*/})"
    case "$state" in
        running|attached)
            # shellcheck disable=SC2034 # Required by test_run_finish.
            TEST_RUN_VALIDATED=1
            test_result_record PASS "$identifier state=$state"
            ;;
        offline)
            if [ "$TEST_RUN_PROCESSORS" = auto ]; then
                test_result_record SKIP "$identifier is offline with unconfirmed lifecycle policy, use --processors to require it running"
            else
                test_result_record FAIL "$identifier was explicitly required but state=offline"
            fi
            ;;
        *)
            test_result_record FAIL "$identifier unexpected state=${state:-unreadable}"
            ;;
    esac
    if [ -s "$TEST_RUN_DIR/kernel-boot/dmesg_snapshot.log" ]; then
        if grep -F "${path##*/}: crash detected" "$TEST_RUN_DIR/kernel-boot/dmesg_snapshot.log" \
            >"$TEST_RUN_DIR/${path##*/}-crashes.log"; then
            log_file_with_label REMOTEPROC-CRASH "$TEST_RUN_DIR/${path##*/}-crashes.log" 20
            test_result_record FAIL "$identifier crashed since boot, including recovered crashes"
        else
            test_result_record PASS "$identifier has no retained crash report"
        fi
    else
        test_result_record SKIP "$identifier crash history is unavailable"
    fi
    log_info "[$identifier] firmware=$firmware runtime_owner=$owner"
done <"$TEST_RUN_DIR/remoteprocs.selected"
test_run_finish
