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

TESTNAME="Audio_DSP_Idle_Recovery_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

EXERCISE="0"
CARD_ID=""
PCM=""
PROCESSOR=""
TIMEOUT="60"
PLAY_SECONDS="2"
RATE="48000"
CHANNELS="2"

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate ALSA playback after a selected DSP synthetic crash.
  --exercise <value>  Explicit opt-in on an isolated target
  --card-id <value>  Stable ALSA card ID, never a numeric first-card fallback
  --pcm <value>  Hardware playback PCM number for the provisioned route
  --processor <value>  Exact runtime remoteproc name or owner device name
  --timeout <value>  Per-operation and recovery deadline in seconds
  --play-seconds <value>  Baseline and recovered silence playback duration
  --rate <value>  Configured S16_LE sample rate
  --channels <value>  Configured channel count
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
            --card-id)
                CARD_ID="$2"
                ;;
            --pcm)
                PCM="$2"
                ;;
            --processor)
                PROCESSOR="$2"
                ;;
            --timeout)
                TIMEOUT="$2"
                ;;
            --play-seconds)
                PLAY_SECONDS="$2"
                ;;
            --rate)
                RATE="$2"
                ;;
            --channels)
                CHANNELS="$2"
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
if [ "$EXERCISE" = 0 ]; then
    test_result_finish SKIP "DSP crash testing requires an isolated target and --exercise 1"
fi
for value in "$TIMEOUT" "$PLAY_SECONDS" "$RATE" "$CHANNELS"; do
    if ! printf '%s\n' "$value" | grep -Eq '^[1-9][0-9]{0,5}$'; then
        test_result_finish FAIL "Timeout, duration, rate and channel count must be positive integers"
    fi
done
if [ "$TIMEOUT" -gt 600 ] || [ "$PLAY_SECONDS" -lt 2 ] || [ "$PLAY_SECONDS" -ge "$TIMEOUT" ]; then
    test_result_finish FAIL "Use timeout at most 600, playback at least 2 seconds and shorter than timeout"
fi
if [ -z "$CARD_ID" ] || [ -z "$PCM" ] || [ -z "$PROCESSOR" ]; then
    test_result_finish SKIP "Supply stable --card-id, --pcm and the exact --processor for the provisioned audio route"
fi
if ! printf '%s\n' "$CARD_ID" | grep -Eq '^[A-Za-z0-9_]+$' ||
    ! printf '%s\n' "$PCM" | grep -Eq '^[0-9]+$' ||
    ! printf '%s\n' "$PROCESSOR" | grep -Eq '^[A-Za-z0-9_.:@-]+$' || [ "$PROCESSOR" = auto ]; then
    test_result_finish FAIL "Invalid card ID, PCM number or explicit processor selector"
fi
RPROC_RUNNER="$TOOLS/../suites/Kernel/Baseport/Remoteproc_Restart_Validation/run.sh"
if [ ! -r "$RPROC_RUNNER" ] || ! command -v test_run_start >/dev/null 2>&1; then
    test_result_finish SKIP "The shared Remoteproc_Restart_Validation crash implementation is not integrated"
fi
RPROC_RUNNER=$(readlink -f "$RPROC_RUNNER") || test_result_finish FAIL "Cannot resolve the remoteproc runner"
test_require_commands aplay alsactl amixer readlink stat sort cmp sleep id || test_result_finish
[ "$(id -u)" = 0 ] || test_result_finish SKIP "DSP injection and mixer restoration require root"
test_run_start
# shellcheck disable=SC2034 # Consumed by the shared recovery helpers.
TEST_RUN_TIMEOUT="$TIMEOUT"
# shellcheck disable=SC2034 # Consumed by the shared recovery helpers.
TEST_RUN_PROCESSORS="$PROCESSOR"
remoteproc_inventory || test_run_finish
if [ "$(wc -l <"$TEST_RUN_DIR/remoteprocs.selected")" -ne 1 ]; then
    test_run_finish FAIL "Processor selector must identify exactly one runtime remoteproc"
