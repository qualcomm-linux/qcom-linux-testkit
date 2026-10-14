# Ethernet failure diagnostics

All Ethernet suites, including QPS615 interface and traffic validation, capture
read-only `ethtool` evidence on recorded failures. The shared implementation in
`Runner/utils/lib_ethernet.sh` uses the same image-provided tools on Yocto,
Debian, Ubuntu, CentOS and other distributions. No package is installed and no
new command-line, environment or YAML option is required.

Evidence is retained under
`results/<suite>/run-<timestamp>-<pid>/failure_diagnostics/` in the suite directory.
Each selected interface has individual query logs and a `status.tsv` containing
the query, diagnostic status, command exit status and artifact path. A missing
tool or failure before any interface selection is explained in a top-level log.
The collector never guesses an unrelated management interface to interrogate.

The `[ETH-DIAG]` stdout messages identify the interface, command, status and file.
Up to 80 lines from each query are replayed with the shared logging helper,
including an omitted-line count and full artifact path when truncated.
Repeated failures reuse the first capture for each interface. This avoids
repeatedly interrogating an unhealthy device and preserves the first snapshot.

## Captured information

| Query | Evidence |
|---|---|
| `ethtool IFACE` | Link state, speed, duplex, autonegotiation and advertised/partner modes |
| `ethtool -i IFACE` | Driver, firmware, driver version and bus information |
| `ethtool -S IFACE` | Driver packet, queue and error counters |
| `ethtool --phy-statistics IFACE` | PHY-specific counters when supported |
| `ethtool -k IFACE` | Checksum, segmentation and other offload features |
| `ethtool -g IFACE` | RX/TX ring sizes and limits |
| `ethtool -l IFACE` | Channel counts and limits |
| `ethtool -c IFACE` | Interrupt coalescing configuration |
| `ethtool -a IFACE` | Pause-frame and flow-control configuration |
| `ethtool -T IFACE` | Timestamping and PTP clock capabilities |
| `ethtool --show-eee IFACE` | Energy Efficient Ethernet state |
| `ethtool --show-fec IFACE` | Forward error correction configuration |
| `ethtool --show-priv-flags IFACE` | Driver-private flag names and current values |

Unsupported options, driver limitations and permission failures retain their
exit status and output as `unavailable-or-error`. Diagnostic collection never
changes PASS/FAIL/SKIP, starts traffic, or changes the existing cleanup traps.
PASS and SKIP do not trigger this collector. Existing functional queries in
individual suites remain unchanged.

Each query has a three-second deadline through the shared managed timeout.
After a timeout, remaining queries on that interface are skipped. A cumulative
60-second command-time budget bounds collection across interfaces. The final
query and watchdog cleanup can exceed that budget by up to five seconds,
excluding filesystem and stdout replay time. Skipped queries are listed in
`status.tsv` rather than silently omitted.

The base query can expose the Wake-on-LAN SecureOn password. It is redacted before
any output is saved or replayed. Register/EEPROM/module dumps are not collected.
The collector never uses self-tests, cable tests, PHY identification, resets,
renegotiation or setting operations such as `-t`, `-p`, `-r`, `-s`, `-K`, `-G`,
`-L`, `-C`, `-A`, `--set-*` or `--reset`. These may disrupt the fixture or alter
the evidence needed to diagnose the original failure.

## Public source references

- [ethtool command manual](https://github.com/Distrotech/ethtool/blob/master/ethtool.8.in)
- [Linux ethtool netlink documentation](https://github.com/torvalds/linux/blob/master/Documentation/networking/ethtool-netlink.rst), covering link state, features, rings, channels, coalescing, pause, EEE, FEC, timestamps and statistics. Its WOL section also documents the confidential SecureOn field.
