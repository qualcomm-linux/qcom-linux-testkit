import os

def check_device_status(pid):
	command = f'lsusb | grep -i {pid}'
	if(os.system(command) == 0):
		print("DUT is properly enumerated")
        return True
	else:
		print("DUT is not found")
        return False

if __name__ == "__main__":
    pid = input("Enter the PID of the device: ")
    check_device_status(pid)