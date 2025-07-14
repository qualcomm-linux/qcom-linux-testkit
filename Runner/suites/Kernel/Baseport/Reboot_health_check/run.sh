#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Reboot_health_check"
cd "$SCRIPT_DIR" || exit 1

LOG_FILE="$SCRIPT_DIR/reboot_test.log"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
MARKER="$SCRIPT_DIR/reboot_marker"
RETRY_FILE="$SCRIPT_DIR/reboot_retry_count"
SERVICE_FILE="/etc/systemd/system/reboot-health.service"
MAX_RETRIES=3

log_info "-------------------- Starting $TESTNAME Test ----------------------------"
log_info "=== Test Initialization ==="

# Initialize retry count
if [ ! -f "$RETRY_FILE" ]; then
    echo "0" > "$RETRY_FILE"
fi
RETRY_COUNT=$(cat "$RETRY_FILE")

# Create systemd service on first run
if [ ! -f "$MARKER" ]; then
    log_info "Creating systemd service and Rebooting..."

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Reboot Health Check Service
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/run.sh
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable reboot-health.service

    touch "$MARKER"
    log_info "System will reboot in 2 seconds..."
    sleep 2
    reboot
    exit 0
fi

log_info "Post-reboot validation"
log_info "Retry Count: $RETRY_COUNT"

pass=true

if ! whoami | grep -q "root"; then
    log_fail "Root shell not accessible"
    pass=false
fi

for path in /proc /sys /dev /tmp; do
    if [ ! -d "$path" ]; then
        log_fail "Missing or inaccessible: $path"
        pass=false
    fi
done

if ! uname -a >/dev/null 2>&1; then
    log_fail "Kernel version not available"
    pass=false
fi

if ! ifconfig >/dev/null 2>&1 && ! ip a >/dev/null 2>&1; then
    log_fail "Networking stack failed"
    pass=false
fi

if $pass; then
    log_pass "$TESTNAME PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
    echo "0" > "$RETRY_FILE"
else
    log_fail "$TESTNAME FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "$RETRY_COUNT" > "$RETRY_FILE"

    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        log_error "Max retries ($MAX_RETRIES) reached. Stopping."
        rm -f "$MARKER"
        exit 1
    else
        log_info "Rebooting for retry #$RETRY_COUNT..."
        sleep 2
        reboot -f
        exit 0
    fi
fi

rm -f "$MARKER"
log_info "------------------- Completed $TESTNAME Test ----------------------------"
exit 0
