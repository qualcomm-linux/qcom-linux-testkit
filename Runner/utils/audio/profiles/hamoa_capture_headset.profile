#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Hamoa headset capture mixer profile for X1E80100-EVK.
# Sourced by setup_audio_route() in alsa_common.sh; defines the ordered list
# of ALSA mixer controls required to route the headset microphone (SWR_MIC)
# through the SoundWire interface into TX_AIF1_CAP. TX SMIC MUX0 must be set
# to SWR_MIC0 (not ADC1) for proper routing.
# Format: one "control_name|value" pair per line in PROFILE_MIXER_CONTROLS.

PROFILE_NAME="hamoa_capture_headset"
PROFILE_MIXER_CONTROLS="
TX DEC0 MUX|SWR_MIC
TX SMIC MUX0|SWR_MIC0
TX_AIF1_CAP Mixer DEC0|1
TX1 MODE|ADC_NORMAL
ADC2 Volume|20
TX_DEC0 Volume|84
ADC2_MIXER Switch|1
HDR12 MUX|NO_HDR12
ADC2 MUX|INP2
ADC2 Switch|1
"