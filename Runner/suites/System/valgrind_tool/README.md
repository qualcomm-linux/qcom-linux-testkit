# valgrind_tool

Checks whether the `valgrind` tool is available on the DUT. This test does not
run Valgrind or check its version.

## What this test checks

The test looks for the `valgrind` command using the DUT's current `PATH`.

## Result semantics

- **PASS** when the `valgrind` command is available.
- **FAIL** when the command cannot be found.

## Output

The test writes its result to:

```text
valgrind_tool.res
```

Expected result format:

```text
valgrind_tool PASS
valgrind_tool FAIL
```
