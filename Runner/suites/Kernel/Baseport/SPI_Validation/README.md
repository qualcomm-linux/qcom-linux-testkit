# SPI validation

`SPI_Validation` validates the functional readiness of enabled SPI controllers
and child devices using Linux SPI masters, runtime client devices, modalias
evidence, and bound drivers. Discovery is based on runtime DT and sysfs instead
of fixed bus or chip-select numbers.

The suite reports each master and client with its driver, runtime DT node,
modalias, `spi-max-frequency` property bytes, SPI mode flags, runtime power
state, framework error and timeout counters, and supplier-wait state when
available. These fields are diagnostic evidence and optional kernel ABI is not
treated as a failure.

## Run

```sh
cd Runner/suites/Kernel/Baseport/SPI_Validation
./run.sh
```

## Result policy

- `PASS`: enabled controllers expose runtime masters and declared clients are
  bound.
- `FAIL`: an enabled controller lacks a runtime master, a declared child is
  absent, or a runtime client is unbound.
- `SKIP`: no enabled or runtime-visible SPI capability exists.

## Diagnostics

The suite emits bounded per-object binding and kernel-health diagnostics to
stdout. Temporary evidence is removed when the run finishes.

The suite never creates `spidev` nodes, changes DT configuration, probes
arbitrary chip-selects, or installs diagnostic utilities. Fixture-controlled
SPI loopback belongs in a separate functional suite.

Reference: [Qualcomm Linux SPI guide](https://docs.qualcomm.com/doc/80-70023-8/topic/spi.html)
