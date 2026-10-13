#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# ALSA hardware-profile helpers for platform-specific mixer configuration.
# Provides mixer configuration and device management driven by declarative
# ".profile" files under Runner/utils/audio_profiles/, dispatched through a
# small set of registries keyed by (profile, device, operation) so that
# AudioPlayback/run.sh and AudioRecord/run.sh never name a specific hardware
# profile directly - they only pass through whatever --alsa-profile/--device
# the caller supplied, plus the operation (playback/capture) implied by which
# suite is running. Adding support for a new hardware profile means adding
# its profile files plus new entries in the registries below (identifying
# control, PCM-device-index, profile filename, UCM device name); no change
# to either run.sh, or to setup_alsa_profile_route() below, is required.
#
# Two mechanisms drive the same underlying hardware route for a profile:
# a raw-amixer profile mechanism (audio_profiles/*.profile +
# setup_audio_route()), and an alsaucm/UCM-configuration-tree mechanism
# (issue #454). setup_alsa_profile_route() prefers UCM when it is actually
# usable on the running image and falls back to the amixer-profile
# mechanism otherwise, so neither path is assumed to be the only one
# available.
#
# This library assumes functestlib.sh has already been sourced by the
# calling script, which provides log_info, log_warn, log_error, log_pass,
# and log_fail. It is sourced by audio_common.sh so every audio suite gets
# these helpers automatically; TOOLS must be exported by init_env.

# ---------------------------------------------------------------------------
# Profile registries
# ---------------------------------------------------------------------------
# These four functions are the only place with hardware-profile-specific
# ALSA knowledge. Everything else in this file and in the calling suites
# operates purely in terms of (profile, device, operation).

# Return the mixer control name used to identify a profile's card at
# runtime. Resolving by a distinctive control (rather than a hardcoded
# card-name string) keeps card selection correct regardless of how a card
# reports its id/name on different images.
# Args: $1 - profile name (e.g., hamoa)
# Returns: control name on stdout, 0 on success, 1 if profile unknown
_alsa_identifying_control() {
  case "$1" in
    hamoa) printf '%s\n' "WSA2 WSA RX0 MUX" ;;
    *) return 1 ;;
  esac
}

# Return the topology-fixed ALSA PCM device number for a profile's
# device/operation combination. PCM device numbers identify the PCM stream
# within the card and remain constant regardless of card registration order.
# Args: $1 - profile name
#       $2 - device name (e.g., handset, headset)
#       $3 - operation (playback or capture)
# Returns: PCM device number on stdout, 0 on success, 1 if combination unknown
_alsa_pcm_device_registry_lookup() {
  case "$1:$2:$3" in
    hamoa:handset:playback) printf '%s\n' 1 ;;  # 4-way speaker system (WSA2 + WSA)
    hamoa:headset:playback) printf '%s\n' 0 ;;  # Stereo headphones (RX codec)
    hamoa:handset:capture)  printf '%s\n' 3 ;;  # Built-in microphone (VA_DMIC)
    hamoa:headset:capture)  printf '%s\n' 2 ;;  # Headset microphone (SWR_MIC)
    *) return 1 ;;
  esac
}

# Return the audio_profiles/*.profile filename for a profile's
# device/operation combination. Centralizing this mapping keeps the profile
# filename convention ("<profile>_<operation>_<device>.profile") in one
# place, used by both setup and validation call sites.
# Args: $1 - profile name
#       $2 - device name
#       $3 - operation
# Returns: profile filename (without directory) on stdout, 0 on success,
#          1 if combination unknown
_alsa_profile_file_registry_lookup() {
  case "$1:$2:$3" in
    hamoa:handset:playback) printf '%s\n' "hamoa_playback_handset.profile" ;;
    hamoa:headset:playback) printf '%s\n' "hamoa_playback_headset.profile" ;;
    hamoa:handset:capture)  printf '%s\n' "hamoa_capture_handset.profile" ;;
    hamoa:headset:capture)  printf '%s\n' "hamoa_capture_headset.profile" ;;
    *) return 1 ;;
  esac
}

