# UART loopback validation

`UART_Loopback_Validation` verifies exact payload transfer through an
auto-detected or explicitly selected UART with an external TX-to-RX loopback
fixture.

The suite refuses active kernel consoles, snapshots the complete termios state,
uses bounded reads and writes, compares a 4 KiB transmitted and received
payload, and restores the saved state after every baud case. When exactly one
accessible DT-backed physical non-console UART exists, it is selected
automatically. Generic legacy `ttyS*` entries without runtime DT ownership are
ignored. Multiple eligible UARTs require an explicit override to avoid guessing
which port has the loopback fixture.

Before changing termios, the suite also compares the selected device with its
own stdin, stdout, and stderr and scans current userspace file-descriptor
owners. A serial shell, getty, or another process holding that UART produces a
safe `SKIP` with the dynamically discovered owner PID, command, and FD in the
live log.

Automatic baud selection uses the portable `115200` default. Specify any
additional board-qualified baud rates explicitly with `--baud` or
`UART_BAUDS`.

## Run

```sh
cd Runner/suites/Kernel/Baseport/UART_Loopback_Validation
./run.sh --fixture
```

Optional settings:

```sh
./run.sh --fixture --device /dev/ttyHS1 --baud 115200,921600,3000000 --payload-bytes 4096 --timeout 15
```

Use `--device` or `UART_DEVICE` to override automatic discovery. CLI options
take precedence over environment variables. Other environment variables are
`UART_BAUDS`, `UART_PAYLOAD_BYTES`, `UART_LOOPBACK_TIMEOUT`, and
`UART_LOOPBACK_FIXTURE`. The legacy single-value `UART_BAUD` environment
variable remains supported.

An external TX-to-RX loopback fixture must be explicitly enabled with
`--fixture` or `UART_LOOPBACK_FIXTURE=1`. This prevents an unqualified test
job from transmitting on an auto-detected UART.

Temporary payload and command evidence is removed when the run finishes. The
live log retains the bounded per-case failure analysis.

## Result policy

- `PASS`: the exact payload is received and termios restoration succeeds.
- `FAIL`: the selected device is unsafe or invalid, configuration or transfer
  fails, bytes differ, a timeout occurs, or state restoration fails.
- `SKIP`: no unique safe UART is discovered and no override is provided, or
  required image utilities are absent.

Reference: [Qualcomm Linux UART guide](https://docs.qualcomm.com/doc/80-70023-8/topic/uart.html)
