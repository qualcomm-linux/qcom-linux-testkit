# AudioLoopback

`AudioLoopback` validates simultaneous playback and capture without downloading
media. It generates a deterministic 48 kHz, unsigned 8-bit stereo WAV, starts
capture, plays the reference, and validates the resulting WAV.

Automatic selection uses an active PipeWire or PulseAudio session and its
physical speaker and microphone routes. PipeWire requires `wpctl`, `pw-record`,
and `pw-play` or `pw-cat`. PulseAudio requires `pactl`, `parecord`, and `paplay`.
If no managed backend is usable, the suite falls back to image-provided `aplay`
and `arecord`. The suite never installs runtime packages.

On Debian and CentOS, a root invocation prepares the regular desktop audio user
and re-launches the complete test as that user. Automatic selection also
prepares the user's systemd session so PipeWire and PulseAudio control and data
paths match the working desktop route. Yocto and Ubuntu keep their existing
execution behavior.

## Fixture requirement

The selected output must reach the selected input through an acoustic or
electrical fixture. Automatic selection prefers the active managed backend and
its physical speaker and microphone endpoints. Supplying either device option
selects direct ALSA mode, where the unspecified side is discovered. Explicit
ALSA devices are recommended for fixtures that require fixed PCM endpoints:

```sh
./run.sh \
    --playback-device plughw:0,0 \
    --capture-device plughw:0,1 \
    --duration 5
```

When no backend or device inventory exists, the suite reports SKIP with the
missing prerequisite. When a managed backend is active but its physical routes
are unusable and direct ALSA fallback also fails, the suite reports FAIL so the
image or routing regression remains visible. An all-zero capture reports FAIL.
The default policy does not claim waveform correlation when the input contains
some other non-zero signal, so retained metrics and the fixture setup remain
important evidence.

## Result policy

CI-blocking validation is intentionally limited to execution failure and basic
WAV integrity: corrupt or empty files, header-only payloads, all-zero audio, and
materially short captures fail. RMS, peak, clipping, digital-silence runs, DC
offset, large sample transitions, and silent-channel counts are emitted in
`AUDIO_VALIDATION` records as diagnostic metrics. They do not fail the default
policy.

## Options

- `--duration SECONDS` selects 2 to 30 seconds.
- `--playback-device DEVICE` overrides playback discovery.
- `--capture-device DEVICE` overrides capture discovery and probes a supported
  format on that exact device.
- `--dmesg-scan 0|1` controls retained kernel-log evidence.
- `--no-dmesg` disables the kernel-log scan.

Artifacts are retained below `results/AudioLoopback/run-<timestamp>-<pid>/`.

## Yocto CI

`AudioLoopback.yaml` runs the default five-second test using automatic backend
and endpoint discovery. A CI device still needs an acoustic or electrical path
from the selected playback endpoint to the selected capture endpoint. Set
`PLAYBACK_DEVICE` and `CAPTURE_DEVICE` in the job parameters when direct ALSA
selection is required by the fixture.
