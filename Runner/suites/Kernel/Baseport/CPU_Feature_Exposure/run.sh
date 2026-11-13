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

TESTNAME="CPU_Feature_Exposure"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

TEST_RUN_TIMEOUT="60"
TEST_RUN_IDREGS="idregs-arm64"
TEST_RUN_FEATURE_TABLE=""
TEST_RUN_EXPECTED=""

# usage
# Show the suite options and safe defaults.
usage() {
    cat <<EOF
Usage: $0 [options]
Per-CPU EL0/KVM feature exposure, PAC key and guest controls, and vector consistency.
  --timeout <value> (default: 60)
  --idregs <value> (default: idregs-arm64)
  --feature-table <value> (default: unset)
  --expect <value> (default: unset)
  --help
EOF
}

# parse_args <arguments>...
# Reject malformed overrides before runtime discovery or state changes.
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
            --idregs)
                TEST_RUN_IDREGS="$2"
                ;;
            --feature-table)
                TEST_RUN_FEATURE_TABLE="$2"
                ;;
            --expect)
                TEST_RUN_EXPECTED="$2"
                ;;
            *)
                test_result_record FAIL "Unknown option: $1"
                test_result_finish
                ;;
        esac
        shift 2
    done
    if ! {
        is_bounded_positive_integer "$TEST_RUN_TIMEOUT" 600
    }; then
        test_result_record FAIL "Invalid value for --timeout: $TEST_RUN_TIMEOUT"
        test_result_finish
    fi
    if ! {
        [ -z "$TEST_RUN_EXPECTED" ] || printf '%s\n' "$TEST_RUN_EXPECTED" | awk '/^(present|absent):FEAT_[A-Za-z0-9_]+(,(present|absent):FEAT_[A-Za-z0-9_]+)*$/ {ok=1} END {exit !ok}'
    }; then
        test_result_record FAIL "Invalid value for --expect: $TEST_RUN_EXPECTED"
        test_result_finish
    fi
}

# Native CPU helpers are shared through lib_kvm.sh.

parse_args "$@"
test_run_start
log_info "[OPTIONS] --idregs=$TEST_RUN_IDREGS"
log_info "[OPTIONS] --feature-table=$TEST_RUN_FEATURE_TABLE"

# ---------- Runtime validation ----------
decoder="$SCRIPT_DIR/cpu_feature_decode.awk"
case "$(uname -m)" in
    aarch64|arm64)
        ;;
    *)
        test_result_record SKIP "Arm64 feature validation is not applicable to $(uname -m)"
        test_run_finish
        ;;
esac
test_require_commands awk grep cat cut sort "$TEST_RUN_IDREGS" || test_run_finish
binary=$(command -v "$TEST_RUN_IDREGS" 2>/dev/null)
if [ -z "$binary" ]; then
    test_result_record SKIP "Image-provided idregs-arm64 helper is missing, supply --idregs"
    test_run_finish
fi
cpus=$(get_online_cpus)
if ! test_run_command idregs "$binary" || ! grep -qx 'idregs 1' "$TEST_RUN_DIR/idregs.log"; then
    test_result_record FAIL "Installed idregs helper failed or lacks the supported v1 output contract"
    test_run_finish FAIL "CPU_Feature_Exposure could not complete, inspect artifacts=$TEST_RUN_DIR"
fi
if cpu_features_views "$TEST_RUN_DIR/idregs.log" "$cpus"; then
    # shellcheck disable=SC2034 # Required by test_run_finish.
    TEST_RUN_VALIDATED=1
    test_result_record PASS "Complete identical EL0 register view on runtime-online CPUs"
else
    test_result_record FAIL "EL0 register views differ or omit an online CPU/register"
fi
if [ -e /dev/kvm ]; then
    kvm_check_device_node
    status=$?
    if [ "$status" = 0 ] && grep -Eq '^kvm ID_AA64[A-Za-z0-9_]+ 0x[0-9a-fA-F]{16}$' "$TEST_RUN_DIR/idregs.log"; then
        test_result_record PASS "Installed helper exercised KVM ID-register view"
    else
        test_result_record FAIL "Present KVM device could not supply a vCPU ID-register view"
    fi
else
    test_result_record SKIP "KVM ID-register view is unavailable without /dev/kvm"
fi
table="$TEST_RUN_FEATURE_TABLE"
if [ -z "$table" ]; then
    for table in "${binary%/*}/features.txt" /usr/share/cpu-features/features.txt; do
        [ -s "$table" ] && break
    done
