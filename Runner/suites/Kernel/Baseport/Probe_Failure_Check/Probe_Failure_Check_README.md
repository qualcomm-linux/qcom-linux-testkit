# Probe failure validation

Run `./run.sh` in this directory or invoke its absolute path from Runner.
The suite uses `scan_dmesg_errors` to capture the current kernel log once and
classifies that retained snapshot for probe, bind and firmware-load failures.
Every unresolved entry in an accessible `devices_deferred` list also fails.
Captured kernel BUG, warning and oops fault blocks also fail, including faults
attributed through later stack frames. Later readiness does not erase them.
The script does not alter DT, firmware, modules or driver state.

Supported lookup fallbacks remain warnings only with runtime evidence:

- An optional global `regulatory.db` ENOENT lookup requires a registered
  wireless PHY with a bound driver. Invalid databases and device firmware
  failures remain FAIL.
- Bluetooth ENOENT/EAGAIN lookups require the matching HCI adapter bound to
  `hci_uart_qca` and a bounded successful `bt_adapter_is_usable` check.
  Other transports, unusable adapters and unknown errors remain FAIL. An
  explicit `BTFW_FATAL_RE` disables this exemption. This verifies runtime
  readiness, it does not certify that patched firmware loaded.

The classifier reuses `wifi_filter_regulatory_warnings` and
`bt_firmware_fallback_pattern` from the shared connectivity/Bluetooth libraries.
It captures no additional kernel log and never powers a radio or starts a
service. Missing optional readiness tools cannot grant a fallback exemption.

`Probe_Failure_Check.res` stays beside `run.sh`. Unique logs are under
`$PWD/results/Probe_Failure_Check/run-*/`: `dmesg_snapshot.log`,
`dmesg_errors.log`, `probe_candidates.log`, `probe_fault_blocks.log`,
`probe_failures.log`, `probe_warnings.log`, `probe_runtime.tsv`, and
`devices_deferred.log` when available. The raw snapshot/scanner files remain
intact. Confirmed failures, fallback warnings and runtime classification reasons
are printed to stdout as well as retained in files.
For failures and supported lookup warnings, `firmware_assets.tsv` maps requested filenames to current
image-provided files, including custom firmware roots and kernel update paths.
`probe_devices.tsv` records matching bus and class devices, driver bindings and
DT nodes. Device names come only from device-bearing probe and firmware
messages, including nested Bluetooth prefixes and `probe of <device> failed`
messages. Full fault traces remain in `probe_fault_blocks.log`, stack labels
such as `BUG`, `CPU` and `in_atomic()` are not treated as device names.
Driver-only messages without a device identity also remain in the captured
logs without creating a device row. Names are deduplicated in encounter order.
Its pipe-separated fields are device name, discovered sysfs path,
driver, resolved DT node, driver-owner device, and DT-owner device. A class
device can inherit its transport driver or DT identity from an ancestor, the
owner fields identify that ancestor without claiming the child is bound.
Missing or dangling links remain `unbound` or `unexposed`. A missing class or
bus match for an identified device is recorded as `missing`, it is not dropped
because sysfs cannot resolve it. An optional device-context parser error warns
and omits that inventory, retaining the captured verdict. These context files
do not change a confirmed failure's verdict.
These diagnostics distinguish a missing asset from an error despite an asset
being present. A current file alone cannot establish successful boot-time
consumption. Confirmed faults remain failures even when a device later works.
The error replay is bounded to 60 lines, and
the complete snapshot and filtered failure log remain available.
Missing optional context tools omit that extra inventory and preserve the core
probe verdict, they do not turn a known failure into SKIP.
Missing kernel-log access skips that check, it cannot create a clean-log PASS.
An independently observed unresolved probe still fails.

Yocto, Debian, Ubuntu, CentOS and shell-only ramdisk use image-provided tools.
Missing inventory tools report SKIP before inspection.
The shared scanner uses dmesg and its existing explicitly enabled journal
fallback. Debugfs is read only when already available, it is not mounted.
The shared filtered error log also retains scoped kernel BUG, warning and oops
stacks, including logs with timestamp/thread prefixes. The probe verdict uses
the captured probe/firmware classification, fault blocks and deferred list as
described above. Failed classification records FAIL, malformed or unreadable
evidence cannot become a clean-log PASS.

```sh
# From this suite directory, inspect the running image without changing it.
./run.sh

# From Runner, keep new diagnostics under the invocation directory.
./suites/Kernel/Baseport/Probe_Failure_Check/run.sh

# Require strict Bluetooth firmware-error policy without a ROM exemption.
BTFW_FATAL_RE='Direct firmware load|QCA Failed to request file' \
    ./suites/Kernel/Baseport/Probe_Failure_Check/run.sh
```

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