# Return the UCM "_enadev" device name for a profile's device/operation
# combination (issue #454). This is the UCM equivalent of the raw-amixer
# PROFILE_MIXER_CONTROLS mechanism above: alsaucm applies the same hardware
# route declaratively via a pre-installed UCM configuration tree, selected
# by _alsa_ucm_available() at runtime rather than this repo's own
# audio_profiles/*.profile files.
# Args: $1 - profile name
#       $2 - device name (e.g., handset, headset)
#       $3 - operation (playback or capture)
# Returns: UCM device-enable name on stdout, 0 on success, 1 if the
#          combination is unknown
_alsa_ucm_device_registry_lookup() {
  case "$1:$2:$3" in
    hamoa:handset:playback) printf '%s\n' "Speaker" ;;
    hamoa:headset:playback) printf '%s\n' "Headphones" ;;
    hamoa:handset:capture)  printf '%s\n' "Mic" ;;
    hamoa:headset:capture)  printf '%s\n' "Headset" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Card resolution
# ---------------------------------------------------------------------------

# Resolve the ALSA card index for a given profile's hardware at runtime.
# Identifies the card by the profile's distinctive mixer control (via
# _alsa_identifying_control()) rather than a platform/model name string, so
# the correct card is selected regardless of registration order (a USB/HDMI
# audio device enumerated earlier would otherwise shift a hardcoded index)
# and regardless of how a card reports its id/name string on different images.
# Args: $1 - profile name
# Returns: card index on stdout, 0 on success, 1 if profile unknown, card not
#          found, or ambiguous
resolve_alsa_card_index() {
  raci_profile="$1"

  if ! command -v amixer >/dev/null 2>&1; then
    log_error "resolve_alsa_card_index: amixer is unavailable" >&2
    return 1
  fi

  raci_identifying_control="$(_alsa_identifying_control "$raci_profile")" || {
    log_error "resolve_alsa_card_index: unknown ALSA profile: $raci_profile" >&2
    return 1
  }

  raci_match_count=0
  raci_matched_card=""

  # Enumerate registered card indexes via the existing shared helper
  # (audio_card_get_registered_cards, in audio_common.sh) rather than a
  # fixed/implicit card list, so a USB/HDMI audio device enumerated earlier
  # does not shift which index this loop checks.
  for raci_card in $(audio_card_get_registered_cards 2>/dev/null | cut -d'|' -f1); do
    if amixer -c "$raci_card" controls 2>/dev/null | grep -q "name='$raci_identifying_control'"; then
      raci_match_count=$((raci_match_count + 1))
      raci_matched_card="$raci_card"
    fi
  done

  if [ "$raci_match_count" -eq 0 ]; then
    log_error "ALSA profile '$raci_profile' card not found (no card exposes '$raci_identifying_control')" >&2
    return 1
  fi

  # Reject ambiguous matches to avoid operating on the wrong card.
  if [ "$raci_match_count" -gt 1 ]; then
    log_error "ALSA profile '$raci_profile': multiple matching cards found - ambiguous card selection" >&2
    return 1
  fi

  printf '%s\n' "$raci_matched_card"
}

# Retrieve the ALSA plughw device identifier for a profile's device/operation
# combination. Resolves the card index at call time and combines it with the
# registry's topology-specific PCM device number to construct the identifier.
# Args: $1 - profile name
#       $2 - device name (e.g., handset, headset)
#       $3 - operation (playback or capture)
# Returns: device identifier on stdout, 0 on success, 1 if the combination is
#          unknown or the card cannot be resolved
get_alsa_route_device() {
  gard_profile="$1"
  gard_device="$2"
  gard_operation="$3"

  gard_card_index="$(resolve_alsa_card_index "$gard_profile")" || return 1
  gard_pcm_device="$(_alsa_pcm_device_registry_lookup "$gard_profile" "$gard_device" "$gard_operation")" || {
    log_error "get_alsa_route_device: unknown profile/device/operation combination: $gard_profile/$gard_device/$gard_operation" >&2
    return 1
  }

  printf 'plughw:%s,%s\n' "$gard_card_index" "$gard_pcm_device"
}

