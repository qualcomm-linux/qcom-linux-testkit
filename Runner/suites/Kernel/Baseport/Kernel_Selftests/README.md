# Kernel Selftest Runner

This directory contains the automation scripts for running **Linux Kernel Selftests** on Qualcomm-based platforms (e.g., RB3GEN2) using the standardized `qcom-linux-testkit` framework.

## Overview

The selftest runner (`run.sh`) is designed to:
- Automatically detect and run enabled kernel selftests using a whitelist file (`enabled_tests.list`)
- Ensure all required dependencies and directories are present
- Log detailed test results for CI/CD integration
- Support both standalone execution and integration with LAVA/automated test infrastructure

## Files

- **run.sh**: Main test runner script. Executes all tests listed in `enabled_tests.list` and produces `.res` and `.run` result files.
- **enabled_tests.list**: Whitelist of test suites or binaries to run (one per line). Supports comments and blank lines.
- **Kernel_Selftests.res**: Detailed result file, capturing PASS/FAIL/SKIP for each test or subtest.
- **Kernel_Selftests.run**: Cumulative PASS or FAIL summary, used by CI pipelines for quick parsing.

## Prerequisites

- `/kselftest` directory must be present on the device/target. This is where the selftest binaries are located (usually deployed by the build or CI).
- All test scripts must have the executable bit set (`chmod +x run.sh`), enforced by GitHub Actions.
- `enabled_tests.list` must exist and contain at least one non-comment, non-blank entry.

## Script Flow

1. **Environment Setup**:  
   Dynamically locates and sources `init_env` and `functestlib.sh` to ensure robust, path-independent execution.

2. **Dependency Checks**:  
   - Checks for required commands (e.g., `find`)
   - Ensures `/kselftest` directory exists
   - Validates `enabled_tests.list` is present and usable

3. **Test Discovery & Execution**:  
   - Parses `enabled_tests.list`, ignoring comments and blanks
   - Supports both directory and subtest (e.g., `timers/thread_test`) entries
   - Executes test binaries or `run_test.sh` for each listed test
   - Logs individual and summary results

4. **Result Logging**:  
   - Writes detailed results to `Kernel_Selftests.res`
   - Writes overall PASS/FAIL to `Kernel_Selftests.run`

5. **CI Compatibility**:  
   - Designed for direct invocation by LAVA or any CI/CD harness
   - Fails early and logs meaningful errors if prerequisites are missing

## enabled_tests.list Format

```text
# This is a comment
timers
thread
timers/thread_test
# Add more test names or subtests as needed
```

- Each non-comment, non-blank line specifies a test directory or a test binary under `/kselftest`.

## Example Usage

```sh
sh run.sh
```

or from a higher-level testkit runner:

```sh
./run-test.sh Kernel_Selftests
```

## Troubleshooting

- **Missing executable bit**:  
  If you see permission errors, ensure all scripts are `chmod +x`.

- **Missing `/kselftest` directory**:  
  Ensure selftests are built and deployed to the target system.

- **Missing or empty `enabled_tests.list`**:  
  Add test entries as needed. The runner will fail if this file is absent or empty.

## Contribution Guidelines

- Update `enabled_tests.list` as test coverage expands.
- Follow the coding and structure conventions enforced by CI (see `CONTRIBUTING.md`).
- All changes should pass permission checks and shellcheck lints in CI.

## License

SPDX-License-Identifier: BSD-3-ClauseCopyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
