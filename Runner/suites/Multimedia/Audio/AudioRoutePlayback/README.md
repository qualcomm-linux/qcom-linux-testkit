# AudioRoutePlayback

## Purpose

`AudioRoutePlayback` validates one explicitly requested external audio route on
any SoC. It first searches runtime ALSA PCM and mixer inventories for generic
route names. When a platform uses opaque topology names, the caller can supply
the exact mixer control, mixer value, PCM label, or ALSA device. The suite then
generates a bounded 1 kHz signal and performs stereo playback with `aplay`.

This fills a gap in the generic `AudioPlayback` suite. The generic suite validates playback through a usable speaker/default sink, but it does not require or prove HDMI, DisplayPort/eDP, or 3.5 mm headphone routing.

## Supported Routes

| Route | CLI value | Generic runtime matches |
|---|---|---|
| HDMI | `hdmi` | HDMI-named PCM or mixer entries |
| DisplayPort or eDP | `displayport` | DisplayPort, DP, or eDP-named PCM or mixer entries |
| 3.5 mm headphones/headset | `headphones` | Headphone, headset, HSJ, or HP-output entries |

Card and PCM device numbers are never hardcoded. The test derives them from
`amixer`, `/proc/asound/pcm`, and `aplay -l`, unless the caller explicitly
provides an ALSA endpoint.

Automatic selection is accepted only when the route resolves to one candidate.
If several HDMI, DP/eDP, or headset mappings match, the test fails before
changing mixer state and asks the fixture job for an exact PCM label or ALSA
device. This avoids silently choosing the first enumerated connector.

## Prerequisites and Fixtures

- The image must provide `aplay` and `amixer`, normally from `alsa-utils`.
- The requested route must be provisioned by the board device tree, ASoC topology, firmware, and image configuration.
- HDMI and DisplayPort/eDP jobs require the corresponding connected display or audio-capable fixture.
- The headphone job requires a board variant or mezzanine that physically exposes the 3.5 mm codec route, plus a connected headset or audio fixture.

These route definitions are opt-in and are not added to the generic config1 nightly plan. Add them to a board-specific job only when its external fixture is guaranteed. Once selected, a missing or nonfunctional route is reported as `FAIL` rather than silently falling back to another output.

The same YAML definitions can be used across SoCs. Board-specific jobs may set
`MIXER_CONTROL`, `MIXER_VALUE`, `PCM_LABEL`, or `ALSA_DEVICE` when their runtime
names do not identify the physical connector. Empty YAML override parameters
leave any corresponding `AUDIO_*` environment value in effect.

## Usage

```sh
cd Runner/suites/Multimedia/Audio/AudioRoutePlayback
./run.sh --route hdmi
./run.sh --route displayport
./run.sh --route headphones
```

The aliases `dp`, `edp`, `headphone`, `headset`, and `3.5mm` are also accepted.

Select an opaque ASoC route by exact mixer control. When the control contains a
`MultiMediaN` label, the PCM is derived automatically:

```sh
./run.sh \
  --route hdmi \
  --mixer-control "Vendor HDMI Audio Mixer MultiMedia3"
```

Switch controls default to value `1`. Supply an exact value for an enum or
other non-boolean control:

```sh
./run.sh \
  --route hdmi \
  --mixer-control "Display Audio Route" \
  --mixer-value "HDMI" \
  --pcm-label "MultiMedia3"
```

Supply a separate PCM label when it cannot be derived from the control:

```sh
./run.sh \
  --route displayport \
  --mixer-control "Display Audio Route Switch" \
  --pcm-label "Display Playback"
```

Or provide the endpoint directly. Card and device numbers shown here are only
examples and must come from the target's `aplay -l` output:

```sh
./run.sh --route headphones --alsa-device plughw:0,2
```

Use a longer playback interval:

```sh
./run.sh --route displayport --duration 10
```

Create a unique result for a LAVA job:

```sh
./run.sh \
  --route hdmi \
  --res-suffix HDMI \
  --lava-testcase-id AudioRoutePlayback_HDMI
```

Disable kernel log capture:

```sh
./run.sh --route headphones --no-dmesg
```

Environment equivalents are available for all public parameters:

```sh
AUDIO_ROUTE=displayport \
AUDIO_MIXER_CONTROL="" \
AUDIO_MIXER_VALUE="" \
AUDIO_PCM_LABEL="" \
AUDIO_ALSA_DEVICE="" \
PLAYBACK_DURATION=5 \
DMESG_SCAN=1 \
RES_SUFFIX=DisplayPort \
LAVA_TESTCASE_ID=AudioRoutePlayback_DisplayPort \
./run.sh
```

## Results

`PASS` requires both:

- A route-specific PCM discovered from runtime names or selected by an explicit
  user override.
- A successful bounded `aplay` operation through the derived `plughw:CARD,DEVICE` endpoint.

The playback payload is a generated 1 kHz unsigned 8-bit stereo signal at
48 kHz. This gives the CI fixture a deterministic non-silent signal to detect.
The runner proves that ALSA accepted and completed the transfer. Physical
connector output remains the responsibility of the fixture-side measurement.

`SKIP` is used when required image-provided ALSA utilities are absent.

`FAIL` is used for malformed input, missing explicitly requested route topology, mixer preparation failure, playback failure, or failure to restore the mixer value changed by the test.

## State Restoration

When a mixer control is used, the test snapshots its current value before
enabling it. The original value is restored on normal completion and from the
exit trap. A route discovered directly from a named PCM does not require mixer
mutation. The test does not install packages, restart audio services, or alter
unrelated mixer controls.

## Artifacts

Artifacts are retained in a collision-safe
`results/AudioRoutePlayback[_SUFFIX]/run-TIMESTAMP-PID/` directory. The exact
path is printed when the suite starts.

- `audio_route_inventory.log`: ALSA cards, PCMs, mixer controls, and UCM card inventory
- `route_mapping.txt`: selected card, device, mixer control, and PCM label
- `route_selection.tsv`: machine-readable selected-route details
- `route_discovery.log`: route discovery and preparation diagnostics
- `playback_tone_1khz_u8_stereo.raw`: generated fixture-detectable signal
- `playback_signal_generation.log`: signal-generation diagnostics
- `aplay_ROUTE.log`: playback command output
- `dmesg_snapshot.log` and `dmesg_errors.log`: shared kernel-log capture output when enabled

## LAVA Definitions

- `AudioRoutePlayback_HDMI.yaml`
- `AudioRoutePlayback_DisplayPort.yaml`
- `AudioRoutePlayback_Headphones.yaml`

Each definition uses a unique result filename and testcase ID, allowing all three to be included in one fixture-aware plan without result collisions.

Playback duration must be between 1 and 60 seconds. `--mixer-value` and
`AUDIO_MIXER_VALUE` require an accompanying mixer control.
