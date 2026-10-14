#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Run with sh scripts/tests/fastrpc-startup-validation.sh [shell-under-test].
# This fixture mode is sourced only by the temporary test tree below.
if [ "${startup_fixture_mode:-0}" = 1 ]; then
    # find_test_case_by_name NAME
    # Resolve the temporary runner directory, never a real DUT suite.
    find_test_case_by_name() {
        printf '%s\n' "$SCRIPT_DIR"
    }

    # log_soc_info
    # Avoid host hardware queries in this startup-only check.
    log_soc_info() {
        :
    }

    # fastrpc_capture_expected_domains RESULT_DIR
    # Mock DT inventory. Real DT parsing is covered by fastrpc-domain-validation.sh.
    fastrpc_capture_expected_domains() {
        printf 'DT_INVENTORY\n' >&2
        [ "$startup_dt_error" = 0 ] || return 1
        printf '%s' "$startup_domains"
    }

    # fastrpc_remoteproc_domain_state DOMAIN_ID
    # Mock kernel records, leaving the real readiness/status validator in use.
    fastrpc_remoteproc_domain_state() {
        case " $startup_missing " in
            *" $1 "*)
                return 2
                ;;
        esac
        case " $startup_offline " in
            *" $1 "*)
                printf 'offline|/mock/remoteproc%s|mock.mdt|mock\n' "$1"
                ;;
            *)
                printf 'running|/mock/remoteproc%s|mock.mdt|mock\n' "$1"
                ;;
        esac
    }

    # fastrpc_domain_endpoint_available DOMAIN_ID
    # Mock the device boundary without creating real FastRPC device nodes.
    fastrpc_domain_endpoint_available() {
        case " $startup_no_endpoint " in
            *" $1 "*)
                return 1
                ;;
        esac
        return 0
    }

    # pkg_ensure_host_distro_package_set_present SET
    # Simulate existing package-provider outcomes without installing anything.
    pkg_ensure_host_distro_package_set_present() {
        printf 'PACKAGE_PROVIDER %s\n' "$1"
        if [ "$startup_package_rc" = 0 ]; then
            # shellcheck disable=SC2034 # Consumed by the real runner after this mock returns.
            RUN_BIN="$startup_fixture_binary"
        fi
        return "$startup_package_rc"
    }

    # fastrpc_capture_qrtr_evidence RESULT_DIR
    # Stop immediately after the real runner's prerequisite gate, before any DUT work.
    fastrpc_capture_qrtr_evidence() {
        printf 'NORMAL_EXECUTION_REACHED\n'
        test_result_finish SKIP "Host fixture reached the existing execution path"
    }
    return 0
fi

set -eu
startup_repo=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
startup_script="$startup_repo/scripts/tests/fastrpc-startup-validation.sh"
startup_shell=${1:-sh}
startup_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fastrpc-startup.XXXXXX")

# startup_cleanup
# Remove this process's successful fixture tree, retaining failed-run evidence.
startup_cleanup() {
    startup_cleanup_rc=$?
    if [ "$startup_cleanup_rc" -ne 0 ]; then
        printf 'Startup fixture failed or was interrupted, evidence=%s\n' "$startup_tmp" >&2
        return 0
    fi
    case "$startup_tmp" in
        "${TMPDIR:-/tmp}"/fastrpc-startup.*)
            rm -rf -- "$startup_tmp"
            ;;
    esac
}
trap startup_cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$startup_tmp/utils" "$startup_tmp/bin"
printf "TOOLS='%s/utils'\n" "$startup_tmp" >"$startup_tmp/init_env"
for startup_lib in functestlib lib_fastrpc; do
    printf '. "%s/Runner/utils/%s.sh"\nstartup_fixture_mode=1\n. "%s"\n' \
        "$startup_repo" "$startup_lib" "$startup_script" >"$startup_tmp/utils/$startup_lib.sh"
done
# These libraries are not needed until after the gate. No real provider is sourced.
: >"$startup_tmp/utils/lib_pkg_provider.sh"
: >"$startup_tmp/utils/lib_diag.sh"
startup_fixture_binary="$startup_tmp/bin/fastrpc_test"
printf '#!/bin/sh\nexit 99\n' >"$startup_fixture_binary"
chmod +x "$startup_fixture_binary"
export startup_fixture_binary

