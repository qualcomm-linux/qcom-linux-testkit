# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# 🛠️ Contributing to qcom-linux-testkit

Thank you for considering contributing to the **qcom-linux-testkit** project! Your contributions help improve the quality and functionality of our test suite. Please follow the guidelines below to ensure a smooth contribution process.

---

## 📋 Contribution Checklist

Before submitting a PR, please ensure the following:

- [ ] **Branching**: Create your feature or fix branch from the latest `main` branch.
- [ ] **Descriptive Commits**: Write clear and concise commit messages. 
- [ ] **ShellCheck Compliance**: Run ShellCheck on all modified shell scripts and address any warnings or errors.
- [ ] **Functionality**: Verify that your changes do not break existing functionality.
- [ ] **Documentation**: Update or add documentation as necessary.
- [ ] **Testing**: Add or update tests to cover your changes, if applicable.

---

## 🧪 Running ShellCheck

We use [ShellCheck](https://www.shellcheck.net/) to analyze shell scripts for common mistakes and potential issues.

### Installation

You can install ShellCheck using your package manager:

- **macOS**: `brew install shellcheck`
- **Ubuntu/Debian**: `sudo apt-get install shellcheck`
- **Fedora**: `sudo dnf install ShellCheck`
- **Arch Linux**: `sudo pacman -S shellcheck`

### Usage

To analyze a script:

```bash
shellcheck path/to/your_script.sh
```

Address all warnings and errors before submitting your PR. If you need to disable a specific ShellCheck warning, use:

```sh
# shellcheck disable=SC1090
```

---

## 📂 Test Suite Structure & Pseudocode Guidelines

Each test suite must follow the standard structure shown below and include a `run.sh` script that:

- Sources `init_env` and `functestlib.sh`
- Sets `TESTNAME`
- Finds the test directory dynamically
- Logs results using `log_pass`, `log_fail`, and outputs a `.res` file

### Directory Structure

```
Runner/
├── suites/
│   └── Kernel/
│       └── FunctionalArea/
│           └── baseport/
│               └── Foo_Validation/
│                   ├── run.sh
│                   └── enabled_tests.list (optional)
├── utils/
│   ├── init_env
│   └── functestlib.sh
```

### Pseudo `run.sh` Template

```sh
#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
#Source init_env and functestlib.sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Foo_Validation"
test_path=$(find_test_case_by_name "$TESTNAME") || {
    log_fail "$TESTNAME : Test directory not found."
    echo "FAIL $TESTNAME" > "./$TESTNAME.res"
    exit 1
}

cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"

log_info "Starting $TESTNAME"

# Run test logic
if run_some_check_or_command; then
    log_pass "$TESTNAME: passed"
    echo "PASS $TESTNAME" > "$res_file"
else
    log_fail "$TESTNAME: failed"
    echo "FAIL $TESTNAME" > "$res_file"
fi
```

### `.res` File Requirements

Each `run.sh` **must generate** a `.res` file in the same directory:

- **File Name**: `<TESTNAME>.res`
- **Content**:
  - `PASS <TESTNAME>` on success
  - `FAIL <TESTNAME>` on failure
  - `SKIP <TESTNAME>` if not applicable

This is essential for CI/CD to parse test outcomes.

### Logging Conventions

Use logging functions from `functestlib.sh`:
```sh
log_info "Preparing test"
log_pass "Test completed successfully"
log_fail "Test failed"
log_error "Setup error"
log_skip "Skipped due to condition"
```

---

## 📄 Licensing

Ensure that all new files include the appropriate license header:

```sh
#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause```

---

## 📬 Submitting a Pull Request

1. **Fork** the repository and create your feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Commit** your changes with clear messages:
   ```bash
   git commit -m "feat: add new feature"
   ```

3. **Push** to your fork:
   ```bash
   git push origin feature/your-feature-name
   ```

4. **Open a Pull Request**: Navigate to the original repository and open a PR from your forked branch.

Please ensure that your PR description includes:

- A summary of the changes made.
- The reason for the changes.
- Any relevant issues or discussions.

---

## 🤝 Code of Conduct

We are committed to fostering a welcoming and respectful community. Please adhere to our [Code of Conduct](docs/CODE_OF_CONDUCT.md) in all interactions.

---

Thank you for contributing to **qcom-linux-testkit**!


---

## 🗂️ Test Organization Guidelines

### Directory Placement

- Kernel-level tests → `Runner/suites/Kernel/FunctionalArea/`
- Multimedia tests → `Runner/suites/Multimedia/`
- Shared test utilities or binaries → `Runner/common/`

### Script Naming

- Main test launcher must be named `run.sh`
- Helper scripts should use lowercase with underscores, e.g. `validate_cache.sh`
- Avoid spaces or uppercase letters in filenames

---

## ⏱️ Test Execution & Timeout Guidelines

- Tests must be self-contained and deterministic
- Long-running tests should support intermediate logging or status messages
- Do not rely on `/tmp` or external mounts
- Scripts must **fail fast** on invalid setup or missing dependencies

---

## 📄 Supported Test Artifacts

Optional per-suite files:
- `enabled_tests.list`: whitelist of subtests to run
- `*.log`: output logs from each run; should reside in the same directory
- `*.res`: REQUIRED file that indicates test result in CI/CD

### .res File Format

Valid output examples:
```
PASS Foo_Validation
FAIL Foo_Validation
SKIP Foo_Validation (missing dependency)
```

This format ensures automated tools and LAVA jobs can collect test outcomes.

---

## 🧩 Shell Compatibility

All scripts must run in POSIX `sh`. **Avoid Bash-only features**, including:

- `local` keyword (use plain assignment)
- `[[ ... ]]` conditions (use `[ ... ]`)
- Arrays
- Bash-style arithmetic without quoting (`$(( ))`)
- Here-strings or `<<<`

Use `#!/bin/sh` in all test scripts and validate with `ShellCheck`.

---

## 🧪 CI Integration Notes

Our CI/CD pipeline expects:
- Each test case to create a `.res` file in the same folder
- No stdout/stderr pollution unless via `log_*` functions
- Proper exit codes (0 for pass, 1 for fail)

All logs should remain local to the suite folder, typically named `*.log`.

---

## 🙋 Questions?

If you're unsure where your test fits or how to structure it, open an issue or tag a maintainer in a draft PR. We're happy to help guide your first contribution.
