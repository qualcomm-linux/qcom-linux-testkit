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
- The default target `8.8.8.8` must be reachable and reply to ICMP through the
  tested interface. For an isolated network, select a reachable local peer with
  `--ping-target` or `PING_TARGET`. Internet access is not required with a local peer.

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

CLI options override environment variables. An omitted or empty
`--ping-target` preserves `PING_TARGET` when set, otherwise it uses `8.8.8.8`.
The default gateway is not automatically selected or used as a fallback after
ping failure. Run `./run.sh --help` for the on-target option summary.

| CLI option | Environment variable | Default | Description |
|---|---|---:|---|
| `--link-timeout` | `LINK_TIMEOUT_S` | `10` | Maximum wait for carrier |
| `--ip-timeout` | `IP_TIMEOUT_S` | `15` | Maximum wait for a valid IPv4 |
| `--interface` | `ETH_INTERFACE` | automatic | Explicit interface, otherwise auto-detect |
| `--ping-target` | `PING_TARGET` | `8.8.8.8` | User-provided target overrides the public IPv4 default |
| `--ping-count` | `PING_COUNT` | `4` | Packets per ping attempt |
| `--ping-wait` | `PING_WAIT_S` | `2` | Per-packet ping timeout |
| `--ping-retries` | `PING_RETRIES` | `3` | Ping attempts |

## Run

```sh
cd Runner/suites/Connectivity/Ethernet/Ethernet_Basic_Validation
./run.sh
```

The default command pings `8.8.8.8` through each tested interface. All retries
use the same selected target. To select a local peer explicitly:

```sh
./run.sh --ping-target 192.168.1.1 --link-timeout 20
```

The environment equivalent and CLI precedence are:

```sh
PING_TARGET=192.168.1.1 ./run.sh
PING_TARGET=192.168.1.1 ./run.sh --ping-target 192.168.1.2
```

For LAVA, set the existing `PING_TARGET` parameter to the desired IP. Its empty
default selects `8.8.8.8`. Unreachable targets fail the connectivity check after
the configured retries, even when carrier and IPv4 checks pass. Disconnected
ports and interfaces without valid IPv4 retain their existing SKIP behavior.

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

## Failure diagnostics

Recorded failures automatically save read-only `ethtool` evidence for the
selected interfaces and replay bounded excerpts to stdout with `[ETH-DIAG]`
markers. No host commands, runtime package installation or new options are
required. The original verdict and cleanup behavior remain unchanged.
See [shared Ethernet failure diagnostics](../README_Ethernet_Diagnostics.md)
for collected queries, artifact locations, time bounds and unavailable-tool handling.
