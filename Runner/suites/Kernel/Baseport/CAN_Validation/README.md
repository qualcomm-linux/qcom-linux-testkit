# CAN validation

`CAN_Validation` validates CAN hardware readiness from runtime DT and SocketCAN
interfaces. It does not assume `can0`, a fixed SPI bus, chip select, board, SoC,
or a single valid CAN controller driver.

For each capability, the suite reports the parent runtime device, bound driver,
DT identity, SocketCAN interface, administrative state, CAN protocol state,
classic and CAN FD bitrates, controller mode, bus error counters, and network
RX/TX error counters. Detailed `ip` output is retained when the image provides
the tool.

## Run

```sh
cd Runner/suites/Kernel/Baseport/CAN_Validation
./run.sh
```

## Result policy

- `PASS`: every discovered CAN declaration has a bound runtime device and
  SocketCAN interface.
- `FAIL`: a declared CAN device is missing, unbound, lacks its SocketCAN
  interface, reports a current error-warning, error-passive, or bus-off state,
  or persistent CAN or parent-SPI kernel errors are present.
- `SKIP`: no enabled or runtime-visible CAN capability exists.

## Diagnostics

The suite emits bounded per-device binding, SocketCAN, and kernel-health
diagnostics to stdout. Temporary evidence is removed when the run finishes.

Internal and external traffic validation are intentionally separate because
they change interface state and require either controlled loopback or external
fixtures with reliable cleanup.

Reference: [Qualcomm Linux CAN guide](https://docs.qualcomm.com/doc/80-70023-8/topic/can.html)
