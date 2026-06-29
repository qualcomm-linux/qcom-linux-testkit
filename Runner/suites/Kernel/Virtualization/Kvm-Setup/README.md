# Kvm-Setup Test

## Overview

This test validates the initial provisioning, configuration, and booting lifecycle of KVM virtual machines managed via `virsh`. It ensures that a virtual machine can be successfully defined from its configuration, booted, and tracked until it transitions into a fully active `running` state on the host hypervisor.

## Test Goals

- Verify the ability to successfully parse and define a new VM instance using `vm_define`.
- Confirm that the defined VM can be successfully booted using `vm_start`.
- Ensure the VM officially reaches the `running` state as reported by the hypervisor.
- Validate that any pre-existing, leftover VM instances with the same name are properly cleaned up prior to attempting setup.

## Prerequisites

- Host kernel built with KVM virtualization support.
- `virsh` utility installed and configured on the host.
- Appropriate privileges (root or `libvirt` group) to manage VMs via `virsh`.
- Test framework dependencies (`init_env` and `functestlib.sh`) must be present in the directory hierarchy.

## Script Location
```
Runner/suites/Kernel/VIRTUALIZATION/Kvm-Setup/run.sh
```
## Files

- `run.sh` - Main test script
- `Kvm-Setup.res` - Summary result file with PASS/FAIL
- `Kvm-Setup.log` - Full execution log (generated if logging is enabled)

## How It Works

1. **Discovery & Setup**: Climbs the directory tree to locate and source `init_env` (using the `__INIT_ENV_LOADED` guard to prevent redundant sourcing) and `$TOOLS/functestlib.sh`. Resolves the test directory using `find_test_case_by_name`.
2. **Pre-Check**: Evaluates `virsh list --all` to check for any existing instance of `$VM_NAME`. If an old instance is found, it calls `vm_clean` to destroy and undefine it, ensuring a clean testing slate.
3. **Define**: Calls `vm_define` to register the new VM's XML configuration with the hypervisor.
4. **Start**: Calls `vm_start` to boot the VM.
5. **Verify**: Calls `check_vm_state` to interrogate the hypervisor. If the state equals `running`, the test passes. Otherwise, it fails.

## Usage

Run the script directly via the framework:

```bash
./run.sh
```

## Example Output

[INFO] 2026-06-15 10:19:54 - -----------------------------------------------------------------------------------------
[INFO] 2026-06-15 10:19:54 - -------------------Starting Kvm-Setup Testcase----------------------------
[INFO] 2026-06-15 10:19:54 - Defining VM from XML: /var/gunyah/vm.xml
Domain 'hk-vm' defined from /var/gunyah/vm.xml

[INFO] 2026-06-15 10:19:54 - Starting VM: hk-vm
Domain 'hk-vm' started

[INFO] 2026-06-15 10:19:59 - Verifying VM state for 'hk-vm'... Expecting: running
[INFO] 2026-06-15 10:19:59 - SUCCESS: VM is in 'running' state.
[PASS] 2026-06-15 10:19:59 - VM is running.

## Return Code

- `0` — The VM was successfully defined, started, and reached the running state.
- `1` — A failure occurred (e.g., framework not found, vm_define failed, vm_start failed, or the VM failed to report a running state).

## Integration in CI

- Can be run standalone or via LAVA.
- Result file Kvm-Setup.res will be parsed by result_parse.sh.

## Notes

- This script avoids bashisms and utilizes a standardized while-loop search pattern to ensure extreme portability across minimal environments like ash or BusyBox.
- The grep -w flag is used during the pre-check to ensure exact matches for the $VM_NAME variable, avoiding false positives with similarly named VMs (e.g., matching test-vm but skipping test-vm-2).
- A failure during vm_define or vm_start immediately drops a FAIL result and halts execution before reaching state verification.

## License

SPDX-License-Identifier: BSD-3-Clause
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.