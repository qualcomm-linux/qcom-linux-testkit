## AVCDenials — SELinux AVC Denial Log Scan

## Overview

Scans system logs for SELinux Access Vector Cache (AVC) denial messages. This test serves to collect and report any audit denials found, which can indicate SELinux policy issues.

## What Is Tested

| Check | Description |
|---|---|
| Audit Log | Scans `/var/log/audit/audit.log` for lines containing "avc" if the file exists. |
| Kernel Log | Scans the output of the `dmesg` command for lines containing "avc". |

## Pass / Fail / Skip Criteria

- **SKIP**: No audit source is available (neither `/var/log/audit/audit.log` nor the `dmesg` command are found) or dependencies like `grep` are missing.
- **FAIL**: This test does not fail. It is designed to report data.
- **PASS**: The test always passes after logging any found AVC denials to `avc_denials.txt`. Its purpose is data collection, not strict validation.

## Usage

```sh
./run.sh
```

## Dependencies

- `grep`
- `dmesg` (or `/var/log/audit/audit.log` as an alternative audit source)