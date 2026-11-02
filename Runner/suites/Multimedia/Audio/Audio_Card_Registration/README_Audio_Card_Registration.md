# Audio_Card_Registration

## Overview

`Audio_Card_Registration` validates that the kernel/ALSA audio card is registered correctly after boot on Qualcomm Linux platforms.

This test is intended as an audio preflight check before running playback or record tests. It verifies the ALSA registration layer only and does not play audio, record audio, restart audio services, or modify mixer controls.

## Active DT and FIT preflight

Before topology and passive registration checks, the runner reports the live DT model, complete
compatible list and sound-card identities. CQS, CQM, IQS and future boards are
discovered from runtime data, not a fixed variant/PCM table. EFI
`VendorDtbOverlays` is read separately without mounting, writing or rebooting.
FIT DT overlays are independent of the audio `--overlay` package/runtime mode.

`dt-fit-preflight/` under the suite log directory retains active DT identity,
sound-card nodes, EFI selection, FIT candidates, configuration/FDT-reference
inventory and extraction diagnostics. Only already accessible boot directories
and mounted FAT filesystems are searched. Raw boot partitions are not mounted
or read. A discovered FIT is a candidate, not proof of what booted.

Optional CLI-only controls (no environment-variable equivalents):

- `--expected-dt-compatible TEXT` requires an exact compatible in the live DT.
  Use a board-specific compatible, not a generic SoC fallback.
- `--fit-image PATH` asserts that this is the intended boot FIT. With a readable
  EFI selector and image-provided `fdtget`, `dumpimage` and `timeout`, the test
  resolves configuration metadata and the ordered base/overlay references.
  An unavailable/ambiguous selection or base-identity mismatch fails preflight.

Automatic mode reports missing DT/EFI/FIT tools as unavailable verification and
preserves normal audio discovery. A candidate-FIT mismatch warns until the boot
FIT is explicitly supplied. Matching the base DT does not prove every overlay
was applied or independently identify the physical board. No packages or DT
assets are installed for this inspection. FIT configurations with compressed
base FDTs are currently reported as unverifiable. Configuration traversal is
bounded to 30 seconds between entries and 512 entries, each tool call to 5 seconds.

Selector matching prefers a unique literal FIT compatible. A compound EFI value
such as `vendor,board,feature` can match `vendor,board-feature` when the FIT
metadata contains every qualifier. Qualifier order may differ, but unknown,
missing or extra qualifiers are never silently discarded. Ambiguous matches
remain unverifiable. `dt-fit-preflight/selected_fit_config.txt` records the
selected configuration, compatible, ordered FDT references and match type.

Examples, use the compatible and FIT from your own device/build:

```sh
./run.sh
./run.sh --expected-dt-compatible qcom,shikra-iqs-evk
./run.sh --expected-dt-compatible qcom,shikra-iqs-evk --fit-image /boot/qclinux_fit.img
```

Run these commands from the suite directory. The FIT path is illustrative,
replace it with the intended build's accessible FIT. For CQS or CQM base
validation, replace the expected compatible with `qcom,shikra-cqs-evk` or
`qcom,shikra-cqm-evk`. These examples do not introduce script-side variant maps.

Suite-specific example, after the image has prepared its audio firmware:

```sh
./run.sh --required required --wait-secs 30 \
    --require-playback-pcm 1 --require-capture-pcm 1 \
    --expected-dt-compatible qcom,shikra-iqs-evk
```

The command checks registered cards and advertised playback/capture PCMs.
It does not start the modem/DSP, change mixer controls or exercise a stream.

Expected outcomes: a matching DT permits the normal test to run, it does not
itself produce PASS. An explicit DT mismatch or unverifiable explicit FIT
produces FAIL before topology validation. Missing optional automatic FIT/EFI
evidence reports unverified detection and preserves the suite's normal
PASS/FAIL/SKIP policy. Inspect `dt-fit-preflight/report.txt` and the accompanying
inventory/tool logs under the suite's retained log directory.

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

On Debian, Ubuntu, and CentOS, the suite ensures the complete ALSA client
package set before card validation. This provides both `aplay` and `arecord`
from `alsa-utils`. Yocto continues to use image-provided clients.

When invoked by root on Debian or CentOS, ALSA inventory and device-node checks
run as the prepared regular audio user. This validates the same access context
used by the functional playback and recording suites.

## What This Test Validates

Base-mode preflight verifies image topology for enabled runtime q6apm sound-card
links before waiting for registration. After registration, each matched card's
driver-specific topology path is checked. CQM/direct-codec and other cards that
do not consume q6apm topology retain that exemption. Remoteproc inventory is
retained for diagnosis, but this suite never starts or restarts a DSP, changes
mixers or opens an audio stream. An offline modem must be prepared by the image
or a functional audio test before passive card registration can pass.

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

Playback and record functionality should remain covered by the existing `AudioPlayback` and `AudioRecord` tests.

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

AudioReach is not enabled for Ubuntu. An explicit `--overlay` request reports
SKIP before any AudioReach source refresh or package operation. Run without
`--overlay` to validate Ubuntu ALSA card registration.

On CentOS Stream 10, `--overlay` prepares EPEL and the Qualcomm aarch64 and
noarch RPM repositories, refreshes DNF metadata, and installs
`audioreach-dkms`, `audioreach-pal`, and `audioreach-pipewire-plugin`. The
default mode ensures the distribution ALSA client package set before
validation.

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

The kernel scan retains `audio_kernel_errors.log` and
`audio_kernel_warnings.log` beside `dmesg_snapshot.log`, and replays findings
to stdout. APM timeouts and DAPM/no-backend warnings remain visible even when
registration passes. This passive suite reports boot-history scope, not errors
proven to originate from its execution. Missing or empty kernel evidence is
unverified, not clean. Diagnostics do not change the registration result and
do not start the DSP or run playback/capture probes.

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
results/Audio_Card_Registration/run-<timestamp>.<id>/matched_cards.txt
```

## Notes for Qualcomm Boards

Default artifacts are rooted in the invocation CWD. Each run retains a unique
`results/Audio_Card_Registration/run-<timestamp>.<id>/` directory for inventory,
DT/FIT and kernel diagnostics. `Audio_Card_Registration.res` stays in CWD for
result publication. Temporary files ignore inherited `TMPDIR` and stay inside
the evidence directory. Use a writable launch directory:

```sh
cd /var/qcom-linux-testkit/Runner/suites/Multimedia/Audio/Audio_Card_Registration
./run.sh
```

A DT traversal/tool error fails preflight, rather than being treated as an empty
hardware inventory. Existing optional-evidence and explicit DT/FIT policies
remain unchanged.

On Qualcomm boards, this test is useful for identifying early audio bring-up issues such as:

- Machine driver not probing
- Sound card DT node missing or incorrect
- Codec or macro probe failures
- LPASS/Q6/ASoC registration issues
- SoundWire-related probe issues
- `/dev/snd` node creation problems

This test should remain lightweight and non-destructive. It should not attempt to recover the audio subsystem by restarting services or remote processors.
