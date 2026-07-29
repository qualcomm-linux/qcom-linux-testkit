#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# ALSA audio helpers for Hamoa test scenarios on X1E80100-EVK platform.
# Provides mixer configuration and device management for ALSA-based audio tests.
#
# This library assumes functestlib.sh has been sourced by the calling script,
# which provides log_info, log_warn, log_error, log_pass, and log_fail functions.

# PCM device numbers for X1E80100-EVK audio hardware.
# These are topology-specific values that identify the PCM stream within the card
# and remain constant regardless of card registration order.
# The card index itself is resolved at runtime via resolve_hamoa_card_index().
HAMOA_PCM_HANDSET_PLAYBACK=1  # 4-way speaker system (WSA2 + WSA)
HAMOA_PCM_HEADSET_PLAYBACK=0  # Stereo headphones (RX codec)
HAMOA_PCM_HANDSET_CAPTURE=3   # Built-in microphone (VA_DMIC)
HAMOA_PCM_HEADSET_CAPTURE=2   # Headset microphone (SWR_MIC)

# Resolve the ALSA card index for the Hamoa audio hardware at runtime.
# Searches /proc/asound/cards for the X1E80100EVK card identifier so the
# correct card is selected regardless of registration order.
# Returns: card index on stdout, 0 on success, 1 if card not found or ambiguous
resolve_hamoa_card_index() {
    if [ ! -r /proc/asound/cards ]; then
        log_error "resolve_hamoa_card_index: /proc/asound/cards not readable"
        return 1
    fi

    card_index=$(grep -i "X1E80100EVK" /proc/asound/cards 2>/dev/null | awk '{print $1}')

    if [ -z "$card_index" ]; then
        log_error "Hamoa audio card (X1E80100EVK) not found in /proc/asound/cards"
        return 1
    fi

    # Reject ambiguous matches to avoid operating on the wrong card
    match_count=$(grep -ic "X1E80100EVK" /proc/asound/cards 2>/dev/null || echo 0)
    if [ "$match_count" -gt 1 ]; then
        log_error "Multiple Hamoa audio cards found - ambiguous card selection"
        return 1
    fi

    printf '%s\n' "$card_index"
}

# Retrieve ALSA device identifier by logical name.
# Resolves the card index at call time and combines it with the topology-specific
# PCM device number to construct the full plughw identifier.
# Args: $1 - device name (handset_playback, headset_playback, handset_capture, headset_capture)
# Returns: device identifier on stdout, 0 on success, 1 if unknown device or card not found
get_alsa_device() {
    card_index=$(resolve_hamoa_card_index) || return 1
    case "$1" in
        handset_playback) printf 'plughw:%s,%s\n' "$card_index" "$HAMOA_PCM_HANDSET_PLAYBACK"; return 0 ;;
        headset_playback) printf 'plughw:%s,%s\n' "$card_index" "$HAMOA_PCM_HEADSET_PLAYBACK"; return 0 ;;
        handset_capture)  printf 'plughw:%s,%s\n' "$card_index" "$HAMOA_PCM_HANDSET_CAPTURE";  return 0 ;;
        headset_capture)  printf 'plughw:%s,%s\n' "$card_index" "$HAMOA_PCM_HEADSET_CAPTURE";  return 0 ;;
        *) log_error "Unknown ALSA device name: $1"; return 1 ;;
    esac
}

# Expand device specification into list of individual devices for testing
# When "all" is specified, returns both handset and headset for sequential testing
# Args: $1 - device specification (handset, headset, or all)
# Returns: space-separated list of devices on stdout
expand_device_list() {
    case "$1" in
        all)
            # Test both devices sequentially to validate each audio path independently
            printf '%s\n' "handset headset"
            ;;
        handset|headset)
            # Single device specification passes through unchanged
            printf '%s\n' "$1"
            ;;
        *)
            log_error "Invalid device specification: $1"
            return 1
            ;;
    esac
}

