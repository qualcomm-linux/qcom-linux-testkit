# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

import time
import subprocess

def check_enum(pid):
    # Run devcon status command with the given PID
    command = f'devcon status *{pid}*'
    result = subprocess.run(command, capture_output=True, universal_newlines=True, stdin=subprocess.DEVNULL,shell=True)
    out, err = result.stdout, result.stderr
    if out.find("The device has the following problem") != -1:
        print("USB is not properly enumerated:{}".format(out))
        print('Retry after 10 secs...')
        time.sleep(10)
        result = subprocess.run(command, capture_output=True, universal_newlines=True, stdin=subprocess.DEVNULL,shell=True)
        out, err = result.stdout, result.stderr
        if out.find("The device has the following problem") != -1:
            print("USB is not properly enumerated. Please check for yellow bang on USB driver in the Device Manager:{}".format(out))
            return False
        elif out.find("Driver is running") != -1:
            print("USB is properly enumerated")
            return True
        else:
            print("USB enumeration failed!")
            print(out)
            return False
    elif out.find("Driver is running") != -1:
        print("USB is properly enumerated")
        return True
    else:
        print("USB enumeration failed!")
        print(out)
        print('Retry after 10 secs...')
        time.sleep(10)
        result = subprocess.run(command, capture_output=True, universal_newlines=True, stdin=subprocess.DEVNULL,shell=True)
        out, err = result.stdout, result.stderr
        if out.find("The device has the following problem") != -1:
            print("USB is not properly enumerated. Please check for yellow bang on USB driver in the Device Manager:{}".format(out))
            return False
        elif out.find("Driver is running") != -1:
            print("USB is properly enumerated")
            return True
        else:
            print("USB enumeration failed!")
            print(out)
            return False

if __name__ == "__main__":
    pid = input("Enter USB PID to check enumeration: ")
    if check_enum(pid):
        print("[PASS] USB Device Enumeration in {} is successful".format(pid))
    else:
        print("[FAIL] USB Device Enumeration in {} has failed".format(pid))