fi
IFS='|' read -r rproc name firmware state owner <"$TEST_RUN_DIR/remoteprocs.selected"
log_info "Selected remoteproc=$rproc name=$name firmware=$firmware"
[ "$state" = running ] || test_run_finish FAIL "Selected processor=$name is initially $state"
identity=$(audio_alsa_card_identity "$CARD_ID") || test_run_finish SKIP "Selected ALSA card is absent or ambiguous"
IFS='|' read -r card_index card_device card_inode <<EOF
$identity
EOF
if ! audio_alsa_card_uses_remoteproc "$card_device" "$owner"; then
    test_run_finish SKIP "No runtime component link proves card=$CARD_ID belongs to processor=$name"
fi
if [ ! -d "/proc/asound/card$card_index/pcm${PCM}p" ]; then
    test_run_finish SKIP "Selected hardware playback PCM=$PCM is absent on card=$CARD_ID"
fi
# Only query configured mixer state. The job must provision a working route.
if ! test_run_command mixer-save alsactl -f "$TEST_RUN_DIR/mixer.state" store "$CARD_ID" ||
    [ ! -s "$TEST_RUN_DIR/mixer.state" ]; then
    test_run_finish FAIL "Cannot save the selected card mixer state before injection"
fi
if ! test_run_command controls-before amixer -c "$CARD_ID" controls; then
    test_run_finish FAIL "Cannot capture selected card controls"
fi
sed 's/^numid=[0-9][0-9]*,//' "$TEST_RUN_DIR/controls-before.log" | sort >"$TEST_RUN_DIR/controls-before.sorted"
test_capture_kernel_log baseline-before || test_run_finish SKIP "Baseline playback requires readable kernel health evidence"
if ! audio_alsa_validate_raw_playback baseline "$CARD_ID" "$PCM" "$PLAY_SECONDS" "$RATE" "$CHANNELS"; then
    test_run_finish FAIL "Baseline playback failed, no DSP crash was injected"
fi
test_capture_kernel_log baseline-after || test_run_finish FAIL "Kernel evidence was lost during baseline playback"
if ! test_check_kernel_delta baseline-before baseline-after \
    'BUG:|WARNING:|Oops:|panic|Call trace:|crash detected|fatal error|watchdog (bite|received|interrupt)'; then
    test_run_finish FAIL "Baseline playback produced faulty or incomplete kernel evidence, no DSP crash was injected"
fi
# A baseline success is a prerequisite, not a completed recovery verdict.
# shellcheck disable=SC2034 # Consumed by the shared recovery helpers.
AUDIO_RECOVERY_CARD="$CARD_ID"
# shellcheck disable=SC2034 # Consumed by the shared recovery helpers.
AUDIO_RECOVERY_DEVICE="$card_device"
# shellcheck disable=SC2034 # Consumed by the shared recovery helpers.
AUDIO_RECOVERY_RESTORE=0
# shellcheck disable=SC2034 # Read by the shared test_run cleanup.
TEST_RUN_CLEANUP=audio_alsa_restore_saved_state
# shellcheck disable=SC2034 # Shared cleanup checks kernel evidence around mixer restoration.
TEST_RUN_CLEANUP_KERNEL_PATTERN='BUG:|WARNING:|Oops:|panic|Call trace:|crash detected|fatal error|watchdog (bite|received|interrupt)'

# shellcheck disable=SC2034 # Consumed by the shared recovery helpers.
AUDIO_RECOVERY_RESTORE=1
mkdir -p "$TEST_RUN_DIR/remoteproc" || test_run_finish FAIL "Cannot create isolated child evidence"
# Reuse the kernel suite's recovery-policy, event-sequence and child-health checks.
# Its own bounded operations include restoration, allow those cleanup deadlines.
# shellcheck disable=SC2034 # Consumed by the shared recovery helpers.
TEST_RUN_TIMEOUT=$((TIMEOUT * 6 + 30))
child_status=0
# shellcheck disable=SC2016 # Arguments expand inside the bounded child shell.
test_run_command crash-recovery sh -c '
    cd "$1" || exit 1
    exec sh "$2" --exercise 1 --processors "$3" --mode crash --rounds 1 --timeout "$4"
