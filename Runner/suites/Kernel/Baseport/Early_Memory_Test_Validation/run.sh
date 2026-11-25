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
TESTNAME="Early_Memory_Test_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

EXPECTED_PASSES=""

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate completed kernel early memory testing and retained pattern coverage.
  --expected-passes <value>  Optional positive expected pattern-pass count
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
            --expected-passes)
                EXPECTED_PASSES="$2"
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


if [ -n "$EXPECTED_PASSES" ] && ! printf '%s\n' "$EXPECTED_PASSES" | grep -Eq '^[1-9][0-9]*$'; then
    test_result_finish FAIL "--expected-passes must be a positive decimal integer"
fi
if ! cat /proc/cmdline >"$OUT_DIR/cmdline.log"; then
    test_result_finish SKIP "Kernel command line is inaccessible, provide procfs"
fi
argument=$(awk '{for (i=1; i<=NF; i++) if ($i == "memtest" || $i ~ /^memtest=/) selected=$i} END {print selected}' "$OUT_DIR/cmdline.log")
if [ -z "$argument" ]; then
    test_result_finish SKIP "Early memory testing was not requested, use a separate boot with CONFIG_MEMTEST and memtest=N"
fi
configured=""
if [ "$argument" != memtest ]; then
    raw=${argument#memtest=}
    case "$raw" in
        ''|*[!0-9a-fA-FxX]*)
            test_result_finish FAIL "Kernel memtest argument=$argument is malformed"
            ;;
    esac
    configured=$(printf '%d' "$raw" 2>/dev/null) ||
        test_result_finish FAIL "Kernel memtest argument=$argument is not a supported unsigned integer"
    if [ "$configured" -eq 0 ]; then
        test_result_finish SKIP "Kernel memtest=0 disables early memory testing, select a positive pass count at boot"
    fi
    if [ "$configured" -lt 0 ] || ! awk -v value="$configured" 'BEGIN {exit !(value <= 4294967295)}'; then
        test_result_finish FAIL "Kernel memtest argument exceeds the unsigned integer interface"
    fi
fi
config=$(kernel_config_state CONFIG_MEMTEST 2>"$OUT_DIR/config.log")
config_status=$?
if [ "$config_status" -eq 0 ] && [ "$config" != y ]; then
    test_result_finish SKIP "Running kernel does not enable CONFIG_MEMTEST, use a memory-test-enabled image"
fi
scan_dmesg_errors "$OUT_DIR/kernel" 'early_memtest|bad mem addr' '' || true
snapshot="$OUT_DIR/kernel/dmesg_snapshot.log"
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_finish SKIP "Kernel log is inaccessible, retain early memory-test evidence and grant log access"
fi
if ! cat /proc/meminfo >"$OUT_DIR/meminfo.log"; then
    test_result_finish FAIL "Cannot capture /proc/meminfo for early memory-test completion"
fi
if grep -Fq 'bad mem addr' "$snapshot"; then
    test_result_finish FAIL "Kernel early memory testing reserved bad memory, inspect $snapshot"
fi
if ! awk '
    /^EarlyMemtestBad:/ {
        count++
        if (NF != 3 || $2 !~ /^[0-9]+$/ || $3 != "kB" || $2 != 0) bad=1
    }
    END {if (count > 1 || bad) exit 1; if (count == 0) exit 2}
' "$OUT_DIR/meminfo.log"; then
    # Distinguish a missing completion field from a positive or malformed value.
    if grep -q '^EarlyMemtestBad:' "$OUT_DIR/meminfo.log"; then
        test_result_finish FAIL "EarlyMemtestBad is nonzero or malformed, inspect $OUT_DIR/meminfo.log"
    fi
    test_result_finish SKIP "Kernel has no EarlyMemtestBad completion evidence, use a kernel exposing the early memtest result"
fi
if ! grep -Fq 'early_memtest: # of tests:' "$snapshot"; then
    test_result_finish SKIP "Early memory-test completion exists but its pattern log was lost, retain a larger boot log"
fi
# The kernel logs each pass before testing every free range and reports completion
# through EarlyMemtestBad. A bare memtest uses the running kernel pattern table,
# so no table length or physical-memory size is hardcoded here.
if awk -v requested="$configured" -v expected="$EXPECTED_PASSES" '
    /early_memtest: # of tests:/ {
        if (groups && passes != announced) bad=1
        text=$0
        sub(/^.*early_memtest: # of tests: /, "", text)
        if (text !~ /^[1-9][0-9]*[[:space:]]*$/) bad=1
        announced=text+0
        if (requested != "" && announced != requested+0) bad=1
        if (expected != "" && announced != expected+0) bad=1
        groups++
        passes=0
        pattern=""
        next
    }
    /0x[0-9a-fA-F]+ - 0x[0-9a-fA-F]+ pattern / {
        if (!groups || $NF !~ /^[0-9a-fA-F]+$/ || length($NF) != 16) bad=1
        if ($NF != pattern) {
            passes++
            pattern=$NF
        }
        ranges++
    }
    END {
        print "sections=" groups, "last_passes=" passes, "last_expected=" announced, "ranges=" ranges
        if (!groups || !ranges || passes != announced || bad) exit 1
    }
' "$snapshot" >"$OUT_DIR/pattern-summary.log"; then
    test_result_record PASS "Early memory test completed all logged passes with EarlyMemtestBad=0, inspect $OUT_DIR/pattern-summary.log"
else
    test_result_record FAIL "Early memory-test pattern evidence is incomplete or differs from the requested count, inspect $OUT_DIR/pattern-summary.log"
fi

test_result_finish
