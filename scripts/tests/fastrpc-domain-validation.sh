#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Host-only checks: sh scripts/tests/fastrpc-domain-validation.sh [--absence-only].
# Hardware boundaries are mocked, DT parsing, domain policy and result helpers are real.
# shellcheck disable=SC2034 # Globals are consumed by sourced production helpers/runner blocks.
set -eu

validation_mode=${1:-all}
case "$validation_mode" in
    all|--absence-only)
        ;;
    *)
        printf 'Usage: %s [--absence-only]\n' "$0" >&2
        exit 2
        ;;
esac

validation_repo=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
validation_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fastrpc-domain-validation.XXXXXX")

# validation_cleanup
# Remove only this process's mktemp fixture tree. No stdout, returns rm status.
validation_cleanup() {
    case "$validation_tmp" in
        "${TMPDIR:-/tmp}"/fastrpc-domain-validation.*)
            rm -rf -- "$validation_tmp"
            ;;
    esac
}
trap validation_cleanup EXIT
trap 'exit 1' HUP INT TERM

# shellcheck disable=SC1091
. "$validation_repo/Runner/utils/functestlib.sh"
# shellcheck disable=SC1091
. "$validation_repo/Runner/utils/lib_fastrpc.sh"

# Execute the actual runner selection/early-exit block, not a copied policy.
validation_runner="$validation_repo/Runner/suites/Multimedia/CDSP/fastrpc_test/run.sh"
awk '
    /^# -------------------- Domain and PD selection/ {emit=1}
    /^# -------------------- Buffering tool availability/ {emit=0}
    emit {print}
' "$validation_runner" >"$validation_tmp/selection.sh"
awk '
    /^_total_count=/ {print}
    /^# Final result determination/ {emit=1}
    emit {print}
' "$validation_runner" >"$validation_tmp/final.sh"
test -s "$validation_tmp/selection.sh"
test -s "$validation_tmp/final.sh"

# dt_runtime_root
# Test seam for the production root resolver. Output fixture path or status 1.
dt_runtime_root() {
    [ -d "$mock_dt" ] || return 1
    printf '%s\n' "$mock_dt"
}

# get_remoteproc_by_firmware ALIAS
# Supply exact-domain remoteproc records including offline states on stdout.
get_remoteproc_by_firmware() {
    mock_id=$(name_to_domain "$1")
    case " $mock_remoteprocs " in
        *" $mock_id "*)
            mock_state=running
            [ "$mock_id" != "$mock_offline" ] || mock_state=offline
            mock_name=$(domain_to_endpoint_label "$mock_id")
            printf '/sys/class/remoteproc/remoteproc%s|%s|%s.mdt|%s\n' \
                "$mock_id" "$mock_state" "$mock_name" "$mock_name"
            ;;
    esac
}

# dt_has_remoteproc_fw ALIAS
# Generic firmware DT evidence is deliberately absent in these fixtures.
dt_has_remoteproc_fw() {
    return 1
}

# fastrpc_domain_endpoint_available ID
# Mock normal/secure endpoint inventory. Return success for listed domains.
fastrpc_domain_endpoint_available() {
    case " $mock_endpoints " in
        *" $1 "*)
            return 0
            ;;
    esac
    return 1
}

# fastrpc_domain_system_library_path ID
# Mock installed runtime libraries. Print a path only for listed domains.
fastrpc_domain_system_library_path() {
    case " $mock_libraries " in
        *" $1 "*)
            printf '/mock/lib/%s\n' "$(fastrpc_domain_field "$1" 7)"
            ;;
    esac
}

# fastrpc_validate_runtime_artifacts
# Test optional shared-asset gating without loading a DSP payload.
fastrpc_validate_runtime_artifacts() {
    FASTRPC_ARTIFACT_ERROR="mock optional skeleton absent"
    [ "$mock_assets" = yes ]
}

# validation_node PATH LABEL COMPATIBLES
# Build NUL-delimited DT properties below the fixture root. Returns write status.
validation_node() {
    mkdir -p "$mock_dt/$1"
    printf '%b\000' "$3" >"$mock_dt/$1/compatible"
    printf '%s\000' "$2" >"$mock_dt/$1/label"
}

