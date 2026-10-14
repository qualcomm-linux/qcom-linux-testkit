# QPS615 interface validation

`QPS615_Interface_Validation` performs read-only QPS615 interface bring-up by
default on both base and overlay images, without hardcoded PCI BDFs or
network-interface names. It correlates
enabled runtime device-tree nodes, the Toshiba `1179:0623` switch, downstream
`1179:0220` Ethernet functions, `tc956x_pcie_eth`, the registered
`tc956x_pci-eth` driver, and exported netdevs. An explicit option supports the
optional EFI boot selection on boards whose FIT integration requires it. This
firmware DT selection is unrelated to installing an image's overlay packages.

The runtime device tree is authoritative when it declares
`compatible = "pci1179,0623"`. A declared node with no enumerated switch is a
bring-up failure. An enumerated switch without a matching runtime DT node is
still validated for compatibility with older integrations.

The public qcom-next binding requires six supplies, `i2c-parent`, and
`resx-gpios` for the TC9563 PCI power-control flow. When a runtime node declares
any of those six supplies, the suite requires the complete supply set and the
node to bind to the `pwrctrl-tc9563` platform driver. Nodes that declare no
supplies remain valid for integrations such as the Talos staging topology that
do not instantiate this platform driver.

## Run

Default validation is read-only. For an explicit standalone module load and
driver/netdev readiness check, reuse the existing module-validation profile:

```sh
cd Runner/suites/Kernel/Baseport/Module_Reload_Validation
./run.sh --module tc956x_pcie_eth --mode load_only
```

Run that command from the repository root. It supports both base and overlay
images without inspecting EFI, keeps initially active modules untouched, and
removes only the target module it loaded. See the module suite README for
prerequisites, restoration, artifacts, and result classification. Ordinary
unload/reload coverage remains available through its unchanged `basic` mode.

```sh
cd Runner/suites/Connectivity/Ethernet/QPS615_Interface_Validation
./run.sh
```

Use this same command on base and overlay images. It does not inspect or modify
EFI and has no `staging` requirement. Runtime DT, PCI enumeration, driver binding
and netdev correlation determine readiness, regardless of package configuration
or how the running DT was loaded. A loaded `tc956x_pcie_eth` module alone is not
proof of an enumerated QPS615 or a usable Ethernet port.

Address readiness prefers IPv4 and also accepts IPv6-only interfaces. IPv6
discovery uses image-provided `ip`, prefers a global address over a link-local
address, and excludes tentative or duplicate-address-failed addresses. A
link-local address supports a same-link peer, it does not prove Internet access.
The interface diagnostic line reports both families. Address readiness is not
packet-transfer proof, run `QPS615_Traffic_Validation` for interface-bound ping,
packet loss and counter checks. No DHCP client or host-side command is started.

### Optional FIT boot preparation

Only when the board's bring-up procedure requires the `staging` FIT selection,
prepare the next boot explicitly. This is not required merely because an image
is base, overlay, or FIT-based:

```sh
./run.sh --prepare-fit
# Existing commands remain supported:
./run.sh --prepare-overlay
```

`--prepare-overlay` is a compatibility alias for `--prepare-fit`. Neither option
selects, downloads, or installs overlay packages. `-h` and `--help` print usage.
There are no environment-variable equivalents for these options.

This option requires image-provided `efivar`, mount utilities, and EFI runtime
services. If efivarfs is unmounted, it mounts the existing EFI variable-storage
directory and leaves it mounted. This follows the manual procedure:

```sh
mount | grep efivar
# If no efivarfs mount is listed:
mount -t efivarfs none /sys/firmware/efi/efivars
```

An existing mount typically appears as
`none on /sys/firmware/efi/efivars type efivarfs (rw,relatime)`.
An existing unique `VendorDtbOverlays` variable supplies its GUID.
If a successful EFI inventory shows no
`VendorDtbOverlays`, explicit preparation creates it using the documented
QPS615 firmware GUID `882f8c2b-9646-435f-8de5-f208ff80c1bd`. Failed inventory,
ambiguous names, and unreadable variables prevent writes and report failure.

If `staging` is not selected, this command writes and verifies it, records
`SKIP`, and asks
the operator to reboot manually. It never reboots the target. After reboot,
rerun the same command. An already selected FIT value followed by missing
runtime QPS615 DT and PCI evidence is then a failure, exposing a FIT image,
firmware, or boot-integration problem.
Firmware may report `staging,el2kvm` after reboot. A value already containing
`staging` is not rewritten, and the additional firmware selection is retained.

