# Audio_DSP_Idle_Recovery_Validation

Validate ALSA playback after a selected DSP synthetic crash.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/Audio_DSP_Idle_Recovery_Validation/run-*` and the result is `Audio_DSP_Idle_Recovery_Validation.res` in the working directory.

Run `./run.sh --help` for options. Select the stable card ID and DSP from runtime
inventory, and supply PCM settings for the route provisioned in the image/job.

| Option | Default | Purpose |
| --- | --- | --- |
| `--exercise` | `0` | Explicit opt-in on an isolated target |
| `--card-id` | `unset` | Stable ALSA card ID, never a numeric first-card fallback |
| `--pcm` | `unset` | Hardware playback PCM number for the provisioned route |
| `--processor` | `unset` | Exact runtime remoteproc name or owner device name |
| `--timeout` | `60` | Per-operation and recovery deadline in seconds |
| `--play-seconds` | `2` | Baseline and recovered silence playback duration |
| `--rate` | `48000` | Configured S16_LE sample rate |
| `--channels` | `2` | Configured channel count |

Requires the Remoteproc_Restart_Validation implementation from PR #643.
Provide a configured ALSA route on an isolated device, with no competing audio clients.
The test proves digital PCM completion, not acoustic output. Missing ownership links
or optional crash controls skip. Recovery failures, hangs and genuine kernel faults fail.
It preserves DSP recovery policy and restores the saved selected-card mixer state.
No audio services are stopped and no DSP is restarted to manufacture a pass.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
