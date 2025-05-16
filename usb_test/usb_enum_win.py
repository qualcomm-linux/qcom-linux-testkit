import time
import subprocess

def check_device_status(pid):
    # Run the devcon status command with the given PID
    command = f'devcon status *{pid}*'
    result = subprocess.run(command, capture_output=True, universal_newlines=True, stdin=subprocess.DEVNULL,shell=True)
    out, err = result.stdout, result.stderr
    if out.find("The device has the following problem") != -1:
        print("DUT Not properly enumerated. Might be some yellow bang on PCs Device Manager or still taking time to enumerate:{}".format(out))
        print('Checking for 2nd time after waiting for 10 sec')
        time.sleep(10)
        result = subprocess.run(command, capture_output=True, universal_newlines=True, stdin=subprocess.DEVNULL,shell=True)
        out, err = result.stdout, result.stderr
        if out.find("The device has the following problem") != -1:
            print("DUT Not properly enumerated. Surely be some yellow bang on PCs Device Manager:{}".format(out))
            return False
        elif out.find("Driver is running") != -1:
            print("DUT is properly enumerated")
            return True
        else:
            print("DUT is not found")
            print(out)
            return False
    elif out.find("Driver is running") != -1:
        print("DUT is properly enumerated")
        return True
    else:
        print("DUT is not found")
        print(out)
        print('Checking for 2nd time after waiting for 10 secs')
        time.sleep(10)
        result = subprocess.run(command, capture_output=True, universal_newlines=True, stdin=subprocess.DEVNULL,shell=True)
        out, err = result.stdout, result.stderr
        if out.find("The device has the following problem") != -1:
            print("DUT Not properly enumerated. Surely be some yellow bang on PCs Device Manager:{}".format(out))
            return False
        elif out.find("Driver is running") != -1:
            print("DUT is properly enumerated")
            return True
        else:
            print("DUT is not found")
            print(out)
            return False

if __name__ == "__main__":
    pid = input("Enter the PID of the device: ")
    check_device_status(pid)