# Verify that a specific ALSA PCM device exists and is accessible.
# Parses the exact card/device numbers out of the identifier and checks the
# correct enumeration for the requested direction - capture devices must be
# validated with "arecord -l", not "aplay -l", since a device number can
# exist for one direction but not the other.
# Args: $1 - ALSA device identifier (e.g., plughw:0,1 or hw:0,3)
#       $2 - direction: playback (default) or capture
# Returns: 0 if the exact card/device combination is found, 1 otherwise
check_alsa_device() {
  cad_device="$1"
  cad_direction="${2:-playback}"

  if [ -z "$cad_device" ]; then
    log_error "check_alsa_device: device parameter is empty" >&2
    return 1
  fi

  cad_card_num="$(printf '%s' "$cad_device" | sed -n 's/.*:\([0-9][0-9]*\),.*/\1/p')"
  cad_dev_num="$(printf '%s' "$cad_device" | sed -n 's/.*:[0-9][0-9]*,\([0-9][0-9]*\).*/\1/p')"

  if [ -z "$cad_card_num" ] || [ -z "$cad_dev_num" ]; then
    log_error "check_alsa_device: cannot parse card/device from: $cad_device" >&2
    return 1
  fi

  if [ "$cad_direction" = "capture" ]; then
    if arecord -l 2>/dev/null | grep -q "card ${cad_card_num}:.*device ${cad_dev_num}:"; then
      log_info "ALSA capture device accessible: $cad_device" >&2
      return 0
    fi
  else
    if aplay -l 2>/dev/null | grep -q "card ${cad_card_num}:.*device ${cad_dev_num}:"; then
      log_info "ALSA playback device accessible: $cad_device" >&2
      return 0
    fi
  fi

  log_error "ALSA device not found: $cad_device (direction=$cad_direction)" >&2
  return 1
}

# Resolve the UCM card name (the "-c" argument alsaucm expects) for a given
# profile's hardware at runtime, for issue #454's alsaucm-based route setup.
# Reuses resolve_alsa_card_index() for identification (so UCM shares the same
# dynamic, ambiguity-rejecting card lookup as the amixer-profile mechanism),
# then reads the matched card's long description from the existing
# audio_card_get_registered_cards() helper - this is the same string ALSA
# reports after the colon in /proc/asound/cards, which is also the name
# alsaucm's "-c" option and the /usr/share/alsa/ucm2/<name>/ directory use.
# Args: $1 - profile name
# Returns: UCM card name on stdout, 0 on success, 1 if the card cannot be
#          resolved or its description cannot be read
resolve_alsa_ucm_card_name() {
  raucn_profile="$1"

  raucn_card_index="$(resolve_alsa_card_index "$raucn_profile")" || return 1

  raucn_name="$(
    audio_card_get_registered_cards 2>/dev/null |
      awk -F'|' -v idx="$raucn_card_index" '$1 == idx { print $3; found=1 } END { exit !found }'
  )"

  if [ -z "$raucn_name" ]; then
    log_error "resolve_alsa_ucm_card_name: could not read UCM name for card index $raucn_card_index" >&2
    return 1
  fi

  printf '%s\n' "$raucn_name"
}

# Check whether the alsaucm-based route-setup path (issue #454) is usable for
# a given profile right now: the alsaucm binary must be present, the card
# must resolve, and that card's UCM configuration directory must actually
# exist under /usr/share/alsa/ucm2/ - alsaucm itself does not reliably fail
# fast on a missing/empty UCM tree, so this is checked explicitly up front
# rather than only discovered after attempting "set _verb HiFi".
# Args: $1 - profile name
# Returns: UCM card name on stdout, 0 if the UCM path is usable, 1 otherwise
#          (never logs an error - callers treat an unusable UCM path as
#          "fall back", not a failure)
_alsa_ucm_available() {
  aua_profile="$1"

  command -v alsaucm >/dev/null 2>&1 || return 1

  aua_card_name="$(resolve_alsa_ucm_card_name "$aua_profile" 2>/dev/null)" || return 1
  [ -n "$aua_card_name" ] || return 1

  [ -d "/usr/share/alsa/ucm2/$aua_card_name" ] || return 1

  printf '%s\n' "$aua_card_name"
}

