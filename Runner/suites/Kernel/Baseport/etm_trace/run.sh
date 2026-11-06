#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc.
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
. "$TOOLS/coresight_common.sh"

TESTNAME="etm_trace"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

# usage
# Describe the automatic route selection.
usage() {
    echo "Usage: $0 [--help], automatically captures one available CPU trace route"
}

# parse_args <arguments...>
# Reject unknown options before touching CoreSight controls.
parse_args() {
    case "${1:-}" in
        --help|-h)
            usage
            exit 0
            ;;
        "")
            ;;
        *)
            test_result_finish FAIL "Unknown CoreSight option: $1"
            ;;
    esac
}
parse_args "$@"
command -v taskset >/dev/null 2>&1 || test_result_finish SKIP "taskset absent, cannot exercise the selected CPU trace source"
[ -d /sys/bus/coresight/devices ] || test_result_finish SKIP "No runtime CoreSight bus, image/DT must expose a CPU source and capture sink"
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || test_result_finish FAIL "Cannot create evidence directory in $PWD"
trap 'test_result_finish FAIL "CoreSight interrupted, inspect restoration evidence in $OUT_DIR"' HUP INT TERM
coresight_capture /sys/bus/coresight/devices /dev "$OUT_DIR" >"$OUT_DIR/capture.log" 2>&1
capture_rc=$?
cat "$OUT_DIR/capture.log"
case "$capture_rc" in
    0)
        test_result_record PASS "Fresh CoreSight trace captured and controls restored, $OUT_DIR"
        ;;
    4)
        test_result_record SKIP "No available idle CPU trace route, see $OUT_DIR/capture.log"
        ;;
    *)
        test_result_record FAIL "CoreSight capture or restoration failed, see $OUT_DIR/capture.log"
        ;;
esac
test_result_finish
