# Contributing to qcom-linux-testkit

<!-- Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries. -->
<!-- SPDX-License-Identifier: BSD-3-Clause -->

Contributions can fix existing tests, add focused validation, improve shared
helpers, or update documentation. Start from the latest upstream `main` and
check existing suites and utilities before introducing new logic.

## Place the change in the current structure

Tests live under [Runner/suites](Runner/suites), grouped by area:
`AI_ML`, `Connectivity`, `Kernel`, `Multimedia`, `Performance`, `System`,
and `Virtualization`. Use the relevant existing subdirectory and preserve
case-sensitive suite names.

A new kernel baseport suite would have this structure:

```text
Runner/
  init_env
  run-test.sh
  utils/
    functestlib.sh
    send-to-lava.sh
    lib_*.sh
  suites/
    Kernel/
      Baseport/
        Foo_Validation/
          run.sh
          Foo_Validation.yaml
          README.md
  plans/
```

Every new suite needs its executable `run.sh`, a LAVA YAML definition, and a
README. Include configuration or test assets only when needed. Generated logs,
`.res` files, and local development fixtures do not belong in the contribution.

Search [functestlib.sh](Runner/utils/functestlib.sh) and the other
[shared utilities](Runner/utils) for result, timeout, device, module, service,
and diagnostic helpers. Reuse or extend an existing helper before adding one.
Keep reusable behavior in the relevant library and test orchestration in
`run.sh`. Add unrelated checks as separate suites.

## Initialize the environment and results

Use the following bootstrap for new suites. It finds `Runner/init_env` without
depending on the installation path. The second `init_env` source is intentional.

This starter reports SKIP until real validation is implemented. It is not a
complete test.

```sh
#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
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

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Foo_Validation"
RES_FILE="./$TESTNAME.res"

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

# Replace this placeholder with capability checks and functional validation.
test_result_record SKIP "Validation has not been implemented"
test_result_finish
```

Source additional libraries explicitly after the bootstrap. For example,
OS/package helpers require `lib_pkg_provider.sh` to be sourced separately.
Keep `TESTNAME` immediately before `RES_FILE`, after helper sourcing.

Put command-line usage and argument handling in named functions such as
`usage()` and `parse_args()`, then call `parse_args "$@"`. Validate arguments
before changing DUT state. Document each option and preserve existing defaults
unless the change deliberately updates the interface.

### Result contract

Use `test_result_init`, `test_result_record`, and `test_result_finish` from
`functestlib.sh`. Do not duplicate result writers or PASS/FAIL/SKIP counters.

The default result filename is `<TESTNAME>.res`. Each line has the testcase
identifier first and verdict last:

```text
Foo_Validation PASS
```

Write reasons to logs, not after the verdict in the result line. Use:

- **PASS** when applicable validation actually ran and met its criteria.
- **SKIP** when the test is not applicable or a documented optional dependency,
  asset, or external fixture is absent.
- **FAIL** when an applicable test fails, required runtime setup is broken, or
  execution or parsing cannot establish the expected result.

Missing optional hardware must not produce PASS. Missing evidence on a selected
or applicable device must not be hidden as SKIP. Distinguish lack of support
from a driver, firmware, service, or configuration failure.

`test_result_record` logs the message and updates counters.
Without an explicit verdict, `test_result_finish` selects FAIL if any check
failed, otherwise PASS if any check passed, otherwise SKIP. It writes the result
and exits zero so the next LAVA step can publish it. Complete cleanup before
finalization or through a suitable exit trap. Consumers must read the result
file rather than interpret shell exit zero as PASS.

## Add the LAVA definition

For the example suite, add `Foo_Validation.yaml` alongside `run.sh`:

```yaml
metadata:
  name: foo-validation
  format: "Lava-Test Test Definition 1.0"
  description: "Describe the capability and functional behavior being validated."
  os:
    - linux
  scope:
    - functional
run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Kernel/Baseport/Foo_Validation
    - ./run.sh
    - $REPO_PATH/Runner/utils/send-to-lava.sh Foo_Validation.res
```

Keep repository-path assignment, directory change, invocation, and result
publication as separate steps. Add `params` only for options the script
actually implements, with safe quoting when forwarding values. Match the
result filename to the invocation, including any supported suffix.

Grouped definitions belong in [Runner/plans](Runner/plans). Add a suite to a
plan only when it fits that plan's device and image requirements. LAVA boot and
deployment settings belong in the job definition. Standalone users can invoke
`run.sh` without consuming YAML.

## Preserve portability and DUT state

- Use POSIX `/bin/sh`. Avoid Bash arrays, `[[ ... ]]`, process substitution,
  here-strings, and new uses of `local`. Arithmetic expansion `$(( ... ))` is
  POSIX and is allowed.
- Format functions, conditionals, and argument handling across multiple lines.
  Quote paths and expansions. Keep function documentation adjacent to the
  function without an empty comment line between its signature and description.
