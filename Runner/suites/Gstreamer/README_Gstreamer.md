# GStreamer V4L2 Test Scripts for Qualcomm Linux

**Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.**  
**SPDX-License-Identifier: BSD-3-Clause-Clear**

---

## Overview

These scripts automate validation of GStreamer encoding and decoding using V4L2 plugins on Qualcomm Linux platforms. The test suite validates the following GStreamer elements:

- **v4l2h264dec**: H.264 decoder
- **v4l2h265dec**: H.265 decoder
- **v4l2h264enc**: H.264 encoder
- **v4l2h265enc**: H.265 encoder

The suite leverages the common test framework with the same stack switching capabilities, pre-flight checks, and result reporting as other multimedia tests.

---

## Features

- **GStreamer Pipeline Tests**: Tests GStreamer pipelines using V4L2 hardware-accelerated codecs
- **Encode/Decode Testing**: Tests both encoding (videotestsrc → H.264/H.265) and decoding (H.264/H.265 → fakevideosink)
- **Auto-generated Test Media**: Creates test media files if they don't exist
- **Pipeline Error Detection**: Analyzes GStreamer logs for errors and warnings
- **Yocto-friendly**: POSIX shell with BusyBox-safe paths
- **Timeout Control**: Configurable timeouts for each test
- **Repeat/Loop Support**: Configurable test repetition with delay
- **Stack Switching**: Upstream ↔ downstream without reboot
- **dmesg Triage**: Scans kernel logs for errors
- **JUnit XML Output**: Optional JUnit XML output for CI/CD integration

---

## Directory Layout

```bash
Runner/
├── suites/
│   └── Multimedia/
│       └── Gstreamer/
│           ├── README_Gstreamer.md
│           ├── Gstreamer_MM_Tests.yaml
│           └── run.sh
└── utils/
    ├── functestlib.sh
    └── lib_video.sh
```

---

## Quick Start

```bash
git clone <this-repo>
cd <this-repo>

# Copy to target
scp -r Runner user@<target_ip>:<target_path>
ssh user@<target_ip>

cd <target_path>/Runner
./run-test.sh 'Gstreamer Multimedia Tests'
```

> Results land under: `Runner/suites/Multimedia/Gstreamer/`

---

## Runner CLI (run.sh)

| Option | Description |
|---|---|
| `--timeout S` | Timeout per test (default: `60`) |
| `--strict` | Treat dmesg warnings as failures |
| `--no-dmesg` | Disable dmesg scanning |
| `--max N` | Run at most `N` tests |
| `--stop-on-fail` | Abort suite on first failure |
| `--loglevel N` | Log level |
| `--repeat N` | Repeat each test `N` times |
| `--repeat-delay S` | Delay between repeats |
| `--repeat-policy all|any` | PASS if all runs pass, or any run passes |
| `--junit FILE` | Write JUnit XML |
| `--dry-run` | Print commands only |
| `--verbose` | Verbose runner logs |
| `--stack auto|upstream|downstream|base|overlay|up|down|both` | Select target stack |
| `--platform lemans|monaco|kodiak` | Force platform (else auto-detect) |
| `--retry-on-fail N` | Retry up to N times if a case ends FAIL |
| `--post-test-sleep S` | Sleep S seconds after each case |

---

## Test Pipelines

### H.264 Decode Pipeline
```
filesrc location=./720p_AVC.h264 ! h264parse ! v4l2h264dec ! videoconvert ! video/x-raw,format=NV12 ! fakevideosink
```

### H.265 Decode Pipeline
```
filesrc location=./720x1280_hevc.h265 ! h265parse ! v4l2h265dec ! videoconvert ! video/x-raw,format=NV12 ! fakevideosink
```

### H.264 Encode Pipeline
```
videotestsrc num-buffers=100 ! video/x-raw,width=1280,height=720,format=NV12,framerate=30/1 ! v4l2h264enc extra-controls="controls,video_bitrate=2000000" ! h264parse ! filesink location=./output_h264.h264
```

### H.265 Encode Pipeline
```
videotestsrc num-buffers=100 ! video/x-raw,width=1280,height=720,format=NV12,framerate=30/1 ! v4l2h265enc extra-controls="controls,video_bitrate=2000000" ! h265parse ! filesink location=./output_h265.h265
```

---

## Pipeline Error Detection

The test script checks for the following error patterns in GStreamer logs:

- General GStreamer errors (`ERROR:`)
- GStreamer warnings (`WARNING:`) - only in strict mode
- V4L2-specific failures (`v4l2.*failed`)
- Negotiation failures (`negotiation failed`)
- Buffer allocation failures (`buffer pool activation failed`)
- Format errors (`format not supported`)
- EOS handling errors (`failed to handle EOS`)
- Hardware acceleration errors (`hardware acceleration not available`)

---

## Examples

### Run with default settings
```sh
./run.sh
```

### Run with increased timeout
```sh
./run.sh --timeout 120
```

### Run with stack selection
```sh
./run.sh --stack upstream
./run.sh --stack downstream
```

### Run with repeat
```sh
./run.sh --repeat 3 --repeat-delay 5
```

### Run with JUnit XML output
```sh
./run.sh --junit gstreamer-results.xml
```

### Run in strict mode (warnings treated as errors)
```sh
./run.sh --strict
```

---

## Troubleshooting

### Missing GStreamer Plugins
If the test skips with a message about missing GStreamer plugins, ensure the following packages are installed:
- gstreamer1.0-plugins-base
- gstreamer1.0-plugins-good
- gstreamer1.0-plugins-bad
- gstreamer1.0-v4l2 (critical for V4L2 elements)

### No Video Devices
If the test skips with "no /dev/video* nodes", check:
1. Video drivers are loaded correctly
2. Stack selection is correct
3. Device nodes exist and have proper permissions

### Pipeline Failures
If a pipeline fails:
1. Check the log file in `logs_Gstreamer Multimedia Tests/`
2. Try running the pipeline manually with `gst-launch-1.0 -v`
3. Check dmesg for driver errors

### Common Issues
- **Negotiation failures**: Ensure the format and resolution are supported by the hardware
- **Buffer allocation failures**: Check system memory and driver capabilities
- **Hardware acceleration not available**: Verify the correct drivers are loaded

---

## Integration with Other Tests

This test follows the same framework as other multimedia tests, making it easy to integrate into existing test suites. It can be run alongside other tests using the same runner infrastructure.

---
