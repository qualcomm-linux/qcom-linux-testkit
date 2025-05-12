# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Contributing to the Shell Scripts Repository

Welcome! This repository contains hardware validation shell scripts for Qualcomm embedded robotic platform boards running Linux systems. These scripts follow POSIX standards for maximum portability and integration into CI tools like LAVA.

## Directory Structure

- `Runner/`: Root test harness
- `Runner/utils/`: Shared libraries like `functestlib.sh`
- `Runner/init_env`: Common environment setup
- `Runner/suites/`: Functional test suites organized per feature

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/qualcomm-linux/qcom-linux-testkit.git
   ```

2. Run test suites using:
   ```bash
   ./Runner/run-test.sh
   ```

3. Ensure `init_env` and utilities are sourced using relative paths:
   ```bash
   . "$(dirname "$0")/../../init_env"
   . "$(dirname "$0")/../../utils/functestlib.sh"
   ```

## Style Guidelines

- Shell scripts must be POSIX-compliant (`#!/bin/sh`)
- Avoid Bash-specific syntax
- Validate using `shellcheck -x`
- Use consistent format: colored output, logging, `PASS/FAIL` status

## Commit and PR Guidelines

- One logical change per commit
- Always add sign-off:
  ```bash
  git commit -s -m "Add test for Bluetooth functionality"
  ```

- Mention reviewers if needed and explain validation steps
- PRs should be raised against `main` unless otherwise noted

## License

All contributions must include:
```sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
```

## Questions?

Open an issue or start a discussion under the GitHub Issues tab.
