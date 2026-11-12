# Remoteproc_Restart_Validation

Repeated remoteproc stop/start or explicitly selected synthetic crash recovery,
with RPMsg and descendant driver/endpoint restoration.

This is a separate suite. Existing runners, plans and shared helper interfaces retain their current behavior. It uses runtime capability discovery on Yocto, Debian, Ubuntu and CentOS, including shell-only images. Required utilities and optional payloads must be supplied by the image or job. It does not install packages, change boot selection or start services.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--exercise` | `0` |
| `--processors` | `auto` |
| `--subsystem` | unset |
| `--rounds` | `3` |
| `--mode` | `stop-start` |
| `--stable-seconds` | `2` |

Direct runs use CLI options, Yocto profiles expose each option as a named parameter.
Direct invocation remains passive unless `--exercise 1` and a subsystem or
explicit processor selection are provided.

The Yocto YAML variants explicitly enable restart, with `TIMEOUT=30` seconds
and `ROUNDS=1`. Each profile exposes named parameters. Optional `MODE` and `STABLE_SECONDS` default to `null`, using runner defaults. Optional `PROCESSORS` defaults to `null`, preserving runtime DSP discovery. Choose the default-all YAML or the subsystem
YAMLs in a plan, using both repeats coverage of the same instances.

| YAML | Runtime selection |
|---|---|
| `Remoteproc_Restart_Validation.yaml` | All positively identified DSP families |
| `Remoteproc_Restart_ADSP.yaml` | All ADSP instances |
| `Remoteproc_Restart_CDSP.yaml` | All CDSP instances |
| `Remoteproc_Restart_GPDSP.yaml` | All GPDSP instances |
| `Remoteproc_Crash_Recovery.yaml` | One synthetic watchdog crash per round for all positively identified DSP families |

All variants use this runner and publish `Remoteproc_Restart_Validation.res`
under their separate LAVA definition names. Existing plans are unchanged.

Run from this suite directory:

```sh
./run.sh
./run.sh --exercise 1 --subsystem dsp --rounds 1 --timeout 30
./run.sh --exercise 1 --subsystem adsp --rounds 1 --timeout 30 --stable-seconds 2
./run.sh --exercise 1 --subsystem cdsp
./run.sh --exercise 1 --subsystem gpdsp --rounds 2 --timeout 30
./run.sh --exercise 1 --processors adsp,cdsp --rounds 3 --timeout 60
./run.sh --exercise 1 --subsystem dsp --processors adsp --rounds 1
./run.sh --exercise 1 --subsystem adsp --mode crash --rounds 1 --timeout 60
./run.sh --exercise 1 --subsystem dsp --mode crash --rounds 1 --timeout 60
```

Requires `--exercise 1` and either `--subsystem` or explicit `--processors`.
Choose only processors whose lifecycle the test is permitted to change, with
no competing client or lifecycle manager. Explicit processor names or stable
owner IDs override subsystem selection, regardless of argument order.
The examples use illustrative runtime identities, discover actual names and
owners from the logged sysfs inventory before supplying an explicit selection.

Automatic selection resolves DT symlinks, checks enabled ancestors, identifies
DSP processor compatible tokens and requires matching registered remoteprocs
and bound drivers. DSP memory/client nodes, modem/WiFi identities and ambiguous
compatible identities are excluded or rejected. A cooling provider beneath a
DSP is auxiliary DT hardware and is not required to register another remoteproc.
Compatible tokens identifying a cooling or thermal role are excluded even when
`#cooling-cells` is on a grandchild instead. Discovery logs the auxiliary
compatible and DT node. Other resource-free cooling providers identifying their
ancestor DSP family are also excluded. Nodes with an explicit PAS/PIL/remoteproc
compatible identity or
their own register, firmware memory or firmware-name property remain eligible,
including nested processors and processors exposing their own cooling controls.
Missing registration or binding of those processor owners still fails. Compatible
strings are classified individually so client fallbacks cannot invent a family.
Family selection includes all
instances, including numbered instances. `--subsystem dsp` also discovers other
DSP families described by compatible processor identities, without a SoC table.
An additional family can be selected directly as `--subsystem <family>dsp`.
Unrecognized DT bindings are not guessed, use a verified explicit runtime
identity when automatic classification cannot establish eligibility.

Absent optional subsystem hardware SKIPs. Enabled matching DT with a missing
registration or driver FAILs before any processor is changed. Externally owned
`attached`/`detached` processors SKIP Linux lifecycle exercise. In stop/start mode,
all other selected processors must pass the shared bounded boot-readiness check,
which waits passively and retains confirmed crash evidence even after recovery.
Crash mode uses the readiness and policy checks described below. Failed
readiness, unreadable/wrong states, ambiguous explicit names or unwritable
lifecycle controls FAIL. No processor is started merely to make readiness pass.

