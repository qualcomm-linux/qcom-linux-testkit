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
. "$TOOLS/lib_pkg_provider.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_kvm.sh"

TESTNAME="CPU_Feature_Reporting"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

TEST_RUN_TIMEOUT="60"
CPU_REPORT_EXPECTED=""
CPU_REPORT_IDREGS="auto"
CPU_REPORT_FEATURE_TABLE=""

# usage
# Describe reporting assertions without claiming native instruction coverage.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate Arm64 kernel-reported CPU features using image-provided shell tools.
  --timeout <seconds> (default: 60, bounds optional utility invocations)
  --expect <list> (default: unset, flag names match /proc/cpuinfo)
  --idregs <auto|none|path-or-command> (default: auto, reuse installed idregs-arm64)
  --feature-table <path> (default: image-provided table next to the native helper)
Kernel reporting always runs, native PAC/vector/KVM checks run when idregs is selected and available.
EOF
}

# parse_args <arguments>...
# Reject malformed or contradictory feature expectations before collecting evidence.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_record FAIL "Missing value for $1"
            test_result_finish
        fi
        case "$2" in
            --*)
                test_result_record FAIL "Missing value for $1 before option=$2"
                test_result_finish
                ;;
        esac
        case "$1" in
            --timeout)
                TEST_RUN_TIMEOUT="$2"
                ;;
            --expect)
                CPU_REPORT_EXPECTED="$2"
                ;;
            --idregs)
                CPU_REPORT_IDREGS="$2"
                ;;
            --feature-table)
                CPU_REPORT_FEATURE_TABLE="$2"
                ;;
            *)
                test_result_record FAIL "Unknown option: $1"
                test_result_finish
                ;;
        esac
        shift 2
    done
    if ! is_bounded_positive_integer "$TEST_RUN_TIMEOUT" 600; then
        test_result_record FAIL "Invalid --timeout=$TEST_RUN_TIMEOUT, use 1 through 600 seconds"
        test_result_finish
    fi
    if [ -n "$CPU_REPORT_EXPECTED" ] && ! printf '%s\n' "$CPU_REPORT_EXPECTED" | awk '
        !/^(present|absent):[a-z][a-z0-9_]*(,(present|absent):[a-z][a-z0-9_]*)*$/ { bad = 1 }
        {
            n = split($0, tokens, ",")
            for (i = 1; i <= n; i++) {
                split(tokens[i], item, ":")
                if (item[2] in state && state[item[2]] != item[1]) bad = 1
                state[item[2]] = item[1]
            }
        }
        END { exit bad }
    '; then
        test_result_record FAIL "Invalid or contradictory --expect=$CPU_REPORT_EXPECTED, use present:flag or absent:flag"
        test_result_finish
    fi
    if [ "$CPU_REPORT_IDREGS" = none ] && [ -n "$CPU_REPORT_FEATURE_TABLE" ]; then
        test_result_record FAIL "--feature-table requests native decoding but --idregs none disables it"
        test_result_finish
    fi
}






parse_args "$@"
test_run_start

# ---------- Kernel reporting ----------
registers=0
schedulable=0
case "$(uname -m)" in
    aarch64|arm64)
        ;;
    *)
        test_result_record SKIP "Arm64 CPU reporting is not applicable to architecture=$(uname -m)"
        test_run_finish
        ;;
esac
test_require_commands awk cat tr sort grep sh || test_run_finish
if [ ! -r /proc/cpuinfo ]; then
    test_result_record SKIP "CPU reporting requires readable /proc/cpuinfo, mount procfs before running"
    test_run_finish
fi
cpus=$(get_online_cpus | sort -n | tr '\n' ' ')
if [ -z "$cpus" ]; then
    test_result_record FAIL "No online CPU inventory could be read from sysfs/procfs"
    test_run_finish FAIL "CPU reporting could not complete, inspect artifacts=$TEST_RUN_DIR"
fi
cat /proc/cpuinfo >"$TEST_RUN_DIR/cpuinfo.log" || test_run_finish FAIL "CPU reporting could not complete, inspect artifacts=$TEST_RUN_DIR"
log_info "Online CPUs=$cpus"
if ! cpu_reporting_flags "$TEST_RUN_DIR/cpuinfo.log" "$cpus" >"$TEST_RUN_DIR/features.tsv"; then
    test_result_record FAIL "CPU feature reporting omits an online CPU or contains duplicate, malformed or inconsistent Features entries"
    test_run_finish FAIL "CPU reporting could not complete, inspect artifacts=$TEST_RUN_DIR"
