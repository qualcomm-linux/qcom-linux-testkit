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

For legacy mixer routes with multiple frontends on the same backend, automatic
selection uses the lowest registered PCM number and validates it through the
existing open probe. Mixer preparation follows the selected playback/capture
PCM, including explicit device overrides. Conflicting backend mappings fail
instead of selecting an unrelated route. UCM remains the preferred path.

On Debian and CentOS, a root invocation prepares the regular desktop audio user
and re-launches the complete test as that user. Automatic selection also
prepares the user's systemd session so PipeWire and PulseAudio control and data
paths match the working desktop route. Yocto and Ubuntu keep their existing
execution behavior.

## Active DT and FIT preflight

Managed capture uses the same sample-progress monitor as AudioRecord. Playback
starts only after a valid capture header and actual PCM payload are observed,
not after a fixed sleep. PipeWire capture also reuses runtime source identity
and per-channel volume preparation/restoration. Capture must collect at least
`duration + 2` seconds of PCM and remain running until playback completes.
Startup, idle and overall waits remain bounded. Native ALSA retains its
image-provided `arecord -d` path and is also checked for payload before playback.

PipeWire playback is pinned with `--target`. Neither managed backend changes
the session defaults. Temporary PipeWire sink mute and source volume changes
are restored on the original nodes. Service reuse is independent of these
temporary stream settings. The fixture must still provide an acoustic or
electrical path, nonzero PCM alone does not prove waveform correlation.

Capture logs, `.volume`, `.server-before`, `.server-after` and WAV `.links`
artifacts retain diagnostics where applicable, replayed to stdout on failure.
Kernel diagnostics cover the current test window rather than all boot history.
Header-only/startup failures do not start playback. Stream, stall and deadline
failures are not retried or converted into PASS by weakening WAV validation.

A zero playback-client exit status is logged as completion, not as a separate
functional playback PASS. PipeWire Loopback also checks the retained
capture-window server journal for explicit PAL stream-start, RX/TX session-start
and graph-open failures. These fail the overall loopback result even when both
clients return zero and the captured WAV contains nonzero samples. Errors may
belong to either duplex stream, they are not attributed to playback alone.
`loopback_server_errors.log` retains matched evidence and prints it to stdout.
No extra service reset or journal dependency is introduced. Missing/incomplete
journal access is a warning, not proof of clean driver health. The bounded
journal can omit earlier messages, and captured activity still does not prove
waveform correlation with the reference. ALSA and PulseAudio retain their
existing client/WAV checks, without a misleading standalone playback PASS.

```sh
./run.sh --duration 5 --sink speakers --source mic
```

Repeat the same command to validate reuse. No additional YAML parameter or
manual service reset is required.

Automatic selection on a native modem-audio overlay now uses the same runtime
mode discovery, image-provided DSP preparation and service readiness helpers as
AudioRecord and AudioPlayback. Existing modem-audio applicability determines
this path, not a new board-to-device table. An active PipeWire service is reused
without a reset, with up to `PIPEWIRE_READY_TIMEOUT` (default 120 seconds) for
both requested routes to appear. Client queries are individually bounded.
An inactive or failed service gets one reset-and-start attempt, followed by
the same readiness checks. Pending jobs or incomplete unit evidence fail
without queuing conflicting service actions. No repeated recovery is attempted.

