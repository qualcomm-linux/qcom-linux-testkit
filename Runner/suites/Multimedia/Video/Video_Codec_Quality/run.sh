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

TESTNAME="Video_Codec_Quality"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

TEST_RUN_TIMEOUT="60"
TEST_RUN_FFMPEG="ffmpeg"
TEST_RUN_STREAMS="."
TEST_RUN_CODECS="h264,hevc,vp9"
TEST_RUN_MODE="decode"
TEST_RUN_ROUNDS="2"
TEST_RUN_SIZE="320x240"
TEST_RUN_FRAMES="60"
TEST_RUN_PSNR="30"

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
                TEST_RUN_TIMEOUT="$2"
                ;;
            --ffmpeg)
                TEST_RUN_FFMPEG="$2"
                ;;
            --streams)
                TEST_RUN_STREAMS="$2"
                ;;
            --codecs)
                TEST_RUN_CODECS="$2"
                ;;
            --mode)
                TEST_RUN_MODE="$2"
                ;;
            --rounds)
                TEST_RUN_ROUNDS="$2"
                ;;
            --size)
                TEST_RUN_SIZE="$2"
                ;;
            --frames)
                TEST_RUN_FRAMES="$2"
                ;;
            --min-psnr)
                TEST_RUN_PSNR="$2"
                ;;
            *)
                test_result_record FAIL "Unknown option: $1"
                test_result_finish
                ;;
        esac
        shift 2
    done
    if ! {
        is_bounded_positive_integer "$TEST_RUN_TIMEOUT" 600
    }; then
        test_result_record FAIL "Invalid value for --timeout: $TEST_RUN_TIMEOUT"
        test_result_finish
    fi
    if ! {
        printf '%s\n' "$TEST_RUN_CODECS" | awk '/^(h264|hevc|vp9)(,(h264|hevc|vp9))*$/ {ok=1} END {exit !ok}'
    }; then
        test_result_record FAIL "Invalid value for --codecs: $TEST_RUN_CODECS"
        test_result_finish
    fi
    if ! {
        [ "$TEST_RUN_MODE" = decode ] || [ "$TEST_RUN_MODE" = encode ] || [ "$TEST_RUN_MODE" = both ]
    }; then
        test_result_record FAIL "Invalid value for --mode: $TEST_RUN_MODE"
        test_result_finish
    fi
    if ! {
        is_bounded_positive_integer "$TEST_RUN_ROUNDS" 10
    }; then
        test_result_record FAIL "Invalid value for --rounds: $TEST_RUN_ROUNDS"
        test_result_finish
    fi
    if ! {
        printf '%s\n' "$TEST_RUN_SIZE" | awk -F x '/^[0-9]+x[0-9]+$/ && $1 >= 16 && $2 >= 16 && $1 <= 8192 && $2 <= 8192 && $1 % 2 == 0 && $2 % 2 == 0 {ok=1} END {exit !ok}'
    }; then
        test_result_record FAIL "Invalid value for --size: $TEST_RUN_SIZE"
        test_result_finish
    fi
    if ! {
        is_bounded_positive_integer "$TEST_RUN_FRAMES" 600
    }; then
        test_result_record FAIL "Invalid value for --frames: $TEST_RUN_FRAMES"
        test_result_finish
    fi
    if ! {
        is_bounded_positive_integer "$TEST_RUN_PSNR" 100
    }; then
        test_result_record FAIL "Invalid value for --min-psnr: $TEST_RUN_PSNR"
        test_result_finish
    fi
}

parse_args "$@"
test_run_start
log_info "[OPTIONS] --ffmpeg=$TEST_RUN_FFMPEG"
log_info "[OPTIONS] --streams=$TEST_RUN_STREAMS"

