# KVM_EL2_DTB

## Overview

`KVM_EL2_DTB` validates that the running target exposes dynamic EL2-DTB
runtime evidence required for KVM and remoteproc/IOMMU coexistence.

This test is designed for Qualcomm ARM64 embedded targets where EL2 boot may
use an EL2-specific DTB or overlay. It intentionally avoids maintaining a
per-board allowlist and instead validates the live DT/sysfs evidence.

The test is non-destructive. It does not stop, start, reset, or otherwise
control any remoteproc instance.

## Test location

```text
Runner/suites/Virtualization/KVM/KVM_EL2_DTB/
```

## Files

```text
run.sh
KVM_EL2_DTB.yaml
README.md
```

## Dependencies

The test uses common helpers from:

```text
Runner/utils/functestlib.sh
Runner/utils/lib_kvm.sh
```

Required target utilities:

```text
cat grep awk sed find tr mkdir uname
```

## Validation coverage

The test validates:

1. KVM availability gate:
   - `CONFIG_KVM`
   - `/dev/kvm` exists and is usable

2. Live device-tree identity logging:
   - `/proc/device-tree`
   - `/sys/firmware/devicetree/base`
   - `model`
   - `compatible`

3. Dynamic remoteproc inspection:
   - logs `/sys/class/remoteproc/remoteproc*/name`
   - logs `/sys/class/remoteproc/remoteproc*/firmware`
   - logs `/sys/class/remoteproc/remoteproc*/state`
   - uses existing `functestlib.sh` remoteproc helpers when available

4. EL2-DTB evidence:
   - remoteproc/rproc DT nodes
   - remoteproc/rproc `iommus` properties
   - runtime sysfs IOMMU/devlink/platform evidence for remoteproc devices

5. Kernel log scan:
   - checks for fatal KVM/EL2/HYP/GIC related runtime errors

## What counts as EL2 runtime evidence

The shared `lib_kvm.sh` helper checks for evidence such as:

```text
/proc/device-tree/...remoteproc.../iommus
/sys/firmware/devicetree/base/...remoteproc.../iommus
/sys/kernel/iommu_groups/*/devices/*remoteproc*
/sys/kernel/iommu_groups/*/devices/*adsp*
/sys/kernel/iommu_groups/*/devices/*cdsp*
/sys/class/devlink/*remoteproc*
/sys/class/devlink/*adsp*
/sys/class/devlink/*cdsp*
/sys/bus/platform/devices/*remoteproc*
```

The goal is to detect whether the live boot has the EL2-style remoteproc/IOMMU
layout without hardcoding each board or DTB name.

## Result policy

### PASS

The test reports `PASS` when:

- KVM is enabled,
- `/dev/kvm` is available and usable,
- remoteproc/IOMMU EL2 runtime evidence is found,
- no fatal KVM/EL2/HYP related dmesg errors are detected.

### SKIP

The test reports `SKIP` when:

- `CONFIG_KVM` is not enabled,
- `/dev/kvm` is not present,
- no remoteproc DT/sysfs entries exist, so EL2 remoteproc validation is not
  applicable on this target,
- required userspace utilities are missing.

### FAIL

The test reports `FAIL` when:

- `/dev/kvm` exists but is not usable,
- remoteproc entries exist but no EL2-style DT/sysfs evidence is found,
- fatal KVM/EL2/HYP related errors are detected in kernel logs.

## Manual execution

From the repository root on target:

```sh
cd Runner/suites/Virtualization/KVM/KVM_EL2_DTB
./run.sh
cat KVM_EL2_DTB.res
```

Expected result file:

```text
KVM_EL2_DTB PASS
```

or:

```text
KVM_EL2_DTB SKIP
```

or:

```text
KVM_EL2_DTB FAIL
```

## LAVA execution

The YAML file runs:

```sh
cd Runner/suites/Virtualization/KVM/KVM_EL2_DTB
./run.sh || true
$REPO_PATH/Runner/utils/send-to-lava.sh KVM_EL2_DTB.res
```

## Logs

The test creates logs under:

```text
results/KVM_EL2_DTB/
```

KVM/EL2 dmesg logs are captured under:

```text
results/KVM_EL2_DTB/dmesg/
```

## Notes

This test does not duplicate secure PIL or remoteproc lifecycle validation.
Dedicated remoteproc tests should continue to cover stop/start/reset flows.

`KVM_EL2_DTB` only validates that the live EL2-compatible DT/runtime layout is
present when KVM is available.
