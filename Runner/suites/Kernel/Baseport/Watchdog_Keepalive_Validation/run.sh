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

TESTNAME="Watchdog_Keepalive_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
# shellcheck disable=SC2034
CHECK_DEPS_RECOVER=0

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

# usage
# Print the supported options without changing hardware.
usage() {
    printf '%s\n' "Usage: $0 [--help]"
}

# parse_args <arguments...>
# Reject unsupported arguments before test setup.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *)
                test_result_finish FAIL "Unsupported option: $1"
                ;;
        esac
    done
}
parse_args "$@"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

deps_list="cat grep sed awk tr mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "watchdog"
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if ! isroot; then
    test_result_record "SKIP" "root is required to open /dev/watchdog"
    test_result_finish "SKIP"
fi

wd_dir=""
wd_dev=""
wd_seen=0
for wd_candidate in $(watchdog_sysfs_dirs); do
    wd_seen=1
    if ! wd_candidate_dev="$(watchdog_provider_node "$wd_candidate")"; then
        test_result_record "SKIP" "watchdog provider has no character device: $wd_candidate"
        continue
    fi
    if [ ! -c "$wd_candidate_dev" ] || [ ! -w "$wd_candidate_dev" ]; then
        test_result_record "SKIP" "$wd_candidate_dev is not a writable character device"
        continue
    fi
    wd_nowayout="$(kernel_attribute_value "$wd_candidate/nowayout")" || wd_nowayout=""
    if [ "$wd_nowayout" != "0" ]; then
        test_result_record "SKIP" "$wd_candidate nowayout is not a confirmed stoppable 0 (value='${wd_nowayout:-unreadable}')"
        continue
    fi
    wd_state="$(kernel_attribute_value "$wd_candidate/state")" || wd_state=""
    if [ "$wd_state" != "inactive" ]; then
        test_result_record "SKIP" "$wd_candidate state is '${wd_state:-unreadable}'; leaving it unchanged"
        continue
    fi
    wd_timeout="$(kernel_attribute_value "$wd_candidate/timeout")" || wd_timeout=""
    if ! is_unsigned_number "$wd_timeout" || [ "$wd_timeout" -lt 2 ]; then
        test_result_record "SKIP" "$wd_candidate timeout '${wd_timeout:-unreadable}' is too small to refresh once per second"
        continue
    fi
    wd_dir="$wd_candidate"
    wd_dev="$wd_candidate_dev"
done
if [ -z "$wd_dir" ]; then
    if [ "$wd_seen" -eq 0 ]; then
        test_result_record "SKIP" "No watchdog sysfs device found"
    else
        test_result_record "SKIP" "No inactive stoppable watchdog can be refreshed safely"
    fi
    test_result_finish "SKIP"
fi
log_info "Keepalive target $wd_dir $wd_dev"

release="$KERNEL_EVIDENCE_DIR/watchdog.release"
holder=""
rm -f "$release"
# Install magic-close before the device is opened. One-second pings stay
# inside a timeout of at least two seconds until the parent releases the hold.
watchdog_hold() {
    wd_opened=0
    watchdog_disarm() {
        [ "$wd_opened" = 1 ] || return 0
        printf 'V' >&3 2>/dev/null || true
        exec 3>&-
        wd_opened=0
    }
    trap watchdog_disarm EXIT INT TERM
    exec 3>"$1" || exit 1
    wd_opened=1
    while [ ! -f "$2" ]; do
        printf '1\n' >&3 || exit 1
        sleep 1
    done
    printf '1\n' >&3 || exit 1
}
watchdog_hold "$wd_dev" "$release" &
holder=$!
cleanup_watchdog() {
    touch "$release"
    if [ -n "$holder" ]; then
        wait "$holder" 2>/dev/null || true
        holder=""
    fi
}
trap cleanup_watchdog EXIT INT TERM
sleep 2
if ! kill -0 "$holder" 2>/dev/null; then
    wait "$holder"
    holder_rc=$?
    holder=""
    final_state="$(kernel_attribute_value "$wd_dir/state")" || final_state=""
    test_result_record "FAIL" "watchdog keepalive holder exited early rc=$holder_rc state='${final_state:-unreadable}'"
    test_result_finish "FAIL"
fi

touch "$release"
wait "$holder"
holder_rc=$?
holder=""
final_state="$(kernel_attribute_value "$wd_dir/state")" || final_state=""
if [ "$holder_rc" -ne 0 ] || [ "$final_state" != "inactive" ]; then
    test_result_record "FAIL" "watchdog did not return to inactive after magic-close rc=$holder_rc state='${final_state:-unreadable}'"
    test_result_finish "FAIL"
fi
test_result_record "PASS" "keepalive refreshed $wd_dev and magic-close returned it to inactive"

test_result_finish
