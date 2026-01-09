# Audio_Playback (GStreamer) — Runner Test

This directory contains the **Audio_Playback** validation test for Qualcomm Linux Testkit runners.

It validates audio **playback** using **GStreamer (`gst-launch-1.0`)** with an auto-selected backend:
- **PipeWire**
- **PulseAudio**
- **ALSA (direct)**

The script is designed to be **CI/LAVA-friendly**:
- Writes **PASS/FAIL/SKIP** into `Audio_Playback.res`
- Always **exits 0** (even on FAIL/SKIP) to avoid terminating LAVA jobs early
- Logs the **final `gst-launch-1.0` command** to console and to log files

---

## Location in repo

Expected path:

```
Runner/suites/Multimedia/GSTreamer/Audio/Audio_Playback/run.sh
```

Required shared utils (sourced from `Runner/utils` via `init_env`):
- `functestlib.sh`
- `lib_gstreamer.sh`
- optional: `audio_common.sh` (wrapper/aliases if present)

---

## What this test does

At a high level, the test:

1. Finds and sources `init_env`
2. Sources:
   - `$TOOLS/functestlib.sh`
   - `$TOOLS/lib_gstreamer.sh`
   - optionally `$TOOLS/audio_common.sh`
3. Resolves or accepts a clip path
4. Ensures the clip is present locally (supports device-provided assets via `--assets` / `--clips-dir`,
   and optionally remote fetch via `--assets-url` if the helper exists)
5. Builds a **backend chain** (auto: pipewire → pulseaudio → alsa)
6. Selects a sink (optional `--sink`, optional `--null-sink`)
7. Constructs a **multi-line** `gst-launch-1.0` playback pipeline
8. Runs the pipeline for the requested duration (watchdog timeout)
9. Applies **post-validation evidence** (streaming/path activity) and emits PASS/FAIL/SKIP
10. Collects best-effort diagnostics:
    - mixer dump
    - dmesg scan

---

## PASS / FAIL / SKIP criteria

### PASS
- `gst-launch-1.0` either:
  - exits `0`, or
  - is killed by watchdog timeout (`124` or `143`) **when a duration timeout is used**
- **AND** evidence indicates the audio path was active, such as:
  - PipeWire stream RUNNING, or
  - PulseAudio stream/sink-input exists, or
  - ALSA PCM substream RUNNING, or
  - ASoC DAPM path shows `On` (fallback heuristic)

### FAIL
- A backend was attempted and the run did not meet PASS criteria (e.g., immediate pipeline failure, no evidence of activity)

### SKIP
- Missing required tools (`gst-launch-1.0`, `gst-inspect-1.0`)
- No usable backend found
- Clip missing and assets not available
- Invalid arguments or required values missing

**Note:** The test always exits `0` even for FAIL/SKIP. The `.res` file is the source of truth.

---

## Logs and artifacts

By default, logs are written relative to the script working directory:

```
./Audio_Playback.res
./logs/Audio_Playback/
  gst.log
  mixers.txt
  clip_meta.txt
  dmesg/
    (dmesg scan outputs)
```

The final `gst-launch-1.0` command is always printed to the console.

---

## Dependencies

### Required
- `gst-launch-1.0`
- `gst-inspect-1.0`

### Recommended (for best results)
- `gst-discoverer-1.0` (for clip metadata and cap inference)
- For PipeWire backend:
  - `pipewire` running
  - `wpctl` available
  - `pipewiresink` GStreamer plugin (preferred)
- For PulseAudio backend:
  - `pulseaudio` or `pipewire-pulse` running
  - `pactl` available
  - `pulsesink` GStreamer plugin
- For ALSA backend:
  - `alsasink` GStreamer plugin
  - proper hw device path (default `hw:0,0`)

---

## Caps negotiation behavior (important)

The pipeline only forces caps (`audio/x-raw,rate=...,channels=...`) when:

- User explicitly sets `--rate` and/or `--channels`, **OR**
- Inference succeeded via `gst-discoverer-1.0`

Otherwise the test **does NOT force caps** and lets GStreamer negotiate.  
This reduces false failures on hardware with unusual constraints.

---

## Usage

Run:

```
./run.sh [options]
```

Help:

```
./run.sh --help
```

### Options

- `--backend <auto|pipewire|pulseaudio|alsa>`
  - Default: `auto` (tries pipewire → pulseaudio → alsa)

- `--stack <auto|base|overlay>`
  - Default: `auto`
  - `auto`    : detect overlay (audioreach modules) and apply overlay setup only if detected
  - `base`    : force base (do not run overlay setup even if audioreach modules are present)
  - `overlay` : force overlay setup (SKIP if overlay setup fails)

- `--format <wav|aac|mp3|flac>`
  - Default: `wav`

- `--duration <N|Ns|Nm|Nh|MM:SS|HH:MM:SS>`
  - Default: `${RUNTIMESEC:-10s}`

- `--clipdur <short|medium|long>`
  - Used with `resolve_clip()` when `--clip` is not specified
  - Default: `short`

- `--clip <path>`
  - Override resolved clip path

- `--clips-dir <dir>`
  - Points to **already untarred** clips directory on device.
  - Sets `AUDIO_CLIPS_BASE_DIR`

