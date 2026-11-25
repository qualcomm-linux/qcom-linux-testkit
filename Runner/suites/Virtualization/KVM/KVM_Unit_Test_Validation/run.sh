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
. "$TOOLS/lib_kvm.sh"
TESTNAME="KVM_Unit_Test_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

TEST_DIR=""
TESTS=""
TIMEOUT="900"

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate image-provided KVM unit tests with hardware acceleration.
  --test-dir <value>  Installed kvm-unit-tests directory, otherwise standard image paths
  --tests <value>  Optional space-separated names from the installed test inventory
  --timeout <value>  Overall execution deadline in seconds
EOF
}

# parse_args <arguments>...
# Parse explicit values before accessing runtime evidence.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_finish FAIL "Missing value for $1"
        fi
        case "$2" in
            --*)
                test_result_finish FAIL "Missing value for $1 before option=$2"
                ;;
        esac
        case "$1" in
            --test-dir)
                TEST_DIR="$2"
                ;;
            --tests)
                TESTS="$2"
                ;;
            --timeout)
                TIMEOUT="$2"
                ;;
            *)
                test_result_finish FAIL "Unknown option=$1"
                ;;
        esac
        shift 2
    done
}

parse_args "$@"

# shellcheck disable=SC2034 # Read by the shared dependency helper.
CHECK_DEPS_RECOVER=0
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat awk grep sed tr uname mkdir mktemp date; then
    test_result_finish SKIP "Required shell tools are absent, provision them in the image"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create retained evidence under CWD=$PWD"


if ! printf '%s\n' "$TIMEOUT" | grep -Eq '^[1-9][0-9]{0,8}$'; then
    test_result_finish FAIL "--timeout must be a positive decimal integer of at most nine digits"
fi
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies bash env setsid getopt timeout getconf cp; then
    test_result_finish SKIP "Provision bash, env, setsid, enhanced getopt and GNU timeout with the packaged unit tests"
fi
getopt -T >/dev/null 2>&1
if [ "$?" -ne 4 ] || ! timeout --foreground 1 true >/dev/null 2>&1; then
    test_result_finish SKIP "Installed unit-test runner needs enhanced getopt and timeout --foreground, provide these image components"
fi
if [ -z "$TEST_DIR" ]; then
    for path in /opt/kvm-unit-tests /usr/lib/kvm-unit-tests /usr/libexec/kvm-unit-tests; do
        if [ -x "$path/run_tests.sh" ]; then
            TEST_DIR="$path"
            break
        fi
    done
fi
if [ -z "$TEST_DIR" ] || [ ! -x "$TEST_DIR/run_tests.sh" ] || [ ! -r "$TEST_DIR/config.mak" ]; then
    test_result_finish SKIP "No configured image-provided KVM unit-test bundle, provision it or pass --test-dir"
fi
TEST_DIR=$(cd "$TEST_DIR" && pwd -P) || test_result_finish FAIL "Cannot access the selected unit-test directory"
# The external runner expands config/log directory paths without quotes, even
# when rotating old logs. Reject unsupported paths before invoking that code.
if printf '%s\n' "$TEST_DIR" "$OUT_DIR" | grep -q '[[:space:]]'; then
    test_result_finish SKIP "The packaged unit runner requires bundle and working-directory paths without whitespace, relocate them before execution"
fi
if ! kvm_check_boot_dmesg_errors "$OUT_DIR/before"; then
    test_result_finish FAIL "KVM initialization contains faults, inspect $OUT_DIR/before"
fi
kvm_check_device_node
device_status=$?
if [ "$device_status" -eq 2 ]; then
    test_result_finish SKIP "No /dev/kvm, enable KVM and firmware virtualization support"
elif [ "$device_status" -ne 0 ]; then
    test_result_finish FAIL "The existing /dev/kvm is unusable, check permissions and device provisioning"
