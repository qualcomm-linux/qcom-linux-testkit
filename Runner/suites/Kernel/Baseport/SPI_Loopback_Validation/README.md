# SPI loopback validation

`SPI_Loopback_Validation` runs `spidev_test` against an auto-detected or
explicitly selected `/dev/spidevX.Y` node. The kernel does not expose a
portable runtime indicator for whether controller-internal loopback is
supported, so select `internal` only when the target's documented controller
supports it. External mode requires a MOSI-to-MISO loopback fixture.

The suite validates command status and compares the exact requested, TX, and RX
byte sequences across SPI modes 0, 1, 2, and 3 by default. It never creates
spidev nodes, changes DT configuration, installs tools, or takes control of a
production SPI client. A unique accessible
`spidev` node is selected automatically. Multiple nodes require an explicit
override so the suite does not guess which device has the loopback fixture.
When the running kernel exposes standard SPI device statistics, the suite also
requires the transfer not to increment the `errors` or `timedout` counters.

Use `--loopback internal` for a documented controller-internal loopback path,
or `--loopback external --fixture` for a wired fixture. Automatic mode skips
instead of inferring loopback capability from a driver name.

## Run

```sh
cd Runner/suites/Kernel/Baseport/SPI_Loopback_Validation
./run.sh --loopback internal
```

Optional settings:

```sh
./run.sh --device /dev/spidev0.0 --speed 5000000 --bits 8 --modes 0,1,2,3 --loopback external --fixture --timeout 15
```

Use `--device` or `SPI_DEVICE` to override automatic discovery. `SPI_MODES`,
`SPI_LOOPBACK_TYPE`, and `SPI_LOOPBACK_FIXTURE` control the functional matrix.
CLI options take precedence over environment variables.

Temporary transfer evidence is removed when the run finishes. The live log
retains the bounded per-case failure analysis.

## Result policy

- `PASS`: requested, TX, and RX bytes match exactly without new SPI error or
  timeout counters when those counters are exposed.
- `FAIL`: the selected node is invalid, the command fails or times out, output
  cannot be validated, the received bytes differ, or an exposed SPI error or
  timeout counter increases during the transfer.
- `SKIP`: no unique accessible `spidev` node is discovered and no override is
  provided, or `spidev_test` is not provided by the image.

Reference: [Qualcomm Linux SPI guide](https://docs.qualcomm.com/doc/80-70023-8/topic/spi.html)
