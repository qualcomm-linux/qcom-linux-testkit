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
. "$TOOLS/audio_common.sh"

TESTNAME="AudioLoopback"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"

DURATION=5
PLAYBACK_ROUTE="auto"
CAPTURE_ROUTE="auto"
PLAYBACK_ROUTE_EXPLICIT=0
CAPTURE_ROUTE_EXPLICIT=0
PLAYBACK_DEVICE=""
PLAYBACK_DEVICE_SELECTION="auto"
CAPTURE_DEVICE=""
DMESG_SCAN="${DMESG_SCAN:-1}"
ARG_ERROR=""
LOGDIR="${LOGDIR:-}"
RECORDER_PID=""
AUDIO_BACKEND=""
PLAYBACK_TARGET=""
CAPTURE_TARGET=""
PLAYBACK_CLIENT=""
CAPTURE_CLIENT=""
MANAGED_BACKEND_FAILURE=""
MANAGED_BACKEND_APPLICABLE_FAILURE=0

# Print the audio loopback CLI and its environment-variable equivalents.
usage() {
    cat <<EOF_USAGE
Usage: $0 [options]

Options:
  --duration SECONDS        Reference playback duration, default: 5
  --sink {auto|speaker|speakers|headphone|headphones|headset}
                            Semantic playback route, default: auto
  --source {auto|mic|microphone|headset-mic|headset_mic|"headset mic"}
                            Semantic capture route, default: auto
  --playback-device DEVICE  Explicit ALSA playback device, default: auto
  --capture-device DEVICE   Explicit ALSA capture device, default: auto
  --dmesg-scan {0|1}        Capture audio-related kernel evidence, default: 1
  --no-dmesg                Disable kernel evidence capture
  --help, -h                Show this help

The test requires a real acoustic or electrical path from the selected output
to the selected input. Automatic mode uses an active PipeWire or PulseAudio
requested physical routes before falling back to direct ALSA. It generates
a deterministic local reference, starts capture, plays the reference, and
validates the recorded WAV.
EOF_USAGE
}

# Parse loopback arguments without changing target state.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --duration)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--duration requires a value"
                    return 1
                fi
                DURATION="$2"
                shift 2
                ;;
            --playback-device)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--playback-device requires a value"
                    return 1
                fi
                case "$2" in
                    ""|auto)
                        PLAYBACK_DEVICE=""
                        PLAYBACK_DEVICE_SELECTION="auto"
                        ;;
                    *)
                        PLAYBACK_DEVICE="$2"
                        PLAYBACK_DEVICE_SELECTION="explicit"
                        ;;
                esac
                shift 2
                ;;
            --sink)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--sink requires a value"
                    return 1
                fi
                PLAYBACK_ROUTE="$2"
                PLAYBACK_ROUTE_EXPLICIT=1
                shift 2
                ;;
            --capture-device)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--capture-device requires a value"
                    return 1
                fi
                case "$2" in
                    ""|auto)
                        CAPTURE_DEVICE=""
                        ;;
                    *)
                        CAPTURE_DEVICE="$2"
                        ;;
                esac
                shift 2
                ;;
            --source)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--source requires a value"
                    return 1
                fi
                CAPTURE_ROUTE="$2"
                CAPTURE_ROUTE_EXPLICIT=1
                shift 2
                ;;
            --dmesg-scan)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--dmesg-scan requires a value"
                    return 1
                fi
                DMESG_SCAN="$2"
                shift 2
                ;;
            --no-dmesg)
                DMESG_SCAN=0
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                ARG_ERROR="unknown option: $1"
                return 1
                ;;
        esac
    done

    return 0
}

# Stop only the recorder process started by this test.
audio_loopback_cleanup() {
    if [ -n "$RECORDER_PID" ]; then
        kill "$RECORDER_PID" >/dev/null 2>&1 || true
        wait "$RECORDER_PID" >/dev/null 2>&1 || true
        RECORDER_PID=""
    fi
}

parse_args "$@"
parse_rc=$?

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if [ "$parse_rc" -ne 0 ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - malformed command line, $ARG_ERROR"
    test_result_finish
fi

case "$DURATION" in
    ''|*[!0-9]*)
        test_result_record "FAIL" \
            "$TESTNAME FAIL - invalid duration '$DURATION', expected an integer from 2 to 30"
        test_result_finish
        ;;
esac

