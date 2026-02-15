# Audio Record Validation Script for Qualcomm Linux-based Platform (Yocto)

## Overview

This suite automates the validation of audio recording capabilities on Qualcomm Linux-based platforms running a Yocto-based Linux system. It supports both PipeWire and PulseAudio backends, with robust evidence-based PASS/FAIL logic, asset management, and diagnostic logging.

## Features

- Supports **PipeWire** and **PulseAudio** backends
- **10-config test coverage**: Comprehensive validation across diverse audio formats (sample rates: 8KHz-96KHz, channels: 1ch-6ch)
- **Flexible config selection**: 
  - Use generic config names (record_config1-record_config10) for easy selection
  - Use descriptive names (e.g., record_48KHz_2ch) for specific formats
  - Auto-discovery mode tests all available configs
- **Config filtering**: Filter tests by sample rate or channel configuration
- Records audio with configurable duration and loop count
- Automatically detects and routes to appropriate source (e.g., mic, null)
- Validates recording using multiple evidence sources:
  - PipeWire/PulseAudio streaming state
  - ALSA and ASoC runtime status
  - Kernel logs (`dmesg`)
- Diagnostic logs: dmesg scan, mixer dumps, recording logs
- Evidence-based validation (user-space, ALSA, ASoC, dmesg)
- Generates `.res` result file and optional JUnit XML output

## Audio Record Configurations

The test suite includes 10 diverse audio record configurations covering various sample rates and channel configurations:

```  
| Config   | Config Name      | Sample Rate | Channels |
|----------|------------------|-------------|----------|
| Config01 | record_config1   | 8 KHz       | 1ch      |
| Config02 | record_config2   | 16 KHz      | 1ch      |
| Config03 | record_config3   | 16 KHz      | 2ch      |
| Config04 | record_config4   | 24 KHz      | 1ch      |
| Config05 | record_config5   | 32 KHz      | 2ch      |
| Config06 | record_config6   | 44.1 KHz    | 2ch      |
| Config07 | record_config7   | 48 KHz      | 2ch      |
| Config08 | record_config8   | 48 KHz      | 6ch      |
| Config09 | record_config9   | 96 KHz      | 2ch      |
| Config10 | record_config10  | 96 KHz      | 6ch      |
```   

**Coverage Summary:**
- Sample Rates: 8 KHz, 16 KHz, 24 KHz, 32 KHz, 44.1 KHz, 48 KHz, 96 KHz
- Channel Configurations: 1ch (Mono), 2ch (Stereo), 6ch (5.1 Surround)
- Total Configurations: 10 unique audio format combinations

## Prerequisites

Ensure the following components are present in the target Yocto build:

- PipeWire: `pw-record`, `wpctl`
- PulseAudio: `parecord`, `pactl`
- ALSA: `arecord`
- Common tools: `pgrep`, `timeout`, `grep`, `sed`
- Daemon: `pipewire` or `pulseaudio` must be running

## Overlay Build Support

For overlay builds using audioreach kernel modules, the test automatically:
- Detects the overlay build configuration
- Sets required DMA heap permissions
- Restarts PipeWire service
- Waits for the service to be ready

This happens transparently before tests run. No manual configuration needed.

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
            └── AudioRecord/
                ├── run.sh         
                ├── Read_me.md
                ├── AudioRecord.yaml
                ├── AudioRecord_Config01.yaml
                ├── AudioRecord_Config02.yaml
                ├── ...
                └── AudioRecord_Config10.yaml
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

# Run AudioRecord using PipeWire (auto-detects backend if not specified)
./run-test.sh AudioRecord

# Force PulseAudio backend
AUDIO_BACKEND=pulseaudio ./run-test.sh AudioRecord

# Custom options via environment variables
AUDIO_BACKEND=pipewire RECORD_SECONDS=10s LOOPS=2 ./run-test.sh AudioRecord


**Directly from Test Directory**
cd Runner/suites/Multimedia/Audio/AudioRecord

# Test all 10 configs (auto-discovery mode)
./run.sh

# Test specific configs using config naming (record_config1 to record_config10)
./run.sh --config-name "record_config1"
./run.sh --config-name "record_config1 record_config2 record_config3"

