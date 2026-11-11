# Remoteproc_Restart_Validation

Repeated remoteproc stop/start, RPMsg disappearance and complete driver/channel restoration.

This is a separate suite. Existing runners, plans and shared helper interfaces retain their current behavior. It uses runtime capability discovery on Yocto, Debian, Ubuntu and CentOS, including shell-only images. Required utilities and optional payloads must be supplied by the image or job. It does not install packages, change boot selection or start services.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--exercise` | `0` |
| `--processors` | `auto` |
| `--subsystem` | unset |
| `--rounds` | `3` |

Direct runs use CLI options, Yocto profiles expose each option as a named parameter.
Direct invocation remains passive unless `--exercise 1` and a subsystem or
explicit processor selection are provided.

The Yocto YAML variants explicitly enable restart, with `TIMEOUT=30` seconds
and `ROUNDS=1`. Each profile exposes named parameters. Optional `PROCESSORS` defaults to `null`, preserving runtime DSP discovery. Choose the default-all YAML or the subsystem
YAMLs in a plan, using both repeats coverage of the same instances.

| YAML | Runtime selection |
|---|---|
| `Remoteproc_Restart_Validation.yaml` | All positively identified DSP families |
| `Remoteproc_Restart_ADSP.yaml` | All ADSP instances |
| `Remoteproc_Restart_CDSP.yaml` | All CDSP instances |
| `Remoteproc_Restart_GPDSP.yaml` | All GPDSP instances |

All variants use this runner and publish `Remoteproc_Restart_Validation.res`
under their separate LAVA definition names. Existing plans are unchanged.

Run from this suite directory:

```sh
./run.sh
./run.sh --exercise 1 --subsystem dsp --rounds 1 --timeout 30
./run.sh --exercise 1 --subsystem adsp
./run.sh --exercise 1 --subsystem cdsp
./run.sh --exercise 1 --subsystem gpdsp --rounds 2 --timeout 30
./run.sh --exercise 1 --processors adsp,cdsp --rounds 3 --timeout 60
./run.sh --exercise 1 --subsystem dsp --processors adsp --rounds 1
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
`attached`/`detached` processors SKIP Linux lifecycle exercise. All other selected
processors must pass the shared bounded boot-readiness check, which waits
passively and retains confirmed crash evidence even after recovery. Failed
readiness, unreadable/wrong states, ambiguous explicit names or unwritable
lifecycle controls FAIL. No processor is started merely to make readiness pass.

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
and all baseline child bindings/registered endpoints must return at the deadline.
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
and `*.child-diagnostics.log`. Recovery transitions and fault evidence are also
printed to stdout.

`--timeout` bounds each lifecycle command, boot-readiness and combined child/channel
recovery wait, it is not the entire suite budget. Allow approximately
`instances * timeout * (3 * rounds + 3)` seconds plus diagnostics and command
cleanup overhead for worst-case execution and restoration. For five instances
at YAML defaults this is approximately 15 minutes before overhead. Budget first
run and rerun separately. Direct CLI defaults remain 60 seconds and three rounds.
For example, `./run.sh --exercise 1 --subsystem dsp --rounds 1 --timeout 30`
observes each selected DSP's recovery for 30 seconds before final kernel capture.
The per-subsystem YAMLs use the same procedure and timeout defaults.

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

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