fi
# shellcheck disable=SC2034 # Consumed by the shared test_run_finish helper.
TEST_RUN_VALIDATED=1
test_result_record PASS "Every online CPU reports a complete consistent Arm64 userspace feature set"
log_file_with_label CPU-FEATURES "$TEST_RUN_DIR/features.tsv" 80
for token in $(printf '%s\n' "$CPU_REPORT_EXPECTED" | tr ',' ' '); do
    expected=${token%%:*}
    flag=${token#*:}
    present=absent
    if awk -F '|' -v flag="$flag" '$2 == flag {found=1} END {exit !found}' "$TEST_RUN_DIR/features.tsv"; then
        present=present
    fi
    if [ "$present" = "$expected" ]; then
        test_result_record PASS "Kernel-reported flag=$flag is $present as requested"
    else
        test_result_record FAIL "Expected kernel-reported flag=$flag $expected, observed=$present"
    fi
done
if test_require_commands od; then
    # shellcheck disable=SC2016 # Child PID selects the same interpreter ABI for both files.
    if ! test_run_command auxv sh -c '
        od -An -tx1 -N6 "/proc/$$/exe" >"$1/elf.bytes" || exit 1
        od -An -tx1 -v "/proc/$$/auxv" >"$1/auxv.bytes"
    ' sh "$TEST_RUN_DIR"; then
        test_result_record FAIL "Installed od could not read the interpreter ELF header and auxiliary vector"
    elif ! cpu_reporting_auxv "$TEST_RUN_DIR/elf.bytes" "$TEST_RUN_DIR/auxv.bytes" >"$TEST_RUN_DIR/auxv.tsv"; then
        test_result_record FAIL "ELF/auxiliary-vector evidence is malformed or lacks AT_HWCAP"
    else
        log_file_with_label CPU-AUXV "$TEST_RUN_DIR/auxv.tsv"
        if ! grep -q '^HWCAP2|' "$TEST_RUN_DIR/auxv.tsv"; then
            test_result_record SKIP "AT_HWCAP2 is not exposed, SVE2/SME reporting comparison was not exercised"
        fi
        cpu_reporting_hwcap_flags "$TEST_RUN_DIR/auxv.tsv" "$TEST_RUN_DIR/features.tsv" >"$TEST_RUN_DIR/hwcap-comparison.tsv"
        status=$?
        log_file_with_label CPU-HWCAP "$TEST_RUN_DIR/hwcap-comparison.tsv"
        case "$status" in
            0)
                test_result_record PASS "Selected Arm64 HWCAP flags agree with kernel CPU feature reporting"
                ;;
            2)
                test_result_record SKIP "Arm64 HWCAP comparison requires a 64-bit interpreter, raw compatibility-ABI evidence retained"
                ;;
            *)
                test_result_record FAIL "Selected Arm64 HWCAP flags disagree with /proc/cpuinfo, comparison=$TEST_RUN_DIR/hwcap-comparison.tsv"
                ;;
        esac
    fi
else
    log_info "Auxiliary-vector comparison was not executed without od, CPU flag reporting remains independently assessed"
fi
allowed=$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status)
if [ -n "$allowed" ]; then
    test_require_commands taskset || true
fi
for cpu in $cpus; do
    for node in /sys/devices/system/cpu/cpu"$cpu"/regs/identification/*; do
        [ -f "$node" ] || continue
        value=$(cat "$node") || {
            test_result_record FAIL "CPU=$cpu exported identification register is unreadable: $node"
            continue
        }
        if ! printf '%s\n' "$value" | grep -Eq '^0x[0-9a-fA-F]{16}$'; then
            test_result_record FAIL "CPU=$cpu exported register=${node##*/} has malformed value=$value"
        else
            printf '%s|%s|%s\n' "$cpu" "${node##*/}" "$value" >>"$TEST_RUN_DIR/identification.tsv"
            registers=$((registers + 1))
        fi
    done
    if command -v taskset >/dev/null 2>&1 && [ -n "$allowed" ] && cpu_in_list "$cpu" "$allowed"; then
        # shellcheck disable=SC2016 # Invoke the existing affinity helper in a bounded child.
        if test_run_command "affinity-cpu$cpu" sh -c '
            . "$1"
            cpu_is_schedulable "$2"
        ' sh "$TOOLS/functestlib.sh" "$cpu"; then
            schedulable=$((schedulable + 1))
        else
            test_result_record FAIL "Online allowed CPU=$cpu cannot execute a trivial affinity-bound shell command"
        fi
    fi