# Test specific configs using descriptive names
./run.sh --config-name "record_48KHz_2ch"
./run.sh --config-name "record_8KHz_1ch"
./run.sh --config-name "record_96KHz_6ch"

# Filter configs by sample rate
./run.sh --config-filter "48KHz"
./run.sh --config-filter "96KHz"

# Filter configs by channel configuration
./run.sh --config-filter "1ch"
./run.sh --config-filter "2ch"
./run.sh --config-filter "6ch"

# Combine filters (tests configs matching any pattern)
./run.sh --config-filter "48KHz 2ch"

# Show usage/help
./run.sh --help

# Run with PipeWire, 3 loops, 10s timeout, mic source
./run.sh --backend pipewire --source mic --loops 3 --timeout 10s

# Run with PulseAudio, null source, strict mode, verbose
./run.sh --backend pulseaudio --source null --strict --verbose

# Provide JUnit output and disable dmesg scan
./run.sh --junit results.xml --no-dmesg

# CI/LAVA workflow: Using pre-configured YAML files
# Each configuration has its own YAML file in the same directory as run.sh
# These can be run directly by LAVA as separate test cases

# Method 1: Using the pre-configured YAML files directly (recommended for LAVA)
# LAVA will execute these automatically based on the YAML definitions

# Method 2: Using run.sh with specific configurations
./run.sh --config-name "record_config1" --res-suffix "Config01" --record-seconds 10s
./run.sh --config-name "record_config7" --res-suffix "Config07" --record-seconds 10s
./run.sh --config-name "record_config10" --res-suffix "Config10" --record-seconds 10s
# This generates AudioRecord_Config01.res, AudioRecord_Config07.res, and AudioRecord_Config10.res (no overwriting)


Environment Variables:
Variable	      Description	                                                  Default
AUDIO_BACKEND	  Selects backend: pipewire or pulseaudio	                      auto-detect
SOURCE_CHOICE	  Recording source: mic or null                                   mic
CONFIG_NAMES      Test specific configs (e.g., "record_config1 record_config2")   record_config1
CONFIG_FILTER     Filter configs by pattern (e.g., "48KHz" or "2ch")              unset
DURATIONS	      Recording durations: short, medium, long (legacy mode only)     ""
RECORD_SECONDS	  Number of seconds to record (e.g., 5s, 10s)                     30s
LOOPS	          Number of recording loops	                                      1
TIMEOUT	          Recording timeout per loop (e.g., 15s, 0=none)                  0
STRICT	          Strict mode (0=disabled, 1=enabled, fail on any error)	      0
DMESG_SCAN	      Scan dmesg for errors after recording	                          1
VERBOSE	          Enable verbose logging	                                      0
JUNIT_OUT	      Path to write JUnit XML output	                              unset
RES_SUFFIX        Suffix for unique result file and log directory                 unset


