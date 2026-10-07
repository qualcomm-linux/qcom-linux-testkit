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

TESTNAME="AudioRoutePlayback"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"

ROUTE="${AUDIO_ROUTE:-}"
DYNAMIC_MIXER_CONTROL="${AUDIO_MIXER_CONTROL:-}"
DYNAMIC_MIXER_VALUE="${AUDIO_MIXER_VALUE:-}"
DYNAMIC_PCM_LABEL="${AUDIO_PCM_LABEL:-}"
DYNAMIC_ALSA_DEVICE="${AUDIO_ALSA_DEVICE:-}"
DURATION="${PLAYBACK_DURATION:-3}"
DMESG_SCAN="${DMESG_SCAN:-1}"
RES_SUFFIX="${RES_SUFFIX:-}"
RESULT_TESTNAME="${LAVA_TESTCASE_ID:-$TESTNAME}"
ARG_ERROR=""
LOGDIR=""
RESULT_SCOPE=""

# Print the supported route-playback CLI and its environment equivalents.
usage() {
    cat <<EOF_USAGE
Usage: $0 --route {hdmi|displayport|dp|edp|headphones|headset|3.5mm} [options]

Options:
  --route ROUTE             Required external playback route
  --mixer-control NAME      Optional exact mixer control for opaque topologies
  --mixer-value VALUE       Value applied to the selected control, default: 1
  --pcm-label LABEL         Optional exact PCM label associated with the route
  --alsa-device DEVICE      Optional ALSA endpoint such as plughw:0,2
  --duration SECONDS        Playback duration from 1 to 60, default: 3
  --dmesg-scan {0|1}        Capture audio-related kernel log evidence, default: 1
  --no-dmesg                Disable kernel log evidence capture
  --res-suffix SUFFIX       Generate AudioRoutePlayback_SUFFIX.res
  --lava-testcase-id ID     Test name written to the result file
  --help, -h                Show this help

Environment equivalents:
  AUDIO_ROUTE
  AUDIO_MIXER_CONTROL
  AUDIO_MIXER_VALUE
  AUDIO_PCM_LABEL
  AUDIO_ALSA_DEVICE
  PLAYBACK_DURATION
  DMESG_SCAN
  RES_SUFFIX
  LAVA_TESTCASE_ID
EOF_USAGE
}

# Parse command-line arguments without performing target-side mutations.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --route)
                if [ "$#" -lt 2 ]; then
                    ARG_ERROR="--route requires a value"
                    return 1
                fi
                ROUTE="$2"
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

# Restore the exact mixer control changed by this test.
audio_route_playback_cleanup() {
    if ! audio_alsa_restore_playback_route; then
        log_warn "Could not restore audio route mixer state, control=${AUDIO_ALSA_ROUTE_CONTROL:-unknown}"
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

case "$ROUTE" in
    hdmi)
        ;;
    displayport|dp|edp)
        ROUTE="displayport"
        ;;
    headphones|headphone|headset|3.5mm)
        ROUTE="headphones"
        ;;
    '')
        test_result_record "FAIL" \
            "$TESTNAME FAIL - no route selected, use --route hdmi, displayport, or headphones"
        test_result_finish
        ;;
    *)
        test_result_record "FAIL" \
            "$TESTNAME FAIL - invalid route '$ROUTE', expected HDMI, DP/eDP, or headphones"
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
            "$TESTNAME FAIL - invalid playback duration '$DURATION', expected a positive integer"
        test_result_finish
        ;;
esac

