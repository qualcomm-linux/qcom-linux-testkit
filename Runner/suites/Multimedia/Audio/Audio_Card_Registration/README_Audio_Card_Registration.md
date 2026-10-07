# Audio_Card_Registration

## Overview

`Audio_Card_Registration` validates that the kernel/ALSA audio card is registered correctly after boot on Qualcomm Linux platforms.

This test is intended as an audio preflight check before running playback or record tests. It verifies the ALSA registration layer only and does not play audio, record audio, restart audio services, or modify mixer controls.

## Test Location

```text
Runner/suites/Multimedia/Audio/Audio_Card_Registration/
```

Main files:

```text
run.sh
Audio_Card_Registration.yaml
```

Common helper dependency:

```text
Runner/utils/audio_common.sh
```

## What This Test Validates

The test checks:

- ALSA sound card registration through `/proc/asound/cards`
- Non-dummy/non-loopback card detection
- `/dev/snd/controlC<N>` control node availability
- Optional PCM entry validation through `/proc/asound/pcm`
- Optional playback PCM validation
- Optional capture PCM validation
- Audio-related dmesg triage for debug visibility

## What This Test Does Not Do

This test intentionally does not:

- Start or restart PipeWire
- Start or restart PulseAudio
- Start or stop ADSP/remoteproc
- Play audio
- Record audio
- Change mixer controls
- Download or use audio clips

Generic playback and record functionality remains covered by `AudioPlayback`
and `AudioRecord`. Connector-specific HDMI, DisplayPort/eDP, and 3.5 mm
playback routing is covered by `AudioRoutePlayback`. Wired headset-microphone
capture routing is covered by `AudioRouteRecord`.

## Default Behavior

By default, the test waits up to 30 seconds for at least one valid ALSA card and validates the matching `/dev/snd/controlC<N>` node.

Default configuration:

```sh
AUDIO_CARD_WAIT_SECS=30
AUDIO_CARD_REQUIRED=auto
AUDIO_CARD_MATCH=
REQUIRE_CONTROL_NODE=1
REQUIRE_PCM_NODE=0
REQUIRE_PLAYBACK_PCM=0
REQUIRE_CAPTURE_PCM=0
DMESG_SCAN=1
```

## Result File

The test always writes a single fixed result file:

```text
Audio_Card_Registration.res
```

The result file contains one of:

```text
Audio_Card_Registration PASS
Audio_Card_Registration FAIL
Audio_Card_Registration SKIP
```

## PASS Criteria

The test reports `PASS` when:

- At least one valid ALSA sound card is registered, or a card matching `AUDIO_CARD_MATCH` is registered.
- Required `/dev/snd/controlC<N>` nodes are present.
- Optional PCM requirements pass when enabled.

## SKIP Criteria

The test reports `SKIP` when:

- Audio is marked optional and no valid ALSA card is registered.
- `AUDIO_CARD_REQUIRED=auto` decides audio is not expected from DT/sysfs and no valid card appears.
- Required userspace dependencies for the test itself are missing.

## FAIL Criteria

The test reports `FAIL` when:

- Audio is required but no valid ALSA sound card registers.
- `AUDIO_CARD_MATCH` is set and no valid card matches it.
- A matched card exists but `/dev/snd/controlC<N>` is missing while `REQUIRE_CONTROL_NODE=1`.
- PCM validation is enabled and required PCM entries are missing.

## Command Line Usage

On CentOS Stream 10, `--overlay` prepares EPEL and the Qualcomm aarch64 and
noarch RPM repositories, refreshes DNF metadata, and installs
`audioreach-dkms`, `audioreach-pal`, and `audioreach-pipewire-plugin`. The
default mode continues to use image-provided audio components.

```sh
./run.sh [options]
```

Options:

```text
--wait-secs N
    Wait time for ALSA sound card registration.
    Default: 30

--required auto|required|optional
    auto     : infer whether audio is expected from DT/sysfs.
    required : fail if no valid ALSA card is registered.
    optional : skip if no valid ALSA card is registered.
    Default: auto

--card-match TEXT
    Optional case-insensitive substring to match card ID or description.
    Example: --card-match qcom

--require-control-node 0|1
    Require /dev/snd/controlC<N> for matched cards.
    Default: 1

--require-pcm-node 0|1
    Require at least one /proc/asound/pcm entry for matched cards.
    Default: 0

--require-playback-pcm 0|1
    Require playback PCM entry for matched cards.
    Default: 0

--require-capture-pcm 0|1
    Require capture PCM entry for matched cards.
    Default: 0

--dmesg-scan 0|1
    Enable or disable audio-related dmesg scan.
    Default: 1

--no-dmesg
    Disable audio-related dmesg scan.

--verbose
    Enable verbose mode.

--help|-h
    Show usage.
```

## Examples

Run with default settings:

```sh
./run.sh
```

Require audio card registration explicitly:

```sh
./run.sh --required required
```

Match a specific card string:

```sh
./run.sh --card-match qcom
```

Require any PCM entry:

```sh
./run.sh --require-pcm-node 1
```

Require both playback and capture PCM entries:

```sh
./run.sh --require-playback-pcm 1 --require-capture-pcm 1
```

Disable dmesg scan:

```sh
./run.sh --no-dmesg
```

## LAVA YAML Usage

The matching YAML runs the test and emits only the fixed result file:

```yaml
run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Multimedia/Audio/Audio_Card_Registration/
    - ./run.sh --wait-secs "${AUDIO_CARD_WAIT_SECS}" --required "${AUDIO_CARD_REQUIRED}" --card-match "${AUDIO_CARD_MATCH}" --require-control-node "${REQUIRE_CONTROL_NODE}" --require-pcm-node "${REQUIRE_PCM_NODE}" --require-playback-pcm "${REQUIRE_PLAYBACK_PCM}" --require-capture-pcm "${REQUIRE_CAPTURE_PCM}" --dmesg-scan "${DMESG_SCAN}" || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh Audio_Card_Registration.res
```

## Recommended CI Defaults

Use the conservative defaults first:

```yaml
params:
  AUDIO_CARD_WAIT_SECS: "30"
  AUDIO_CARD_REQUIRED: "auto"
  AUDIO_CARD_MATCH: ""
  REQUIRE_CONTROL_NODE: "1"
  REQUIRE_PCM_NODE: "0"
  REQUIRE_PLAYBACK_PCM: "0"
  REQUIRE_CAPTURE_PCM: "0"
  DMESG_SCAN: "1"
```

After board coverage is confirmed, stricter validation can be enabled per board or per job:

```yaml
REQUIRE_PCM_NODE: "1"
```

or:

```yaml
REQUIRE_PLAYBACK_PCM: "1"
REQUIRE_CAPTURE_PCM: "1"
```

## Debug Output

The test logs the following inventories for CI debug:

```text
/proc/asound/cards
/proc/asound/devices
/proc/asound/pcm
/dev/snd
/sys/class/sound
aplay -l, if available
arecord -l, if available
```

It also stores matched card data under:

```text
results/Audio_Card_Registration/matched_cards.txt
```

## Notes for Qualcomm Boards

On Qualcomm boards, this test is useful for identifying early audio bring-up issues such as:

- Machine driver not probing
- Sound card DT node missing or incorrect
- Codec or macro probe failures
- LPASS/Q6/ASoC registration issues
- SoundWire-related probe issues
- `/dev/snd` node creation problems

This test should remain lightweight and non-destructive. It should not attempt to recover the audio subsystem by restarting services or remote processors.
