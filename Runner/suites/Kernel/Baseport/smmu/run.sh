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

TESTNAME="smmu"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat grep awk find readlink wc od tr sort cp sed id date mktemp head uname; then
    test_result_finish SKIP "SMMU inventory tools are absent from the image"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create SMMU evidence under CWD=$PWD"

if ! check_kernel_config "CONFIG_IOMMU_API CONFIG_ARM_SMMU CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=y"; then
    test_result_finish FAIL "Required SMMU kernel configuration is unavailable, inspect the running kernel config"
fi
if ! wait_for_path /sys/kernel/iommu_groups 3; then
    test_result_finish FAIL "No runtime IOMMU groups path, check enabled SMMU DT providers and kernel drivers"
fi
find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d >"$OUT_DIR/iommu_groups.log" ||
    test_result_finish FAIL "Cannot enumerate runtime IOMMU groups"
group_count=$(wc -l <"$OUT_DIR/iommu_groups.log" | tr -d '[:space:]')
if [ "$group_count" -eq 0 ]; then
    test_result_finish FAIL "No IOMMU group registered for the running DT and kernel"
fi
test_result_record PASS "Runtime IOMMU groups registered, count=$group_count"

iommu_validate_runtime_devices "$OUT_DIR"
context_rc=$?
log_file_with_label IOMMU-CONTEXT "$OUT_DIR/iommu_contexts.tsv"
case "$context_rc" in
    0)
        test_result_record PASS "Enabled DT DMA contexts have runtime IOMMU attachments"
        ;;
    2)
        test_result_record SKIP "DT iommus context evidence is unavailable, only runtime group registration was validated"
        ;;
    *)
        test_result_record FAIL "DT DMA context attachment is incomplete, inspect $OUT_DIR/iommu_contexts.tsv and driver suppliers"
        ;;
esac

# Correct API: result directory, module expression, benign exclusions.
scan_dmesg_errors "$OUT_DIR" '.*(arm-smmu|smmu|iommu).*' \
    'dummy regulator|supply [^ ]+ not found|using dummy regulator|^\[[^]]+\][[:space:]]+iommu: DMA domain TLB invalidation policy: (strict|lazy) mode[[:space:]]*$' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record SKIP "Kernel log access unavailable, inspect $OUT_DIR/dmesg_access.log"
else
    # Reuse the captured log for fault wording outside the generic scanner.
    grep -Ei 'smmu|iommu' "$OUT_DIR/dmesg_snapshot.log" >"$OUT_DIR/iommu_kernel.log" || true
    grep -Ei 'bypass mode|running in bypass|identity mapping|default domain type:[[:space:]]*passthrough|translation fault|permission fault|context fault|global fault|unhandled|iova.*fault' \
        "$OUT_DIR/iommu_kernel.log" >>"$OUT_DIR/dmesg_errors.log" || true
    if [ -s "$OUT_DIR/dmesg_errors.log" ]; then
        log_file_with_label IOMMU-ERROR "$OUT_DIR/dmesg_errors.log"
        test_result_record FAIL "SMMU or IOMMU kernel errors detected, inspect $OUT_DIR/dmesg_errors.log"
    else
        test_result_record PASS "Captured kernel log has no SMMU or IOMMU error evidence"
    fi
fi
test_result_finish
