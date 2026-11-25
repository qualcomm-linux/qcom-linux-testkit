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
TESTNAME="CPU_Boot_Online_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

EXERCISE="0"

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate first online transitions for CPUs excluded by maxcpus at boot.
  --exercise <value>  Set 1 only on an isolated fresh boot with maxcpus=N
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
            --exercise)
                EXERCISE="$2"
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


case "$EXERCISE" in
    0)
        test_result_finish SKIP "First CPU startup requires --exercise 1 on an isolated fresh maxcpus=N boot"
        ;;
    1)
        ;;
    *)
        test_result_finish FAIL "--exercise must be 0 or 1"
        ;;
esac
case "$(uname -m)" in
    aarch64|arm64)
        ;;
    *)
        test_result_finish SKIP "First-start evidence currently requires the Arm64 CPU boot-log interface"
        ;;
esac
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies taskset cmp sort id sh; then
    test_result_finish SKIP "CPU execution proof requires image-provided taskset, cmp, sort, id and sh"
fi
if [ "$(id -u)" != 0 ]; then
    test_result_finish SKIP "CPU online controls require root on an isolated validation target"
fi
if ! cat /proc/cmdline >"$OUT_DIR/cmdline.log"; then
    test_result_finish SKIP "Cannot read kernel boot arguments, provide procfs"
fi
limit=$(awk '{for (i=1; i<=NF; i++) if ($i ~ /^maxcpus=/) {value=$i; sub(/^maxcpus=/,"",value)}} END {print value}' "$OUT_DIR/cmdline.log")
if [ -z "$limit" ]; then
    test_result_finish SKIP "Boot with maxcpus=N before this test, ordinary hotplug cannot prove first CPU startup"
fi
if ! printf '%s\n' "$limit" | grep -Eq '^[1-9][0-9]*$'; then
    test_result_finish SKIP "Use a positive decimal maxcpus=N limit, maxcpus=0 disables SMP setup"
fi
if [ "$(kernel_config_state CONFIG_HOTPLUG_CPU 2>"$OUT_DIR/config.log")" = n ]; then
    test_result_finish SKIP "Running kernel disables CONFIG_HOTPLUG_CPU"
fi
cpu_root=/sys/devices/system/cpu
if ! cat "$cpu_root/online" >"$OUT_DIR/initial-online.list" ||
   ! cat "$cpu_root/present" >"$OUT_DIR/initial-present.list"; then
    test_result_finish SKIP "CPU online/present masks are unavailable, provide sysfs CPU topology"
fi
initial_online=$(cat "$OUT_DIR/initial-online.list")
initial_present=$(cat "$OUT_DIR/initial-present.list")
if ! kernel_cpu_list_valid "$initial_online" || ! kernel_cpu_list_valid "$initial_present"; then
    test_result_finish FAIL "CPU online/present masks are malformed"
fi
expand_cpu_list "$initial_online" >"$OUT_DIR/online-cpus.list"
expand_cpu_list "$initial_present" >"$OUT_DIR/present-cpus.list"
online_count=$(awk 'END {print NR}' "$OUT_DIR/online-cpus.list")
present_count=$(awk 'END {print NR}' "$OUT_DIR/present-cpus.list")
expected_count=$(awk -v limit="$limit" -v present="$present_count" 'BEGIN {print limit < present ? limit : present}')
scan_dmesg_errors "$OUT_DIR/before" 'CPU[0-9]+|smp|psci|cpuhp' '' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_finish SKIP "First-start proof needs readable retained boot logs, provide kernel-log access"
fi
snapshot="$OUT_DIR/before/dmesg_snapshot.log"
if [ -s "$OUT_DIR/before/dmesg_errors.log" ]; then
    test_result_finish FAIL "CPU boot already contains kernel faults, inspect $OUT_DIR/before/dmesg_errors.log"
fi
if ! grep -Fq 'Booting Linux on physical CPU ' "$snapshot"; then
    test_result_finish SKIP "Early CPU log has rotated, first-start history cannot be established"
fi
boot_count=$(sed -n 's/.*SMP: Total of \([0-9]*\) processors activated.*/\1/p' "$snapshot")
if [ "$boot_count" != "$expected_count" ]; then
    test_result_finish FAIL "Kernel booted CPU count=${boot_count:-unreported} differs from expected limit=$expected_count"
