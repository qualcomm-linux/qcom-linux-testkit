# Audio Playback Validation Script for Qualcomm Linux-based Platform (Yocto)

## Overview

This suite automates the validation of audio playback capabilities on Qualcomm Linux-based platforms. It supports PipeWire, PulseAudio, and direct ALSA backends with robust evidence-based PASS/FAIL logic, asset management, and diagnostic logging.


## Features

### Active DT and FIT preflight

Before topology checks and test-driven DSP startup, the runner reports the live DT model, complete
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

Suite-specific examples, with the requested clip already provisioned:

```sh
# Base playback, discover the speaker PCM dynamically.
./run.sh --backend alsa --sink speakers --clip-name playback_config1 \
    --expected-dt-compatible qcom,shikra-iqs-evk

# Prepared CQS/IQS AudioReach image, this does not select a boot DT.
./run.sh --overlay --sink speakers --clip-name playback_config1 \
    --expected-dt-compatible qcom,shikra-iqs-evk
```

Expected outcomes: a matching DT permits the normal test to run, it does not
itself produce PASS. An explicit DT mismatch or unverifiable explicit FIT
produces FAIL before topology validation. Missing optional automatic FIT/EFI
evidence reports unverified detection and preserves the suite's normal
PASS/FAIL/SKIP policy. Inspect `dt-fit-preflight/report.txt` and the accompanying
inventory/tool logs under the suite's retained log directory.

### Runtime ALSA routing and image-provided assets

Base playback uses UCM first. Without a matching UCM route, the shared helper
matches an exposed mixer frontend (for example, `MultiMedia1`) to the PCM name
reported by `aplay -l`. Direct-codec cards use their named speaker DAI link.
Card and PCM numbers are discovered, not inferred from a SoC or form factor.
Multiple frontends connected to the same backend are valid candidates. Automatic
selection uses the lowest registered PCM number, then validates it with the
existing bounded playback probe. Mixer and frontend volume writes follow that
selected PCM. An explicit PCM must map to the requested route. This does not
scan unrelated devices or hide a selected PCM's execution failure.
A conflicting backend or ambiguous PCM mapping for one frontend fails preparation instead
of falling back to an unrelated headphones/USB device. Existing generic-card
and UCM paths remain available. Mixer writes are bounded and failures are
reported, with the selected card, control and value on stderr.

Before remoteproc startup, base preflight discovers enabled sound-card DT links
to `qcom,q6apm`. It requires a nonempty `<DT-model>-tplg.bin` in one unambiguous
image firmware `qcom/<driver>/` directory, including running-kernel directories
and compressed firmware supported by the shared resolver. A missing, empty or
ambiguous file fails before the DSP starts. No card registration is needed for
this prerequisite check, and no SoC-to-file lookup table is used.

After registration, for cards whose runtime DT links reference `qcom,q6apm`, the helper verifies
the image-provided `qcom/<driver>/<model>-tplg.bin`, following the public kernel
topology-loader naming contract. The selected card's DT model and ALSA driver
identity supply the names. Direct-codec cards do not require this topology.
The test does not copy or download topology, UCM, firmware, or calibration files.
Provision these in the build, along with `aplay`, `arecord`, `amixer` and any UCM
data. Missing required assets or failure to start an applicable audio remoteproc
is FAIL. No applicable audio hardware in automatic mode remains SKIP.

For base ALSA or automatic backend selection, an applicable audio remoteproc is
followed by a bounded registration wait, up to 30 seconds for a card and another
10 seconds for a playback PCM. A timeout reports registration failure with ALSA
and remoteproc inventory. Explicit managed backends, overlay and null routes
do not acquire this ALSA readiness requirement.

When registration times out, the result stays FAIL and the test observes for
another 15 seconds to capture late remoteproc watchdog/recovery messages. It
does not restart the DSP or turn late registration into PASS. A crash/recovery
observed before registration completes also fails preparation. Diagnostics are
stored under `results/AudioPlayback_<suffix>/run-<timestamp>.<id>/remoteproc-preflight/` (without the
suffix when none is supplied): kernel snapshot, filtered errors, access status,
remoteproc state/inventory, current-window audio events, attributed remoteproc
failures and deferred probes. Key evidence is replayed to stdout. At normal
completion the same health classifier reuses the final kernel snapshot, without
recapturing it. Old messages and crashes from unrelated remoteprocs do not
become current-run failures. Missing kernel-log access is reported as a
diagnostic limitation, never proof of a healthy DSP. `--no-dmesg` disables kernel
capture and the extra observation window, but retains sysfs failure diagnostics.

