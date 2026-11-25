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
TESTNAME="TEE_Memory_Reclaim_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

BINARY=""
ROUNDS="20"
PAGES="1 64 1024"
MIN_RANGES="0"
TRANSPORT="any"
TIMEOUT="120"

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate repeated TEE user-memory registration, release and re-registration.
  --binary <value>  Installed tee-shm-reclaim executable, otherwise PATH discovery
  --rounds <value>  Registration rounds per buffer, at least 2
  --pages <value>  Unique positive decimal buffer sizes in pages
  --min-ranges <value>  Optional minimum physical ranges for the final size
  --transport <value>  any or ffa, verified against the tested TEE device
  --timeout <value>  Maximum helper runtime in seconds
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
            --binary)
                BINARY="$2"
                ;;
            --rounds)
                ROUNDS="$2"
                ;;
            --pages)
                PAGES="$2"
                ;;
            --min-ranges)
                MIN_RANGES="$2"
                ;;
            --transport)
                TRANSPORT="$2"
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


for value in "$ROUNDS" "$TIMEOUT"; do
    if ! printf '%s\n' "$value" | grep -Eq '^[1-9][0-9]*$' ||
       ! awk -v value="$value" 'BEGIN {exit !(value <= 2147483647)}'; then
        test_result_finish FAIL "Rounds and timeout must be positive decimal integers within the client integer interface"
    fi
done
if [ "$ROUNDS" -lt 2 ]; then
    test_result_finish FAIL "At least two rounds are required to validate re-registration"
fi
if [ "${#TIMEOUT}" -gt 9 ]; then
    test_result_finish FAIL "--timeout must contain at most nine digits for the shared timeout helper"
fi
if ! printf '%s\n' "$MIN_RANGES" | grep -Eq '^(0|[1-9][0-9]*)$' ||
   ! awk -v value="$MIN_RANGES" 'BEGIN {exit !(value <= 2147483647)}'; then
    test_result_finish FAIL "--min-ranges must be a nonnegative decimal integer within the client interface"
fi
case "$TRANSPORT" in
    any|ffa)
        ;;
    *)
        test_result_finish FAIL "--transport must be any or ffa"
        ;;
esac
if ! printf '%s\n' "$PAGES" | awk '
    {
        for (i=1; i<=NF; i++) {
            if ($i !~ /^[1-9][0-9]*$/ || $i+0 > 2147483647 || seen[$i]++) exit 1
            count++
        }
    }
    END {if (!count) exit 1}
'; then
    test_result_finish FAIL "--pages must contain unique positive decimal page counts within the client interface"
fi
# The installed reference helper has a fixed /dev/tee0 ABI. Do not silently
# discover another node while allowing the helper to exercise the wrong TEE.
if [ ! -c /dev/tee0 ]; then
    test_result_finish SKIP "The installed helper requires /dev/tee0, provision a matching TEE driver and helper"
fi
if [ ! -r /dev/tee0 ] || [ ! -w /dev/tee0 ]; then
    test_result_finish SKIP "TEE memory registration requires read/write access to /dev/tee0"
fi
if [ -z "$BINARY" ]; then
    BINARY=$(command -v tee-shm-reclaim 2>/dev/null || true)
else
    BINARY=$(command -v "$BINARY" 2>/dev/null || true)
fi
if [ -z "$BINARY" ] || [ ! -x "$BINARY" ]; then
    test_result_finish SKIP "Provision the tee-shm-reclaim helper in the image or pass --binary, no runtime compilation is performed"
