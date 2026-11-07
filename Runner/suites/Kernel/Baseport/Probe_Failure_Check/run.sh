#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Probe failure / deferred probe detector using kernel logs + devices_deferred

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

TESTNAME="Probe_Failure_Check"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat grep wc tr id cp sed date mktemp head; then
    test_result_finish SKIP "Probe inventory tools are absent from the image"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create probe diagnostics under CWD=$PWD"

scan_dmesg_errors "$OUT_DIR" '.*' \
    'dummy regulator|supply [^ ]+ not found|using dummy regulator' || true
LOG_FILE="$OUT_DIR/probe_failures.log"
: >"$LOG_FILE"
FAIL_PATTERN='(failed to (probe|instantiate)|'\
'probe of .* failed|probe with driver .* failed|deferred probe timeout, ignoring dependency|'\
'Direct firmware load .* failed|tplg firmware loading .* failed|ASoC error|'\
'unprobe failed|failed to remove .* driver|component bind error|component unbind error|'\
'Driver .* failed|cannot register device driver|register_component error|'\
'sound: ASoC: failed|load_firmware failed|request_firmware failed|device_add failed|'\
'platform device_add failed|Cannot register component|bind failed|'\
'lookup_component error|failed to add machine driver)'


if [ "${DMESG_ACCESS_STATUS:-unavailable}" = "available" ]; then
    grep -Ei "$FAIL_PATTERN" "$OUT_DIR/dmesg_snapshot.log" >"$LOG_FILE" || true
else
    test_result_record SKIP "Kernel probe log unavailable, inspect $OUT_DIR/dmesg_access.log"
fi

DEFERRED_FILE="/sys/kernel/debug/devices_deferred"
if [ -r "$DEFERRED_FILE" ]; then
    if ! cat "$DEFERRED_FILE" >"$OUT_DIR/devices_deferred.log"; then
        test_result_record FAIL "Cannot read the runtime deferred-probe list"
    elif [ -s "$OUT_DIR/devices_deferred.log" ]; then
        log_file_with_label DEFERRED-PROBE "$OUT_DIR/devices_deferred.log"
        test_result_record FAIL "DT devices still have unresolved probe suppliers, inspect $OUT_DIR/devices_deferred.log"
    fi
else
    log_info "Deferred-probe debugfs evidence is unavailable, retaining the kernel-log check"
fi
if [ -s "$LOG_FILE" ]; then
    log_file_with_label PROBE-ERROR "$LOG_FILE"
    test_result_record FAIL "Kernel probe or firmware-load errors detected, inspect $LOG_FILE and the image firmware/DT"
elif [ "${DMESG_ACCESS_STATUS:-unavailable}" = "available" ]; then
    test_result_record PASS "No probe, firmware or bind failure found in the captured kernel log"
fi
test_result_finish
