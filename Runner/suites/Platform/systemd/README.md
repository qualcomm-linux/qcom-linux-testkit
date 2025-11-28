# systemd Suite

This folder contains test scripts for validating `systemd` functionality on the platform. Particularly for **Qualcomm RB3Gen2** and platforms based on `meta-qcom` and `meta-qcom-distros`.  

## Contents

- **directory/**: Each directory contains individual test script run.sh for specific `systemd` features.
- **README.md**: This documentation file.

## Usage

1. Ensure all dependencies are installed as specified in the root documentation.
2. Run the suite using run-test.sh in root directory Runner/:
    ```
    ./run-test.sh <directory-name>
    for e.g. ./run-test.sh systemdPID
    ```
3. Review the test results stored in file named <directory-name.res> in respective directory.

## Purpose

The `systemd` suite helps maintain reliability by ensuring that service management and related features work as expected on QCOM platforms.

These scripts focus on
- Validate systemctl commands
- Check failed services
- Basic systemd validation
