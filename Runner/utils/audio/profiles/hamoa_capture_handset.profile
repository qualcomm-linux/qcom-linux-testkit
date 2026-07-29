#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Hamoa handset capture mixer profile for X1E80100-EVK.
# Sourced by setup_audio_route() in alsa_common.sh; defines the ordered list
# of ALSA mixer controls required to route the built-in microphones (VA_DMIC)
# through the VA decimators into VA_AIF1_CAP.
# Format: one "control_name|value" pair per line in PROFILE_MIXER_CONTROLS.

PROFILE_NAME="hamoa_capture_handset"
PROFILE_MIXER_CONTROLS="
VA DEC0 MUX|VA_DMIC
VA DMIC MUX0|DMIC0
VA_AIF1_CAP Mixer DEC0|1
VA_DEC0 Volume|100
VA DEC1 MUX|VA_DMIC
VA DMIC MUX1|DMIC1
VA_AIF1_CAP Mixer DEC1|1
VA_DEC1 Volume|100
"