fi
if [ -s "$table" ]; then
    if ! awk -f "$decoder" "$table" "$TEST_RUN_DIR/idregs.log" \
        >"$TEST_RUN_DIR/features.tsv"; then
        test_result_record FAIL "Feature table is malformed or could not be decoded: $table"
        test_run_finish FAIL "CPU_Feature_Exposure could not complete, inspect artifacts=$TEST_RUN_DIR"
    fi
    for token in $(printf '%s\n' "$TEST_RUN_EXPECTED" | tr ',' ' '); do
        expected=${token%%:*}
        feature=${token#*:}
        actual=$(awk -v feature="$feature" '$1 == feature {print $2}' "$TEST_RUN_DIR/features.tsv")
        if [ "$actual" = "$expected" ]; then
            test_result_record PASS "Expected $feature=$expected"
        else
            test_result_record FAIL "Expected $feature=$expected, observed=${actual:-not-in-table}"
        fi
    done
elif [ -n "$TEST_RUN_EXPECTED" ] || [ -n "$TEST_RUN_FEATURE_TABLE" ]; then
    test_result_record FAIL "Requested feature validation lacks its readable image-provided feature table"
else
    test_result_record SKIP "Full feature decoding requires an image-provided Arm feature table, supply --feature-table"
fi
if test_run_command pac "$binary" pac; then
    paca=$(awk '$2 == "hwcap" {print $4}' "$TEST_RUN_DIR/pac.log")
    pacg=$(awk '$2 == "hwcap" {print $6}' "$TEST_RUN_DIR/pac.log")
    if [ "$paca:$pacg" = 1:1 ]; then
        if cpu_features_validate_pac "$TEST_RUN_DIR/pac.log" "$cpus"; then
            test_result_record PASS "Per-CPU PAC key roundtrips, wrong-modifier faults and key reset passed"
        else
            test_result_record FAIL "PAC output is incomplete or functional key validation failed"
        fi
        if [ -e /dev/kvm ]; then
            if awk '
                $2 == "kvm-ptrauth" && $4 == "auth" { if ($5 != "0x0000000080000000") bad = 1; auth++ }
                $2 == "kvm-ptrauth" && $4 == "wrong" { if ($5 == "0x0000000080000000") bad = 1; wrong++ }
                $2 == "kvm-ptrauth" && $3 == "done" { positive = $4 == 1 }
                $2 == "kvm-noptrauth" && $4 == "sign" { if ($5 != "0x0000000080000000") bad = 1; negative_keys++ }
                $2 == "kvm-noptrauth" && $3 == "done" { negative = $4 == 1 && $6 > 0 && $8 ~ /^0x2000000/ }
                END {exit bad || !positive || !negative || auth != 4 || wrong != 4 || negative_keys != 4}
            ' "$TEST_RUN_DIR/pac.log"; then
                test_result_record PASS "PAC-enabled guest and PAC-disabled guest negative control passed"
            else
                test_result_record FAIL "PAC guest controls failed or lack complete evidence"
            fi
        else
            test_result_record SKIP "PAC guest controls require /dev/kvm"
        fi
    elif [ "$paca:$pacg" = 0:0 ]; then
        if grep -Eq '^pac cpu[0-9]+ AP[A-Z]+ sign .* ok$' "$TEST_RUN_DIR/pac.log"; then
            test_result_record FAIL "A CPU signs despite absent PAC HWCAPs"
        else
            test_result_record SKIP "PAC is not exposed by this system"
        fi
    elif [ "$paca:$pacg" = 1:0 ] || [ "$paca:$pacg" = 0:1 ]; then
        test_result_record SKIP "Installed all-key PAC helper cannot prove partial PAC feature support, paca=$paca pacg=$pacg"
    else
        test_result_record FAIL "PAC helper omitted valid HWCAP evidence"
    fi
else
    test_result_record FAIL "PAC helper invocation failed"
fi
if test_run_command vectors "$binary" vec; then
    for feature in sve sve2 sme sme2; do
        instruction=""
        case "$feature" in
            sve)
                instruction=rdvl
                ;;
            sme)
                instruction=rdsvl
                ;;
        esac
        cpu_features_vector "$TEST_RUN_DIR/vectors.log" "$feature" "$instruction" "$cpus" "$TEST_RUN_DIR/features.tsv"
        status=$?
        case "$status" in
            0)
                test_result_record PASS "$feature register, HWCAP and instruction exposure agrees"
                ;;
            2)
                test_result_record SKIP "$feature lacks a visible decoded ID-register field or feature table"
                ;;
            *)
                test_result_record FAIL "$feature register, HWCAP or per-CPU instruction exposure differs"
                ;;
        esac
    done
else
    test_result_record FAIL "Vector instruction helper failed"
fi
if [ "$(get_online_cpus)" != "$cpus" ]; then
    test_result_record FAIL "Online CPU population changed during feature validation, rerun on a stable system"
fi
test_run_finish
