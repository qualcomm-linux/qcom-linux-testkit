#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Kernel_Module_Sign_OOT_check"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-------------------------------------------------"
log_info "----------- Starting $TESTNAME Test -------------"

# ---------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------
check_dependencies zcat grep modinfo dmesg find

# ---------------------------------------------------------------
# PART 1: Check CONFIG_MODULE_SIG in /proc/config.gz
# ---------------------------------------------------------------
log_info "--- Checking CONFIG_MODULE_SIG kernel config ---"

check_kernel_config "CONFIG_MODULE_SIG" || {
	log_fail "CONFIG_MODULE_SIG is not enabled in kernel config."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}
log_pass "CONFIG_MODULE_SIG is enabled in kernel config."

# Also check CONFIG_MODULE_SIG_FORCE as informational
if zcat /home/manjeet/config.gz 2>/dev/null | grep -q "^CONFIG_MODULE_SIG_FORCE=y"; then
    log_info "CONFIG_MODULE_SIG_FORCE is enabled (unsigned modules will be rejected)."
else
    log_info "CONFIG_MODULE_SIG_FORCE is NOT enabled (unsigned modules are permitted but may taint kernel)."
fi

# ---------------------------------------------------------------
# PART 2: Check signature field in modinfo for a kernel module
#         (In-tree modules ONLY — kernel/ subtree)
# ---------------------------------------------------------------
log_info "--- Checking module signature via modinfo ---"

KVER=$(uname -r)
MODULE_PATH="/usr/lib/modules/${KVER}"
INTREE_PATH="${MODULE_PATH}/kernel"   # <-- In-tree modules live here ONLY

if [ ! -d "${INTREE_PATH}" ]; then
    echo "[ERROR] In-tree module path not found: ${INTREE_PATH}" > "$res_file"
    exit 1
fi

# Search only under kernel/ — excludes extra/, external/, updates/ (OOT paths)
TOP_MODULE=$(find "${INTREE_PATH}" -type f \( -name "*.ko" -o -name "*.ko.zst" \) \
    -exec du -k {} + \
    | sort -rn \
    | awk 'NR==1 { print $2 }')

if [ -z "${TOP_MODULE}" ]; then
    echo "[ERROR] No in-tree .ko/.ko.zst modules found under ${INTREE_PATH}" > "$res_file"
    exit 1
fi

log_info "Inspecting in-tree module: $TOP_MODULE"
MODINFO_OUTPUT=$(modinfo "$TOP_MODULE" 2>/dev/null)

if echo "$MODINFO_OUTPUT" | grep -q "^signature:"; then
    log_pass "Module '$TOP_MODULE' contains a signature field — module signing is active."
    # Log signature metadata
    SIG_ID=$(echo "$MODINFO_OUTPUT" | grep "^sig_id:"      | awk '{print $2}')
    SIGNER=$(echo "$MODINFO_OUTPUT" | grep "^signer:"      | cut -d: -f2- | sed 's/^ //')
    SIG_ALGO=$(echo "$MODINFO_OUTPUT" | grep "^sig_hashalgo:" | awk '{print $2}')
    log_info "  sig_id      : ${SIG_ID:-N/A}"
    log_info "  signer      : ${SIGNER:-N/A}"
    log_info "  sig_hashalgo: ${SIG_ALGO:-N/A}"
    SIGNING_ACTIVE=1
else
    log_info "Module '$TOP_MODULE' does NOT contain a signature field."
    log_info "modinfo output:"
    echo "$MODINFO_OUTPUT" | while IFS= read -r line; do log_info "  $line"; done
    SIGNING_ACTIVE=0
fi

# ---------------------------------------------------------------
# PART 3: Detect out-of-tree kernel modules
# ---------------------------------------------------------------
log_info "--- Checking for out-of-tree kernel modules ---"

# Check dmesg for out-of-tree taints
log_info "Scanning dmesg for out-of-tree module taints..."
OOT_DMESG=$(dmesg 2>/dev/null | grep -i "out-of-tree")

if [ -n "$OOT_DMESG" ]; then
    log_info "Out-of-tree modules detected in dmesg:"
    echo "$OOT_DMESG" | while IFS= read -r line; do log_info "  $line"; done
    OOT_FOUND=1
else
    log_info "No out-of-tree module taints found in dmesg."
    OOT_FOUND=0
fi

# Check /sys/module for taint flags as a second method
log_info "Scanning /sys/module/*/taint for out-of-tree flags..."
OOT_SYSFS=""
for taint_file in /sys/module/*/taint; do
    [ -f "$taint_file" ] || continue
    taint_val=$(cat "$taint_file" 2>/dev/null)
    # 'O' flag in taint indicates out-of-tree
    if echo "$taint_val" | grep -q "O"; then
        mod_name=$(echo "$taint_file" | sed 's|/sys/module/||;s|/taint||')
        log_info "  Out-of-tree module (taint=O): $mod_name"
        OOT_SYSFS="$OOT_SYSFS $mod_name"
        OOT_FOUND=1
    fi
done

if [ -z "$OOT_SYSFS" ]; then
    log_info "No out-of-tree taint flags found in /sys/module/*/taint."
fi

# ---------------------------------------------------------------
# PART 4: Locate out-of-tree .ko files under /usr/lib/modules
# ---------------------------------------------------------------
log_info "--- Locating out-of-tree .ko files outside kernel/ subdirectory ---"

# Modules under /usr/lib/modules/<kver>/ but NOT under kernel/ are typically out-of-tree
OOT_FILES=$(find "/usr/lib/modules/${KVER}/" \
    -name "*.ko" -o -name "*.ko.zst" 2>/dev/null \
    | grep -v "/kernel/" 2>/dev/null)

if [ -n "$OOT_FILES" ]; then
    log_info "Potential out-of-tree .ko files found (outside kernel/ tree):"
    echo "$OOT_FILES" | while IFS= read -r f; do log_info "  $f"; done
    OOT_FOUND=1
else
    log_info "No out-of-tree .ko files detected outside /kernel/ subdirectory."
fi

# ---------------------------------------------------------------
# PART 5: For each detected out-of-tree module, check if signed
# ---------------------------------------------------------------
log_info "--- Verifying signatures on out-of-tree modules ---"

if [ -n "$OOT_FILES" ]; then
    echo "$OOT_FILES" | while IFS= read -r oot_mod; do
        OOT_INFO=$(modinfo "$oot_mod" 2>/dev/null)
        if echo "$OOT_INFO" | grep -q "^signature:"; then
            log_pass "  SIGNED   : $oot_mod"
        else
            log_info "  UNSIGNED : $oot_mod (no signature field in modinfo)"
        fi
    done
else
    log_info "No out-of-tree module files to check for signatures."
fi

# ---------------------------------------------------------------
# Final Verdict
# ---------------------------------------------------------------
log_info "--- Final Output ---"
log_info "CONFIG_MODULE_SIG enabled : YES"
log_info "In-tree module signed     : $([ "$SIGNING_ACTIVE" -eq 1 ] && echo YES || echo NO)"
log_info "Out-of-tree modules found : $([ "$OOT_FOUND" -eq 1 ] && echo YES || echo NO)"

if [ "$SIGNING_ACTIVE" -eq 1 ]; then
    log_pass "$TESTNAME PASSED — Module signing is active and kernel config is valid."
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME FAILED — Module signing is NOT active on inspected module(s)."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
