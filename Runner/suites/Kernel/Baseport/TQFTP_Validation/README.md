# TQFTP validation

`TQFTP_Validation` performs readiness and exact local-host transfer validation
of the public QRTR TFTP server. Applicability comes from the
`tqftpserv.service` unit or a running `tqftpserv` process. An image-provided binary is retained as diagnostic
evidence but does not by itself prove that the service applies.

The service set still varies by target, but users do not provide a QRTR service
number. Run `./run.sh` and the suite dynamically decides whether TQFTP applies,
then checks its public protocol tuple `4096:1:0`. The tuple is defined by
`tqftpserv`; it is not inferred from a particular board.

The active server must advertise QRTR service `4096`, version `1`, instance
`0`. The suite checks access to the state directory and searches a bounded
service journal for public request and transfer markers.

By default, it also stages a temporary deterministic payload in the read-write
directory and uses the repository Python client to issue an RRQ to the
dynamically discovered local `4096:1:0` QRTR endpoint. The received bytes must
exactly match the staged file. This covers the QRTR socket, request/response,
path translation, TQFTP `blksize`/`wsize`/`rsize` option negotiation, OACK,
multi-block transfer, acknowledgments, and payload integrity.
The temporary source file is removed on success, failure, timeout, and signal.

The E2E path uses local `AF_QIPCRTR` traffic. It does not require Wi-Fi,
Ethernet, DNS, or Internet access, and an IP-network transfer cannot substitute
for this protocol check. The client uses Python's named `AF_QIPCRTR` constant
when available and the public Linux family number otherwise. Socket failures
remain explicit functional diagnostics.
If more than one endpoint advertises the same tuple, the E2E subcheck prints
all candidates and skips instead of choosing an endpoint by enumeration order.

## Run

```sh
./run.sh
./run.sh --timeout 15 --state-dir /var/lib/tqftpserv
./run.sh --e2e 0
```

CLI options override the matching environment variables:

| Option | Environment | Default | Purpose |
|---|---|---:|---|
| `--timeout` | `TQFTP_TIMEOUT` | `10` | Bound QRTR and service evidence commands |
| `--state-dir` | `TQFTP_STATE_DIR` | `/var/lib/tqftpserv` | Server read-write root and E2E staging path |
| `--e2e` | `TQFTP_E2E_ENABLE` | `1` | Enable the local exact RRQ transfer |

The default state directory follows the public `tqftpserv` implementation and
systemd `StateDirectory=tqftpserv` unit. Override it only for an image carrying
a deliberately modified TQFTP build or service definition. `--timeout` only
changes probe bounds. Neither option is normally SoC-specific.

## Result policy

- `PASS`: TQFTP is active, advertises `4096:1:0`, exposed state is usable, and
  an enabled E2E transfer returns the exact staged payload.
- `FAIL`: TQFTP is provisioned but inactive, advertisement is absent, a query
  or enabled E2E transfer fails, state access is invalid, or TQFTP or
  QRTR/GLINK/RPMSG transport errors are present.
- `SKIP`: TQFTP is not provisioned or required QRTR advertisement or kernel
  health evidence is unavailable. No request in the bounded journal is a
  subcheck skip because remote firmware may make no request during the run.

Independent DSP/modem faults are reported as warnings without failing a
successful local transfer. This test does not validate those subsystems' health.

Look for `[TQFTP-DISCOVERY]`, `[TQFTP-QRTR]`, `[TQFTP-QRTR-ENDPOINT]`,
`[TQFTP-E2E]`, `[TQFTP-STATE]`, `[TQFTP-STATE-ENTRY]`, and
`[TQFTP-REQUEST]` in stdout.
Endpoint lines include the serving node and port. State, request, service, and
kernel-error excerpts are bounded and point to the complete retained artifact.
The E2E artifact includes the negotiated OACK values, each data block up to a
bounded display limit, cumulative byte counts, and the final SHA-256 proof.
When no request occurred, the request marker reports the journal command status
and number of retained lines so readiness is distinguishable from traffic proof.
`[TQFTP-POLICY]` records the dynamically selected
applicability contract and effective state directory. Service, topology,
request, E2E client output, the received payload, and kernel evidence is retained under the printed
`results/TQFTP_Validation/run-*/` directory.

Kernel health capture prefers `dmesg` and falls back to image-provided
`journalctl -k`. `kernel/dmesg_access.log` records the selected provider,
command status, `dmesg_restrict`, effective capabilities, and any access error.
