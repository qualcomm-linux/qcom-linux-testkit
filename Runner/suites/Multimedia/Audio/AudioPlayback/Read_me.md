# Audio Playback Validation Script for Qualcomm Linux-based Platform (Yocto)

## Overview

This suite automates the validation of audio playback capabilities on Qualcomm Linux-based platforms running a Yocto-based Linux system. It supports both PipeWire and PulseAudio backends, with robust evidence-based PASS/FAIL logic, asset management, and diagnostic logging.


## Features

- Supports **PipeWire** and **PulseAudio** backends
- **10-clip test coverage**: Comprehensive validation across diverse audio formats (sample rates: 8KHz-48KHz, bit depths: 8b-32b, channels: 1ch-8ch)
- **Flexible clip selection**: 
  - Use generic config names (playback_config1-playback_config10) for easy selection
  - Use descriptive names (e.g., play_48KHz_8b_2ch) for specific formats
  - Auto-discovery mode tests all available clips
- **Clip filtering**: Filter tests by sample rate, bit rate, or channel configuration
- Plays audio clips with configurable format, duration, and loop count
- **Network operations are optional**: By default, no network connection is attempted. Use `--enable-network-download` to enable downloading missing audio files
- Automatically downloads and extracts audio assets if missing
- Validates playback using multiple evidence sources:
  - PipeWire/PulseAudio streaming state
  - ALSA and ASoC runtime status
  - Kernel logs (`dmesg`)
- Diagnostic logs: dmesg scan, mixer dumps, playback logs	
- Evidence-based validation (user-space, ALSA, ASoC, dmesg)	
- Generates `.res` result file and optional JUnit XML output
								 

## Audio Clip Configurations

The test suite includes 10 diverse audio clip configurations covering various sample rates, bit depths, and channel configurations:

Playback Config     Descriptive Name         Sample Rate    Bit Rate    Channels
playback_config1    play_16KHz_16b_2ch       16 KHz         16-bit      2ch
playback_config2    play_16KHz_8b_6ch        16 KHz         8-bit       6ch
playback_config3    play_22.050KHz_8b_1ch    22.05 KHz      8-bit       1ch
playback_config4    play_24KHz_24b_6ch       24 KHz         24-bit      6ch
playback_config5    play_24KHz_32b_1ch       24 KHz         32-bit      1ch
playback_config6    play_32KHz_16b_2ch       32 KHz         16-bit      2ch
playback_config7    play_32KHz_8b_8ch        32 KHz         8-bit       8ch
playback_config8    play_44.1KHz_16b_1ch     44.1 KHz       16-bit      1ch
playback_config9    play_48KHz_8b_2ch        48 KHz         8-bit       2ch
playback_config10   play_8KHz_8b_1ch         8 KHz          8-bit       1ch

Coverage Summary:
- Sample Rates: 8 KHz, 16 KHz, 22.05 KHz, 24 KHz, 32 KHz, 44.1 KHz, 48 KHz
- Bit Depths: 8-bit, 16-bit, 24-bit, 32-bit
- Channel Configurations: 1ch (Mono), 2ch (Stereo), 6ch (5.1 Surround), 8ch (7.1 Surround)
- Total Configurations: 10 unique audio format combinations

## Prerequisites

Ensure the following components are present in the target Yocto build:

- PipeWire: `pw-play`, `wpctl`
- PulseAudio: `paplay`, `pactl`
- Common tools: `pgrep`, `timeout`, `grep`, `wget`, `tar`
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

# Run without network (requires local clips)
./run.sh

# Enable network download for missing clips
./run.sh --enable-network-download

# Provide WiFi credentials (auto-enables download)
./run.sh --ssid "MyNetwork" --password "MyPassword"

# Offline mode with local clips only
./run.sh --no-extract-assets

# CI workflow: Use pre-staged clips at custom location
./run.sh --audio-clips-path /tmp/ci-audio-staging/AudioClips

# CI workflow: Via environment variable
AUDIO_CLIPS_BASE_DIR="/tmp/ci-audio-staging/AudioClips" ./run-test.sh AudioPlayback

**Directly from Test Directory**
cd Runner/suites/Multimedia/Audio/AudioPlayback

# Test all 10 clips (auto-discovery mode)
./run.sh --no-extract-assets

# Test specific clips using playback_config naming (playback_config1 to playback_config10)
./run.sh --no-extract-assets --clip-name "playback_config1"
./run.sh --no-extract-assets --clip-name "playback_config1 playback_config5 playback_config10"

# Test specific clips using descriptive names
./run.sh --no-extract-assets --clip-name "play_48KHz_8b_2ch"
./run.sh --no-extract-assets --clip-name "play_8KHz_8b_1ch"
./run.sh --no-extract-assets --clip-name "play_44.1KHz_16b_1ch"