Preflight retains the complete kernel snapshot. Scanner output is kept in
`kernel_capture.log`, but only current-window audio/selected-remoteproc events
are replayed. Unrelated PCIe/Ethernet messages and benign dummy-regulator context
are not presented as audio failures. Selected remoteproc crash evidence is retained.

The final scan also writes `audio_kernel_errors.log` and
`audio_kernel_warnings.log` beside the raw snapshot, and replays findings to
stdout. APM timeouts and DAPM/no-backend warnings remain visible even when the
streams pass. Counts cover the recorded preparation window, or boot history
when no window was established. Missing or empty kernel evidence is unverified,
not clean. These diagnostics do not change functional PASS policy or the
separate selected-DSP crash gate.

ALSA preparation announces its start before discovery, topology and mixer checks.
Each attempt's diagnostics are replayed on completion and retained in
`alsa_playback_probe.log` under the suite result directory. Stream-probe duration is
reported separately from total preparation time. Media invocation and result
policy are unchanged. `[AUDIO-PHASE]` lines show discovery, topology/mixer
preparation and each mixer write with elapsed seconds and status. These phases
are nested, not additive. They identify setup delays without extending the stream
duration or changing command timeouts. The post-execution snapshot can show inactive streams
after successful playback. These counters are not continuous monitoring, and
existing log-derived/fallback evidence remains part of the summary.

Issue #624 coverage uses the same runner and capability discovery:

| Form factor | Base route | Build topology | Overlay |
| --- | --- | --- | --- |
| CQS | TDM speaker frontend | `shikra-cqs-evk-tplg.bin` | PipeWire |
| CQM | Named WSA speaker link | No q6apm topology required | Not in scope |
| IQS | MI2S speaker frontend | `shikra-iqs-evk-tplg.bin` | PipeWire |

