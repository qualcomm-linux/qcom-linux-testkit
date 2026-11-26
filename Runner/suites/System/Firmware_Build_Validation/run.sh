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
TESTNAME="Firmware_Build_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

EXPECTED_VERSION=""

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate the firmware-published BIOS version against the deployment contract.
  --expected-version <value>  Exact expected SMBIOS BIOS version
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
            --expected-version)
                EXPECTED_VERSION="$2"
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


if [ -z "$EXPECTED_VERSION" ]; then
    test_result_finish SKIP "Provide --expected-version from the deployed firmware build metadata"
fi
version_file=/sys/class/dmi/id/bios_version
if [ ! -e "$version_file" ]; then
    test_result_finish SKIP "Firmware does not expose SMBIOS BIOS version, use boot-console validation for that firmware"
fi
if ! cat "$version_file" >"$OUT_DIR/bios-version.log"; then
    test_result_finish FAIL "Cannot read exposed firmware version=$version_file"
fi
version=$(cat "$OUT_DIR/bios-version.log")
if [ -z "$version" ]; then
    test_result_finish FAIL "Firmware exposes an empty SMBIOS BIOS version"
fi
if [ "$version" = "$EXPECTED_VERSION" ]; then
    test_result_record PASS "Firmware BIOS version matches expected=$EXPECTED_VERSION"
else
    test_result_record FAIL "Firmware BIOS version=$version differs from expected=$EXPECTED_VERSION"
fi

test_result_finish
