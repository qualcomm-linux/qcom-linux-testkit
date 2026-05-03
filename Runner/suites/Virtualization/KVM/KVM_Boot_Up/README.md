# KVM_Boot_Up

## Overview

`KVM_Boot_Up` validates that the running target has the baseline KVM host
support expected for virtualization testing.

This test is intentionally lightweight. It validates kernel configuration,
`/dev/kvm`, and KVM/EL2 related boot logs. It does not launch a VM.

## Test location

```text
Runner/suites/Virtualization/KVM/KVM_Boot_Up/
```

## Files

```text
run.sh
KVM_Boot_Up.yaml
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

1. Kernel config support:
   - `CONFIG_VIRTUALIZATION`
   - `CONFIG_KVM`

2. Optional KVM-related configs are logged when visible:
   - `CONFIG_HAVE_KVM`
   - `CONFIG_HAVE_KVM_IRQCHIP`
   - `CONFIG_HAVE_KVM_IRQFD`
   - `CONFIG_KVM_ARM_PMU`
   - `CONFIG_KVM_GENERIC_DIRTYLOG_READ_PROTECT`

3. Runtime device node:
   - `/dev/kvm` exists
   - `/dev/kvm` is a character device
   - `/dev/kvm` is readable and writable

4. Kernel log scan:
   - checks for fatal KVM/EL2/HYP/GIC related boot/runtime errors

## Result policy

### PASS

The test reports `PASS` when:

- mandatory KVM configs are enabled,
- `/dev/kvm` is present and accessible,
- no fatal KVM/EL2 errors are detected in kernel logs.

### SKIP

The test reports `SKIP` when:

- `CONFIG_VIRTUALIZATION` is not enabled,
- `CONFIG_KVM` is not enabled,
- `/dev/kvm` is not present,
- required userspace utilities are missing.

This allows the same suite to run on images where KVM is not enabled by design.

### FAIL

The test reports `FAIL` when:

- `/dev/kvm` exists but is not usable,
- fatal KVM/EL2/HYP related errors are detected in kernel logs.

## Manual execution

From the repository root on target:

```sh
cd Runner/suites/Virtualization/KVM/KVM_Boot_Up
./run.sh
cat KVM_Boot_Up.res
```

Expected result file:

```text
KVM_Boot_Up PASS
```

or:

```text
KVM_Boot_Up SKIP
```

or:

```text
KVM_Boot_Up FAIL
```

## LAVA execution

The YAML file runs:

```sh
cd Runner/suites/Virtualization/KVM/KVM_Boot_Up
./run.sh || true
$REPO_PATH/Runner/utils/send-to-lava.sh KVM_Boot_Up.res
```

## Logs

The test creates logs under:

```text
results/KVM_Boot_Up/
```

KVM/EL2 dmesg logs are captured under:

```text
results/KVM_Boot_Up/dmesg/
```

## Notes

This test only validates KVM boot/runtime baseline. Deeper validation is covered
by separate tests:

```text
KVM_Driver
KVM_EL2_DTB
KVM_Infra
QEMU_VM_Validation
```