' sh "$TEST_RUN_DIR/remoteproc" "$RPROC_RUNNER" "$PROCESSOR" "$TIMEOUT" || child_status=$?
# shellcheck disable=SC2034 # Consumed by the shared recovery helpers.
TEST_RUN_TIMEOUT="$TIMEOUT"
child_result="$TEST_RUN_DIR/remoteproc/Remoteproc_Restart_Validation.res"
if [ "$child_status" -ne 0 ] || [ ! -r "$child_result" ] ||
    ! awk 'NR!=1 || NF!=2 || $1!="Remoteproc_Restart_Validation" || $2!~/^(PASS|FAIL|SKIP)$/ {bad=1} END {exit (bad || NR!=1)}' "$child_result"; then
    test_run_finish FAIL "Remoteproc crash child failed or produced invalid/missing evidence"
fi
child_verdict=$(awk '{print $2}' "$child_result")
case "$child_verdict" in
    FAIL)
        test_run_finish FAIL "Remoteproc crash/recovery failed, genuine firmware and kernel faults remain failures"
        ;;
    SKIP)
        test_run_finish SKIP "Remoteproc crash injection was not exercised, inspect child prerequisites"
        ;;
esac

identity=$(audio_alsa_card_identity "$CARD_ID") || test_run_finish FAIL "Previously working card did not return after DSP recovery"
IFS='|' read -r restored_index restored_device restored_inode <<EOF
$identity
EOF
log_info "Restored card index=$restored_index stable_id=$CARD_ID"
if [ "$restored_device" != "$card_device" ] || [ "$restored_inode" = "$card_inode" ]; then
    test_run_finish FAIL "The selected sound card was not re-registered on the same runtime device"
fi
if ! audio_alsa_card_uses_remoteproc "$restored_device" "$owner"; then
    test_run_finish FAIL "Restored sound card lost its selected DSP component link"
fi
if ! audio_alsa_restore_saved_state || ! test_run_command controls-after amixer -c "$CARD_ID" controls; then
    test_run_finish FAIL "Cannot restore mixer state or capture recovered controls"
fi
sed 's/^numid=[0-9][0-9]*,//' "$TEST_RUN_DIR/controls-after.log" | sort >"$TEST_RUN_DIR/controls-after.sorted"
if ! cmp -s "$TEST_RUN_DIR/controls-before.sorted" "$TEST_RUN_DIR/controls-after.sorted"; then
    test_run_finish FAIL "Selected ALSA control inventory changed after DSP recovery"
fi
test_capture_kernel_log playback-before || test_run_finish FAIL "Post-recovery playback lacks kernel health evidence"
if ! audio_alsa_validate_raw_playback recovered "$CARD_ID" "$PCM" "$PLAY_SECONDS" "$RATE" "$CHANNELS"; then
    test_result_record FAIL "Playback did not recover on the same card and PCM"
else
    # shellcheck disable=SC2034 # Required by shared finalization.
    TEST_RUN_VALIDATED=1
    test_result_record PASS "Selected DSP recovered, card controls restored and hardware playback completed"
fi
test_capture_kernel_log playback-after || test_run_finish FAIL "Kernel evidence lost during recovered playback"
if ! test_check_kernel_delta playback-before playback-after \
    'BUG:|WARNING:|Oops:|panic|Call trace:|crash detected|fatal error|watchdog (bite|received|interrupt)|(ASoC|snd|q6|audioreach).*(failed|timed out)'; then
    test_result_record FAIL "Recovered playback kernel health is faulty or incomplete"
fi
test_run_finish