# Filter clips by sample rate
./run.sh --no-extract-assets --clip-filter "48KHz"
./run.sh --no-extract-assets --clip-filter "16KHz"

# Filter clips by bit depth
./run.sh --no-extract-assets --clip-filter "16b"
./run.sh --no-extract-assets --clip-filter "24b"

# Filter clips by channel configuration
./run.sh --no-extract-assets --clip-filter "2ch"
./run.sh --no-extract-assets --clip-filter "8ch"

# Combine filters (tests clips matching any pattern)
./run.sh --no-extract-assets --clip-filter "48KHz 16b"
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

# CI/LAVA workflow: Generate unique result files for each test
./run.sh --clip-name "playback_config1" --res-suffix "Config1" --audio-clips-path /home/AudioClips/ --no-extract-assets
./run.sh --clip-name "playback_config7" --res-suffix "Config7" --audio-clips-path /home/AudioClips/ --no-extract-assets
# This generates AudioPlayback_Config1.res and AudioPlayback_Config7.res (no overwriting)



Environment Variables:
Variable	             Description	                                   Default
AUDIO_BACKEND	         Selects backend: pipewire or pulseaudio	       auto-detect
SINK_CHOICE	             Playback sink: speakers or null	               speakers
FORMATS	                 Audio formats: e.g. wav	                       wav
DURATIONS	             Playback durations: short, medium, long	       short
LOOPS	                 Number of playback loops	                       1
TIMEOUT	                 Playback timeout per loop (e.g., 15s, 0=none)     0
STRICT	                 Enable strict mode (fail on any error)            0
DMESG_SCAN	             Scan dmesg for errors after playback	           1
VERBOSE	                 Enable verbose logging                            0
EXTRACT_AUDIO_ASSETS     Download/extract audio assets if missing	       true
ENABLE_NETWORK_DOWNLOAD  Enable network download of missing audio files    false
AUDIO_CLIPS_BASE_DIR     Custom path to pre-staged audio clips (CI use)    unset
JUNIT_OUT                Path to write JUnit XML output                    unset
SSID                     Wi-Fi SSID for network connection                 unset
PASSWORD                 Wi-Fi password for network connection             unset
NET_PROBE_ROUTE_IP       IP used for route probing (default: 1.1.1.1)      1.1.1.1
NET_PING_HOST            Host used for ping reachability check             8.8.8.8


CLI Options
Option	                    Description
--backend	                Select backend: pipewire or pulseaudio
--sink	                    Playback sink: speakers or null
--clip-name <names>         Test specific clips using playback_config1-playback_config10 or descriptive names (space-separated)
--clip-filter <patterns>    Filter clips by sample rate, bit rate, or channels (space-separated patterns)
--formats	                Audio formats (space/comma separated): e.g. wav 
--durations	                Playback durations: short, medium, long
--loops	                    Number of playback loops
--timeout	                Playback timeout per loop (e.g., 15s)
--strict	                Enable strict mode
--no-dmesg	                Disable dmesg scan
--no-extract-assets         Disable asset extraction entirely (skips all asset operations)
--enable-network-download   Enable network operations to download missing audio files (default: disabled)
--audio-clips-path <path>   Custom location for audio clips (for CI with pre-staged clips)
--res-suffix <suffix>       Suffix for unique result file and log directory (e.g., "Config1" generates AudioPlayback_Config1.res and results/AudioPlayback_Config1/)
--junit <file.xml>	        Write JUnit XML output
--verbose	                Enable verbose logging
--help	                    Show usage instructions

