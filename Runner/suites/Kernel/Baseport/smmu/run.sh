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

# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat grep awk find readlink wc od tr sort cp sed id date mktemp head uname; then
    test_result_finish SKIP "SMMU inventory tools are absent from the image"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create SMMU evidence under CWD=$PWD"

# Reuse the shared validator, only registered devices independently expose DMA.
iommu_validate_runtime_devices "$OUT_DIR" registered
context_rc=$?
runtime_validated=0
log_file_with_label IOMMU-CONTEXT "$OUT_DIR/iommu_contexts.tsv" 120
case "$context_rc" in
    0)
        runtime_validated=1
        context_count=$(wc -l <"$OUT_DIR/iommu_contexts.tsv" | tr -d '[:space:]')
        test_result_record PASS "All $context_count enabled registered DT DMA contexts have verified group membership"
        ;;
    2)
        if [ -s "$OUT_DIR/iommu_group_members.tsv" ]; then
            runtime_validated=1
            member_count=$(wc -l <"$OUT_DIR/iommu_group_members.tsv" | tr -d '[:space:]')
            test_result_record PASS "Runtime IOMMU groups contain $member_count devices"
        fi
        test_result_record SKIP "No registered enabled DT DMA context was available for attachment validation"
        ;;
    *)
        log_file_with_label IOMMU-GROUPS "$OUT_DIR/iommu_group_members.tsv" 120
        test_result_record FAIL "DT DMA attachment is missing or inconsistent, inspect $OUT_DIR/iommu_contexts.tsv and iommu_group_members.tsv"
        ;;
esac

# Correct API: result directory, module expression, benign exclusions.
scan_dmesg_errors "$OUT_DIR" '.*(arm-smmu|smmu|iommu).*' \
    'dummy regulator|supply [^ ]+ not found|using dummy regulator|^(\[[^]]+\][[:space:]]+)*iommu: DMA domain TLB invalidation policy: (strict|lazy) mode[[:space:]]*$' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record SKIP "Kernel log access unavailable, inspect $OUT_DIR/dmesg_access.log"
else
    # Reuse the captured log for fault wording outside the generic scanner.
    grep -Ei 'smmu|iommu' "$OUT_DIR/dmesg_snapshot.log" >"$OUT_DIR/iommu_kernel.log" || true
    grep -Ei 'bypass mode|running in bypass|identity mapping|default domain type:[[:space:]]*(identity|passthrough)|translation fault|permission fault|context fault|global fault|unhandled|iova.*fault' \
        "$OUT_DIR/iommu_kernel.log" >>"$OUT_DIR/dmesg_errors.log" || true
    if [ -s "$OUT_DIR/dmesg_errors.log" ]; then
        log_file_with_label IOMMU-ERROR "$OUT_DIR/dmesg_errors.log"
        test_result_record FAIL "SMMU or IOMMU kernel errors detected, inspect $OUT_DIR/dmesg_errors.log"
    elif [ "$runtime_validated" -eq 1 ]; then
        test_result_record PASS "Captured kernel log has no SMMU or IOMMU error evidence"
    else
        log_info "No captured IOMMU errors, runtime DMA attachment evidence is unavailable"
    fi
fi
test_result_finish
