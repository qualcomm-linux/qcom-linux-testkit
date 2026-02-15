#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
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

TESTNAME="wpss_remoteproc"
FW="wpss"
RES_FILE="./$TESTNAME.res"

# Run from the testcase directory so relative outputs (like .res) land next to run.sh
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || {
    echo "[ERROR] Could not cd to testcase path: $test_path" >&2
    exit 1
}
log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"
log_info "=== Test Initialization ==="

# Tunables
STOP_TO="${STOP_TO:-10}"
START_TO="${START_TO:-10}"
POLL_I="${POLL_I:-1}"

# ---------- Try remoteproc path ----------
rp_entries=""
dt_says_present=0

if dt_has_remoteproc_fw "$FW"; then
    dt_says_present=1
    log_info "DT indicates $FW is present"
    # prints: path|state|firmware|name (multiple lines)
    rp_entries="$(get_remoteproc_by_firmware "$FW" "" all)" || rp_entries=""
else
    log_info "DT does NOT list $FW – may be driver-loaded (ath11k) on this platform"
fi

if [ -n "$rp_entries" ]; then
    log_info "Remoteproc mode selected (found $(printf '%s\n' "$rp_entries" | wc -l) instance(s))"

    inst_fail=0
    RESULT_LINES=""
    tmp_list="$(mktemp)"
    printf '%s\n' "$rp_entries" >"$tmp_list"

    while IFS='|' read -r rpath rstate rfirm rname; do
        [ -n "$rpath" ] || continue
        inst="$(basename "$rpath")"

        log_info "---- $inst: path=$rpath state=$rstate firmware=$rfirm name=$rname ----"

        boot_res="PASS"
        stop_res="NA"
        start_res="NA"
        ping_res="SKIPPED"

        # Boot check
        if [ "$rstate" = "running" ]; then
            log_pass "$inst: boot check PASS"
        else
            log_fail "$inst: boot check FAIL (state=$rstate)"
            boot_res="FAIL"
            inst_fail=$((inst_fail + 1))
            RESULT_LINES="$RESULT_LINES
 $inst: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
            continue
        fi

        # Stop
        dump_rproc_logs "$rpath" before-stop
        t0=$(date +%s)
        log_info "$inst: stopping"
        if stop_remoteproc "$rpath" && wait_remoteproc_state "$rpath" offline "$STOP_TO" "$POLL_I"; then
            t1=$(date +%s)
            log_pass "$inst: stop PASS ($((t1 - t0))s)"
            stop_res="PASS"
        else
            dump_rproc_logs "$rpath" after-stop-fail
            log_fail "$inst: stop FAIL"
            stop_res="FAIL"
            inst_fail=$((inst_fail + 1))
            RESULT_LINES="$RESULT_LINES
 $inst: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
            continue
        fi
        dump_rproc_logs "$rpath" after-stop

        # Start
        dump_rproc_logs "$rpath" before-start
        t2=$(date +%s)
        log_info "$inst: starting"
        if start_remoteproc "$rpath" && wait_remoteproc_state "$rpath" running "$START_TO" "$POLL_I"; then
            t3=$(date +%s)
            log_pass "$inst: start PASS ($((t3 - t2))s)"
            start_res="PASS"
        else
            dump_rproc_logs "$rpath" after-start-fail
            log_fail "$inst: start FAIL"
            start_res="FAIL"
            inst_fail=$((inst_fail + 1))
            RESULT_LINES="$RESULT_LINES
 $inst: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
            continue
        fi
        dump_rproc_logs "$rpath" after-start

        # RPMsg ping (optional)
        if CTRL_DEV=$(find_rpmsg_ctrl_for "$FW"); then
            log_info "$inst: RPMsg ctrl dev: $CTRL_DEV"
            if rpmsg_ping_generic "$CTRL_DEV"; then
                log_pass "$inst: rpmsg ping PASS"
                ping_res="PASS"
            else
                log_warn "$inst: rpmsg ping FAIL"
                ping_res="FAIL"
                inst_fail=$((inst_fail + 1))
            fi
        else
            log_info "$inst: no RPMsg channel, skipping ping"
        fi

        RESULT_LINES="$RESULT_LINES
 $inst: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"

    done <"$tmp_list"
    rm -f "$tmp_list"

    log_info "Instance results:$RESULT_LINES"

    if [ "$inst_fail" -gt 0 ]; then
        log_fail "One or more $FW instance(s) failed ($inst_fail)"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi

    log_pass "All $FW remoteproc instance(s) passed"
    echo "$TESTNAME PASS" >"$RES_FILE"
    exit 0
fi

# ---------- Fallback: ath11k driver mode ----------
log_info "Remoteproc instance not used → checking ath11k driver path"

# Is ath11k/ath11xx loaded?
if lsmod | grep -qE '^ath11k(_pci)?\b'; then
    log_pass "ath11k driver is loaded"
else
    # Try modprobe quietly
    if command -v modprobe >/dev/null 2>&1 && modprobe ath11k_pci 2>/dev/null; then
        log_info "Loaded ath11k_pci via modprobe"
    fi

    if lsmod | grep -qE '^ath11k(_pci)?\b'; then
        log_pass "ath11k driver loaded (post-modprobe)"
    else
        # If DT said WPSS present but neither remoteproc nor driver -> FAIL
        if [ "$dt_says_present" -eq 1 ]; then
            log_fail "DT lists $FW but no remoteproc and ath11k not loaded"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 1
        fi
        log_skip "$TESTNAME SKIP – neither remoteproc nor ath11k path available"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
fi

# Firmware presence check (paths may vary, so just log)
if [ -d /lib/firmware/ath11k ]; then
    log_info "Found /lib/firmware/ath11k directory"
else
    log_warn "No /lib/firmware/ath11k directory found"
fi

# Dmesg scan for errors/success
scan_dmesg_errors "ath11k|wpss" "." "crash|timeout|fail" "fw_version|firmware"
# (Return codes from scan_dmesg_errors are informational; it logs itself)

# Net interface presence is informative
set -- /sys/class/net/wlan[0-9]* 2>/dev/null
if [ -e "$1" ]; then
    log_info "wlan interface present (ath11k up)"
else
    log_info "No wlan interface yet (maybe not brought up)"
fi

# Final result for driver path: PASS if we got here
log_pass "WPSS driver path checks passed"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
