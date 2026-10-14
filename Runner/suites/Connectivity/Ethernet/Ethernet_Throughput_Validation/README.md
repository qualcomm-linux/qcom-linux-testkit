# Ethernet_Throughput_Validation

## Overview

This testcase runs an `iperf3` client bound to a selected Ethernet interface
and its IPv4 address. It supports a recommended external-peer mode and an
optional local host-stack self-test mode.

It supports:

- TCP forward traffic
- TCP reverse traffic
- optional UDP traffic
- optional simultaneous bidirectional TCP traffic
- configurable minimum throughput thresholds
- parallel TCP streams

## Test infrastructure

### External peer mode, recommended

Use this mode to measure traffic that traverses the Ethernet MAC, PHY, cable,
switch, and peer. The target and peer need:

- `iperf3` available in their images
- IPv4 addresses with working routes between them
- carrier on the selected target interface
- matching TCP and optional UDP access to `ETH_IPERF_PORT`
- no firewall rule blocking the selected port

Start the server on the peer before running the testcase:

```sh
iperf3 -s -B 192.168.1.10 -p 5201
```

Run the testcase on the target:

```sh
./run.sh \
  --mode external \
  --iperf-server 192.168.1.10 \
  --interface end0
```

The peer should be at least as fast as the link under test. For meaningful
thresholds, avoid routing the traffic through a slower management network.

### Local host-stack mode

Use this mode only when a second system is unavailable. The testcase starts
and stops an `iperf3` server bound to the selected interface IPv4 address:

```sh
./run.sh --mode local --interface end0
```

This traffic is locally routed by the kernel and does not traverse the cable,
MAC, or PHY. It validates the `iperf3` installation, address binding, test
control flow, and host networking stack, but it is not a physical Ethernet
throughput measurement. Do not configure an external server in local mode.

## Configuration

CLI options override environment variables. In `auto` mode an external server
is selected when configured, otherwise the target-local self-test is used.

| CLI option | Environment variable | Default | Description |
|---|---|---:|---|
| `--mode` | `ETH_IPERF_MODE` | `auto` | Select `auto`, `external`, or `local` |
| `--iperf-server` | `ETH_IPERF_SERVER` | empty | External server IPv4 or hostname |
| `--port` | `ETH_IPERF_PORT` | `5201` | Server port |
| `--interface` | `ETH_IPERF_INTERFACE` | automatic | Interface to test |
| `--link-timeout` | `LINK_TIMEOUT_S` | `10` | Maximum wait for carrier |
| `--ip-timeout` | `IP_TIMEOUT_S` | `15` | Maximum wait for IPv4 |
| `--duration` | `ETH_IPERF_DURATION` | `20` | Seconds per mode |
| `--streams` | `ETH_IPERF_STREAMS` | `1` | Parallel TCP streams |
| `--min-tcp-mbps` | `ETH_IPERF_MIN_TCP_MBPS` | `0` | Forward TCP threshold |
| `--reverse-enable` | `ETH_IPERF_REVERSE_ENABLE` | `1` | Enable reverse TCP |
| `--min-reverse-mbps` | `ETH_IPERF_MIN_REVERSE_MBPS` | `0` | Reverse TCP threshold |
| `--udp-enable` | `ETH_IPERF_UDP_ENABLE` | `0` | Enable UDP validation |
| `--udp-bitrate` | `ETH_IPERF_UDP_BITRATE` | `100M` | Requested UDP rate |
| `--min-udp-mbps` | `ETH_IPERF_MIN_UDP_MBPS` | `0` | UDP receiver threshold |
| `--bidir-enable` | `ETH_IPERF_BIDIR_ENABLE` | `0` | Enable `--bidir` when supported |
| `--min-bidir-mbps` | `ETH_IPERF_MIN_BIDIR_MBPS` | `0` | Bidirectional receiver threshold |

Example with explicit performance thresholds:

```sh
./run.sh \
  --mode external \
  --iperf-server 192.168.1.10 \
  --interface end0 \
  --duration 60 \
  --streams 4 \
  --min-tcp-mbps 800 \
  --min-reverse-mbps 800
```

Example enabling UDP and simultaneous bidirectional TCP:

```sh
./run.sh \
  --mode external \
  --iperf-server 192.168.1.10 \
  --udp-enable 1 \
  --udp-bitrate 1G \
  --min-udp-mbps 900 \
  --bidir-enable 1 \
  --min-bidir-mbps 800
```

UDP validation uses the receiver throughput reported on the summary line.
Jitter and packet loss remain visible in `iperf_logs/udp_forward.log` for
diagnosis. Bidirectional mode is reported as SKIP when the installed `iperf3`
does not support `--bidir`.

## Result

External mode requires a server address. Local server startup failure, port
conflicts, client failures, or throughput below an enabled threshold produce
a failure.

```text
Ethernet_Throughput_Validation.res
Ethernet_Throughput_Validation.results.tsv
iperf_logs/
```

## Failure diagnostics

Recorded failures automatically save read-only `ethtool` evidence for the
selected interfaces and replay bounded excerpts to stdout with `[ETH-DIAG]`
markers. No host commands, runtime package installation or new options are
required. The original verdict and cleanup behavior remain unchanged.
See [shared Ethernet failure diagnostics](../README_Ethernet_Diagnostics.md)
for collected queries, artifact locations, time bounds and unavailable-tool handling.
