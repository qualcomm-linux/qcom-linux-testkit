# core_dump_ulimit

Checks whether the core-dump size limit in the DUT's test shell is unlimited.
The test runs locally on the DUT.

## Test procedure

The test runs:

```sh
ulimit -c
```

It checks the value in the shell that runs the test; it does not change the
limit.

## Result semantics

- **PASS** when `ulimit -c` reports `unlimited`.
- **FAIL** for any other value or if the command cannot be read.

## Output

The test writes `core_dump_ulimit.res` in the suite directory.