# validation_case NAME EXPECTED_RESULT
# Run real selection and final classification with mocked successful invocations.
# Assert verdict plus a healthy ADSP's continued selection where applicable.
validation_case() {
    validation_name="$1"
    validation_expected="$2"
    LOG_ROOT="$validation_tmp/$validation_name"
    mkdir -p "$LOG_ROOT"
    (
        set +e
        TESTNAME=fastrpc_test
        test_result_init "$TESTNAME" "$LOG_ROOT/fastrpc_test.res"
        # shellcheck disable=SC1091
        . "$validation_tmp/selection.sh"
        for validation_domain in $DOMAINS_TO_TEST; do
            test_result_record PASS "mock invocation domain=$validation_domain"
        done
        # shellcheck disable=SC1091
        . "$validation_tmp/final.sh"
    ) >"$LOG_ROOT/stdout.log" 2>&1
    if [ "$(cat "$LOG_ROOT/fastrpc_test.res")" != "fastrpc_test $validation_expected" ]; then
        cat "$LOG_ROOT/stdout.log"
        printf 'FAIL: %s expected %s\n' "$validation_name" "$validation_expected" >&2
        exit 1
    fi
    if [ "$mock_expect_adsp" = yes ]; then
        grep -q 'mock invocation domain=0' "$LOG_ROOT/stdout.log"
    fi
    printf 'PASS: %s\n' "$validation_name"
}

CLI_DOMAIN=""
CLI_DOMAIN_NAME=""
FASTRPC_DOMAIN=""
FASTRPC_DOMAIN_NAME=""
FASTRPC_UNSIGNED_PD=0
UNSIGNED_PD_FLAG=0
DOMAIN_MODE=all-supported
PD_MODE=both
VERBOSE=0
FASTRPC_LIB_SYS_DIRS_CHECKED=/mock/lib
FASTRPC_HEALTHCHECK_TSV=""
CAPABILITY_SOURCE=runtime-fallback
mock_dt="$validation_tmp/dt"
mock_remoteprocs="0 3"
mock_endpoints="0 3"
mock_libraries="0 3"
mock_offline=""
mock_assets=yes
mock_expect_adsp=yes

# Current-DT expectations must not invent a removed domain. Use real DT parsing
# and runner selection with healthcheck inventory that contains only ADSP.
mock_dt="$validation_tmp/adsp-only-dt"
mock_remoteprocs=0
mock_endpoints=0
mock_libraries=0
FASTRPC_HEALTHCHECK_TSV="$validation_tmp/absence-healthcheck.tsv"
CAPABILITY_SOURCE=fastrpc-healthcheck
validation_node soc/adsp/fastrpc adsp qcom,fastrpc
printf 'ADSP\tonline\tyes\tno\tyes\tsupported\n' >"$FASTRPC_HEALTHCHECK_TSV"
validation_case absent-cdsp-adsp-continues PASS
if grep -q 'mock invocation domain=3' "$LOG_ROOT/stdout.log"; then
    exit 1
fi
test "$(wc -l <"$LOG_ROOT/fastrpc_dt_expected_domains.log")" -eq 1

CLI_DOMAIN_NAME=cdsp
mock_expect_adsp=no
validation_case explicit-cdsp-absent-from-dt-and-runtime FAIL
CLI_DOMAIN_NAME=""

# A runtime-exposed domain is still tested even without its DT declaration.
mock_endpoints="0 3"
mock_libraries="0 3"
mock_expect_adsp=yes
printf 'CDSP\tonline\tyes\tno\tyes\tsupported\n' >>"$FASTRPC_HEALTHCHECK_TSV"
validation_case runtime-cdsp-without-dt PASS
grep -q 'mock invocation domain=3' "$LOG_ROOT/stdout.log"

# An existing DT with no FastRPC nodes is not a discovery error. Non-supported
# healthcheck inventory plus no declarations must produce SKIP, not invented FAIL.
mock_dt="$validation_tmp/no-fastrpc-dt"
mkdir -p "$mock_dt"
mock_remoteprocs=""
mock_endpoints=""
mock_expect_adsp=no
printf 'ADSP\toffline\tno\tno\tno\tunsupported\n' >"$FASTRPC_HEALTHCHECK_TSV"
validation_case no-declared-or-supported-domains SKIP

if [ "$validation_mode" = --absence-only ]; then
    printf 'FastRPC absence-policy checks passed. No DUT operations were executed.\n'
    exit 0
fi