# Validate that a recorded audio file meets a minimum size requirement.
# Delegates size handling to the shared file_size_bytes() helper so behavior
# stays consistent with the rest of the Audio test suite rather than
# duplicating direct stat logic here.
# Args: $1 - path to recording file
#       $2 - minimum size in bytes (default: 1024)
# Returns: 0 if valid, 1 otherwise
validate_alsa_recording() {
  var_file="$1"
  var_min_size="${2:-1024}"

  if [ ! -f "$var_file" ]; then
    log_error "Recording file not found: $var_file" >&2
    return 1
  fi

  var_size="$(file_size_bytes "$var_file" 2>/dev/null || echo 0)"
  if [ "$var_size" -lt "$var_min_size" ] 2>/dev/null; then
    log_error "Recording file too small: $var_size bytes (expected >= $var_min_size): $var_file" >&2
    return 1
  fi

  log_info "Recording validated: $var_file ($var_size bytes)" >&2
  return 0
}

# ---------------------------------------------------------------------------
# Mixer control read/validate helpers
# ---------------------------------------------------------------------------

# Verify that a specific ALSA mixer control is set to the expected value.
# Args: $1 - card index to query
#       $2 - mixer control name (e.g., 'WSA2 WSA RX0 MUX')
#       $3 - expected value (e.g., 'AIF1_PB', 'on'/'off', or a number)
# Returns: 0 if control matches expected value, 1 otherwise
check_mixer_control() {
  cmc_card_index="$1"
  cmc_control="$2"
  cmc_expected="$3"

  if [ -z "$cmc_control" ]; then
    log_error "check_mixer_control: control name is empty" >&2
    return 1
  fi

  cmc_output="$(amixer -c "$cmc_card_index" cget iface=MIXER,name="$cmc_control" 2>/dev/null)"

  if [ -z "$cmc_output" ]; then
    log_error "Mixer control not found: $cmc_control" >&2
    return 1
  fi

  if printf '%s\n' "$cmc_output" | grep -q "type=ENUMERATED"; then
    # For ENUM controls, "values=" reports the selected item as a numeric
    # index. Resolve that index to its item name and accept a match against
    # either the numeric index or the item name, since profile files may
    # declare either form (amixer cset accepts both).
    cmc_active_index="$(printf '%s\n' "$cmc_output" | grep "^  : values=" | sed 's/.*values=\([0-9][0-9]*\).*/\1/')"
    cmc_active_value="$(printf '%s\n' "$cmc_output" | grep "Item #${cmc_active_index} '" | sed "s/.*Item #${cmc_active_index} '\\(.*\\)'.*/\\1/")"
    if [ "$cmc_expected" = "$cmc_active_index" ] || [ "$cmc_expected" = "$cmc_active_value" ]; then
      return 0
    fi
    cmc_actual="$cmc_active_value"
  elif printf '%s\n' "$cmc_output" | grep -q "type=BOOLEAN"; then
    # amixer always reports boolean controls as "on"/"off" in cget output,
    # even though cset accepts (and profile files store) "1"/"0" as the
    # argument. Normalize the expected value to the same on/off form cget
    # reports, so profile-driven 1/0 values compare correctly.
    cmc_actual="$(printf '%s\n' "$cmc_output" | grep ": values=" | cut -d'=' -f2)"
    case "$cmc_expected" in
      1) cmc_expected_norm="on" ;;
      0) cmc_expected_norm="off" ;;
      *) cmc_expected_norm="$cmc_expected" ;;
    esac
    if [ "$cmc_actual" = "$cmc_expected_norm" ]; then
      return 0
    fi
  else
    # Integer controls (e.g. volume): compare the values= field exactly.
    cmc_actual="$(printf '%s\n' "$cmc_output" | grep ": values=" | cut -d'=' -f2)"
    if [ "$cmc_actual" = "$cmc_expected" ]; then
      return 0
    fi
  fi

  log_error "Mixer control validation failed: $cmc_control" >&2
  log_error "  Expected: $cmc_expected" >&2
  log_error "  Actual: ${cmc_actual:-<not captured for this control type>}" >&2
  return 1
}

