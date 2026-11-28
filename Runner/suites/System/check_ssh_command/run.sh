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
TESTNAME="check_ssh_command"
LAVA_CASE_ID="check_ssh_command"
RES_FILE="$PWD/${TESTNAME}.res"
SSH_LOG="$PWD/${TESTNAME}.version.log"

test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1
runner_install_bounded_timeout_cleanup

SSH_COMMAND=$(command -v ssh 2>/dev/null)
if [ -z "$SSH_COMMAND" ] || [ ! -x "$SSH_COMMAND" ]; then
    test_result_finish SKIP "SSH client is not installed or executable; install it in the image if this plan requires SSH"
fi

if ! : > "$SSH_LOG"; then
    test_result_finish FAIL "Could not create SSH version log: $SSH_LOG"
fi

log_info "Checking SSH command discovered in PATH: $SSH_COMMAND"
BOUNDED_TIMEOUT_EXPIRED=0
run_with_bounded_timeout 5 "$SSH_COMMAND" -V > "$SSH_LOG" 2>&1
SSH_STATUS=$?
SSH_TIMED_OUT=${BOUNDED_TIMEOUT_EXPIRED:-0}
SSH_VERSION=$(cat "$SSH_LOG")
log_info "ssh -V output (rc=$SSH_STATUS): ${SSH_VERSION:-<empty>}"

if [ "$SSH_TIMED_OUT" -eq 1 ]; then
    test_result_finish FAIL "ssh -V exceeded its 5-second deadline"
fi

if [ "$SSH_STATUS" -ne 0 ]; then
    test_result_finish FAIL "ssh -V failed with exit status $SSH_STATUS"
fi

case "$SSH_VERSION" in
    *OpenSSH_*)
        ;;
    *)
        test_result_finish FAIL "ssh -V did not identify an OpenSSH client"
        ;;
esac

SSH_RESOLVED="$SSH_COMMAND"
SSH_LINK_COUNT=0
if [ -L "$SSH_COMMAND" ]; then
    if command -v readlink >/dev/null 2>&1; then
        while [ -L "$SSH_RESOLVED" ]; do
            SSH_LINK_COUNT=$((SSH_LINK_COUNT + 1))
            if [ "$SSH_LINK_COUNT" -gt 40 ]; then
                test_result_finish FAIL "SSH command symlink chain exceeds 40 links: $SSH_COMMAND"
            fi

            SSH_LINK_TARGET=$(readlink "$SSH_RESOLVED" 2>/dev/null)
            if [ -z "$SSH_LINK_TARGET" ]; then
                test_result_finish FAIL "Could not resolve SSH command symlink: $SSH_RESOLVED"
            fi

            case "$SSH_LINK_TARGET" in
                /*) SSH_RESOLVED="$SSH_LINK_TARGET" ;;
                *) SSH_RESOLVED="$(dirname "$SSH_RESOLVED")/$SSH_LINK_TARGET" ;;
            esac
        done

        if [ ! -x "$SSH_RESOLVED" ]; then
            test_result_finish FAIL "PATH-selected SSH command does not resolve to an executable: $SSH_COMMAND"
        fi
        log_info "PATH-selected SSH command $SSH_COMMAND resolves to $SSH_RESOLVED"
    else
        # The selected symlink already passed -x and bounded ssh -V; do not
        # make the optional readlink utility a prerequisite for SSH readiness.
        log_info "PATH-selected SSH symlink passed the bounded ssh -V check; readlink is unavailable for target reporting"
    fi
else
    log_info "PATH-selected SSH command is a regular executable: $SSH_COMMAND"
fi

test_result_record PASS "SSH client is executable and reports an OpenSSH version"
test_result_finish
