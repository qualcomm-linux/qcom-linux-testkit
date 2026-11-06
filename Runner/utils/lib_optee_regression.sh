#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# optee_regression_summary <log-file> <case-id>
# Validate exact selected-case completion and all failure totals, not exit alone.
optee_regression_summary() {
    local log="$1" case_id="$2"
    if ! grep -Eq "regression_${case_id}([[:space:]]|$)" "$log"; then
        return 1
    fi
    optee_validate_xtest_log "$log"
}

# optee_regression_run
# Run explicitly reviewed image-provided cases without changing smoke defaults.
optee_regression_run() {
    local selection device binary case_id status summary case_list uuid asset root
    if [ "$SCENARIO_EXERCISE" != 1 ] || [ -z "$SCENARIO_CASES" ]; then
        test_result_record SKIP "Additional TA regressions require --exercise --cases with reviewed case IDs, native smoke defaults remain separate"
        return
    fi
    optee_capture_device_inventory "$SCENARIO_DIR/tee-devices.tsv" || return 1
    optee_log_device_inventory "$SCENARIO_DIR/tee-devices.tsv" 16
    selection=$(optee_select_device "$SCENARIO_DIR/tee-devices.tsv")
    if [ -z "$selection" ]; then
        test_result_record SKIP "No native public OP-TEE device was discovered"
        return
    fi
    device=$(printf '%s\n' "$selection" | cut -f1)
    binary=$(command -v "$SCENARIO_XTEST" 2>/dev/null)
    if [ -z "$binary" ]; then
        test_result_record SKIP "Native OP-TEE device=$device has no image-provided xtest binary"
        return
    fi
    # The supplied case list is a job/operator-reviewed test-tier contract.
    # Never run the entire catalogue or expand the native smoke allowlist.
    case_list=$(printf '%s\n' "$SCENARIO_CASES" | tr ',' '\n' | sort -u)
    scenario_capture_kernel kernel-before || true
    for case_id in $case_list; do
        uuid=""
        case "$case_id" in
            1003)
                ;;
            1004)
                uuid=cb3e5ba0-adf1-11e0-998b-0002a5d5c51b
                ;;
            1005)
                uuid=e13010e0-2ae1-11e5-896a-0002a5d5c51b
                ;;
            1006)
                uuid=5b9e0e40-2636-11e1-ad9e-0002a5d5c51b
                ;;
            *)
                test_result_record FAIL "Case=$case_id is outside the reviewed non-provisioning tier: 1003,1004,1005,1006"
                continue
                ;;
        esac
        if [ -n "$uuid" ]; then
            asset=""
            for root in /lib/optee_armtz /usr/lib/optee_armtz "$SCENARIO_TA_DIR"; do
                if [ -n "$root" ] && [ -r "$root/$uuid.ta" ]; then
                    asset="$root/$uuid.ta"
                    break
                fi
            done
            if [ -z "$asset" ]; then
                test_result_record SKIP "Case=$case_id requires image-provided TA=$uuid.ta, supply --ta-dir for an installed alternate directory"
                continue
            fi
        fi
        log_info "[OPTEE-REGRESSION] selected_case=$case_id device=$device prerequisites=matching-image-provided-TAs"
        scenario_command "xtest-$case_id" "$binary" -d optee-tz -t regression -l 0 "$case_id"
        status=$?
        optee_regression_summary "$SCENARIO_DIR/xtest-$case_id.log" "$case_id"
        summary=$?
        if [ "$status" = 0 ] && [ "$summary" = 0 ]; then
            # shellcheck disable=SC2034 # Required by scenario_finish.
            SCENARIO_VALIDATED=1
            test_result_record PASS "OP-TEE regression case=$case_id completed with zero failures"
        elif [ "$status" = 0 ] && [ "$summary" = 2 ]; then
            test_result_record SKIP "OP-TEE regression case=$case_id was explicitly skipped by xtest, inspect optional PTA/TA prerequisites"
        else
            test_result_record FAIL "OP-TEE regression case=$case_id failed or lacks complete selected-case evidence, process_status=$status"
        fi
    done
    scenario_capture_kernel kernel-after || true
    scenario_kernel_delta kernel-before kernel-after \
        'BUG:|WARNING:|Oops:|panic|Call trace:|optee.*(failed|error)|mem_reclaim:' || true
}