if [ "$DURATION" -lt 2 ] || [ "$DURATION" -gt 30 ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - duration '$DURATION' is outside the supported 2 to 30 second range"
    test_result_finish
fi

PLAYBACK_ROUTE_REQUESTED="$PLAYBACK_ROUTE"
PLAYBACK_ROUTE="$(
    audio_normalize_playback_route "$PLAYBACK_ROUTE_REQUESTED" 2>/dev/null
)" || {
    test_result_record "FAIL" \
        "$TESTNAME FAIL - invalid sink '$PLAYBACK_ROUTE_REQUESTED', expected auto, speaker, speakers, headphone, headphones, or headset"
    test_result_finish
}
if [ "$PLAYBACK_ROUTE" = "null" ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - loopback requires a physical playback route, use speaker or headset"
    test_result_finish
fi
if [ "$PLAYBACK_ROUTE" = "auto" ]; then
    PLAYBACK_ROUTE_EXPLICIT=0
fi

CAPTURE_ROUTE_REQUESTED="$CAPTURE_ROUTE"
CAPTURE_ROUTE="$(
    audio_normalize_capture_route "$CAPTURE_ROUTE_REQUESTED" 2>/dev/null
)" || {
    test_result_record "FAIL" \
        "$TESTNAME FAIL - invalid source '$CAPTURE_ROUTE_REQUESTED', expected auto, mic, microphone, or headset-mic"
    test_result_finish
}
if [ "$CAPTURE_ROUTE" = "null" ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - loopback requires a physical capture route, use mic or headset-mic"
    test_result_finish
fi
if [ "$CAPTURE_ROUTE" = "auto" ]; then
    CAPTURE_ROUTE_EXPLICIT=0
fi

PLAYBACK_ROUTE_POLICY="$PLAYBACK_ROUTE"
CAPTURE_ROUTE_POLICY="$CAPTURE_ROUTE"
SINK_CHOICE="$PLAYBACK_ROUTE"
SRC_CHOICE="$CAPTURE_ROUTE"
export SINK_CHOICE SRC_CHOICE PLAYBACK_ROUTE_EXPLICIT CAPTURE_ROUTE_EXPLICIT

case "$DMESG_SCAN" in
    0|1)
        ;;
    *)
        test_result_record "FAIL" \
            "$TESTNAME FAIL - invalid dmesg selection '$DMESG_SCAN', expected 0 or 1"
        test_result_finish
        ;;
esac

if [ -z "$LOGDIR" ]; then
    RUN_STAMP="$(date -u '+%Y%m%d-%H%M%S' 2>/dev/null || printf '%s' unknown)"
    LOGDIR="$SCRIPT_DIR/results/$TESTNAME/run-${RUN_STAMP}-$$"
fi

if ! mkdir -p "$LOGDIR"; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - cannot create retained evidence directory $LOGDIR"
    test_result_finish
fi

if ! command -v audio_prepare_desktop_audio_test_user >/dev/null 2>&1; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - required helper is unavailable: audio_prepare_desktop_audio_test_user"
    test_result_finish
fi

audio_loopback_user_manager_required=0
if [ -z "$PLAYBACK_DEVICE" ] &&
   [ -z "$CAPTURE_DEVICE" ] &&
   command -v systemctl >/dev/null 2>&1 &&
   [ -d /run/systemd/system ] &&
   { command -v pw-play >/dev/null 2>&1 ||
     command -v pw-cat >/dev/null 2>&1 ||
     command -v pw-record >/dev/null 2>&1 ||
     command -v paplay >/dev/null 2>&1 ||
     command -v parecord >/dev/null 2>&1; }; then
    audio_loopback_user_manager_required=1
fi

if ! audio_prepare_desktop_audio_test_user \
    "$SCRIPT_DIR/run.sh" \
    "$RES_FILE" \
    "$LOGDIR" \
    "$audio_loopback_user_manager_required" \
    "$@"; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - desktop Audio user launch failed"
    test_result_finish
fi

if command -v pkg_detect_os_id >/dev/null 2>&1; then
    audio_loopback_os_id="$(pkg_detect_os_id 2>/dev/null || echo unknown)"
else
    audio_loopback_os_id="unknown"
fi

if ! command -v audio_configure_ubuntu_desktop_session >/dev/null 2>&1; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - required helper is unavailable: audio_configure_ubuntu_desktop_session"
    test_result_finish
fi

audio_configure_ubuntu_desktop_session "$audio_loopback_os_id"
export AUDIO_USE_DESKTOP_SESSION

AUDIO_ALSA_PLAYBACK_PROBE_LOG="$LOGDIR/alsa_playback_probe.log"
export AUDIO_ALSA_PLAYBACK_PROBE_LOG
: >"$AUDIO_ALSA_PLAYBACK_PROBE_LOG"

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap audio_loopback_cleanup EXIT