mock_dt="$validation_tmp/dt"
mock_remoteprocs="0 3"
mock_endpoints="0 3"
mock_libraries="0 3"
mock_expect_adsp=yes
FASTRPC_HEALTHCHECK_TSV=""
CAPABILITY_SOURCE=runtime-fallback
validation_node soc/adsp/fastrpc adsp qcom,fastrpc
validation_node soc/cdsp/fastrpc cdsp qcom,fastrpc
validation_case healthy-dt PASS
grep -q 'mock invocation domain=3' "$LOG_ROOT/stdout.log"

mock_remoteprocs=0
mock_endpoints=0
validation_case missing-cdsp-other-domain-passes FAIL
mock_remoteprocs="0 3"
mock_endpoints="0 3"
mock_offline=3
validation_case offline-cdsp FAIL
mock_offline=""
mock_endpoints=0
validation_case missing-cdsp-endpoint FAIL
mock_endpoints="0 3"
mock_libraries=0
validation_case missing-cdsp-runtime-library FAIL
mock_libraries="0 3"

mock_remoteprocs=0
mock_endpoints=0
printf 'disabled\000' >"$mock_dt/soc/cdsp/status"
validation_case disabled-ancestor PASS
printf 'okay\000' >"$mock_dt/soc/cdsp/status"
printf 'reserved\000' >"$mock_dt/soc/cdsp/fastrpc/status"
validation_case reserved-node PASS
printf 'ok\000' >"$mock_dt/soc/cdsp/fastrpc/status"
validation_case enabled-again FAIL

CLI_DOMAIN_NAME=adsp
validation_case cli-scopes-out-broken-cdsp PASS
CLI_DOMAIN_NAME=""
FASTRPC_DOMAIN_NAME=adsp
validation_case environment-scopes-out-broken-cdsp PASS
FASTRPC_DOMAIN_NAME=""
CLI_DOMAIN_NAME=cdsp
mock_expect_adsp=no
validation_case explicit-missing-cdsp FAIL
CLI_DOMAIN_NAME=""

mock_assets=no
validation_case assets-cannot-hide-readiness-failure FAIL
mock_assets=yes
mock_remoteprocs=""
mock_endpoints=""
validation_case no-runnable-expected-domains FAIL

mock_remoteprocs=0
mock_endpoints=0
mock_expect_adsp=yes
FASTRPC_HEALTHCHECK_TSV="$validation_tmp/healthcheck.tsv"
CAPABILITY_SOURCE=fastrpc-healthcheck
printf 'ADSP\tonline\tyes\tno\tyes\tsupported\n' >"$FASTRPC_HEALTHCHECK_TSV"
validation_case healthcheck-omits-cdsp FAIL
printf 'CDSP\toffline\tno\tno\tno\toffline\n' >>"$FASTRPC_HEALTHCHECK_TSV"
validation_case healthcheck-offline-cdsp FAIL
printf 'ADSP\tonline\tyes\tno\tyes\tsupported\nCDSP\tonline\tno\tno\tno\tunsupported\n' >"$FASTRPC_HEALTHCHECK_TSV"
validation_case healthcheck-unsupported-expected-cdsp FAIL
printf 'disabled\000' >"$mock_dt/soc/cdsp/status"
validation_case healthcheck-unsupported-optional-cdsp PASS

FASTRPC_HEALTHCHECK_TSV=""
CAPABILITY_SOURCE=runtime-fallback
mock_dt="$validation_tmp/absent-dt"
validation_case no-dt-runtime-fallback PASS
mock_remoteprocs=""
mock_endpoints=""
mock_expect_adsp=no
validation_case no-dt-no-domains SKIP

mock_dt="$validation_tmp/new-dt"
mock_remoteprocs="0 3"
mock_endpoints="0 3"
mock_expect_adsp=yes
validation_node soc/cdsp/fastrpc cdsp 'qcom,glymur-fastrpc\000qcom,kaanapali-fastrpc'
validation_node soc/cdsp/fastrpc/cb@1 ignored qcom,fastrpc-compute-cb
validation_case fallback-compatible PASS
test "$(wc -l <"$LOG_ROOT/fastrpc_dt_expected_domains.log")" -eq 1
ln -s "$mock_dt" "$validation_tmp/dt-link"
mock_dt="$validation_tmp/dt-link"
validation_case symlink-dt-root PASS

mock_dt="$validation_tmp/malformed-dt"
validation_node soc/fastrpc '' qcom,fastrpc
mock_expect_adsp=no
validation_case missing-label FAIL

printf 'All FastRPC domain regression checks passed. No DUT operations were executed.\n'
