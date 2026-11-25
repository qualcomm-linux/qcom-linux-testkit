#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd)" || exit 1

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
    echo "[ERROR] Could not find init_env, starting at $SCRIPT_DIR" >&2
    exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
TESTNAME="efivar_tool_available"
LAVA_CASE_ID="efivar_tool_available"
RES_FILE="$PWD/${TESTNAME}.res"
EFIVAR_LOG="$PWD/${TESTNAME}.command.log"

test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1
runner_install_bounded_timeout_cleanup

EFIVAR_PATH=$(command -v efivar 2>/dev/null)
if [ -z "$EFIVAR_PATH" ]; then
    case "${REQUIRE_EFIVAR:-false}" in
        1|true|TRUE|yes|YES)
            test_result_finish FAIL "efivar is required by this plan but is not installed in the image"
            ;;
        *)
            test_result_finish SKIP "efivar is optional and is not installed; set REQUIRE_EFIVAR=true when this plan requires EFI tooling"
            ;;
    esac
fi

if [ ! -x "$EFIVAR_PATH" ]; then
    test_result_finish FAIL "efivar was found at $EFIVAR_PATH but is not executable"
fi

if ! : > "$EFIVAR_LOG"; then
    test_result_finish FAIL "Could not create efivar output log: $EFIVAR_LOG"
fi

log_info "Checking efivar help output from $EFIVAR_PATH"
BOUNDED_TIMEOUT_EXPIRED=0
run_with_bounded_timeout 5 "$EFIVAR_PATH" --help > "$EFIVAR_LOG" 2>&1
EFIVAR_STATUS=$?
EFIVAR_TIMED_OUT=${BOUNDED_TIMEOUT_EXPIRED:-0}

log_info "Output from efivar --help (rc=$EFIVAR_STATUS):"
while IFS= read -r line || [ -n "$line" ]; do
    log_info "$line"
done < "$EFIVAR_LOG"

if [ "$EFIVAR_TIMED_OUT" -eq 1 ]; then
    test_result_finish FAIL "efivar --help exceeded its 5-second deadline"
fi

if [ "$EFIVAR_STATUS" -ne 0 ]; then
    if [ "$EFIVAR_STATUS" -ge 128 ]; then
        test_result_finish FAIL "efivar --help exited after signal termination (status $EFIVAR_STATUS)"
    fi
    test_result_finish FAIL "efivar --help exited with unexpected status $EFIVAR_STATUS"
fi

if ! grep -Fq "Usage: efivar" "$EFIVAR_LOG"; then
    test_result_finish FAIL "efivar --help did not print the expected usage text"
fi

test_result_record PASS "efivar is available, executable, and responds successfully to --help"
test_result_finish