Before each round, the test passively requires an unchanged running inventory
for `--stable-seconds` within `--timeout`. First-observed channels and child
bindings remain required while later registrations are collected into the
verified stable baseline. New terminal faults during this wait abort before
mutation. After stop, the test requires offline state and no owned RPMsg
channels for the same interval before starting. Static descendant drivers can
remain bound while offline. No services are stopped and no reset/retry is used
to turn a functional failure into PASS.

The default stability interval is two seconds, use `--stable-seconds 0` to
disable this additional interval. Values must not exceed `--timeout`.
Inventory changes reset the interval within the existing deadline. This guards
observable registration and teardown races, it does not prove that firmware
commands are healthy or repair DSP memory-map/PCM initialization failures.

Each round validates offline/running transitions, removal and restoration of
RPMsg channel names/counts/drivers, descendant device bindings and registered device
endpoints, plus new captured kernel fault evidence. Descendants are discovered
under the resolved processor owner. Regenerated virtio transport numbers are
normalized while endpoint names, drivers and duplicate counts remain significant.
Optional unbound children are not invented as required endpoints.

After start, the test observes recovery for the full `--timeout` window even
when RPMsg channels return immediately. This covers asynchronous child probing
that can fail after the transport driver binds. Inventories that change during
probing are retried within the same deadline, their availability is logged.
The processor must remain running, RPMsg channels must match their baseline,
and all baseline child bindings/registered endpoints must return with a stable
inventory for the requested interval at the deadline.
Additional child registrations are allowed. Lost baseline bindings/registered
endpoints fail, an empty child baseline skips only that assertion.
Machine sound cards outside the processor owner and
audio signal correctness remain the audio suites' responsibility.

The final captured delta is also checked for terminal child probe, registration
and PCM-creation errors attributed to the selected owner or observed descendants.
These failures remain FAIL even when the endpoints later recover. Standalone
command-timeout diagnostics and normal deferred probes are retained separately,
their keywords alone do not establish a failed functional operation. Preexisting
boot history is preserved in the snapshots and excluded from the round delta.
Errors from explicitly identified sibling devices do not become child faults
for the selected processor. Existing crash/BUG checks remain strict.

Generic firmware lookup warnings alone do not fail a successfully completed
restart. Failed stop/start, channel loss and confirmed crashes still FAIL.
Kernel delta extraction verifies an exact retained baseline, including a
timestamped suffix retained after ring rotation. Each after-snapshot directory
contains `kernel_delta.log`, `kernel_delta_status.log` and `kernel_errors.log`.
Without a trustworthy baseline, kernel health SKIPs with diagnostic details.
Captured newer faults still FAIL even when continuity cannot be established.
Empty baseline RPMsg inventory skips only channel restoration coverage. Cleanup
restores running state only for processors changed by this test and verifies
the original channels, descendant bindings and registered endpoints.
Healthy unchanged cleanup returns immediately, it does not repeat the observation window or reset
processors. The ownership record is created before the first state-changing
operation, after both baselines exist. Per-round artifacts include
`*.children-before`, `*.children-after`, `*.recovery.log`, `*.child-errors.log`
and `*.child-diagnostics.log`, `*-baseline.recovery.log` and `*.quiescence.log`. Recovery transitions and fault evidence are also
printed to stdout.

`--timeout` bounds each lifecycle command, boot-readiness, baseline stabilization,
offline quiescence and combined child/channel recovery wait, it is not the entire suite budget. Allow approximately
`instances * timeout * (5 * rounds + 3)` seconds plus diagnostics and command
cleanup overhead for worst-case execution and restoration. For five instances
at YAML defaults this is approximately 20 minutes before overhead for stop/start. Crash mode omits the
stop, offline-quiescence and start stages, but includes injection and recovery. Budget first
run and rerun separately. Direct CLI defaults remain 60 seconds and three rounds.
For example, `./run.sh --exercise 1 --subsystem dsp --rounds 1 --timeout 30`
observes each selected DSP's recovery for 30 seconds before final kernel capture.
The per-subsystem YAMLs use the same procedure and timeout defaults.

### Explicit crash recovery

`--mode crash` writes the kernel-defined synthetic watchdog value `1` to the
selected instance's debugfs `crash` control. This calls `rproc_report_crash()`,
which queues the remoteproc crash handler and automatic recovery. It exercises
the recovery, firmware reload and child-device rebuilding paths. It does not
cause a firmware watchdog interrupt, validate crash-reason SMEM, reproduce a
firmware bug or validate dump contents. No processor index, SoC, firmware
filename or audio PCM is hardcoded.

The test discovers existing debugfs mounts and matches the selected sysfs
instance and its debugfs name. It does not mount debugfs. Recovery must already
be `enabled`, and coredump policy must be `disabled` or `enabled`. Missing
optional debugfs/crash support, disabled recovery or `inline` coredumps SKIP
that instance without changing policies. Inline coredumps wait for userspace
dump consumption and cannot provide bounded automatic recovery here. Present
but unreadable, conflicting or unwritable controls FAIL. Sysfs policy controls
are preferred, with debugfs policy controls used on older kernels.