missing_commands=""
if ! command -v awk >/dev/null 2>&1; then
    missing_commands="$missing_commands awk"
fi

if ! command -v python3 >/dev/null 2>&1; then
    for required_command in dd od; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            missing_commands="$missing_commands $required_command"
        fi
    done
fi

if [ -n "$missing_commands" ]; then
    test_result_record "SKIP" \
        "$TESTNAME SKIP - required image-provided audio utilities are unavailable, missing=$missing_commands"
    test_result_finish
fi

log_info "Starting $TESTNAME, duration=${DURATION}s sink=$PLAYBACK_ROUTE source=$CAPTURE_ROUTE playback_device=${PLAYBACK_DEVICE:-auto} capture_device=${CAPTURE_DEVICE:-auto}"
log_info "AUDIO_ROUTE_DISCOVERY scope=loopback playback_requested='$PLAYBACK_ROUTE_REQUESTED' playback_explicit=$PLAYBACK_ROUTE_EXPLICIT playback_policy=$PLAYBACK_ROUTE automatic_playback_order='speakers headphones' capture_requested='$CAPTURE_ROUTE_REQUESTED' capture_explicit=$CAPTURE_ROUTE_EXPLICIT capture_policy=$CAPTURE_ROUTE automatic_capture_order='mic headset-mic'"
log_info "Retaining loopback artifacts in $LOGDIR"

if [ -n "$PLAYBACK_DEVICE" ] || [ -n "$CAPTURE_DEVICE" ]; then
    AUDIO_BACKEND="alsa"
else
    AUDIO_BACKEND="$(
        audio_run_helper_as_test_user \
            --require-session \
            detect_audio_backend 2>/dev/null || true
    )"
fi

