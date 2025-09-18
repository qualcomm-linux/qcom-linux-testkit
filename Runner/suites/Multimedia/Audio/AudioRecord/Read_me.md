# Audio Record Validation Script for Qualcomm Linux-based Platform (Yocto)

## Overview

This suite automates the validation of audio recording capabilities on Qualcomm Linux-based platforms running a Yocto-based Linux system. It supports both PipeWire and PulseAudio backends, with robust evidence-based PASS/FAIL logic, asset management, and diagnostic logging.

## Features


- Supports **PipeWire** and **PulseAudio** backends
- Records audio clips with configurable duration and loop count
- Automatically detects and routes to appropriate source (e.g., mic, null)
- Validates recording using multiple evidence sources:
  - PipeWire/PulseAudio streaming state
  - ALSA and ASoC runtime status
  - Kernel logs (`dmesg`)
- Diagnostic logs: dmesg scan, mixer dumps, playback logs
- Evidence-based validation (user-space, ALSA, ASoC, dmesg)
- Generates `.res` result file and optional JUnit XML output


## Prerequisites

Ensure the following components are present in the target Yocto build:

- PipeWire: `pw-record`, `wpctl`
- PulseAudio: `parecord`, `pactl`
- Common tools: `pgrep`, `timeout`, `grep`, `sed`
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
            ├── AudioRecord/
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
cd <Path in device>Runner

# Run Audiorecord using PipeWire (auto-detects backend if not specified)
./run-test.sh Audiorecord

# Force PulseAudio backend
AUDIO_BACKEND=pulseaudio ./run-test.sh Audiorecord

# Custom options via environment variables
AUDIO_BACKEND=pipewire RECORD_TIMEOUT=20s RECORD_LOOPS=2 RECORD_VOLUME=0.5 ./run-test.sh Audiorecord


**Directly from Test Directory**
cd Runner/suites/Multimedia/Audio/Audiorecord

# Show usage/help
./run.sh --help

# Run with PipeWire, 3 loops, 10s timeout, mic source
./run.sh --backend pipewire --source mic --loops 3 --timeout 10s

# Run with PulseAudio, null source, strict mode, verbose
./run.sh --backend pulseaudio --source null --strict --verbose


Environment Variables:
Variable	      Description	                                   Default
AUDIO_BACKEND	  Selects backend: pipewire or pulseaudio	       auto-detect
SOURCE_CHOICE	  Recording source: mic or null	                   mic
DURATIONS	      Recording durations: short, medium, long	       short
RECORD_SECONDS	  Number of seconds to record (numeric or mapped)  5
LOOPS	          Number of recording loops	                       1
TIMEOUT	          Recording timeout per loop (e.g., 15s, 0=none)   0
STRICT	          Enable strict mode (fail on any error)	       0
DMESG_SCAN	      Scan dmesg for errors after recording	           1
VERBOSE	          Enable verbose logging	                       0
JUNIT_OUT	      Path to write JUnit XML output	               unset


CLI Options:
Option	          Description
--backend	      Select backend: pipewire or pulseaudio
--source	      Recording source: mic or null
--durations	      Recording durations: short, medium, long
--record-seconds  Number of seconds to record (numeric or mapped)
--loops	          Number of recording loops
--timeout	      Recording timeout per loop (e.g., 15s)
--strict	      Enable strict mode
--no-dmesg	      Disable dmesg scan
--junit<file.xml> Write JUnit XML output
--verbose	      Enable verbose logging
--help	          Show usage instructions
```

Sample Output:
```
sh-5.2# ./run.sh --backend pipewire
[INFO] 2025-09-12 06:06:04 - ---------------- Starting AudioRecord ----------------
[INFO] 2025-09-12 06:06:04 - SoC: 498
[INFO] 2025-09-12 06:06:04 - Args: backend=pipewire source=mic loops=1 durations='short' rec_secs=30s timeout=0 strict=0 dmesg=1
[INFO] 2025-09-12 06:06:04 - Using backend: pipewire
[INFO] 2025-09-12 06:06:04 - Routing to source: id/name=48 label='pal source handset mic' choice=mic
[INFO] 2025-09-12 06:06:04 - Watchdog/timeout: 0
[INFO] 2025-09-12 06:06:04 - [record_short] loop 1/1 start=2025-09-12T06:06:04Z secs=30s backend=pipewire source=mic(48)
[INFO] 2025-09-12 06:06:04 - [record_short] exec: pw-record -v "results/AudioRecord/record_short.wav"
[WARN] 2025-09-12 06:06:34 - [record_short] nonzero rc=124 but recording looks valid (bytes=5738540) - PASS
[INFO] 2025-09-12 06:06:34 - [record_short] evidence: pw_streaming=1 pa_streaming=0 alsa_running=1 asoc_path_on=1 bytes=5738540 pw_log=1
[PASS] 2025-09-12 06:06:34 - [record_short] loop 1 OK (rc=0, 30s, bytes=5738540)
[INFO] 2025-09-12 06:06:34 - Scanning dmesg for snd|audio|pipewire|pulseaudio: errors & success patterns
[INFO] 2025-09-12 06:06:34 - No snd|audio|pipewire|pulseaudio-related errors found (no OK pattern requested)
[INFO] 2025-09-12 06:06:34 - Summary: total=1 pass=1 fail=0 skip=0
[PASS] 2025-09-12 06:06:34 - AudioRecord PASS
```

Results:
- Results are stored in: results/Audiorecord/
- Summary result file: Audiorecord.res
- JUnit XML (if enabled): <your-path>.xml
- Diagnostic logs: dmesg snapshots, mixer dumps, record logs per test case


## Notes

- The script validates the presence of required tools before executing tests; missing tools result in SKIP.
- If any critical tool is missing, the script exits with an error message.
- Logs include dmesg snapshots, mixer dumps, and record logs.
- Evidence-based PASS/FAIL logic ensures reliability even if backend quirks occur.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.