fi
if [ "$TRANSPORT" = ffa ]; then
    if ! CHECK_DEPS_NO_EXIT=1 check_dependencies readlink; then
        test_result_finish SKIP "FF-A transport validation requires image-provided readlink"
    fi
    device=$(readlink -f /sys/class/tee/tee0/device 2>/dev/null)
    transport_found=0
    while [ -n "$device" ] && [ "$device" != / ]; do
        subsystem=$(readlink -f "$device/subsystem" 2>/dev/null)
        if [ "${subsystem##*/}" = arm_ffa ] && [ -e "$device/driver" ]; then
            transport_found=1
            printf 'tee=/dev/tee0 device=%s driver=%s\n' "$device" "$(readlink -f "$device/driver")" >"$OUT_DIR/transport.log"
            break
        fi
        device=${device%/*}
    done
    if [ "$transport_found" -ne 1 ]; then
        test_result_finish SKIP "The tested /dev/tee0 is not bound through FF-A, use an FF-A OP-TEE image for --transport ffa"
    fi
fi
if [ "$MIN_RANGES" -gt 0 ] && [ ! -r /proc/self/pagemap ]; then
    test_result_finish SKIP "Physical-range verification needs /proc/self/pagemap access and CAP_SYS_ADMIN"
fi
scan_dmesg_errors "$OUT_DIR/before" 'optee|tee|arm_ffa|ffa' '' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_finish SKIP "Reclaim validation needs readable kernel logs, grant log access before execution"
fi
if [ -s "$OUT_DIR/before/dmesg_errors.log" ] ||
   grep -Eq 'mem_reclaim:|shm_unregister.*(fail|error)' "$OUT_DIR/before/dmesg_snapshot.log"; then
    test_result_finish FAIL "TEE kernel faults already exist before execution, inspect $OUT_DIR/before"
fi
printf 'binary=%s rounds=%s pages=%s min_ranges=%s transport=%s\n' \
    "$BINARY" "$ROUNDS" "$PAGES" "$MIN_RANGES" "$TRANSPORT" >"$OUT_DIR/invocation.log"
set -- "$ROUNDS" "$MIN_RANGES"
for pages in $PAGES; do
    set -- "$@" "$pages"
done
# shellcheck disable=SC2034 # Shared finish invokes the owned-child cleanup.
TEST_RESULT_CLEANUP=bounded_timeout_cancel
trap 'test_result_finish FAIL "TEE memory reclaim validation interrupted"' HUP INT TERM
run_with_bounded_timeout "$TIMEOUT" "$BINARY" "$@" >"$OUT_DIR/helper.log" 2>&1
helper_status=$?
scan_dmesg_errors "$OUT_DIR/after" 'optee|tee|arm_ffa|ffa' '' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_finish FAIL "Kernel evidence became unavailable after memory registration, inspect $OUT_DIR/after"
fi
if [ -s "$OUT_DIR/after/dmesg_errors.log" ] ||
   grep -Eq 'mem_reclaim:|shm_unregister.*(fail|error)' "$OUT_DIR/after/dmesg_snapshot.log"; then
    test_result_finish FAIL "TEE memory release produced kernel faults, inspect $OUT_DIR/after"
fi
if [ "$helper_status" -eq 77 ]; then
    if grep -q '^tee-shm-reclaim-.* ' "$OUT_DIR/helper.log" ||
       ! grep -Fq 'no TEE_GEN_CAP_REG_MEM' "$OUT_DIR/helper.log"; then
        test_result_finish FAIL "Helper returned SKIP after partial execution or without a dynamic-memory capability reason"
    fi
    test_result_finish SKIP "The tested TEE lacks TEE_GEN_CAP_REG_MEM, use a dynamic-shared-memory-enabled image"
fi
if [ "$helper_status" -ne 0 ]; then
    test_result_finish FAIL "Memory registration helper exited status=$helper_status, inspect $OUT_DIR/helper.log"
fi
if ! awk -v pages="$PAGES" '
    BEGIN {
        expected["tee-shm-reclaim-open"]=1
        count=split(pages, sizes, /[[:space:]]+/)
        for (i=1; i<=count; i++) if (sizes[i] != "") expected["tee-shm-reclaim-" sizes[i] "p"]=1
    }
    /^tee-shm-reclaim-/ {
        if (NF != 2 || !($1 in expected) || $2 != "pass" || seen[$1]++) bad=1
    }
    END {
        for (name in expected) if (seen[name] != 1) bad=1
        exit bad
    }
' "$OUT_DIR/helper.log"; then
    test_result_finish FAIL "Helper results are failed, missing, duplicated or unexpected, inspect $OUT_DIR/helper.log"
fi
test_result_record PASS "All requested buffers were repeatedly registered and released without captured reclaim errors"

test_result_finish
