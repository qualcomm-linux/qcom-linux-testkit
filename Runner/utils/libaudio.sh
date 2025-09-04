#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

if [ -z "$TOOLS" ]; then
    TOOLS="$(cd "$(dirname "$0")" && pwd)"
fi

. "$TOOLS/functestlib.sh"

init_audio_env() {
    TESTNAME="$1"
    AUDIO_BACKEND="$2"
    export TESTNAME
    export AUDIO_BACKEND

    if [ "$TESTNAME" = "AudioRecord" ]; then
        export AUDIO_RECORD_DEVICE="regular0"
    else
        export AUDIO_PLAYBACK_DEVICE="low-latency0"
    fi
	
    export PLAYBACK_CLIP="AudioClips/yesterday_48KHz.wav"
    export LOGDIR="results/${TESTNAME}"
    export RESULT_FILE="${TESTNAME}.res"
	
	export RECORD_FILE="${RECORD_FILE:-/tmp/rec.wav}"
	export RECORD_TIMEOUT="${RECORD_TIMEOUT:-15s}"
	export PLAYBACK_TIMEOUT="${PLAYBACK_TIMEOUT:-15s}"
    export RECORD_LOOPS="${RECORD_LOOPS:-1}"
    export PLAYBACK_LOOPS="${PLAYBACK_LOOPS:-1}"
	
	if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
		export PLAYBACK_VOLUME="${PLAYBACK_VOLUME:-65536}"
	elif [ "$AUDIO_BACKEND" = "pipewire" ]; then
		export PLAYBACK_VOLUME="${PLAYBACK_VOLUME:-1.0}"
	fi

    mkdir -p "$LOGDIR"
    chmod -R 777 "$LOGDIR"
}

validate_file_exists() {
    file="$1"
    if [ ! -s "$file" ]; then
        log_fail "File missing or empty: $file"
        return 1
    fi
    return 0
}

execute_with_timeout() {
    timeout_val="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_val" "$@"
    else
        run_with_timeout "$timeout_val" "$@"
    fi
    return $?
}

check_audio_daemon() {
    if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
        pgrep pulseaudio >/dev/null || pgrep pipewire-pulse >/dev/null || \
        log_skip_exit "$TESTNAME" "PulseAudio or pipewire-pulse not running"
    elif [ "$AUDIO_BACKEND" = "pipewire" ]; then
        pgrep pipewire >/dev/null || log_skip_exit "$TESTNAME" "PipeWire not running"
    fi
}

select_pipewire_source() {
    SOURCE_ID=$(wpctl status | grep -i -E "pal source handset mic|Built-in Audio internal Mic" | sed -n 's/^[^0-9]*\([0-9]\+\)\..*/\1/p' | head -n 1)
    if echo "$SOURCE_ID" | grep -qE '^[0-9]+$'; then
        log_info "Detected PipeWire source ID: $SOURCE_ID"
        wpctl set-default "$SOURCE_ID"
    else
        log_warn "No valid PipeWire source ID found"
    fi
}

setup_record_command() {
    if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
        echo "parec --rate=48000 --format=s16le --channels=1 --file-format=wav \"$RECORD_FILE\" -d \"$AUDIO_RECORD_DEVICE\""
    elif [ "$AUDIO_BACKEND" = "pipewire" ]; then
        echo "pw-record \"$RECORD_FILE\" -v"
    fi
}

setup_playback_command() {
    if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
        echo "paplay --volume=$PLAYBACK_VOLUME \"$PLAYBACK_CLIP\" -d \"$AUDIO_PLAYBACK_DEVICE\""
    elif [ "$AUDIO_BACKEND" = "pipewire" ]; then
        echo "pw-play --volume=$PLAYBACK_VOLUME \"$PLAYBACK_CLIP\""
    fi
}

audio_download_clip() {
    TAR_URL="https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/Pulse-Audio-Files-v1.0/AudioClips.tar.gz"
    if [ ! -f "$PLAYBACK_CLIP" ]; then
        log_info "Audio clip not found, downloading..."
        extract_tar_from_url "$TAR_URL" || {
            log_fail "Failed to fetch/extract playback audio tarball"
            echo "$TESTNAME FAIL" > "$RESULT_FILE"
            exit 1
        }
    fi
    validate_file_exists "$PLAYBACK_CLIP" || {
        log_fail "Playback clip $PLAYBACK_CLIP not found after extraction."
        echo "$TESTNAME FAIL" > "$RESULT_FILE"
        exit 1
    }
    log_info "Playback clip present: $PLAYBACK_CLIP"
}

