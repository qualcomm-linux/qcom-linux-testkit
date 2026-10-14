# Ethernet Basic Validation

## Overview

`Ethernet_Basic_Validation` is the basic Ethernet connectivity testcase. It automatically detects physical Ethernet interfaces and validates link readiness, IPv4 assignment, and interface-bound ping connectivity.

The testcase is driver- and PHY-agnostic. It does not gate execution on a single PHY configuration such as `CONFIG_QCA808X_PHY`, so it can cover Qualcomm ETHQOS ports using Marvell, Aquantia, Qualcomm, TI, fixed-link, USB, or other supported PHY implementations.

## Coverage

For every detected physical Ethernet interface, the testcase checks:

- interface presence
- bound driver when available
- administrative link bring-up
- carrier or link-partner detection
- valid non-link-local IPv4 assignment
- interface-bound ping connectivity
- negotiated speed and duplex when available

A disconnected port is reported as an interface-level SKIP rather than a failure.

## Prerequisites and infrastructure

- The target image must provide `ip` and `ping`.
- At least one physical Ethernet port must be enabled and have a bound driver.
- Connect the port to a link partner or switch.
- Provide IPv4 using the image network manager, DHCP configuration, or a
  preconfigured static address.
- Ensure the selected gateway or `PING_TARGET` is reachable through the tested
  interface. Internet access is not required when a local peer is used.

## Files

```text
Runner/suites/Connectivity/Ethernet/Ethernet_Basic_Validation/
|-- run.sh
|-- Ethernet_Basic_Validation.yaml
`-- README.md
```

Shared helpers are provided by:

```text
Runner/utils/lib_ethernet.sh
```

## Configuration

CLI options override environment variables. Run `./run.sh --help` for the
on-target option summary.

| CLI option | Environment variable | Default | Description |
|---|---|---:|---|
| `--link-timeout` | `LINK_TIMEOUT_S` | `10` | Maximum wait for carrier |
| `--ip-timeout` | `IP_TIMEOUT_S` | `15` | Maximum wait for a valid IPv4 |
| `--interface` | `ETH_INTERFACE` | automatic | Explicit interface, otherwise auto-detect |
| `--ping-target` | `PING_TARGET` | automatic | Explicit target, otherwise gateway or `8.8.8.8` |
| `--ping-count` | `PING_COUNT` | `4` | Packets per ping attempt |
| `--ping-wait` | `PING_WAIT_S` | `2` | Per-packet ping timeout |
| `--ping-retries` | `PING_RETRIES` | `3` | Ping attempts |

## Run

```sh
cd Runner/suites/Connectivity/Ethernet/Ethernet_Basic_Validation
./run.sh
```

Example:

```sh
./run.sh --ping-target 192.168.1.1 --link-timeout 20
```

To test one explicit interface, use either form:

```sh
./run.sh --interface end0
ETH_INTERFACE=end0 ./run.sh
```

## Result

The testcase writes:

```text
Ethernet_Basic_Validation.res
Ethernet_Basic_Validation.summary
Ethernet_Basic_Validation.results.tsv
```

The overall testcase passes when at least one detected Ethernet interface completes link, IPv4, and ping validation. It fails when interfaces are testable but none passes. It skips when no interface can be tested, for example when every port is disconnected.