CLI Options:
Option	                      Description
--backend	                  Select backend: pipewire or pulseaudio
--source	                  Recording source: mic or null
--config-name <names>         Test specific configs using record_config1-record_config10 or descriptive names (space-separated)
--config-filter <patterns>    Filter configs by sample rate or channels (space-separated patterns)
--record-seconds <duration>   Number of seconds to record (e.g., 5s, 10s)
--durations	                  Recording durations: short, medium, long (legacy mode only)
--loops	                      Number of recording loops
--timeout	                  Recording timeout per loop (e.g., 15s)
--strict [0|1]                Enable strict mode (0=disabled, 1=enabled)
--no-dmesg	                  Disable dmesg scan
--res-suffix <suffix>         Suffix for unique result file and log directory (e.g., "Config01" generates AudioRecord_Config01.res and results/AudioRecord_Config01/)
--junit <file.xml>            Write JUnit XML output
--verbose	                  Enable verbose logging
--help	                      Show usage instructions
```

Sample Output:

**Example 1: Testing specific config using config naming**
```
sh-5.3# ./run.sh --config-name "record_config1"
[INFO] 2026-01-02 12:00:46 - Base build detected (no audioreach modules), skipping overlay setup
[INFO] 2026-01-02 12:00:46 - ---------------- Starting AudioRecord ----------------
[INFO] 2026-01-02 12:00:46 - Platform Details: machine='Qualcomm Technologies, Inc. Robotics RB3gen2' target='Kodiak' kernel='6.18.0-00393-g27507852413b' arch='aarch64'
[INFO] 2026-01-02 12:00:46 - Args: backend=auto source=mic loops=1 durations='short' record_seconds=30s timeout=0 strict=0 dmesg=1
[INFO] 2026-01-02 12:00:46 - Backend fallback chain: pipewire pulseaudio alsa
[INFO] 2026-01-02 12:00:46 - Using backend: pipewire
[INFO] 2026-01-02 12:00:46 - Routing to source: id/name=45 label='Built-in Audio internal Mic' choice=mic
[INFO] 2026-01-02 12:00:46 - Watchdog/timeout: disabled (no timeout)
[INFO] 2026-01-02 12:00:46 - Using config discovery mode
[INFO] 2026-01-02 12:00:46 - Discovered 1 configs to test
[INFO] 2026-01-02 12:00:46 - [record_8KHz_1ch] Using config: record_config1 (rate=8000Hz channels=1)
[INFO] 2026-01-02 12:00:46 - [record_8KHz_1ch] loop 1/1 start=2026-01-02T12:00:46Z rate=8000Hz channels=1 backend=pipewire source=mic(45)
[INFO] 2026-01-02 12:00:46 - [record_8KHz_1ch] exec: pw-record -v --rate=8000 --channels=1 "results/AudioRecord/record_8KHz_1ch.wav"
[WARN] 2026-01-02 12:01:16 - [record_8KHz_1ch] nonzero rc=124 but recording looks valid (bytes=482634) - PASS
[INFO] 2026-01-02 12:01:16 - [record_8KHz_1ch] evidence: pw_streaming=1 pa_streaming=0 alsa_running=1 asoc_path_on=1 bytes=482634 pw_log=1
[PASS] 2026-01-02 12:01:16 - [record_8KHz_1ch] loop 1 OK (rc=0, 30s, bytes=482634)
[INFO] 2026-01-02 12:01:16 - No relevant, non-benign errors for modules [results/AudioRecord] in recent dmesg.
[INFO] 2026-01-02 12:01:16 - Summary: total=1 pass=1 fail=0 skip=0
[PASS] 2026-01-02 12:01:16 - AudioRecord PASS
```

**Example 2: Testing multiple configs**
```
sh-5.3# ./run.sh --config-name "record_config1 record_config2"
[INFO] 2026-01-02 11:47:53 - Using config discovery mode
[INFO] 2026-01-02 11:47:53 - Discovered 2 configs to test
[INFO] 2026-01-02 11:47:53 - [record_8KHz_1ch] Using config: record_config1 (rate=8000Hz channels=1)
[PASS] 2026-01-02 11:48:23 - [record_8KHz_1ch] loop 1 OK (rc=0, 30s, bytes=482292)
[INFO] 2026-01-02 11:48:23 - [record_16KHz_1ch] Using config: record_config2 (rate=16000Hz channels=1)
[PASS] 2026-01-02 11:48:53 - [record_16KHz_1ch] loop 1 OK (rc=0, 30s, bytes=957768)
[INFO] 2026-01-02 11:48:53 - Summary: total=2 pass=2 fail=0 skip=0
[PASS] 2026-01-02 11:48:53 - AudioRecord PASS
```

**Example 3: Filtering configs by sample rate**
```
sh-5.3# ./run.sh --config-filter "48KHz"
[INFO] 2026-01-02 11:52:22 - Using config discovery mode
[INFO] 2026-01-02 11:52:22 - Discovered 2 configs to test
[INFO] 2026-01-02 11:52:22 - [record_48KHz_2ch] Using config: record_config7 (rate=48000Hz channels=2)
[PASS] 2026-01-02 11:52:53 - [record_48KHz_2ch] loop 1 OK (rc=0, 31s, bytes=5791788)
[INFO] 2026-01-02 11:52:53 - [record_48KHz_6ch] Using config: record_config8 (rate=48000Hz channels=6)
[PASS] 2026-01-02 11:53:23 - [record_48KHz_6ch] loop 1 OK (rc=0, 30s, bytes=17240144)
[INFO] 2026-01-02 11:53:23 - Summary: total=2 pass=2 fail=0 skip=0
[PASS] 2026-01-02 11:53:23 - AudioRecord PASS
```

**Example 4: Filtering configs by channel configuration**
```
sh-5.3# ./run.sh --config-filter "2ch"
[INFO] 2026-01-02 11:53:38 - Using config discovery mode
[INFO] 2026-01-02 11:53:38 - Discovered 5 configs to test
[INFO] 2026-01-02 11:53:38 - [record_16KHz_2ch] Using config: record_config3 (rate=16000Hz channels=2)
[PASS] 2026-01-02 11:54:08 - [record_16KHz_2ch] loop 1 OK (rc=0, 30s, bytes=1930512)
[INFO] 2026-01-02 11:54:08 - [record_32KHz_2ch] Using config: record_config5 (rate=32000Hz channels=2)
[PASS] 2026-01-02 11:54:38 - [record_32KHz_2ch] loop 1 OK (rc=0, 30s, bytes=3833788)
[INFO] 2026-01-02 11:54:38 - [record_44.1KHz_2ch] Using config: record_config6 (rate=44100Hz channels=2)
[PASS] 2026-01-02 11:55:08 - [record_44.1KHz_2ch] loop 1 OK (rc=0, 30s, bytes=5283464)
[INFO] 2026-01-02 11:55:08 - [record_48KHz_2ch] Using config: record_config7 (rate=48000Hz channels=2)
[PASS] 2026-01-02 11:55:38 - [record_48KHz_2ch] loop 1 OK (rc=0, 30s, bytes=5746732)
[INFO] 2026-01-02 11:55:38 - [record_96KHz_2ch] Using config: record_config9 (rate=96000Hz channels=2)
[PASS] 2026-01-02 11:56:09 - [record_96KHz_2ch] loop 1 OK (rc=0, 30s, bytes=11509556)
[INFO] 2026-01-02 11:56:09 - Summary: total=5 pass=5 fail=0 skip=0
[PASS] 2026-01-02 11:56:09 - AudioRecord PASS
```

**Example 5: Invalid config name (shows helpful error)**
```
sh-5.3# ./run.sh --config-name "record_config99"
[INFO] 2026-01-02 11:59:34 - Using config discovery mode
[SKIP] 2026-01-02 11:59:34 - AudioRecord SKIP - [ERROR] 2026-01-02 11:59:34 - Available range: record_config1 to record_config10
```

**Example 6: CI/LAVA workflow with unique result files**
```
sh-5.3# ./run.sh --config-name "record_config1" --res-suffix "Config01" --record-seconds 10s
[INFO] 2026-01-12 07:14:09 - Using unique result file: ./AudioRecord_Config01.res
[INFO] 2026-01-12 07:14:09 - ---------------- Starting AudioRecord ----------------
[INFO] 2026-01-12 07:14:09 - Using config discovery mode
[INFO] 2026-01-12 07:14:09 - Discovered 1 configs to test
[INFO] 2026-01-12 07:14:09 - [record_8KHz_1ch] Using config: record_config1 (rate=8000Hz channels=1)
[PASS] 2026-01-12 07:14:19 - [record_8KHz_1ch] loop 1 OK (rc=0, 10s, bytes=162462)
[PASS] 2026-01-12 07:14:19 - AudioRecord PASS

