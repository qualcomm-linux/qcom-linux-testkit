# KVM_Driver

## Overview

`KVM_Driver` validates the mandatory KVM host configuration, `/dev/kvm`
runtime device node, and KVM userspace ioctl API.

This test now covers the baseline KVM boot/config validation that was previously
covered separately by `KVM_Boot_Up`, and then performs a stronger functional
driver check by opening `/dev/kvm`, validating the KVM API version, and
attempting a safe `KVM_CREATE_VM` ioctl through the shared `lib_kvm.sh` helper.

This test does not launch QEMU and does not boot a guest VM.

## Test location

```text
Runner/suites/Virtualization/KVM/KVM_Driver/
```

## Files

```text
run.sh
KVM_Driver.yaml
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
cat grep awk sed tr mkdir uname
```

Additional helper dependency:

```text
python3
```

`python3` is used by `kvm_check_api_version()` to issue the `/dev/kvm` ioctl
checks without requiring a prebuilt C helper binary. If `python3` is not
present, the test reports `SKIP`.

## Validation coverage

The test validates:

1. Mandatory kernel config support:
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

4. KVM API ioctl path:
   - `open("/dev/kvm")`
   - `KVM_GET_API_VERSION`
   - API version must be `12`
   - `KVM_CREATE_VM`

5. Kernel log scan:
   - checks for fatal KVM/EL2/HYP/GIC related runtime errors

## Result policy

### PASS

The test reports `PASS` when:

- mandatory KVM configs are enabled,
- `/dev/kvm` is present and accessible,
- KVM ioctl API validation passes,
- no fatal KVM/EL2 errors are detected in kernel logs.

### SKIP

The test reports `SKIP` when:

- `python3` is not available for the ioctl helper,
- required userspace utilities are missing,
- the testcase path or setup environment cannot be resolved before test
  execution starts.

### FAIL

The test reports `FAIL` when:

- `CONFIG_VIRTUALIZATION` is not enabled,
- `CONFIG_KVM` is not enabled,
- `/dev/kvm` is not present,
- `/dev/kvm` exists but is not usable,
- KVM ioctl API validation fails,
- fatal KVM/EL2/HYP related errors are detected in kernel logs.

## Manual execution

From the repository root on target:

```sh
cd Runner/suites/Virtualization/KVM/KVM_Driver
./run.sh
cat KVM_Driver.res
```

Expected result file:

```text
KVM_Driver PASS
```

or:

```text
KVM_Driver SKIP
```

or:

```text
KVM_Driver FAIL
```

## LAVA execution

The YAML file runs:

```sh
cd Runner/suites/Virtualization/KVM/KVM_Driver
./run.sh || true
$REPO_PATH/Runner/utils/send-to-lava.sh KVM_Driver.res
```

## Logs

The test creates logs under:

```text
results/KVM_Driver/
```

KVM/EL2 dmesg logs are captured under:

```text
results/KVM_Driver/dmesg/
```

## Notes

`KVM_Driver` intentionally includes the baseline KVM boot/config checks so a
separate `KVM_Boot_Up` test is not required.

This test does not launch QEMU or boot a guest VM. That coverage belongs to:

```text
KVM_Infra
QEMU_VM_Validation
```

This test also does not validate EL2-DTB remoteproc/IOMMU evidence. That is
covered by:

```text
KVM_EL2_DTB
```
