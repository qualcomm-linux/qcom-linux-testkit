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
. "$TOOLS/lib_iommu.sh"

TESTNAME="smmu"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! check_dependencies cat grep sort readlink mkdir tr sed; then
    test_result_finish SKIP "Image lacks the tools required for IOMMU inventory"
fi
RESULT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || test_result_finish FAIL "Cannot create IOMMU evidence directory"
scan_dmesg_errors "$RESULT_DIR" 'arm-smmu.*|iommu.*|smmu.*' 'deferred probe|EPROBE_DEFER' || true
# Reuse the snapshot, the common filter alone does not cover fault-only lines.
grep -Ei 'smmu|iommu|default domain type:' "$RESULT_DIR/dmesg_snapshot.log" \
    >"$RESULT_DIR/iommu.log" || true
log_file_with_label IOMMU "$RESULT_DIR/iommu.log"
if grep -Ei 'translation fault|permission fault|context fault|global fault|unhandled.*fault|failed|error|running in bypass|default domain type:[[:space:]]*(identity|passthrough)' \
    "$RESULT_DIR/iommu.log" >"$RESULT_DIR/iommu_errors.log"; then
    test_result_record FAIL "IOMMU initialization, translation or bypass errors, see $RESULT_DIR/iommu_errors.log"
fi
if [ ! -s "$RESULT_DIR/dmesg_snapshot.log" ]; then
    test_result_record SKIP "Kernel log access is unavailable for IOMMU health validation"
fi
if ! iommu_collect_runtime "$RESULT_DIR"; then
    test_result_record FAIL "Runtime DT DMA attachment validation failed, see $RESULT_DIR/masters.tsv"
elif [ "$IOMMU_MASTER_COUNT" -gt 0 ]; then
    test_result_record PASS "All $IOMMU_MASTER_COUNT enabled bound DT DMA masters have actual group membership"
elif [ "$IOMMU_MEMBER_COUNT" -gt 0 ]; then
    test_result_record PASS "Runtime IOMMU groups contain $IOMMU_MEMBER_COUNT devices"
    test_result_record SKIP "No registered enabled DT DMA master exposes an iommus property"
else
    test_result_record SKIP "No runtime IOMMU group members or registered DT DMA masters"
fi
test_result_finish
