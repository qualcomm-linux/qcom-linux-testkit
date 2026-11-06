#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# video_quality_hashes <framemd5-file> <output-file>
# Normalize and validate every frame, rejecting empty/truncated hash output.
video_quality_hashes() {
    awk -F ',' '
        /^#/ || /^[[:space:]]*$/ {next}
        {
            hash = $6
            gsub(/[[:space:]]/, "", hash)
            if (NF != 6 || length(hash) != 32 || hash ~ /[^0-9a-fA-F]/) bad = 1
            print tolower(hash)
            count++
        }
        END { exit bad || !count }
    ' "$1" >"$2"
}

# video_quality_hardware_evidence <log-file>
# Require the actual FFmpeg-selected V4L2 node to match runtime codec inventory.
video_quality_hardware_evidence() {
    local node nodes found=0
    nodes=$(sed -n 's/.*Using device \(\/dev\/video[0-9][0-9]*\).*/\1/p' "$1" | sort -u)
    while IFS= read -r node; do
        [ -n "$node" ] || continue
        if grep -qxF "$node" "$SCENARIO_DIR/codec-nodes.txt"; then
            found=1
        else
            return 1
        fi
    done <<EOF
$nodes
EOF
    [ "$found" = 1 ]
}

# video_quality_decode <codec> <stream> <iteration>
# Compare every hardware-decoded NV12 frame against an explicit software decode.
video_quality_decode() {
    local codec="$1" stream="$2" iteration="$3" label="decode-$1-$3" decoder fourcc
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
    if ! grep -q "'$fourcc'" "$SCENARIO_DIR/decode-formats.log"; then
        test_result_record SKIP "No runtime V4L2 codec advertises $codec compressed input"
        return 0
    fi
    if ! grep -Eq "[[:space:]]${codec}_v4l2m2m[[:space:]]" "$SCENARIO_DIR/decoders.log"; then
        test_result_record SKIP "Installed FFmpeg has no ${codec}_v4l2m2m decoder"
        return
    fi
    if [ ! -f "$SCENARIO_DIR/reference-$codec.hashes" ]; then
        if ! scenario_command "reference-$codec" "$SCENARIO_FFMPEG" -nostdin -y \
            -hide_banner -loglevel verbose -c:v "$decoder" -i "$stream" \
            "$SCENARIO_FPS_OPTION" "$SCENARIO_FPS_VALUE" -pix_fmt nv12 -f framemd5 "$SCENARIO_DIR/reference-$codec.md5" ||
           ! video_quality_hashes "$SCENARIO_DIR/reference-$codec.md5" "$SCENARIO_DIR/reference-$codec.hashes"; then
            test_result_record FAIL "Software reference decode failed or emitted invalid frame hashes: codec=$codec"
            return 1
        fi
    fi
    if ! scenario_command "$label" "$SCENARIO_FFMPEG" -nostdin -y -hide_banner \
        -loglevel verbose -c:v "${codec}_v4l2m2m" -i "$stream" "$SCENARIO_FPS_OPTION" "$SCENARIO_FPS_VALUE" \
        -pix_fmt nv12 -f framemd5 "$SCENARIO_DIR/$label.md5"; then
        test_result_record FAIL "Hardware decode failed: codec=$codec iteration=$iteration"
        return 1
    fi
    if ! video_quality_hardware_evidence "$SCENARIO_DIR/$label.log" ||
       ! video_quality_hashes "$SCENARIO_DIR/$label.md5" "$SCENARIO_DIR/$label.hashes"; then
        test_result_record FAIL "Hardware decode lacks matching V4L2 device or complete frame hashes: codec=$codec"
        return 1
    fi
    if cmp -s "$SCENARIO_DIR/reference-$codec.hashes" "$SCENARIO_DIR/$label.hashes"; then
        # shellcheck disable=SC2034 # Required by scenario_finish.
        SCENARIO_VALIDATED=1
        test_result_record PASS "codec=$codec iteration=$iteration all $(wc -l <"$SCENARIO_DIR/$label.hashes") decoded frames match software"
    else
        test_result_record FAIL "codec=$codec iteration=$iteration frame count or content differs from software reference"
    fi
}

