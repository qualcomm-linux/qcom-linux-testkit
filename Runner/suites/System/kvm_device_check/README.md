# kvm_device_check

Checks whether the KVM device node is exposed on the DUT. The test runs locally on the DUT.

## What this test checks

The test verifies that:

- `/dev/kvm` exists.
- `/dev/kvm` is a character device.

## Scope

This test checks KVM device-node presence only. It does not change the
hypervisor mode, reboot the DUT, or start a virtual machine. A PASS therefore
confirms that `/dev/kvm` is exposed; it does not by itself prove that a guest
VM can be launched.

## Requirements

- The DUT must boot to a Linux shell.
- `/dev` must be mounted and expose device nodes.
- The testkit `Runner` directory, including `init_env` and shared utilities,
  must be kept together.
- The test directory must be writable so the result file and logs can be saved.

## Result semantics

- **PASS** when `/dev/kvm` exists and is a character device.
- **SKIP** when `/dev/kvm` is missing and KVM is optional (`REQUIRE_KVM=false`).
- **FAIL** when `/dev/kvm` is missing and KVM is required (`REQUIRE_KVM=true`),
  or when the path exists but is not a character device.

The LAVA parameter `REQUIRE_KVM` defaults to `false`. Set it to `true` on DUTs
where KVM must be available.

## Output

The test writes its result to:

```text
kvm_device_check.res
```

Expected result format:

```text
kvm_device_check PASS
kvm_device_check FAIL
```
