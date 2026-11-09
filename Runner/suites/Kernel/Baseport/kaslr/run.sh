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

TESTNAME="kaslr"
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
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat grep awk sed tr mkdir mktemp date uname; then
    test_result_finish SKIP "Image-provided kaslr validation utilities are unavailable"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create evidence under CWD=$PWD"
log_info "Evidence: $OUT_DIR"

config_value=$(kernel_config_value CONFIG_RANDOMIZE_BASE || true)
config_source=$(kernel_config_source || true)
log_info "CONFIG_RANDOMIZE_BASE=${config_value:-unknown} source=${config_source:-unavailable}"
if grep -Eq '(^|[[:space:]])nokaslr([[:space:]]|$)' /proc/cmdline; then
    test_result_finish FAIL "KASLR is disabled by the boot command line"
fi
case "$config_value" in
    y)
        ;;
    n|not-set)
        test_result_finish FAIL "Kernel configuration disables address randomization"
        ;;
    *)
        test_result_finish SKIP "KASLR configuration evidence is unavailable"
        ;;
esac
scan_dmesg_errors "$OUT_DIR" 'kaslr|randomiz|Kernel Offset' '' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" = available ] &&
   grep -Eiq 'KASLR.*disabled|Kernel Offset:[[:space:]]+disabled' "$OUT_DIR/dmesg_snapshot.log"; then
    test_result_finish FAIL "Boot evidence reports KASLR disabled"
fi
symbol=$(awk '$3 == "_stext" || $3 == "stext" {print $1; exit}' /proc/kallsyms 2>/dev/null || true)
case "$symbol" in
    ''|*[![:xdigit:]]*)
        test_result_finish SKIP "Runtime KASLR symbol evidence is unavailable"
        ;;
esac
if ! printf '%s\n' "$symbol" | grep -q '[1-9a-fA-F]'; then
    test_result_finish SKIP "Kernel addresses are hidden, zero kallsyms data cannot verify runtime KASLR"
fi
log_info "Runtime kernel text symbol=$symbol, one boot cannot establish cross-boot randomness"
test_result_finish PASS "KASLR configuration and runtime symbol evidence available with no observed boot disable, cross-boot randomness was not tested"