# Read the current value of a mixer control in a form suitable for
# reapplying via "amixer cset" later. Used by setup_audio_route() to
# snapshot a control's state before writing a new value, so a later failure
# in the same profile can restore exactly what was there before. Mirrors the
# same ENUM/BOOLEAN/INTEGER parsing used by check_mixer_control(), since the
# value returned here must round-trip back through "amixer cset".
# Args: $1 - mixer control name
#       $2 - card index to query
# Returns: current value on stdout (empty if control not found)
get_mixer_control_value() {
  gmcv_control="$1"
  gmcv_card="$2"

  gmcv_output="$(amixer -c "$gmcv_card" cget iface=MIXER,name="$gmcv_control" 2>/dev/null)"
  if [ -z "$gmcv_output" ]; then
    return 1
  fi

  if printf '%s\n' "$gmcv_output" | grep -q "type=ENUMERATED"; then
    # amixer cset accepts the item name for enumerated controls, so resolve
    # the active index to its name - this keeps the restore value
    # unambiguous regardless of whether the profile stores names or indices.
    gmcv_active_index="$(printf '%s\n' "$gmcv_output" | grep "^  : values=" | sed 's/.*values=\([0-9][0-9]*\).*/\1/')"
    printf '%s\n' "$gmcv_output" | grep "Item #${gmcv_active_index} '" | sed "s/.*Item #${gmcv_active_index} '\\(.*\\)'.*/\\1/"
  else
    # BOOLEAN and INTEGER controls report their current value directly in
    # the "values=" field, and both accept that same value back via cset.
    printf '%s\n' "$gmcv_output" | grep ": values=" | cut -d'=' -f2
  fi
}

# Restore mixer controls to previously captured values. Used by
# setup_audio_route() when a control write fails partway through applying a
# profile, so the card is not left in a mix of old and new control values.
# Args: $1 - card index
#       $2 - newline-separated "control_name|previous_value" pairs
#       $3 - mixer log file to append amixer output to
rollback_audio_route() {
  rar_card="$1"
  rar_pairs="$2"
  rar_log="$3"

  # Reads via a heredoc (not a pipe) so this loop runs in the current shell
  # rather than a subshell, and scopes IFS to just this "read" invocation
  # instead of mutating the shell's global IFS for the duration of the loop.
  while IFS= read -r rar_pair; do
    [ -n "$rar_pair" ] || continue
    rar_name="${rar_pair%%|*}"
    rar_value="${rar_pair#*|}"
    amixer -c "$rar_card" cset iface=MIXER,name="$rar_name" "$rar_value" >>"$rar_log" 2>&1
  done <<EOF
$rar_pairs
EOF
}

