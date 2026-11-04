# PCIe Validation Test
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

## Overview

This test validates PCI enumeration, driver binding and runtime link health using sysfs. When lspci is installed, its output is retained as supplemental evidence. Functional endpoint tests remain in their respective suites.

### The test checks for:

- Presence of **Device Tree Node**
- Supplemental PCI capabilities when exposed by lspci
- Binding of a **Kernel Driver**
- Per-device negotiated and maximum link speed and width
- MSI/MSI-X runtime IRQ exposure
- Runtime power state
- PCIe controller, link-training, and uncorrected AER kernel errors

Unused PCIe bridge ports may legitimately report zero negotiated width. They
are identified as inactive bridge ports, while a zero-width non-bridge
endpoint remains a failure.

These checks help confirm that the PCIe root port is properly initialized and ready for use 

When an enumerated Toshiba `1179:0623` switch identifies QPS615 hardware, the
suite also validates the discovered downstream PCIe topology, TC956x Ethernet
function enumeration, and the image-provided
`TC956X_Firmware_PCIeBridge.bin`. Driver and netdev readiness are logged for
diagnosis but are owned by `Ethernet_Inventory_Validation`, so an Ethernet
driver packaging or binding failure does not incorrectly fail the generic PCIe
contract. Systems without QPS615 continue through the existing generic checks.

The split follows the documented startup sequence. The QPS615 switch power,
I2C initialization, firmware, PCIe link, and bridge enumeration establish the
PCIe capability. The downstream `1179:0220` functions, `tc956x_pci-eth` driver
binding, and exported netdevs establish Ethernet readiness. This keeps a
downstream MAC/PHY problem visible without misclassifying it as a failed PCIe
switch topology.

References:

- [Qualcomm Linux PCIe guide](https://docs.qualcomm.com/doc/80-70023-8/topic/pcie.html#pcie-software-support-feature-for-qps615)
- [Qualcomm Linux Ethernet bring-up guide](https://docs.qualcomm.com/bundle/publicresource/80-70023-26/topics/bring_up-ethernet.md)

## Usage

Run the suite directly on the target:

```sh
cd Runner/suites/Kernel/Baseport/PCIe
./run.sh
```

It can also be launched through the repository runner:

```sh
cd Runner
./run-test.sh PCIe
```

## Prerequisites

1. `lspci` must be available on the target device 
2. PCIe interface must be exposed and initialized
3. Root access may be required depending on system configuration

## Result Format

Check the final result:

```sh
cat PCIe.res
```

The file contains `PCIe PASS`, `PCIe FAIL`, or `PCIe SKIP`.

On QPS615 systems, inspect the retained topology evidence:

```sh
cat qps615_runtime/qps615_switches.log
cat qps615_runtime/qps615_runtime.tsv
find /lib/firmware /usr/lib/firmware \
    -name 'TC956X_Firmware_PCIeBridge.bin*' -print 2>/dev/null
```

Generic PCIe runtime and kernel-health evidence is retained in:

```sh
cat pcie_runtime/pcie_runtime.tsv
cat pcie_runtime/dmesg_errors.log
```

Kernel-log findings are advisory by default because the boot log can contain
history from unused ports or previously detached endpoints. To make matching
PCIe controller, link, or uncorrected AER errors fail the suite:

```sh
PCIE_DMESG_STRICT=1 ./run.sh
```

## Runtime evidence and portability

Driver binding, link state, MSI and power inventory come from PCI sysfs through
pcie_collect_runtime_health. Human-readable lspci labels are not mandatory.
When provided by the image, lspci is collected with a 15-second watchdog and a
failed installed command remains FAIL. Without lspci, sysfs coverage still runs.
No devices is SKIP unless lspci and sysfs contradict each other. No binding is
reported as missing functional coverage, not as proof of a healthy endpoint.
Existing kernel error gating and QPS615 checks retain their configured policy.
Artifacts are stored under CWD/results/PCIe and diagnostics appear in stdout.