These names document the current build requirements, not a script lookup table.
See the public [qcom-next DTs](https://github.com/qualcomm-linux/kernel/tree/qcom-next/arch/arm64/boot/dts/qcom),
[topology loader](https://github.com/qualcomm-linux/kernel/blob/qcom-next/sound/soc/qcom/qdsp6/topology.c),
and [AudioReach configuration assets](https://github.com/AudioReach/audioreach-conf/tree/master/qcom/qli).

On a prepared Yocto image, with a non-silent WAV already under `/home/AudioClips`:

```sh
# Base ALSA, choose the speaker route from runtime inventory.
./run.sh --backend alsa --sink speakers --formats wav --durations short --audio-clips-path /home/AudioClips --no-extract-assets --timeout 0

# CQS/IQS overlay, require the physical PipeWire speaker route.
./run.sh --overlay --sink speakers --formats wav --durations short --audio-clips-path /home/AudioClips --no-extract-assets --timeout 0
```

Both `--overlay` and runtime-detected AudioReach modules select PipeWire,
without ALSA or PulseAudio fallback. An incompatible explicit backend fails.
Detection alone does not request package installation. On an already provisioned
CQS/IQS overlay image, the normal playback command works without `--overlay`:

```sh
./run.sh --clip-name "playback_config1 playback_config7" \
    --audio-clips-path /var/AudioClips/AudioClips
```

Before overlay service preparation or route polling, the selected test user must
have `wpctl` and either `pw-play` or a `pw-cat` supporting `--playback`. Missing
clients fail immediately with the required image capabilities in stdout and
`overlay-services/clients.log`, without waiting for nonexistent routes or
installing packages. Optional `pw-cli` supplies richer diagnostics, its absence
is reported as unavailable evidence, not a shell error.

On Debian and CentOS, both explicit and detected overlays use the existing
desktop-user runtime preparation. Active unchanged PipeWire is preserved even
when its control plane is unresponsive, then bounded physical-route discovery
must succeed. An inactive or failed service gets one existing bounded restart.
Pending jobs, transitional or incomplete core-unit evidence fail without restart.
An explicitly requested package transition retains its existing restart policy.
Automatic detection does not request an overlay package transition. Ubuntu's
explicit-overlay SKIP, base ALSA/PulseAudio paths, and native system-service
policies are unchanged. RHEL does not gain Debian/CentOS package or desktop
service preparation. Non-systemd images require image-provided running services.
An active server with no physical sinks still fails, with no ALSA fallback.

On readiness failure, `overlay-services/failure-server.log` also captures
startup logs for the current PipeWire/WirePlumber processes, bounded by their
reported start time, PID and current boot. Root reads desktop logs from the
system journal using the exact test UID and user-unit names, so missing per-user
journal files do not hide initialization errors. Non-root and native runs keep
their journal scope. Missing tools, identity or access remain diagnostic limits.
`initialization-errors.log` retains up to 20 distinct ACDB-open and AGM graph-init
errors and replays them to stdout. The final failure reason includes a short
summary with paths reported by the runtime, without board-specific mappings.
An ACDB-open error does not prove file absence, check image provisioning and
service permissions. Startup history only explains failed readiness, it does
not fail a successful stream or trigger service resets, downloads or permission
changes. Topology binaries do not replace the image's required ACDB payload.

For the runtime-selected modem overlay, setup follows this order:

1. Verify DT/FIT policy and provisioned firmware, then start the selected DSP
   only if it is offline. No numeric remoteproc index is assumed.
2. Wait up to 10 seconds per device for modem passthrough and its audio heap.
   Log original mode, owner and service user, then check test-user access.
   **No chmod or chown is performed.** Missing/inaccessible devices fail.
3. Reuse active PipeWire, including after DSP startup, when it responds in
   the test-user session, the requested playback route exists and
   `pipewire.service` is active. Discover and deduplicate installed audio-unit
   aliases before reuse, then require every discovered service/socket to have
   no pending job or transitional state. No setup marker is used.
   Wait up to `PIPEWIRE_READY_TIMEOUT` (default 120 seconds) for its route,
   with individually bounded client queries. If discovery still fails, report
   FAIL without resetting active services. If PipeWire is inactive or failed,
   snapshot activity and perform one reset-and-start attempt using the installed
   audio units. Recheck device access before starting PipeWire. No repeated
   recovery attempt is made.
4. Wait for live readiness and require the requested playback route
   before playing clips. Readiness or routing failure is FAIL, not SKIP.
5. After readiness succeeds, retain the prepared native overlay services for
   subsequent tests and reruns. Do not stop a recovered PipeWire service just
   because it was initially inactive or failed. Incomplete setup still rolls
   back initial activity, and rollback failure makes the suite FAIL.

This one-time service recovery is restricted to native systemd modem-audio overlays.
Desktop user sessions and non-modem platforms keep their established service
paths. Non-systemd images use already provisioned running audio services.
Pending jobs, transitional states or incomplete unit queries prevent both reuse
and startup, with FAIL and no service mutation by this preparation. Wait for the
existing jobs to settle before retrying. Optional inactive services/sockets are
not required to be active. Pre-existing failed optional units remain visible in
the inventory, the requested live route and functional stream are still required.
`overlay-services/preflight-units` and its `.raw` file retain the canonical unit
set and refreshed states/jobs before the decision, also replayed to stdout.
`reuse-units` rechecks those states after route discovery. `reuse-route.log`
retains each reuse probe's return code, target and diagnostics. `route-check.log`
does the same after startup. Readiness failures capture `failure-server.log`
and `failure-nodes.log` before rollback, replaying service identity, recent
journal errors and node inventory to stdout. Missing diagnostic tools are
reported without replacing the original failure. A startup crash remains FAIL
even if rollback restores the initial activity.
The reuse message reports control-plane readiness, not a clean audio data path.
Existing optional-unit failures and DSP/APM errors remain visible, and playback
must still pass its normal functional checks.
`overlay-services/` retains unit inventory, initial activity, setup/restore
output and failed PipeWire status. Service actions are queued nonblocking, then
wait for final activity with no pending job, using the existing
`PIPEWIRE_SYSTEMCTL_TIMEOUT` (default 180 seconds). Command return codes, unit
states, results, job IDs and configured systemd timeouts are retained in
`setup-*` and `restore-*` artifacts, with progress on stdout. The completion
bound does not cancel systemd jobs. A timeout fails, and cleanup refuses to
queue conflicting restoration while audio jobs remain pending. Inspect the
retained jobs before retrying. Every rerun checks live readiness again, without
trusting a persistent setup marker. A stream failure remains FAIL and does not
trigger a retry or automatically undo a successfully prepared service stack.
`discovery-failure/` retains kernel evidence
for terminal discovery failures unless `--no-dmesg` is supplied.

The modem path requires `/dev/aud_pasthru_modem` and uses
`/dev/dma_heap/qcom,audio`, even if device registration fails. Other overlays
retain the system heap. `AUDIO_DMA_HEAP_NODE` remains an override.
Ubuntu's explicit overlay SKIP and Debian/CentOS package preparation policy are
unchanged. Base automatic discovery still SKIPs absent optional routes, but a
candidate that fails preparation or playback makes exhausted discovery FAIL.
A working alternative automatic route can still be selected.

Use `AudioPlayback.yaml` with `AUDIO_BACKEND=alsa` for base CI, or
`AudioPlayback_Overlay.yaml` for overlay CI. ALSA inventory and mixer contents
are retained alongside the existing PipeWire/PulseAudio diagnostics. Successful
playback proves stream execution, not acoustic output at the physical speaker.

- Supports **PipeWire**, **PulseAudio**, and direct **ALSA** backends
- **10-clip test coverage**: Comprehensive validation across diverse audio formats (sample rates: 8KHz-48KHz, bit depths: 8b-32b, channels: 1ch-8ch)
- **Flexible clip selection**: 
  - Use generic config names (playback_config1-playback_config10) for easy selection
  - Use descriptive names (e.g., play_48KHz_8b_2ch) for specific formats
  - Auto-discovery mode tests all available clips
- **Clip filtering**: Filter tests by sample rate, bit rate, or channel configuration
- **CI/LAVA integration**: 
  - Unique result file suffixes prevent file collisions in parallel test runs
  - Unique testcase IDs prevent LAVA testcase ID collisions
  - Enables running multiple AudioPlayback configurations simultaneously in CI
- Plays audio clips with configurable format, duration, and loop count
- Validates every WAV before playback and emits machine-readable
  `AUDIO_VALIDATION` records for both clip integrity and playback execution
- **Network operations are optional**: By default, no network connection is attempted. Use `--enable-network-download` to enable downloading missing audio files
- Automatically downloads and extracts audio assets if missing

Playback clip validation blocks only on basic integrity failures: corrupt or
empty WAV files, header-only payloads, all-zero audio, materially short clips,
or filename metadata that disagrees with the WAV header. RMS, peak, clipping,
digital-silence runs, DC offset, large sample transitions, and silent-channel
counts are reported as diagnostic `AUDIO_VALIDATION` metrics and do not fail the
default policy. Complete RIFF chunks after the audio `data` chunk are reported
as `post_data_chunks` metadata and are not misclassified as trailing audio.
- Validates playback using multiple evidence sources:
  - PipeWire/PulseAudio streaming state
  - ALSA and ASoC runtime status
  - Kernel logs (`dmesg`)
- Diagnostic logs: dmesg scan, mixer dumps, playback logs	
- Evidence-based validation (user-space, ALSA, ASoC, dmesg)	
- Generates `.res` result file and optional JUnit XML output
								 

## Audio Clip Configurations

The test suite includes 10 diverse audio clip configurations covering various sample rates, bit depths, and channel configurations:

```  
| Config   | Config Name       | Sample Rate | Bit Rate | Channels |
|----------|-------------------|-------------|----------|----------|
| Config01 | playback_config1  | 8 KHz       | 8-bit    | 1ch      |
| Config02 | playback_config2  | 16 KHz      | 8-bit    | 6ch      |
| Config03 | playback_config3  | 16 KHz      | 16-bit   | 2ch      |
| Config04 | playback_config4  | 22.05 KHz   | 8-bit    | 1ch      |
| Config05 | playback_config5  | 24 KHz      | 24-bit   | 6ch      |
| Config06 | playback_config6  | 24 KHz      | 32-bit   | 1ch      |
| Config07 | playback_config7  | 32 KHz      | 8-bit    | 8ch      |
| Config08 | playback_config8  | 32 KHz      | 16-bit   | 2ch      |
| Config09 | playback_config9  | 44.1 KHz    | 16-bit   | 1ch      |
| Config10 | playback_config10 | 48 KHz      | 8-bit    | 2ch      |
```   

**Coverage Summary:**
- Sample Rates: 8 KHz, 16 KHz, 22.05 KHz, 24 KHz, 32 KHz, 44.1 KHz, 48 KHz
- Bit Depths: 8-bit, 16-bit, 24-bit, 32-bit
- Channel Configurations: 1ch (Mono), 2ch (Stereo), 6ch (5.1 Surround), 8ch (7.1 Surround)
- Total Configurations: 10 unique audio format combinations

## Prerequisites

Yocto images must provide the following components. The suite does not change
the Yocto package flow.

- PipeWire: `pw-play` or `pw-cat --playback`, plus `wpctl`. CentOS provides
  these playback clients in the `pipewire-utils` image package.
- PulseAudio: `paplay`, `pactl`
- ALSA: `aplay`, `amixer`, `alsaucm` when UCM is available
- Common tools: `pgrep`, `timeout`, `grep`, `tar`, and either `curl` or `wget`
- Daemon: `pipewire` or `pulseaudio` must be running

On Debian, Ubuntu, and CentOS, the selected backend controls client package
recovery. PipeWire ensures `pw-play`, `pw-record`, and `wpctl`; ALSA ensures
`aplay` and `arecord`; PulseAudio ensures `paplay`, `parecord`, and `pactl`.
Yocto continues to use image-provided clients.

### Audio asset extraction

Before downloading a missing clip archive, the suite checks gzip-tar extraction
with a small local archive. On CentOS, missing or unusable extraction tools
trigger the shared provider's complete `audio-extract` set, `tar gzip`, followed
by another capability check. Recovery respects the provider's installation
policy and permissions. Healthy reruns do not perform extractor package work.
Yocto, Debian, Ubuntu, RHEL and other OSes retain their image-provided extraction
policy. A tar implementation with built-in gzip support does not require a
separate `gzip` executable. Extraction errors are retained under the current
run's artifact directory and printed to stdout. Unavailable prerequisites or
failed preparation retain the existing asset SKIP behavior.

On LRH/CentOS, request missing-asset preparation with:

```sh
./run.sh --enable-network-download --clip-name playback_config1
```

If matching clips are already provisioned, they are reused without downloading
or installing extraction tools. Neither base nor overlay audio backend selection
is changed by this preparation.

### Ubuntu package preparation

When run as root, the suite uses the shared package provider to install missing
Ubuntu audio packages. It does not run a blanket distribution upgrade.
When network download is requested and neither downloader is present, Ubuntu
uses the shared package provider to install the complete `audio-download` set,
`curl wget`, from the image's configured APT sources. Other distributions keep
their image-provided downloader policy. Each displayed download attempt has a
finite deadline. If recovery is unavailable or fails, the suite skips and
reports the missing prerequisite.

If the target already has a valid global IPv4 address but the generic ICMP
probe is blocked, the suite preserves the active interface and lets the bounded
HTTPS download validate endpoint reachability. It does not cycle Wi-Fi, renew
DHCP, or probe unrelated network services in that state. CentOS targets using
the systemd-managed `NetworkManager.service` are recognized through `nmcli`
when network activation is actually required. The absence of
`systemd-networkd` or ConnMan is not reported when NetworkManager is active.

- `auto` is the default profile. It selects `desktop` when `graphical.target`
  is active and otherwise selects `server`.
- `server` ensures `alsa-utils` for ALSA playback.
- `desktop` ensures `alsa-utils`, `pipewire`, `pipewire-pulse`, `wireplumber`,
  `pipewire-bin`, and `pulseaudio-utils`.
- AudioReach is not enabled for Ubuntu. An explicit `--overlay` request reports
  SKIP before any AudioReach source refresh or package operation. Rerun without
  `--overlay` to validate the Ubuntu base Audio stack.
- Set `AUDIO_PACKAGE_UPDATE=1` only when installed packages should be upgraded
  as part of the test preparation.

The optional `snd-soc-wcd938x` codec module is loaded only when the running
kernel provides it. Targets without that module are unchanged.

### CentOS Stream 10 overlay preparation

An explicit `./run.sh --overlay` request ensures EPEL and the Qualcomm CentOS
10 aarch64 and noarch repositories, refreshes DNF metadata, and installs:

```text
audioreach-dkms audioreach-pal audioreach-pipewire-plugin
```

If the DKMS package changes, the suite requests a reboot before validation.
In base mode, CentOS recovers only the complete client set for the selected
backend from the configured distribution repositories.

Backend client checks run after package recovery. PipeWire uses `pw-play` when
available and falls back to `pw-cat --playback`. Automatic backend selection
falls back to an available ALSA path. Package-recovery failure is reported as
FAIL before any audio-clip download begins.

When launched by root on Debian or CentOS, the suite discovers and prepares the
regular desktop audio user, then runs PipeWire, PulseAudio, UCM, mixer, and PCM
operations in that user's context. Yocto retains its native execution model,
and Ubuntu continues to use its dynamically discovered desktop session.

```sh
# Let the suite detect a server or desktop Ubuntu image
./run.sh --clip-name "playback_config1 playback_config7"

# Force desktop package preparation
AUDIO_PACKAGE_PROFILE=desktop \
  ./run.sh --clip-name "playback_config1 playback_config7"

# Upgrade the selected profile's installed packages
AUDIO_PACKAGE_PROFILE=desktop AUDIO_PACKAGE_UPDATE=1 \
  ./run.sh --clip-name "playback_config1 playback_config7"
```

## Backend and Route Selection

When no route is requested, `auto` discovers speakers first and then headphones on the running target. A physical PipeWire audio sink uses `pw-play` or `pw-cat --playback`, and a physical PulseAudio sink uses `paplay`. `speaker` and `speakers` explicitly select the speaker route. `headphone`, `headphones`, and `headset` explicitly select the headphones route. A generic physical output remains a compatibility fallback for automatic or explicit speaker selection, but an explicitly named headphones endpoint is never used as speakers. Dummy, null, monitor, and loopback PipeWire sinks are not accepted as physical routes. `--sink auto` also restores automatic route selection. The selected backend, request source, explicitness, requested alias, canonical route, runtime target, and UCM device are emitted to standard output in an `AUDIO_ROUTE` record.

If automatic selection finds no matching managed sink, the suite probes direct ALSA speakers and then headphones. UCM discovery enumerates every card and HiFi device, retrieves `PlaybackPCM`, enables the exact device, verifies `_enadevs`, and functionally opens the resulting PCM. An explicit semantic route is never replaced by another route. An explicit route that cannot be discovered and opened reports FAIL, while automatic discovery with no applicable physical output reports SKIP. The remaining UCM namespace, `plughw:` conversion, legacy speaker fallback, and audio-remoteproc applicability rules remain unchanged.

An explicit backend request is never replaced:

- `--backend pipewire` or `AUDIO_BACKEND=pipewire` runs `pw-play` or `pw-cat --playback`. A client absent from the image remains an optional-capability SKIP for compatibility, but a ready backend with no requested physical sink fails.
- `--backend pulseaudio` or `AUDIO_BACKEND=pulseaudio` runs `paplay` only. A ready backend with no requested sink fails.
- `--backend alsa` or `AUDIO_BACKEND=alsa` runs `aplay` with the discovered ALSA route.

Existing Yocto/LAVA YAML definitions keep their `SINK_CHOICE=speakers` contract,
which is treated as an explicit speaker validation. Override that parameter with
`auto` when a job should choose speakers or headphones from runtime evidence.

PulseAudio discovery rejects null, dummy, monitor, loopback, and freewheel
endpoints before selecting a physical route. It uses the endpoint name,
description, form factor, and active port to distinguish speakers from
headphones while preserving a generic physical sink as the compatibility
fallback on older distributions with sparse metadata.

## Audio Remoteproc Preflight

Before backend discovery, the suite enumerates runtime remoteprocs and checks the configured firmware and topology under `/lib/firmware` or `/usr/lib/firmware`. It recognizes audio DSP identities and the Shikra modem-hosted audio path. A remoteproc named `modem` is ignored on non-Shikra targets because it is not their audio preflight dependency.

If the matching remoteproc is `running`, the suite records its name and firmware evidence. If it is `offline`, the suite starts it only after confirming the corresponding firmware is provisioned. Generic audio DSP paths also require adjacent topology evidence. Shikra's modem-hosted path does not require a topology beside the modem firmware, the selected ALSA card's q6apm topology is validated separately. The suite never stops a remoteproc. Platforms with no applicable audio remoteproc continue normally. Provisioning or start issues on an applicable remoteproc report FAIL with the reason.

## Overlay Build Support

For overlay builds using audioreach kernel modules, the test automatically:
- Detects the overlay build configuration
- Checks image-provided DMA heap access without changing permissions
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
            └── AudioPlayback/
                ├── run.sh
                ├── Read_me.md
                ├── AudioPlayback.yaml                
                ├── AudioPlayback_Config01.yaml
                ├── AudioPlayback_Config02.yaml
                ├── ...
                └── AudioPlayback_Config10.yaml
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

# Select headphones using the runtime PipeWire endpoint
./run.sh --backend pipewire --sink headphones --loops 1

# Select headphones through the dynamically discovered UCM card and PlaybackPCM
./run.sh --backend alsa --sink headphones --loops 1

# Run with PulseAudio, null sink, strict mode, verbose
./run.sh --backend pulseaudio --sink null --strict --verbose

# Disable asset extraction (offline mode)
./run.sh --no-extract-assets

# Provide JUnit output and disable dmesg scan
./run.sh --junit results.xml --no-dmesg

# CI/LAVA workflow: Using pre-configured YAML files
# Each configuration has its own YAML file in the same directory as run.sh
# These can be run directly by LAVA as separate test cases

# Method 1: Using the pre-configured YAML files directly (recommended for LAVA)
# LAVA will execute these automatically based on the YAML definitions

# Method 2: Using run.sh with specific configurations
./run.sh --clip-name "playback_config1" --res-suffix "Config01" --audio-clips-path /home/AudioClips/ --no-extract-assets
./run.sh --clip-name "playback_config7" --res-suffix "Config07" --audio-clips-path /home/AudioClips/ --no-extract-assets
# This generates AudioPlayback_Config01.res and AudioPlayback_Config07.res (no overwriting)



Environment Variables:
Variable	             Description	                                   Default
AUDIO_BACKEND	         Selects backend: pipewire, pulseaudio, or alsa	       auto-detect
SINK_CHOICE	             Playback sink: auto, speakers, headphones, or null	   auto
CLIP_NAMES               Test specific clips (e.g., "playback_config1 playback_config2")    playback_config1
CLIP_FILTER              Filter clips by pattern (e.g., "48KHz" or "16b" or "2ch")          unset
FORMATS	                 Audio formats: e.g. wav	                       wav
DURATIONS	             Playback durations: short, medium, long (legacy mode only)    ""
LOOPS	                 Number of playback loops	                       1
TIMEOUT	                 Playback timeout per loop (0=automatic for discovered clips) "10s"
STRICT	                 Enable strict mode (fail on any error)            0
DMESG_SCAN	             Scan dmesg for errors after playback	           1
VERBOSE	                 Enable verbose logging                            0
EXTRACT_AUDIO_ASSETS     Download/extract audio assets if missing	       true
ENABLE_NETWORK_DOWNLOAD  Enable network download of missing audio files    false
AUDIO_CLIPS_BASE_DIR     Custom path to pre-staged audio clips (CI use)    unset
AUDIO_PACKAGE_PROFILE    Ubuntu package profile: auto, server, or desktop  auto
AUDIO_PACKAGE_UPDATE     Upgrade selected Ubuntu audio packages             0
JUNIT_OUT                Path to write JUnit XML output                    unset
SSID                     Wi-Fi SSID for network connection                 unset
PASSWORD                 Wi-Fi password for network connection             unset
NET_PROBE_ROUTE_IP       IP used for route probing (default: 1.1.1.1)      1.1.1.1
NET_PING_HOST            Host used for ping reachability check             8.8.8.8
RES_SUFFIX               Suffix for unique result file and log directory   unset
LAVA_TESTCASE_ID         Unique testcase ID written into the .res file for LAVA    AudioPlayback


CLI Options
Option	                    Description
--backend	                Select backend: pipewire, pulseaudio, or alsa
--sink	                    Playback sink: auto, speaker(s), headphone(s), headset, or null
--clip-name <names>         Test specific clips using playback_config1-playback_config10 or descriptive names (space-separated)
--clip-filter <patterns>    Filter clips by sample rate, bit rate, or channels (space-separated patterns)
--formats	                Audio formats (space/comma separated): e.g. wav 
--durations	                Playback durations: short, medium, long (legacy mode only)
--loops	                    Number of playback loops
--timeout <duration>      Playback timeout per loop; 0 uses clip duration plus five seconds in discovery mode
--strict	                Enable strict mode
--no-dmesg	                Disable dmesg scan
--no-extract-assets         Disable asset extraction entirely (skips all asset operations)
--enable-network-download   Enable network operations to download missing audio files (default: disabled)
--audio-clips-path <path>   Custom location for audio clips (for CI with pre-staged clips)
--res-suffix <suffix>       Suffix for unique result file and log directory (e.g., "Config01" generates AudioPlayback_Config01.res and results/AudioPlayback_Config01/)
--lava-testcase-id <id>     Unique testcase ID written into the .res file for LAVA (e.g., "AudioPlayback_Config01")
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
sh-5.3# ./run.sh --clip-name "playback_config1" --res-suffix "Config01" --audio-clips-path /home/AudioClips/ --no-extract-assets
[INFO] 2026-01-22 17:46:33 - Using unique result file: ./AudioPlayback_Config01.res
[INFO] 2026-01-22 17:46:33 - ---------------- Starting AudioPlayback ----------------
[INFO] 2026-01-22 17:46:33 - Using clip discovery mode
[INFO] 2026-01-22 17:46:33 - Discovered 1 clips to test
[INFO] 2026-01-22 17:46:33 - [play_16KHz_16b_2ch] Clip duration: 30s (minimum successful runtime: 29s)
[PASS] 2026-01-22 17:47:04 - [play_16KHz_16b_2ch] loop 1 OK (rc=0, 30s)
[PASS] 2026-01-22 17:47:04 - AudioPlayback PASS

sh-5.3# cat AudioPlayback_Config01.res
AudioPlayback PASS

sh-5.3# ./run.sh --clip-name "playback_config7" --res-suffix "Config07" --audio-clips-path /home/AudioClips/ --no-extract-assets
[INFO] 2026-01-22 17:48:34 - Using unique result file: ./AudioPlayback_Config07.res
[PASS] 2026-01-22 17:49:05 - AudioPlayback PASS

sh-5.3# cat AudioPlayback_Config07.res
AudioPlayback PASS

# Both result files exist without overwriting
sh-5.3# ls -1 AudioPlayback*.res
AudioPlayback_Config01.res
AudioPlayback_Config07.res
```

**Example 7: CI/LAVA workflow with unique testcase IDs (prevents LAVA collisions)**
```
# Using --lava-testcase-id ensures unique testcase IDs in LAVA results
# This prevents testcase ID collisions when running multiple AudioPlayback configs in parallel

sh-5.3# ./run.sh --clip-name "playback_config1" --res-suffix "Config01" --lava-testcase-id "AudioPlayback_Config01" --audio-clips-path /home/AudioClips/ --no-extract-assets
[INFO] 2026-01-22 18:10:15 - Using unique result file: ./AudioPlayback_Config01.res
[PASS] 2026-01-22 18:10:45 - AudioPlayback PASS

sh-5.3# cat AudioPlayback_Config01.res
AudioPlayback_Config01 PASS

sh-5.3# ./run.sh --clip-name "playback_config7" --res-suffix "Config07" --lava-testcase-id "AudioPlayback_Config07" --audio-clips-path /home/AudioClips/ --no-extract-assets
[INFO] 2026-01-22 18:11:30 - Using unique result file: ./AudioPlayback_Config07.res
[PASS] 2026-01-22 18:12:00 - AudioPlayback PASS

sh-5.3# cat AudioPlayback_Config07.res
AudioPlayback_Config07 PASS

# LAVA will receive unique testcase IDs:
# - AudioPlayback_Config01 PASS
# - AudioPlayback_Config07 PASS
# No testcase ID collisions!
```

Results:
- Results are stored in a unique run directory below CWD/results/AudioPlayback/ (or CWD/results/AudioPlayback_<suffix>/ when using --res-suffix).
- Summary result file: AudioPlayback.res (or AudioPlayback_<suffix>.res when using --res-suffix)
- JUnit XML (if enabled): <your-path>.xml
- Diagnostic logs: dmesg snapshots, mixer dumps, playback logs per test case, and `alsa_playback_probe.log` containing the selected direct-ALSA candidate, probe command, exit status, and `aplay` error output
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

## Working directory and reruns

Clip selection is resolved before audio-user/service and DSP preparation.
The inventory prints each runtime filename, its `playback_configN` index and
its semantic selector when the filename can be parsed. Indices follow the
sorted installed inventory, they are not fixed sample-rate mappings. Exact
WAV basenames are also accepted. Clip directory paths may contain spaces,
but individual filenames must not contain whitespace.

Malformed selectors, conflicting modes and discovery-tool/access errors FAIL.
Absent requested assets SKIP with the available inventory. A partially matched
explicit list does not run only its available subset. Existing network-download
opt-in and image-package policy remain unchanged. For example:

```sh
./run.sh --overlay --sink speakers --clip-name playback_config1 --audio-clips-path /var/AudioClips/AudioClips
./run.sh --overlay --sink speakers --clip-name yesterday_16KHz_30s_16b_2ch.wav --audio-clips-path /var/AudioClips/AudioClips
```

The second example requires that exact installed filename. PipeWire clients
receive `--target`, and playback does not change the session default sink.
Temporary sink volume/mute changes are snapshotted and restored on the same
object serial, with readback verification. If `pw-cli` is absent, volume/mute
state is left unchanged with a warning. `playback-volume.initial` retains the
original properties. A replacement node is never modified during restoration.

Launch from a writable directory. Test-owned logs, scratch files and default
result files are stored under that invocation directory, even when using an
absolute path to `run.sh`. An inherited `TMPDIR=/data/local/tmp` is not used.
Source/config discovery still uses the installed test directory. Existing
explicit output-path options remain supported.

If a minimal image needs a test-started audio daemon, its private runtime
directory is a short `.ar.<id>` child of CWD. An excessively long CWD fails
with a request to use a shorter directory, rather than exceeding Linux's
Unix-socket path limit. Existing system-managed runtime directories are reused.

Each invocation retains a separate `results/AudioPlayback[_suffix]/run-<timestamp>.<id>/` directory for playback logs, download logs/archives, route probes and diagnostics. Default clips are stored in `CWD/AudioClips` for reuse across runs. Desktop-user commands use a dedicated writable scratch child, while the existing session socket stays in its system-managed location.

For example, use the suite directory on the DUT:

```sh
cd /var/qcom-linux-testkit/Runner/suites/Multimedia/Audio/AudioPlayback
./run.sh
```

Keep the same working directory when publishing the `AudioPlayback.res` file.
The LAVA definitions already launch from the suite directory. A CWD permission
or artifact-creation error must be corrected before rerunning, it is not proof
that audio hardware is absent.

## License

SPDX-License-Identifier: BSD-3-Clause(C) Qualcomm Technologies, Inc. and/or its subsidiaries.