case "$AUDIO_BACKEND" in
    pipewire)
        if command -v pw-play >/dev/null 2>&1; then
            PLAYBACK_CLIENT="pw-play"
        elif command -v pw-cat >/dev/null 2>&1 &&
             pw-cat --help 2>&1 | grep -q -- '--playback'; then
            PLAYBACK_CLIENT="pw-cat"
        fi

        if command -v pw-record >/dev/null 2>&1; then
            CAPTURE_CLIENT="pw-record"
        fi

        if [ -z "$PLAYBACK_CLIENT" ] ||
           [ -z "$CAPTURE_CLIENT" ] ||
           ! command -v wpctl >/dev/null 2>&1; then
            MANAGED_BACKEND_FAILURE="PipeWire is active but its playback, recording, or control client is unavailable"
            MANAGED_BACKEND_APPLICABLE_FAILURE=1
            AUDIO_BACKEND=""
        else
            playback_route_record="$(
                audio_run_helper_as_test_user \
                    --require-session \
                    audio_select_managed_playback_route \
                    pipewire "$PLAYBACK_ROUTE" 2>/dev/null || true
            )"
            capture_route_record="$(
                audio_run_helper_as_test_user \
                    --require-session \
                    audio_select_managed_capture_route \
                    pipewire "$CAPTURE_ROUTE" 2>/dev/null || true
            )"
            PLAYBACK_ROUTE="$(
                printf '%s\n' "$playback_route_record" | cut -d'|' -f1
            )"
            PLAYBACK_TARGET="$(
                printf '%s\n' "$playback_route_record" | cut -d'|' -f2-
            )"
            CAPTURE_ROUTE="$(
                printf '%s\n' "$capture_route_record" | cut -d'|' -f1
            )"
            CAPTURE_TARGET="$(
                printf '%s\n' "$capture_route_record" | cut -d'|' -f2-
            )"

            if [ -z "$PLAYBACK_TARGET" ] || [ -z "$CAPTURE_TARGET" ]; then
                PLAYBACK_ROUTE="$PLAYBACK_ROUTE_POLICY"
                CAPTURE_ROUTE="$CAPTURE_ROUTE_POLICY"
                SINK_CHOICE="$PLAYBACK_ROUTE"
                SRC_CHOICE="$CAPTURE_ROUTE"
                export SINK_CHOICE SRC_CHOICE
                MANAGED_BACKEND_FAILURE="PipeWire is active but no usable requested or automatically selected playback/capture route pair was discovered"
                AUDIO_BACKEND=""
            else
                SINK_CHOICE="$PLAYBACK_ROUTE"
                SRC_CHOICE="$CAPTURE_ROUTE"
                export SINK_CHOICE SRC_CHOICE
            fi
        fi
        ;;
    pulseaudio)
        if command -v paplay >/dev/null 2>&1 &&
           command -v parecord >/dev/null 2>&1 &&
           command -v pactl >/dev/null 2>&1; then
            PLAYBACK_CLIENT="paplay"
            CAPTURE_CLIENT="parecord"
            playback_route_record="$(
                audio_run_helper_as_test_user \
                    --require-session \
                    audio_select_managed_playback_route \
                    pulseaudio "$PLAYBACK_ROUTE" 2>/dev/null || true
            )"
            capture_route_record="$(
                audio_run_helper_as_test_user \
                    --require-session \
                    audio_select_managed_capture_route \
                    pulseaudio "$CAPTURE_ROUTE" 2>/dev/null || true
            )"
            PLAYBACK_ROUTE="$(
                printf '%s\n' "$playback_route_record" | cut -d'|' -f1
            )"
            PLAYBACK_TARGET="$(
                printf '%s\n' "$playback_route_record" | cut -d'|' -f2-
            )"
            CAPTURE_ROUTE="$(
                printf '%s\n' "$capture_route_record" | cut -d'|' -f1
            )"
            CAPTURE_TARGET="$(
                printf '%s\n' "$capture_route_record" | cut -d'|' -f2-
            )"

            if [ -z "$PLAYBACK_TARGET" ] || [ -z "$CAPTURE_TARGET" ]; then
                PLAYBACK_ROUTE="$PLAYBACK_ROUTE_POLICY"
                CAPTURE_ROUTE="$CAPTURE_ROUTE_POLICY"
                SINK_CHOICE="$PLAYBACK_ROUTE"
                SRC_CHOICE="$CAPTURE_ROUTE"
                export SINK_CHOICE SRC_CHOICE
                MANAGED_BACKEND_FAILURE="PulseAudio is active but no usable requested or automatically selected playback/capture route pair was discovered"
                AUDIO_BACKEND=""
            else
                SINK_CHOICE="$PLAYBACK_ROUTE"
                SRC_CHOICE="$CAPTURE_ROUTE"
                export SINK_CHOICE SRC_CHOICE
            fi
        else
            MANAGED_BACKEND_FAILURE="PulseAudio is active but paplay, parecord, or pactl is unavailable"
            MANAGED_BACKEND_APPLICABLE_FAILURE=1
            AUDIO_BACKEND=""
        fi
        ;;
    alsa|"")
        ;;
    *)
        MANAGED_BACKEND_FAILURE="unsupported detected audio backend '$AUDIO_BACKEND'"
        MANAGED_BACKEND_APPLICABLE_FAILURE=1
        AUDIO_BACKEND=""
        ;;
esac

if [ -z "$AUDIO_BACKEND" ]; then
    if [ -n "$MANAGED_BACKEND_FAILURE" ]; then
        log_warn "$TESTNAME: $MANAGED_BACKEND_FAILURE, probing direct ALSA loopback paths"
    fi

    if command -v aplay >/dev/null 2>&1 &&
       command -v arecord >/dev/null 2>&1 &&
       audio_playback_probe_selected_alsa_with_recovery \
           "$PLAYBACK_DEVICE"; then
        PLAYBACK_ROUTE="$SINK_CHOICE"
        AUDIO_BACKEND="alsa"
    fi
fi

if [ -z "$AUDIO_BACKEND" ]; then
    if [ "$PLAYBACK_ROUTE_EXPLICIT" -eq 1 ] ||
       [ "$CAPTURE_ROUTE_EXPLICIT" -eq 1 ] ||
       [ -n "$PLAYBACK_DEVICE" ] ||
       [ -n "$CAPTURE_DEVICE" ] ||
       [ "$MANAGED_BACKEND_APPLICABLE_FAILURE" -eq 1 ]; then
        log_file_with_label \
            "ALSA-PROBE" "$AUDIO_ALSA_PLAYBACK_PROBE_LOG" 40
        test_result_record "FAIL" \
            "$TESTNAME FAIL - requested or applicable loopback routes are unavailable, playback_requested='$PLAYBACK_ROUTE_REQUESTED' capture_requested='$CAPTURE_ROUTE_REQUESTED' playback_device='${PLAYBACK_DEVICE:-auto}' capture_device='${CAPTURE_DEVICE:-auto}' managed_reason='${MANAGED_BACKEND_FAILURE:-none}' ALSA_reason='${AUDIO_ALSA_PLAYBACK_REASON:-playback probe failed}', verify sound-card registration, topology, UCM, mixer routing, and image audio clients"
    else
        test_result_record "SKIP" \
            "$TESTNAME SKIP - automatic discovery found no usable speaker/headphones and mic/headset-mic loopback route pair on managed audio or direct ALSA"
    fi
    test_result_finish
