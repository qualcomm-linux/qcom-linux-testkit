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

TESTNAME="watchdog"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0

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
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat mkdir mktemp date; then
    test_result_finish SKIP "Image-provided watchdog validation utilities are unavailable"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create evidence under CWD=$PWD"
log_info "Evidence: $OUT_DIR"

providers=0
for provider in /sys/class/watchdog/watchdog[0-9]*; do
    [ -d "$provider" ] || continue
    providers=$((providers + 1))
    node="/dev/${provider##*/}"
    identity=$(cat "$provider/identity" 2>/dev/null || true)
    if [ -z "$identity" ] || [ ! -c "$node" ]; then
        test_result_record FAIL "Registered watchdog ${provider##*/} lacks identity or character device $node"
    else
        test_result_record PASS "Watchdog provider=$identity node=$node, device was not opened or armed"
    fi
done
if [ "$providers" -eq 0 ]; then
    if [ -e /dev/watchdog ] && [ ! -c /dev/watchdog ]; then
        test_result_record FAIL "/dev/watchdog is not a character device"
    else
        test_result_record SKIP "No watchdog provider registered in sysfs"
    fi
fi
test_result_finish
