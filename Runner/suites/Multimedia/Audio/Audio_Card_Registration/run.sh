#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Audio card registration validation:
# - validates ALSA sound card registration
# - validates /dev/snd/controlC<N> nodes
# - optionally validates PCM/playback/capture entries
# - optionally prepares Debian or CentOS AudioReach packages with --overlay
# - does not start/restart PipeWire, PulseAudio, ADSP, or remoteproc
# - does not play or record audio

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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/audio_common.sh"

if [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_pkg_provider.sh"
fi

TESTNAME="Audio_Card_Registration"

# Only the explicit --overlay option enables AudioReach package preparation.
# Ignore inherited values so native/base mode remains the default.
AUDIO_OVERLAY_REQUESTED=0
AUDIO_EARLY_HELP_REQUESTED=0

AUDIO_CARD_WAIT_SECS="${AUDIO_CARD_WAIT_SECS:-30}"
AUDIO_CARD_REQUIRED="${AUDIO_CARD_REQUIRED:-auto}"
AUDIO_CARD_MATCH="${AUDIO_CARD_MATCH:-}"
REQUIRE_CONTROL_NODE="${REQUIRE_CONTROL_NODE:-1}"
REQUIRE_PCM_NODE="${REQUIRE_PCM_NODE:-1}"
REQUIRE_PLAYBACK_PCM="${REQUIRE_PLAYBACK_PCM:-1}"
REQUIRE_CAPTURE_PCM="${REQUIRE_CAPTURE_PCM:-1}"
DMESG_SCAN="${DMESG_SCAN:-1}"
VERBOSE="${VERBOSE:-0}"

usage() {
    cat <<EOF_USAGE
Usage: $0 [options]

Options:
  --overlay
      On Debian or CentOS, ensure the Qualcomm AudioReach package set before
      validating ALSA card registration. Without this flag, use the
      native/base audio stack. This test never starts or restarts PipeWire.

  --wait-secs N
      Wait time for ALSA sound card registration.
      Default: 30

  --required {auto|required|optional}
      auto : infer whether audio is expected from DT/sysfs.
      required : fail if no valid ALSA card is registered.
      optional : skip if no valid ALSA card is registered.
      Default: auto

  --card-match TEXT
      Optional case-insensitive substring to match card id/description.
      Example: --card-match qcom

  --require-control-node {0|1}
      Require /dev/snd/controlC<N> for matched cards.
      Default: 1

  --require-pcm-node {0|1}
      Require at least one /proc/asound/pcm entry for matched cards.
      Default: 1

  --require-playback-pcm {0|1}
      Require playback PCM entry for matched cards.
      Default: 1

  --require-capture-pcm {0|1}
      Require capture PCM entry for matched cards.
      Default: 1

  --dmesg-scan {0|1}
      Enable or disable audio-related dmesg scan.
      Default: 1

  --no-dmesg
      Disable audio-related dmesg scan.

  --verbose
      Enable verbose mode.

  --help|-h
      Show this help.

Examples:
  $0
  $0 --overlay
  $0 --required required
  $0 --card-match qcom
  $0 --require-pcm-node 1
  $0 --require-playback-pcm 1 --require-capture-pcm 1
EOF_USAGE
}

# Pre-parse the privileged package-selection and help options without
# consuming the normal parser input.
for audio_arg in "$@"; do
    case "$audio_arg" in
        --overlay)
            AUDIO_OVERLAY_REQUESTED=1
            ;;
        --help|-h)
            AUDIO_EARLY_HELP_REQUESTED=1
            ;;
    esac
done

export AUDIO_OVERLAY_REQUESTED

# Help must not install packages, modify group membership, create result files,
# or start a user manager.
if [ "$AUDIO_EARLY_HELP_REQUESTED" -eq 1 ]; then
    usage
    exit 0
fi

# Resolve absolute output paths. The complete runner remains the root
# orchestrator on Debian, so logs, results, inventory, and dmesg evidence stay
# root-owned.
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
LOGDIR="$SCRIPT_DIR/results/$TESTNAME"