fi

if [ "$AUDIO_BACKEND" = "alsa" ]; then
    if ! command -v aplay >/dev/null 2>&1 ||
       ! command -v arecord >/dev/null 2>&1; then
        test_result_record "SKIP" \
            "$TESTNAME SKIP - direct ALSA loopback requires image-provided aplay and arecord utilities"
        test_result_finish
    fi

    if [ -z "${AUDIO_ALSA_PLAYBACK_DEVICE:-}" ] ||
       [ -n "$PLAYBACK_DEVICE" ]; then
        if ! audio_playback_probe_selected_alsa_with_recovery \
            "$PLAYBACK_DEVICE"; then
            if [ "$PLAYBACK_ROUTE_EXPLICIT" -eq 1 ] ||
               [ -n "$PLAYBACK_DEVICE" ] ||
               [ "$MANAGED_BACKEND_APPLICABLE_FAILURE" -eq 1 ]; then
                log_file_with_label \
                    "ALSA-PROBE" "$AUDIO_ALSA_PLAYBACK_PROBE_LOG" 40
                test_result_record "FAIL" \
                    "$TESTNAME FAIL - requested playback route/device is unavailable, route='$PLAYBACK_ROUTE_REQUESTED' device='${PLAYBACK_DEVICE:-auto}' reason=${AUDIO_ALSA_PLAYBACK_REASON:-probe failed}, verify sound-card registration, topology, UCM, mixer routing, and image audio clients"
            else
                test_result_record "SKIP" \
                    "$TESTNAME SKIP - automatic playback discovery found no usable speakers or headphones ALSA route"
            fi
            test_result_finish
        fi
    fi
    PLAYBACK_ROUTE="$SINK_CHOICE"
    PLAYBACK_DEVICE="$AUDIO_ALSA_PLAYBACK_DEVICE"

    requested_capture_device="$CAPTURE_DEVICE"
    if ! audio_record_probe_selected_alsa_capture_profile \
        "$requested_capture_device"; then
        if [ "$CAPTURE_ROUTE_EXPLICIT" -eq 1 ] ||
           [ -n "$requested_capture_device" ] ||
           [ "$MANAGED_BACKEND_APPLICABLE_FAILURE" -eq 1 ]; then
            test_result_record "FAIL" \
                "$TESTNAME FAIL - requested capture route/device is unavailable, route='$CAPTURE_ROUTE_REQUESTED' device='${requested_capture_device:-auto}' reason=${AUDIO_ALSA_CAPTURE_REASON:-unknown}, verify the microphone route, UCM data, and image audio clients"
        else
            test_result_record "SKIP" \
                "$TESTNAME SKIP - automatic capture discovery found no usable mic or headset-mic ALSA route, reason=${AUDIO_ALSA_CAPTURE_REASON:-unknown}, connect a loopback fixture or pass an available explicit route/device"
        fi
        test_result_finish
    fi
    CAPTURE_ROUTE="$SRC_CHOICE"

    playback_route_record="$(
        audio_playback_resolve_alsa_route "$PLAYBACK_ROUTE" 2>/dev/null || true
    )"
    playback_ucm_pcm="$(
        printf '%s\n' "$playback_route_record" | cut -d'|' -f1
    )"
    playback_ucm_card="$(
        printf '%s\n' "$playback_route_record" | cut -d'|' -f2
    )"
    playback_ucm_device="$(
        printf '%s\n' "$playback_route_record" | cut -d'|' -f3
    )"
    capture_route_record="$(
        audio_record_resolve_alsa_route "$CAPTURE_ROUTE" 2>/dev/null || true
    )"
    capture_ucm_card="$(
        printf '%s\n' "$capture_route_record" | cut -d'|' -f2
    )"
    capture_ucm_device="$(
        printf '%s\n' "$capture_route_record" | cut -d'|' -f3
    )"

    if [ -n "$playback_ucm_card" ] &&
       [ "$playback_ucm_card" = "$capture_ucm_card" ] &&
       [ -n "$playback_ucm_device" ] &&
       [ -n "$capture_ucm_device" ]; then
        if ! audio_alsa_enable_ucm_hifi_devices \
            "$playback_ucm_card" \
            "$playback_ucm_device" \
            "$capture_ucm_device"; then
            test_result_record "FAIL" \
                "$TESTNAME FAIL - could not enable the $PLAYBACK_ROUTE and $CAPTURE_ROUTE UCM devices together on card '$playback_ucm_card'"
            test_result_finish
        fi
    elif [ -n "$playback_ucm_card" ]; then
        if ! audio_playback_alsa_prepare \
            "$(audio_alsa_device_card "$PLAYBACK_DEVICE")" \
            "$playback_ucm_card" "$playback_ucm_device"; then
            test_result_record "FAIL" \
                "$TESTNAME FAIL - could not prepare the $PLAYBACK_ROUTE ALSA playback route"
            test_result_finish
        fi

        if ! audio_record_alsa_prepare_capture \
            "$(audio_alsa_device_card "$AUDIO_ALSA_CAPTURE_DEVICE")" \
            "$capture_ucm_card" "$capture_ucm_device"; then
            test_result_record "FAIL" \
                "$TESTNAME FAIL - could not prepare the $CAPTURE_ROUTE ALSA capture route"
            test_result_finish
        fi
    else
        if ! audio_record_alsa_prepare_capture \
            "$(audio_alsa_device_card "$AUDIO_ALSA_CAPTURE_DEVICE")" \
            "$capture_ucm_card" "$capture_ucm_device"; then
            test_result_record "FAIL" \
                "$TESTNAME FAIL - could not prepare the $CAPTURE_ROUTE ALSA capture route"
            test_result_finish
        fi

        if ! audio_playback_alsa_prepare \
            "$(audio_alsa_device_card "$PLAYBACK_DEVICE")" \
            "$playback_ucm_card" "$playback_ucm_device"; then
            test_result_record "FAIL" \
                "$TESTNAME FAIL - could not prepare the $PLAYBACK_ROUTE ALSA playback route"
            test_result_finish
        fi
    fi

    CAPTURE_DEVICE="$AUDIO_ALSA_CAPTURE_DEVICE"
    PLAYBACK_TARGET="$(
        audio_playback_effective_alsa_device \
            "$PLAYBACK_DEVICE" \
            "$PLAYBACK_DEVICE_SELECTION"
    )"
    CAPTURE_TARGET="$CAPTURE_DEVICE"
    PLAYBACK_CLIENT="aplay"
    CAPTURE_CLIENT="arecord"
    capture_format="$AUDIO_ALSA_CAPTURE_FORMAT"
    capture_rate="$AUDIO_ALSA_CAPTURE_RATE"
    capture_channels="$AUDIO_ALSA_CAPTURE_CHANNELS"
