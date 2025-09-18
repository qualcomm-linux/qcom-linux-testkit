# Audio Playback Validation Script for Qualcomm Linux-based Platform (Yocto)

## Overview

This suite automates the validation of audio playback capabilities on Qualcomm Linux-based platforms running a Yocto-based Linux system. It supports both PipeWire and PulseAudio backends, with robust evidence-based PASS/FAIL logic, asset management, and diagnostic logging.


## Features

- Supports **PipeWire** and **PulseAudio** backends
- Plays audio clips with configurable format, duration, and loop count
- Automatically downloads and extracts audio assets if missing
- Validates playback using multiple evidence sources:
  - PipeWire/PulseAudio streaming state
  - ALSA and ASoC runtime status
  - Kernel logs (`dmesg`)
- Diagnostic logs: dmesg scan, mixer dumps, playback logs	
- Evidence-based validation (user-space, ALSA, ASoC, dmesg)	
- Generates `.res` result file and optional JUnit XML output
								 

## Prerequisites

Ensure the following components are present in the target Yocto build:

- PipeWire: `pw-play`, `wpctl`
- PulseAudio: `paplay`, `pactl`
- Common tools: `pgrep`, `timeout`, `grep`, `wget`, `tar`
- Daemon: `pipewire` or `pulseaudio` must be running

## Directory Structure

```bash
Runner/
├── run-test.sh
├── utils/
│   ├── functestlib.sh
│   └── audio_common.sh
└── suites/
    └── Multimedia/
        └── Audio/
            ├── AudioPlayback/
                ├── run.sh
                └── Read_me.md
```

## Usage

Instructions:
1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.
2. Verify Transfer: Ensure that the repo has been successfully copied to any directory on the target device.
3. Run Scripts: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run a specific test using:
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip 

**Using Unified Runner**
cd <Path in device>/Runner

# Run AudioPlayback using PipeWire (auto-detects backend if not specified)
./run-test.sh AudioPlayback

# Force PulseAudio backend
AUDIO_BACKEND=pulseaudio ./run-test.sh AudioPlayback

# Custom options via environment variables
AUDIO_BACKEND=pipewire PLAYBACK_TIMEOUT=20s PLAYBACK_LOOPS=2 ./run-test.sh AudioPlayback

# Disable asset extraction (offline mode)
EXTRACT_AUDIO_ASSETS=false ./run-test.sh AudioPlayback

# Provide Wi-Fi credentials for asset download
SSID="MyNetwork" PASSWORD="MyPassword" ./run-test.sh AudioPlayback

# Override network probe targets (useful in restricted networks)
NET_PROBE_ROUTE_IP=192.168.1.1 NET_PING_HOST=192.168.1.254 ./run-test.sh AudioPlayback


**Directly from Test Directory**
cd Runner/suites/Multimedia/Audio/AudioPlayback
# Show usage/help
./run.sh --help

# Run with PipeWire, 3 loops, 10s timeout, speakers sink
./run.sh --backend pipewire --sink speakers --loops 3 --timeout 10s

# Run with PulseAudio, null sink, strict mode, verbose
./run.sh --backend pulseaudio --sink null --strict --verbose

# Disable asset extraction (offline mode)
./run.sh --no-extract-assets

# Provide JUnit output and disable dmesg scan
./run.sh --junit results.xml --no-dmesg



