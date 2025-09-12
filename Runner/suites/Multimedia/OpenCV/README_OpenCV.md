# OpenCV Test Script for Qualcomm Linux based platform (Yocto)

## Overview

OpenCV Test Scripts automates the validation of one of the OpenCV APIs functionality on the Qualcomm Linux based platform running a Yocto-based Linux system.

## Features

- OpenCV core module - ARITHM API
- accuracy test from ARITHM API

## Prerequisites

Ensure the following components are present in the target Yocto build:

- Compiling the OpenCV Binaries.
- set up the build from Qualcomm Linux buid guide
- To enable the tests package, include tests in PACKAGECONFIG in the
	<workspace>/layers/meta-qcom-hwe/recipes-support/opencv/opencv_4.11.0.qcom.bb recipe file as follows.
	
	PACKAGECONFIG ??= "gapi python3 eigen jpeg png tiff v4l libv4l
	samples tbb gphoto2 tests \
	${@bb.utils.contains("DISTRO_FEATURES", "x11", "gtk", "", d)} \
	
- To retain test bins, include the following code in the
	<workspace>/layers/meta-qcom-hwe/recipes-support/opencv/opencv_4.11.0.qcom.bb recipe file:
	
	RM_WORK_EXCLUDE += "opencv"
	
- To Clean OpenCV, run the below command :
	
	bitbake -fc cleanall opencv
	
- To compile OpenCV, run the following command:
	
	bitbake opencv
	
- The path to OpenCV bins will be below :

	tmp-glibc\work\armv8-2a-qcom-linux\opencv\4.11.0.qcom\build\bin
	
- Use the scp command to push the required test bin to /usr/bin. ( Test bin should be pushed to /usr/bin/ )
	
	For example: scp -r opencv_test_core root@[IP-ADDR]:/usr/bin/


## Directory Structure

```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── OpenCV/
│   │   │    ├── run.sh
      
```

## Usage


Instructions

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to any directory on the target device.

3. Run Scripts: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run a specific test using:
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:/<Path in device>
ssh user@target_device_ip 
cd <Path in device>Runner && ./run-test.sh 
```
Sample output:
```
sh-5.2# cd <Path in device>/Runner && ./run-test.sh OpenCV
[Executing test case: /<Path in device>/Runner/suites/Multimedia/OpenCV/] 1980-01-09 01:31:15 -
[INFO] 1980-01-09 01:31:15 - -----------------------------------------------------------------------------------------
[INFO] 1980-01-09 01:31:15 - -------------------Starting Opencv_core Testcase----------------------------
[INFO] 1980-01-09 01:31:15 - Checking if dependency binary is available
[PASS] 1980-01-08 01:31:15 - Test related dependencies are present.
...
[PASS] 1980-01-09 22:31:16 - Opencv_core : Test Passed
[INFO] 1980-01-09 22:31:16 - -------------------Completed Opencv_core Testcase----------------------------
```

## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.