- Check behavior on Yocto, Debian, Ubuntu, and CentOS. Do not assume systemd,
  GNU-only utility flags, Python, a package manager, or a full rootfs is present.
  Probe required capabilities and account for BusyBox tools on minimal images.
- Use image-provided components for new tests. Do not add runtime package
  installation. Document dependencies and skip cleanly for optional components
  or assets. Report broken required setup distinctly.
- Discover devices, driver bindings, DT compatibles, routes, and available
  services at runtime. Avoid fixed card numbers, interface names, board lists,
  or module names when the runtime can provide the information.
- Resolve a device-tree root symlink before traversing it with `find`.
  Account for both `/proc/device-tree` and `/sys/firmware/devicetree/base`.
- Use bounded waits and shared timeout helpers. Check command status as well
  as the expected output or artifact. A successful process launch alone is not
  functional validation.
- Snapshot state before changes. Restore only state changed by the test,
  including modules, services, routes, mounts, and device settings. Preserve
  initially active resources and validate first-run and rerun behavior.
- Keep test-owned temporary files and diagnostics under the invocation working
  directory, using unique per-run names where needed. Do not redirect unrelated
  system runtime sockets or firmware paths.
- Keep helper stdout machine-readable when used in command substitution.
  Send diagnostic messages to stderr. Use shared logging helpers for readable
  test progress and include the actual command failure in diagnostics.
- Use `scan_dmesg_errors` with a suite-specific output directory. Retain
  `dmesg_snapshot.log` and `dmesg_errors.log`, and reuse those captured files.
  Do not add direct `dmesg` invocations or pipes in a suite.

Existing suites may predate these conventions. Keep changes focused, preserve
working interfaces, and check all callers affected by shared-library changes.

## Document and validate the change

The suite README should describe prerequisites, supported runtime modes,
permissions and fixtures, CLI defaults and overrides, launch examples, result
and log locations, cleanup, and PASS/FAIL/SKIP conditions. Distinguish driver
coverage on a ramdisk from validation that needs userspace services. Update
examples whenever options or behavior change.

Run checks on the affected files before submission. For a shell file, use the
version and flags from the
[ShellCheck workflow](.github/workflows/shellcheck.yml), currently 0.9.0:

```sh
shellcheck --version
shellcheck -s sh -e SC1091,SC2230,SC3043 -- Runner/suites/Kernel/Baseport/Foo_Validation/run.sh
dash -n Runner/suites/Kernel/Baseport/Foo_Validation/run.sh
git diff --check
git diff --cached --check
```

Replace the example path with each changed script or affected helper. Use narrow,
explained suppressions only when necessary. Also:

- Parse changed YAML and verify its suite path, invocation, result filename,
  and testcase identifier agree with the script.
- Confirm Git records executable shell scripts as `100755` and documentation
  and YAML as `100644`. Use targeted `chmod +x` on Linux or
  `git update-index --chmod=+x <path>` on Windows for intended shell files.
  Preserve existing modes on unrelated files.
- Validate applicable runtime paths, missing dependencies, invalid arguments,
  timeouts, cleanup, and repeat execution. For shared helpers, exercise the
  affected consumers and distro differences. State which checks ran on hardware
  and which used local fixtures. Do not claim untested platforms passed.
- Keep ad hoc development fixtures outside the repository. Include permanent
  regression tests only when agreed as part of the contribution.
- Inspect the configured [CI workflows](.github/workflows), including Semgrep,
  ShellCheck, executable permissions, and preflight checks. Confirm the checks
  and DCO status for the current PR head before merging. Pending, skipped, or
  unavailable checks are not evidence of a pass.

Host validation tools are separate from DUT dependencies. Documentation-only
changes need link, example, and formatting checks, without running hardware
tests.

## Submit the contribution

Fork the repository and create a branch from the latest upstream `main`.
Assuming `origin` points to your fork and `upstream` points to
`https://github.com/qualcomm-linux/qcom-linux-testkit.git`:

```sh
git fetch upstream
git switch -c descriptive-change upstream/main
```

Keep commits focused. When both a shared library and suite consumers change,
use separate coherent commits where practical so the behavior can be reviewed
and reverted independently.

Include the appropriate copyright and SPDX license header in new files,
following [LICENSE](LICENSE) and neighboring files. Sign off each commit for
the [Developer Certificate of Origin](https://developercertificate.org/):

```sh
git add Runner/suites/Kernel/Baseport/Foo_Validation
git commit -s -m "Add Foo validation"
git log --format=full upstream/main..HEAD
git push -u origin descriptive-change
```

Verify every outgoing commit has a valid `Signed-off-by` trailer, including
after an amend or rebase. Open a pull request against `main` with a title and
description explaining why it is needed and what it fixes or adds. Link the
relevant issue. Use a draft while required validation remains outstanding.

For questions about scope or placement, open a
[GitHub issue](https://github.com/qualcomm-linux/qcom-linux-testkit/issues) or
discuss them in a draft PR.
