#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Hamoa headset playback mixer profile for X1E80100-EVK.
# Sourced by setup_audio_route() in alsa_common.sh; defines the ordered list
# of ALSA mixer controls required to route AIF1_PB through the stereo
# headphone output using the RX codec in Class-H High Fidelity mode.
# Format: one "control_name|value" pair per line in PROFILE_MIXER_CONTROLS.

PROFILE_NAME="hamoa_playback_headset"
PROFILE_MIXER_CONTROLS="
HPHL_RDAC Switch|1
HPHR_RDAC Switch|1
HPHL Switch|1
HPHR Switch|1
HPHR_COMP Switch|1
HPHL_COMP Switch|1
RX HPH Mode|CLS_H_HIFI
RX_HPH PWR Mode|LOHIFI
RX_MACRO RX0 MUX|AIF1_PB
RX_MACRO RX1 MUX|AIF1_PB
RX INT0_1 MIX1 INP0|RX0
RX INT1_1 MIX1 INP0|RX1
RX INT0 DEM MUX|CLSH_DSM_OUT
RX INT1 DEM MUX|CLSH_DSM_OUT
RX_COMP1 Switch|1
RX_COMP2 Switch|1
RX_RX0 Digital Volume|60
RX_RX1 Digital Volume|60
HPHL Volume|20
HPHR Volume|20
CLSH Switch|1
LO Switch|1
"