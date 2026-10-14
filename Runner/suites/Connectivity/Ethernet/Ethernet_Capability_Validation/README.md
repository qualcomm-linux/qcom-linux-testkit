# Ethernet_Capability_Validation

## Overview

This testcase validates the capabilities exposed by each physical Ethernet driver through `ethtool` and sysfs. It covers MAC/PHY link modes, offloads, driver statistics, pause frames, timestamping/PTP, queue-related controls, and negotiated speed/duplex.

## Core checks

The following checks are required when an interface is enumerated:

- `ethtool -i` driver query
- base `ethtool` link-capability query
- `ethtool -k` offload-feature query

Optional driver operations are reported as SKIP when unsupported:

- driver statistics
- pause parameters
- hardware timestamping and PTP hardware clock, skipped when no clock is exposed
- channels
- ring parameters
- interrupt coalescing
- Energy Efficient Ethernet
- private flags

When carrier is present, negotiated speed and duplex are actively validated.

## Prerequisites and infrastructure

- The target image must provide `ip` and `ethtool`.
- At least one physical Ethernet interface and bound driver must be present.
- A cable and link partner are required only for negotiated speed and duplex
  checks. Driver capability queries can run without carrier.
- Optional operations such as PTP, pause parameters, rings, channels, and EEE
  depend on what the MAC and PHY drivers expose. Unsupported features and a
  missing PTP hardware clock are reported as SKIP.

## Configuration

CLI options override environment variables.

| CLI option | Environment variable | Default | Description |
|---|---|---:|---|
| `--interface` | `ETH_INTERFACE` | automatic | Explicit interface, otherwise auto-detect |
| `--require-full-duplex` | `REQUIRE_FULL_DUPLEX` | `1` | Require full duplex on a linked interface |
| `--min-link-speed` | `MIN_LINK_SPEED_MBPS` | `0` | Minimum speed, `0` disables the threshold |

Example for a 1-Gbit platform:

```sh
./run.sh --min-link-speed 1000
```

Example for a 2.5-Gbit port:

```sh
./run.sh --min-link-speed 2500
```

Add `--interface IFACE` when only one port should be checked. Without it, the
shared discovery helper validates every detected physical Ethernet interface.

## Result

Driver statistics use the shared `lib_ethernet.sh` capture helper. It discovers
all unsigned counters reported by `ethtool -S`, without a driver-specific field
list. Full output and parsed values are retained under
`results/Ethernet_Capability_Validation/driver-*/`. Missing, unsupported, or
unusable optional driver statistics retain the existing `SKIP` policy for that
check and log the reason. No packages are installed.

```text
Ethernet_Capability_Validation.res
Ethernet_Capability_Validation.results.tsv
```

## Failure diagnostics

Recorded failures automatically save read-only `ethtool` evidence for the
selected interfaces and replay bounded excerpts to stdout with `[ETH-DIAG]`
markers. No host commands, runtime package installation or new options are
required. The original verdict and cleanup behavior remain unchanged.
See [shared Ethernet failure diagnostics](../README_Ethernet_Diagnostics.md)
for collected queries, artifact locations, time bounds and unavailable-tool handling.