# Verify that a specific ALSA PCM device exists and is accessible
# Args: $1 - ALSA device identifier (e.g., plughw:0,1 or hw:0,3)
#       $2 - direction: playback (default) or capture
# Returns: 0 if the exact card/device combination is found, 1 otherwise
check_alsa_device() {
    device="$1"
    direction="${2:-playback}"

    if [ -z "$device" ]; then
        log_error "check_alsa_device: device parameter is empty"
        return 1
    fi

    # Extract card and device numbers from identifiers like plughw:0,1 or hw:0,3
    card_num="$(printf '%s' "$device" | sed -n 's/.*:\([0-9][0-9]*\),.*/\1/p')"
    dev_num="$(printf '%s' "$device" | sed -n 's/.*:[0-9][0-9]*,\([0-9][0-9]*\).*/\1/p')"

    if [ -z "$card_num" ] || [ -z "$dev_num" ]; then
        log_error "check_alsa_device: cannot parse card/device from: $device"
        return 1
    fi

    # Use the appropriate enumeration command for the direction.
    # Capture devices must be validated with arecord -l, not aplay -l,
    # since a device number may exist for playback but not for capture.
    if [ "$direction" = "capture" ]; then
        if arecord -l 2>/dev/null | grep -q "card ${card_num}:.*device ${dev_num}:"; then
            log_info "ALSA capture device accessible: $device"
            return 0
        fi
    else
        if aplay -l 2>/dev/null | grep -q "card ${card_num}:.*device ${dev_num}:"; then
            log_info "ALSA playback device accessible: $device"
            return 0
        fi
    fi

    log_error "ALSA device not found: $device (direction=$direction)"
    return 1
}

# Validate that an audio file exists and has non-zero size
# Args: $1 - path to audio file
# Returns: 0 if valid, 1 otherwise
validate_audio_file() {
    file="$1"
    if [ ! -f "$file" ]; then
        log_error "Audio file not found: $file"
        return 1
    fi

    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -eq 0 ]; then
        log_error "Audio file is empty: $file"
        return 1
    fi

    log_info "Audio file validated: $file ($size bytes)"
    return 0
}

# Validate that a recorded audio file meets minimum size requirements
# Args: $1 - path to recording file
#       $2 - minimum size in bytes (default: 1024 bytes, same as AudioRecord)
# Returns: 0 if valid, 1 otherwise
validate_recording() {
    file="$1"
    min_size="${2:-1024}"

    validate_audio_file "$file" || return 1

    size=$(file_size_bytes "$file" 2>/dev/null || echo 0)
    if [ "$size" -lt "$min_size" ]; then
        log_error "Recording file too small: $size bytes (expected >= $min_size)"
        return 1
    fi

    log_info "Recording validated: $file ($size bytes)"
    return 0
}

# Verify that a specific ALSA mixer control is set to the expected value.
# Resolves the card index at runtime for the mixer query.
# Args: $1 - mixer control name (e.g., 'WSA2 WSA RX0 MUX')
#       $2 - expected value (e.g., 'AIF1_PB' or 'on' or '1')
# Returns: 0 if control matches expected value, 1 otherwise
check_mixer_control() {
    control="$1"
    expected_value="$2"

    if [ -z "$control" ]; then
        log_error "check_mixer_control: control name is empty"
        return 1
    fi

    card_index=$(resolve_hamoa_card_index) || return 1

    # Query the full control output including type, items, and current value
    control_output=$(amixer -c "$card_index" cget iface=MIXER,name="$control" 2>/dev/null)

    if [ -z "$control_output" ]; then
        log_error "Mixer control not found: $control"
        return 1
    fi

    if echo "$control_output" | grep -q "type=ENUMERATED"; then
        # For ENUM controls, "values=" reports the selected item as a numeric
        # index; look up the matching "Item #N 'name'" line to compare the
        # active value by name. Profile files may declare either the numeric
        # index (matching the amixer cset argument used at setup time, e.g.
        # 'WooferLeft WSA MODE|0') or the item name (e.g. 'WSA2 WSA RX0 MUX|
        # AIF1_PB'), so accept a match against either representation.
        active_index=$(echo "$control_output" | grep "^  : values=" | sed 's/.*values=\([0-9][0-9]*\).*/\1/')
        active_value=$(echo "$control_output" | grep "Item #${active_index} '" | sed "s/.*Item #${active_index} '\\(.*\\)'.*/\\1/")
        if [ "$expected_value" = "$active_index" ] || [ "$expected_value" = "$active_value" ]; then
            return 0
        fi
    elif echo "$control_output" | grep -q "type=BOOLEAN"; then
        # amixer always reports boolean controls as "on"/"off" in cget output,
        # even though cset accepts (and profile files store) "1"/"0" as the
        # argument. Normalize the expected value to the same on/off form
        # cget reports, so profile-driven 1/0 values compare correctly.
        actual_value=$(echo "$control_output" | grep ": values=" | cut -d'=' -f2)
        case "$expected_value" in
            1) expected_norm="on" ;;
            0) expected_norm="off" ;;
            *) expected_norm="$expected_value" ;;
        esac
        if [ "$actual_value" = "$expected_norm" ]; then
            return 0
        fi
    else
        # For integer controls (e.g. volume), compare the values= field exactly.
        actual_value=$(echo "$control_output" | grep ": values=" | cut -d'=' -f2)
        if [ "$actual_value" = "$expected_value" ]; then
            return 0
        fi
    fi

    log_error "Mixer control validation failed: $control"
    log_error "  Expected: $expected_value"
    log_error "  Actual: ${actual_value:-<not captured for this control type>}"
    return 1
}

