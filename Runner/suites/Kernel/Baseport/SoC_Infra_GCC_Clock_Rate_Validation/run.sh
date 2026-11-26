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

TESTNAME="SoC_Infra_GCC_Clock_Rate_Validation"
RES_FILE="./$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

CLK_PREFIX="gcc"
# Current SoCs use qcom,<soc>-gcc; older ones use qcom,gcc-<soc>.
GCC_ERE='(^|[[:space:]])qcom,([[:alnum:]_-]+-gcc|gcc-[[:alnum:]_-]+)([[:space:]]|$)'
REPORT_FILE="./gcc_clk_rates.log"

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"

# Never install packages on the target; skip when a base utility is missing.
if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies find grep cat tr readlink dirname basename mktemp; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

# debugfs is a prerequisite of its own. It needs CONFIG_DEBUG_FS and a mount, and
# the clk/ tree exists only when the clock framework registered its debugfs
# files. A GCC node in the device tree guarantees none of that, so an
# unavailable interface is a SKIP, not a FAIL. FAIL is kept below for the cases
# where the interface is present and the clocks are still broken.
if ! debugfs_root=$(socinfra_debugfs_root); then
    test_result_finish "SKIP" "$TESTNAME SKIP: debugfs is not mounted or not readable, so the clock tree is unavailable (mount -t debugfs debugfs /sys/kernel/debug, run as root)"
fi
if [ ! -d "$debugfs_root/clk" ] || [ ! -r "$debugfs_root/clk" ] || [ ! -x "$debugfs_root/clk" ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: $debugfs_root/clk is not available, the kernel does not expose the clock tree in debugfs"
fi

# The interface is usable. The device tree now decides whether the platform has
# a global clock controller, so having no GCC clocks on such a platform is a
# failure and not a skip.
gcc_in_dt=0
if dt_list_compatible_nodes "$GCC_ERE" regex >/dev/null 2>&1; then
    gcc_in_dt=1
fi
log_info "Global clock controller (*-gcc) in the device tree: $gcc_in_dt"
log_info "Checking $debugfs_root/clk/${CLK_PREFIX}*/clk_rate"

socinfra_check_clk_rates "$debugfs_root" "$CLK_PREFIX" "$REPORT_FILE"
clk_rc=$?
log_info "Clocks checked: total=$SOCINFRA_CLK_TOTAL invalid=$SOCINFRA_CLK_BAD (details: $REPORT_FILE)"
# Replay the report so the job log shows every clock name and its rate in Hz.
# clk_rc is already saved above and the replay always returns 0. The report file
# is kept as a result artifact.
log_file_with_label "GCC-CLK-RATE-HZ" "$REPORT_FILE"

case "$clk_rc" in
    0)
        test_result_record "PASS" "All $SOCINFRA_CLK_TOTAL ${CLK_PREFIX}* clock rates are integers"
        ;;
    2)
        if [ "$gcc_in_dt" -eq 1 ]; then
            test_result_finish "FAIL" "$TESTNAME FAIL: the device tree has a global clock controller but no ${CLK_PREFIX}* clocks are registered under $debugfs_root/clk; check the GCC clock driver"
        fi
        test_result_finish "SKIP" "$TESTNAME SKIP: no ${CLK_PREFIX}* clocks under $debugfs_root/clk and no global clock controller in the device tree"
        ;;
    *)
        grep -E 'NOT_INTEGER|READ_ERROR' "$REPORT_FILE" | while IFS= read -r bad_line; do
            log_fail "Invalid clock rate: $bad_line"
        done
        test_result_record "FAIL" "$SOCINFRA_CLK_BAD of $SOCINFRA_CLK_TOTAL ${CLK_PREFIX}* clock rates are not valid integers or cannot be read"
        ;;
esac

test_result_finish
