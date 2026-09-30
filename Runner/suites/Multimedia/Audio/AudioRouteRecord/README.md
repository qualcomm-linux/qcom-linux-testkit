# AudioRouteRecord

## Purpose

`AudioRouteRecord` validates capture from an explicitly requested wired headset
microphone on any SoC. It searches runtime ALSA capture PCM and mixer inventories
for generic headset-microphone names. When a platform uses opaque topology
names, the caller can supply the exact mixer control, mixer value, PCM label, or
ALSA device.

This complements the generic `AudioRecord` suite. `AudioRecord` proves that a
usable microphone capture path works, while this suite requires the selected
3.5 mm headset-microphone path and does not fall back to an internal DMIC or
another capture source. HDMI, DisplayPort, and eDP are playback-only routes and
are therefore not accepted as recording sources.

## Runtime Discovery

The suite accepts `headset-mic`, `headset-microphone`, `headset`, `3.5mm-mic`,
and `3.5mm` as source names. It discovers the card and capture PCM from:

- `arecord -l`
- `/proc/asound/pcm`
- `amixer -c CARD controls`

Card and PCM device numbers are never hardcoded. A named capture PCM can be
used without changing mixer state. If the route is represented by a mixer
control, the test snapshots the current value, applies the requested value, and
restores the original value after capture.

Automatic selection is accepted only when the headset microphone resolves to
one candidate. Multiple matching capture PCMs or mixer-to-PCM mappings fail
before state changes and require an exact PCM label or ALSA device override.

## Prerequisites and Fixture

- The image must provide `arecord`, normally from `alsa-utils`.
- `amixer` is needed when the capture PCM name alone does not identify the
  headset-microphone route.
- The board must expose a wired headset-microphone input through its device
  tree, codec, ASoC topology, firmware, and image configuration.
- CI must connect the headset microphone and inject a detectable audio signal
  for the recording interval.

The LAVA definition is opt-in. Add it only to jobs where the hardware fixture
is guaranteed. Once selected, a missing or nonfunctional headset-microphone
route is reported as `FAIL` rather than falling back to a different microphone.

## Usage

Run automatic discovery:

```sh
cd Runner/suites/Multimedia/Audio/AudioRouteRecord
./run.sh --source headset-mic
```

Select an opaque topology by exact mixer control and value. The default mixer
value is `1`, which is suitable for switch controls. Enum controls normally
require an explicit value:

```sh
./run.sh \
  --source headset-mic \
  --mixer-control "Capture Source" \
  --mixer-value "Headset Mic" \
  --pcm-label "MultiMedia1"
```

Provide the capture endpoint directly. The card and device numbers below are
examples and must come from the target's `arecord -l` output:

```sh
./run.sh --source headset-mic --alsa-device plughw:0,2
```

An explicit device can be combined with an exact mixer selection:

```sh
./run.sh \
  --source headset-mic \
  --alsa-device plughw:0,2 \
  --mixer-control "Capture Source" \
  --mixer-value "Headset Mic"
```

Use a longer recording interval:

```sh
./run.sh --source headset-mic --duration 10
```

Signal checking is strict by default. The default requires an RMS level of at
least `-60` dBFS in addition to the shared WAV activity checks. A fixture may
tighten this threshold when its injected level is known:

```sh
./run.sh \
  --source headset-mic \
  --strict-signal 1 \
  --min-rms-dbfs -45
```

The same RMS gate is enforced by the image-provided Python validator and by
the bounded `od`/`dd` fallback used on smaller images without Python.

Create a unique result for a LAVA job:

```sh
./run.sh \
  --source headset-mic \
  --res-suffix HeadsetMic \
  --lava-testcase-id AudioRouteRecord_HeadsetMic
```

Disable kernel log capture:

```sh
./run.sh --source headset-mic --no-dmesg
```

Environment equivalents are available for every public parameter:

```sh
AUDIO_CAPTURE_SOURCE=headset-mic \
AUDIO_CAPTURE_MIXER_CONTROL="" \
AUDIO_CAPTURE_MIXER_VALUE="" \
AUDIO_CAPTURE_PCM_LABEL="" \
AUDIO_CAPTURE_ALSA_DEVICE="" \
AUDIO_CAPTURE_DURATION=5 \
AUDIO_CAPTURE_STRICT_SIGNAL=1 \
AUDIO_CAPTURE_MIN_RMS_DBFS=-60 \
DMESG_SCAN=1 \
RES_SUFFIX=HeadsetMic \
LAVA_TESTCASE_ID=AudioRouteRecord_HeadsetMic \
./run.sh
```

## Result Policy

`PASS` requires all of the following:

- A route-specific capture PCM discovered from runtime names or selected by an
  explicit user override.
- A bounded `arecord` operation through the selected endpoint.
- A structurally valid WAV with the expected duration, format, sample rate,
  channel count, and real signal activity.
- Successful restoration of any mixer control changed by the test.

`SKIP` is used when required image-provided ALSA utilities are absent.

`FAIL` is used for malformed input, a missing explicitly requested headset
microphone route, mixer preparation failure, capture or signal-validation
failure, or failure to restore mixer state.

## Artifacts

Artifacts are retained in a collision-safe
`results/AudioRouteRecord[_SUFFIX]/run-TIMESTAMP-PID/` directory. The exact
path is printed when the suite starts.

- `audio_capture_route_inventory.log`: ALSA cards, capture PCMs, mixer controls,
  and UCM card inventory
- `route_mapping.txt`: selected card, device, mixer control, mixer value, and
  PCM label
- `route_selection.tsv`: machine-readable selected-route details
- `route_discovery.log`: route discovery and preparation diagnostics
- `headset_microphone.wav`: recorded WAV payload
- `arecord_headset_microphone.log`: recorder and WAV-validation output
- `dmesg_snapshot.log` and `dmesg_errors.log`: shared kernel-log capture output
  when enabled

## LAVA Definition

`AudioRouteRecord_HeadsetMic.yaml` exposes mixer, PCM, device, duration, signal
threshold, and dmesg parameters without tying the test to a particular SoC or
card number.

`--mixer-value` and `AUDIO_CAPTURE_MIXER_VALUE` require an accompanying mixer
control so a supplied value cannot be applied to an unintended auto-discovered
control. Recording duration must be between 1 and 60 seconds. Empty YAML route
override parameters leave any corresponding `AUDIO_CAPTURE_*` environment
value in effect.