Both playback and capture routes must be ready before the prepared services
are retained for reruns. Incomplete preparation rolls back initial activity.
Before service preparation or route polling, the selected execution context
must have `wpctl`, `pw-record`, and either `pw-play` or `pw-cat` supporting
`--playback`. Missing clients fail immediately with the required image
capabilities in stdout and `overlay-services/clients.log`, without installation.
Optional `pw-cli`, systemctl and journal tools are reported as unavailable
diagnostic evidence when absent, not invoked as missing commands. This does not
turn missing journal evidence into a clean driver result.
Readiness failures also capture current-process startup journals using service
start time, PID and current boot, with root-visible UID/user-unit filtering for
desktop diagnostics. `initialization-errors.log` prints distinct ACDB-open and
AGM graph-init failures and adds a short runtime-path summary to the final FAIL.
This history stays separate from the capture-window evidence used to validate
the stream. Missing tools or journal access remain diagnostic limits, not a
reason to change device permissions or reset services. No board path is assumed.
Failures retain and print route attempts, unit states and bounded service journal
evidence under `overlay-services/`, before rollback can replace crash evidence.
A failed overlay preparation, missing client or lost route does not fall back
to base ALSA and pass. Functional playback/capture validation is still required.

Explicit `--playback-device`/`--capture-device` selections keep their direct ALSA
path. Base images, non-modem platforms and Debian/Ubuntu/CentOS/RHEL desktop
paths keep their existing behavior. Without systemd, a running image-provided
audio server is required, the test does not install services or packages.

Before topology checks and test-driven DSP startup, the runner reports the live DT model, complete
compatible list and sound-card identities. CQS, CQM, IQS and future boards are
discovered from runtime data, not a fixed variant/PCM table. EFI
`VendorDtbOverlays` is read separately without mounting, writing or rebooting.
FIT DT overlays are independent of AudioReach runtime selection. Loopback does
not install or switch overlay packages.

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

Suite-specific example, with a real acoustic/electrical path from speakers to mic:

```sh
./run.sh --sink speakers --source mic --duration 5 \
    --expected-dt-compatible qcom,shikra-iqs-evk
```

This keeps backend and PCM discovery automatic. Loopback has no `--overlay`
option, it can use an already running managed audio backend.

Expected outcomes: a matching DT permits the normal test to run, it does not
itself produce PASS. An explicit DT mismatch or unverifiable explicit FIT
produces FAIL before topology validation. Missing optional automatic FIT/EFI
evidence reports unverified detection and preserves the suite's normal
PASS/FAIL/SKIP policy. Inspect `dt-fit-preflight/report.txt` and the accompanying
inventory/tool logs under the suite's retained log directory.

For direct ALSA on Shikra, the existing runtime platform detector selects the
shared modem/topology preparation before any stream probe, followed by playback
and capture registration waits. Other platforms retain their existing lazy DSP
recovery. The final captured kernel snapshot is checked for a selected DSP crash.
The loopback still requires an acoustic/electrical fixture and does not force
mono or change the WAV validation policy.

The final scan retains `audio_kernel_errors.log` and
`audio_kernel_warnings.log` beside the raw kernel snapshot and replays findings
to stdout. APM timeouts and DAPM/no-backend warnings remain visible even when
streams pass. Counts cover the preparation window when established, otherwise
boot history. Missing or empty evidence is unverified, not clean. These
diagnostics do not change functional PASS policy or the selected-DSP crash gate.
Direct ALSA capture discovery/preparation and individual mixer writes emit
`[AUDIO-PHASE]` timing. Nested phase durations are not additive and do not alter
stream commands or their timeouts.

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

Default logs, temporary files and `AudioLoopback.res` belong to the invocation
CWD, not the script location or an inherited `TMPDIR`. Existing `LOGDIR`
overrides remain supported. System-managed user-session sockets are unchanged.
Use a writable launch directory, for example:

```sh
cd /var/qcom-linux-testkit/Runner/suites/Multimedia/Audio/AudioLoopback
./run.sh
```

The desktop-user process uses its prepared evidence directory for scratch files.
An operational DT discovery error fails preflight instead of looking like absent
hardware. Empty discovery remains distinct from a traversal/tool failure.

`AudioLoopback.yaml` runs the default five-second test using automatic backend
and endpoint discovery. A CI device still needs an acoustic or electrical path
from the selected playback endpoint to the selected capture endpoint. Set
`PLAYBACK_DEVICE` and `CAPTURE_DEVICE` in the job parameters when direct ALSA
selection is required by the fixture.