# Apply all mixer controls declared in a profile file to the current card.
# Sources the profile to load PROFILE_MIXER_CONTROLS (one "control_name|value"
# pair per line), then applies each control in order via amixer.
#
# The whole operation is serialized with a per-card flock so two concurrent
# test runs touching the same card cannot interleave their amixer writes,
# following the same lock-file convention as acquire_test_lock()/
# release_test_lock() in functestlib.sh.
#
# Before each control is written, its current value is captured so that if
# a later control in the profile fails to apply, every control already
# changed in this call is restored to its pre-call value - otherwise a
# partial failure would leave the mixer in a state matching neither the old
# nor the new configuration.
#
# The control list is read via a heredoc rather than a pipe, since a piped
# loop runs in a subshell where sar_rc/sar_applied_pairs set inside the loop
# would not be visible to the rest of this function.
# Args: $1 - card index to apply the profile's controls to
#       $2 - path to profile file (see Runner/utils/audio_profiles/*.profile)
#       $3 - path to mixer log file to append amixer output to
# Returns: 0 if all controls applied successfully, 1 if a control failed
#          (previously-applied controls from this call are rolled back)
setup_audio_route() {
  sar_card_index="$1"
  sar_profile_file="$2"
  sar_mixer_log="$3"

  if [ ! -r "$sar_profile_file" ]; then
    log_error "setup_audio_route: profile file not readable: $sar_profile_file" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  . "$sar_profile_file"

  if [ -z "$PROFILE_MIXER_CONTROLS" ]; then
    log_error "setup_audio_route: profile defines no PROFILE_MIXER_CONTROLS: $sar_profile_file" >&2
    return 1
  fi

  # Waits (bounded) for the lock rather than failing immediately on
  # contention, since the lock exists to serialize concurrent mixer writes
  # on the same card - a brief wait for another in-flight writer to finish
  # is the expected, correct outcome, not a failure.
  sar_lockfile="/var/lock/alsa_audio_${sar_card_index}.lock"
  exec 8>"$sar_lockfile"
  if ! flock -w 10 8; then
    log_error "setup_audio_route: could not acquire mixer lock after 10s: $sar_lockfile" >&2
    exec 8>&-
    return 1
  fi

  sar_applied_pairs=""
  sar_rc=0

  # Reads via a heredoc (not a pipe) so this loop - and the sar_rc/
  # sar_applied_pairs it sets - run in the current shell rather than a
  # subshell, and scopes IFS to just this "read" invocation instead of
  # mutating the shell's global IFS for the duration of the loop.
  while IFS= read -r sar_control_line; do
    [ -n "$sar_control_line" ] || continue
    sar_ctrl_name="${sar_control_line%%|*}"
    sar_ctrl_value="${sar_control_line#*|}"

    sar_prev_value="$(get_mixer_control_value "$sar_ctrl_name" "$sar_card_index")"

    if ! amixer -c "$sar_card_index" cset iface=MIXER,name="$sar_ctrl_name" "$sar_ctrl_value" >>"$sar_mixer_log" 2>&1; then
      log_error "setup_audio_route: failed to set '$sar_ctrl_name' to '$sar_ctrl_value' - restoring previously applied controls" >&2
      sar_rc=1
      break
    fi

    sar_applied_pairs="${sar_applied_pairs}${sar_ctrl_name}|${sar_prev_value}
"
  done <<EOF
$PROFILE_MIXER_CONTROLS
EOF

  if [ "$sar_rc" -ne 0 ]; then
    rollback_audio_route "$sar_card_index" "$sar_applied_pairs" "$sar_mixer_log"
  fi

  flock -u 8
  exec 8>&-

  return "$sar_rc"
}

# Validate complete mixer state for a specific profile/device/operation
# combination. Uses the same profile file that setup_audio_route() applied,
# so every control that was configured is also verified here - the profile
# is the single source of truth for both setup and validation, instead of a
# separate, easily-drifting shortlist of "key" controls.
# Args: $1 - card index to query
#       $2 - path to profile file (same file setup_audio_route() applied)
# Returns: 0 if every control in the profile matches its configured value,
#          1 otherwise
validate_mixer_state() {
  vms_card_index="$1"
  vms_profile_file="$2"

  if [ ! -r "$vms_profile_file" ]; then
    log_error "validate_mixer_state: profile file not readable: $vms_profile_file" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  . "$vms_profile_file"

  if [ -z "$PROFILE_MIXER_CONTROLS" ]; then
    log_error "validate_mixer_state: profile defines no PROFILE_MIXER_CONTROLS: $vms_profile_file" >&2
    return 1
  fi

  log_info "Validating mixer state against profile: $vms_profile_file" >&2

  # Reads via a heredoc (not a pipe) so a failing check_mixer_control() can
  # "return 1" directly from this loop instead of only exiting a subshell,
  # and scopes IFS to just this "read" invocation instead of mutating the
  # shell's global IFS for the duration of the loop.
  while IFS= read -r vms_control_line; do
    [ -n "$vms_control_line" ] || continue
    vms_ctrl_name="${vms_control_line%%|*}"
    vms_ctrl_value="${vms_control_line#*|}"
    check_mixer_control "$vms_card_index" "$vms_ctrl_name" "$vms_ctrl_value" || return 1
  done <<EOF
$PROFILE_MIXER_CONTROLS
EOF

  log_info "Mixer state validation passed" >&2
  return 0
}

