# Device Tree Hardware Capability Validation

## Overview

`DeviceTree_HW_Capability_Validation` validates the active runtime device tree,
not a DTB stored on the root filesystem. It is designed for Qualcomm Linux
Developer Kits and Evaluation Kits with differing board revisions, FIT DTB
selection, and overlays.

The suite discovers enabled hardware controllers from the runtime `compatible`
properties. It does not hardcode board names, network-interface names, or
attached peripherals.

## Validation scope

| Area selector | Validation |
| --- | --- |
| `identity` | Runtime DT root, `compatible`, optional `model`, root address and size cells, and a profile identifier derived from the first compatible string |
| `boot` | Optional `/chosen` `stdout-path` and `bootargs`, including stdout target resolution through `/aliases` |
| `cpu-memory` | Enabled DT CPU nodes cover kernel-exposed CPUs; memory nodes expose `reg`; reserved-memory children expose `reg` or `size`; declared NUMA node identifiers are inventoried |
| `interrupts` | Readable `/proc/interrupts`, interrupt-controller providers, and GIC, PDC, and GPIO structural or runtime evidence as appropriate |
| `fabric` | Clock, reset, regulator, power-domain, mailbox, interconnect, RPMh, LLCC, and SMMU provider structure with platform-driver evidence where applicable; optional regulator and generic power-domain debugfs summaries are retained when exposed |
| `storage` | Enabled UFS, SDHCI, and SPI controller bindings; SPI-NOR DT inventory; optional NVMe and MTD runtime evidence |
| `usb` | Enabled USB controller binding plus optional host and gadget-controller runtime evidence, including role-state reporting when host mode is inactive; enabled Qualcomm PMIC GLINK declarations require a bound parent, UCSI auxiliary device, and Type-C port exposure |
| `pcie` | Enabled PCIe controller binding plus optional endpoint enumeration evidence |
| `network` | Enabled Ethernet controller binding, non-virtual network-runtime evidence, and separate Wi-Fi/Bluetooth DT inventory without requiring an external module or link |
| `multimedia` | Display and GPU binding, audio and camera DT inventory, and optional DRM and ALSA runtime evidence |
| `remoteproc` | Enabled Qualcomm remoteproc inventory, memory-region and firmware-name evidence, firmware provisioning status, and runtime instance correlation |
| `security` | OP-TEE, SCM, TPM, and KVM EL2 DT inventory with optional TEE, TPM, and KVM runtime evidence, distinguishing a likely Qualcomm TEE flow from declared OP-TEE |
| `health` | Captured relevant DT and controller probe failures plus capability-gated thermal-zone readings and cooling-device exposure. Optional or aggregate zones without a current temperature are reported separately when other readable zones establish runtime health |

Existing focused suites remain responsible for active functional testing. For
example, PCIe endpoint enumeration, Ethernet traffic, audio capture,
interconnect voting, and EDAC counter behavior are not duplicated here.

## Result policy

- **PASS**: Required DT structure is present and a discovered controller is bound.
- **SKIP**: The runtime tree does not expose an optional capability, remoteproc
  firmware is not provisioned, an external fixture or USB role is inactive, a
  framework provider has no direct runtime binding, optional debugfs evidence
  is unavailable, an optional or aggregate thermal zone has no current
  temperature, or a required base utility is absent.
- **FAIL**: Required DT identity, CPU, or memory data is invalid; a hardware
  controller that requires an MMIO register range lacks `reg`; or the captured
  kernel log reports relevant failures. Enabled PMIC GLINK/UCSI or thermal
  capabilities that do not produce their required runtime objects also fail.
  Framework children and firmware nodes without direct platform-device
  representation are reported as **SKIP**.

An attached USB device, PCIe endpoint, Ethernet cable, display, camera, or
wireless module is not required. Those are fixture-level validations.

The profile identifier is runtime-derived from the first compatible string.
This keeps the baseline valid for all supported `meta-qcom` machines and their
overlay variants without tying the suite to a Yocto `MACHINE` name. Platform
profiles can later add stricter requirements after target evidence is collected.

## Usage

Run directly on the target from the suite directory:

```sh
./run.sh
```

By default all areas run. To shorten an investigation, select one area or a
comma-separated set. The accepted area names correspond to the table above:

```sh
./run.sh --area interrupts
./run.sh --area storage,usb,pcie
./run.sh --area remoteproc,security
./run.sh --list-areas
```

Run only the newly extended validation areas:

```sh
./run.sh --area usb
./run.sh --area fabric,health
```

The suite builds compatible, provider-property, and platform-device indexes
once at startup, then reuses them for each selected area. This avoids repeated
full device-tree and platform-bus scans. It deliberately does not run checks in
parallel because they update one result file and one set of result counters.
The final output includes a compact per-area pass, fail, and skip table; full
per-node details remain in the artifacts.

The result file is `DeviceTree_HW_Capability_Validation.res`. DT node lists and
captured kernel-log artifacts, including `dmesg_snapshot.log` and
`dmesg_errors.log`, are retained in:

```text
results/DeviceTree_HW_Capability_Validation/
```

This directory also contains `dt_compatible_index.log`,
`dt_property_index.log`, `platform_device_index.log`, and
`dt_area_summary.tsv`. Capability-dependent runs additionally retain
`pmic_glink_nodes.log`, `typec_ports.log`, `thermal_zones.log`,
`cooling_devices.log`, `regulator_summary.log`, and
`power_domain_summary.log` when the corresponding runtime interfaces exist.

Check the final result, area summary, and capability evidence:

```sh
cat DeviceTree_HW_Capability_Validation.res
cat results/DeviceTree_HW_Capability_Validation/dt_area_summary.tsv
cat results/DeviceTree_HW_Capability_Validation/pmic_glink_nodes.log
cat results/DeviceTree_HW_Capability_Validation/typec_ports.log
cat results/DeviceTree_HW_Capability_Validation/thermal_zones.log
cat results/DeviceTree_HW_Capability_Validation/cooling_devices.log
cat results/DeviceTree_HW_Capability_Validation/dmesg_errors.log
```

The optional regulator and power-domain summaries can be checked when debugfs
exposes them:

```sh
test -r results/DeviceTree_HW_Capability_Validation/regulator_summary.log && \
    cat results/DeviceTree_HW_Capability_Validation/regulator_summary.log
test -r results/DeviceTree_HW_Capability_Validation/power_domain_summary.log && \
    cat results/DeviceTree_HW_Capability_Validation/power_domain_summary.log
```

## LAVA

Use `DeviceTree_HW_Capability_Validation.yaml`. The definition invokes the
suite and uploads its result file through the repository LAVA helper.
