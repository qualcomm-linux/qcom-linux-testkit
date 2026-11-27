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

TESTNAME="Video_Driver_Rebind_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

EXERCISE="0"
STREAMS=""
CODEC="h264"
FFMPEG="ffmpeg"
TIMEOUT="60"

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Verify hardware decode correctness after driver unbind and rebind.
  --exercise <value>  Explicit rebind opt-in on an isolated target
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
            --exercise)
                EXERCISE="$2"
                ;;
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


if [ "$EXERCISE" != 0 ] && [ "$EXERCISE" != 1 ]; then
    test_result_finish FAIL "--exercise must be 0 or 1"
fi
[ "$EXERCISE" = 1 ] || test_result_finish SKIP "Driver rebind requires --exercise 1 on an isolated target"

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

test_require_commands fuser id || test_run_finish
[ "$(id -u)" = 0 ] || test_run_finish SKIP "Driver lifecycle validation requires root"
if [ ! -w "$DRIVER/unbind" ] || [ ! -w "$DRIVER/bind" ]; then
    test_run_finish SKIP "Selected runtime driver does not expose writable bind controls"
fi
video_device_nodes "$DEVICE" >"$TEST_RUN_DIR/nodes-before.list" || test_run_finish FAIL "Cannot retain affected node inventory"
[ -s "$TEST_RUN_DIR/nodes-before.list" ] || test_run_finish FAIL "Baseline video nodes disappeared before unbind"
while IFS= read -r affected; do
    users=0
    test_run_command --stdout-only "users-${affected##*/}" fuser "$affected" || users=$?
    if [ "$users" = 0 ]; then
        test_run_finish SKIP "Device=$affected is in use, stop competing clients before isolated rebind validation"
    fi
    if [ "$users" != 1 ] || [ -s "$TEST_RUN_DIR/users-${affected##*/}.stderr.log" ]; then
        test_run_finish SKIP "Cannot prove device=$affected has no other users, inspect fuser diagnostics"
    fi
done <"$TEST_RUN_DIR/nodes-before.list"
if [ "$(readlink -f "$DEVICE/driver")" != "$DRIVER" ]; then
    test_run_finish FAIL "Driver identity changed before unbind"
fi
# shellcheck disable=SC2034 # Owned-state restoration callback uses these fields.
VIDEO_REBIND_DEVICE="$DEVICE"
# shellcheck disable=SC2034 # Owned-state restoration callback uses these fields.
VIDEO_REBIND_DRIVER="$DRIVER"
# shellcheck disable=SC2034 # Mark ownership before a write that may partially succeed.
VIDEO_REBIND_OWNED=1
# shellcheck disable=SC2034 # Shared lifecycle cleanup invokes the binding restorer.
TEST_RUN_CLEANUP=video_restore_driver_binding
# shellcheck disable=SC2034 # Preserve faults even during rescue binding.
TEST_RUN_CLEANUP_KERNEL_PATTERN='BUG:|WARNING:|Oops:|panic|Call trace:|(iris|venus|vidc).*(fail|error|timed out)'
# shellcheck disable=SC2016 # Positional arguments belong to the bounded child.
if ! test_run_command unbind sh -c 'printf "%s\n" "$1" >"$2/unbind"' sh "${DEVICE##*/}" "$DRIVER"; then
    test_run_finish FAIL "Driver unbind failed, cleanup will restore only the original binding"
fi
video_device_nodes "$DEVICE" >"$TEST_RUN_DIR/nodes-unbound.list" || test_run_finish FAIL "Cannot observe node teardown"
if [ -L "$DEVICE/driver" ] || [ -s "$TEST_RUN_DIR/nodes-unbound.list" ]; then
    test_run_finish FAIL "Driver or video nodes remained registered after unbind"
fi
if ! video_restore_driver_binding; then
    test_run_finish FAIL "Original driver binding did not return"
fi
started=$(get_monotonic_seconds)
while :; do
    video_device_nodes "$DEVICE" >"$TEST_RUN_DIR/nodes-restored.list" || test_run_finish FAIL "Cannot observe returned nodes"
    if [ "$(wc -l <"$TEST_RUN_DIR/nodes-restored.list")" -eq "$(wc -l <"$TEST_RUN_DIR/nodes-before.list")" ]; then
        break
    fi
    if [ "$(($(get_monotonic_seconds) - started))" -ge "$TIMEOUT" ]; then
        test_run_finish FAIL "Selected codec node inventory did not return within the deadline"
    fi
    sleep 1
done

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

test_capture_kernel_log lifecycle-after || test_run_finish FAIL "Kernel evidence became unavailable during lifecycle validation"
if ! test_check_kernel_delta lifecycle-before lifecycle-after \
    'BUG:|WARNING:|Oops:|panic|Call trace:|(iris|venus|vidc).*(fail|error|timed out)'; then
    test_result_record FAIL "Codec lifecycle kernel health is faulty or incomplete"
fi
test_run_finish