# ---------- Codec discovery and validation ----------
test_require_commands "$TEST_RUN_FFMPEG" v4l2-ctl awk sort cmp || test_run_finish
: >"$TEST_RUN_DIR/codec-nodes.txt"
: >"$TEST_RUN_DIR/decode-formats.log"
: >"$TEST_RUN_DIR/encode-formats.log"
for node in /sys/class/video4linux/video*; do
    [ -c "/dev/${node##*/}" ] || continue
    if test_run_command "capabilities-${node##*/}" v4l2-ctl -d "/dev/${node##*/}" --all; then
        capabilities="$TEST_RUN_DIR/capabilities-${node##*/}.log"
        if grep -Eq 'Video Memory-to-Memory' "$capabilities"; then
            printf '%s\n' "/dev/${node##*/}" >>"$TEST_RUN_DIR/codec-nodes.txt"
            if test_run_command "output-formats-${node##*/}" v4l2-ctl -d "/dev/${node##*/}" --list-formats-out; then
                cat "$TEST_RUN_DIR/output-formats-${node##*/}.log" >>"$TEST_RUN_DIR/decode-formats.log"
            fi
            if test_run_command "capture-formats-${node##*/}" v4l2-ctl -d "/dev/${node##*/}" --list-formats; then
                cat "$TEST_RUN_DIR/capture-formats-${node##*/}.log" >>"$TEST_RUN_DIR/encode-formats.log"
            fi
        fi
    fi
done
if [ ! -s "$TEST_RUN_DIR/codec-nodes.txt" ]; then
    test_result_record SKIP "No accessible runtime V4L2 memory-to-memory codec device"
    test_run_finish
fi
# Existing stack discovery is diagnostic only, never switch modules here.
video_runtime_stack_status >"$TEST_RUN_DIR/runtime-stack.txt" || true
test_run_command decoders "$TEST_RUN_FFMPEG" -hide_banner -decoders || test_run_finish FAIL "Codec discovery could not complete, inspect artifacts=$TEST_RUN_DIR"
test_run_command encoders "$TEST_RUN_FFMPEG" -hide_banner -encoders || test_run_finish FAIL "Codec discovery could not complete, inspect artifacts=$TEST_RUN_DIR"
test_run_command filters "$TEST_RUN_FFMPEG" -hide_banner -filters || test_run_finish FAIL "Codec discovery could not complete, inspect artifacts=$TEST_RUN_DIR"
test_run_command ffmpeg-help "$TEST_RUN_FFMPEG" -hide_banner -h full || test_run_finish FAIL "Codec discovery could not complete, inspect artifacts=$TEST_RUN_DIR"
if grep -q -- '-fps_mode' "$TEST_RUN_DIR/ffmpeg-help.log"; then
    TEST_RUN_FPS_OPTION=-fps_mode
    TEST_RUN_FPS_VALUE=passthrough
else
    TEST_RUN_FPS_OPTION=-vsync
    TEST_RUN_FPS_VALUE=0
