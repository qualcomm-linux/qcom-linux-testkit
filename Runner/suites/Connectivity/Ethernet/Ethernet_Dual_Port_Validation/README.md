# Ethernet_Dual_Port_Validation

## Overview

This testcase validates two physical Ethernet ports at the same time. It is intended for dual-MAC platforms such as RB8-class systems and verifies that both interfaces can remain linked, obtain IPv4 addresses, transmit traffic concurrently, and update independent RX/TX counters.

## Coverage

- automatic selection of the first two physical Ethernet interfaces
- optional explicit interface selection
- carrier and IPv4 readiness on both ports
- interface-specific target selection
- simultaneous interface-bound ping traffic
- independent RX/TX packet-counter movement
- failure isolation for each port

## Configuration

CLI options override environment variables.

| CLI option | Environment variable | Default | Description |
|---|---|---:|---|
| `--link-timeout` | `LINK_TIMEOUT_S` | `10` | Maximum wait for carrier |
| `--ip-timeout` | `IP_TIMEOUT_S` | `15` | Maximum wait for IPv4 |
| `--interfaces` | `ETH_DUAL_INTERFACES` | automatic | Two space-separated interface names |
| `--target-a` | `ETH_DUAL_TARGET_A` | automatic | Target for the first interface |
| `--target-b` | `ETH_DUAL_TARGET_B` | automatic | Target for the second interface |
| `--ping-count` | `PING_COUNT` | `10` | Concurrent packets per interface |
| `--ping-wait` | `PING_WAIT_S` | `2` | Per-packet timeout |

Example:

```sh
./run.sh
```

The command above auto-detects the first two physical Ethernet interfaces. To
select the ports and targets explicitly:

```sh
./run.sh \
  --interfaces "eth0 eth1" \
  --target-a 192.168.10.1 \
  --target-b 192.168.20.1
```

The two interfaces should normally be connected to distinct subnets or otherwise have valid interface-specific routes.

## Prerequisites and infrastructure

- The target image must provide `ip` and `ping`.
- Two physical Ethernet interfaces with bound drivers are required.
- Connect both ports to active link partners.
- Configure IPv4 and an interface-specific reachable target for each port.
- Distinct subnets are recommended so Linux route selection cannot move both
  traffic flows onto the same interface.
- Do not use the same peer address for both ports unless policy routing makes
  the intended egress interface unambiguous.

## Result

The testcase skips when fewer than two physical Ethernet interfaces are present or when both ports cannot be made traffic-ready.

```text
Ethernet_Dual_Port_Validation.res
Ethernet_Dual_Port_Validation.results.tsv
```

## Failure diagnostics

Recorded failures automatically save read-only `ethtool` evidence for the
selected interfaces and replay bounded excerpts to stdout with `[ETH-DIAG]`
markers. No host commands, runtime package installation or new options are
required. The original verdict and cleanup behavior remain unchanged.
See [shared Ethernet failure diagnostics](../README_Ethernet_Diagnostics.md)
for collected queries, artifact locations, time bounds and unavailable-tool handling.
