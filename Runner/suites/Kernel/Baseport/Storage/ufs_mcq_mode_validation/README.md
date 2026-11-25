# UFS MCQ mode

Checks that the UFS host driver runs in Multi-Circular Queue (MCQ) mode on
devices that support it. MCQ is defined from UFS 4.0 onwards.

The test discovers everything at runtime through sysfs:

1. `detect_ufs_partition_block` finds a block device beneath a bound UFS host.
2. `storage_ufs_host_node` walks up from that block device to the bound UFS
   host controller directory, for example `.../1d84000.ufs`.
3. `storage_ufs_spec_version` reads `device_descriptor/specification_version`
   from that directory and converts it to `<major>.<minor>`.
4. The `use_mcq_mode` module parameter is looked up in
   `/sys/module/*/parameters/use_mcq_mode`. The module name is not hard coded,
   but only a module whose name starts with `ufs` (for example `ufshcd_core`)
   is accepted. A same-named parameter in an unrelated module is logged and
   ignored.

Applicability follows the bound UFS host, not the filesystem that holds the
root partition. Nothing on the device is modified.

## Prerequisites

- Image-provided `cat` and `readlink`. No package installation is attempted.
- A kernel that exposes the UFS host attributes in sysfs.
- No command-line options, permissions beyond read access to sysfs, or
  external fixtures are required.

## Usage

```sh
cd Runner/suites/Kernel/Baseport/Storage/ufs_mcq_mode_validation
./run.sh
```

## Results

`ufs_mcq_mode_validation.res` is written beside `run.sh` and replaces the previous result.
Reasons are reported in the console log, not in the result file.

| Result | Condition |
|--------|-----------|
| PASS | UFS 4.0 or later and `use_mcq_mode` reads `Y` (or `1`). |
| FAIL | `use_mcq_mode` reads `N` (or `0`) or any other value. |
| FAIL | The UFS host controller cannot be resolved from the block device. |
| FAIL | `specification_version` is missing, unreadable or not hexadecimal. |
| FAIL | UFS 4.0 or later, but no readable `use_mcq_mode` parameter exists in a UFS module. |
| SKIP | No block device beneath a bound UFS host (not a UFS system). |
| SKIP | UFS specification version is below 4.0. |
| SKIP | `cat` or `readlink` is missing from the image. |

A UFS 4.0 or later device whose kernel does not provide `use_mcq_mode` is
reported as FAIL because the expected evidence is missing on an applicable
device.

## Cleanup

The test creates no files other than `ufs_mcq_mode_validation.res` and changes no system
state, so no cleanup is needed.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

