#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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
    echo "[ERROR] Could not find init_env, starting at $SCRIPT_DIR" >&2
    exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="smmu"
test_path="$(find_test_case_by_name "$TESTNAME")" || {
    log_fail "$TESTNAME, test directory not found"
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}

cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"

FAIL_COUNT=0
WARN_COUNT=0

inc_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

inc_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
}

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"
log_info "=== Test Initialization ==="

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies grep awk ls readlink basename find wc; then
    log_skip "$TESTNAME SKIP, missing required dependencies"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Checking required SMMU kernel configs"
if ! check_kernel_config "CONFIG_IOMMU_API CONFIG_ARM_SMMU CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=y"; then
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

log_info "Checking optional SMMU v3 kernel config"
if check_kernel_config "CONFIG_ARM_SMMU_V3"; then
    log_pass "Optional SMMU v3 config is enabled"
else
    log_warn "CONFIG_ARM_SMMU_V3 is not enabled, continuing because some targets may use a different SMMU configuration"
    inc_warn
fi

log_info "Checking IOMMU groups path"
if command -v wait_for_path >/dev/null 2>&1; then
    if ! wait_for_path "/sys/kernel/iommu_groups" 3; then
        log_fail "/sys/kernel/iommu_groups is not present"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0
    fi
else
    if [ ! -d /sys/kernel/iommu_groups ]; then
        log_fail "/sys/kernel/iommu_groups is not present"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0
    fi
fi
log_pass "/sys/kernel/iommu_groups is present"

group_count="$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | awk '{print $1}')"
if [ -z "$group_count" ] || [ "$group_count" -le 0 ]; then
    log_fail "No IOMMU groups found under /sys/kernel/iommu_groups"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_pass "IOMMU groups are present, count ${group_count}"

log_info "Enumerating IOMMU groups"
for group_dir in /sys/kernel/iommu_groups/*; do
    [ -d "$group_dir" ] || continue
    group_id="$(basename "$group_dir")"
    if [ -d "$group_dir/devices" ]; then
        device_count="$(find "$group_dir/devices" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | awk '{print $1}')"
        log_info "IOMMU group ${group_id}, device count ${device_count}"
    else
        log_warn "IOMMU group ${group_id} has no devices directory"
        inc_warn
    fi
done

log_info "Checking platform devices attached to IOMMU groups"
protected_device_count=0
critical_seen_count=0
critical_fail_count=0

for dev in /sys/bus/platform/devices/*; do
    [ -e "$dev" ] || continue
    dev_name="$(basename "$dev")"

    if [ -e "$dev/iommu_group" ]; then
        group_target="$(readlink "$dev/iommu_group" 2>/dev/null || true)"
        group_id="$(basename "$group_target")"
        protected_device_count=$((protected_device_count + 1))
        if [ -n "$group_id" ]; then
            log_info "Protected device, ${dev_name} -> IOMMU group ${group_id}"
        else
            log_info "Protected device, ${dev_name} -> iommu_group attached"
        fi
    fi

    dev_role=""
    case "$dev_name" in
        *.gpu)
            dev_role="GPU"
            ;;
        *display-subsystem*)
            dev_role="Display"
            ;;
        *.isp|*camss*|*camera-subsystem*)
            dev_role="Camera"
            ;;
        *video-codec*)
            dev_role="Video"
            ;;
        *.ufshc)
            dev_role="UFS"
            ;;
        *.usb)
            dev_role="USB"
            ;;
        *.ethernet)
            dev_role="Ethernet"
            ;;
        *lpass*|*audioreach*|*q6dsp*)
            dev_role="Audio"
            ;;
    esac

    if [ -n "$dev_role" ]; then
        critical_seen_count=$((critical_seen_count + 1))
        if [ -e "$dev/iommu_group" ]; then
            group_target="$(readlink "$dev/iommu_group" 2>/dev/null || true)"
            group_id="$(basename "$group_target")"
            if [ -n "$group_id" ]; then
                log_pass "Critical master protected, ${dev_role} ${dev_name} -> group ${group_id}"
            else
                log_pass "Critical master protected, ${dev_role} ${dev_name} -> iommu_group attached"
            fi
        else
            log_fail "Critical master is missing iommu_group attachment, ${dev_role} ${dev_name}"
            critical_fail_count=$((critical_fail_count + 1))
            inc_fail
        fi
    fi
done

if [ "$protected_device_count" -le 0 ]; then
    log_fail "No platform devices were found attached to any IOMMU group"
    inc_fail
else
    log_pass "Platform devices attached to IOMMU groups found, count ${protected_device_count}"
fi

if [ "$critical_seen_count" -le 0 ]; then
    log_warn "No critical DMA masters were matched on this platform, check naming patterns if this is unexpected"
    inc_warn
fi

if [ "$critical_fail_count" -eq 0 ] && [ "$critical_seen_count" -gt 0 ]; then
    log_pass "All discovered critical DMA masters are attached to IOMMU groups"
fi

log_info "Scanning kernel log for SMMU and IOMMU errors"
# scan_dmesg_errors(label, out_dir, extra_err, ok_kw)
scan_dmesg_errors \
    "smmu" \
    "." \
    "bypass mode|running in bypass|identity mapping|default domain type:[[:space:]]*passthrough|translation fault|permission fault|context fault|global fault|unhandled.*smmu|iova.*fault" \
    "Default domain type: DMA|arm-smmu|iommu"
scan_rc=$?

case "$scan_rc" in
    0)
        log_fail "SMMU or IOMMU related errors were found in kernel log, see smmu_dmesg_errors.log"
        inc_fail
        ;;
    1)
        log_pass "No SMMU or IOMMU related errors found in kernel log"
        ;;
    2)
        log_warn "No explicit SMMU success pattern was found in kernel log, continuing because iommu_groups and protected masters are present"
        inc_warn
        ;;
    3)
        log_fail "scan_dmesg_errors reported misuse for SMMU scan"
        inc_fail
        ;;
esac

if command -v get_kernel_log >/dev/null 2>&1; then
    smmu_log_excerpt="$(get_kernel_log 2>/dev/null | grep -Ei 'smmu|iommu' || true)"
    if [ -n "$smmu_log_excerpt" ]; then
        log_info "Showing recent SMMU and IOMMU kernel log lines, capped at 40"
        printf '%s\n' "$smmu_log_excerpt" | tail -n 40 | while IFS= read -r line; do
            [ -n "$line" ] || continue
            log_info "[iommu-log] $line"
        done
    else
        log_warn "No SMMU or IOMMU lines found through get_kernel_log"
        inc_warn
    fi
fi

log_info "Completed with WARN=${WARN_COUNT}, FAIL=${FAIL_COUNT}"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "$TESTNAME FAIL" > "$res_file"
else
    echo "$TESTNAME PASS" > "$res_file"
fi

exit 0
