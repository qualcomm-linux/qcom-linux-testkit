# Probe failure validation

Run `./run.sh` in this directory or invoke its absolute path from Runner.
The suite uses `scan_dmesg_errors` to capture the current kernel log once and
filters that retained snapshot for probe, bind and firmware-load failures.
Every unresolved entry in an accessible `devices_deferred` list also fails.
Firmware-load errors remain visible even when another functional test passes.
The script does not alter DT, firmware, modules or driver state.

`Probe_Failure_Check.res` stays beside `run.sh`. Unique logs are under
`$PWD/results/Probe_Failure_Check/run-*/`: `dmesg_snapshot.log`,
`dmesg_errors.log`, `probe_failures.log`, and `devices_deferred.log` when
available. Failure evidence is printed to stdout as well as retained in files.
On failure, `firmware_assets.tsv` maps requested filenames to current
image-provided files, including custom firmware roots and kernel update paths.
`probe_devices.tsv` records matching bus and class devices, driver bindings and
DT nodes. Its pipe-separated fields are device name, discovered sysfs path,
driver, resolved DT node, driver-owner device, and DT-owner device. A class
device can inherit its transport driver or DT identity from an ancestor, the
owner fields identify that ancestor without claiming the child is bound.
Missing or dangling links remain `unbound` or `unexposed`. A missing class or
bus match is recorded as `missing`, current runtime evidence never changes the
captured probe-failure verdict.
These diagnostics distinguish a missing asset from an error despite an asset
being present. Neither a current file nor a bound driver erases a captured
firmware-load or probe failure. The error replay is bounded to 60 lines, and
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
the captured probe/firmware patterns and deferred list as described above.

```sh
# From this suite directory, inspect the running image without changing it.
./run.sh

# From Runner, keep new diagnostics under the invocation directory.
./suites/Kernel/Baseport/Probe_Failure_Check/run.sh
```

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
