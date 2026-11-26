# check_openmp_lib

Checks for the GNU OpenMP runtime library on the DUT. The test runs locally on
the DUT and does not use `adb`.

## What this test checks

The test passes when either runtime path exists and resolves to a regular file:

```text
/usr/lib/libgomp.so.1
/usr/lib/libgomp.so
```

The unversioned `libgomp.so` linker symlink is commonly supplied by development
packages and is not required when the versioned runtime library is present.

## Result semantics

- **PASS** when at least one path exists and resolves to a regular file.
- **FAIL** when neither runtime path is available.

## Output

The test writes `check_openmp_lib.res` in the suite directory.
