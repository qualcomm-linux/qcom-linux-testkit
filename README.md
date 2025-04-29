Linux Feature Validation Framework

Overview
This repository provides standalone validation scripts designed to test and verify various Linux features, particularly for Qualcomm RB3Gen2 and platforms based on meta-qcom and meta-qcom-distros.
The tests aim to cover functional, sanity, and smoke validations, and can be easily integrated into CI/CD pipelines.

These scripts focus on:
Core Linux kernel functionality validation.
Robust error handling and dynamic environment detection.
Easy extension for continuous integration (CI) frameworks.
Designed to be run directly on target hardware.

---

Intent

Validate Linux kernel and userspace features systematically.
Offer flexibility to run standalone or plug into any CI/CD system.
Cover positive and negative scenarios for strong functional validation.
Support sanity checks, smoke tests, and full system tests.
Minimal dependencies — usable even on minimal Yocto-based images.

---
Usage

Instructions

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to the /var directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to the /var directory on the target device.

3. Run Scripts: Navigate to the /var directory on the target device and execute the scripts as needed.

Run a specific test using:
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:/var
ssh user@target_device_ip 
cd /var/Runner && ./run-test.sh cpufreq
```
Output:
```
[INFO] Starting CPU frequency validation...
[PASS] Core 0 validated successfully
[FAIL] Core 1 failed at frequency setting...
```
> Note: Refer https://docs.qualcomm.com/bundle/publicresource/topics/80-70017-254/how_to.html#use-ssh
---
Features

1. Standalone scripts: Shell scripts and C programs.

2. Extensible: Easily pluggable into any existing CI framework.

3. Cross-Platform: Tested primarily on Yocto images, Qualcomm platforms.

4. Dynamic: Auto-detects hardware interfaces dynamically wherever possible.

5. Strong Error Handling: Failure of any validation immediately flagged.

---

Test Coverage (Examples)

| Area          | Test Type      | Status        |
|---------------|----------------|----------------
| CPU Frequency (cpufreq)  | Functional        | Available |
| Reboot Health Validation | Functional        | Available |
| Audo, USB, Sensors, WiFi, Bluetooth  | Sanity       | Planned |
| Camera, GPS, Ethernet, Touchsceen, Display  | Functional | Planned |

> Note: Coverage is under active enhancement for broader validation.

---

Extending for CI/CD

These standalone tests can be wrapped inside any CI frameworks (like Jenkins, GitLab CI, GitHub Actions).
Sample integration flow:

1. Prepare the DUT (Device Under Test).

2. Copy and launch relevant test scripts.

3. Parse results (stdout/logs).

4. Decide pass/fail status based on outputs.

---

Contributions

Contributions to add more validations, improve robustness, or extend for more platforms are welcome!

Please make sure to sign your commits:
```
git commit -s -m "your commit message"
```

Maintainers

Qualcomm - Initial framework

Future contributors - Enhancements & new validations
