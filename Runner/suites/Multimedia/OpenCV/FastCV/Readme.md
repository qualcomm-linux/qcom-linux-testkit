# FastCV OpenCV SFM Validation Test

This test validates the OpenCV Structure from Motion (SFM) module functionality using the FastCV framework on Qualcomm platforms with Yocto builds.

## Overview

The test script performs the following functional checks:

1. **Filesystem Preparation**  
   - Resizes the root filesystem partition to ensure sufficient space using `resize2fs`.

2. **Binary Permissions**  
   - Sets executable permissions for OpenCV binaries located in `/usr/bin/FastCV` and `/usr/bin`.

3. **Package Installation**  
   - Installs required `.ipk` packages from `/usr/bin/FastCV/opencv` using `opkg`

4. **Test Execution**  
   - Runs the OpenCV SFM test suite with performance parameters:
     ```
     OPENCV_TEST_DATA_PATH=/usr/bin/FastCV/testdata/ /usr/bin/opencv_test_sfm --perf_min_samples=10 --perf_force_samples=10
     ```

5. **Validation**  
   - Parses the test output to confirm that all 19 tests have passed.

## How to Run

source init_env
cd suites/Vision/FunctionalArea/FastCV
./run.sh


## Prerequisites

- `resize2fs`, `opkg`, and OpenCV binaries must be available on the target device
- Root access is required for resizing partitions and setting permissions
- Test data must be present at `/usr/bin/FastCV/testdata/`
- `.ipk` packages should be available in `/usr/bin/FastCV/opencv/`

## Result Format
Test result will be saved in fastCV.res as:

- OpenCV test suite passed successfully. `[  PASSED  ] 19 tests` – if all validations pass
- OpenCV test suite failed or incomplete. Test output did not match expected results. – if any check fails

## License

SPDX-License-Identifier: BSD-3-Clause-Clear
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.