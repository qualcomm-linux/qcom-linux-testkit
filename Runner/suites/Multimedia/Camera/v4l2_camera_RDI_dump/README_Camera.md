# Camera RDI dump validation using YAVTA App Test Scripts for Qualcomm Linux based platform (Yocto)

## Overview

Camera scripts automates the Camera RDI dump validation using YAVTA App on the Qualcomm Linux based platform running a Yocto-based Linux system.It utilizes yavta and media-ctl binaries which is publicly available 
## Features

- Camera RDI dump validation using YAVTA App
- Compatible with Yocto-based root filesystem

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `yavta and media-ctl` (available in /usr/bin/) 
- To find the exact /dev/media node for our camss driver
  ```
  media-ctl -p -d /dev/media 'y' | grep camss ['y' has to be replaced with media0 or media1 eg: /dev/media0, /dev/media1]

  Output will be # driver   qcom-camss [for probed media]
  ```
- To find list avaliable device files
  ```
  v4l2-ctl --list-devices
  ```
  Output will be # video0 video1 video2 ...
- /dev/video# linking to RDI port is dynamic not fixed , user need to identify the correct video device file(by trail and error) to use in yavta RDI dump command

  'y' has to be replaced eg: /dev/video0, /dev/video1 depending on RDI port configured..
  ```
  yavta -B capture-mplane -c -I -n 5 -f SRGGB10P -s 4056x3040 -F /dev/video'y' --capture=5 --file='frame-#.bin'  
  ```
- camera_node_finder function dynamically detects the active media node and the corresponding video node (e.g., /dev/mediaX and /dev/videoY) for the msm_vfe0_rdi0 entity, enabling automated and adaptable camera pipeline configuration.
  
## Directory Structure

```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Camera/
│   │   │   ├── v4l2_camera_RDI_dump
│   │   │   │   ├── run.sh
│   │   │   ├── README_Camera.md
│   │   │   │    
```

## Usage

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to any directory on the target device.

3. Run Scripts: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run a specific test using:
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip 
cd <Path in device> && chmod +x run.sh && ./run.sh 
```
Sample output:
```
sh-5.2# cd <Path in device>
sh-5.2# ./run.sh
[INFO] 2025-01-09 13:45:22 - -----------------------------------------------------------------------------------------
[INFO] 2025-01-09 13:45:22 - -------------------Starting v4l2_camera_RDI_dump Testcase----------------------------
[INFO] 2025-01-09 13:45:22 - === Test Initialization ===
[INFO] 2025-01-09 13:45:22 - Checking if dependency binary is available
[INFO] 2025-01-09 13:45:22 - -------------------Camera commands execution start----------------------------
Device /dev/v4l-subdev0 opened.
Control 0x009f0903 set to 0, is 0
Device /dev/v4l-subdev0 opened.
Control 0x009f0903 set to 9, is 9
[PASS] 2025-01-09 13:45:23 - v4l2_camera_RDI_dump : Test Passed
[INFO] 2025-01-09 13:45:23 - -------------------Completed v4l2_camera_RDI_dump Testcase----------------------------
```
3. Results will be available in the `Runner/suites/Multimedia/Camera/v4l2_camera_RDI_dump/` directory under each usecase folder.

## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.