# Validate complete mixer state for a specific device type.
# Uses the same profile file that setup_audio_route() applied, so every
# control that was configured is also verified here - the profile is the
# single source of truth for both setup and validation, rather than
# maintaining a separate, easily-drifting shortlist of "key" controls.
# Args: $1 - device type (handset_playback, headset_playback, handset_capture, headset_capture)
# Returns: 0 if every control in the profile matches its configured value, 1 otherwise
validate_mixer_state() {
    device_type="$1"

    case "$device_type" in
        handset_playback) profile_file="$TOOLS/audio/profiles/hamoa_playback_handset.profile" ;;
        headset_playback) profile_file="$TOOLS/audio/profiles/hamoa_playback_headset.profile" ;;
        handset_capture)  profile_file="$TOOLS/audio/profiles/hamoa_capture_handset.profile" ;;
        headset_capture)  profile_file="$TOOLS/audio/profiles/hamoa_capture_headset.profile" ;;
        *)
            log_error "Unknown device type: $device_type"
            return 1
            ;;
    esac

    log_info "Validating mixer state for: $device_type"

    if [ ! -r "$profile_file" ]; then
        log_error "validate_mixer_state: profile file not readable: $profile_file"
        return 1
    fi

    # shellcheck disable=SC1090
    . "$profile_file"

    if [ -z "$PROFILE_MIXER_CONTROLS" ]; then
        log_error "validate_mixer_state: profile defines no PROFILE_MIXER_CONTROLS: $profile_file"
        return 1
    fi

    old_ifs="$IFS"
    IFS='
'
    # shellcheck disable=SC2086
    set -- $PROFILE_MIXER_CONTROLS
    IFS="$old_ifs"

    for control_line in "$@"; do
        [ -n "$control_line" ] || continue
        ctrl_name="${control_line%%|*}"
        ctrl_value="${control_line#*|}"
        check_mixer_control "$ctrl_name" "$ctrl_value" || return 1
    done

    log_info "Mixer state validation passed"
    return 0
}

