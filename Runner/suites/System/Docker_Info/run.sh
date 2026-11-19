#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="docker_info"
LAVA_CASE_ID="docker_info"
RES_FILE="$SCRIPT_DIR/${TEST_NAME}.res"

write_early_fail() {
    echo "$LAVA_CASE_ID FAIL" > "$RES_FILE"
    echo "[FAIL] $1" >&2
    exit 0
}

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
    write_early_fail "Could not find init_env, starting at $SCRIPT_DIR"
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1

cleanup_docker_info() {
    cleanup_status=$?
    trap - EXIT
    trap '' HUP INT TERM

    if ! bounded_timeout_cancel; then
        cleanup_status=1
    fi

    if [ "${__RUN_STDOUT_ACTIVE:-0}" -eq 1 ]; then
        _runner_stdout_cleanup "$cleanup_status"
    fi

    exit "$cleanup_status"
}

trap 'cleanup_docker_info' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail_test() {
    test_result_record FAIL "$1"
    test_result_finish
}

if ! command -v docker >/dev/null 2>&1; then
    fail_test "docker command not found on the DUT"
fi

if ! command -v grep >/dev/null 2>&1; then
    fail_test "grep command not found on the DUT"
fi

log_info "Starting Docker_Info test"
log_info "Running docker info with a 30-second deadline"

DOCKER_INFO_LOG="$SCRIPT_DIR/docker_info.log"
if ! : > "$DOCKER_INFO_LOG"; then
    fail_test "Could not create docker info output log: $DOCKER_INFO_LOG"
fi

run_with_bounded_timeout 30 docker info > "$DOCKER_INFO_LOG" 2>&1
DOCKER_STATUS=$?
DOCKER_TIMED_OUT=$BOUNDED_TIMEOUT_EXPIRED

log_info "docker info output retained in $DOCKER_INFO_LOG"
log_info "docker info output:"
while IFS= read -r line || [ -n "$line" ]; do
    log_info "$line"
done < "$DOCKER_INFO_LOG"

if [ "$DOCKER_TIMED_OUT" -eq 1 ]; then
    fail_test "docker info exceeded its 30-second deadline"
fi

if [ "$DOCKER_STATUS" -ne 0 ]; then
    fail_test "docker info failed; verify that the Docker daemon is running and accessible"
fi

# Remove carriage returns in case output was captured with CRLF line endings.
DOCKER_INFO_OUTPUT=$(tr -d '\r' < "$DOCKER_INFO_LOG")

check_field() {
    field_name="$1"
    accepted_values_regex="$2"

    if ! printf '%s\n' "$DOCKER_INFO_OUTPUT" |
        grep -Eq "^[[:space:]]*${field_name}:[[:space:]]*(${accepted_values_regex})[[:space:]]*$"; then
        fail_test "Expected '${field_name}' to match '${accepted_values_regex}' in docker info output"
    fi

    log_info "Verified ${field_name}"
}

check_field "Storage Driver" "vfs|overlay2|overlayfs"
check_field "Default Runtime" "runc"
check_field "Init Binary" "docker-init"
check_field "Docker Root Dir" "/var/lib/docker"

log_info "Completed Docker_Info test"
test_result_record PASS "Docker info contains the expected configuration"
test_result_finish
