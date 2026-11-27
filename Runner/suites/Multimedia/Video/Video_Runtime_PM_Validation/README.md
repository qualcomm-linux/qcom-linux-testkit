# Video_Runtime_PM_Validation

Verify hardware decode correctness after an observed runtime suspend and resume.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/Video_Runtime_PM_Validation/run-*` and the result is `Video_Runtime_PM_Validation.res` in the working directory.

Run `./run.sh --help` for options. The job supplies the reference clip directory
and codec. Device and driver identity are derived from the actual hardware decode.

| Option | Default | Purpose |
| --- | --- | --- |
| `--streams` | `unset` | Directory containing a supported codec-* reference clip |
| `--codec` | `h264` | One codec to validate, h264, hevc or vp9 |
| `--ffmpeg` | `ffmpeg` | Installed FFmpeg binary or path |
| `--timeout` | `60` | Per-operation and readiness deadline in seconds |

Requires Video_Codec_Quality from PR #643 and image-provided FFmpeg/v4l2-ctl.
Select a job-provided reference clip, for example h264-reference.h264.
The baseline verifier identifies the actual FFmpeg-selected codec device.
The same device must decode correctly after the lifecycle operation.
No driver, firmware or PM policy is selected from a board-name map.
Runtime PM must already be enabled. An unsupported interface skips, a supported
device failing to suspend or resume correctly fails. Power policy is not changed.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