- `--assets <path>`
  - Device-provided assets (no network):
    - If directory: treated as `--clips-dir`
    - If file: `.tar` / `.tar.gz` extracted into `clips-dir` (or `AudioClips` under script dir)

- `--assets-url <url>`
  - Optional remote tarball URL (used only if clip missing and helper exists)

- `--rate <Hz>`
  - Forces output caps **rate** after decode/resample  
  - Example: `48000`

- `--channels <N>`
  - Forces output caps **channels** after decode/resample  
  - Example: `1` or `2`

- `--sink <idOrName>`
  - For PipeWire: numeric id or substring match in `wpctl status`
  - For PulseAudio: sink name or numeric index

- `--null-sink`
  - Prefer null/dummy sink if available (useful for silent CI runs)

- `--gst-debug <level>`
  - Sets `GST_DEBUG=<level>` (single numeric level)
  - Values:
    - `1` ERROR
    - `2` WARNING
    - `3` FIXME
    - `4` INFO
    - `5` DEBUG
    - `6` LOG
    - `7` TRACE
    - `9` MEMDUMP
  - Default: `2`

---

## Examples

### 1) Basic WAV playback (auto backend)

```
./run.sh --format wav --clip /var/yesterday_48KHz.wav --duration 10s
```

### 2) Base stack (force no overlay actions)

```
./run.sh --stack base --format wav --clip /var/yesterday_48KHz.wav --duration 10s
```

### 3) Overlay stack (force overlay setup)

```
./run.sh --stack overlay --format wav --clip /var/yesterday_48KHz.wav --duration 10s
```

### 4) AAC playback (matches your reference pipeline intent)

Your reference pipeline:

```
gst-launch-1.0 filesrc location=/opt/aac_48k_mono.aac !   aacparse ! avdec_aac !   audioconvert ! audioresample !   audio/x-raw,rate=48000,channels=1 !   alsasink device=hw:0,0
```

Equivalent test invocation:

```
./run.sh --format aac --clip /opt/aac_48k_mono.aac --rate 48000 --channels 1 --duration 10s
```

### 5) FLAC 48k stereo playback (reference intent)

```
./run.sh --format flac --clip /opt/flac_48k_stereo.flac --rate 48000 --channels 2 --duration 10s
```

### 6) MP3 44.1k stereo playback (reference intent)

```
./run.sh --format mp3 --clip /opt/mp3_44k1_stereo.mp3 --rate 44100 --channels 2 --duration 10s
```

### 7) Prefer a null/dummy sink for CI

```
./run.sh --null-sink --format wav --clip /var/yesterday_48KHz.wav --duration 10s
```

### 8) Choose a specific sink

PipeWire example:

```
./run.sh --backend pipewire --sink speaker --format wav --clip /var/yesterday_48KHz.wav --duration 10s
```

PulseAudio example:

```
./run.sh --backend pulseaudio --sink 0 --format wav --clip /var/yesterday_48KHz.wav --duration 10s
```

### 9) Use device-provided local assets (tar.gz)

```
./run.sh --assets /opt/audio_clips.tar.gz --format wav --clipdur short --duration 10s
```

### 10) Use device-provided untar directory

```
./run.sh --clips-dir /opt/AudioClips --format wav --clipdur short --duration 10s
```

### 11) Increase GStreamer debug verbosity

```
./run.sh --gst-debug 5 --format wav --clip /var/yesterday_48KHz.wav --duration 10s
```

---

## Troubleshooting

### A) “SKIP: Missing gstreamer runtime”
- Ensure `gst-launch-1.0` and `gst-inspect-1.0` are installed in the image.

### B) PipeWire/PulseAudio backend not used
- Ensure the daemon is running:
  - PipeWire: `pgrep -x pipewire`
  - PulseAudio: `pgrep -x pulseaudio` or `pgrep -x pipewire-pulse`
- Ensure control tools exist:
  - PipeWire: `wpctl`
  - PulseAudio: `pactl`
- Ensure plugin exists:
  - PipeWire: `pipewiresink`
  - PulseAudio: `pulsesink`

### C) ALSA backend fails
- Confirm `alsasink` plugin exists:
  - `gst-inspect-1.0 alsasink`
- Confirm device is correct (default `hw:0,0` in the test):
  - You can update the default in the test or extend args later if needed.

### D) “FAIL: evidence=0”
- If audio is routed through a sound server, ensure the sound server interfaces are accessible.
- Check `logs/Audio_Playback/gst.log`, `mixers.txt`, and `dmesg/` outputs.
- Try forcing `--gst-debug 5` for more detail.

---

## Notes for CI / LAVA

- The test always exits `0`.
- Use the `.res` file for result:
  - `PASS`
  - `FAIL`
  - `SKIP`

---

## Maintainers

- This test is intended to be robust and easy to extend alongside:
  - `Audio_Record`
  - `Audio_Duplex_Loopback`
  - `Audio_Concurrency`

Follow the same conventions:
- Keep **usage in run.sh**
- Use shared helpers in `Runner/utils/lib_gstreamer.sh` and `audio_common.sh`
- Use `log_*` helpers from `functestlib.sh`
- Always emit `.res` and exit `0`