# video_quality_encode <codec> <iteration>
# Verify hardware encoding, software-decodable frame count and PSNR quality.
video_quality_encode() {
    local codec="$1" iteration="$2" label="encode-$1-$2" output source psnr count fourcc
    case "$codec" in
        h264)
            fourcc=H264
            ;;
        hevc)
            fourcc=HEVC
            ;;
    esac
    if ! grep -q "'$fourcc'" "$SCENARIO_DIR/encode-formats.log"; then
        test_result_record SKIP "No runtime V4L2 codec advertises $codec compressed output"
        return 0
    fi
    if ! grep -Eq '[[:space:]]psnr[[:space:]]' "$SCENARIO_DIR/filters.log" ||
       ! grep -Eq '[[:space:]]testsrc2[[:space:]]' "$SCENARIO_DIR/filters.log"; then
        test_result_record SKIP "Installed FFmpeg lacks the quality-reference filters"
        return 0
    fi
    if ! grep -Eq "[[:space:]]${codec}_v4l2m2m[[:space:]]" "$SCENARIO_DIR/encoders.log"; then
        test_result_record SKIP "Installed FFmpeg has no ${codec}_v4l2m2m encoder"
        return
    fi
    output="$SCENARIO_DIR/$label.$codec"
    source="testsrc2=size=$SCENARIO_SIZE:rate=30"
    if ! scenario_command "$label" "$SCENARIO_FFMPEG" -nostdin -y -hide_banner \
        -loglevel verbose -f lavfi -i "$source" -frames:v "$SCENARIO_FRAMES" \
        -pix_fmt nv12 -c:v "${codec}_v4l2m2m" -b:v 4M -f "$codec" "$output"; then
        test_result_record FAIL "Hardware encode failed: codec=$codec iteration=$iteration"
        return 1
    fi
    if ! video_quality_hardware_evidence "$SCENARIO_DIR/$label.log" || [ ! -s "$output" ]; then
        test_result_record FAIL "Encode lacks a matching hardware device or nonempty output: codec=$codec"
        return 1
    fi
    if ! scenario_command "$label-decode" "$SCENARIO_FFMPEG" -nostdin -y \
        -hide_banner -loglevel verbose -c:v "$codec" -i "$output" "$SCENARIO_FPS_OPTION" "$SCENARIO_FPS_VALUE" \
        -f framemd5 "$SCENARIO_DIR/$label.md5" ||
       ! video_quality_hashes "$SCENARIO_DIR/$label.md5" "$SCENARIO_DIR/$label.hashes"; then
        test_result_record FAIL "Encoded output could not be fully decoded in software: codec=$codec"
        return 1
    fi
    count=$(wc -l <"$SCENARIO_DIR/$label.hashes")
    if ! scenario_command "$label-psnr" "$SCENARIO_FFMPEG" -nostdin -hide_banner \
        -loglevel info -r 30 -c:v "$codec" -i "$output" -f lavfi -i "$source" \
        -frames:v "$SCENARIO_FRAMES" \
        -lavfi '[0:v]format=yuv420p,setpts=PTS-STARTPTS[a];[1:v]format=yuv420p,setpts=PTS-STARTPTS[b];[a][b]psnr' \
        -f null -; then
        test_result_record FAIL "PSNR comparison failed: codec=$codec"
        return 1
    fi
    psnr=$(sed -n 's/.*PSNR.* average:\([^ ]*\).*/\1/p' "$SCENARIO_DIR/$label-psnr.log" | tail -n 1)
    if [ "$count" -eq "$SCENARIO_FRAMES" ] && awk -v psnr="$psnr" -v minimum="$SCENARIO_PSNR" \
        'BEGIN {exit !(psnr == "inf" || (psnr ~ /^[0-9]+([.][0-9]+)?$/ && psnr + 0 >= minimum))}'; then
        # shellcheck disable=SC2034 # Required by scenario_finish.
        SCENARIO_VALIDATED=1
        test_result_record PASS "codec=$codec iteration=$iteration encoded_frames=$count PSNR=$psnr dB"
    else
        test_result_record FAIL "codec=$codec encoded_frames=$count expected=$SCENARIO_FRAMES PSNR=${psnr:-missing} minimum=$SCENARIO_PSNR dB"
    fi
}

