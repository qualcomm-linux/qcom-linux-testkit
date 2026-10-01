#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# fastcv_collect_test_markers LOG_FILE MODULE FUNCTION WITHOUT_OPERATION_MODE
# Classify success and failure markers emitted by supported fastcv_test builds.
# Inputs: a readable command log, the selected module, an optional function,
# and a 0/1 without-operation-mode flag. Output: no stdout.
# Returns: 0 after parsing or 1 when the log is unreadable.
# Side effects: updates FASTCV_MARKER_FAILURE_COUNT, FASTCV_MARKER_FIT_COUNT,
# FASTCV_MARKER_PROFILE_SUMMARY_COUNT, FASTCV_MARKER_PROFILE_CASE_PASS_COUNT,
# FASTCV_MARKER_MODULE_COUNT, FASTCV_MARKER_FUNCTION_COUNT, and
# FASTCV_MARKER_WITHOUT_MODE_COUNT for the caller.
fastcv_collect_test_markers() {
    fcctm_log="$1"
    fcctm_module="$2"
    fcctm_function="$3"
    fcctm_without_mode="$4"

    FASTCV_MARKER_FAILURE_COUNT=0
    FASTCV_MARKER_FIT_COUNT=0
    FASTCV_MARKER_PROFILE_SUMMARY_COUNT=0
    FASTCV_MARKER_PROFILE_CASE_PASS_COUNT=0
    FASTCV_MARKER_MODULE_COUNT=0
    FASTCV_MARKER_FUNCTION_COUNT=0
    FASTCV_MARKER_WITHOUT_MODE_COUNT=0
    fcctm_profile_function_count=0

    [ -r "$fcctm_log" ] || return 1

    # Exported result state for suite callers.
    # shellcheck disable=SC2034
    FASTCV_MARKER_FAILURE_COUNT=$(grep -E -c \
        '(^FASTCV_TEST, .*=>FAIL[[:space:]]*$)|(^FASTCV_PROFILE, .* :: FAIL([,[:space:]]|$))|(^((FASTCV_PROFILE, )?FIT:\(FeatureName=>FASTCV, Overall=>FAIL\))[[:space:]]*$)' \
        "$fcctm_log" 2>/dev/null || true)
    # Exported result state for suite callers.
    # shellcheck disable=SC2034
    FASTCV_MARKER_FIT_COUNT=$(grep -E -c \
        '^FIT:\(FeatureName=>FASTCV, Overall=>PASS\)[[:space:]]*$' \
        "$fcctm_log" 2>/dev/null || true)
    # Exported result state for suite callers.
    # shellcheck disable=SC2034
    FASTCV_MARKER_PROFILE_SUMMARY_COUNT=$(grep -E -c \
        '^FASTCV_PROFILE, FIT:\(FeatureName=>FASTCV, Overall=>PASS\)[[:space:]]*$' \
        "$fcctm_log" 2>/dev/null || true)
    # Exported result state for suite callers.
    # shellcheck disable=SC2034
    FASTCV_MARKER_PROFILE_CASE_PASS_COUNT=$(grep -E -c \
        '^FASTCV_PROFILE, .+ :: PASS(,|[[:space:]]*$)' \
        "$fcctm_log" 2>/dev/null || true)

    if [ "$fcctm_module" = "ALL" ]; then
        # Exported result state for suite callers.
        # shellcheck disable=SC2034
        FASTCV_MARKER_MODULE_COUNT=$(grep -E -c \
            '^FASTCV_TEST, [^=]+=>PASS[[:space:]]*$' \
            "$fcctm_log" 2>/dev/null || true)
    else
        # Exported result state for suite callers.
        # shellcheck disable=SC2034
        FASTCV_MARKER_MODULE_COUNT=$(grep -F -c \
            "FASTCV_TEST, $fcctm_module=>PASS" \
            "$fcctm_log" 2>/dev/null || true)
    fi

    if [ -n "$fcctm_function" ]; then
        FASTCV_MARKER_FUNCTION_COUNT=$(grep -E -c \
            "^Function chosen: ${fcctm_function}[[:space:]]*$" \
            "$fcctm_log" 2>/dev/null || true)
        fcctm_profile_function_count=$(grep -E -c \
            "^FASTCV_PROFILE, $fcctm_function :: PASS(,|[[:space:]]*$)" \
            "$fcctm_log" 2>/dev/null || true)
        FASTCV_MARKER_FUNCTION_COUNT=$((
            FASTCV_MARKER_FUNCTION_COUNT +
            fcctm_profile_function_count
        ))
    fi

    if [ "$fcctm_without_mode" -eq 1 ]; then
        # Exported result state for suite callers.
        # shellcheck disable=SC2034
        FASTCV_MARKER_WITHOUT_MODE_COUNT=$(grep -F -c \
            'Running fastCV API without calling setOperationMode is pass' \
            "$fcctm_log" 2>/dev/null || true)
    fi

    return 0
}

# fastcv_prepare_runtime_packages
# Ensure the FastCV runtime package set on supported host distributions.
# Inputs: none. Output: no machine-readable stdout contract.
# Returns: 0 when packages are ready, 1 when required recovery fails, and 2
# when the target is an image-managed or otherwise unsupported distribution.
# Side effects: may configure Qualcomm RPM repositories on CentOS/RHEL and may
# install mapped packages through lib_pkg_provider.sh. Package-set upgrades are
# disabled for this operation and the prior policy is restored before return.
# Yocto remains unchanged.
fastcv_prepare_runtime_packages() {
    fcprp_os_id="$(pkg_detect_os_id)"

    for fcprp_helper in \
        pkg_provider_init \
        pkg_ensure_host_distro_package_set_present \
        pkg_prepare_qualcomm_rpm_overlay_repositories \
        pkg_ensure_required_package_set_present \
        pkg_verify_package_set_installed \
        pkg_package_recovery_supported_os; do
        if ! command -v "$fcprp_helper" >/dev/null 2>&1; then
            log_error "FastCV package preparation helper is unavailable: $fcprp_helper"
            return 1
        fi
    done

    if ! pkg_package_recovery_supported_os "$fcprp_os_id"; then
        log_info "[FASTCV-PACKAGES] action=image-provided os=$fcprp_os_id set=fastcv-runtime"
        return 2
    fi

    if ! pkg_provider_init; then
        log_error "FastCV package provider initialization failed"
        return 1
    fi

    if pkg_verify_package_set_installed fastcv-runtime; then
        log_info "[FASTCV-PACKAGES] action=already-ready os=$fcprp_os_id set=fastcv-runtime upgrades=disabled"
        return 0
    fi

    fcprp_previous_set_upgrade="$PKG_PACKAGE_SET_UPGRADE"
    PKG_PACKAGE_SET_UPGRADE=0
    fcprp_rc=0

    case "$fcprp_os_id" in
        centos|rhel)
            if ! pkg_prepare_qualcomm_rpm_overlay_repositories; then
                fcprp_rc=1
            fi
            ;;
    esac

    if [ "$fcprp_rc" -eq 0 ] &&
       ! pkg_ensure_host_distro_package_set_present fastcv-runtime; then
        fcprp_rc=1
    fi

    PKG_PACKAGE_SET_UPGRADE="$fcprp_previous_set_upgrade"

    if [ "$fcprp_rc" -ne 0 ]; then
        return "$fcprp_rc"
    fi

    log_info "[FASTCV-PACKAGES] action=ready os=$fcprp_os_id set=fastcv-runtime upgrades=disabled"
    return 0
}
