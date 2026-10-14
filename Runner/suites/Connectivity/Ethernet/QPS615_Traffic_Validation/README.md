# QPS615 traffic validation

`QPS615_Traffic_Validation` provides the external-fixture part of the QPS615
bring-up procedure. It reuses runtime PCIe, firmware, device-tree, driver, and
netdev correlation from the read-only interface test, then validates packet
transfer only after explicit operator opt-in.

The suite never assumes PCI BDFs or interface names, never installs packages,
and never changes link state, addresses, DHCP, or routes. Prepare the selected
interfaces before running it.

The same test runs on base and overlay images without inspecting EFI or changing
packages. Confirm that runtime QPS615 DT and PCI evidence is active. Only boards
whose bring-up procedure requires a different FIT boot selection need the
optional `QPS615_Interface_Validation/run.sh --prepare-fit` preparation and a
manual reboot. FIT boot preparation is not a general traffic prerequisite.
DT discovery errors fail rather than being classified as absent hardware.

## Fixture preparation and run

Connect the selected QPS615 port or ports to reachable peers. Configure link
carrier and addressing through the existing image network manager, DHCP,
IPv6 router advertisements, or static configuration. The suite does not start
DHCP or modify the network configuration.

Without `--peer`, the suite selects the interface-specific IPv4 default gateway,
then an IPv6 default gateway only when no IPv4 gateway exists. It does not use
another interface's gateway, scan neighbours/subnets, or fall back to a public
Internet address. Gateway ping validates the path to the router, not a specific
host. Once a peer is selected, a failed ping is FAIL, not a reason to try IPv6
or a different target.

For a DHCP-addressed host, pass its stable DNS hostname instead of a changing
IP address. The DUT resolves it afresh using image-provided `getent` and the
system NSS configuration, preferring IPv4 to IPv6. Queries use `ahostsv4`,
then `hosts` for implementations without that database, then `ahostsv6` if
needed. Each query has a 10-second deadline plus watchdog cleanup time.
The first IPv4 result is preferred within mixed output, otherwise the first
IPv6 result is selected. No attempt is made to discover arbitrary host names.
DHCP-integrated DNS or existing mDNS/NSS registration must already work.
`.local` names require configured mDNS support, they are not assumed to work
merely because the host uses DHCP. No host-side command is needed for each run,
but the peer must answer ICMP echo requests.

```sh
cd Runner/suites/Connectivity/Ethernet/QPS615_Traffic_Validation
./run.sh --fixture --peer 192.0.2.2
./run.sh --fixture --interfaces eth1,eth2 --peer 192.0.2.2
./run.sh --fixture --interfaces all --peer 192.0.2.2
# Automatic interface gateway, IPv4 preferred over IPv6
./run.sh --fixture --interfaces enP1p5s0f0
# Stable host name with a DHCP-assigned address
./run.sh --fixture --interfaces enP1p5s0f0 --peer lab-host.example.com
# Explicit IPv6 selects IPv6 even when IPv4 is available
./run.sh --fixture --interfaces enP1p5s0f0 --peer 2001:db8::2
./run.sh --fixture --interfaces enP1p5s0f0 --peer fe80::1
```

The interface names and peers above are examples, use runtime-discovered names
and reachable lab peers. Supply IPv6 literals without brackets or `%interface`.
The selected interface provides scope for link-local IPv6. IPv6 traffic requires
image-provided `ip` and either `ping6` or an IPv6-capable `ping -6`. IPv4 retains
the existing `ping` invocation and `ifconfig` fallback for explicit peers.
IPv4-mapped IPv6 addresses are rejected, supply their ordinary IPv4 form instead.
An explicit IPv6 peer is also how to exercise IPv6 on a dual-stack fixture while
leaving the normal IPv4-first default unchanged.

Options:

| Option | Default | Purpose |
|---|---:|---|
| `--fixture [0\|1]` | `0` | Confirm that selected ports have reachable peers |
| `--interfaces LIST` | automatic | Select a comma-separated subset or `all` |
| `--peer IP\|HOST` | interface gateway | Override with IPv4, IPv6 or a resolvable hostname |
| `--ping-count N` | `10` | Echo requests per interface, maximum `20` |
| `--ping-wait N` | `2` | Per-request wait in seconds, maximum `5` |

Automatic interface selection is accepted only when exactly one QPS615 netdev
exists. Multiple interfaces require `--interfaces` because software cannot
infer the lab wiring. Running without `--fixture` performs discovery and
returns an actionable `SKIP` without transmitting traffic.

The LAVA YAML exposes the same fixture, interface, peer, count, and wait
options. Its default `QPS615_TRAFFIC_FIXTURE=0` remains non-disruptive. A lab
job must set it to `1` and supply interface or peer overrides when automatic
discovery does not match the fixture wiring.

## Validation and result policy

Each selected interface must have carrier, a ready address in the selected family, a valid
peer, successful interface-bound ping with zero packet loss, increasing RX and
TX packet counters, and no growth in RX, TX, CRC, or carrier-error counters.
Once `--fixture` is selected, missing hardware, tools, carrier, address,
routing, hostname resolution, or counter evidence is `FAIL` because the requested data path cannot
be proven. This keeps missing image content separate from unsupported-platform
skips.

Loopback, unspecified, multicast and all DUT-owned peer addresses are rejected,
including secondary addresses and addresses on other DUT ports. IPv6 addresses
are normalized before comparison so different textual spellings cannot bypass
the check. Tentative or duplicate-address-failed IPv6 addresses do not establish
readiness. Missing peer discovery never produces PASS. An explicit peer on a
directly connected subnet does not require a default gateway.

The `[QPS615-PEER]` line reports the interface, selection source, IP family,
requested peer and resolved address. Resolver stdout/stderr and DUT address
inventory are retained under the per-interface `*_peer_*` artifacts. DNS/NSS
resolution may use the system management network, but the actual ping remains
bound to the selected QPS615 interface and uses the resolved numeric address.
Echo request/reply traffic proves DUT TX/RX, not independent host-initiated
connections or throughput. Physical port-to-port loopback is not implemented
by pinging an address owned by the DUT.

Ping runs in the C locale with its native finite count and per-request wait.
Kernel logs are captured once through the shared diagnostic helper. Evidence
is retained under `results/QPS615_Traffic_Validation/run-*/`.

When supported by image-provided `ethtool`, the suite also captures full
`ethtool -S` output and parsed counter inventories before and after traffic,
including failed ping attempts. Shared `lib_ethernet.sh` helpers match counters
by runtime name and retain exact unsigned values, including 64-bit counters.
The comparison records unchanged, changed, added, and missing fields, with a
bounded excerpt on stdout and complete `.log`/`.tsv` artifacts. Driver-specific
gauges, resets, and unknown fields are diagnostic only, not invented failure
thresholds. Missing or unsupported driver statistics do not weaken or replace
the standard packet/error checks above.

This focused suite closes the interface-selection gap by transmitting only on
netdevs dynamically correlated with QPS615 PCI functions. Throughput, UDP,
bidirectional, dual-port, and suspend/resume coverage remains in the existing
generic Ethernet suites. Operators should pass one of the correlated netdevs
reported by this suite to those tests rather than duplicating their data paths
here.

## Failure diagnostics

Recorded failures automatically save read-only `ethtool` evidence for the
selected interfaces and replay bounded excerpts to stdout with `[ETH-DIAG]`
markers. No host commands, runtime package installation or new options are
required. The original verdict and cleanup behavior remain unchanged.
See [shared Ethernet failure diagnostics](../README_Ethernet_Diagnostics.md)
for collected queries, artifact locations, time bounds and unavailable-tool handling.
