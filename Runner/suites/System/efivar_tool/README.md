# efivar_tool_available

Checks that the optional `efivar` tool is installed, executable, and responds
successfully to `--help` on the DUT. The test runs locally on the DUT.

## What this test checks

The test:

1. Locates the `efivar` command.
2. Verifies that its executable file is executable.
3. Runs `efivar --help`, requires a successful exit status, and checks for the
   expected usage text, including `Usage: efivar`.
   The invocation has a five-second deadline; its output is retained in
   `efivar_tool_available.command.log`.

## Requirements

- The `efivar` tool is optional by default. Set the LAVA parameter
  `REQUIRE_EFIVAR=true` when the selected plan requires EFI tooling. The test
  never installs packages at runtime.
- The testkit `Runner` directory, including `init_env` and shared utilities,
  must be kept together.
- The invocation's current directory must be writable for result and log files.

## Scope

This test checks tool availability and basic invocation only. It does not
verify reading, writing, or changing EFI variables, and it does not validate
EFI variable storage or permissions.

## Result semantics

- **PASS** when `efivar` is found, is executable, and prints the expected usage
  output.
- **SKIP** when `efivar` is not installed and `REQUIRE_EFIVAR` is false.
- **FAIL** when it is missing and `REQUIRE_EFIVAR=true` for the selected plan.
- **FAIL** when an installed command is not executable, returns a nonzero
  status, omits the expected usage output, or exceeds its deadline.

## Output

The result is written to:

```text
efivar_tool_available.res
```
