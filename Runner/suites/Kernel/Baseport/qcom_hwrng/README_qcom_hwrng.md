# Qualcomm hardware RNG

Selects a Qualcomm provider from the runtime `rng_available` list and validates
1000 FIPS blocks with the image-provided `rngtest`. The previous RNG selection is
restored after completion, failure or interruption. Nothing is installed.

```sh
cd Runner/suites/Kernel/Baseport/qcom_hwrng
./run.sh
```

The test reads 2,500,004 bytes (32 initial bits plus 1000 blocks of 20,000 bits)
within 60 seconds. Statistics have a separate 30-second limit. Fewer than 10
statistical failures are tolerated, as before, but incomplete statistics,
short reads, timeouts and failed restoration are FAIL. Missing `rngtest` or no
registered Qualcomm provider is SKIP. A registered provider without a readable
`/dev/hwrng` is FAIL.

`qcom_hwrng.res` and a unique `qcom_hwrng.*` evidence directory are written in CWD.
The directory retains entropy bytes, read errors and statistics for diagnosis.
A kernel abort or uninterruptible driver operation still requires platform triage.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