sh-5.3# cat AudioRecord_Config01.res
AudioRecord PASS

sh-5.3# ./run.sh --config-name "record_config7" --res-suffix "Config07" --record-seconds 10s
[INFO] 2026-01-12 07:16:01 - Using unique result file: ./AudioRecord_Config07.res
[PASS] 2026-01-12 07:16:11 - AudioRecord PASS

sh-5.3# cat AudioRecord_Config07.res
AudioRecord PASS

# Both result files exist without overwriting
sh-5.3# ls -1 AudioRecord*.res
AudioRecord_Config01.res
AudioRecord_Config07.res
```

**Example 7: Testing all 10 configs with short duration**
```
sh-5.3# ./run.sh --record-seconds 3s
[INFO] 2026-01-02 12:05:26 - Auto-detected config discovery mode (testing all 10 record configs)
[INFO] 2026-01-02 12:05:26 - Using config discovery mode
[INFO] 2026-01-02 12:05:26 - Discovered 10 configs to test
[INFO] 2026-01-02 12:05:26 - [record_8KHz_1ch] Using config: record_config1 (rate=8000Hz channels=1)
[PASS] 2026-01-02 12:05:30 - [record_8KHz_1ch] loop 1 OK (rc=0, 3s, bytes=49822)
[INFO] 2026-01-02 12:05:30 - [record_16KHz_1ch] Using config: record_config2 (rate=16000Hz channels=1)
[PASS] 2026-01-02 12:05:33 - [record_16KHz_1ch] loop 1 OK (rc=0, 3s, bytes=96242)
[INFO] 2026-01-02 12:05:33 - [record_16KHz_2ch] Using config: record_config3 (rate=16000Hz channels=2)
[PASS] 2026-01-02 12:05:36 - [record_16KHz_2ch] loop 1 OK (rc=0, 3s, bytes=186980)
[INFO] 2026-01-02 12:05:36 - [record_24KHz_1ch] Using config: record_config4 (rate=24000Hz channels=1)
[PASS] 2026-01-02 12:05:39 - [record_24KHz_1ch] loop 1 OK (rc=0, 3s, bytes=142322)
[INFO] 2026-01-02 12:05:39 - [record_32KHz_2ch] Using config: record_config5 (rate=32000Hz channels=2)
[PASS] 2026-01-02 12:05:42 - [record_32KHz_2ch] loop 1 OK (rc=0, 3s, bytes=376764)
[INFO] 2026-01-02 12:05:42 - [record_44.1KHz_2ch] Using config: record_config6 (rate=44100Hz channels=2)
[PASS] 2026-01-02 12:05:46 - [record_44.1KHz_2ch] loop 1 OK (rc=0, 4s, bytes=523016)
[INFO] 2026-01-02 12:05:46 - [record_48KHz_2ch] Using config: record_config7 (rate=48000Hz channels=2)
[PASS] 2026-01-02 12:05:49 - [record_48KHz_2ch] loop 1 OK (rc=0, 3s, bytes=565292)
[INFO] 2026-01-02 12:05:49 - [record_48KHz_6ch] Using config: record_config8 (rate=48000Hz channels=6)
[PASS] 2026-01-02 12:05:52 - [record_48KHz_6ch] loop 1 OK (rc=0, 3s, bytes=1695824)
[INFO] 2026-01-02 12:05:52 - [record_96KHz_2ch] Using config: record_config9 (rate=96000Hz channels=2)
[PASS] 2026-01-02 12:05:55 - [record_96KHz_2ch] loop 1 OK (rc=0, 3s, bytes=1138484)
[INFO] 2026-01-02 12:05:55 - [record_96KHz_6ch] Using config: record_config10 (rate=96000Hz channels=6)
[PASS] 2026-01-02 12:05:59 - [record_96KHz_6ch] loop 1 OK (rc=0, 3s, bytes=3415400)
[INFO] 2026-01-02 12:05:59 - Summary: total=10 pass=10 fail=0 skip=0
[PASS] 2026-01-02 12:05:59 - AudioRecord PASS
```

Results:
- Results are stored in: results/AudioRecord/ (or results/AudioRecord_<suffix>/ when using --res-suffix)
- Summary result file: AudioRecord.res (or AudioRecord_<suffix>.res when using --res-suffix)
- JUnit XML (if enabled): <your-path>.xml
- Diagnostic logs: dmesg snapshots, mixer dumps, record logs per test case
- **Note**: When using --res-suffix, both result files AND log directories are unique per invocation, preventing log collisions in CI/LAVA workflows


## Notes

- The script validates the presence of required tools before executing tests; missing tools result in SKIP.
- If any critical tool is missing, the script exits with an error message.
- Logs include dmesg snapshots, mixer dumps, and record logs.
- Evidence-based PASS/FAIL logic ensures reliability even if backend quirks occur.
- **Config discovery mode** is enabled by default, testing all 10 configurations automatically.
- Use `--config-name` to test specific configurations or `--config-filter` to filter by sample rate or channels.
- The `--durations` option is for legacy matrix mode only; use `--config-name` or `--config-filter` for config discovery mode (recommended).

## License

SPDX-License-Identifier: BSD-3-Clause(C) Qualcomm Technologies, Inc. and/or its subsidiaries.
