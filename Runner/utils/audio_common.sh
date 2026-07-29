#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Compatibility entry point for audio helpers.
# Audio utilities are organized under utils/audio/; this file sources
# the canonical location so existing callers continue to work.
# shellcheck disable=SC1091
. "$TOOLS/audio/audio_common.sh"