# Kvm-Reboot Test

## Overview

This test validates the soft-reboot functionality for KVM virtual machines managed via `virsh`. It ensures that an actively running virtual machine can gracefully restart its guest operating system and safely transition back into a stable `running` state on the host hypervisor without hanging or requiring a hard reset.

## Test Goals

- Verify the ability to successfully execute the `virsh reboot` command on an active VM instance.
- Confirm that the VM gracefully restarts and returns to the `running` state as reported by the hypervisor.
- Validate that residual log files (`*_stdout_*.log`) from previous runs are safely cleaned up.
- Ensure the virtualization layer successfully handles the reboot lifecycle without leaving the guest in a suspended or crashed state.

## Prerequisites

- Host kernel built with KVM virtualization support.
- `virsh` utility installed and configured on the host.
- Appropriate privileges (root or `libvirt` group) to manage VMs via `virsh`.
- Test framework dependencies (specifically `utils/kvm_common.sh`) must be accessible in the parent directory tree.

## Script Location
```
Runner/suites/Kernel/VIRTUALIZATION/Kvm-Reboot/run.sh
```
## Files

- `run.sh` - Main test script
- `Kvm-Reboot.res` - Summary result file with PASS/FAIL
- `Kvm-Reboot.log` - Full execution log (generated if logging is enabled)

## How It Works

1. **Discovery & Setup**: Climbs the directory tree using a standardized POSIX `while` loop to locate and source `utils/kvm_common.sh` for shared KVM testing utilities. Resolves the test directory using `find_test_case_by_name`.
2. **Pre-Check & Cleanup**: Clears any existing `.res` file and old standard output logs (`*_stdout_*.log`). Checks `virsh list --all` for pre-existing instances of `$VM_NAME` and cleans them up.
3. **Initialization**: Creates and boots a new VM instance using the `vm_define` and `vm_start` helper functions.
4. **Reboot**: Issues the `virsh reboot` command against the VM. Implements a 5-second delay (`sleep 5`) to allow the guest OS and hypervisor sufficient time to initiate and complete the reboot sequence.
5. **Verify**: Calls `check_vm_state` to interrogate the hypervisor, confirming the VM successfully transitioned back to the `running` state.
6. **Teardown**: Executes `vm_clean` at the end of the test to safely destroy and undefine the test VM instance.

## Usage

Run the script directly via the framework:

```bash
./run.sh
```

## Example Output

[INFO] 2026-06-15 10:26:37 - -----------------------------------------------------------------------------------------
[INFO] 2026-06-15 10:26:37 - -------------------Starting Kvm-Reboot Testcase----------------------------
[INFO] 2026-06-15 10:26:37 - Existing VM instance found. Cleaning up...
[INFO] 2026-06-15 10:26:37 - Cleaning up existing VM state for: hk-vm
[INFO] 2026-06-15 10:26:40 - Defining VM from XML: /var/gunyah/vm.xml
Domain 'hk-vm' defined from /var/gunyah/vm.xml

[INFO] 2026-06-15 10:26:40 - Starting VM: hk-vm
Domain 'hk-vm' started

[INFO] 2026-06-15 10:26:45 - Rebooting hk-vm
Domain 'hk-vm' is being rebooted

[INFO] 2026-06-15 10:26:50 - Verifying VM state for 'hk-vm'... Expecting: running
[INFO] 2026-06-15 10:26:50 - SUCCESS: VM is in 'running' state.
[PASS] 2026-06-15 10:26:50 - VM rebooted successfully.
[INFO] 2026-06-15 10:26:50 - Cleaning up existing VM state for: hk-vm

## Return Code

- `0` — The VM was successfully started, rebooted, returned to the running state, and cleaned up.
- `1` — A failure occurred (e.g., framework dependencies missing, vm_start failed, virsh reboot was rejected, or the VM failed to return to running).

## Integration in CI

- Can be run standalone or via LAVA.
- Result file Kvm-Reboot.res will be parsed by result_parse.sh.

## Notes

- Portability: This script avoids bashisms and utilizes a standardized POSIX while loop for script location, ensuring broad compatibility across minimalistic environments like ash or BusyBox.

- Timing Constraint: A 5-second sleep (sleep 5) is injected following the reboot command to account for hypervisor and guest ACPI state transitions before verification occurs.

## License

SPDX-License-Identifier: BSD-3-Clause
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.