# ---------------------------------------------------------------------------
# UCM (Use Case Manager) route (issue #454)
# ---------------------------------------------------------------------------
#
# Ubuntu/UCM-configured images apply a route through "alsaucm" and a
# pre-installed UCM configuration tree (see
# https://github.com/alsa-project/alsa-ucm-conf, installed under
# /usr/share/alsa/ucm2/<card>/) instead of this file's own
# audio_profiles/*.profile + setup_audio_route() amixer mechanism. Both
# mechanisms drive the same underlying hardware route; setup_alsa_profile_route()
# below prefers UCM when it is actually usable on the running image and
# falls back to the amixer-profile mechanism otherwise, so neither path is
# ever assumed to be the only one available.

# Configure the hardware route for a profile's device/operation combination
# via "alsaucm set _verb HiFi set _enadev <device>", then verify the exact
# PCM device is enumerated for the requested direction. UCM's own
# configuration tree is the single source of truth for the mixer state it
# applies, so (unlike the amixer-profile path) there is no separate
# per-control validation step here - the only locally-known fact to verify
# is that the resulting PCM device is actually present.
# Args: $1 - profile name (e.g., hamoa)
#       $2 - device name (e.g., handset, headset)
#       $3 - operation (playback or capture)
#       $4 - optional log directory path for the alsaucm log
# Returns: 0 on success, 1 if card/UCM-name resolution, "alsaucm set", or
#          device validation fails
setup_alsa_ucm_route() {
  saur_profile="$1"
  saur_device="$2"
  saur_operation="$3"
  saur_logdir="${4:-}"

  saur_ucm_card="$(_alsa_ucm_available "$saur_profile")" || return 1

  saur_ucm_device="$(_alsa_ucm_device_registry_lookup "$saur_profile" "$saur_device" "$saur_operation")" || {
    log_error "setup_alsa_ucm_route: unknown profile/device/operation combination: $saur_profile/$saur_device/$saur_operation" >&2
    return 1
  }

  if [ -n "$saur_logdir" ]; then
    mkdir -p "$saur_logdir" 2>/dev/null || true
    saur_log="$saur_logdir/ucm_${saur_device}_${saur_operation}.log"
  else
    saur_log="./ucm_${saur_device}_${saur_operation}.log"
  fi

  log_info "Configuring UCM route for profile=$saur_profile device=$saur_device operation=$saur_operation (ucm_card=$saur_ucm_card, enadev=$saur_ucm_device)" >&2

  if ! alsaucm -c "$saur_ucm_card" set _verb HiFi set _enadev "$saur_ucm_device" >>"$saur_log" 2>&1; then
    log_error "setup_alsa_ucm_route: 'alsaucm -c $saur_ucm_card set _verb HiFi set _enadev $saur_ucm_device' failed, see $saur_log" >&2
    return 1
  fi

  saur_device_id="$(get_alsa_route_device "$saur_profile" "$saur_device" "$saur_operation")" || {
    log_error "setup_alsa_ucm_route: failed to resolve device identifier for $saur_profile/$saur_device/$saur_operation" >&2
    return 1
  }

  if ! check_alsa_device "$saur_device_id" "$saur_operation"; then
    log_error "setup_alsa_ucm_route: PCM device not enumerated: $saur_device_id (operation=$saur_operation)" >&2
    return 1
  fi

  log_info "UCM route ready: profile=$saur_profile device=$saur_device operation=$saur_operation -> $saur_device_id" >&2
  printf '%s\n' "$saur_device_id"
}