fi
if [ "$online_count" -ne "$expected_count" ]; then
    test_result_finish SKIP "Initial online CPU count=$online_count differs from boot limit=$expected_count, use a fresh boot before other hotplug tests"
fi
: >"$OUT_DIR/candidates.list"
while IFS= read -r candidate; do
    if cpu_in_list "$candidate" "$initial_online"; then
        continue
    fi
    if grep -Eq "CPU${candidate}: Booted secondary processor " "$snapshot"; then
        test_result_finish SKIP "CPU$candidate already started during this boot, use a fresh maxcpus boot"
    fi
    if [ ! -w "$cpu_root/cpu$candidate/online" ]; then
        test_result_finish SKIP "CPU$candidate has no writable online control, enable CPU hotplug and required privileges"
    fi
    printf '%s\n' "$candidate" >>"$OUT_DIR/candidates.list"
done <"$OUT_DIR/present-cpus.list"
if [ ! -s "$OUT_DIR/candidates.list" ]; then
    test_result_finish SKIP "All present CPUs already started, boot with maxcpus below the present CPU count"
fi
owned_cpus=""

# restore_boot_cpus
# Restore only initially offline CPUs whose startup this test attempted.
# Return nonzero on restoration or post-operation evidence failure.
restore_boot_cpus() {
    bounded_timeout_cancel || return 1
    restore_failed=0
    for restore_cpu in $owned_cpus; do
        if [ "$(cpu_hotplug_read_state "$restore_cpu")" != 0 ]; then
            cpu_hotplug_write_state "$restore_cpu" 0 restore "$OUT_DIR" || restore_failed=1
        fi
        if [ "$(cpu_hotplug_read_state "$restore_cpu")" != 0 ]; then
            log_fail "CPU$restore_cpu did not return to its initially offline state"
            restore_failed=1
        fi
    done
    if ! cmp -s "$OUT_DIR/initial-online.list" "$cpu_root/online" ||
       ! cmp -s "$OUT_DIR/initial-present.list" "$cpu_root/present"; then
        log_fail "CPU online/present masks were not restored to the initial state"
        restore_failed=1
    fi
    scan_dmesg_errors "$OUT_DIR/after" 'CPU[0-9]+|smp|psci|cpuhp' '' || true
    if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ] || [ -s "$OUT_DIR/after/dmesg_errors.log" ]; then
        log_fail "CPU transition health is failed or unverified, inspect $OUT_DIR/after"
        restore_failed=1
    fi
    [ "$restore_failed" -eq 0 ]
}

# shellcheck disable=SC2034 # Invoked by shared test_result_finish.
TEST_RESULT_CLEANUP=restore_boot_cpus
trap 'test_result_finish FAIL "CPU first-start validation interrupted"' HUP INT TERM
while IFS= read -r candidate; do
    if [ "$(cpu_hotplug_read_state "$candidate")" != 0 ]; then
        test_result_finish FAIL "CPU$candidate changed state before the owned startup, isolate competing hotplug managers"
    fi
    owned_cpus="$owned_cpus $candidate"
    if ! cpu_hotplug_write_state "$candidate" 1 first_online "$OUT_DIR"; then
        test_result_record FAIL "CPU$candidate first startup failed, inspect retained errors and kernel capability conflicts"
        break
    fi
    if [ "$(cpu_hotplug_read_state "$candidate")" != 1 ] || ! cpu_hotplug_in_online_mask "$candidate"; then
        test_result_record FAIL "CPU$candidate startup returned without a confirmed online state"
        break
    fi
    # /proc/self/stat belongs to the affinity-bound awk process. Strip pid/comm
    # before selecting the documented processor field, so spaces in comm are safe.
    # shellcheck disable=SC2016 # Field references belong to awk.
    if run_with_bounded_timeout 10 taskset -c "$candidate" awk -v expected="$candidate" '
        {
            sub(/^.*\) /, "")
            print "processor=" $37, "expected=" expected
            if (NF < 37 || $37 !~ /^[0-9]+$/ || $37 != expected) exit 1
        }
    ' /proc/self/stat >"$OUT_DIR/cpu$candidate-execution.log" 2>&1; then
        test_result_record PASS "CPU$candidate first startup completed and executed an affinity-bound process"
    else
        test_result_record FAIL "CPU$candidate did not execute the requested affinity-bound process, inspect $OUT_DIR/cpu$candidate-execution.log"
        break
    fi
done <"$OUT_DIR/candidates.list"

test_result_finish