# Package preparation is privileged and runs exactly once in the root runner.
if ! command -v audio_prepare_test_packages >/dev/null 2>&1; then
    log_fail "$TESTNAME FAIL: required helper is unavailable: audio_prepare_test_packages"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

audio_prepare_test_packages "$AUDIO_OVERLAY_REQUESTED"
audio_prepare_rc=$?

case "$audio_prepare_rc" in
    0)
        ;;
    2)
        log_skip "$TESTNAME SKIP: AudioReach kernel package changed; reboot required"
        echo "$TESTNAME SKIP" > "$RES_FILE"
        exit 0
        ;;
    *)
        log_fail "$TESTNAME FAIL: audio package preparation failed"
        echo "$TESTNAME FAIL" > "$RES_FILE"
        exit 1
        ;;
esac

# Prepare only the Debian Audio account and group membership. This ALSA-only
# testcase does not require a systemd user manager and does not re-execute the
# complete runner as debian.
if ! command -v audio_prepare_debian_audio_environment >/dev/null 2>&1; then
    log_fail "$TESTNAME FAIL: required helper is unavailable: audio_prepare_debian_audio_environment"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

if ! audio_prepare_debian_audio_environment 0; then
    log_fail "$TESTNAME FAIL: Debian Audio environment preparation failed"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

if ! command -v audio_run_helper_as_test_user >/dev/null 2>&1; then
    log_fail "$TESTNAME FAIL: required helper is unavailable: audio_run_helper_as_test_user"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

if ! mkdir -p "$LOGDIR"; then
    log_fail "$TESTNAME FAIL: failed to create log directory: $LOGDIR"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

if ! chmod 0755 "$LOGDIR"; then
    log_fail "$TESTNAME FAIL: failed to make log directory readable for ALSA user validation"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

if ! : > "$RES_FILE"; then
    log_fail "$TESTNAME FAIL: failed to initialize result file: $RES_FILE"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --overlay)
            AUDIO_OVERLAY_REQUESTED=1
            export AUDIO_OVERLAY_REQUESTED
            shift
            ;;
        --wait-secs)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --wait-secs requires an argument" >&2
                exit 1
            fi
            AUDIO_CARD_WAIT_SECS="$2"
            shift 2
            ;;
        --required)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --required requires an argument" >&2
                exit 1
            fi
            AUDIO_CARD_REQUIRED="$2"
            shift 2
            ;;
        --card-match)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --card-match requires an argument" >&2
                exit 1
            fi
            AUDIO_CARD_MATCH="$2"
            shift 2
            ;;
        --require-control-node)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --require-control-node requires an argument" >&2
                exit 1
            fi
            REQUIRE_CONTROL_NODE="$2"
            shift 2
            ;;
        --require-pcm-node)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --require-pcm-node requires an argument" >&2
                exit 1
            fi
            REQUIRE_PCM_NODE="$2"
            shift 2
            ;;
        --require-playback-pcm)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --require-playback-pcm requires an argument" >&2
                exit 1
            fi
            REQUIRE_PLAYBACK_PCM="$2"
            shift 2
            ;;
        --require-capture-pcm)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --require-capture-pcm requires an argument" >&2
                exit 1
            fi
            REQUIRE_CAPTURE_PCM="$2"
            shift 2
            ;;
        --dmesg-scan)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --dmesg-scan requires an argument" >&2
                exit 1
            fi
            DMESG_SCAN="$2"
            shift 2
            ;;
        --no-dmesg)
            DMESG_SCAN=0
            shift
            ;;
        --verbose)
            VERBOSE=1
            export VERBOSE
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[WARN] Unknown option: $1" >&2
            shift
            ;;
    esac
done

case "$AUDIO_CARD_WAIT_SECS" in
    ''|*[!0-9]*)
        log_warn "Invalid AUDIO_CARD_WAIT_SECS='$AUDIO_CARD_WAIT_SECS', using 30"
        AUDIO_CARD_WAIT_SECS=30
        ;;
esac

