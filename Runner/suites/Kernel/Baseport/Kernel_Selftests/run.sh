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
. "$TOOLS/lib_kselftest.sh"

TESTNAME="Kernel_Selftests"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
SELFTEST_DIR=${SELFTEST_DIR:-}
ALLOWLIST=${ALLOWLIST:-$SCRIPT_DIR/enabled_tests.list}
TIMEOUT=${TIMEOUT:-300}

# usage
# Print selection and timeout options.
usage() {
    echo "Usage: $0 [--selftest-dir DIR] [--allowlist FILE] [--timeout SECONDS]"
}

# parse_args <arguments...>
# Validate options before launching any kernel selftest.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --selftest-dir|--allowlist|--timeout)
                [ "$#" -ge 2 ] || test_result_finish FAIL "Missing value for $1"
                case "$1" in
                    --selftest-dir)
                        if [ -n "$2" ]; then
                            SELFTEST_DIR=$2
                        fi
                        ;;
                    --allowlist)
                        ALLOWLIST=$2
                        ;;
                    --timeout)
                        TIMEOUT=$2
                        ;;
                esac
                shift 2
                ;;
            *)
                test_result_finish FAIL "Unknown option: $1"
                ;;
        esac
    done
}
parse_args "$@"
if ! is_unsigned_number "$TIMEOUT" || [ "$TIMEOUT" -eq 0 ]; then
    test_result_finish FAIL "Timeout must be a positive integer"
fi
if [ -z "$SELFTEST_DIR" ]; then
    for candidate in /kselftest /usr/lib/kselftests /usr/libexec/kselftests; do
        [ -d "$candidate" ] || continue
        SELFTEST_DIR=$candidate
        break
    done
fi
[ -d "$SELFTEST_DIR" ] || test_result_finish SKIP "Installed kernel selftests absent, no payloads will be downloaded"
[ -r "$ALLOWLIST" ] || test_result_finish FAIL "Cannot read selftest allowlist: $ALLOWLIST"
command -v setsid >/dev/null 2>&1 || test_result_finish SKIP "setsid is not supplied, bounded selftest process-group cleanup unavailable"
SELFTEST_DIR=$(cd "$SELFTEST_DIR" && pwd -P) || test_result_finish FAIL "Cannot resolve selftest directory"
OUT_DIR=$(mktemp -d "$PWD/kselftest-run.XXXXXX") || test_result_finish FAIL "Cannot create evidence directory in $PWD"
trap 'test_result_finish FAIL "Kernel selftests interrupted, inspect $OUT_DIR"' HUP INT TERM
kselftest_select "$SELFTEST_DIR" "$ALLOWLIST" "$OUT_DIR/selected.list" || test_result_finish FAIL "Invalid selftest selection, see $ALLOWLIST"
log_info "Selected kernel selftests: $OUT_DIR/selected.list"
while IFS= read -r selection; do
    [ -n "$selection" ] || continue
    kselftest_run_one "$SELFTEST_DIR" "$selection" "$OUT_DIR" "$TIMEOUT" || test_result_record FAIL "Could not retain evidence for $selection"
done <"$OUT_DIR/selected.list"
test_result_finish