# startup_case NAME VERDICT BIN_MODE [RUNNER_ARGS...]
# Run a complete, unchanged run.sh copy with temporary bootstrap and boundary mocks.
# Verify the .res verdict and reject any invented functional PASS. Output: case status.
startup_case() {
    startup_name="$1"
    startup_verdict="$2"
    startup_mode="$3"
    shift 3
    startup_case_dir="$startup_tmp/$startup_name"
    mkdir -p "$startup_case_dir"
    cp "$startup_repo/Runner/suites/Multimedia/CDSP/fastrpc_test/run.sh" "$startup_case_dir/run.sh"
    case "$startup_mode" in
        missing)
            startup_bin_dir="$startup_tmp/not-installed"
            ;;
        installed)
            startup_bin_dir="$startup_tmp/bin"
            ;;
        default)
            startup_bin_dir=/usr/bin
            ;;
    esac
    if ! "$startup_shell" "$startup_case_dir/run.sh" --bin-dir "$startup_bin_dir" "$@" >"$startup_case_dir/stdout.log" 2>&1; then
        cat "$startup_case_dir/stdout.log"
        printf 'FAIL %s: runner exited before normal result publication\n' "$startup_name" >&2
        return 1
    fi
    if [ "$(cat "$startup_case_dir/fastrpc_test.res")" != "fastrpc_test $startup_verdict" ] ||
       grep -q '\[PASS\]' "$startup_case_dir/stdout.log"; then
        cat "$startup_case_dir/stdout.log"
        printf 'FAIL %s\n' "$startup_name" >&2
        exit 1
    fi
    printf 'PASS %s\n' "$startup_name"
}

# Fixture values are test-only boundaries, not new product environment options.
startup_domains="0 3"
startup_missing=3
startup_offline=""
startup_no_endpoint=""
startup_dt_error=0
startup_package_rc=2
FASTRPC_DOMAIN=""
FASTRPC_DOMAIN_NAME=""
export startup_domains startup_missing startup_offline startup_no_endpoint
export startup_dt_error startup_package_rc FASTRPC_DOMAIN FASTRPC_DOMAIN_NAME

startup_case missing-binary-and-cdsp FAIL missing
grep -q 'CDSP.*expected but not registered' "$startup_case_dir/stdout.log"
startup_case explicit-cdsp-without-binary FAIL missing --domain-name cdsp
startup_case explicit-adsp-ignores-cdsp SKIP missing --domain-name adsp
if grep -q DT_INVENTORY "$startup_case_dir/stdout.log"; then
    exit 1
fi
startup_case invalid-explicit-domain FAIL missing --domain-name invalid
FASTRPC_DOMAIN_NAME=cdsp
startup_case environment-required-cdsp FAIL missing
FASTRPC_DOMAIN_NAME=""
startup_missing=""
startup_offline=3
startup_case offline-cdsp-without-binary FAIL missing
startup_offline=""
startup_no_endpoint=3
startup_case missing-endpoint-without-binary FAIL missing
startup_no_endpoint=""
startup_case healthy-registration-no-binary SKIP missing
startup_domains=0
startup_missing=3
startup_case absent-cdsp-adsp-only-no-binary SKIP missing
grep -q 'domain=ADSP kernel_registration=ready' "$startup_case_dir/stdout.log"
if grep -q 'CDSP.*expected' "$startup_case_dir/stdout.log"; then
    exit 1
fi
startup_missing=""
startup_domains=""
startup_case no-expectation-no-binary SKIP missing
startup_dt_error=1
startup_case discovery-error-no-binary FAIL missing
startup_dt_error=0
startup_missing=3
startup_domains="0 3"
startup_case installed-binary-bypasses-early-preflight SKIP installed
grep -q NORMAL_EXECUTION_REACHED "$startup_case_dir/stdout.log"
if grep -q DT_INVENTORY "$startup_case_dir/stdout.log"; then
    exit 1
fi

if [ ! -x /usr/bin/fastrpc_test ]; then
    startup_case registration-fails-before-package-provider FAIL default
    if grep -q PACKAGE_PROVIDER "$startup_case_dir/stdout.log"; then
        exit 1
    fi
    startup_missing=""
    startup_case image-managed-missing-binary SKIP default
    grep -q 'PACKAGE_PROVIDER fastrpc' "$startup_case_dir/stdout.log"
    startup_package_rc=1
    startup_case existing-package-provider-failure FAIL default
    startup_package_rc=0
    startup_case existing-package-provider-success SKIP default
    grep -q NORMAL_EXECUTION_REACHED "$startup_case_dir/stdout.log"
else
    printf 'SKIP default-path provider mocks, host already has /usr/bin/fastrpc_test\n'
fi
printf 'FastRPC full-runner startup checks passed, no DUT operations executed.\n'
