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

TESTNAME="AudioRouteRecord"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"

SOURCE="${AUDIO_CAPTURE_SOURCE:-headset-mic}"
DYNAMIC_MIXER_CONTROL="${AUDIO_CAPTURE_MIXER_CONTROL:-}"
DYNAMIC_MIXER_VALUE="${AUDIO_CAPTURE_MIXER_VALUE:-}"
DYNAMIC_PCM_LABEL="${AUDIO_CAPTURE_PCM_LABEL:-}"
DYNAMIC_ALSA_DEVICE="${AUDIO_CAPTURE_ALSA_DEVICE:-}"
DURATION="${AUDIO_CAPTURE_DURATION:-3}"
STRICT_SIGNAL="${AUDIO_CAPTURE_STRICT_SIGNAL:-1}"
MIN_RMS_DBFS="${AUDIO_CAPTURE_MIN_RMS_DBFS:--60}"
DMESG_SCAN="${DMESG_SCAN:-1}"
RES_SUFFIX="${RES_SUFFIX:-}"
RESULT_TESTNAME="${LAVA_TESTCASE_ID:-$TESTNAME}"
ARG_ERROR=""
LOGDIR=""
RESULT_SCOPE=""

# Print the supported route-recording CLI and its environment equivalents.
usage() {
    cat <<EOF_USAGE
Usage: $0 [--source headset-mic] [options]

Options:
  --source SOURCE           Wired capture source, default: headset-mic
  --mixer-control NAME      Optional exact mixer control for opaque topologies
  --mixer-value VALUE       Value applied to the selected control, default: 1
  --pcm-label LABEL         Optional exact capture PCM label
  --alsa-device DEVICE      Optional ALSA endpoint such as plughw:0,2
  --duration SECONDS        Recording duration from 1 to 60, default: 3
  --strict-signal {0|1}     Require the configured minimum RMS, default: 1
  --min-rms-dbfs DBFS       Strict minimum RMS in dBFS, default: -60
  --dmesg-scan {0|1}        Capture audio-related kernel log evidence, default: 1
  --no-dmesg                Disable kernel log evidence capture
  --res-suffix SUFFIX       Generate AudioRouteRecord_SUFFIX.res
  --lava-testcase-id ID     Test name written to the result file
  --help, -h                Show this help

Environment equivalents:
  AUDIO_CAPTURE_SOURCE
  AUDIO_CAPTURE_MIXER_CONTROL
  AUDIO_CAPTURE_MIXER_VALUE
  AUDIO_CAPTURE_PCM_LABEL
  AUDIO_CAPTURE_ALSA_DEVICE
  AUDIO_CAPTURE_DURATION
  AUDIO_CAPTURE_STRICT_SIGNAL
  AUDIO_CAPTURE_MIN_RMS_DBFS
  DMESG_SCAN
  RES_SUFFIX
  LAVA_TESTCASE_ID
EOF_USAGE
}

# Parse command-line arguments without performing target-side mutations.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--source requires a value"
                    return 1
                fi
                SOURCE="$2"
                shift 2
                ;;
            --mixer-control)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--mixer-control requires a value"
                    return 1
                fi
                if [ -n "$2" ]; then
                    DYNAMIC_MIXER_CONTROL="$2"
                fi
                shift 2
                ;;
            --mixer-value)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--mixer-value requires a value"
                    return 1
                fi
                if [ -n "$2" ]; then
                    DYNAMIC_MIXER_VALUE="$2"
                fi
                shift 2
                ;;
            --pcm-label)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--pcm-label requires a value"
                    return 1
                fi
                if [ -n "$2" ]; then
                    DYNAMIC_PCM_LABEL="$2"
                fi
                shift 2
                ;;
            --alsa-device)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--alsa-device requires a value"
                    return 1
                fi
                if [ -n "$2" ]; then
                    DYNAMIC_ALSA_DEVICE="$2"
                fi
                shift 2
                ;;
            --duration)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--duration requires a value"
                    return 1
                fi
                DURATION="$2"
                shift 2
                ;;
            --strict-signal)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--strict-signal requires a value"
                    return 1
                fi
                STRICT_SIGNAL="$2"
                shift 2
                ;;
            --min-rms-dbfs)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--min-rms-dbfs requires a value"
                    return 1
                fi
                MIN_RMS_DBFS="$2"
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
            --res-suffix)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--res-suffix requires a value"
                    return 1
                fi
                RES_SUFFIX="$2"
                shift 2
                ;;
            --lava-testcase-id)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--lava-testcase-id requires a value"
                    return 1
                fi
                RESULT_TESTNAME="$2"
                shift 2
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

# Restore the exact capture mixer control changed by this test.
audio_route_record_cleanup() {
    if ! audio_alsa_restore_capture_route; then
        log_warn "Could not restore capture-route mixer state, control=${AUDIO_ALSA_CAPTURE_ROUTE_CONTROL:-unknown}"
    fi
}

parse_args "$@"
parse_rc=$?

