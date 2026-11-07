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
Missing kernel-log access skips that check, it cannot create a clean-log PASS.
An independently observed unresolved probe still fails.

Yocto, Debian, Ubuntu, CentOS and shell-only ramdisk use image-provided tools.
Missing inventory tools report SKIP before inspection.
The shared scanner uses dmesg and its existing explicitly enabled journal
fallback. Debugfs is read only when already available, it is not mounted.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
