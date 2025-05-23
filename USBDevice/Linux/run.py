# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

import os

def check_enum(pid):
	command = f'lsusb | grep -i {pid}'
	if(os.system(command) == 0):
		print("USB is properly enumerated")
        return True
	else:
		print("USB enumeration failed!")
        return False

if __name__ == "__main__":
    pid = input("Enter USB PID to check enumeration: ")
    if check_enum(pid):
        print("[PASS] USB Device Enumeration in {} is successful".format(pid))
    else:
        print("[FAIL] USB Device Enumeration in {} has failed".format(pid))