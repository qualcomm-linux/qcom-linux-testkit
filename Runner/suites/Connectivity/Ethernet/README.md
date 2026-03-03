Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# Ethernet Validation Test

## Overview

This test case validates Ethernet connectivity on the target device using the qcom-linux-testkit framework.

Unlike the older `eth0`-only flow, the current test:

- **Auto-detects all Ethernet interfaces** (e.g., `end0`, `eth0`, `enpXsY`, USB dongles, etc.)
- Uses a **fast-path** when the interface already has:
  - Link **UP**, and
  - A **valid non-link-local IPv4**
- Brings the link up using **robust link bring-up fallback** (`ethEnsureLinkUpWithFallback`) to handle ports that may be locked to specific speeds
- Handles IP acquisition in a **manager-aware** way:
  - If **NetworkManager** or **systemd-networkd** is active, it **waits for IP** and does **not** run DHCP client
  - If no manager is active, it uses `try_dhcp_client_safe` for DHCP (with safety checks)
- Validates connectivity via ping (default: `8.8.8.8`) with retries
- Produces both:
  - `Ethernet.res` (PASS/FAIL/SKIP)
  - `Ethernet.summary` (per-interface summary)

## What this test validates

For each auto-detected Ethernet interface:

- Interface presence
- Link status (carrier / Link detected)
- Link bring-up (with fallback)
- IPv4 address availability (non-link-local)
- L3 connectivity using ping to the configured target

## Usage

### Quick Example

```sh
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh Ethernet

Run directly from the test folder

cd Runner/suites/Connectivity/Ethernet
./run.sh
```

Configuration (Env/LAVA)

These parameters can be overridden via environment variables (LAVA params: or shell export):

Variable Default Description

LINK_TIMEOUT_S 5 Max time to wait for link-up (per interface)
IP_TIMEOUT_S 10 Max time to wait for a valid IPv4
PING_TARGET 8.8.8.8 Ping target to validate connectivity
PING_COUNT 4 Ping packets per attempt
PING_WAIT_S 2 Ping timeout (seconds)
PING_RETRIES 3 Ping retry attempts
VERBOSE 0 Enable extra debug output when set to 1


Example:

PING_TARGET=1.1.1.1 IP_TIMEOUT_S=20 PING_RETRIES=5 ./run.sh

Prerequisites

Tools: ip, ping, ethtool

functestlib.sh must be available via init_env

The following kernel config must be enabled, otherwise the test will SKIP:

CONFIG_QCA808X_PHY

> Note: Root access is recommended for full validation and for consistent interface bring-up behavior.

Result Format

Output files

Ethernet.res → single line summary result:

Ethernet PASS

Ethernet FAIL

Ethernet SKIP


Ethernet.summary → per-interface summary lines, e.g.:

end0: PASS (IP: 10.x.x.x, ping OK)

eth0: SKIP (no cable/link; carrier=0)

enp0s1: FAIL (link bring-up failed; carrier=1)



Pass Criteria

At least one Ethernet interface is tested and passes:

Link is UP

Valid non-link-local IPv4 is present

Ping to PING_TARGET succeeds within retry limits



Fail Criteria

One or more interfaces were tested, and none passed.

Examples:

Link bring-up failure when carrier/link indicates a cable is present

Ping failures on all tested interfaces


Skip Criteria

No interfaces were suitable to test (e.g., all were no-link / no-IP / link-local only), or

Required dependencies/config are missing (e.g., ethtool missing, CONFIG_QCA808X_PHY not enabled)


Notes on Network Manager behavior

If NetworkManager or systemd-networkd is active, the test:

waits for IPv4 assignment (wait_for_ip_address)

does not run udhcpc/DHCP client to avoid fighting the manager


If no manager is active, the test uses:

try_dhcp_client_safe <iface> <timeout> (best-effort, safe for minimal images)

Sample Log

[INFO] 1970-01-01 06:12:02 - Auto-detected Ethernet interfaces: end0
[INFO] 1970-01-01 06:12:02 - Network manager detected (NetworkManager/systemd-networkd active): will wait for IP, will NOT run udhcpc.
[INFO] 1970-01-01 06:12:02 - ---- Testing interface: end0 ----
[INFO] 1970-01-01 06:12:02 - Bringing link up with fallback for end0 (timeout=5s)...
[INFO] 1970-01-01 06:12:31 - end0 got IP: 10.142.133.169
[INFO] 1970-01-01 06:12:31 - Ping attempt 1/3: ping -I end0 -c 4 -W 2 8.8.8.8
[PASS] 1970-01-01 06:12:34 - Ethernet connectivity verified via ping
end0: PASS (IP: 10.142.133.169, ping OK)
