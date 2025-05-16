#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) Qualcomm Technologies, Inc.
 
set -e
 
echo "Running full clean and rebuild..."
 
# Step 1: Clean previous build artifacts
if [ -f Makefile ]; then
    echo " - Running make distclean..."
    make distclean || true
fi
 
# Step 2: Run autogen to regenerate build system files
echo " - Running autogen.sh..."
./autogen.sh
 
# Step 3: Run configure
echo " - Running ./configure..."
./configure
 
# Step 4: Build
echo " - Running make..."
make
 
echo "Rebuild complete."
