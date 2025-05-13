# USB Device mode Validation

## Overview

This folder contains script related to basic USB functionalities.

1) usb_enum_win.py -> To check the enumeration of DUT in Windows host
2) usb_enum_linux.py -> To check the enumeration of DUT in Linux host

## Prerequisites

For Windows
1) Python 3
2) pip install subprocess
3) Devcon

For Linux
1) Python3

## Usage

To run the script: python "filename"

The script will prompt you to enter the PID. Enter the PID according to the variant of the meta.

PID for ADV variant -> 9135
PID for STD variant -> D002