Environment Variables:
Variable	          Description	                                 Default
AUDIO_BACKEND	      Selects backend: pipewire or pulseaudio	     auto-detect
SINK_CHOICE	          Playback sink: speakers or null	             speakers
FORMATS	              Audio formats: e.g. wav	                     wav
DURATIONS	          Playback durations: short, medium, long	     short
LOOPS	              Number of playback loops	                     1
TIMEOUT	              Playback timeout per loop (e.g., 15s, 0=none)	 0
STRICT	              Enable strict mode (fail on any error)	     0
DMESG_SCAN	          Scan dmesg for errors after playback	         1
VERBOSE	              Enable verbose logging	                     0
EXTRACT_AUDIO_ASSETS  Download/extract audio assets if missing	     true
JUNIT_OUT	          Path to write JUnit XML output	             unset
SSID                  Wi-Fi SSID for network connection              unset
PASSWORD              Wi-Fi password for network connection          unset
NET_PROBE_ROUTE_IP    IP used for route probing (default: 1.1.1.1)   1.1.1.1
NET_PING_HOST         Host used for ping reachability check          8.8.8.8


CLI Options
Option	              Description
--backend	          Select backend: pipewire or pulseaudio
--sink	              Playback sink: speakers or null
--formats	          Audio formats (space/comma separated): e.g. wav
--durations	          Playback durations: short, medium, long
--loops	              Number of playback loops
--timeout	          Playback timeout per loop (e.g., 15s)
--strict	          Enable strict mode
--no-dmesg	          Disable dmesg scan
--no-extract-assets	  Disable asset extraction
--junit <file.xml>	  Write JUnit XML output
--verbose	          Enable verbose logging
--help	              Show usage instructions

```

Sample Output:
```
sh-5.3# ./run.sh --backend pipewire
[INFO] 2025-09-12 05:24:47 - ---------------- Starting AudioPlayback ----------------
[INFO] 2025-09-12 05:24:47 - SoC: 498
[INFO] 2025-09-12 05:24:47 - Args: backend=pipewire sink=speakers loops=1 timeout=0 formats='wav' durations='short' strict=0 dmesg=1 extract=true
[INFO] 2025-09-12 05:24:47 - Using backend: pipewire
[INFO] 2025-09-12 05:24:47 - Routing to sink: id=72 name='Built-in Audio Speaker playback' choice=speakers
[INFO] 2025-09-12 05:24:47 - Watchdog/timeout: 0
[INFO] 2025-09-12 05:24:47 - [play_wav_short] loop 1/1 start=2025-09-12T05:24:47Z clip=AudioClips/yesterday_48KHz.wav backend=pipewire sink=speakers(72)
[INFO] 2025-09-12 05:24:47 - [play_wav_short] exec: pw-play -v "AudioClips/yesterday_48KHz.wav"
[INFO] 2025-09-12 05:26:52 - [play_wav_short] evidence: pw_streaming=1 pa_streaming=0 alsa_running=1 asoc_path_on=1 pw_log=1
[PASS] 2025-09-12 05:26:52 - [play_wav_short] loop 1 OK (rc=0, 125s)
[INFO] 2025-09-12 05:26:52 - Scanning dmesg for snd|audio|pipewire|pulseaudio: errors & success patterns
[INFO] 2025-09-12 05:26:52 - No snd|audio|pipewire|pulseaudio-related errors found (no OK pattern requested)
[INFO] 2025-09-12 05:26:52 - Summary: total=1 pass=1 fail=0 skip=0
[PASS] 2025-09-12 05:26:52 - AudioPlayback PASS
```

Results:
Results are stored in: results/AudioPlayback/
Summary result file: AudioPlayback.res
JUnit XML (if enabled): <your-path>.xml
Diagnostic logs: dmesg snapshots, mixer dumps, playback logs per test case


## Notes

- The script validates the presence of required tools before executing tests; missing tools result in SKIP.
- If any critical tool is missing, the script exits with an error message.
- Logs include dmesg snapshots, mixer dumps, and playback logs.
- Asset download requires network connectivity.
- Pass Wi-Fi credentials via SSID and PASSWORD environment variables to enable network access for asset downloads and playback validation.
- You can override default network probe targets using NET_PROBE_ROUTE_IP and NET_PING_HOST to avoid connectivity-related failures in restricted environments.
- Evidence-based PASS/FAIL logic ensures reliability even if backend quirks occur.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.

