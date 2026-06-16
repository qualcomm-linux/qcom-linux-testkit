## CheckSestatus — SELinux Status Validation

## Overview

Validates the output of the `sestatus` command to ensure that SELinux is active and running in a valid mode.

## What Is Tested

| Check | Description |
|---|---|
| `sestatus` command | Executes the `sestatus` command to get a detailed report of the SELinux status. |
| Current Mode | Parses the `sestatus` output to verify that the 'Current mode' is either 'enforcing' or 'permissive'. |

## Pass / Fail / Skip Criteria

- **SKIP**: The `sestatus` or `getenforce` command is not available.
- **FAIL**: The `sestatus` output does not report the 'Current mode' as 'enforcing' or 'permissive'.
- **PASS**: The 'Current mode' in the `sestatus` output is confirmed to be either 'enforcing' or 'permissive'.

## Usage

```sh
./run.sh
```

## Dependencies

- `sestatus`
- `getenforce`
- `grep`
- `awk`