if [ -n "$RES_SUFFIX" ]; then
    RES_FILE="$SCRIPT_DIR/${TESTNAME}_${RES_SUFFIX}.res"
    RESULT_SCOPE="$SCRIPT_DIR/results/${TESTNAME}_${RES_SUFFIX}"
else
    RESULT_SCOPE="$SCRIPT_DIR/results/${TESTNAME}"
fi

RUN_STAMP="$(date -u '+%Y%m%d-%H%M%S' 2>/dev/null || printf '%s' unknown)"
LOGDIR="$RESULT_SCOPE/run-${RUN_STAMP}-$$"

test_result_init "$RESULT_TESTNAME" "$RES_FILE" || exit 1

if [ "$parse_rc" -ne 0 ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - malformed command line, $ARG_ERROR"
    test_result_finish
fi

case "$SOURCE" in
    headset-mic|headset-microphone|headset|3.5mm-mic|3.5mm)
        SOURCE="headset-mic"
        ;;
    '')
        test_result_record "FAIL" \
            "$TESTNAME FAIL - no capture source selected, use --source headset-mic"
        test_result_finish
        ;;
    *)
        test_result_record "FAIL" \
            "$TESTNAME FAIL - invalid capture source '$SOURCE', expected headset-mic"
        test_result_finish
        ;;
esac

if [ -n "$DYNAMIC_MIXER_VALUE" ] &&
   [ -z "$DYNAMIC_MIXER_CONTROL" ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - --mixer-value requires --mixer-control so the requested value cannot be applied to the wrong control"
    test_result_finish
fi

case "$DURATION" in
    ''|*[!0-9]*)
        test_result_record "FAIL" \
            "$TESTNAME FAIL - invalid recording duration '$DURATION', expected a positive integer"
        test_result_finish
        ;;
esac

if [ "$DURATION" -le 0 ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - invalid recording duration '$DURATION', expected a positive integer"
    test_result_finish
fi

if [ "$DURATION" -gt 60 ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - recording duration '$DURATION' exceeds the 60 second safety limit"
    test_result_finish
fi

case "$STRICT_SIGNAL" in
    0|1)
        ;;
    *)
        test_result_record "FAIL" \
            "$TESTNAME FAIL - invalid strict-signal value '$STRICT_SIGNAL', expected 0 or 1"
        test_result_finish
        ;;
esac

case "$MIN_RMS_DBFS" in
    0|-[0-9]|-[0-9][0-9]|-[0-9][0-9][0-9])
        ;;
    *)
        test_result_record "FAIL" \
            "$TESTNAME FAIL - invalid minimum RMS '$MIN_RMS_DBFS', expected an integer from -120 to 0 dBFS"
        test_result_finish
        ;;
esac

if [ "$MIN_RMS_DBFS" -lt -120 ] ||
   [ "$MIN_RMS_DBFS" -gt 0 ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - minimum RMS '$MIN_RMS_DBFS' is outside the supported -120 to 0 dBFS range"
    test_result_finish
fi

AUDIO_RECORD_STRICT_SIGNAL="$STRICT_SIGNAL"
AUDIO_RECORD_MIN_RMS_DBFS="$MIN_RMS_DBFS"
export AUDIO_RECORD_STRICT_SIGNAL AUDIO_RECORD_MIN_RMS_DBFS

case "$DMESG_SCAN" in
    0|1)
        ;;
    *)
        test_result_record "FAIL" \
            "$TESTNAME FAIL - invalid dmesg selection '$DMESG_SCAN', expected 0 or 1"
        test_result_finish
        ;;
esac

if ! mkdir -p "$LOGDIR"; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - cannot create artifact directory: $LOGDIR"
    test_result_finish
fi

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap audio_route_record_cleanup EXIT

log_info "Starting $TESTNAME, source=$SOURCE duration=${DURATION}s strict_signal=$STRICT_SIGNAL min_rms_dbfs=$MIN_RMS_DBFS mixer_control='${DYNAMIC_MIXER_CONTROL:-auto}' mixer_value='${DYNAMIC_MIXER_VALUE:-auto}' pcm_label='${DYNAMIC_PCM_LABEL:-auto}' alsa_device='${DYNAMIC_ALSA_DEVICE:-auto}'"
log_info "Retaining route-recording artifacts in $LOGDIR"

audio_alsa_capture_route_inventory \
    "$LOGDIR/audio_capture_route_inventory.log" || true

if ! command -v arecord >/dev/null 2>&1; then
    test_result_record "SKIP" \
        "$TESTNAME SKIP - required ALSA capture utility is missing: arecord, provision alsa-utils in the image"
    test_result_finish
fi

