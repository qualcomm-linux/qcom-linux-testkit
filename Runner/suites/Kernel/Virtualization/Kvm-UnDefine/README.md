# Kvm-UnDefine Test 

## Overview

This test validates the teardown and cleanup process for KVM virtual machines managed via `virsh`. It ensures that a running VM can be successfully force-stopped (destroyed) and that its configuration can be completely removed (undefined) from the host hypervisor without leaving residual state behind.

## Test Goals

- Verify the ability to successfully destroy (force-stop) a running VM instance.
- Ensure that virsh undefine completely removes the VM's configuration.
- Confirm that the VM no longer appears in virsh list (running) or virsh list --all (defined) after the teardown process.
- Validate the robustness of the automated VM lifecycle management script.

## Prerequisites

- Host kernel built with KVM virtualization support.
- virsh utility installed and configured on the host.
- Root privileges to manage VMs via virsh.

## Script Location
```
Runner/suites/Kernel/VIRTUALIZATION/Kvm-UnDefine/run.sh
```
## Files

- `run.sh` - Main test script
- `Kvm-UnDefine.res` - Summary result file with PASS/FAIL
- `Kvm-UnDefine.log` - Full execution log (generated if logging is enabled)

## How It Works

1. **Discovery & Setup**: Climbs the directory tree to locate and source init_env (using the __INIT_ENV_LOADED guard to prevent redundant sourcing) and $TOOLS/functestlib.sh for common testing utilities. Resolves the test directory using find_test_case_by_name.
2. **Pre-Check**: Scans virsh list --all for the target $VM_NAME. If it already exists, cleans it up to ensure a clean slate.
3. **Initialization**: Defines and starts a fresh VM instance using vm_define and vm_start to create a valid state for teardown.
4. **Destroy**: Executes virsh destroy to stop the VM. Verifies the VM is no longer actively running.
5. **Undefine**: Executes virsh undefine to erase the VM's configuration from the hypervisor.
6. **Verify & Teardown**: Checks virsh list --all. If the VM configuration is still found, the test fails. If it is entirely absent, the test passes.

## Usage

Run the script directly via the framework:
```bash
./run.sh
```

## Example Output

[INFO] 2026-06-15 10:30:26 - -----------------------------------------------------------------------------------------
[INFO] 2026-06-15 10:30:26 - -------------------Starting Kvm-UnDefine Testcase----------------------------
[INFO] 2026-06-15 10:30:26 - Defining VM from XML: /var/gunyah/vm.xml
Domain 'hk-vm' defined from /var/gunyah/vm.xml

[INFO] 2026-06-15 10:30:26 - Starting VM: hk-vm
Domain 'hk-vm' started

[INFO] 2026-06-15 10:30:32 - Destroying VM hk-vm
Domain 'hk-vm' destroyed

[INFO] 2026-06-15 10:30:34 - Undefining VM hk-vm
Domain 'hk-vm' has been undefined

[PASS] 2026-06-15 10:30:34 - VM successfully torn down.

## Return Code

- `0` — VM was successfully destroyed and its configuration undefined without errors.
- `1` — Failed to locate framework environment, VM failed to define/start initially, VM remained running after destroy, or configuration persisted after undefining.

## Integration in CI

- Can be run standalone or via LAVA.
- Result file Kvm-UnDefine.res will be parsed by result_parse.sh.

## Notes

- The script leverages a POSIX-compliant directory-climbing while loop to dynamically locate init_env, avoiding hardcoded paths and Bashisms.
- The virsh destroy command forces the VM to stop immediately (equivalent to pulling the power plug), which is required to ensure the undefine command works reliably without waiting for a graceful guest OS shutdown.
- Failure at any intermediate step (like failing to vm_start) immediately records a FAIL in the .res file and halts execution.

## License

SPDX-License-Identifier: BSD-3-Clause
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.