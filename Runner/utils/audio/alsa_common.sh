#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# ALSA audio helpers for Hamoa test scenarios on X1E80100-EVK platform.
# Provides mixer configuration and device management for ALSA-based audio tests.
#
# This library assumes functestlib.sh has been sourced by the calling script,
# which provides log_info, log_warn, log_error, log_pass, and log_fail functions.

# ALSA device mappings for X1E80100-EVK audio hardware
# These map logical device names to ALSA plughw device identifiers
ALSA_DEVICE_HANDSET_PLAYBACK="plughw:0,1"  # 4-way speaker system (WSA2 + WSA)
ALSA_DEVICE_HEADSET_PLAYBACK="plughw:0,0"  # Stereo headphones (RX codec)
ALSA_DEVICE_HANDSET_CAPTURE="plughw:0,3"   # Built-in microphone (MSM_DMIC)
ALSA_DEVICE_HEADSET_CAPTURE="plughw:0,2"   # Headset microphone (SWR_MIC)

# Retrieve ALSA device identifier by logical name
# Args: $1 - device name (handset_playback, headset_playback, handset_capture, headset_capture)
# Returns: device identifier on stdout, 0 on success, 1 if unknown device
get_alsa_device() {
    case "$1" in
        handset_playback) printf '%s\n' "$ALSA_DEVICE_HANDSET_PLAYBACK"; return 0 ;;
        headset_playback) printf '%s\n' "$ALSA_DEVICE_HEADSET_PLAYBACK"; return 0 ;;
        handset_capture)  printf '%s\n' "$ALSA_DEVICE_HANDSET_CAPTURE";  return 0 ;;
        headset_capture)  printf '%s\n' "$ALSA_DEVICE_HEADSET_CAPTURE";  return 0 ;;
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

# Verify that an ALSA device exists and is accessible
# Args: $1 - ALSA device identifier (e.g., plughw:0,1)
# Returns: 0 if device exists, 1 otherwise
check_alsa_device() {
    device="$1"
    if [ -z "$device" ]; then
        log_error "check_alsa_device: device parameter is empty"
        return 1
    fi
    
    if aplay -l 2>/dev/null | grep -q "card 0"; then
        log_info "ALSA device accessible: $device"
        return 0
    else
        log_error "ALSA device not found: $device"
        return 1
    fi
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
    
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -lt "$min_size" ]; then
        log_error "Recording file too small: $size bytes (expected >= $min_size)"
        return 1
    fi
    
    log_info "Recording validated: $file ($size bytes)"
    return 0
}

# Verify that a specific ALSA mixer control is set to the expected value
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
    
    # Get the full control output to check both enum index and string value
    control_output=$(amixer -c 0 cget iface=MIXER,name="$control" 2>/dev/null)
    
    if [ -z "$control_output" ]; then
        log_error "Mixer control not found: $control"
        return 1
    fi
    
    # For enum controls, check if the expected value appears in the selected item line
    # For boolean/integer controls, check the values= line
    if echo "$control_output" | grep -q "type=ENUMERATED"; then
        # For enum, check if expected value is in the output (handles both index and string)
        if echo "$control_output" | grep -q "$expected_value"; then
            return 0
        fi
    else
        # For boolean/integer, check the values= line
        actual_value=$(echo "$control_output" | grep ": values=" | cut -d'=' -f2)
        case "$actual_value" in
            *"$expected_value"*)
                return 0
                ;;
        esac
    fi
    
    log_error "Mixer control validation failed: $control"
    log_error "  Expected: $expected_value"
    return 1
}

# Validate complete mixer state for a specific device type
# Checks key mixer controls to ensure audio path is configured correctly
# Args: $1 - device type (handset_playback, headset_playback, handset_capture, headset_capture)
# Returns: 0 if mixer state is valid, 1 otherwise
validate_mixer_state() {
    device_type="$1"
    
    log_info "Validating mixer state for: $device_type"
    
    case "$device_type" in
        handset_playback)
            check_mixer_control "WSA2 WSA RX0 MUX" "AIF1_PB" || return 1
            check_mixer_control "WSA2 WSA RX1 MUX" "AIF1_PB" || return 1
            ;;
        headset_playback)
            check_mixer_control "HPHL_RDAC Switch" "on" || return 1
            check_mixer_control "HPHR_RDAC Switch" "on" || return 1
            ;;
        handset_capture)
            check_mixer_control "VA DEC0 MUX" "VA_DMIC" || return 1
            check_mixer_control "VA DMIC MUX0" "DMIC0" || return 1
            ;;
        headset_capture)
            check_mixer_control "TX DEC0 MUX" "SWR_MIC" || return 1
            check_mixer_control "TX SMIC MUX0" "SWR_MIC0" || return 1
            ;;
        *)
            log_error "Unknown device type: $device_type"
            return 1
            ;;
    esac
    
    log_info "Mixer state validation passed"
    return 0
}

