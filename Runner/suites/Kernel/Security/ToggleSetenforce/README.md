## ToggleSetenforce — SELinux Mode Toggling Validation

## Overview

Validates that the SELinux mode can be successfully toggled between 'Permissive' and 'Enforcing' using the `setenforce` command.

## What Is Tested

| Check | Description |
|---|---|
| Set to Permissive | The test executes `setenforce 0` and verifies that the system switches to 'Permissive' mode. |
| Set to Enforcing | The test executes `setenforce 1` and verifies that the system switches to 'Enforcing' mode. |
| Restore Default Mode | After testing, the script restores the original SELinux mode. |

## Pass / Fail / Skip Criteria

- **SKIP**: The `getenforce` or `setenforce` command is not available.
- **FAIL**: The script fails to change the mode to 'Permissive' or 'Enforcing' as expected.
- **PASS**: The script successfully toggles the SELinux mode to 'Permissive' and then to 'Enforcing'.

## Usage

```sh
./run.sh
```

## Dependencies

- `getenforce`
- `setenforce`