# Kernel and ramdisk premerge plan

`qcom-next-ci-premerge.yaml` runs against the booted kernel, DT, firmware and
existing image tools. It does not require a multimedia rootfs or systemd.
`TESTKIT_IMAGE_ONLY=1` prevents package-provider installation and dependency
recovery. Individual functional tests still SKIP when their clients are absent.

Each suite runs from its own directory, removes its previous result before
launch and publishes with `send-to-lava.sh --strict`. Missing, empty or malformed
results produce a `<suite>_result_publication` failure. The LAVA definition must
start at the repository root. Job boot/retry policy remains in LAVA.

Coverage notes:

- Boot health reports the real kernel, PID 1 and root mount, then validates root
  shell access. It does not initiate a reboot.
- UFS validates runtime-bound storage. File writes are skipped unless CWD is
  proven to reside on UFS. Read-only validation remains available on ramdisk.
- Hardware RNG collection and statistics are bounded and restore selection.
- Wi-Fi uses runtime bindings and the running kernel's device aliases, then
  checks firmware provisioning and a matching PHY. Unrelated firmware packages
  or generic kernel messages cannot establish Wi-Fi readiness.
- Bluetooth reuses healthy BlueZ. Without systemd it can start image-provided
  D-Bus/BlueZ once and stops only its own processes. Startup logs remain in CWD.
- USB separates host readiness from external-peripheral coverage. Optional
  lsusb inventory is bounded. A fixture is needed to exercise an attached device.
- KVM captures configuration, DT, device and EL2/HYP diagnostics before early
  exits. Python ioctl and QEMU checks remain distinct, missing clients SKIP
  rather than turning readiness evidence into functional PASS.
- Audio card registration retains ALSA registration checks without requiring
  playback/record clients or a PipeWire user session in this plan.
- DSP_AudioPD needs adsprpcd and OpenCV needs its test binaries. Their absence
  remains SKIP, the existing remoteproc tests provide separate driver coverage.

These changes cannot fix firmware/probe failures, kernel crashes, or absent
external fixtures. SMMU validates registered enabled DT DMA masters and actual group membership.
GitHub workflow verdict propagation is handled by the separate kernel-config change.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

The plan now has 40 invocations, adding KVM_Runtime_Validation and
FastRPC_Runtime_Validation as distinct readiness results. Optional functional
clients retain their original SKIP behavior. A failed suite-directory change
stops execution, preventing a previous test from running under another name.
USB kernel-health errors are strict in this kernel-validation plan, while the
USBHost direct-run default remains unchanged.

SMMU checks registered DT DMA masters and reverse group membership across
runtime buses. RNG statistics check complete reads and preserve a failed
hardware source as FAIL. CPUFreq, GIC, Interrupts and PCI reuse the runtime
helpers from PR640. Kernel aborts, firmware/probe errors and missing expected
KVM state remain failures requiring kernel/image investigation.

For repeatable lab validation, provision a USB peripheral, a discoverable BT
peer, and a Wi-Fi AP/Ethernet link partner as appropriate. BT_SCAN with no
explicit target SKIPs missing-peer coverage only after positive discovery
startup evidence. Explicit missing targets and scan-start failures remain FAIL.
WiFi_OnOff does not require an AP, it validates administrative transitions.
Ethernet connectivity requires a peer, carrier and suitable addressing, and
does not claim traffic coverage from driver readiness alone.

Invoke from the repository root through LAVA using this plan. For direct
validation, run each suite from its directory, for example:

```sh
REPO_PATH=$(pwd)
cd "$REPO_PATH/Runner/suites/Kernel/Baseport/smmu"
./run.sh
cd "$REPO_PATH/Runner/suites/Virtualization/KVM/KVM_Runtime_Validation"
./run.sh
```

Every plan publication declares --expected-testcase-id. Wrong result identities
fail publication, and CI can detect an unstarted expected testcase without
guessing a name from a result filename. Legacy sender callers remain unchanged.
