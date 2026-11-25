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
. "$TOOLS/lib_video.sh"

TESTNAME="Video_Runtime_PM_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

STREAMS=""
CODEC="h264"
FFMPEG="ffmpeg"
TIMEOUT="60"

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Verify hardware decode correctness after an observed runtime suspend and resume.
  --streams <value>  Directory containing a supported codec-* reference clip
  --codec <value>  One codec to validate, h264, hevc or vp9
  --ffmpeg <value>  Installed FFmpeg binary or path
  --timeout <value>  Per-operation and readiness deadline in seconds
EOF
}

# parse_args <arguments>...
# Parse explicit values before accessing runtime evidence.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_finish FAIL "Missing value for $1"
        fi
        case "$2" in
            --*)
                test_result_finish FAIL "Missing value for $1 before option=$2"
                ;;
        esac
        case "$1" in
            --streams)
                STREAMS="$2"
                ;;
            --codec)
                CODEC="$2"
                ;;
            --ffmpeg)
                FFMPEG="$2"
                ;;
            --timeout)
                TIMEOUT="$2"
                ;;
            *)
                test_result_finish FAIL "Unknown option=$1"
                ;;
        esac
        shift 2
    done
}

parse_args "$@"

# shellcheck disable=SC2034 # Read by the shared dependency helper.
CHECK_DEPS_RECOVER=0
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat awk grep sed tr uname mkdir mktemp date readlink wc; then
    test_result_finish SKIP "Required shell tools are absent, provision them in the image"
fi


if ! printf '%s\n' "$TIMEOUT" | grep -Eq '^[1-9][0-9]{0,2}$' || [ "$TIMEOUT" -gt 600 ]; then
    test_result_finish FAIL "--timeout must be between 1 and 600 seconds"
fi
case "$CODEC" in
    h264|hevc|vp9)
        ;;
    *)
        test_result_finish FAIL "Select one supported codec h264, hevc or vp9"
        ;;
esac
if [ -z "$STREAMS" ] || [ ! -d "$STREAMS" ]; then
    test_result_finish SKIP "Provide --streams with an image/job-provided codec reference clip"
fi
STREAMS=$(cd "$STREAMS" && pwd -P) || test_result_finish FAIL "Cannot resolve reference directory"
QUALITY_RUNNER="$TOOLS/../suites/Multimedia/Video/Video_Codec_Quality/run.sh"
if [ ! -r "$QUALITY_RUNNER" ] || ! command -v test_run_start >/dev/null 2>&1; then
    test_result_finish SKIP "The existing Video_Codec_Quality implementation is not integrated"
fi
QUALITY_RUNNER=$(readlink -f "$QUALITY_RUNNER") || test_result_finish FAIL "Cannot resolve quality runner"
test_require_commands "$FFMPEG" v4l2-ctl readlink find sort cmp sleep || test_result_finish
FFMPEG=$(command -v "$FFMPEG") || test_result_finish SKIP "Installed FFmpeg is unavailable"
FFMPEG=$(readlink -f "$FFMPEG") || test_result_finish FAIL "Cannot resolve installed FFmpeg"
test_run_start
# shellcheck disable=SC2034 # Consumed by shared bounded operations.
TEST_RUN_TIMEOUT="$TIMEOUT"
test_capture_kernel_log lifecycle-before || test_run_finish SKIP "Lifecycle validation requires readable kernel evidence"
quality_status=0
video_quality_run_child baseline "$QUALITY_RUNNER" "$FFMPEG" "$STREAMS" "$CODEC" "$TIMEOUT" || quality_status=$?
case "$quality_status" in
    77)
        test_run_finish SKIP "Baseline hardware decoding was not exercised, inspect child prerequisites"
        ;;
    0)
        ;;
    *)
        test_run_finish FAIL "Baseline decode quality failed, no lifecycle operation attempted"
        ;;
esac
node="$VIDEO_QUALITY_NODE"
DEVICE=$(video_bound_device "$node") || test_run_finish SKIP "Selected codec node has no runtime driver-bound device"
DRIVER=$(readlink -f "$DEVICE/driver") || test_run_finish FAIL "Cannot resolve selected codec driver"
log_info "Actual decoder=$node device=$DEVICE driver=$DRIVER"

if [ ! -r "$DEVICE/power/runtime_status" ] || [ ! -r "$DEVICE/power/runtime_active_time" ]; then
    test_run_finish SKIP "Selected decoder lacks runtime-PM accounting"
fi
if [ "$(cat "$DEVICE/power/control" 2>/dev/null)" != auto ]; then
    test_run_finish SKIP "Selected decoder is not configured for automatic runtime PM, policy left unchanged"
fi
started=$(get_monotonic_seconds)
: >"$TEST_RUN_DIR/runtime-status.log"
while :; do
    state=$(cat "$DEVICE/power/runtime_status") || test_run_finish FAIL "Runtime-PM status became unreadable"
    elapsed=$(($(get_monotonic_seconds) - started))
    printf '%s %s\n' "$elapsed" "$state" >>"$TEST_RUN_DIR/runtime-status.log"
    case "$state" in
        suspended)
            break
            ;;
        unsupported)
            test_run_finish SKIP "Selected decoder does not support runtime PM"
            ;;
        active|suspending|resuming)
            ;;
        *)
            test_run_finish FAIL "Unexpected runtime-PM state=$state"
            ;;
    esac
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        test_run_finish FAIL "Codec did not runtime-suspend within the configured deadline"
    fi
    sleep 1
done
active_before=$(cat "$DEVICE/power/runtime_active_time") || test_run_finish FAIL "Cannot capture runtime active accounting"

quality_status=0
video_quality_run_child recovered "$QUALITY_RUNNER" "$FFMPEG" "$STREAMS" "$CODEC" "$TIMEOUT" || quality_status=$?
if [ "$quality_status" -ne 0 ]; then
    test_result_record FAIL "Previously supported codec failed its post-lifecycle decode verification, status=$quality_status"
else
    restored_device=$(video_bound_device "$VIDEO_QUALITY_NODE") || restored_device=""
    if [ "$restored_device" != "$DEVICE" ] || [ "$(readlink -f "$DEVICE/driver")" != "$DRIVER" ]; then
        test_result_record FAIL "Post-lifecycle FFmpeg used another device or driver"
    else
        # shellcheck disable=SC2034 # Required by shared finalization.
        TEST_RUN_VALIDATED=1
        test_result_record PASS "The same codec device decoded every reference frame correctly after the lifecycle operation"
    fi
fi

active_after=$(cat "$DEVICE/power/runtime_active_time") || active_after=""
if ! awk -v before="$active_before" -v after="$active_after" 'BEGIN {exit !(before ~ /^[0-9]+$/ && after ~ /^[0-9]+$/ && after > before)}'; then
    test_result_record FAIL "Runtime active accounting did not advance during recovered decoding"
fi
printf 'before=%s after=%s\n' "$active_before" "$active_after" >"$TEST_RUN_DIR/runtime-active-time.log"

test_capture_kernel_log lifecycle-after || test_run_finish FAIL "Kernel evidence became unavailable during lifecycle validation"
if ! test_check_kernel_delta lifecycle-before lifecycle-after \
    'BUG:|WARNING:|Oops:|panic|Call trace:|(iris|venus|vidc).*(fail|error|timed out)'; then
    test_result_record FAIL "Codec lifecycle kernel health is faulty or incomplete"
fi
test_run_finish