fi
test_capture_kernel_log kernel-before || true
for codec in $(printf '%s\n' "$TEST_RUN_CODECS" | tr ',' ' '); do
    iteration=1
    while [ "$iteration" -le "$TEST_RUN_ROUNDS" ]; do
        for operation in decode encode; do
            if [ "$TEST_RUN_MODE" != both ] && [ "$TEST_RUN_MODE" != "$operation" ]; then
                continue
            fi
            if [ "$operation" = decode ]; then
                stream=""
                for stream in "$TEST_RUN_STREAMS/$codec"-*; do
                    case "$stream" in
                        *.md5|*.hashes)
                            continue
                            ;;
                    esac
                    [ -f "$stream" ] && break
                done
                if [ ! -f "$stream" ]; then
                    test_result_record SKIP "codec=$codec has no image/job-provided $codec-* clip under $TEST_RUN_STREAMS"
                    continue
                fi
                label="decode-$codec-$iteration"
                decoder="$codec"
                case "$codec" in
                    h264)
                        fourcc=H264
                        ;;
                    hevc)
                        fourcc=HEVC
                        ;;
                    vp9)
                        fourcc=VP90
                        ;;
                esac
                if ! grep -q "'$fourcc'" "$TEST_RUN_DIR/decode-formats.log"; then
                    test_result_record SKIP "No runtime V4L2 codec advertises $codec compressed input"
                    continue
                fi
                if ! grep -Eq "[[:space:]]${codec}_v4l2m2m[[:space:]]" "$TEST_RUN_DIR/decoders.log"; then
                    test_result_record SKIP "Installed FFmpeg has no ${codec}_v4l2m2m decoder"
                    continue
                fi
                if [ ! -f "$TEST_RUN_DIR/reference-$codec.hashes" ]; then
                    if ! test_run_command "reference-$codec" "$TEST_RUN_FFMPEG" -nostdin -y \
                        -hide_banner -loglevel verbose -c:v "$decoder" -i "$stream" \
                        "$TEST_RUN_FPS_OPTION" "$TEST_RUN_FPS_VALUE" -pix_fmt nv12 -f framemd5 "$TEST_RUN_DIR/reference-$codec.md5" ||
                       ! video_quality_hashes "$TEST_RUN_DIR/reference-$codec.md5" "$TEST_RUN_DIR/reference-$codec.hashes"; then
                        test_result_record FAIL "Software reference decode failed or emitted invalid frame hashes: codec=$codec"
                        continue
                    fi
                fi
                if ! test_run_command "$label" "$TEST_RUN_FFMPEG" -nostdin -y -hide_banner \
                    -loglevel verbose -c:v "${codec}_v4l2m2m" -i "$stream" "$TEST_RUN_FPS_OPTION" "$TEST_RUN_FPS_VALUE" \
                    -pix_fmt nv12 -f framemd5 "$TEST_RUN_DIR/$label.md5"; then
                    test_result_record FAIL "Hardware decode failed: codec=$codec iteration=$iteration"
                    continue
                fi
                if ! video_quality_hardware_evidence "$TEST_RUN_DIR/$label.log" "$TEST_RUN_DIR/codec-nodes.txt" ||
                   ! video_quality_hashes "$TEST_RUN_DIR/$label.md5" "$TEST_RUN_DIR/$label.hashes"; then
                    test_result_record FAIL "Hardware decode lacks matching V4L2 device or complete frame hashes: codec=$codec"
                    continue
                fi
                if cmp -s "$TEST_RUN_DIR/reference-$codec.hashes" "$TEST_RUN_DIR/$label.hashes"; then
                    # shellcheck disable=SC2034 # Required by test_run_finish.
                    TEST_RUN_VALIDATED=1
                    test_result_record PASS "codec=$codec iteration=$iteration all $(wc -l <"$TEST_RUN_DIR/$label.hashes") decoded frames match software"
                else
                    test_result_record FAIL "codec=$codec iteration=$iteration frame count or content differs from software reference"
                fi
            else
                case "$codec" in
                    h264|hevc)
                        ;;
                    *)
                        test_result_record SKIP "codec=$codec encoder is outside the selected elementary-stream quality checks"
                        continue
                        ;;
                esac
                label="encode-$codec-$iteration"
                case "$codec" in
                    h264)
                        fourcc=H264
                        ;;
                    hevc)
                        fourcc=HEVC
                        ;;
                esac
                if ! grep -q "'$fourcc'" "$TEST_RUN_DIR/encode-formats.log"; then
                    test_result_record SKIP "No runtime V4L2 codec advertises $codec compressed output"
                    continue
                fi
                if ! grep -Eq '[[:space:]]psnr[[:space:]]' "$TEST_RUN_DIR/filters.log" ||
                   ! grep -Eq '[[:space:]]testsrc2[[:space:]]' "$TEST_RUN_DIR/filters.log"; then
                    test_result_record SKIP "Installed FFmpeg lacks the quality-reference filters"
                    continue
                fi
                if ! grep -Eq "[[:space:]]${codec}_v4l2m2m[[:space:]]" "$TEST_RUN_DIR/encoders.log"; then
                    test_result_record SKIP "Installed FFmpeg has no ${codec}_v4l2m2m encoder"
                    continue
                fi
                output="$TEST_RUN_DIR/$label.$codec"
                source="testsrc2=size=$TEST_RUN_SIZE:rate=30"
                if ! test_run_command "$label" "$TEST_RUN_FFMPEG" -nostdin -y -hide_banner \
                    -loglevel verbose -f lavfi -i "$source" -frames:v "$TEST_RUN_FRAMES" \
                    -pix_fmt nv12 -c:v "${codec}_v4l2m2m" -b:v 4M -f "$codec" "$output"; then
                    test_result_record FAIL "Hardware encode failed: codec=$codec iteration=$iteration"
                    continue
                fi
                if ! video_quality_hardware_evidence "$TEST_RUN_DIR/$label.log" "$TEST_RUN_DIR/codec-nodes.txt" || [ ! -s "$output" ]; then
                    test_result_record FAIL "Encode lacks a matching hardware device or nonempty output: codec=$codec"
                    continue
                fi
                if ! test_run_command "$label-decode" "$TEST_RUN_FFMPEG" -nostdin -y \
                    -hide_banner -loglevel verbose -c:v "$codec" -i "$output" "$TEST_RUN_FPS_OPTION" "$TEST_RUN_FPS_VALUE" \
                    -f framemd5 "$TEST_RUN_DIR/$label.md5" ||
                   ! video_quality_hashes "$TEST_RUN_DIR/$label.md5" "$TEST_RUN_DIR/$label.hashes"; then
                    test_result_record FAIL "Encoded output could not be fully decoded in software: codec=$codec"
                    continue
                fi
                count=$(wc -l <"$TEST_RUN_DIR/$label.hashes")
                if ! test_run_command "$label-psnr" "$TEST_RUN_FFMPEG" -nostdin -hide_banner \
                    -loglevel info -r 30 -c:v "$codec" -i "$output" -f lavfi -i "$source" \
                    -frames:v "$TEST_RUN_FRAMES" \
                    -lavfi '[0:v]format=yuv420p,setpts=PTS-STARTPTS[a];[1:v]format=yuv420p,setpts=PTS-STARTPTS[b];[a][b]psnr' \
                    -f null -; then
                    test_result_record FAIL "PSNR comparison failed: codec=$codec"
                    continue
                fi
                psnr=$(sed -n 's/.*PSNR.* average:\([^ ]*\).*/\1/p' "$TEST_RUN_DIR/$label-psnr.log" | tail -n 1)
                if [ "$count" -eq "$TEST_RUN_FRAMES" ] && awk -v psnr="$psnr" -v minimum="$TEST_RUN_PSNR" \
                    'BEGIN {exit !(psnr == "inf" || (psnr ~ /^[0-9]+([.][0-9]+)?$/ && psnr + 0 >= minimum))}'; then
                    # shellcheck disable=SC2034 # Required by test_run_finish.
                    TEST_RUN_VALIDATED=1
                    test_result_record PASS "codec=$codec iteration=$iteration encoded_frames=$count PSNR=$psnr dB"
                else
                    test_result_record FAIL "codec=$codec encoded_frames=$count expected=$TEST_RUN_FRAMES PSNR=${psnr:-missing} minimum=$TEST_RUN_PSNR dB"
                fi
            fi
        done
        iteration=$((iteration + 1))
    done
done
test_capture_kernel_log kernel-after || true
test_check_kernel_delta kernel-before kernel-after \
    'BUG:|WARNING:|Oops:|panic|Call trace:|(iris|venus|vidc).*(fail|error|timed out)' || true
test_run_finish
