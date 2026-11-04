# RNG statistics

Run `./run.sh` from this directory using image-provided rngtest, head, wc, awk
and mktemp. Select /dev/hwrng when present, otherwise /dev/urandom. A selected
hardware source that fails or times out FAILs without replacing it with urandom.
This result names its actual source and does not claim Qualcomm hardware
coverage when only the software source exists.

Read exactly 2,500,004 bytes in 10 seconds, then validate 1000 FIPS blocks
within 30 seconds. Preserve the existing threshold of at least 997 successes.
Short reads, incomplete or invalid statistics and command/timeouts FAIL.
Missing clients SKIP. CWD results/rngtest/run-* retains entropy and logs.
Works on Yocto, Debian, Ubuntu and CentOS without an init manager.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
