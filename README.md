Linux Feature Validation Scripts

Overview

This repository provides standalone test scripts aimed at functional validation of key Linux system features.
It focuses on sanity, smoke, and functional testing for environments using Qualcomm kernels, meta-qcom, and meta-qcom-distros Yocto layers.

These scripts are lightweight, extensible, and designed to integrate easily with CI/CD pipelines or run manually for system validation.
The goal is to ensure critical Linux subsystems are operational and behave correctly.


---

Key Features

Standalone scripts — No dependency on specific frameworks.

Functional validation of Linux features like:

CPU Frequency Scaling

Reboot health check

Audio, USB, Sensors, Bluetooth, Wi-Fi, Camera, GPS, Ethernet, Touchscreen, Display, Power management, and more.


Per-feature pass/fail reporting with detailed logs.

Extensible — Scripts can be easily plugged into any CI/CD framework.

Error Handling — Robust detection and logging of failures.

Support for Yocto-based Systems — Especially with meta-qcom and meta-qcom-distros.



---

Usage

To run a specific test:

./run-test.sh <testname>

Where <testname> is the name of the test you want to run (example: cpufreq, reboot_health, etc).

Example:

./run-test.sh cpufreq

The run-test.sh script will dynamically call the appropriate test script, handle basic setup, and consolidate test results.


---

Folder Structure

├── run-test.sh           # Launcher script
├── tests/
│   ├── cpufreq_test.sh    # CPU frequency scaling validation
│   ├── reboot_health.c    # C program to validate reboot health
│   ├── audio_test.sh      # Audio validation script
│   ├── usb_test.sh        # USB validation script
│   └── ...                # Other feature validation scripts
├── results/
│   ├── logs/              # Log files
│   ├── summary.txt        # Test summary (pass/fail per test)
├── README.md              # This file
└── LICENSE


---

Integrating with CI/CD

Scripts are designed to be called independently.

CI pipelines (like GitLab CI, Jenkins, GitHub Actions) can invoke run-test.sh with a specific test or loop through all available tests.

Results can be collected from results/summary.txt and logs for reporting and visualization.

Failures can automatically stop pipelines if configured.


Example CI/CD Pseudocode:

for test in cpufreq reboot_health audio_test usb_test; do
    ./run-test.sh $test || exit 1
done


---

Extending the Framework

Adding a new test:

Write a new script inside the tests/ folder.

Follow the simple pattern: initialize, run checks, output PASS or FAIL.

Update run-test.sh if needed to add the mapping.


Improving validations:

Extend existing scripts with deeper corner case handling, stress tests, or coverage expansion.




---

Requirements

Basic Linux environment.

Root (sudo) permissions (for accessing system files like /sys, /dev, etc).

Compilers/tools installed on-device if needed for C programs (gcc).



---

Targeted Platforms

Qualcomm-based devices (Snapdragon SoCs, automotive, robotics platforms, etc).

Yocto builds using meta-qcom, meta-qcom-distros.

Other Linux distributions after basic compatibility validation.



---

Contribution

Feel free to open issues, suggest improvements, or submit pull requests if you wish to extend or improve the scripts for broader hardware coverage, kernel feature validation, or CI enhancements.
