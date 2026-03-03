Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# WiFi Connectivity Validation

## 📋 Overview

This test validates WiFi functionality by:

- Connecting to an access point (AP) using either `nmcli` or `wpa_supplicant`.
- Verifying IP acquisition via DHCP.
- Checking internet connectivity with a `ping` test.
- Handling systemd network service status.
- Supporting flexible SSID/password input via arguments, environment, or file.

## ✅ SSID/PASSWORD Input Priority (Hybrid Approach)

1. **Command-line arguments**:
   ```sh
   ./run.sh "MySSID" "MyPassword"
   ```

2. **Environment variables**:
   ```sh
   SSID_ENV=MySSID PASSWORD_ENV=MyPassword ./run.sh
   ```

3. **Fallback to `ssid_list.txt` file** (if above not set):
   ```txt
   MySSID MyPassword
   ```

## ⚙️ Supported Tools

- Primary: `nmcli`
- Fallback: `wpa_supplicant`, `udhcpc`, `ifconfig`

Ensure these tools are available in the system before running the test. Missing tools are detected and logged as skipped/failure.

## 🧪 Test Flow

1. **Dependency check** – verifies necessary binaries are present.
2. **Systemd services check** – attempts to start network services if inactive.
3. **WiFi connect (nmcli or wpa_supplicant)** – based on tool availability.
4. **IP assignment check** – validates `ifconfig wlan0` output.
5. **Internet test** – pings `8.8.8.8` to confirm outbound reachability.
6. **Result logging** – writes `.res` file and logs all actions.

## 🧾 Output

- `WiFi_Connectivity.res`: Contains `WiFi_Connectivity PASS` or `FAIL`.
- Logs are printed using `log_info`, `log_pass`, and `log_fail` from `functestlib.sh`.

## 📂 Directory Structure

```
WiFi/
├── run.sh
├── ssid_list.txt (optional)
├── README.md
```

## 🌐 Integration (meta-qcom_PreMerge.yaml)

Add this test with SSID parameters as follows:

```yaml
- name: WiFi_Connectivity
  path: Runner/suites/Connectivity/WiFi
  timeout:
    minutes: 5
  params:
    SSID_ENV: "xxxx"
    PASSWORD_ENV: "xxxx"
```
