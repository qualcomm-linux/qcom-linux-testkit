# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#!/bin/bash

# Function to check if systemd is running with PID 1
check_systemd_pid() {
    if [ "$(ps -p 1 -o comm=)" == "systemd" ]; then
        echo "PASS: Check systemd PID"
    else
        echo "FAIL: Check systemd PID"
    fi
}

# Function to check if systemctl stop command works for systemd-user-sessions.service
check_systemctl_stop() {
    systemctl stop systemd-user-sessions.service
    if systemctl is-active --quiet systemd-user-sessions.service; then
        echo "FAIL: Systemctl Stop Service"
    else
        echo "PASS: Systemctl Stop Service"
    fi
}

# Function to check if systemctl start command works for systemd-user-sessions.service
check_systemctl_start() {
    systemctl start systemd-user-sessions.service
    if systemctl is-active --quiet systemd-user-sessions.service; then
        echo "PASS: Systemctl Start Service"
    else
        echo "FAIL: Systemctl Start Service"
    fi
}

# Function to check for any failed services and print them
check_failed_services() {
    failed_services=$(systemctl --failed --no-legend --plain | awk '{print $1}')
    if [ -z "$failed_services" ]; then
        echo "PASS: Check failed services"
    else
        echo "FAIL: Check failed services"
        echo "$failed_services"
    fi

}

# Call the functions
check_systemd_pid
check_systemctl_stop
check_systemctl_start
check_failed_services

