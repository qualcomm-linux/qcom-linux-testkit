#!/bin/sh
# Import test suite definitions
set -x
chmod 777 -R /var/common/*
__RUNNER_UTILS_BIN_DIR="/var/common"
# Find test case path by name
find_test_case_bin_by_name() {
    local test_name="$1"
    find $__RUNNER_UTILS_BIN_DIR -type f -iname "$test_name" 2>/dev/null
}

# Define variables
APP_PATH=$(find_test_case_bin_by_name "reboot_health_check")
APP_DIR=$(readlink -f $APP_PATH)
SERVICE_FILE="/etc/systemd/system/reboot-health.service"

# Colors for console output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m" # No Color

# Function to log
log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Verify app binary exists
if [ ! -f "$APP_PATH" ]; then
    log_error "App binary $APP_PATH not found!"
    exit 1
fi

# Make app binary executable
chmod +x "$APP_PATH"
log_info "Made app binary executable: $APP_PATH"

# Create systemd service file
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Reboot Health Check Service
After=default.target

[Service]
Type=simple
ExecStart=$APP_PATH
StandardOutput=append:$APP_DIR/service_output.log
StandardError=append:$APP_DIR/service_error.log
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

if [ $? -eq 0 ]; then
    log_info "Created systemd service file: $SERVICE_FILE"
else
    log_error "Failed to create systemd service file!"
    exit 1
fi

# Reload systemd
systemctl daemon-reload
log_info "Systemd daemon reloaded."

# Enable and start service
systemctl enable reboot-health.service
if [ $? -eq 0 ]; then
    log_info "Service enabled at boot."
else
    log_error "Failed to enable service!"
    exit 1
fi

systemctl start reboot-health.service
if [ $? -eq 0 ]; then
    log_success "Service started successfully!"
else
    log_error "Failed to start service!"
    exit 1
fi

exit 0
