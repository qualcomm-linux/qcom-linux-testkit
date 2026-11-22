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

wd_dir="$(watchdog_sysfs_dirs | awk 'NR==1 { print; exit }')"
if [ -z "$wd_dir" ]; then
    test_result_record "SKIP" "No watchdog sysfs device found"
    test_result_finish "SKIP"
fi

if ! wd_dev="$(watchdog_provider_node "$wd_dir")"; then
    test_result_record "SKIP" "watchdog provider has no character device: $wd_dir"
    test_result_finish "SKIP"
fi
if [ ! -c "$wd_dev" ] || [ ! -w "$wd_dev" ]; then
    test_result_record "SKIP" "$wd_dev is not a writable character device"
    test_result_finish "SKIP"
fi

nowayout="$(kernel_attribute_value "$wd_dir/nowayout")" || nowayout=""
if [ "$nowayout" != "0" ]; then
    test_result_record "SKIP" "nowayout is not a confirmed stoppable 0 (value='${nowayout:-unreadable}')"
    test_result_finish "SKIP"
fi

initial_state="$(kernel_attribute_value "$wd_dir/state")" || initial_state=""
if [ "$initial_state" != "inactive" ]; then
    test_result_record "SKIP" "watchdog state is '${initial_state:-unreadable}'; leaving an active watchdog unchanged"
    test_result_finish "SKIP"
fi

release="$KERNEL_EVIDENCE_DIR/watchdog.release"
holder=""
rm -f "$release"
# Keep the device open until magic-close. A signal still writes V before close.
watchdog_hold() {
    exec 3>"$1" || exit 1
    printf '1\n' >&3 || exit 1
    trap 'printf "V" >&3; exec 3>&-' EXIT INT TERM
    while [ ! -f "$2" ]; do
        sleep 1
    done
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
sleep 1
if ! kill -0 "$holder" 2>/dev/null; then
    test_result_record "FAIL" "watchdog keepalive holder exited before magic-close"
    test_result_finish "FAIL"
fi

touch "$release"
wait "$holder"
holder_rc=$?
holder=""
final_state="$(kernel_attribute_value "$wd_dir/state")" || final_state=""
if [ "$holder_rc" -ne 0 ]; then
    test_result_record "FAIL" "watchdog magic-close holder failed rc=$holder_rc state='${final_state:-unreadable}'"
    test_result_finish "FAIL"
fi
if [ "$final_state" != "inactive" ]; then
    test_result_record "FAIL" "watchdog stayed armed after magic-close, state='${final_state:-unreadable}'"
    test_result_finish "FAIL"
fi
test_result_record "PASS" "keepalive armed $wd_dev and magic-close returned it to inactive"

test_result_finish
