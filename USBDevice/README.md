```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear
```

# USB Device Mode Validation

## Overview

This test verifies enumeration of DUT (Device-Under-Test) connected via USB to Host PC.

---

## Setup

- Connect DUT to Host PC via USB.
- Only applicable for USB port(s) on DUT that support Peripheral/Device Mode functionality.

---

## Usage

### Prerequisites

1. Install Python3 on Host PC.

2. The script requires user to input USB PID (Product ID) against which the test checks successful USB enumeration on Host PC. Following is the list of supported PIDs:
```
A4A1    NCM
4EE7    ADB
900E    DIAG
901C    DIAG + UAC2
901D    DIAG + ADB
9015    MASS_STORAGE + ADB
9024    RNDIS + ADB
902A    RNDIS + MASS_STORAGE
902B    RNDIS + ADB + MASS_STORAGE
902C    RNDIS + DIAG
902D    RNDIS + DIAG + ADB
902F    RNDIS + DIAG + MASS_STORAGE
908C    NCM + ADB
90CA    DIAG + UAC2 + ADB
90CB    DIAG + UVC + ADB
90CC    DIAG + UAC2 + UVC + ADB
90DF    DIAG + UVC
90E0    DIAG + UAC2 + UVC
9135    DIAG + QDSS + ADB
9136    DIAG + QDSS
F000    MASS_STORAGE
F00E    RNDIS
```

### Windows

1. **Connect DUT to Windows PC via USB**
	

2. **Execute run.py under USBDevice/Windows directory**  
   Use `python3` to execute run.py script on the Windows host by giving PID (Product ID) as user argument to test USB enumeration of target device.

   
### Example

```py
python3 run.py <USB PID>
```

### Linux

1. **Connect DUT to Linux PC via USB**
	

2. **Execute run.py under USBDevice/Linux directory**  
   Use `python3` to execute run.py script on the Linux host by giving PID (Product ID) as user argument to test USB enumeration of target device.

---


## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
```