audio_playback() {
    check_audio_daemon
    check_dependencies "$([ "$AUDIO_BACKEND" = "pulseaudio" ] && echo "paplay" || echo "pw-play")" pgrep grep
    audio_download_clip

    get_kernel_log > "$LOGDIR/dmesg_before.log"
    PLAY_CMD=$(setup_playback_command)
    PLAY_SUCCESS=0

    for i in $(seq 1 "$PLAYBACK_LOOPS"); do
        log_info "Playback loop $i of $PLAYBACK_LOOPS"
        execute_with_timeout "$PLAYBACK_TIMEOUT" sh -c "$PLAY_CMD" >> "$LOGDIR/playback_stdout.log" 2>&1
        ret=$?
        if [ "$ret" -eq 0 ]; then
			log_pass "Playback loop $i: Completed successfully (ret=0)"
		elif [ "$ret" -eq 1 ] && [ "$AUDIO_BACKEND" = "pipewire" ]; then
			log_warn "Playback loop $i: Interrupted/timed out for PipeWire (ret=1)"
		elif [ "$ret" -eq 124 ]; then
			log_warn "Playback loop $i: Timed out (ret=124)"
		else
			log_fail "Playback loop $i: Failed with error code $ret"
			# shellcheck disable=SC2034
			PLAYBACK_SUCCESS=1
			break  # Early exit on first true failure
		fi
    done

    get_kernel_log > "$LOGDIR/dmesg_after.log"
    scan_dmesg_errors "audio" "$LOGDIR"

    if [ "$PLAY_SUCCESS" -eq 0 ]; then
        log_pass_exit "$TESTNAME" "Audio playback test completed successfully"
        echo "$TESTNAME PASS" > "$RESULT_FILE"
    else
        log_fail_exit "$TESTNAME" "Audio playback test failed"
        echo "$TESTNAME FAIL" > "$RESULT_FILE"
    fi

}

audio_record() {
    check_audio_daemon
    if [ "$AUDIO_BACKEND" = "pipewire" ]; then
        select_pipewire_source
    fi
    check_dependencies "$([ "$AUDIO_BACKEND" = "pulseaudio" ] && echo "parec" || echo "pw-record")" pgrep grep

    get_kernel_log > "$LOGDIR/dmesg_before.log"
    rm -f "$RECORD_FILE"
    RECORD_CMD=$(setup_record_command)
    RECORD_SUCCESS=0

    for i in $(seq 1 "$RECORD_LOOPS"); do
        log_info "Recording loop $i of $RECORD_LOOPS"
        execute_with_timeout "$RECORD_TIMEOUT" sh -c "$RECORD_CMD" >> "$LOGDIR/record_stdout.log" 2>&1
        ret=$?
        if validate_file_exists "$RECORD_FILE"; then
			if [ "$ret" -eq 0 ]; then
				log_pass "Recording loop $i: Completed successfully"
			elif [ "$ret" -eq 1 ] && [ "$AUDIO_BACKEND" = "pipewire" ]; then
				log_warn "Recording loop $i: Interrupted/timed out for PipeWire (ret=1, file exists)"
			elif [ "$ret" -eq 124 ]; then
				log_warn "Recording loop $i: Timed out (ret=124) and recorded clip exists"
			else
				log_fail "Recording loop $i: Error code $ret, but recorded clip exists"
			fi
		else
			log_fail "Recording loop $i: recorded clip missing or empty"
			# shellcheck disable=SC2034
			RECORD_SUCCESS=1
			break
		fi
    done

    get_kernel_log > "$LOGDIR/dmesg_after.log"
    scan_dmesg_errors "audio" "$LOGDIR"

    if [ "$RECORD_SUCCESS" -eq 0 ]; then
        log_pass_exit "$TESTNAME" "Audio record test completed successfully"
        echo "$TESTNAME PASS" > "$RESULT_FILE"
    else
        log_fail_exit "$TESTNAME" "Audio record test failed"
        echo "$TESTNAME FAIL" > "$RESULT_FILE"
    fi
	
}
