# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# IGT kms_atomic Test Script

## Overview

This script automates the validation of the KMS atomic modesetting API using the IGT `kms_atomic` test suite. It exercises atomic property commits, plane configurations, and connector/CRTC state transitions. Subtests matching `*test*` or `*immutable*` are excluded by default as they require special hardware configurations. The script stops any active Weston compositor before the test and restores it afterwards.

## Features

- Atomic modesetting API validation via `--run-subtest '*,!*test*,!*immutable*'`
- Configurable subtest filter via `--run-subtest` argument
- Automatic Weston compositor stop/restore around the IGT run
- Configurable binary path and timeout via arguments or environment variables
- Bounded signal-trap cleanup preventing DRM device conflicts
- Subtest-level pass/fail/skip counting and summary
- Result written to `kms_atomic.res` for LAVA integration

## Prerequisites

- `kms_atomic` binary from the IGT GPU tools package (default: `/usr/libexec/igt-gpu-tools/kms_atomic`)
- Write access to the test directory

## Directory Structure

```
Runner/
└── suites/
    └── Multimedia/
        └── Display/
            └── igt-gpu-tools/
                └── kms_atomic/
                    ├── run.sh
                    ├── kms_atomic.yaml
                    └── README.md
```

## Usage

**Method 1: Default subtest filter**
```bash
./run.sh --kms-atomic-path /usr/libexec/igt-gpu-tools/kms_atomic
```

**Method 2: Custom subtest filter**
```bash
./run.sh --kms-atomic-path /usr/libexec/igt-gpu-tools/kms_atomic --run-subtest '*,!*test*,!*immutable*'
```

**Method 3: Positional argument**
```bash
./run.sh /usr/libexec/igt-gpu-tools/kms_atomic
```

**Method 4: Environment variable override**
```bash
IGT_TIMEOUT=600 ./run.sh
```

**Method 5: Help**
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
| `kms_atomic_log.txt` | Full stdout/stderr from the IGT binary |
| `kms_atomic.res` | Final result: `kms_atomic PASS`, `FAIL`, or `SKIP` |

## Subtest Filter

The default filter `*,!*test*,!*immutable*` runs all subtests except those containing `test` or `immutable` in their name. These are excluded because:
- `*test*` subtests exercise internal IGT test infrastructure
- `*immutable*` subtests require properties that are locked after the first atomic commit

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
./run-test.sh kms_atomic /usr/libexec/igt-gpu-tools/kms_atomic
```

## Example Output

```
[INFO] -------------------Starting kms_atomic Testcase-----------------------------
[INFO] Using kms_atomic binary at: /usr/libexec/igt-gpu-tools/kms_atomic
[INFO] Running with subtest pattern: *,!*test*,!*immutable* (timeout: 300s)
[INFO] Logs written to: .../kms_atomic_log.txt
[INFO] Subtest Results: SUCCESS=8, FAIL=0, SKIP=2, TOTAL=10
[PASS] kms_atomic : Test Passed - 8 subtest(s) succeeded, 2 skipped
[INFO] -------------------Completed kms_atomic Testcase----------------------------
