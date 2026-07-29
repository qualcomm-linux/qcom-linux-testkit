#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Hamoa handset playback mixer profile for X1E80100-EVK.
# Sourced by setup_audio_route() in alsa_common.sh; defines the ordered list
# of ALSA mixer controls required to route AIF1_PB through the 4-way speaker
# system (WSA2 + WSA amplifiers driving WooferLeft/Right + TweeterLeft/Right).
# Format: one "control_name|value" pair per line in PROFILE_MIXER_CONTROLS.

PROFILE_NAME="hamoa_playback_handset"
PROFILE_MIXER_CONTROLS="
WSA2 WSA RX0 MUX|AIF1_PB
WSA2 WSA RX1 MUX|AIF1_PB
WSA2 WSA_RX0 INP0|RX0
WSA2 WSA_RX1 INP0|RX1
WSA2 WSA_COMP1 Switch|1
WSA2 WSA_COMP2 Switch|1
WSA2 WSA_RX0 Digital Volume|81
WSA2 WSA_RX1 Digital Volume|81
WSA WSA RX0 MUX|AIF1_PB
WSA WSA RX1 MUX|AIF1_PB
WSA WSA_RX0 INP0|RX0
WSA WSA_RX1 INP0|RX1
WSA WSA_COMP1 Switch|1
WSA WSA_COMP2 Switch|1
WSA WSA_RX0 Digital Volume|81
WSA WSA_RX1 Digital Volume|81
WooferLeft COMP Switch|1
WooferLeft BOOST Switch|1
WooferLeft DAC Switch|1
WooferLeft PBR Switch|1
WooferLeft VISENSE Switch|0
WooferLeft WSA MODE|0
WooferLeft PA Volume|6
TweeterLeft COMP Switch|1
TweeterLeft BOOST Switch|1
TweeterLeft DAC Switch|1
TweeterLeft PBR Switch|1
TweeterLeft VISENSE Switch|0
TweeterLeft WSA MODE|0
TweeterLeft PA Volume|6
WooferRight COMP Switch|1
WooferRight BOOST Switch|1
WooferRight DAC Switch|1
WooferRight PBR Switch|1
WooferRight VISENSE Switch|0
WooferRight WSA MODE|0
WooferRight PA Volume|6
TweeterRight COMP Switch|1
TweeterRight BOOST Switch|1
TweeterRight DAC Switch|1
TweeterRight PBR Switch|1
TweeterRight VISENSE Switch|0
TweeterRight WSA MODE|0
TweeterRight PA Volume|6
"