route_discovery_log="$LOGDIR/route_discovery.log"
if ! audio_alsa_find_capture_route \
    "$SOURCE" \
    "$DYNAMIC_MIXER_CONTROL" \
    "$DYNAMIC_MIXER_VALUE" \
    "$DYNAMIC_PCM_LABEL" \
    "$DYNAMIC_ALSA_DEVICE" \
    >"$LOGDIR/route_mapping.txt" 2>"$route_discovery_log"; then
    if ! command -v amixer >/dev/null 2>&1; then
        test_result_record "SKIP" \
            "$TESTNAME SKIP - the requested headset microphone was not visible in the capture PCM inventory and amixer is unavailable for mixer discovery, provision alsa-utils or supply --alsa-device"
        test_result_finish
    fi

    route_reason="$(tail -n 1 "$route_discovery_log" 2>/dev/null)"
    [ -n "$route_reason" ] || route_reason="no matching runtime route evidence"
    test_result_record "FAIL" \
        "$TESTNAME FAIL - requested headset microphone route was not discovered, reason='$route_reason', verify the capture PCM and mixer inventory or supply --mixer-control, --mixer-value, --pcm-label, or --alsa-device, artifact=$route_discovery_log"
    test_result_finish
fi

test_result_record "PASS" \
    "Discovered the requested headset microphone route, device=$AUDIO_ALSA_CAPTURE_ROUTE_DEVICE_NAME source=$AUDIO_ALSA_CAPTURE_ROUTE_DISCOVERY"

if ! audio_alsa_prepare_capture_route 2>>"$route_discovery_log"; then
    route_reason="$(tail -n 1 "$route_discovery_log" 2>/dev/null)"
    [ -n "$route_reason" ] || route_reason="mixer preparation failed without details"
    test_result_record "FAIL" \
        "$TESTNAME FAIL - headset microphone route was discovered but could not be enabled, reason='$route_reason', verify mixer permissions, control value, and route topology, artifact=$route_discovery_log"
    test_result_finish
fi

{
    printf 'source\t%s\n' "$SOURCE"
    printf 'card\t%s\n' "$AUDIO_ALSA_CAPTURE_ROUTE_CARD"
    printf 'device\t%s\n' "$AUDIO_ALSA_CAPTURE_ROUTE_DEVICE"
    printf 'capture_device\t%s\n' "$AUDIO_ALSA_CAPTURE_ROUTE_DEVICE_NAME"
    printf 'pcm_label\t%s\n' "$AUDIO_ALSA_CAPTURE_ROUTE_PCM_LABEL"
    printf 'mixer_control\t%s\n' "$AUDIO_ALSA_CAPTURE_ROUTE_CONTROL"
    printf 'mixer_value\t%s\n' "$AUDIO_ALSA_CAPTURE_ROUTE_VALUE"
    printf 'previous_mixer_value\t%s\n' "$AUDIO_ALSA_CAPTURE_ROUTE_PREVIOUS_VALUE"
    printf 'discovery\t%s\n' "$AUDIO_ALSA_CAPTURE_ROUTE_DISCOVERY"
} >"$LOGDIR/route_selection.tsv"

capture_output="$LOGDIR/headset_microphone.wav"
capture_log="$LOGDIR/arecord_headset_microphone.log"
capture_timeout=$((DURATION + 10))
log_info "Recording mono audio from $AUDIO_ALSA_CAPTURE_ROUTE_DEVICE_NAME, pcm=$AUDIO_ALSA_CAPTURE_ROUTE_PCM_LABEL control='$AUDIO_ALSA_CAPTURE_ROUTE_CONTROL'"

rm -f "$capture_output"

audio_exec_with_timeout "${capture_timeout}s" \
    env LC_ALL=C \
    arecord \
    -q \
    -D "$AUDIO_ALSA_CAPTURE_ROUTE_DEVICE_NAME" \
    -f S16_LE \
    -r 48000 \
    -c 1 \
    -d "$DURATION" \
    "$capture_output" >"$capture_log" 2>&1
capture_rc=$?

if audio_validate_recording_result \
    "$capture_output" \
    mic \
    48000 \
    1 \
    "$DURATION" \
    "$capture_rc" \
    "${capture_timeout}s" \
    "$capture_log"; then
    test_result_record "PASS" \
        "Headset microphone capture produced a valid active WAV through $AUDIO_ALSA_CAPTURE_ROUTE_DEVICE_NAME"
else
    test_result_record "FAIL" \
        "$TESTNAME FAIL - headset microphone capture validation failed on $AUDIO_ALSA_CAPTURE_ROUTE_DEVICE_NAME, rc=$capture_rc, verify the connected headset microphone and injected audio signal, validation='$AUDIO_WAV_VALIDATION_SUMMARY', artifact=$capture_log"
fi

if [ "$DMESG_SCAN" -eq 1 ]; then
    scan_dmesg_errors \
        "$LOGDIR" \
        'snd|asoc|audio|lpass|q6|codec|jack|headset|mic' \
        'dummy regulator|supply [^ ]+ not found|using dummy regulator|probe deferred' || true

    if [ -s "$LOGDIR/dmesg_errors.log" ]; then
        log_warn "Audio-related kernel errors were captured in $LOGDIR/dmesg_errors.log"
    fi
fi

if ! audio_alsa_restore_capture_route; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - capture finished but the previous mixer state could not be restored, control='$AUDIO_ALSA_CAPTURE_ROUTE_CONTROL'"
fi

test_result_finish