if [ "$DURATION" -le 0 ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - invalid playback duration '$DURATION', expected a positive integer"
    test_result_finish
fi

if [ "$DURATION" -gt 60 ]; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - playback duration '$DURATION' exceeds the 60 second safety limit"
    test_result_finish
fi

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
trap audio_route_playback_cleanup EXIT

log_info "Starting $TESTNAME, route=$ROUTE duration=${DURATION}s mixer_control='${DYNAMIC_MIXER_CONTROL:-auto}' mixer_value='${DYNAMIC_MIXER_VALUE:-auto}' pcm_label='${DYNAMIC_PCM_LABEL:-auto}' alsa_device='${DYNAMIC_ALSA_DEVICE:-auto}'"
log_info "Retaining route-playback artifacts in $LOGDIR"

audio_alsa_capture_playback_route_inventory \
    "$LOGDIR/audio_route_inventory.log" || true

if ! command -v aplay >/dev/null 2>&1; then
    test_result_record "SKIP" \
        "$TESTNAME SKIP - required ALSA playback utility is missing: aplay, provision alsa-utils in the image"
    test_result_finish
fi

route_discovery_log="$LOGDIR/route_discovery.log"
if ! audio_alsa_find_playback_route \
    "$ROUTE" \
    "$DYNAMIC_MIXER_CONTROL" \
    "$DYNAMIC_MIXER_VALUE" \
    "$DYNAMIC_PCM_LABEL" \
    "$DYNAMIC_ALSA_DEVICE" \
    >"$LOGDIR/route_mapping.txt" 2>"$route_discovery_log"; then
    if ! command -v amixer >/dev/null 2>&1; then
        test_result_record "SKIP" \
            "$TESTNAME SKIP - the requested $ROUTE route was not visible in the PCM inventory and amixer is unavailable for mixer discovery, provision alsa-utils or supply --alsa-device"
        test_result_finish
    fi

    route_reason="$(tail -n 1 "$route_discovery_log" 2>/dev/null)"
    [ -n "$route_reason" ] || route_reason="no matching runtime route evidence"
    test_result_record "FAIL" \
        "$TESTNAME FAIL - requested $ROUTE route was not discovered, reason='$route_reason', verify the runtime PCM and mixer inventory or supply --mixer-control, --mixer-value, --pcm-label, or --alsa-device, artifact=$route_discovery_log"
    test_result_finish
fi

test_result_record "PASS" \
    "Discovered the requested $ROUTE route, device=$AUDIO_ALSA_ROUTE_PLAYBACK_DEVICE source=$AUDIO_ALSA_ROUTE_DISCOVERY"

if ! audio_alsa_prepare_playback_route 2>>"$route_discovery_log"; then
    route_reason="$(tail -n 1 "$route_discovery_log" 2>/dev/null)"
    [ -n "$route_reason" ] || route_reason="mixer preparation failed without details"
    test_result_record "FAIL" \
        "$TESTNAME FAIL - requested $ROUTE route was discovered but could not be enabled, reason='$route_reason', verify mixer permissions, control value, and route topology, artifact=$route_discovery_log"
    test_result_finish
fi

{
    printf 'route\t%s\n' "$ROUTE"
    printf 'card\t%s\n' "$AUDIO_ALSA_ROUTE_CARD"
    printf 'device\t%s\n' "$AUDIO_ALSA_ROUTE_DEVICE"
    printf 'playback_device\t%s\n' "$AUDIO_ALSA_ROUTE_PLAYBACK_DEVICE"
    printf 'pcm_label\t%s\n' "$AUDIO_ALSA_ROUTE_PCM_LABEL"
    printf 'mixer_control\t%s\n' "$AUDIO_ALSA_ROUTE_CONTROL"
    printf 'mixer_value\t%s\n' "$AUDIO_ALSA_ROUTE_VALUE"
    printf 'previous_mixer_value\t%s\n' "$AUDIO_ALSA_ROUTE_PREVIOUS_VALUE"
    printf 'discovery\t%s\n' "$AUDIO_ALSA_ROUTE_DISCOVERY"
} >"$LOGDIR/route_selection.tsv"

playback_log="$LOGDIR/aplay_${ROUTE}.log"
playback_signal="$LOGDIR/playback_tone_1khz_u8_stereo.raw"
playback_timeout=$((DURATION + 10))
if ! audio_generate_u8_stereo_tone \
    "$playback_signal" "$DURATION" 48000 1000 \
    2>"$LOGDIR/playback_signal_generation.log"; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - could not generate the bounded 1 kHz playback signal, artifact=$LOGDIR/playback_signal_generation.log"
    test_result_finish
fi

log_info "Playing a 1 kHz stereo signal through $AUDIO_ALSA_ROUTE_PLAYBACK_DEVICE, pcm=$AUDIO_ALSA_ROUTE_PCM_LABEL control='$AUDIO_ALSA_ROUTE_CONTROL'"

audio_exec_with_timeout "${playback_timeout}s" \
    env LC_ALL=C \
    aplay \
    -D "$AUDIO_ALSA_ROUTE_PLAYBACK_DEVICE" \
    -t raw \
    -f U8 \
    -r 48000 \
    -c 2 \
    -d "$DURATION" \
    "$playback_signal" >"$playback_log" 2>&1
playback_rc=$?

if [ "$playback_rc" -eq 0 ] &&
   grep -q 'Playing raw data' "$playback_log"; then
    test_result_record "PASS" \
        "$ROUTE playback completed with a 1 kHz signal through $AUDIO_ALSA_ROUTE_PLAYBACK_DEVICE"
else
    test_result_record "FAIL" \
        "$TESTNAME FAIL - $ROUTE playback did not complete on $AUDIO_ALSA_ROUTE_PLAYBACK_DEVICE, rc=$playback_rc, verify the connected display or 3.5 mm fixture and inspect $playback_log"
fi

if [ "$DMESG_SCAN" -eq 1 ]; then
    scan_dmesg_errors \
        "$LOGDIR" \
        'snd|asoc|audio|lpass|q6|display|hdmi|codec' \
        'dummy regulator|supply [^ ]+ not found|using dummy regulator|probe deferred' || true

    if [ -s "$LOGDIR/dmesg_errors.log" ]; then
        log_warn "Audio-related kernel errors were captured in $LOGDIR/dmesg_errors.log"
    fi
fi

if ! audio_alsa_restore_playback_route; then
    test_result_record "FAIL" \
        "$TESTNAME FAIL - playback finished but the previous mixer state could not be restored, control='$AUDIO_ALSA_ROUTE_CONTROL'"
fi

test_result_finish