# Read the current value of a mixer control in a form suitable for reapplying
# via "amixer cset" later. Used by setup_audio_route() to snapshot a control's
# state before writing a new value, so a subsequent failure elsewhere in the
# profile can restore exactly what was there before this call started.
# Mirrors the same ENUM/BOOLEAN/INTEGER parsing used by check_mixer_control(),
# since the value returned here must round-trip back through "amixer cset".
# Args: $1 - mixer control name
#       $2 - card index to query
# Returns: current value on stdout, 0 on success, 1 if control not found
get_mixer_control_value() {
    control="$1"
    query_card_index="$2"

    control_output=$(amixer -c "$query_card_index" cget iface=MIXER,name="$control" 2>/dev/null)
    if [ -z "$control_output" ]; then
        return 1
    fi

    if echo "$control_output" | grep -q "type=ENUMERATED"; then
        # amixer cset accepts the item name for enumerated controls, so
        # resolve the active index to its name rather than returning the
        # raw index - this keeps the restore value unambiguous regardless
        # of whether the profile itself stores names or indices.
        active_index=$(echo "$control_output" | grep "^  : values=" | sed 's/.*values=\([0-9][0-9]*\).*/\1/')
        echo "$control_output" | grep "Item #${active_index} '" | sed "s/.*Item #${active_index} '\\(.*\\)'.*/\\1/"
    else
        # BOOLEAN and INTEGER controls both report their current value
        # directly in the "values=" field, and both accept that same
        # value back via cset (on/off for BOOLEAN, the number for INTEGER).
        echo "$control_output" | grep ": values=" | cut -d'=' -f2
    fi
}

# Restore mixer controls to previously captured values. Used by
# setup_audio_route() when a control write fails partway through applying a
# profile, so the card is not left in a mix of old and new control values.
# Args: $1 - card index
#       $2 - newline-separated "control_name|previous_value" pairs (in the
#            order they were originally applied - restore order does not
#            matter here since each ALSA mixer control is independent)
#       $3 - mixer log file to append amixer output to
rollback_audio_route() {
    rollback_card_index="$1"
    rollback_pairs="$2"
    rollback_log="$3"

    old_ifs="$IFS"
    IFS='
'
    # shellcheck disable=SC2086
    set -- $rollback_pairs
    IFS="$old_ifs"

    for pair in "$@"; do
        [ -n "$pair" ] || continue
        restore_name="${pair%%|*}"
        restore_value="${pair#*|}"
        amixer -c "$rollback_card_index" cset iface=MIXER,name="$restore_name" "$restore_value" >> "$rollback_log" 2>&1
    done
}

# Apply all mixer controls declared in a profile file to the current card.
# Sources the profile to load PROFILE_MIXER_CONTROLS (one "control_name|value"
# pair per line), then applies each control in order via amixer.
#
# Two card-wide test runs configuring the same profile (or different profiles
# that share controls) could otherwise interleave their amixer writes, so the
# whole operation is serialized with a per-card flock, following the same
# lock file convention as acquire_test_lock()/release_test_lock() in
# functestlib.sh (lock file under /var/lock, held only for the duration of
# this function).
#
# Before each control is written, its current value is captured so that if a
# later control in the same profile fails to apply, every control already
# changed in this call can be restored to its pre-call value. Without this,
# a failure partway through a profile would leave the mixer in a state that
# matches neither the old configuration nor the new one - some controls
# configured for the new route, others still holding whatever was set
# before, which is difficult to diagnose and unsafe to build on.
#
# The profile (and the rollback list) are read into positional parameters
# rather than piped into a loop, since a piped loop would run in a subshell
# and any "return" inside it would not propagate a failure back to the caller.
# Args: $1 - path to profile file (see Runner/utils/audio/profiles/*.profile)
#       $2 - path to mixer log file to append amixer output to
# Returns: 0 if all controls applied successfully, 1 if a control failed
#          (in which case previously-applied controls from this call have
#          already been rolled back to their prior values)
setup_audio_route() {
    profile_file="$1"
    mixer_log="$2"

    if [ ! -r "$profile_file" ]; then
        log_error "setup_audio_route: profile file not readable: $profile_file"
        return 1
    fi

    card_index=$(resolve_hamoa_card_index) || return 1

    # shellcheck disable=SC1090
    . "$profile_file"

    if [ -z "$PROFILE_MIXER_CONTROLS" ]; then
        log_error "setup_audio_route: profile defines no PROFILE_MIXER_CONTROLS: $profile_file"
        return 1
    fi

    lockfile="/var/lock/hamoa_audio_${card_index}.lock"
    exec 8>"$lockfile"
    if ! flock -n 8; then
        log_error "setup_audio_route: could not acquire mixer lock: $lockfile"
        exec 8>&-
        return 1
    fi

    old_ifs="$IFS"
    IFS='
'
    # shellcheck disable=SC2086
    set -- $PROFILE_MIXER_CONTROLS
    IFS="$old_ifs"

    applied_pairs=""
    rc=0

    for control_line in "$@"; do
        [ -n "$control_line" ] || continue
        ctrl_name="${control_line%%|*}"
        ctrl_value="${control_line#*|}"

        prev_value=$(get_mixer_control_value "$ctrl_name" "$card_index")

        if ! amixer -c "$card_index" cset iface=MIXER,name="$ctrl_name" "$ctrl_value" >> "$mixer_log" 2>&1; then
            log_error "setup_audio_route: failed to set '$ctrl_name' to '$ctrl_value' - restoring previously applied controls"
            rc=1
            break
        fi

        applied_pairs="${applied_pairs}${ctrl_name}|${prev_value}
"
    done

    if [ "$rc" -ne 0 ]; then
        rollback_audio_route "$card_index" "$applied_pairs" "$mixer_log"
    fi

    flock -u 8
    exec 8>&-

    return "$rc"
}

