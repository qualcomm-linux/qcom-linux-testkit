# Kvm-Teardown Test
© Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview
This test cleans up the KVM environment by forcefully stopping (destroying) the VM and removing its configuration (undefining).

### The test checks for:
- Successful execution of `virsh destroy`.
- Successful execution of `virsh undefine`.
- Verification that the VM is no longer listed in `virsh list --all`.

## Usage
### Quick Example
```bash
cd /var/Runner/suites/Kernel/Virtualization/Kvm-Teardown
./run.sh
```

### Result Format
Test result will be saved in Kvm-Reboot.res.

### Output
Kvm-Reboot PASS OR Kvm-Reboot FAIL
