# Logging_Journalctl_Validation

## Overview

`Logging_Journalctl_Validation` verifies that the system logging pipeline is working correctly after boot.

The testcase checks that:

- required logging tools are available
- `systemd-journald.service` is active
- a readable log sink exists under `/var/log`
- a custom test message can be written using `logger`
- the same test message can be retrieved using `journalctl`
- the same test message is also present in the selected `/var/log` file

This testcase is intended to validate journald and file-based logging behavior on the target system.

---

## Validation Scope

The testcase covers the following:

1. **Tool availability**
   - `journalctl`
   - `systemctl`
   - `logger`
   - `grep`
   - `sed`
   - `awk`
   - `tail`

2. **Journald service validation**
   - verifies that `systemd-journald.service` is active

3. **Log file detection**
   - checks for a readable log sink under `/var/log`
   - supported files include:
     - `/var/log/messages`
     - `/var/log/syslog`
     - `/var/log/user.log`
     - `/var/log/daemon.log`
     - `/var/log/kern.log`

4. **Custom message injection**
   - creates a unique test token
   - emits the message using `logger`

5. **Journal verification**
   - verifies that the emitted message is visible through `journalctl`

6. **File log verification**
   - verifies that the emitted message is present in the detected log file

---

## Prerequisites

Before running the testcase, ensure that:

- the target has booted successfully
- `systemd-journald.service` is available on the target
- `logger` is available
- `journalctl` is available
- at least one readable log file exists under `/var/log`

---

## Test Location

```text
Runner/suites/System/Logging/Logging_Journalctl_Validation/
```

---

## Files

Typical contents of this testcase directory:

```text
run.sh
Logging_Journalctl_Validation.yaml
README.md
```

---

## How to Run

Run the testcase directly:

```sh
cd Runner/suites/System/Logging/Logging_Journalctl_Validation
chmod +x run.sh
./run.sh
```

---

## Optional Environment Variables

The testcase supports the following optional variables:

- `RETRY_COUNT`
  - number of retries used while searching for the injected message
  - default: `5`

- `RETRY_SLEEP_SECS`
  - delay in seconds between retries
  - default: `1`

Example:

```sh
RETRY_COUNT=10 RETRY_SLEEP_SECS=2 ./run.sh
```

---

## Expected Result

### PASS
The testcase passes when:

- required tools are present
- `systemd-journald.service` is active
- a readable `/var/log` file is detected
- the injected test message is found in `journalctl`
- the injected test message is found in the detected log file

### FAIL
The testcase fails when any of the following occurs:

- required tools are missing
- `systemd-journald.service` is not active
- no readable log file is found under `/var/log`
- the test message cannot be emitted
- the test message is not visible through `journalctl`
- the test message is not visible in the selected log file

### SKIP
The testcase is skipped when required runtime dependencies are not available.

---

## Result File

The testcase writes the result to:

```text
Logging_Journalctl_Validation.res
```

Possible values:

```text
Logging_Journalctl_Validation PASS
Logging_Journalctl_Validation FAIL
Logging_Journalctl_Validation SKIP
```

The script is expected to write the result file even when the shell exit code remains `0` for CI/LAVA flow continuity.

---

## Notes

- This testcase does **not** require `/var/log/journal` to exist.
- This testcase is intended to work on systems that use file-based logging under `/var/log`.
- This testcase does **not** validate unrelated failed services.
- This testcase is focused only on journald visibility and log propagation.

---

## Example Checks Performed

Typical validation sequence:

1. detect logging tools
2. verify `systemd-journald.service`
3. identify active log file
4. emit unique test message
5. verify message in `journalctl`
6. verify message in `/var/log/*`

---
