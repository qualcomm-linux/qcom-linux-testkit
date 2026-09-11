# Ethernet_Inventory_Validation

## Overview

This testcase performs a read-only inventory of every enumerated physical Ethernet interface. It is intended to establish whether the MAC, PHY, driver, device-tree node, queue layout, and associated platform resources are visible before running link or traffic tests.

## Coverage

For each interface, the testcase reports and validates:

- physical network-interface enumeration
- MAC address and MTU
- driver and kernel-module binding
- device and bus path
- firmware version when reported by the driver
- OF compatible string when exposed
- PHY identifier when exposed
- carrier, operational state, speed, and duplex
- RX and TX queue enumeration
- relevant kernel probe messages

The testcase does not bring interfaces up, run DHCP, change link settings, or transmit traffic.

When the runtime PCI topology contains a QPS615 switch (`1179:0623`), the
testcase also correlates downstream TC956x driver functions with exported
Ethernet interfaces and verifies that `TC956X_Firmware_PCIeBridge.bin` remains
available from a standard firmware root. Images without QPS615 retain the
generic Ethernet inventory behavior.

For each expected Toshiba `1179:0220` Ethernet function, the live log and TSV
include its PCI modalias, bound driver, exported netdevs, and availability of
the running-kernel `tc956x_pcie_eth` module. They also report whether that
module registered its `tc956x_pci-eth` PCI driver and expose the current
`tc956x_eth_ports_bdf` value, PCI driver-autoprobe state, per-function driver
override, runtime power state, and runtime OF node as diagnostic evidence. The
driver's all-zero BDF array selects its built-in defaults and is not itself a
failure. An enumerated Ethernet function that remains unbound is a real
Ethernet failure only when its runtime OF node declares a platform Ethernet
port through the current `phy-reset-gpios` property or the legacy
`qcom,phy-rst-gpio` property. Bare embedded PCI functions can be enumerated for
IOMMU/topology description even when no MAC/PHY port is provisioned, and are
reported as SKIP. The PCIe suite continues to evaluate switch topology and
firmware independently.

This classification follows the Qualcomm Linux PCIe and Ethernet guides: the
QPS615 MAC driver and kernel configuration are enabled by default, and the
supported Ethernet interfaces are expected to activate during startup once the
QPS615 driver is loaded and the PCIe link is established. Link carrier and the
optional AQR PHY are not required by this inventory-only testcase.

References:

- [Qualcomm Linux PCIe guide](https://docs.qualcomm.com/doc/80-70023-8/topic/pcie.html#pcie-software-support-feature-for-qps615)
- [Qualcomm Linux Ethernet bring-up guide](https://docs.qualcomm.com/bundle/publicresource/80-70023-26/topics/bring_up-ethernet.md)

## Prerequisites and infrastructure

- No cable, peer, DHCP service, or Internet connection is required.
- The target must expose the interface through `/sys/class/net` with a bound
  physical device.
- Standard image utilities such as `find`, `readlink`, `awk`, and `grep` must
  be present.
- `ethtool` data is collected when available, but optional properties that the
  driver does not expose are reported as SKIP.

## Run

```sh
cd Runner/suites/Connectivity/Ethernet/Ethernet_Inventory_Validation
./run.sh
./run.sh --help
```

Use `--interface IFACE` or `ETH_INTERFACE` to inspect one explicit interface.
When neither is provided, the suite uses the shared Ethernet discovery helper
and inventories every detected physical interface. CLI options override
environment variables.

Example:

```sh
./run.sh --interface end0
```

## Result

Check the final result and per-check summary:

```sh
cat Ethernet_Inventory_Validation.res
cat Ethernet_Inventory_Validation.results.tsv
```

The testcase passes when at least one physical Ethernet interface is enumerated with a bound driver and valid RX/TX queue entries. Optional OF and PHY properties are reported as SKIP when the corresponding bus or driver does not expose them.

On QPS615 systems, inspect the correlated PCIe, driver, and netdev evidence:

```sh
cat qps615_runtime/qps615_switches.log
cat qps615_runtime/qps615_runtime.tsv
```

The QPS615 files are empty or contain no switch records when the capability is
not present. That does not change the generic Ethernet result path.
