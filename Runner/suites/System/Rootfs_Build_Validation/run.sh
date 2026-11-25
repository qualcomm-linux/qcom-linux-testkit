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
TESTNAME="Rootfs_Build_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

EXPECTED_BUILD_ID=""
RELEASE_FILE=""

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate the rootfs BUILD_ID against the deployment contract.
  --expected-build-id <value>  Exact expected BUILD_ID
  --release-file <value>  Optional os-release path, defaults to /etc then /usr/lib/os-release
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
            --expected-build-id)
                EXPECTED_BUILD_ID="$2"
                ;;
            --release-file)
                RELEASE_FILE="$2"
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


if [ -z "$EXPECTED_BUILD_ID" ]; then
    test_result_finish SKIP "Provide --expected-build-id from the deployed rootfs build metadata"
fi
if [ -z "$RELEASE_FILE" ]; then
    if [ -e /etc/os-release ]; then
        RELEASE_FILE=/etc/os-release
    else
        RELEASE_FILE=/usr/lib/os-release
    fi
fi
if [ ! -e "$RELEASE_FILE" ]; then
    test_result_finish SKIP "Rootfs metadata=$RELEASE_FILE is absent, provision os-release with BUILD_ID"
fi
if ! cat "$RELEASE_FILE" >"$OUT_DIR/os-release.log"; then
    test_result_finish FAIL "Cannot read existing rootfs metadata=$RELEASE_FILE"
fi
# Parse data only. Sourcing os-release would execute arbitrary shell content.
# Preserve case, unlike pkg_os_release_value which normalizes distro identifiers.
awk '
    /^BUILD_ID=/ {
        count++
        value = substr($0, 10)
        quote = substr(value, 1, 1)
        if (quote == "\047" || quote == "\042") {
            if (length(value) < 2 || substr(value, length(value), 1) != quote) exit 1
            value = substr(value, 2, length(value) - 2)
            if (quote == "\042") {
                decoded = ""
                for (i = 1; i <= length(value); i++) {
                    ch = substr(value, i, 1)
                    if (ch == "\\") {
                        i++
                        ch = substr(value, i, 1)
                        if (ch !~ /^[\\$`"]$/) exit 1
                    } else if (ch ~ /^["$`]$/) exit 1
                    decoded = decoded ch
                }
                value = decoded
            } else if (index(value, "\047")) exit 1
        } else if (value !~ /^[A-Za-z0-9_.+-]+$/) exit 1
        if (value == "") exit 1
        print value
    }
    END { if (count > 1) exit 1 }
' "$OUT_DIR/os-release.log" >"$OUT_DIR/build-id.log" ||
    test_result_finish FAIL "BUILD_ID is malformed or duplicated in $RELEASE_FILE"
if [ ! -s "$OUT_DIR/build-id.log" ]; then
    test_result_finish SKIP "BUILD_ID is not provisioned in $RELEASE_FILE, add immutable build metadata to the image"
fi
build_id=$(cat "$OUT_DIR/build-id.log")
if [ "$build_id" = "$EXPECTED_BUILD_ID" ]; then
    test_result_record PASS "Rootfs BUILD_ID matches expected=$EXPECTED_BUILD_ID"
else
    test_result_record FAIL "Rootfs BUILD_ID=$build_id differs from expected=$EXPECTED_BUILD_ID"
fi

test_result_finish