# ---------------------------------------------------------------------------
# Generic profile dispatch
# ---------------------------------------------------------------------------
#
# This is the single entry point invoked from AudioPlayback/run.sh and
# AudioRecord/run.sh via:
#   --backend alsa --alsa-profile <profile> --device <device>
#
# run.sh validates (profile, device) against an explicit allowlist (never
# dynamic function-name construction - see the "no eval/dynamic dispatch"
# architectural requirement) before calling this function, then passes the
# literal profile/device/operation strings straight through. Adding a new
# hardware profile means adding entries to the four registries above
# (_alsa_identifying_control, _alsa_pcm_device_registry_lookup,
# _alsa_profile_file_registry_lookup, _alsa_ucm_device_registry_lookup)
# plus the profile files themselves - this function and its caller never
# change. setup_alsa_profile_route() tries the UCM route first when usable
# on the running image, falling back to the amixer-profile route otherwise.

# Configure the ALSA mixer for a profile's device/operation route, then
# verify the exact PCM device is enumerated for the requested direction and
# that every mixer control in the profile reads back the expected value.
# Args: $1 - profile name (e.g., hamoa)
#       $2 - device name (e.g., handset, headset)
#       $3 - operation (playback or capture)
#       $4 - optional log directory path for mixer logs
# Returns: 0 on success, 1 if card resolution, mixer setup, or device/state
#          validation fails
setup_alsa_profile_route() {
  sapr_profile="$1"
  sapr_device="$2"
  sapr_operation="$3"
  sapr_logdir="${4:-}"

  sapr_ucm_card="$(_alsa_ucm_available "$sapr_profile" 2>/dev/null)"
  if [ -n "$sapr_ucm_card" ]; then
    log_info "UCM configuration tree found for profile=$sapr_profile (card=$sapr_ucm_card) - using alsaucm route setup" >&2
    setup_alsa_ucm_route "$sapr_profile" "$sapr_device" "$sapr_operation" "$sapr_logdir" && return 0
    log_warn "setup_alsa_profile_route: alsaucm route setup failed for $sapr_profile/$sapr_device/$sapr_operation - falling back to amixer profile mechanism" >&2
  fi

  sapr_card_index="$(resolve_alsa_card_index "$sapr_profile")" || return 1

  sapr_profile_filename="$(_alsa_profile_file_registry_lookup "$sapr_profile" "$sapr_device" "$sapr_operation")" || {
    log_error "setup_alsa_profile_route: unknown profile/device/operation combination: $sapr_profile/$sapr_device/$sapr_operation" >&2
    return 1
  }
  sapr_profile_file="${TOOLS:-.}/audio_profiles/$sapr_profile_filename"

  if [ -n "$sapr_logdir" ]; then
    mkdir -p "$sapr_logdir" 2>/dev/null || true
    sapr_mixer_log="$sapr_logdir/mixer_${sapr_device}_${sapr_operation}.log"
  else
    sapr_mixer_log="./mixer_${sapr_device}_${sapr_operation}.log"
  fi

  log_info "Configuring ALSA mixer for profile=$sapr_profile device=$sapr_device operation=$sapr_operation (card=$sapr_card_index)" >&2
  setup_audio_route "$sapr_card_index" "$sapr_profile_file" "$sapr_mixer_log" || return 1
  log_info "Mixer configured successfully for $sapr_device $sapr_operation" >&2

  sapr_device_id="$(get_alsa_route_device "$sapr_profile" "$sapr_device" "$sapr_operation")" || {
    log_error "setup_alsa_profile_route: failed to resolve device identifier for $sapr_profile/$sapr_device/$sapr_operation" >&2
    return 1
  }

  if ! check_alsa_device "$sapr_device_id" "$sapr_operation"; then
    log_error "setup_alsa_profile_route: PCM device not enumerated: $sapr_device_id (operation=$sapr_operation)" >&2
    return 1
  fi

  if ! validate_mixer_state "$sapr_card_index" "$sapr_profile_file"; then
    log_error "setup_alsa_profile_route: mixer state validation failed after setup for $sapr_profile/$sapr_device/$sapr_operation" >&2
    return 1
  fi

  log_info "ALSA profile route ready: profile=$sapr_profile device=$sapr_device operation=$sapr_operation -> $sapr_device_id" >&2
  printf '%s\n' "$sapr_device_id"
}
