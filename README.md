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

Run a specific test using:
```
./run-test.sh <testname>

<testname> is the name of the script to be executed.

Example:

./run-test.sh cpufreq
./run-test.sh reboot_health
```
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
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
chmod +x run-test.sh
./run-test.sh cpufreq
```
Output:
```
[INFO] Starting CPU frequency validation...
[PASS] Core 0 validated successfully
[FAIL] Core 1 failed at frequency setting...
```
---

Maintainers

Qualcomm - Initial framework

Future contributors - Enhancements & new validations