else
    capture_format="S16_LE"
    capture_rate=48000
    capture_channels=2

    case "$AUDIO_BACKEND" in
        pipewire)
            audio_run_helper_as_test_user \
                --require-session \
                pw_set_default_sink "$PLAYBACK_TARGET" >/dev/null 2>&1 ||
                log_warn "Could not set PipeWire default sink id=$PLAYBACK_TARGET"
            audio_run_helper_as_test_user \
                --require-session \
                pw_set_default_source "$CAPTURE_TARGET" >/dev/null 2>&1 ||
                log_warn "Could not set PipeWire default source id=$CAPTURE_TARGET"
            audio_run_with_timeout_as_test_user \
                --require-session \
                3s \
                wpctl set-mute "$PLAYBACK_TARGET" 0 >/dev/null 2>&1 ||
                log_warn "Could not unmute PipeWire sink id=$PLAYBACK_TARGET"
            ;;
        pulseaudio)
            audio_run_helper_as_test_user \
                --require-session \
                pa_set_default_sink "$PLAYBACK_TARGET" >/dev/null 2>&1 || true
            audio_run_helper_as_test_user \
                --require-session \
                pa_set_default_source "$CAPTURE_TARGET" >/dev/null 2>&1 || true
            ;;
    esac
fi

log_info "Using audio backend: $AUDIO_BACKEND"
if [ "$AUDIO_BACKEND" = "alsa" ] &&
   [ -n "${playback_ucm_card:-}" ] &&
   [ -n "${playback_ucm_device:-}" ] &&
   [ -n "${capture_ucm_card:-}" ] &&
   [ -n "${capture_ucm_device:-}" ]; then
    log_info "Loopback ALSA route: playback_choice=$PLAYBACK_ROUTE ucm_pcm='$playback_ucm_pcm' playback_target=$PLAYBACK_TARGET playback_selection=$PLAYBACK_DEVICE_SELECTION playback_ucm_card='$playback_ucm_card' playback_ucm_device='$playback_ucm_device' capture_choice=$CAPTURE_ROUTE capture_device=$CAPTURE_TARGET capture_ucm_card='$capture_ucm_card' capture_ucm_device='$capture_ucm_device'"
