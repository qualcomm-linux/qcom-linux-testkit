# Kvm-Setup Test
© Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview
This test case initializes the KVM environment by defining the Virtual Machine using an XML configuration and starting the domain. It verifies that the VM transitions to the `running` state.

### The test checks for:
- Successful **definition** of the VM from `vm.xml`.
- Successful **start** command execution.
- Verification that the VM state is **"running"**.

## Usage
### Instructions:
1. Ensure the `vm.xml` and guest image files are present in `/var/gunyah/`.
2. Navigate to the test directory.
3. Run the script.

### Quick Example
```bash
cd /var/Runner/suites/Kernel/Virtualization/Kvm-Setup
./run.sh
```

### Prerequisites
1. virsh tool must be installed.
2. Gunyah hypervisor must be enabled.
3. Root access is required.

### Result Format
Test result will be saved in Kvm-Setup.res.

### Output
Kvm-Setup PASS OR Kvm-Setup FAIL