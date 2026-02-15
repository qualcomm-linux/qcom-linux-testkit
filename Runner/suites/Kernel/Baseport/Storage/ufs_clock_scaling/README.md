# UFS Clock Scaling and Gating Validation
## Overview

This shell script executes on the DUT (Device-Under-Test) and verifies the UFS clock scaling and clock gating functionality by monitoring clock frequency changes during I/O load and idle states.

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of mandatory configs: `CONFIG_SCSI_UFSHCD`, `CONFIG_SCSI_UFS_QCOM`
   - Checks optional configs: `CONFIG_SCSI_UFSHCD_PLATFORM`, `CONFIG_SCSI_UFSHCD_PCI`, `CONFIG_SCSI_UFS_CDNS_PLATFORM`, `CONFIG_SCSI_UFS_HISI`, `CONFIG_SCSI_UFS_EXYNOS`, `CONFIG_SCSI_UFS_ROCKCHIP`, `CONFIG_SCSI_UFS_BSG`

2. **Device Tree Validation**:
   - Verifies UFS device tree nodes exist at `/sys/bus/platform/devices/*ufs*`
   - Detects UFS block device partition

3. **Clock Frequency Node Detection**:
   - Locates current frequency node: `/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/cur_freq`
   - Locates max frequency node: `/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/max_freq`
   - Locates min frequency node: `/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/min_freq`

4. **Clock Scaling Verification**:
   - Generates I/O load using `dd` command (writes 2GB of data)
   - Monitors whether UFS clock scales up to maximum frequency during load
   - Validates clock frequency on application of load

5. **Clock Gating Verification**:
   - Waits for UFS driver to enter idle state
   - Monitors whether UFS clock gates down to minimum frequency when idle
   - Validates ufs clock is gated when no load is present

## How to Run

```sh
source init_env
cd suites/Kernel/Baseport/Storage/ufs_clock_scaling
./run.sh
```

## Prerequisites

- `dd`, `sleep` must be available
- Root access may be required for complete validation
- Sufficient storage space for temporary test file (approximately 2GB)

## Result Format

Test result will be saved in `ufs_clock_scaling.res` as:
- `ufs_clock_scaling PASS` – if both clock scaling and gating validations pass
- `ufs_clock_scaling FAIL` – if either clock scaling or gating check fails
- `ufs_clock_scaling SKIP` – if required kernel configs, device tree nodes, or UFS devices are not found

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
