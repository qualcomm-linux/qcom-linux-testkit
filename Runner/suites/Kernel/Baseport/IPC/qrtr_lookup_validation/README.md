# qrtr-lookup Validation Test

## Overview
This script verifies the existence of Qualcomm IPC Router (QRTR) services on a Linux target. It utilizes the `qrtr-lookup` command to scan for active nodes and validates that specific subsystems (ADSP, CDSP, Modem, etc.) are up and registered with the correct Instance IDs.

## Prerequisites
*   **Target Device:** Qualcomm Linux Device (e.g., QCS6490, QCS9100, etc.)
*   **Software:** `qrtr-lookup` binary must be installed and in the system `$PATH`.
*   **Shell:** Standard `/bin/sh` or `/bin/bash`.

## Usage

### 1. Default Mode (ADSP Root)
### 1. Default Mode (Any Service Scan)
Running the script without arguments will scan for **any** active service labeled "Test service" in the `qrtr-lookup` output. The test passes if **at least one** service is found.
```bash
./run.sh

### 2. Targeted Mode (Recommended)
Use the `-t` flag to check a specific subsystem by name. This handles ID mapping automatically.
```bash
./run.sh -t <target_name>
```
**Examples:**
```bash
./run.sh -t audio      # Checks ADSP Audio PD (ID 33)
./run.sh -t adsp root      # Checks ADSP Root PD (ID 32)
./run.sh -t cdsp       # Checks CDSP Root (ID 64)
./run.sh -t wpss       # Checks WPSS (ID 128)
./run.sh -t gpdsp0       # Checks GPDSP0 (ID 112)
```

### 3. Manual Override
Use the `-i` flag if you need to check a specific Instance ID that is not yet mapped in the script.
```bash
./run.sh -i 99
```

## Supported Targets
The following aliases are supported via the `-t` flag:

| Subsystem | Target Names (Case Insensitive) | Instance ID |
| :--- | :--- | :--- |
| **ADSP** | `adsp`, `adsp-root` | **32** (Default) |
| **ADSP Audio** | `audio`, `adsp-audiopd` | **33** |
| **ADSP Sensor** | `sensor`, `adsp-sensorpd` | **34** |
| **ADSP Charger** | `charger`, `adsp-chargerpd` | **35** |
| **CDSP** | `cdsp` | **64** |
| **CDSP 1** | `cdsp1` | **72** |
| **GPDSP 0** | `gpdsp0`, `gpdsp0-root` | **112** |
| **GPDSP 0 User**| `gpdsp0-user` | **113** |
| **GPDSP 1** | `gpdsp1`, `gpdsp1-root` | **120** |
| **GPDSP 1 User**| `gpdsp1-user` | **121** |
| **WPSS** | `wpss` | **128** |
| **SOC CP** | `soccp` | **141** |
| **DCP** | `dcp` | **142** |
| **MODEM** | `mpss`, `modem` | **5** |
| **MODEM OEM** | `mpss-oempd`, `modem-oempd` | **6** |

## Outputs
*   **Console:** Prints `PASS` or `FAIL` with details about the found ID.
*   **Result File:** Generates `qrtr-lookup_validation.res` in the current directory containing:
    *   `qrtr-lookup_validation PASS`
    *   `qrtr-lookup_validation FAIL`

## LAVA Integration
To include this in a LAVA test definition (`.yaml`), simply call the script multiple times for the subsystems you wish to validate:

\`\`\`yaml
run:
  steps:
    - chmod +x run.sh
    - ./run.sh            # Validates ADSP Root (Default)
    - ./run.sh -t audio   # Validates Audio
    - ./run.sh -t cdsp    # Validates CDSP
    - ./run.sh -t cdsp1    # Validates CDSP1
    - ./run.sh -t gpdsp0    # Validates GPDSP0
    - ./run.sh -t gpdsp1    # Validates GPDSP1
    - ./run.sh -t gpdsp0-user    # Validates GPDSP0 User PD
    - ./run.sh -t gpdsp1-user    # Validates GPDSP1 User PD
    - ./run.sh -t mpss    # Validates Modem Root
    - ./run.sh -t mpss-oempd    # Validates Modem OEM PD
\`\`\`
