# KVM_Infra

## Overview

`KVM_Infra` validates the host-side userspace infrastructure required to run
virtual machines with KVM acceleration.

This test does not boot a guest VM. It verifies that KVM is available, a QEMU
system emulator exists, QEMU advertises KVM acceleration, and optional VM host
networking acceleration paths are visible when present.

## Test location

```text
Runner/suites/Virtualization/KVM/KVM_Infra/
```

## Files

```text
run.sh
KVM_Infra.yaml
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
cat grep awk sed find tr head mkdir uname
```

Optional runtime tools:

```text
qemu-system-aarch64
qemu-system-arm
qemu-kvm
qemu-img
```

The test searches for a usable QEMU system emulator in this order:

```text
qemu-system-aarch64
qemu-system-arm
qemu-kvm
```

## Validation coverage

The test validates:

1. KVM availability gate:
   - `CONFIG_KVM`
   - `/dev/kvm` exists and is usable

2. QEMU binary availability:
   - finds a QEMU system emulator suitable for the target
   - logs QEMU version
   - logs machine help output
   - logs CPU help output

3. QEMU KVM acceleration:
   - runs `qemu-system-* -accel help`
   - checks whether `kvm` acceleration is advertised

4. Optional host infrastructure:
   - `/dev/net/tun`
   - `/dev/vhost-net`
   - loaded `vhost_net` module

5. Kernel log scan:
   - checks for fatal KVM/EL2/HYP/GIC related runtime errors

## Result policy

### PASS

The test reports `PASS` when:

- `CONFIG_KVM` is enabled,
- `/dev/kvm` is available and usable,
- QEMU system binary is found,
- QEMU advertises KVM acceleration,
- no fatal KVM/EL2 errors are detected in kernel logs.

### SKIP

The test reports `SKIP` when:

- `CONFIG_KVM` is not enabled,
- `/dev/kvm` is not present,
- no QEMU system emulator is installed,
- required userspace utilities are missing.

This keeps the test CI-safe for minimal images that intentionally do not ship
QEMU.

### FAIL

The test reports `FAIL` when:

- `/dev/kvm` exists but is not usable,
- QEMU is installed but does not advertise KVM acceleration,
- fatal KVM/EL2/HYP related errors are detected in kernel logs.

## Optional infrastructure behavior

Missing `/dev/net/tun` or `vhost-net` is logged as a warning only. These are
not hard requirements for confirming QEMU/KVM host infrastructure, because a
guest may still boot with limited or alternate networking.

## Manual execution

From the repository root on target:

```sh
cd Runner/suites/Virtualization/KVM/KVM_Infra
./run.sh
cat KVM_Infra.res
```

Expected result file:

```text
KVM_Infra PASS
```

or:

```text
KVM_Infra SKIP
```

or:

```text
KVM_Infra FAIL
```

## LAVA execution

The YAML file runs:

```sh
cd Runner/suites/Virtualization/KVM/KVM_Infra
./run.sh || true
$REPO_PATH/Runner/utils/send-to-lava.sh KVM_Infra.res
```

## Logs

The test creates logs under:

```text
results/KVM_Infra/
```

KVM/EL2 dmesg logs are captured under:

```text
results/KVM_Infra/dmesg/
```

## Notes

This test only validates QEMU/KVM host infrastructure. Actual guest boot is
covered by the later `QEMU_VM_Validation` test.

Related tests:

```text
KVM_Boot_Up
KVM_Driver
KVM_EL2_DTB
QEMU_VM_Validation
```
