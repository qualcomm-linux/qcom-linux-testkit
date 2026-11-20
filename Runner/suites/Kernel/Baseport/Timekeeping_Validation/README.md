# Timekeeping_Validation

Validate monotonic timekeeping: /proc/uptime advances, CLOCK-like counters do not go backwards, and nanosleep sleeps at least the requested interval.

This suite discovers kernel interfaces at runtime. It does not hard-code SoC
names, fixed CPU lists, or board maps. Missing optional ABI is `SKIP`. A
broken required interface on an applicable device is `FAIL`.

## Prerequisites

- Image-provided utilities: `cat grep sed awk tr sleep`, plus `mkdir`, `mktemp`, and `date`
  for the shared evidence directory
- POSIX `/bin/sh` (BusyBox-capable)
- Read access to the sysfs/proc nodes named in `run.sh`; root is not required
- Optional `/proc/config.gz` for Kconfig cross-checks; absence is `SKIP`,
  not `FAIL`

This is driver/sysfs coverage and can run on a ramdisk that exports the
relevant nodes. It does not require Weston, audio services, or extra
firmware blobs.

## Launch

```sh
cd Runner/suites/Kernel/Baseport/Timekeeping_Validation
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

- `Timekeeping_Validation.res` in the suite directory: `Timekeeping_Validation PASS`, `Timekeeping_Validation FAIL`, or
  `Timekeeping_Validation SKIP`
- `results/Timekeeping_Validation/run-*/kernel/dmesg_snapshot.log`, `dmesg_errors.log`, and
  `dmesg_access.log` from `scan_dmesg_errors`
- Optional stdout capture from `init_env` next to the suite

Verdicts:

- `PASS`: applicable checks ran and met their criteria
- `FAIL`: an applicable interface was inconsistent, unreadable when required,
  or a selected write path failed
- `SKIP`: the capability, optional debug ABI, or image-provided tool is absent

## Cleanup

Read-only. No modules, governors, or device nodes are changed.

Generated `.res` files and `results/` trees are local artifacts and are not
part of the contribution.

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
