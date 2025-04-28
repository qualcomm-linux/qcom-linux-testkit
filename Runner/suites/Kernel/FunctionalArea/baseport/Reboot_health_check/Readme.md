Overview

This script automates a full reboot validation and health check for any embedded Linux system.
It ensures that after each reboot, the system:

Boots correctly to shell

Key directories (/proc, /sys, /tmp, /dev) are available

Kernel version is accessible

Networking stack is functional


It supports auto-retry on failures, with configurable maximum retries.

No dependency on cron, systemd, Yocto specifics — purely portable.


---

Features

Automatic setup of a temporary boot hook

Reboot and post-boot health validations

Detailed logs with PASS/FAIL results

Auto-retry mechanism up to a configurable limit

Safe cleanup of temp files and hooks after success or failure

Color-coded outputs for easy reading

Lightweight and BusyBox compatible



---

Usage

Step 1: Copy the script to your device

scp reboot_health_check_autoretry.sh root@<device_ip>:/tmp/

Step 2: Make it executable

chmod +x /tmp/reboot_health_check_autoretry.sh

Step 3: Run the script

/tmp/reboot_health_check_autoretry.sh

The script will automatically:

Create a flag and self-copy to survive reboot

Setup a temporary /etc/init.d/ hook

Force reboot

On reboot, validate the system

Retry if needed



---

Log File

All outputs are stored in /tmp/reboot_test.log

Summarizes all individual tests and overall result



---

Configuration

Modify these inside the script if needed:


---

Pass/Fail Criteria


---

Limitations

Requires basic /bin/sh shell (ash, bash, dash supported)

Needs writable /tmp/ and /etc/init.d/

Does not rely on systemd, cron, or external daemons



---

Cleanup

Script automatically:

Removes temporary boot hook

Deletes self-copy after successful completion

Cleans retry counters


You don't need to manually intervene.


---

Example Run Output

2025-04-26 19:45:20 [START] Reboot Health Test Started
2025-04-26 19:45:21 [STEP] Preparing system for reboot test...
2025-04-26 19:45:23 [INFO] System will reboot now to perform validation.
(reboots)

2025-04-26 19:46:10 [STEP] Starting post-reboot validation...
2025-04-26 19:46:11 [PASS] Boot flag detected. System reboot successful.
2025-04-26 19:46:12 [PASS] Shell is responsive.
2025-04-26 19:46:12 [PASS] Directory /proc exists.
2025-04-26 19:46:12 [PASS] Directory /sys exists.
2025-04-26 19:46:12 [PASS] Directory /tmp exists.
2025-04-26 19:46:12 [PASS] Directory /dev exists.
2025-04-26 19:46:12 [PASS] Kernel version: 6.6.65
2025-04-26 19:46:13 [PASS] Network stack active (ping localhost successful).
2025-04-26 19:46:13 [OVERALL PASS] Reboot + Health Check successful!

