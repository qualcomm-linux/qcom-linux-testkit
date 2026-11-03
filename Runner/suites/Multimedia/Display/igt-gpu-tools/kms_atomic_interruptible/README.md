# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# IGT kms_atomic_interruptible Test Script

## Overview

This script automates the validation of the KMS atomic modesetting API under interrupt-heavy conditions using the IGT `kms_atomic_interruptible` test suite. It exercises atomic commits while injecting signals to verify that the kernel correctly handles interrupted system calls and recovers display state cleanly. The script stops any active Weston compositor before the test and restores it afterwards.

## Features

- Full coverage of `kms_atomic_interruptible` subtests
- Automatic Weston compositor stop/restore around the IGT run
- Configurable binary path and timeout via arguments or environment variables
- Bounded signal-trap cleanup preventing DRM device conflicts
- Subtest-level pass/fail/skip counting and summary
- Result written to `kms_atomic_interruptible.res` for LAVA integration

## Prerequisites

- `kms_atomic_interruptible` binary from the IGT GPU tools package (default: `/usr/libexec/igt-gpu-tools/kms_atomic_interruptible`)
- Write access to the test directory

## Directory Structure

```
Runner/
└── suites/
    └── Multimedia/
        └── Display/
            └── igt-gpu-tools/
                └── kms_atomic_interruptible/
                    ├── run.sh
                    ├── kms_atomic_interruptible.yaml
                    └── README.md
```

## Usage

**Method 1: Named argument**
```bash
./run.sh --kms-atomic-interruptible-path /usr/libexec/igt-gpu-tools/kms_atomic_interruptible
```

**Method 2: Positional argument**
```bash
./run.sh /usr/libexec/igt-gpu-tools/kms_atomic_interruptible
```

**Method 3: Environment variable override**
```bash
IGT_TIMEOUT=600 ./run.sh
```

**Method 4: Help**
```bash
./run.sh --help
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `IGT_TIMEOUT` | `300` | Maximum seconds to wait for the IGT binary to complete |

## Output Files

| File | Description |
|---|---|
| `kms_atomic_interruptible_log.txt` | Full stdout/stderr from the IGT binary |
| `kms_atomic_interruptible.res` | Final result: `kms_atomic_interruptible PASS`, `FAIL`, or `SKIP` |

## Test Status Determination

| Condition | Result |
|---|---|
| Exit code 143 or 124 | FAIL (timeout) |
| Exit code 77 | SKIP (IGT skip) |
| Exit code ≠ 0 | FAIL |
| `fail_count > 0` | FAIL |
| `success_count = 0` and `skip_count > 0` | SKIP |
| Otherwise | PASS |

## Running via the Unified Runner

```bash
cd <repo>/Runner
./run-test.sh kms_atomic_interruptible /usr/libexec/igt-gpu-tools/kms_atomic_interruptible
```

## Example Output

```
[INFO] -------------------Starting kms_atomic_interruptible Testcase-----------------------------
[INFO] Using kms_atomic_interruptible binary at: /usr/libexec/igt-gpu-tools/kms_atomic_interruptible
[INFO] Running kms_atomic_interruptible (timeout: 300s)
[INFO] Logs written to: .../kms_atomic_interruptible_log.txt
[INFO] Subtest Results: SUCCESS=6, FAIL=0, SKIP=0, TOTAL=6
[PASS] kms_atomic_interruptible : Test Passed - All 6 subtest(s) succeeded
[INFO] -------------------Completed kms_atomic_interruptible Testcase----------------------------