Preparation never unmounts efivarfs. A newly created mount remains available
after success, write/read failures, or interruption. Cleanup only restores an
initially read-only mount after a temporary read-write remount, including on
failure or interruption. Initially read-write mounts remain read-write.
Read-only restoration failure makes preparation fail even if the EFI write
succeeded.

The LAVA YAML intentionally runs only the read-only default command. EFI
mutation is not exposed as an automated parameter. Neither mode changes
network configuration, routes, or link state.

## Validation and classification

The suite validates:

- enabled `pci1179,0623` DT nodes and their complete compatible strings;
- conditional `pwrctrl-tc9563` platform-device binding;
- PCI switch and downstream endpoint enumeration, reporting outermost
  `1179:0623` switch roots separately from all matching bridge functions;
- `TC956X_Firmware_PCIeBridge.bin` provisioning;
- TC956x module and PCI-driver readiness;
- runtime DT Ethernet-port declarations and dynamic netdev correlation;
- optional non-mutating `ethtool` driver and link diagnostics;
- captured kernel health through the shared dmesg scanner.

Carrier and IPv4 are readiness evidence and do not fail this suite because
they depend on external wiring and lab network configuration.

- `PASS`: applicable DT, power-control, PCIe, firmware, driver, and netdev
  checks are healthy.
- `FAIL`: DT discovery cannot complete, declared hardware does not enumerate, the supply-backed DT contract
  is partial or unbound, an explicitly selected FIT value does not become
  active, EFI preparation fails, required firmware or driver readiness is
  broken, or an image-provided diagnostic tool fails on an interface.
- `SKIP`: no enabled QPS615 DT node or enumerated switch is present, no
  Ethernet port is provisioned, a newly written FIT value requires reboot, or
  optional carrier, IPv4, or `ethtool` evidence is absent.

The suite installs no packages and is portable across Yocto, Debian, Ubuntu,
and CentOS. Evidence is retained under
`results/QPS615_Interface_Validation/run-*/`, including
`qps615_runtime/qps615_runtime.tsv`, `qps615_dt_nodes.log`,
`qps615_dt_platform.tsv`, `qps615_dt_scan.log`, PCI topology,
`ethtool`, and captured kernel logs.
Only explicit FIT preparation generates `qps615_overlay.tsv`, EFI diagnostics,
`before_qps615_overlay.tsv`, the original variable
inventory and printout, and mount/cleanup logs alongside the updated evidence.
Scratch files use the writable evidence directory, so an inherited missing
ADB `TMPDIR` such as `/data/local/tmp` cannot break EFI or DT discovery. A
discovery error is reported as `FAIL`, never as proof that QPS615 is absent.

For the guide's one upstream and three downstream `0623` bridges, the runtime
summary reports `switches=1 bridge_functions=4`. Separate PCI hierarchies are
counted independently. A switch-root group includes any nested `0623` bridges,
so this count describes the discovered topology roots.

## Public driver references

- [qcom-next TC9563 binding](https://github.com/qualcomm-linux/kernel/blob/qcom-next/Documentation/devicetree/bindings/pci/toshiba%2Ctc9563.yaml)
- [qcom-next TC9563 power-control driver](https://github.com/qualcomm-linux/kernel/blob/qcom-next/drivers/pci/pwrctrl/pci-pwrctrl-tc9563.c)
- [kernel-topics QPS615 pull requests](https://github.com/search?q=repo%3Aqualcomm-linux%2Fkernel-topics+qps615&type=pullrequests)
- [QCS8550 RB5Gen2 base-DT integration](https://github.com/qualcomm-linux/kernel-topics/commit/33cae252054a694269f9dcd41b354063193c8f59)

Use `QPS615_Traffic_Validation` for fixture-gated interface-bound ping and
counter movement. Use the existing generic Ethernet capability, throughput,
bidirectional, dual-port, and suspend/resume suites for their respective
end-use cases after selecting a QPS615-correlated interface.

## Failure diagnostics

Recorded failures automatically save read-only `ethtool` evidence for the
selected interfaces and replay bounded excerpts to stdout with `[ETH-DIAG]`
markers. No host commands, runtime package installation or new options are
required. The original verdict and cleanup behavior remain unchanged.
See [shared Ethernet failure diagnostics](../README_Ethernet_Diagnostics.md)
for collected queries, artifact locations, time bounds and unavailable-tool handling.
