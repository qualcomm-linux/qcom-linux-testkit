# Video_Codec_Quality

Hardware decode reference-frame equality and encode frame-count/PSNR correctness across repeat runs.

This is a separate suite. Existing runners, plans and shared helper interfaces retain their current behavior. It uses runtime capability discovery on Yocto, Debian, Ubuntu and CentOS, including shell-only images. Required utilities and optional payloads must be supplied by the image or job. It does not install packages, change boot selection or start services.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--ffmpeg` | `ffmpeg` |
| `--streams` | `.` |
| `--codecs` | `h264,hevc,vp9` |
| `--mode` | `decode` |
| `--rounds` | `2` |
| `--size` | `320x240` |
| `--frames` | `60` |
| `--min-psnr` | `30` |

Options are CLI-only. No new environment-variable overrides are introduced. For Yocto YAML, set `OPTIONS` to the same argument string.

Run from this suite directory:

```sh
./run.sh --streams ./clips --mode decode
./run.sh --mode encode --codecs h264,hevc --size 640x480 --frames 60 --min-psnr 30
./run.sh --mode both --streams ./clips --rounds 3 --timeout 120
```

Requires image-provided `ffmpeg` and `v4l2-ctl`, an accessible V4L2 memory-to-memory device and the corresponding FFmpeg v4l2m2m codec. Decode clips are read from `<codec>-*` under `--streams`, for example `h264-validation.h264`. All hardware-decoded NV12 frame hashes must equal an explicit software decode of the same clip. Encode creates a synthetic reference, then checks complete software decode frame count and PSNR. Every hardware result requires FFmpeg verbose evidence of the actual V4L2 node. This suite never reloads a driver or changes firmware. Resolution and codecs can be overridden to match the running device capability.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/Video_Codec_Quality/run-*`, each invocation starts fresh. The shared result file is `./Video_Codec_Quality.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
