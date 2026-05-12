# Kvm-Reboot Test
© Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview
This test validates the reboot functionality of the Guest VM. It issues a reboot command via `virsh` and ensures the VM returns to a running state.

### The test checks for:
- Successful execution of `virsh reboot`.
- VM returning to **"running"** state.

## Usage
### Quick Example
```bash
cd /var/Runner/suites/Kernel/Virtualization/Kvm-Reboot
./run.sh
```

### Result Format
Test result will be saved in Kvm-Reboot.res.

### Output
Kvm-Reboot PASS OR Kvm-Reboot FAIL
