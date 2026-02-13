# Kvm-Resume Test
© Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview
This test validates that a suspended VM can be resumed to active execution.

### The test checks for:
- Successful execution of `virsh resume`.
- VM state transition back to **"running"**.

## Usage
### Quick Example
```bash
cd /var/Runner/suites/Kernel/Virtualization/Kvm-Resume
./run.sh
```

### Result Format
Test result will be saved in Kvm-Reboot.res.

### Output
Kvm-Reboot PASS OR Kvm-Reboot FAIL
