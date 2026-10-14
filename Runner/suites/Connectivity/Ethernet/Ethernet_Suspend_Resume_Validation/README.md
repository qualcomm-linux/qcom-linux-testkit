# Ethernet_Suspend_Resume_Validation

## Overview

This opt-in testcase validates Ethernet recovery across a system suspend/resume cycle. It verifies that the selected interface remains enumerated with the same driver and device binding, then confirms carrier, IPv4, counters, and network connectivity after resume.

## Safety

The testcase is disabled by default:

```text
ETH_SUSPEND_ENABLE=0
```

Enable it only on a target that has a reliable RTC wake source and an independent control channel such as serial/LAVA console. Running it over the only management Ethernet connection may temporarily disconnect the test harness.

## Prerequisites and infrastructure

- Run as root on a target whose image provides `rtcwake`, `ip`, and `ping`.
- Verify that the selected `ETH_RTC_DEVICE` can wake the board from the chosen
  `ETH_SUSPEND_MODE` before enabling automation.
- Keep an independent serial or LAVA control channel available for recovery.
- Connect the tested Ethernet port to an active link partner and configure
  IPv4 plus a reachable gateway or `PING_TARGET`.
- Do not enable this testcase when loss of the tested Ethernet connection would
  also remove the only control path to the target.

## Coverage

- pre-suspend carrier and IPv4 readiness
- MAC driver and device binding snapshot
- RTC-triggered suspend/resume
- post-resume interface enumeration
- unchanged driver/device binding
- carrier recovery
- IPv4 recovery
- interface-bound ping after resume
- statistics-node readability
- Ethernet-related kernel health scan after resume

## Configuration

CLI options override environment variables.

| CLI option | Environment variable | Default | Description |
|---|---|---:|---|
| `--enable` | `ETH_SUSPEND_ENABLE` | `0` | Explicit opt-in |
| `--interface` | `ETH_SUSPEND_INTERFACE` | automatic | Interface to validate |
| `--suspend-seconds` | `ETH_SUSPEND_SECONDS` | `30` | Suspend interval |
| `--suspend-mode` | `ETH_SUSPEND_MODE` | `mem` | Mode passed to `rtcwake -m` |
| `--rtc-device` | `ETH_RTC_DEVICE` | `/dev/rtc0` | RTC wake device |
| `--resume-timeout` | `ETH_RESUME_TIMEOUT_S` | `30` | Carrier and IPv4 recovery timeout |
| `--link-timeout` | `LINK_TIMEOUT_S` | `10` | Pre-suspend carrier timeout |
| `--ip-timeout` | `IP_TIMEOUT_S` | `20` | Pre-suspend IPv4 timeout |
| `--ping-target` | `PING_TARGET` | automatic | Gateway or `8.8.8.8` |
| `--ping-count` | `PING_COUNT` | `5` | Connectivity packet count |
| `--ping-wait` | `PING_WAIT_S` | `2` | Per-packet timeout |

Example:

```sh
./run.sh --enable 1 --interface eth0 --suspend-seconds 30
```

Omit `--interface` to use the first interface returned by the shared physical
Ethernet discovery helper.

## Result

```text
Ethernet_Suspend_Resume_Validation.res
Ethernet_Suspend_Resume_Validation.results.tsv
rtcwake.log
dmesg/dmesg_snapshot.log
dmesg/dmesg_errors.log
```

## Failure diagnostics

Recorded failures automatically save read-only `ethtool` evidence for the
selected interfaces and replay bounded excerpts to stdout with `[ETH-DIAG]`
markers. No host commands, runtime package installation or new options are
required. The original verdict and cleanup behavior remain unchanged.
See [shared Ethernet failure diagnostics](../README_Ethernet_Diagnostics.md)
for collected queries, artifact locations, time bounds and unavailable-tool handling.