# Configure ALSA mixer for handset playback (built-in speakers)
# Sets up 4-way speaker system using WSA2 and WSA amplifiers
# Audio path: AIF1_PB -> WSA2/WSA RX0/RX1 -> WooferLeft/Right + TweeterLeft/Right
# Control list is declared in the hamoa_playback_handset profile file.
# Returns: 0 on success, 1 on failure
setup_handset_playback_mixer() {
    log_info "Configuring mixer for handset playback (speakers)..."

    if [ -n "$LOGDIR" ]; then
        mkdir -p "$LOGDIR" 2>/dev/null || true
        mixer_log="$LOGDIR/mixer_handset_playback.log"
    else
        mixer_log="./mixer_handset_playback.log"
    fi

    setup_audio_route "$TOOLS/audio/profiles/hamoa_playback_handset.profile" "$mixer_log" || return 1

    log_info "Handset playback mixer configured successfully"
    return 0
}

# Configure ALSA mixer for headset playback (headphones)
# Sets up stereo headphone output using RX codec in Class-H High Fidelity mode
# Audio path: AIF1_PB -> RX_MACRO RX0/RX1 -> RX INT0/INT1 -> HPHL/HPHR
# Control list is declared in the hamoa_playback_headset profile file.
# Returns: 0 on success, 1 on failure
setup_headset_playback_mixer() {
    log_info "Configuring mixer for headset playback (headphones)..."

    if [ -n "$LOGDIR" ]; then
        mkdir -p "$LOGDIR" 2>/dev/null || true
        mixer_log="$LOGDIR/mixer_headset_playback.log"
    else
        mixer_log="./mixer_headset_playback.log"
    fi

    setup_audio_route "$TOOLS/audio/profiles/hamoa_playback_headset.profile" "$mixer_log" || return 1

    log_info "Headset playback mixer configured successfully"
    return 0
}

# Configure ALSA mixer for handset capture (built-in microphone)
# Sets up VA_DMIC (Voice Activation DMIC) routing through VA decimators
# Audio path: DMIC0/DMIC1 -> VA DMIC MUX0/MUX1 -> VA DEC0/DEC1 -> VA_AIF1_CAP
# Control list is declared in the hamoa_capture_handset profile file.
# Returns: 0 on success, 1 on failure
setup_handset_capture_mixer() {
    log_info "Configuring mixer for handset capture (built-in mic)..."

    if [ -n "$LOGDIR" ]; then
        mkdir -p "$LOGDIR" 2>/dev/null || true
        mixer_log="$LOGDIR/mixer_handset_capture.log"
    else
        mixer_log="./mixer_handset_capture.log"
    fi

    setup_audio_route "$TOOLS/audio/profiles/hamoa_capture_handset.profile" "$mixer_log" || return 1

    log_info "Handset capture mixer configured successfully"
    return 0
}

