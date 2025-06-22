# Reboot Health Check Test

This test automates a full reboot validation and health check for an embedded Linux system. It ensures that after a reboot, the system:

- Boots into a stable shell
- Key filesystems (`/proc`, `/sys`, `/tmp`, `/dev`) are accessible
- Kernel version is accessible
- Networking stack is functional

This script is useful for validating device boot health as part of CI, flashing, or kernel testing workflows.

---

## Overview

The test script performs the following functional checks:

1. **Boot Validation**
   - Ensures the system boots into a stable shell.

2. **Filesystem Accessibility**
   - Confirms that key filesystems (`/proc`, `/sys`, `/tmp`, `/dev`) are accessible.

3. **Kernel Version Check**
   - Verifies that the kernel version is accessible.

4. **Networking Stack Verification**
   - Checks that the networking stack is functional.

---
## Files Used

| File / Path                                      | Description                                                                 |
|--------------------------------------------------|-----------------------------------------------------------------------------|
| `run.sh`                                         | Main script to execute the reboot validation test                          |
| `/var/reboot_health/`                            | Directory to store log and retry-related files                             |
| `/var/reboot_health/reboot_test.log`             | Persistent log file for all test outputs                                   |
| `/var/reboot_health/reboot_retry_count`          | File storing number of reboot retries (used internally)                    |
| `/var/reboot_marker`                             | Temporary marker to differentiate pre- and post-reboot states              |
| `/etc/systemd/system/reboot-health.service`      | systemd service file to autostart reboot health check after boot           |
| `/var/common/reboot_health_check.sh`             | Actual reboot validation script that is called on system boot              |

---


---
## Service setup:
1. Copy the `reboot-health.service` file to:
Enable the service:
systemctl`enable reboot-health.service`
---

---
## Manual Run Instructions:

1. **make the script excuetable**
    `chmod +x run.sh`

2. **Run the test using:**
   `./run-test.sh Reboot_health_check`
---

---
## Sample output:
```text
[2025-05-22 18:11:00] [START] Reboot Health Test Started
[2025-05-22 18:11:00] [INFO] Reboot marker not found. Rebooting now...
Rebooting...

...system reboots...

[2025-05-22 18:11:10] [START] Reboot Health Test Started
[2025-05-22 18:11:10] [PASS] System booted successfully and root shell obtained.
[2025-05-22 18:11:10] [OVERALL PASS] Reboot + Health Check successful!
```
---
---
## Notes:
```text
The device takes approximately 10 seconds to reach shell after reboot.
Log file is persistent and accumulates output from all runs.
You can manually clear logs using:
 `rm -f /var/reboot_health/reboot_test.log`
```
---
## License:
```text
SPDX-License-Identifier: BSD-3-Clause-Clear
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.
```

