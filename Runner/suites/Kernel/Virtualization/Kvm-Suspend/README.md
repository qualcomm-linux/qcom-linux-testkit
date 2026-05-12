# Kvm-Suspend Test
© Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview
This test checks the ability to suspend (pause) the execution of the Guest VM.

### The test checks for:
- Successful execution of `virsh suspend`.
- VM state transition to **"paused"**.

## Usage
### Quick Example
```bash
cd /var/Runner/suites/Kernel/Virtualization/Kvm-Suspend
./run.sh
```

### Result Format
Test result will be saved in Kvm-Suspend.res.

### Output
Kvm-Suspend PASS OR Kvm-Suspend FAIL