# Configure ALSA mixer for headset capture (headset microphone)
# Sets up SWR_MIC (headset microphone) routing through SoundWire interface
# Audio path: SWR_MIC -> ADC2 -> TX SMIC MUX0 (SWR_MIC0) -> TX DEC0 -> TX_AIF1_CAP
# Note: TX SMIC MUX0 must be set to 'SWR_MIC0' (not 'ADC1') for proper routing
# Control list is declared in the hamoa_capture_headset profile file.
# Returns: 0 on success, 1 on failure
setup_headset_capture_mixer() {
    log_info "Configuring mixer for headset capture (headset mic)..."

    if [ -n "$LOGDIR" ]; then
        mkdir -p "$LOGDIR" 2>/dev/null || true
        mixer_log="$LOGDIR/mixer_headset_capture.log"
    else
        mixer_log="./mixer_headset_capture.log"
    fi

    setup_audio_route "$TOOLS/audio/profiles/hamoa_capture_headset.profile" "$mixer_log" || return 1

    log_info "Headset capture mixer configured successfully"
    return 0
}

#
# Hamoa ALSA Profile Functions
# These wrapper functions provide a profile interface for Hamoa platform
# to be used with --backend alsa --alsa-profile hamoa
#
# Profile: hamoa
# Devices: handset, headset for playback and capture. The underlying ALSA
# plughw identifiers are resolved dynamically at runtime via get_alsa_device()
# since the card index is not fixed across boots (see resolve_hamoa_card_index).
#

# Hamoa profile wrapper for handset playback
# Configures mixer, then verifies the PCM device and mixer state are ready
# Args: $1 - optional log directory path
# Returns: 0 on success, 1 if mixer setup or device/state validation fails
setup_alsa_profile_hamoa_playback_handset() {
    logdir="${1:-}"
    export LOGDIR="$logdir"
    setup_handset_playback_mixer || return 1
    check_alsa_device "$(get_alsa_device handset_playback)" playback || return 1
    validate_mixer_state handset_playback || return 1
}

# Hamoa profile wrapper for headset playback
# Configures mixer, then verifies the PCM device and mixer state are ready
# Args: $1 - optional log directory path
# Returns: 0 on success, 1 if mixer setup or device/state validation fails
setup_alsa_profile_hamoa_playback_headset() {
    logdir="${1:-}"
    export LOGDIR="$logdir"
    setup_headset_playback_mixer || return 1
    check_alsa_device "$(get_alsa_device headset_playback)" playback || return 1
    validate_mixer_state headset_playback || return 1
}

# Hamoa profile wrapper for handset capture
# Configures mixer, then verifies the PCM device and mixer state are ready
# Args: $1 - optional log directory path
# Returns: 0 on success, 1 if mixer setup or device/state validation fails
setup_alsa_profile_hamoa_capture_handset() {
    logdir="${1:-}"
    export LOGDIR="$logdir"
    setup_handset_capture_mixer || return 1
    check_alsa_device "$(get_alsa_device handset_capture)" capture || return 1
    validate_mixer_state handset_capture || return 1
}

# Hamoa profile wrapper for headset capture
# Configures mixer, then verifies the PCM device and mixer state are ready
# Args: $1 - optional log directory path
# Returns: 0 on success, 1 if mixer setup or device/state validation fails
setup_alsa_profile_hamoa_capture_headset() {
    logdir="${1:-}"
    export LOGDIR="$logdir"
    setup_headset_capture_mixer || return 1
    check_alsa_device "$(get_alsa_device headset_capture)" capture || return 1
    validate_mixer_state headset_capture || return 1
}

# Get ALSA device for Hamoa handset playback
get_alsa_device_hamoa_playback_handset() {
    get_alsa_device handset_playback
}

# Get ALSA device for Hamoa headset playback
get_alsa_device_hamoa_playback_headset() {
    get_alsa_device headset_playback
}

# Get ALSA device for Hamoa handset capture
get_alsa_device_hamoa_capture_handset() {
    get_alsa_device handset_capture
}

# Get ALSA device for Hamoa headset capture
get_alsa_device_hamoa_capture_headset() {
    get_alsa_device headset_capture
}
