# Kvm-Suspend Test

## Overview

This test validates the suspend (pause) functionality for KVM virtual machines managed via `virsh`. It ensures that a running virtual machine can be successfully paused, temporarily halting its CPU execution and transitioning its status to a `paused` state on the host hypervisor.

## Test Goals

- Verify the ability to successfully execute the suspend command on an actively running VM instance.
- Confirm that the VM transitions precisely to the `paused` state as reported by the hypervisor.
- Ensure the virtualization layer handles the state transition without hanging the host or crashing the test script.
- Validate that the VM framework properly cleans up suspended instances post-verification.

## Prerequisites

- Host kernel built with KVM virtualization support.
- `virsh` utility installed and configured on the host.
- Appropriate privileges (root or `libvirt` group) to manage VMs via `virsh`.
- Test framework dependencies (`init_env` and `functestlib.sh`) must be accessible in the parent directory tree.

## Script Location
```
Runner/suites/Kernel/VIRTUALIZATION/Kvm-Suspend/run.sh
```
## Files

- `run.sh` - Main test script
- `Kvm-Suspend.res` - Summary result file with PASS/FAIL
- `Kvm-Suspend.log` - Full execution log (generated if logging is enabled)

## How It Works

1. **Discovery & Setup**: Climbs the directory tree to locate and source `init_env` (using the `__INIT_ENV_LOADED` guard to prevent redundant sourcing) and `$TOOLS/functestlib.sh`. Dynamically resolves the test directory using `find_test_case_by_name`.
2. **Pre-Check**: Evaluates `virsh list --all` for an existing instance of the target VM. If found, executes `vm_clean` to guarantee a pristine testing environment.
3. **Initialization**: Creates and boots a new VM instance using the `vm_define` and `vm_start` helper functions.
4. **Suspend**: Issues the `virsh suspend` command against the running VM to halt guest execution.
5. **Verify**: Calls `check_vm_state` to interrogate the hypervisor, confirming the VM successfully entered the `paused` state.
6. **Teardown**: Executes `vm_clean` at the end of the test to safely destroy and undefine the paused VM instance.

## Usage

Run the script directly via the framework:

```bash
./run.sh
```

## Example Output

[INFO] 2026-06-15 10:28:23 - -----------------------------------------------------------------------------------------
[INFO] 2026-06-15 10:28:23 - -------------------Starting Kvm-Suspend Testcase----------------------------
[INFO] 2026-06-15 10:28:23 - Defining VM from XML: /var/gunyah/vm.xml
Domain 'hk-vm' defined from /var/gunyah/vm.xml

[INFO] 2026-06-15 10:28:23 - Starting VM: hk-vm
Domain 'hk-vm' started

[INFO] 2026-06-15 10:28:29 - Suspending VM: hk-vm
Domain 'hk-vm' suspended

[INFO] 2026-06-15 10:28:29 - Verifying VM state for 'hk-vm'... Expecting: paused
[INFO] 2026-06-15 10:28:29 - SUCCESS: VM is in 'paused' state.
[PASS] 2026-06-15 10:28:29 - VM successfully paused.
[INFO] 2026-06-15 10:28:29 - Cleaning up existing VM state for: hk-vm

## Return Code

- `0` — The VM was successfully started, suspended, transitioned to the paused state, and cleaned up.
- `1` — A failure occurred (e.g., environment setup failed, VM failed to start, the suspend command was rejected, or the VM did not enter the expected paused state).

## Integration in CI

- Can be run standalone or via LAVA.
- Result file Kvm-Suspend.res will be parsed by result_parse.sh.

## Notes

- This script avoids bashisms and utilizes a standardized while-loop search pattern to ensure extreme portability across minimal environments like ash or BusyBox.

- The virsh suspend action does not save the RAM to disk (unlike hibernation or virsh save); it simply pauses CPU scheduling for the guest domains.

## License

SPDX-License-Identifier: BSD-3-Clause
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.