```

Sample Output:

**Example 1: Testing specific clip using playback_config naming**
```
sh-5.3# ./run.sh --no-extract-assets --clip-name "playback_config1"
[INFO] 2026-01-22 17:46:33 - ---------------- Starting AudioPlayback ----------------
[INFO] 2026-01-22 17:46:33 - Platform Details: machine='Qualcomm Technologies, Inc. Robotics RB3gen2' target='Kodiak' kernel='6.18.0-00393-g27507852413b' arch='aarch64'
[INFO] 2026-01-22 17:46:33 - Args: backend=auto sink=speakers loops=1 timeout=0 formats='wav' durations='short' strict=0 dmesg=1 extract=false network_download=false clips_path=default
[INFO] 2026-01-22 17:46:33 - Using backend: pipewire
[INFO] 2026-01-22 17:46:33 - Routing to sink: id=52 name='Built-in Audio Speaker playback' choice=speakers
[INFO] 2026-01-22 17:46:33 - Using clip discovery mode
[INFO] 2026-01-22 17:46:33 - Discovered 1 clips to test
[INFO] 2026-01-22 17:46:33 - [play_16KHz_16b_2ch] Using clip: yesterday_16KHz_30s_16b_2ch.wav (1922036 bytes)
[INFO] 2026-01-22 17:46:33 - [play_16KHz_16b_2ch] loop 1/1 start=2026-01-22T17:46:33Z clip=yesterday_16KHz_30s_16b_2ch.wav backend=pipewire sink=speakers(52)
[INFO] 2026-01-22 17:46:33 - [play_16KHz_16b_2ch] exec: pw-play -v "AudioClips/yesterday_16KHz_30s_16b_2ch.wav"
[INFO] 2026-01-22 17:47:04 - [play_16KHz_16b_2ch] evidence: pw_streaming=1 pa_streaming=0 alsa_running=1 asoc_path_on=1 pw_log=1
[PASS] 2026-01-22 17:47:04 - [play_16KHz_16b_2ch] loop 1 OK (rc=0, 30s)
[INFO] 2026-01-22 17:47:04 - Summary: total=1 pass=1 fail=0 skip=0
[PASS] 2026-01-22 17:47:04 - AudioPlayback PASS
```

**Example 2: Testing multiple clips**
```
sh-5.3# ./run.sh --no-extract-assets --clip-name "playback_config1 playback_config3 playback_config5"
[INFO] 2026-01-22 17:42:30 - Using clip discovery mode
[INFO] 2026-01-22 17:42:30 - Discovered 3 clips to test
[INFO] 2026-01-22 17:42:30 - [play_16KHz_16b_2ch] Using clip: yesterday_16KHz_30s_16b_2ch.wav (1922036 bytes)
[PASS] 2026-01-22 17:43:00 - [play_16KHz_16b_2ch] loop 1 OK (rc=0, 30s)
[INFO] 2026-01-22 17:43:00 - [play_22.050KHz_8b_1ch] Using clip: yesterday_22.050KHz_30s_8b_1ch.wav (662284 bytes)
[PASS] 2026-01-22 17:43:30 - [play_22.050KHz_8b_1ch] loop 1 OK (rc=0, 30s)
[INFO] 2026-01-22 17:43:31 - [play_24KHz_32b_1ch] Using clip: yesterday_24KHz_30s_32b_1ch.wav (2883004 bytes)
[PASS] 2026-01-22 17:44:01 - [play_24KHz_32b_1ch] loop 1 OK (rc=0, 30s)
[INFO] 2026-01-22 17:44:01 - Summary: total=3 pass=3 fail=0 skip=0
[PASS] 2026-01-22 17:44:01 - AudioPlayback PASS
```

**Example 3: Filtering clips by sample rate**
```
sh-5.3# ./run.sh --no-extract-assets --clip-filter "48KHz"
[INFO] 2026-01-22 17:54:45 - Using clip discovery mode
[INFO] 2026-01-22 17:54:45 - Discovered 1 clips to test
[INFO] 2026-01-22 17:54:45 - [play_48KHz_8b_2ch] Using clip: yesterday_48KHz_30s_8b_2ch.wav (2883002 bytes)
[PASS] 2026-01-22 17:55:15 - [play_48KHz_8b_2ch] loop 1 OK (rc=0, 30s)
[INFO] 2026-01-22 17:55:15 - Summary: total=1 pass=1 fail=0 skip=0
[PASS] 2026-01-22 17:55:15 - AudioPlayback PASS
```

**Example 4: Testing all 10 clips (auto-discovery mode)**
```
sh-5.3# ./run.sh --no-extract-assets --timeout 5s
[INFO] 2026-01-22 17:51:32 - Auto-detected clip discovery mode (found clips in /home/AudioClips/)
[INFO] 2026-01-22 17:51:32 - Using clip discovery mode
[INFO] 2026-01-22 17:51:32 - Discovered 10 clips to test
[INFO] 2026-01-22 17:51:32 - [play_16KHz_16b_2ch] Using clip: yesterday_16KHz_30s_16b_2ch.wav (1922036 bytes)
[PASS] 2026-01-22 17:51:37 - [play_16KHz_16b_2ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:51:37 - [play_16KHz_8b_6ch] Using clip: yesterday_16KHz_30s_8b_6ch.wav (2883002 bytes)
[PASS] 2026-01-22 17:51:43 - [play_16KHz_8b_6ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:51:43 - [play_22.050KHz_8b_1ch] Using clip: yesterday_22.050KHz_30s_8b_1ch.wav (662284 bytes)
[PASS] 2026-01-22 17:51:48 - [play_22.050KHz_8b_1ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:51:48 - [play_24KHz_24b_6ch] Using clip: yesterday_24KHz_30s_24b_6ch.wav (12973134 bytes)
[PASS] 2026-01-22 17:51:53 - [play_24KHz_24b_6ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:51:53 - [play_24KHz_32b_1ch] Using clip: yesterday_24KHz_30s_32b_1ch.wav (2883004 bytes)
[PASS] 2026-01-22 17:51:58 - [play_24KHz_32b_1ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:51:58 - [play_32KHz_16b_2ch] Using clip: yesterday_32KHz_30s_16b_2ch.wav (3843964 bytes)
[PASS] 2026-01-22 17:52:03 - [play_32KHz_16b_2ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:52:03 - [play_32KHz_8b_8ch] Using clip: yesterday_32KHz_30s_8b_8ch.wav (7687832 bytes)
[PASS] 2026-01-22 17:52:09 - [play_32KHz_8b_8ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:52:09 - [play_44.1KHz_16b_1ch] Using clip: yesterday_44.1KHz_30s_16b_1ch.wav (2648774 bytes)
[PASS] 2026-01-22 17:52:14 - [play_44.1KHz_16b_1ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:52:14 - [play_48KHz_8b_2ch] Using clip: yesterday_48KHz_30s_8b_2ch.wav (2883002 bytes)
[PASS] 2026-01-22 17:52:19 - [play_48KHz_8b_2ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:52:19 - [play_8KHz_8b_1ch] Using clip: yesterday_8KHz_30s_8b_1ch.wav (240362 bytes)
[PASS] 2026-01-22 17:52:24 - [play_8KHz_8b_1ch] loop 1 OK (rc=0, 5s)
[INFO] 2026-01-22 17:52:24 - Summary: total=10 pass=10 fail=0 skip=0
[PASS] 2026-01-22 17:52:24 - AudioPlayback PASS
```

**Example 5: Invalid config name (shows helpful error)**
```
sh-5.3# ./run.sh --no-extract-assets --clip-name "playback_config99"
[INFO] 2026-01-22 17:59:52 - Using clip discovery mode
[SKIP] 2026-01-22 17:59:52 - AudioPlayback SKIP - Invalid clip/config name(s) provided. Available range: playback_config1 to playback_config10
```

**Example 6: CI/LAVA workflow with unique result files**
```
sh-5.3# ./run.sh --clip-name "playback_config1" --res-suffix "Config1" --audio-clips-path /home/AudioClips/ --no-extract-assets
[INFO] 2026-01-22 17:46:33 - Using unique result file: ./AudioPlayback_Config1.res
[INFO] 2026-01-22 17:46:33 - ---------------- Starting AudioPlayback ----------------
[INFO] 2026-01-22 17:46:33 - Using clip discovery mode
[INFO] 2026-01-22 17:46:33 - Discovered 1 clips to test
[INFO] 2026-01-22 17:46:33 - [play_16KHz_16b_2ch] Clip duration: 30s (timeout threshold: 29s)
[PASS] 2026-01-22 17:47:04 - [play_16KHz_16b_2ch] loop 1 OK (rc=0, 30s)
[PASS] 2026-01-22 17:47:04 - AudioPlayback PASS

sh-5.3# cat AudioPlayback_Config1.res
AudioPlayback PASS

sh-5.3# ./run.sh --clip-name "playback_config7" --res-suffix "Config7" --audio-clips-path /home/AudioClips/ --no-extract-assets
[INFO] 2026-01-22 17:48:34 - Using unique result file: ./AudioPlayback_Config7.res
[PASS] 2026-01-22 17:49:05 - AudioPlayback PASS

sh-5.3# cat AudioPlayback_Config7.res
AudioPlayback PASS

# Both result files exist without overwriting
sh-5.3# ls -1 AudioPlayback*.res
AudioPlayback_Config1.res
AudioPlayback_Config7.res
```

Results:
- Results are stored in: results/AudioPlayback/ (or results/AudioPlayback_<suffix>/ when using --res-suffix)
- Summary result file: AudioPlayback.res (or AudioPlayback_<suffix>.res when using --res-suffix)
- JUnit XML (if enabled): <your-path>.xml
- Diagnostic logs: dmesg snapshots, mixer dumps, playback logs per test case
- **Note**: When using --res-suffix, both result files AND log directories are unique per invocation, preventing log collisions in CI/LAVA workflows


## Notes

- The script validates the presence of required tools before executing tests; missing tools result in SKIP.
- If any critical tool is missing, the script exits with an error message.
- Logs include dmesg snapshots, mixer dumps, and playback logs.
- **Network operations are disabled by default**. Use `--enable-network-download` to download missing audio files.
- Pass Wi-Fi credentials via `--ssid` and `--password` CLI flags (or SSID/PASSWORD environment variables) to auto-enable network download.
- If audio clips are present locally, the test runs without any network operations (offline-capable).
- If clips are missing and network download is disabled, the test will SKIP with a helpful message.
- You can override default network probe targets using NET_PROBE_ROUTE_IP and NET_PING_HOST to avoid connectivity-related failures in restricted environments.
- Evidence-based PASS/FAIL logic ensures reliability even if backend quirks occur.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.