elif [ "$AUDIO_BACKEND" = "alsa" ]; then
    log_info "Loopback ALSA route: playback_target=$PLAYBACK_TARGET playback_requested_choice=$PLAYBACK_ROUTE playback_selection=$PLAYBACK_DEVICE_SELECTION capture_device=$CAPTURE_TARGET capture_requested_choice=$CAPTURE_ROUTE selection=legacy-inventory-fallback"
else
    log_info "Loopback route: playback=$PLAYBACK_TARGET capture=$CAPTURE_TARGET"
fi
CAPTURE_DEVICE_SELECTION="auto"
if [ -n "$requested_capture_device" ]; then
    CAPTURE_DEVICE_SELECTION="explicit"
fi
log_info "AUDIO_ROUTE scope=loopback backend=$AUDIO_BACKEND playback_requested='$PLAYBACK_ROUTE_REQUESTED' playback_explicit=$PLAYBACK_ROUTE_EXPLICIT playback_canonical=$PLAYBACK_ROUTE playback_target='$PLAYBACK_TARGET' playback_device_selection=$PLAYBACK_DEVICE_SELECTION capture_requested='$CAPTURE_ROUTE_REQUESTED' capture_explicit=$CAPTURE_ROUTE_EXPLICIT capture_canonical=$CAPTURE_ROUTE capture_target='$CAPTURE_TARGET' capture_device_selection=$CAPTURE_DEVICE_SELECTION"

reference_wav="$LOGDIR/reference_48KHz_${DURATION}s_8b_2ch.wav"
reference_log="$LOGDIR/reference_validation.log"
capture_wav="$LOGDIR/loopback_capture.wav"
capture_log="$LOGDIR/capture.log"
playback_log="$LOGDIR/playback.log"

if ! audio_generate_u8_stereo_wav \
    "$reference_wav" \
    "$DURATION" \
    48000 \
    1000 2>"$LOGDIR/reference_generation.log"; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - deterministic playback reference generation failed, artifact=$LOGDIR/reference_generation.log"
    test_result_finish
fi

if ! audio_validate_wav_file \
    "$reference_wav" \
    mic \
    48000 \
    2 \
    8 \
    "$DURATION" \
    "$reference_log" \
    playback \
    2; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - generated reference failed basic-integrity validation, validation='${AUDIO_VALIDATION_SUMMARY:-unavailable}', artifact=$reference_log"
    test_result_finish
fi

test_result_record "PASS" \
    "Generated and validated a deterministic local playback reference, validation='$AUDIO_VALIDATION_SUMMARY'"

capture_duration=$((DURATION + 2))
capture_timeout=$((capture_duration + 10))
playback_timeout=$((DURATION + 10))
rm -f "$capture_wav"

if [ "$AUDIO_USE_DESKTOP_SESSION" -eq 1 ] &&
   [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]; then
    audio_loopback_command_user="$(
        audio_find_desktop_audio_user 2>/dev/null || true
    )"

    if [ -z "$audio_loopback_command_user" ] ||
       ! : >"$capture_wav" ||
       ! chown "$audio_loopback_command_user" "$capture_wav" ||
       ! chmod 0644 "$capture_wav"; then
        test_result_record "FAIL" \
            "$TESTNAME FAIL - cannot prepare loopback capture artifact for the active Ubuntu audio user, artifact=$capture_wav"
        test_result_finish
    fi
fi

log_info "Starting capture before playback, backend=$AUDIO_BACKEND target=$CAPTURE_TARGET format=$capture_format rate=$capture_rate channels=$capture_channels duration=${capture_duration}s"
case "$AUDIO_BACKEND" in
    pipewire)
        capture_watchdog="${capture_duration}s"
        audio_run_with_timeout_as_test_user \
            --require-session \
            "$capture_watchdog" \
            env LC_ALL=C \
            pw-record \
            -v \
            --rate="$capture_rate" \
            --channels="$capture_channels" \
            --target "$CAPTURE_TARGET" \
            "$capture_wav" >"$capture_log" 2>&1 &
        ;;
    pulseaudio)
        capture_watchdog="${capture_duration}s"
        audio_run_with_timeout_as_test_user \
            --require-session \
            "$capture_watchdog" \
            env LC_ALL=C \
            parecord \
            --rate="$capture_rate" \
            --channels="$capture_channels" \
            --file-format=wav \
            --device="$CAPTURE_TARGET" \
            "$capture_wav" >"$capture_log" 2>&1 &
        ;;
    alsa)
        capture_watchdog="${capture_timeout}s"
        audio_run_with_timeout_as_test_user "$capture_watchdog" \
            env LC_ALL=C \
            arecord \
            -q \
            -D "$CAPTURE_TARGET" \
            -f "$capture_format" \
            -r "$capture_rate" \
            -c "$capture_channels" \
            -d "$capture_duration" \
            "$capture_wav" >"$capture_log" 2>&1 &
        ;;
