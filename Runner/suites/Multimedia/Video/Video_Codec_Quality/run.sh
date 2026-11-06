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
. "$TOOLS/lib_scenario.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_video.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_video_quality.sh"

TESTNAME="Video_Codec_Quality"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

SCENARIO_TIMEOUT="60"
SCENARIO_FFMPEG="ffmpeg"
SCENARIO_STREAMS="."
SCENARIO_CODECS="h264,hevc,vp9"
SCENARIO_MODE="decode"
SCENARIO_ROUNDS="2"
SCENARIO_SIZE="320x240"
SCENARIO_FRAMES="60"
SCENARIO_PSNR="30"

# usage
# Show the suite options and safe defaults.
usage() {
    cat <<EOF
Usage: $0 [options]
Hardware decode reference-frame equality and encode frame-count/PSNR correctness across repeat runs.
  --timeout <value> (default: 60)
  --ffmpeg <value> (default: ffmpeg)
  --streams <value> (default: .)
  --codecs <value> (default: h264,hevc,vp9)
  --mode <value> (default: decode)
  --rounds <value> (default: 2)
  --size <value> (default: 320x240)
  --frames <value> (default: 60)
  --min-psnr <value> (default: 30)
  --help
EOF
}

# parse_args <arguments>...
# Reject malformed overrides before runtime discovery or state changes.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_record FAIL "Missing value for $1"
            test_result_finish
        fi
        case "$2" in
            --*)
                test_result_record FAIL "Missing value for $1 before option=$2"
                test_result_finish
                ;;
        esac
        case "$1" in
            --timeout)
                SCENARIO_TIMEOUT="$2"
                ;;
            --ffmpeg)
                SCENARIO_FFMPEG="$2"
                ;;
            --streams)
                SCENARIO_STREAMS="$2"
                ;;
            --codecs)
                SCENARIO_CODECS="$2"
                ;;
            --mode)
                SCENARIO_MODE="$2"
                ;;
            --rounds)
                SCENARIO_ROUNDS="$2"
                ;;
            --size)
                SCENARIO_SIZE="$2"
                ;;
            --frames)
                SCENARIO_FRAMES="$2"
                ;;
            --min-psnr)
                SCENARIO_PSNR="$2"
                ;;
            *)
                test_result_record FAIL "Unknown option: $1"
                test_result_finish
                ;;
        esac
        shift 2
    done
    if ! {
        scenario_positive_integer "$SCENARIO_TIMEOUT" 600
    }; then
        test_result_record FAIL "Invalid value for --timeout: $SCENARIO_TIMEOUT"
        test_result_finish
    fi
    if ! {
        printf '%s\n' "$SCENARIO_CODECS" | awk '/^(h264|hevc|vp9)(,(h264|hevc|vp9))*$/ {ok=1} END {exit !ok}'
    }; then
        test_result_record FAIL "Invalid value for --codecs: $SCENARIO_CODECS"
        test_result_finish
    fi
    if ! {
        [ "$SCENARIO_MODE" = decode ] || [ "$SCENARIO_MODE" = encode ] || [ "$SCENARIO_MODE" = both ]
    }; then
        test_result_record FAIL "Invalid value for --mode: $SCENARIO_MODE"
        test_result_finish
    fi
    if ! {
        scenario_positive_integer "$SCENARIO_ROUNDS" 10
    }; then
        test_result_record FAIL "Invalid value for --rounds: $SCENARIO_ROUNDS"
        test_result_finish
    fi
    if ! {
        printf '%s\n' "$SCENARIO_SIZE" | awk -F x '/^[0-9]+x[0-9]+$/ && $1 >= 16 && $2 >= 16 && $1 <= 8192 && $2 <= 8192 && $1 % 2 == 0 && $2 % 2 == 0 {ok=1} END {exit !ok}'
    }; then
        test_result_record FAIL "Invalid value for --size: $SCENARIO_SIZE"
        test_result_finish
    fi
    if ! {
        scenario_positive_integer "$SCENARIO_FRAMES" 600
    }; then
        test_result_record FAIL "Invalid value for --frames: $SCENARIO_FRAMES"
        test_result_finish
    fi
    if ! {
        scenario_positive_integer "$SCENARIO_PSNR" 100
    }; then
        test_result_record FAIL "Invalid value for --min-psnr: $SCENARIO_PSNR"
        test_result_finish
    fi
}

parse_args "$@"
scenario_start
log_info "[OPTIONS] --ffmpeg=$SCENARIO_FFMPEG"
log_info "[OPTIONS] --streams=$SCENARIO_STREAMS"
if ! video_quality_run; then
    test_result_record FAIL "Scenario could not complete, inspect artifacts=$SCENARIO_DIR"
fi
scenario_finish