Before injection the selected processor must be running with its original
firmware, verified owner and bound driver. Captured kernel evidence must be
readable and continuous. Each round requires exactly one selected watchdog
report, one handling message, one recovery message and one completed boot,
plus restored RPMsg names/counts/drivers and descendant bindings/endpoints
within `--timeout`. Fast recovery can complete between state polls, the captured
sequence still proves the crash was handled. Further crashes, sibling crashes,
real watchdog/fatal interrupt reports, host BUG/Oops/WARN and terminal
child-driver faults remain FAIL even if recovery later succeeds. A missing
sequence or lost kernel-log baseline cannot become PASS.

Crash readiness evaluates new faults against retained snapshots instead of
rejecting every historical boot crash. This lets a healthy rerun execute after
a previous deliberate injection while keeping its history in the artifacts.
Normal stop/start and legacy DSP boot-readiness checks retain their existing
crash-history policy. Each invocation records fresh inventories and evidence.

The functional recovery check never starts or resets a DSP to manufacture PASS.
Crash cleanup passively waits within `--timeout` for automatic running state and
original channels, child bindings and registered endpoints. It does not write
`recover`, `start` or `stop`. A `crashed` or `offline` state can follow a partially
completed kernel teardown, so another lifecycle write is not a safe restoration
step. If automatic restoration remains incomplete, the test fails and reports
that reset/recovery must be handled outside the test. Healthy cleanup returns
immediately. Original firmware, identity and policies are also verified.
Normal stop/start mode retains owned start/restoration when needed.
Incomplete cleanup, state lost at cleanup, or successful cleanup after a
functional failure remains FAIL. No recovery/coredump policy is changed by
this mode.

Selected-owner shutdown failures and remoteproc cannot-stop errors are retained
as unexpected recovery faults even if a later boot succeeds. Matching uses the
resolved runtime owner and instance, without a board or driver-name table.

Crash mode captures kernel evidence before and after every cleanup attempt,
including deferred restoration when an owned command cannot be stopped.
`cleanup-N-before` and `cleanup-N-after` directories retain separate snapshots,
deltas and kernel errors, with new fault evidence printed to stdout. New host
Oops, BUG, hard lockups and RCU stalls remain FAIL. Missing or discontinuous
required cleanup evidence also fails. Historical boot faults remain in snapshots
and are excluded from a verified new delta. Recovery policy controls need read
access, only the debugfs crash trigger requires write access.

Run only on an isolated DUT with no competing lifecycle manager or active
clients. The crash YAML opts into injection, existing restart YAMLs default to
stop/start and allow an optional `MODE` override. All five profiles expose
`STABLE_SECONDS`, leave it unset to use two seconds or provide an explicit value. Use `SUBSYSTEM` or `PROCESSORS`
to narrow crash coverage. Budget readiness, injection, observation and cleanup
separately using the existing per-operation deadline. Coredump collection can
increase recovery time and memory consumption.

Open Boot Stack's `remoteproc-restart` covers orderly restart. Its
`alsa-dsp-restart` additionally checks playback before/after idle and busy
injection, recreated sound-card controls and bounded interrupted-stream exit.
This suite validates generic DSP recovery and registered endpoints. It does not
claim those audio-stream or signal assertions, which require audio route and
workload validation.

Public implementation references:

- [Remoteproc debugfs trigger](https://github.com/qualcomm-linux/kernel/blob/17bbb4b37bbc4fc5827b4667445a0c43967c0f48/drivers/remoteproc/remoteproc_debugfs.c)
- [Remoteproc crash handler and recovery](https://github.com/qualcomm-linux/kernel/blob/17bbb4b37bbc4fc5827b4667445a0c43967c0f48/drivers/remoteproc/remoteproc_core.c)
- [Qualcomm watchdog/fatal interrupt handling](https://github.com/qualcomm-linux/kernel/blob/17bbb4b37bbc4fc5827b4667445a0c43967c0f48/drivers/remoteproc/qcom_q6v5.c)
- [Open Boot Stack audio-DSP restart](https://github.com/EmbeddedAndroid/test-definitions/blob/81c6b8ef967cf0ee412e860abeeca28e0696745a/automated/linux/alsa-dsp-restart/alsa-dsp-restart.sh)

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/Remoteproc_Restart_Validation/run-*`, each invocation starts fresh. The shared result file is `./Remoteproc_Restart_Validation.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.


Yocto parameters:

| Parameter | Default | CLI option |
| --- | --- | --- |
| `TIMEOUT` | `30` | `--timeout` |
| `EXERCISE` | `1` | `--exercise` |
| `SUBSYSTEM` | `dsp`, or the selected profile's `adsp`/`cdsp`/`gpdsp` | `--subsystem` |
| `ROUNDS` | `1` | `--rounds` |
| `PROCESSORS` | `null` | `--processors` |
| `MODE` | `null` for restart profiles, `crash` for crash recovery | `--mode` |
| `STABLE_SECONDS` | `null`, runner default `2` | `--stable-seconds` |

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
