#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
 
LOG_FILE="/var/reboot_test.log"
MARKER="/var/reboot_marker"
 
echo "[START] Reboot Health Test Started" > $LOG_FILE
 
if [ "$(whoami)" = "root" ]; then
    if [ ! -f "$MARKER" ]; then
        echo "[INFO] Reboot marker not found. Rebooting now..." >> $LOG_FILE
        touch "$MARKER"
        sleep 2
        reboot -f
    else
        echo "[PASS] System booted successfully and root shell obtained." >> $LOG_FILE
        echo "[OVERALL PASS] Reboot + Health Check successful!" >> $LOG_FILE
        rm -f "$MARKER"
    fi
    cat $LOG_FILE
    exit 0
else
    echo "[FAIL] Root shell not available!" >> $LOG_FIle
   cat $LOG_FILE
    exit 1
fi