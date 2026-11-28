# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# IGT kms_color Test Script

## Overview

This script automates the validation of DRM color management pipelines using the IGT `kms_color` test suite. It tests gamma correction, degamma, and Color Transformation Matrix (CTM) hardware pipelines by programming the KMS color properties and verifying the output through CRC comparison. The script stops any active Weston compositor before the test and restores it afterwards.

## Features

- Full coverage of `kms_color` subtests (gamma, degamma, CTM)
- Automatic Weston compositor stop/restore around the IGT run
- Configurable binary path and timeout via arguments or environment variables
- Bounded signal-trap cleanup preventing DRM device conflicts
- Subtest-level pass/fail/skip counting and summary
- Result written to `kms_color.res` for LAVA integration

## Prerequisites

- `kms_color` binary from the IGT GPU tools package (default: `/usr/libexec/igt-gpu-tools/kms_color`)
- Write access to the test directory

## Directory Structure

```
Runner/
└── suites/
    └── Multimedia/
        └── Display/
            └── igt-gpu-tools/
                └── kms_color/
                    ├── run.sh
                    ├── kms_color.yaml
                    └── README.md
```

## Usage

**Method 1: Named argument**
```bash
./run.sh --kms-color-path /usr/libexec/igt-gpu-tools/kms_color
```

**Method 2: Positional argument**
```bash
./run.sh /usr/libexec/igt-gpu-tools/kms_color
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
| `kms_color_log.txt` | Full stdout/stderr from the IGT binary |
| `kms_color.res` | Final result: `kms_color PASS`, `FAIL`, or `SKIP` |

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
./run-test.sh kms_color /usr/libexec/igt-gpu-tools/kms_color
```

## Example Output

```
[INFO] -------------------Starting kms_color Testcase-----------------------------
[INFO] Using kms_color binary at: /usr/libexec/igt-gpu-tools/kms_color
[INFO] Running kms_color (timeout: 300s)
[INFO] Logs written to: .../kms_color_log.txt
[INFO] Subtest Results: SUCCESS=10, FAIL=0, SKIP=2, TOTAL=12
[PASS] kms_color : Test Passed - 10 subtest(s) succeeded, 2 skipped
[INFO] -------------------Completed kms_color Testcase----------------------------
