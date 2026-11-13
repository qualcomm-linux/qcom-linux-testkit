# Video_Codec_Quality

Hardware decode reference-frame equality and encode frame-count/PSNR correctness across repeat runs.

Uses runtime discovery on Yocto, Debian, Ubuntu and CentOS. Missing mapped tools can be installed on Ubuntu, Debian and CentOS through the shared package provider, with installed tools reused. Yocto and `TESTKIT_IMAGE_ONLY=1` use image-provided tools only. Recovery respects `CHECK_DEPS_RECOVER=0` and `Runner/config/pkg_provider.conf`. Native helpers and test assets still require provisioning.

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

Direct runs use the CLI options below. Yocto YAML exposes each option as a named parameter. Optional parameters default to `null` and are omitted, preserving runtime discovery and runner defaults.

Run from this suite directory:

```sh
./run.sh --streams ./clips --mode decode
./run.sh --mode encode --codecs h264,hevc --size 640x480 --frames 60 --min-psnr 30
./run.sh --mode both --streams ./clips --rounds 3 --timeout 120
```

Requires available `ffmpeg` and `v4l2-ctl`, an accessible V4L2 memory-to-memory device and the corresponding FFmpeg v4l2m2m codec. Decode clips are read from `<codec>-*` under `--streams`, for example `h264-validation.h264`. All hardware-decoded NV12 frame hashes must equal an explicit software decode of the same clip. Encode creates a synthetic reference, then checks complete software decode frame count and PSNR. Every hardware result requires FFmpeg verbose evidence of the actual V4L2 node. CentOS recovery requires an already configured repository providing `ffmpeg`, no multimedia repository is added automatically. This suite never reloads a driver or changes firmware. Resolution and codecs can be overridden to match the running device capability.

Kernel health uses an exact retained baseline, including a timestamped suffix
after ring rotation. `kernel-after/kernel_delta.log`, `kernel_delta_status.log`
and `kernel_errors.log` retain comparison details and appended records. Lost
continuity SKIPs kernel health, captured newer faults still FAIL. Frame and PSNR
assertions remain independently assessed.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/Video_Codec_Quality/run-*`, each invocation starts fresh. The shared result file is `./Video_Codec_Quality.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.


Yocto parameters:

| Parameter | Default | CLI option |
| --- | --- | --- |
| `TIMEOUT` | `60` | `--timeout` |
| `MODE` | `decode` | `--mode` |
| `CODECS` | `h264,hevc,vp9` | `--codecs` |
| `ROUNDS` | `2` | `--rounds` |
| `SIZE` | `320x240` | `--size` |
| `FRAMES` | `60` | `--frames` |
| `MIN_PSNR` | `30` | `--min-psnr` |
| `FFMPEG` | `null` | `--ffmpeg` |
| `STREAMS` | `null` | `--streams` |

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
