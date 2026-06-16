## CheckGetenforce — SELinux Getenforce Validation

## Overview

Validates the `getenforce` command and checks the current SELinux mode to ensure it is either 'Enforcing' or 'Permissive'.

## What Is Tested

| Check | Description |
|---|---|
| `getenforce` command | Verifies the `getenforce` command is available on the system. |
| Current SELinux Mode | Executes `getenforce` to retrieve the current SELinux mode and validates its state. |

## Pass / Fail / Skip Criteria

- **SKIP**: The `getenforce` command is not found.
- **FAIL**: The SELinux mode is 'Disabled' or returns an unknown state.
- **PASS**: The SELinux mode is 'Enforcing' or 'Permissive'.

## Usage

```sh
./run.sh
```

## Dependencies

- `getenforce` command-line utility