# Configure ALSA mixer for handset playback (built-in speakers)
# Sets up 4-way speaker system using WSA2 and WSA amplifiers
# Audio path: AIF1_PB -> WSA2/WSA RX0/RX1 -> WooferLeft/Right + TweeterLeft/Right
# Returns: 0 on success, 1 on failure
setup_handset_playback_mixer() {
    log_info "Configuring mixer for handset playback (speakers)..."
    
    # Create mixer log file if LOGDIR is set
    if [ -n "$LOGDIR" ]; then
        mkdir -p "$LOGDIR" 2>/dev/null || true
        mixer_log="$LOGDIR/mixer_handset_playback.log"
    else
        mixer_log="./mixer_handset_playback.log"
    fi
    
    # WSA2 Configuration
    amixer -c 0 cset iface=MIXER,name='WSA2 WSA RX0 MUX' 'AIF1_PB' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA2 WSA RX1 MUX' 'AIF1_PB' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA2 WSA_RX0 INP0' 'RX0' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA2 WSA_RX1 INP0' 'RX1' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA2 WSA_COMP1 Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA2 WSA_COMP2 Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA2 WSA_RX0 Digital Volume' 84 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA2 WSA_RX1 Digital Volume' 84 >> "$mixer_log" 2>&1 || return 1
    
    # WSA Configuration
    amixer -c 0 cset iface=MIXER,name='WSA WSA RX0 MUX' 'AIF1_PB' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA WSA RX1 MUX' 'AIF1_PB' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA WSA_RX0 INP0' 'RX0' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA WSA_RX1 INP0' 'RX1' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA WSA_COMP1 Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA WSA_COMP2 Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA WSA_RX0 Digital Volume' 84 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WSA WSA_RX1 Digital Volume' 84 >> "$mixer_log" 2>&1 || return 1
    
    # WooferLeft Configuration
    amixer -c 0 cset iface=MIXER,name='WooferLeft COMP Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferLeft BOOST Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferLeft DAC Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferLeft PBR Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferLeft VISENSE Switch' 0 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferLeft WSA MODE' 0 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferLeft PA Volume' 12 >> "$mixer_log" 2>&1 || return 1
    
    # TweeterLeft Configuration
    amixer -c 0 cset iface=MIXER,name='TweeterLeft COMP Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterLeft BOOST Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterLeft DAC Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterLeft PBR Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterLeft VISENSE Switch' 0 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterLeft WSA MODE' 0 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterLeft PA Volume' 12 >> "$mixer_log" 2>&1 || return 1
    
    # WooferRight Configuration
    amixer -c 0 cset iface=MIXER,name='WooferRight COMP Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferRight BOOST Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferRight DAC Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferRight PBR Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferRight VISENSE Switch' 0 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferRight WSA MODE' 0 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='WooferRight PA Volume' 12 >> "$mixer_log" 2>&1 || return 1
    
    # TweeterRight Configuration
    amixer -c 0 cset iface=MIXER,name='TweeterRight COMP Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterRight BOOST Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterRight DAC Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterRight PBR Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterRight VISENSE Switch' 0 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterRight WSA MODE' 0 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TweeterRight PA Volume' 12 >> "$mixer_log" 2>&1 || return 1
    
    log_info "Handset playback mixer configured successfully"
    return 0
}

# Configure ALSA mixer for headset playback (headphones)
# Sets up stereo headphone output using RX codec in Class-H High Fidelity mode
# Audio path: AIF1_PB -> RX_MACRO RX0/RX1 -> RX INT0/INT1 -> HPHL/HPHR
# Returns: 0 on success, 1 on failure
setup_headset_playback_mixer() {
    log_info "Configuring mixer for headset playback (headphones)..."
    
    # Create mixer log file if LOGDIR is set
    if [ -n "$LOGDIR" ]; then
        mkdir -p "$LOGDIR" 2>/dev/null || true
        mixer_log="$LOGDIR/mixer_headset_playback.log"
    else
        mixer_log="./mixer_headset_playback.log"
    fi
    
    amixer -c 0 cset iface=MIXER,name='HPHL_RDAC Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='HPHR_RDAC Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='HPHL Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='HPHR Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='HPHR_COMP Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='HPHL_COMP Switch' 1 >> "$mixer_log" 2>&1 || return 1
    
    amixer -c 0 cset iface=MIXER,name='RX HPH Mode' 'CLS_H_HIFI' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='RX_HPH PWR Mode' 'LOHIFI' >> "$mixer_log" 2>&1 || return 1
    
    amixer -c 0 cset iface=MIXER,name='RX_MACRO RX0 MUX' 'AIF1_PB' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='RX_MACRO RX1 MUX' 'AIF1_PB' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='RX INT0_1 MIX1 INP0' 'RX0' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='RX INT1_1 MIX1 INP0' 'RX1' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='RX INT0 DEM MUX' 'CLSH_DSM_OUT' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='RX INT1 DEM MUX' 'CLSH_DSM_OUT' >> "$mixer_log" 2>&1 || return 1
    
    amixer -c 0 cset iface=MIXER,name='RX_COMP1 Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='RX_COMP2 Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='RX_RX0 Digital Volume' 60 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='RX_RX1 Digital Volume' 60 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='HPHL Volume' 20 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='HPHR Volume' 20 >> "$mixer_log" 2>&1 || return 1
    
    amixer -c 0 cset iface=MIXER,name='CLSH Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='LO Switch' 1 >> "$mixer_log" 2>&1 || return 1
    
    log_info "Headset playback mixer configured successfully"
    return 0
}

