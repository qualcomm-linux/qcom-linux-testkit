# Kvm-Resume Test

## Overview

This test validates the resume (unpause) functionality for KVM virtual machines managed via `virsh`. It ensures that a suspended (`paused`) virtual machine can be successfully awakened, resuming its CPU execution and safely transitioning its status back to a `running` state on the host hypervisor.

## Test Goals

- Verify the ability to successfully transition an active VM into a suspended state.
- Validate the `virsh resume` command against the paused VM instance.
- Confirm that the VM transitions precisely back to the `running` state as reported by the hypervisor.
- Ensure the virtualization layer handles rapid state transitions (active -> paused -> active) without hanging the host system.

## Prerequisites

- Host kernel built with KVM virtualization support.
- `virsh` utility installed and configured on the host.
- Appropriate privileges (root or `libvirt` group) to manage VMs via `virsh`.
- Test framework dependencies (`init_env` and `functestlib.sh`) must be accessible in the parent directory tree.

## Script Location
```
Runner/suites/Kernel/VIRTUALIZATION/Kvm-Resume/run.sh
```
## Files

- `run.sh` - Main test script
- `Kvm-Resume.res` - Summary result file with PASS/FAIL
- `Kvm-Resume.log` - Full execution log (generated if logging is enabled)

## How It Works

1. **Discovery & Setup**: Climbs the directory tree to locate and source `init_env` (using the `__INIT_ENV_LOADED` guard to prevent redundant sourcing) and `$TOOLS/functestlib.sh`. Dynamically resolves the test directory using `find_test_case_by_name`.
2. **Pre-Check**: Evaluates `virsh list --all` for an existing instance of `$VM_NAME`. If found, executes `vm_clean` to guarantee a pristine testing environment.
3. **Initialization**: Creates and boots a new VM instance using the `vm_define` and `vm_start` helper functions.
4. **Suspend**: Issues `virsh suspend` and implements a brief 2-second wait (`sleep 2`) to ensure the hypervisor fully registers the state transition.
5. **Resume**: Issues the `virsh resume` command to awaken the VM.
6. **Verify**: Calls `check_vm_state` to interrogate the hypervisor, confirming the VM successfully transitioned back to the `running` state.
7. **Teardown**: Executes `vm_clean` to safely destroy and undefine the test VM instance.

## Usage

Run the script directly via the framework:

```bash
./run.sh
```

## Example Output

[INFO] 2026-06-15 10:29:38 - -----------------------------------------------------------------------------------------
[INFO] 2026-06-15 10:29:38 - -------------------Starting Kvm-Resume Testcase----------------------------
[INFO] 2026-06-15 10:29:38 - Defining VM from XML: /var/gunyah/vm.xml
Domain 'hk-vm' defined from /var/gunyah/vm.xml

[INFO] 2026-06-15 10:29:38 - Starting VM: hk-vm
Domain 'hk-vm' started

[INFO] 2026-06-15 10:29:43 - Suspending VM for resume test...
Domain 'hk-vm' suspended

[INFO] 2026-06-15 10:29:45 - Resuming hk-vm
Domain 'hk-vm' resumed

[INFO] 2026-06-15 10:29:45 - Verifying VM state for 'hk-vm'... Expecting: running
[INFO] 2026-06-15 10:29:45 - SUCCESS: VM is in 'running' state.
[PASS] 2026-06-15 10:29:45 - VM resumed successfully.
[INFO] 2026-06-15 10:29:45 - Cleaning up existing VM state for: hk-vm

## Return Code

- `0` — The VM was successfully started, suspended, resumed, transitioned to running, and finally cleaned up.
- `1` — A failure occurred (e.g., setup failed, the VM refused to suspend or resume, or the state failed to return to running).

## Integration in CI

- Can be run standalone or via LAVA.
- Result file Kvm-Resume.res will be parsed by result_parse.sh.

## Notes

-This script deliberately avoids bashisms and utilizes a standardized POSIX while loop search pattern for script location, ensuring portability across minimal environments like ash or BusyBox.
-A 2-second delay (sleep 2) is injected between the suspend and resume commands. This allows the KVM/libvirt backend sufficient time to flush the state transition before receiving the immediate counter-command, preventing race conditions.

## License

SPDX-License-Identifier: BSD-3-Clause
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.