done
if [ "$registers" -gt 0 ]; then
    test_result_record PASS "Validated $registers exported CPU identification values, heterogeneous CPU identities are allowed"
    log_file_with_label CPU-IDENTIFICATION "$TEST_RUN_DIR/identification.tsv" 80
else
    test_result_record SKIP "Kernel exports no readable CPU identification register files, enable reporting to exercise this assertion"
fi
if [ "$schedulable" -gt 0 ]; then
    test_result_record PASS "Affinity-bound shell executed on $schedulable online CPUs allowed by this process cpuset"
else
    test_result_record SKIP "No affinity assertion executed, requires image-provided taskset and readable process CPU allowance"
fi
if test_require_commands lscpu; then
    if ! test_run_command lscpu lscpu; then
        log_warn "Optional lscpu diagnostics failed, CPU assertions use procfs/sysfs evidence"
    fi
fi
if [ "$(get_online_cpus | sort -n | tr '\n' ' ')" != "$cpus" ]; then
    test_result_record FAIL "Online CPU population changed during reporting, rerun without concurrent hotplug"
fi

# ---------- Optional native validation ----------
requested="$CPU_REPORT_IDREGS"
if [ "$requested" = none ]; then
    test_result_record SKIP "Native CPU checks disabled by --idregs none, kernel reporting remains independently assessed"
else
    if [ "$requested" = auto ]; then
        requested=idregs-arm64
    fi
    binary=$(command -v "$requested" 2>/dev/null)
    if [ -z "$binary" ]; then
        test_require_commands "$requested" || true
        binary=$(command -v "$requested" 2>/dev/null)
    fi
    if [ -z "$binary" ] || [ ! -x "$binary" ] || [ -d "$binary" ]; then
        if [ "$CPU_REPORT_IDREGS" != auto ] || [ -n "$CPU_REPORT_FEATURE_TABLE" ]; then
            test_result_record FAIL "Requested native CPU helper=$requested is unavailable or not executable, provide an image-installed helper"
        else
            test_result_record SKIP "Native PAC/vector/KVM checks require image-provided idregs-arm64, kernel reporting remains independently assessed"
        fi
    else
        case "$binary" in
            /*)
                ;;
            *)
                binary="$PWD/$binary"
                ;;
        esac
        feature_table="$CPU_REPORT_FEATURE_TABLE"
        case "$feature_table" in
            ''|/*)
                ;;
            *)
                feature_table="$PWD/$feature_table"
                ;;
        esac
        native_dir="$TEST_RUN_DIR/native"
        mkdir -p "$native_dir" || test_run_finish FAIL "Cannot create native CPU evidence under CWD=$native_dir"
        set -- --timeout "$TEST_RUN_TIMEOUT" --idregs "$binary"
        if [ -n "$feature_table" ]; then
            set -- "$@" --feature-table "$feature_table"
        fi
        log_info "[CPU-NATIVE] helper=$binary table=${CPU_REPORT_FEATURE_TABLE:-auto} artifacts=$native_dir"
        if ! (
            cd "$native_dir" || exit 1
            RUN_STDOUT_ENABLE=0 sh "$SCRIPT_DIR/../CPU_Feature_Exposure/run.sh" "$@"
        ); then
            test_result_record FAIL "Native CPU runner could not complete, inspect $native_dir"
        elif [ ! -r "$native_dir/CPU_Feature_Exposure.res" ]; then
            test_result_record FAIL "Native CPU runner emitted no current result, inspect $native_dir"
        else
            native_status=$(awk '$1 == "CPU_Feature_Exposure" && NF == 2 {count++; result=$2} END {if (count == 1) print result}' "$native_dir/CPU_Feature_Exposure.res")
            case "$native_status" in
                PASS)
                    test_result_record PASS "Native PAC/vector/KVM validation completed, artifacts=$native_dir"
                    ;;
                SKIP)
                    test_result_record SKIP "Native CPU validation prerequisites unavailable, artifacts=$native_dir"
                    ;;
                *)
                    test_result_record FAIL "Native CPU validation failed or emitted malformed results, artifacts=$native_dir"
                    ;;
            esac
        fi
    fi
fi
test_run_finish