case "$AUDIO_CARD_REQUIRED" in
    auto|required|optional)
        ;;
    *)
        log_warn "Invalid AUDIO_CARD_REQUIRED='$AUDIO_CARD_REQUIRED', using auto"
        AUDIO_CARD_REQUIRED="auto"
        ;;
esac

case "$REQUIRE_CONTROL_NODE" in
    0|1)
        ;;
    *)
        log_warn "Invalid REQUIRE_CONTROL_NODE='$REQUIRE_CONTROL_NODE', using 1"
        REQUIRE_CONTROL_NODE=1
        ;;
esac

case "$REQUIRE_PCM_NODE" in
    0|1)
        ;;
    *)
        log_warn "Invalid REQUIRE_PCM_NODE='$REQUIRE_PCM_NODE', using 0"
        REQUIRE_PCM_NODE=0
        ;;
esac

case "$REQUIRE_PLAYBACK_PCM" in
    0|1)
        ;;
    *)
        log_warn "Invalid REQUIRE_PLAYBACK_PCM='$REQUIRE_PLAYBACK_PCM', using 0"
        REQUIRE_PLAYBACK_PCM=0
        ;;
esac

case "$REQUIRE_CAPTURE_PCM" in
    0|1)
        ;;
    *)
        log_warn "Invalid REQUIRE_CAPTURE_PCM='$REQUIRE_CAPTURE_PCM', using 0"
        REQUIRE_CAPTURE_PCM=0
        ;;
esac

case "$DMESG_SCAN" in
    0|1)
        ;;
    *)
        log_warn "Invalid DMESG_SCAN='$DMESG_SCAN', using 1"
        DMESG_SCAN=1
        ;;
esac

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
if ! cd "$test_path"; then
    log_fail "cd failed: $test_path"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies awk grep sed cat ls find sleep wc chmod; then
    log_skip "$TESTNAME SKIP: missing required dependencies"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

# This testcase intentionally performs no PipeWire/PulseAudio runtime setup.
# Do not call audio_prepare_overlay_runtime(), audio_restart_pipewire_service(),
# or audio_restart_services_best_effort() here. Only the ALSA node validation
# helpers below are executed as the Debian Audio user.

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Config, AUDIO_OVERLAY_REQUESTED=$AUDIO_OVERLAY_REQUESTED AUDIO_CARD_WAIT_SECS=$AUDIO_CARD_WAIT_SECS AUDIO_CARD_REQUIRED=$AUDIO_CARD_REQUIRED AUDIO_CARD_MATCH=${AUDIO_CARD_MATCH:-<unset>}"
log_info "Config, REQUIRE_CONTROL_NODE=$REQUIRE_CONTROL_NODE REQUIRE_PCM_NODE=$REQUIRE_PCM_NODE REQUIRE_PLAYBACK_PCM=$REQUIRE_PLAYBACK_PCM REQUIRE_CAPTURE_PCM=$REQUIRE_CAPTURE_PCM DMESG_SCAN=$DMESG_SCAN"

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform >/dev/null 2>&1 || true
    log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='${PLATFORM_KERNEL:-unknown}' arch='${PLATFORM_ARCH:-unknown}'"
else
    log_info "Platform Details: kernel='$(uname -r 2>/dev/null || echo unknown)' arch='$(uname -m 2>/dev/null || echo unknown)'"
fi

audio_expected=0

case "$AUDIO_CARD_REQUIRED" in
    required)
        audio_expected=1
        log_info "Audio card registration is marked required"
        ;;
    optional)
        audio_expected=0
        log_info "Audio card registration is marked optional"
        ;;
    auto)
        if audio_card_dt_audio_expected; then
            audio_expected=1
            log_info "Audio card registration appears expected from DT/sysfs"
        else
            audio_expected=0
            log_info "Audio card registration does not appear expected from DT/sysfs"
        fi
        ;;
esac

audio_card_log_alsa_inventory

