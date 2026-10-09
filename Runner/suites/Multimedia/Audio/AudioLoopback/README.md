# AudioLoopback

`AudioLoopback` validates simultaneous playback and capture without downloading
media. It generates a deterministic 48 kHz, unsigned 8-bit stereo WAV, starts
capture, plays the reference, and validates the resulting WAV.

Automatic selection uses an active PipeWire or PulseAudio session and discovers
playback and capture independently. Playback tries speakers and then headphones.
Capture tries mic and then headset-mic. PipeWire requires `wpctl`, `pw-record`,
and `pw-play` or `pw-cat`.
PulseAudio requires `pactl`, `parecord`, and `paplay`.
Playback aliases `speaker`/`speakers` and
`headphone`/`headphones`/`headset` map to the same canonical routes. Capture
aliases `mic`/`microphone` and
`headset-mic`/`headset_mic`/quoted `headset mic` are normalized before runtime
route discovery. The effective selections and targets are emitted to standard
output in an `AUDIO_ROUTE` record.
If no managed backend is usable, the suite falls back to image-provided `aplay`
and `arecord`. Direct ALSA mode retrieves `PlaybackPCM` and `CapturePCM` from
the matching UCM HiFi devices instead of encoding card or PCM numbers. It
enables both devices in one UCM session when they share a card and verifies
both through `_enadevs`. Private `_ucmNNNN.` prefixes are removed only from
standard `hw:` or `plughw:` PCM names. UCM-only private virtual names are not
used as standalone direct PCM routes. Auto-discovered raw `hw:` playback PCMs
use the corresponding `plughw:` target so ALSA can convert the generated U8
reference to the hardware PCM capabilities. Capture keeps its probed hardware
format and device. Legacy speaker/microphone discovery
remains available for images without usable UCM routes. The suite never
installs runtime packages.

On Debian and CentOS, a root invocation prepares the regular desktop audio user
and re-launches the complete test as that user. Automatic selection also
prepares the user's systemd session so PipeWire and PulseAudio control and data
paths match the working desktop route. Yocto and Ubuntu keep their existing
execution behavior.

## Fixture requirement

The selected output must reach the selected input through an acoustic or
electrical fixture. Automatic selection prefers the active managed backend and
its requested physical endpoints. Supplying either device option selects direct
ALSA mode, where the unspecified side is discovered. Explicit ALSA devices are
recommended for fixtures that require fixed PCM endpoints:

```sh
./run.sh \
    --playback-device plughw:0,0 \
    --capture-device plughw:0,1 \
    --duration 5
```

Route-only examples use runtime endpoint and UCM discovery:

```sh
./run.sh --sink speakers --source mic --duration 5
./run.sh --sink headphones --source headset-mic --duration 5
```

An explicit semantic route or PCM device is used only after runtime discovery
and an open probe succeed. Explicit unavailable or malformed choices report
FAIL with the requested route/device and retained probe evidence. Automatic
discovery with no applicable route pair reports SKIP. A ready backend with
missing required clients, a broken applicable route, or an all-zero capture
reports FAIL.
The default policy does not claim waveform correlation when the input contains
some other non-zero signal, so retained metrics and the fixture setup remain
important evidence.

## Result policy

CI-blocking validation is intentionally limited to execution failure and basic
WAV integrity: corrupt or empty files, header-only payloads, all-zero audio, and
materially short captures fail. RMS, peak, clipping, digital-silence runs, DC
offset, large sample transitions, and silent-channel counts are emitted in
`AUDIO_VALIDATION` records as diagnostic metrics. They do not fail the default
policy. The generated two-level square-wave reference is validated with its
known signal shape, so it does not produce a near-constant diagnostic. Complete
RIFF chunks after a WAV `data` chunk are reported as metadata rather than as
trailing audio.

## Options

- `--duration SECONDS` selects 2 to 30 seconds.
- `--sink auto|speaker|speakers|headphone|headphones|headset` selects playback.
- `--source auto|mic|microphone|headset-mic|headset_mic|"headset mic"` selects
  capture.
- `--playback-device DEVICE|auto` overrides playback discovery. `auto` and an
  empty LAVA parameter retain discovery.
- `--capture-device DEVICE|auto` overrides capture discovery and probes a supported
  format on that exact device.
- `--dmesg-scan 0|1` controls retained kernel-log evidence.
- `--no-dmesg` disables the kernel-log scan.

An explicit `--playback-device` value is used exactly as supplied. Use
`plughw:CARD,DEVICE` when the fixture's hardware PCM does not natively accept
the generated U8 stereo reference.

Artifacts are retained below `results/AudioLoopback/run-<timestamp>-<pid>/`.

## Yocto CI

`AudioLoopback.yaml` runs the default five-second test using automatic backend
and endpoint discovery. A CI device still needs an acoustic or electrical path
from the selected playback endpoint to the selected capture endpoint. Set
`PLAYBACK_DEVICE` and `CAPTURE_DEVICE` in the job parameters when direct ALSA
selection is required by the fixture.
