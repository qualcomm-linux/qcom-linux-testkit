# Linux Feature Validation Framework

## Overview

This repository provides standalone validation scripts designed to test and verify various Linux features, particularly for **Qualcomm RB3Gen2** and platforms based on `meta-qcom` and `meta-qcom-distros`.  
The tests aim to cover functional, sanity, and smoke validations and can be easily integrated into CI/CD pipelines.

These scripts focus on:

- Core Linux kernel functionality validation  
- Robust error handling and dynamic environment detection  
- Easy extension for continuous integration (CI) frameworks  
- Designed to be run directly on target hardware  

---

## Intent

- Validate Linux kernel and userspace features systematically  
- Offer flexibility to run standalone or plug into any CI/CD system  
- Cover positive and negative scenarios for strong functional validation  
- Support sanity checks, smoke tests, and full system tests  
- Minimal dependencies — usable even on minimal Yocto-based images  

---

## Usage

### Instructions

1. **Copy repo to Target Device**  
   Use `scp` to transfer the scripts from the host to the target device. The scripts should be copied to the `/var` directory on the target device.

2. **Verify Transfer**  
   Ensure that the repo has been successfully copied to `/var` on the target.

3. **Run Scripts**  
   Navigate to `/var` on the target and execute scripts as needed.

---

### Quick Example

```sh
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@<target_device_ip>:/var
ssh user@<target_device_ip>
cd /var/Runner && ./run-test.sh cpufreq
```

#### Output:

```text
[INFO] Starting CPU frequency validation...
[PASS] Core 0 validated successfully
[FAIL] Core 1 failed at frequency setting...
```

> **Note**: Refer to [Qualcomm SSH Setup Guide](https://docs.qualcomm.com/bundle/publicresource/topics/80-70017-254/how_to.html#use-ssh)

---

## Features

- **Standalone Scripts**: Shell and C-based validation  
- **Extensible**: Easily pluggable into CI frameworks  
- **Cross-Platform**: Tested on Yocto and Qualcomm platforms  
- **Dynamic Detection**: Hardware interfaces detected dynamically  
- **Robust Error Handling**: Failures flagged immediately  

---

## Test Coverage (Examples)

| Area                          | Test Type  | Status     |
|------------------------------|------------|------------|
| CPU Frequency (cpufreq)      | Functional | Available  |
| Reboot Health Validation     | Functional | Available  |
| Audio, USB, Sensors, WiFi, Bluetooth | Sanity     | Planned    |
| Camera, GPS, Ethernet, Touchscreen, Display | Functional | Planned    |

> Coverage is under active enhancement for broader validation.

---

## Extending for CI/CD

These tests can be used as CI jobs in:

- Jenkins  
- GitLab CI  
- GitHub Actions  

**Flow:**
1. Prepare the DUT (Device Under Test)  
2. Copy and launch test scripts  
3. Parse results from `stdout` or logs  
4. Mark pass/fail status  

---

## Maintainers

- **Qualcomm** – Initial framework  
- **Future contributors** – Enhancements and new validations  

---

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
```