# video_quality_run
# Discover codec devices, then exercise image-supported decode/encode paths.
video_quality_run() {
    local node codec iteration stream capabilities
    scenario_require "$SCENARIO_FFMPEG" v4l2-ctl awk sort cmp || return 0
    : >"$SCENARIO_DIR/codec-nodes.txt"
    : >"$SCENARIO_DIR/decode-formats.log"
    : >"$SCENARIO_DIR/encode-formats.log"
    for node in /sys/class/video4linux/video*; do
        [ -c "/dev/${node##*/}" ] || continue
        if scenario_command "capabilities-${node##*/}" v4l2-ctl -d "/dev/${node##*/}" --all; then
            capabilities="$SCENARIO_DIR/capabilities-${node##*/}.log"
            if grep -Eq 'Video Memory-to-Memory' "$capabilities"; then
                printf '%s\n' "/dev/${node##*/}" >>"$SCENARIO_DIR/codec-nodes.txt"
                if scenario_command "output-formats-${node##*/}" v4l2-ctl -d "/dev/${node##*/}" --list-formats-out; then
                    cat "$SCENARIO_DIR/output-formats-${node##*/}.log" >>"$SCENARIO_DIR/decode-formats.log"
                fi
                if scenario_command "capture-formats-${node##*/}" v4l2-ctl -d "/dev/${node##*/}" --list-formats; then
                    cat "$SCENARIO_DIR/capture-formats-${node##*/}.log" >>"$SCENARIO_DIR/encode-formats.log"
                fi
            fi
        fi
    done
    if [ ! -s "$SCENARIO_DIR/codec-nodes.txt" ]; then
        test_result_record SKIP "No accessible runtime V4L2 memory-to-memory codec device"
        return
    fi
    # Existing stack discovery is diagnostic only, never switch modules here.
    video_runtime_stack_status >"$SCENARIO_DIR/runtime-stack.txt" || true
    scenario_command decoders "$SCENARIO_FFMPEG" -hide_banner -decoders || return 1
    scenario_command encoders "$SCENARIO_FFMPEG" -hide_banner -encoders || return 1
    scenario_command filters "$SCENARIO_FFMPEG" -hide_banner -filters || return 1
    scenario_command ffmpeg-help "$SCENARIO_FFMPEG" -hide_banner -h full || return 1
    if grep -q -- '-fps_mode' "$SCENARIO_DIR/ffmpeg-help.log"; then
        SCENARIO_FPS_OPTION=-fps_mode
        SCENARIO_FPS_VALUE=passthrough
    else
        SCENARIO_FPS_OPTION=-vsync
        SCENARIO_FPS_VALUE=0
    fi
    scenario_capture_kernel kernel-before || true
    for codec in $(printf '%s\n' "$SCENARIO_CODECS" | tr ',' ' '); do
        iteration=1
        while [ "$iteration" -le "$SCENARIO_ROUNDS" ]; do
            if [ "$SCENARIO_MODE" != encode ]; then
                stream=""
                for stream in "$SCENARIO_STREAMS/$codec"-*; do
                    case "$stream" in
                        *.md5|*.hashes)
                            continue
                            ;;
                    esac
                    [ -f "$stream" ] && break
                done
                if [ -f "$stream" ]; then
                    video_quality_decode "$codec" "$stream" "$iteration" || true
                else
                    test_result_record SKIP "codec=$codec has no image/job-provided $codec-* clip under $SCENARIO_STREAMS"
                fi
            fi
            if [ "$SCENARIO_MODE" != decode ]; then
                case "$codec" in
                    h264|hevc)
                        video_quality_encode "$codec" "$iteration" || true
                        ;;
                    *)
                        test_result_record SKIP "codec=$codec encoder is not selected by this elementary-stream quality scenario"
                        ;;
                esac
            fi
            iteration=$((iteration + 1))
        done
    done
    scenario_capture_kernel kernel-after || true
    scenario_kernel_delta kernel-before kernel-after \
        'BUG:|WARNING:|Oops:|panic|Call trace:|(iris|venus|vidc).*(fail|error|timed out)' || true
}
