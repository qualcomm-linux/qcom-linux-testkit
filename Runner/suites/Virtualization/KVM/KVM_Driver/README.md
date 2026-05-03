# KVM_Driver

## Overview

`KVM_Driver` validates that the KVM userspace device node is not only present,
but also usable through the KVM ioctl API.

This test is stronger than a simple `/dev/kvm` existence check. It opens
`/dev/kvm`, validates the KVM API version, and attempts a safe `KVM_CREATE_VM`
ioctl through the shared `lib_kvm.sh` helper.

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
checks without requiring a prebuilt C helper binary. If `python3` is not present,
the test reports `SKIP`.

## Validation coverage

The test validates:

1. Kernel KVM config gate:
   - `CONFIG_KVM`

2. Runtime device node:
   - `/dev/kvm` exists
   - `/dev/kvm` is a character device
   - `/dev/kvm` is readable and writable

3. KVM API ioctl path:
   - `open("/dev/kvm")`
   - `KVM_GET_API_VERSION`
   - API version must be `12`
   - `KVM_CREATE_VM`

4. Kernel log scan:
   - checks for fatal KVM/EL2/HYP/GIC related runtime errors

## Result policy

### PASS

The test reports `PASS` when:

- `CONFIG_KVM` is enabled,
- `/dev/kvm` is present and accessible,
- KVM ioctl API validation passes,
- no fatal KVM/EL2 errors are detected in kernel logs.

### SKIP

The test reports `SKIP` when:

- `CONFIG_KVM` is not enabled,
- `/dev/kvm` is not present,
- `python3` is not available for the ioctl helper,
- required userspace utilities are missing.

This allows the same suite to run on images where KVM or python3 is not included
by design.

### FAIL

The test reports `FAIL` when:

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
