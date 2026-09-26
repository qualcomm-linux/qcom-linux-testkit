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
. "$TOOLS/lib_pkg_provider.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_tflite_benchmark.sh"

TESTNAME="AI_ML_Tflite_Benchmark_QNNHTP_1_thread_yolov8_det_quantized.tflite"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

# usage
# Prints the fixed QNN HTP benchmark CLI contract without target changes.
usage() {
    tflite_benchmark_usage
}

# parse_args <suite-arguments...>
# Applies supported overrides and returns 2 for invalid CLI syntax.
parse_args() {
    tflite_benchmark_parse_args "$@"
}

tflite_benchmark_defaults qnn-htp || exit 2
parse_args "$@" || {
    usage >&2
    exit 2
}
tflite_benchmark_execute "$TESTNAME" "$RES_FILE" "$SCRIPT_DIR"