if ! audio_card_wait_for_cards "$AUDIO_CARD_WAIT_SECS" "$AUDIO_CARD_MATCH"; then
    audio_card_log_alsa_inventory

    if [ "$audio_expected" -eq 1 ]; then
        if [ -n "$AUDIO_CARD_MATCH" ]; then
            log_fail "$TESTNAME FAIL: no valid ALSA card matched '$AUDIO_CARD_MATCH'"
        else
            log_fail "$TESTNAME FAIL: no valid ALSA sound card registered"
        fi

        if [ "$DMESG_SCAN" -eq 1 ]; then
            audio_card_dmesg_scan "$LOGDIR"
        fi

        echo "$TESTNAME FAIL" > "$RES_FILE"
        exit 0
    fi

    if [ -n "$AUDIO_CARD_MATCH" ]; then
        log_skip "$TESTNAME SKIP: no valid ALSA card matched '$AUDIO_CARD_MATCH' and audio is optional"
    else
        log_skip "$TESTNAME SKIP: no valid ALSA sound card registered and audio is optional"
    fi

    if [ "$DMESG_SCAN" -eq 1 ]; then
        audio_card_dmesg_scan "$LOGDIR"
    fi

    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

MATCHED_CARDS_FILE="$LOGDIR/matched_cards.txt"

if ! : > "$MATCHED_CARDS_FILE"; then
    log_fail "$TESTNAME FAIL: failed to initialize matched card inventory"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if ! chmod 0644 "$MATCHED_CARDS_FILE"; then
    log_fail "$TESTNAME FAIL: failed to make matched card inventory readable for the Audio user"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

if [ -n "$AUDIO_CARD_MATCH" ]; then
    audio_card_find_matching_cards "$AUDIO_CARD_MATCH" > "$MATCHED_CARDS_FILE"
else
    audio_card_get_valid_cards > "$MATCHED_CARDS_FILE"
fi

if [ ! -s "$MATCHED_CARDS_FILE" ]; then
    log_fail "$TESTNAME FAIL: card wait succeeded but no matched card inventory was captured"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

log_info "Matched ALSA cards:"
while IFS='|' read -r card_idx card_id card_desc || [ -n "$card_idx" ]; do
    [ -n "$card_idx" ] || continue
    log_info "[matched-card] index=${card_idx} id='${card_id}' desc='${card_desc}'"
done < "$MATCHED_CARDS_FILE"

test_failed=0

if [ "$REQUIRE_CONTROL_NODE" -eq 1 ]; then
    if ! audio_run_helper_as_test_user \
        audio_card_validate_control_nodes \
        "$MATCHED_CARDS_FILE"; then
        test_failed=1
    fi
else
    log_info "Skipping ALSA control node validation, REQUIRE_CONTROL_NODE=0"
fi

if [ "$REQUIRE_PCM_NODE" -eq 1 ]; then
    if ! audio_run_helper_as_test_user \
        audio_card_validate_pcm_nodes \
        "$MATCHED_CARDS_FILE" \
        "any"; then
        test_failed=1
    fi
else
    log_info "Skipping generic PCM node validation, REQUIRE_PCM_NODE=0"
fi

if [ "$REQUIRE_PLAYBACK_PCM" -eq 1 ]; then
    if ! audio_run_helper_as_test_user \
        audio_card_validate_pcm_nodes \
        "$MATCHED_CARDS_FILE" \
        "playback"; then
        test_failed=1
    fi
else
    log_info "Skipping playback PCM validation, REQUIRE_PLAYBACK_PCM=0"
fi

if [ "$REQUIRE_CAPTURE_PCM" -eq 1 ]; then
    if ! audio_run_helper_as_test_user \
        audio_card_validate_pcm_nodes \
        "$MATCHED_CARDS_FILE" \
        "capture"; then
        test_failed=1
    fi
else
    log_info "Skipping capture PCM validation, REQUIRE_CAPTURE_PCM=0"
fi

if [ "$DMESG_SCAN" -eq 1 ]; then
    audio_card_dmesg_scan "$LOGDIR"
fi

if [ "$test_failed" -eq 0 ]; then
    log_pass "$TESTNAME : PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
else
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
fi

log_info "------------------- Completed $TESTNAME Testcase --------------------------"
exit 0
