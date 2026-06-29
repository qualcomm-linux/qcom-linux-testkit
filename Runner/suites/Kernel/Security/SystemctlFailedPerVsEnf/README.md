## SystemctlFailedPerVsEnf — Systemd Service Failures vs. SELinux Mode

## Overview

Compares the list of failed `systemd` services when SELinux is in 'Permissive' mode versus 'Enforcing' mode. The test is designed to identify services that fail to start specifically due to SELinux policy restrictions.

## What Is Tested

| Check | Description |
|---|---|
| Service Failures (Permissive) | Captures a list of all `systemd` units in a 'failed' state while SELinux is set to 'Permissive'. |
| Service Failures (Enforcing) | Captures a list of all `systemd` units in a 'failed' state while SELinux is set to 'Enforcing'. |
| Comparison | Compares the two lists to see if there are any differences. |

## Pass / Fail / Skip Criteria

- **SKIP**: One or more required command-line utilities are missing.
- **FAIL**: The list of failed services is different between 'Permissive' and 'Enforcing' modes. This indicates that SELinux policy is likely causing one or more services to fail.
- **PASS**: The list of failed services is identical in both 'Permissive' and 'Enforcing' modes, indicating no service failures are directly attributable to the change in SELinux mode.

## Usage

```sh
./run.sh
```

## Dependencies

- `getenforce`
- `setenforce`
- `systemctl`
- `grep`
- `awk`