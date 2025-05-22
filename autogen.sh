#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) Qualcomm Technologies, Inc.

set -e

PROJECT_ROOT=$(dirname "$0")

echo "Starting autotools cleanup and regeneration..."

clean_autotools_files() {
    echo " - Cleaning autotools-generated files..."

    FILE_PATTERNS="Makefile.in Makefile config.* stamp-h1 configure configure~ aclocal.m4 compile install-sh ltmain.sh missing"
    for pattern in $FILE_PATTERNS; do
        find "$PROJECT_ROOT" -name "$pattern" -exec rm -f {} +
    done

    # Remove directories
    find "$PROJECT_ROOT" -name 'autom4te.cache' -type d -exec rm -rf {} +
    find "$PROJECT_ROOT" -name '.deps' -type d -exec rm -rf {} +
}

regenerate_build_system() {
    echo " - Regenerating with autoreconf..."
    autoreconf --install --force --verbose
}

main() {
    clean_autotools_files
    regenerate_build_system
    echo
    echo "Autotools setup complete."
    echo "You can now run:"
    echo " ./configure"
    echo " make"
}

main "$@"
