# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# IGT kms_addfb_basic Test Script

## Overview

This script automates the validation of basic DRM framebuffer creation and destruction using the IGT `kms_addfb_basic` test suite. It exercises the `DRM_IOCTL_MODE_ADDFB` and `DRM_IOCTL_MODE_ADDFB2` kernel interfaces across a range of pixel formats and tiling modes. The script stops any active Weston compositor before the test and restores it afterwards.

## Features

- Full coverage of `kms_addfb_basic` subtests
- Automatic Weston compositor stop/restore around the IGT run
- Configurable binary path and timeout via arguments or environment variables
- Bounded signal-trap cleanup preventing DRM device conflicts
- Subtest-level pass/fail/skip counting and summary
- Result written to `kms_addfb_basic.res` for LAVA integration

## Prerequisites

- `kms_addfb_basic` binary from the IGT GPU tools package (default: `/usr/libexec/igt-gpu-tools/kms_addfb_basic`)
- Write access to the test directory

## Directory Structure

```
Runner/
└── suites/
    └── Multimedia/
        └── Display/
            └── igt-gpu-tools/
                └── kms_addfb_basic/
                    ├── run.sh
                    ├── kms_addfb_basic.yaml
                    └── README.md
```

## Usage

**Method 1: Named argument**
```bash
./run.sh --kms-addfb-basic-path /usr/libexec/igt-gpu-tools/kms_addfb_basic
```

**Method 2: Positional argument**
```bash
./run.sh /usr/libexec/igt-gpu-tools/kms_addfb_basic
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
| `kms_addfb_basic_log.txt` | Full stdout/stderr from the IGT binary |
| `kms_addfb_basic.res` | Final result: `kms_addfb_basic PASS`, `FAIL`, or `SKIP` |

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
./run-test.sh kms_addfb_basic /usr/libexec/igt-gpu-tools/kms_addfb_basic
```

## Example Output

```
[INFO] -------------------Starting kms_addfb_basic Testcase-----------------------------
[INFO] Using kms_addfb_basic binary at: /usr/libexec/igt-gpu-tools/kms_addfb_basic
[INFO] Running kms_addfb_basic (timeout: 300s)
[INFO] Logs written to: .../kms_addfb_basic_log.txt
[INFO] Subtest Results: SUCCESS=12, FAIL=0, SKIP=0, TOTAL=12
[PASS] kms_addfb_basic : Test Passed - All 12 subtest(s) succeeded
[INFO] -------------------Completed kms_addfb_basic Testcase----------------------------
