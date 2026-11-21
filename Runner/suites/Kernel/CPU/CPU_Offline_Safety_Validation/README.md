# CPU_Offline_Safety_Validation

Validate CPU hotplug sysfs safety: boot CPU remains online and online files exist. Does not offline CPUs (see hotplug suite).

This suite discovers kernel interfaces at runtime. It does not hard-code SoC
names, fixed CPU lists, or board maps. Missing optional ABI is `SKIP`. A
broken required interface on an applicable device is `FAIL`.

## Prerequisites

- Image-provided utilities: `cat grep sed awk tr`, plus `mkdir`, `mktemp`, and `date`
  for the shared evidence directory
- POSIX `/bin/sh` (BusyBox-capable)
- Root is required only to probe whether `cpu0/online` rejects offline. Non-root records that the node is not writable.
- Optional `/proc/config.gz` for Kconfig cross-checks; absence is `SKIP`,
  not `FAIL`

This is driver/sysfs coverage and can run on a ramdisk that exports the
relevant nodes. It does not require Weston, audio services, or extra
firmware blobs.

## Launch

```sh
cd Runner/suites/Kernel/CPU/CPU_Offline_Safety_Validation
./run.sh
./run.sh --help
```

Unknown arguments fail before any DUT writes. The LAVA YAML invokes `./run.sh`
with no extra parameters.

## Options

| Option | Default | Purpose |
|---|---|---|
| `--help` / `-h` | | Print usage and exit |

## Results and artifacts

- `CPU_Offline_Safety_Validation.res` in the suite directory: `CPU_Offline_Safety_Validation PASS`, `CPU_Offline_Safety_Validation FAIL`, or
  `CPU_Offline_Safety_Validation SKIP`
- `results/CPU_Offline_Safety_Validation/run-*/kernel/dmesg_snapshot.log`, `dmesg_errors.log`, and
  `dmesg_access.log` from `scan_dmesg_errors`
- Optional stdout capture from `init_env` next to the suite

Verdicts:

- `PASS`: applicable checks ran and met their criteria
- `FAIL`: an applicable interface was inconsistent, unreadable when required,
  or a selected write path failed
- `SKIP`: the capability, optional debug ABI, or image-provided tool is absent

## Cleanup

If a write of `0` to `cpu0/online` is unexpectedly accepted, the suite immediately writes `1` to restore it.

Generated `.res` files and `results/` trees are local artifacts and are not
part of the contribution.

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