esac
RECORDER_PID=$!

sleep 1

log_info "Playing deterministic reference while capture is active, backend=$AUDIO_BACKEND target=$PLAYBACK_TARGET"
case "$AUDIO_BACKEND" in
    pipewire)
        if [ "$PLAYBACK_CLIENT" = "pw-cat" ]; then
            audio_run_with_timeout_as_test_user \
                --require-session \
                "${playback_timeout}s" \
                env LC_ALL=C \
                pw-cat \
                --playback \
                -v \
                "$reference_wav" >"$playback_log" 2>&1
        else
            audio_run_with_timeout_as_test_user \
                --require-session \
                "${playback_timeout}s" \
                env LC_ALL=C \
                pw-play \
                -v \
                "$reference_wav" >"$playback_log" 2>&1
        fi
        ;;
    pulseaudio)
        audio_run_with_timeout_as_test_user \
            --require-session \
            "${playback_timeout}s" \
            env LC_ALL=C \
            paplay \
            --device="$PLAYBACK_TARGET" \
            "$reference_wav" >"$playback_log" 2>&1
        ;;
    alsa)
        audio_run_with_timeout_as_test_user "${playback_timeout}s" \
            env LC_ALL=C \
            aplay \
            -q \
            -D "$PLAYBACK_TARGET" \
            "$reference_wav" >"$playback_log" 2>&1
        ;;
esac
playback_rc=$?

wait "$RECORDER_PID"
capture_rc=$?
RECORDER_PID=""

if [ "$playback_rc" -eq 0 ]; then
    test_result_record "PASS" \
        "Deterministic reference playback completed, backend=$AUDIO_BACKEND target=$PLAYBACK_TARGET artifact=$playback_log"
else
    test_result_record "FAIL" \
        "$TESTNAME FAIL - deterministic reference playback failed, backend=$AUDIO_BACKEND target=$PLAYBACK_TARGET rc=$playback_rc artifact=$playback_log"
fi

AUDIO_RECORD_STRICT_SIGNAL=0
export AUDIO_RECORD_STRICT_SIGNAL

if audio_validate_recording_result \
    "$capture_wav" \
    mic \
    "$capture_rate" \
    "$capture_channels" \
    "$capture_duration" \
    "$capture_rc" \
    "$capture_watchdog" \
    "$capture_log" \
    loopback; then
    log_info "AUDIO_VALIDATION scope=loopback policy=basic-integrity status=PASS backend=$AUDIO_BACKEND playback_target=$PLAYBACK_TARGET capture_target=$CAPTURE_TARGET playback_rc=$playback_rc capture_rc=$capture_rc"
    test_result_record "PASS" \
        "Loopback capture contains a valid non-zero signal, validation='$AUDIO_VALIDATION_SUMMARY' artifact=$capture_wav"
else
    log_info "AUDIO_VALIDATION scope=loopback policy=basic-integrity status=FAIL backend=$AUDIO_BACKEND playback_target=$PLAYBACK_TARGET capture_target=$CAPTURE_TARGET playback_rc=$playback_rc capture_rc=$capture_rc"
    test_result_record "FAIL" \
        "$TESTNAME FAIL - loopback capture is corrupt, empty, all-zero, or materially short, validation='${AUDIO_VALIDATION_SUMMARY:-unavailable}', verify the acoustic or electrical fixture, artifact=$capture_log"
fi

if [ "$DMESG_SCAN" -eq 1 ]; then
    scan_dmesg_errors \
        "$LOGDIR" \
        'snd|asoc|audio|lpass|q6|codec|xrun|underrun|overrun' \
        'dummy regulator|supply [^ ]+ not found|using dummy regulator|probe deferred' || true

    if [ -s "$LOGDIR/dmesg_errors.log" ]; then
        log_warn "Audio-related kernel errors were captured, artifact=$LOGDIR/dmesg_errors.log"
    fi
fi

test_result_finish