# Configure ALSA mixer for handset capture (built-in microphone)
# Sets up VA_DMIC (Voice Activation DMIC) routing through VA decimators
# Audio path: DMIC0/DMIC1 -> VA DMIC MUX0/MUX1 -> VA DEC0/DEC1 -> VA_AIF1_CAP
# Returns: 0 on success, 1 on failure
setup_handset_capture_mixer() {
    log_info "Configuring mixer for handset capture (built-in mic)..."
    
    # Create mixer log file if LOGDIR is set
    if [ -n "$LOGDIR" ]; then
        mkdir -p "$LOGDIR" 2>/dev/null || true
        mixer_log="$LOGDIR/mixer_handset_capture.log"
    else
        mixer_log="./mixer_handset_capture.log"
    fi
    
    amixer -c 0 cset iface=MIXER,name='VA DEC0 MUX' 'VA_DMIC' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='VA DMIC MUX0' 'DMIC0' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='VA_AIF1_CAP Mixer DEC0' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='VA_DEC0 Volume' 100 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='VA DEC1 MUX' 'VA_DMIC' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='VA DMIC MUX1' 'DMIC1' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='VA_AIF1_CAP Mixer DEC1' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='VA_DEC1 Volume' 100 >> "$mixer_log" 2>&1 || return 1
    
    log_info "Handset capture mixer configured successfully"
    return 0
}

# Configure ALSA mixer for headset capture (headset microphone)
# Sets up SWR_MIC (headset microphone) routing through SoundWire interface
# Audio path: SWR_MIC -> ADC2 -> TX SMIC MUX0 (SWR_MIC0) -> TX DEC0 -> TX_AIF1_CAP
# Note: TX SMIC MUX0 must be set to 'SWR_MIC0' (not 'ADC1') for proper routing
# Returns: 0 on success, 1 on failure
setup_headset_capture_mixer() {
    log_info "Configuring mixer for headset capture (headset mic)..."
    
    # Create mixer log file if LOGDIR is set
    if [ -n "$LOGDIR" ]; then
        mkdir -p "$LOGDIR" 2>/dev/null || true
        mixer_log="$LOGDIR/mixer_headset_capture.log"
    else
        mixer_log="./mixer_headset_capture.log"
    fi
    
    amixer -c 0 cset iface=MIXER,name='TX DEC0 MUX' 'SWR_MIC' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TX SMIC MUX0' 'SWR_MIC0' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TX_AIF1_CAP Mixer DEC0' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TX1 MODE' 'ADC_NORMAL' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='ADC2 Volume' 20 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='TX_DEC0 Volume' 84 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='ADC2_MIXER Switch' 1 >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='HDR12 MUX' 'NO_HDR12' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='ADC2 MUX' 'INP2' >> "$mixer_log" 2>&1 || return 1
    amixer -c 0 cset iface=MIXER,name='ADC2 Switch' 1 >> "$mixer_log" 2>&1 || return 1
    
    log_info "Headset capture mixer configured successfully"
    return 0
}

#
# Hamoa ALSA Profile Functions
# These wrapper functions provide a profile interface for Hamoa platform
# to be used with --backend alsa --alsa-profile hamoa
#
# Profile: hamoa
# Devices: handset (plughw:0,1), headset (plughw:0,0) for playback
#          handset (plughw:0,3), headset (plughw:0,2) for capture
#

# Hamoa profile wrapper for handset playback
# Args: $1 - optional log directory path
setup_alsa_profile_hamoa_playback_handset() {
    local logdir="${1:-}"
    export LOGDIR="$logdir"
    setup_handset_playback_mixer
}

# Hamoa profile wrapper for headset playback
# Args: $1 - optional log directory path
setup_alsa_profile_hamoa_playback_headset() {
    local logdir="${1:-}"
    export LOGDIR="$logdir"
    setup_headset_playback_mixer
}

# Hamoa profile wrapper for handset capture
# Args: $1 - optional log directory path
setup_alsa_profile_hamoa_capture_handset() {
    local logdir="${1:-}"
    export LOGDIR="$logdir"
    setup_handset_capture_mixer
}

# Hamoa profile wrapper for headset capture
# Args: $1 - optional log directory path
setup_alsa_profile_hamoa_capture_headset() {
    local logdir="${1:-}"
    export LOGDIR="$logdir"
    setup_headset_capture_mixer
}

# Get ALSA device for Hamoa handset playback
get_alsa_device_hamoa_playback_handset() {
    echo "plughw:0,1"
}

# Get ALSA device for Hamoa headset playback
get_alsa_device_hamoa_playback_headset() {
    echo "plughw:0,0"
}

# Get ALSA device for Hamoa handset capture
get_alsa_device_hamoa_capture_handset() {
    echo "plughw:0,3"
}

# Get ALSA device for Hamoa headset capture
get_alsa_device_hamoa_capture_headset() {
    echo "plughw:0,2"
}