fi
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_finish SKIP "KVM validation needs readable kernel logs for pre/post health evidence"
fi
# ACCEL=kvm forbids the upstream runner from falling back to TCG. Preserve
# upstream nodefault exclusions, never force errata or manual-only tests.
# shellcheck disable=SC2034 # Shared timeout and finish consume these controls.
MANAGED_TIMEOUT_USE_SESSION=1
# shellcheck disable=SC2034
TEST_RESULT_CLEANUP=managed_timeout_cancel_bounded
trap 'test_result_finish FAIL "KVM unit validation interrupted"' HUP INT TERM
launch_dir="$PWD"
cd "$TEST_DIR" || test_result_finish FAIL "Cannot enter the selected unit-test directory"
run_with_managed_timeout 30 "$OUT_DIR" inventory env ACCEL=kvm TIMEOUT= bash ./run_tests.sh -l >"$OUT_DIR/inventory.list" 2>"$OUT_DIR/inventory-errors.log"
inventory_status=$?
if [ "$inventory_status" -ne 0 ] || ! awk '
    NF != 1 || $0 !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ || seen[$0]++ {bad=1}
    END {exit (NR == 0 || bad)}
' "$OUT_DIR/inventory.list"; then
    test_result_finish FAIL "Installed unit-test inventory is unavailable or malformed, inspect $OUT_DIR/inventory-errors.log"
fi
set --
if [ -n "$TESTS" ]; then
    if ! printf '%s\n' "$TESTS" | awk '
        {for (i=1; i<=NF; i++) if ($i !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ || seen[$i]++) bad=1; count+=NF}
        END {exit (!count || bad)}
    '; then
        test_result_finish FAIL "--tests must contain unique names from the installed inventory"
    fi
    : >"$OUT_DIR/expected.list"
    for name in $TESTS; do
        if ! grep -Fxq "$name" "$OUT_DIR/inventory.list"; then
            test_result_finish FAIL "Unknown requested unit test=$name, inspect $OUT_DIR/inventory.list"
        fi
        set -- "$@" "$name"
        printf '%s\n' "$name" >>"$OUT_DIR/expected.list"
    done
else
    cp "$OUT_DIR/inventory.list" "$OUT_DIR/expected.list" || test_result_finish FAIL "Cannot retain the expected case inventory"
fi
run_with_managed_timeout "$TIMEOUT" "$OUT_DIR" units env ACCEL=kvm TIMEOUT= unittest_run_queues=1 unittest_log_dir="$OUT_DIR/unit-logs" \
    bash ./run_tests.sh -v "$@" >"$OUT_DIR/runner.log" 2>&1
runner_status=$?
cd "$launch_dir" || test_result_finish FAIL "Cannot return to the suite working directory"
if [ "$runner_status" -ne 0 ]; then
    test_result_record FAIL "Unit-test runner exited status=$runner_status, inspect $OUT_DIR/runner.log"
fi
# Upstream returns success even when individual unit tests fail. Require one
# top-level verdict for every selected name and retain its detailed guest log.
sed "s/$(printf '\033')\[[0-9;]*m//g" "$OUT_DIR/runner.log" >"$OUT_DIR/runner-plain.log"
if ! awk '
    FILENAME == ARGV[1] {expected[$1]=1; next}
    /^(PASS|FAIL|SKIP)[[:space:]]/ {
        if (!($2 in expected) || seen[$2]++) bad=1
        result[$2]=$1
    }
    END {
        for (name in expected) {
            if (seen[name] != 1) {print name, "FAIL", "missing-or-duplicate-result"; bad=1}
            else print name, result[name]
        }
        exit bad
    }
' "$OUT_DIR/expected.list" "$OUT_DIR/runner-plain.log" >"$OUT_DIR/cases.tsv"; then
    test_result_record FAIL "Unit-test results are missing, duplicated or unexpected, inspect $OUT_DIR/cases.tsv"
fi
while read -r name verdict reason; do
    case "$verdict" in
        PASS|FAIL|SKIP)
            test_result_record "$verdict" "Unit test=$name ${reason:-see retained unit-logs and runner.log}"
            ;;
    esac
done <"$OUT_DIR/cases.tsv"
if ! kvm_check_boot_dmesg_errors "$OUT_DIR/after"; then
    test_result_record FAIL "KVM unit execution produced kernel faults, inspect $OUT_DIR/after"
elif [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_record FAIL "KVM kernel evidence became unavailable after unit execution"
fi

test_result_finish
