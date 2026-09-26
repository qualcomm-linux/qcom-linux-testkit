# I2C Buses Validation

This suite performs capability-driven I2C runtime validation. It correlates
enabled Qualcomm I2C device-tree controllers with runtime adapters and clients,
reports driver binding, queries adapter functionality, and retains bounded
inventory and kernel-health evidence.

The suite also provides an in-repository EEPROM validator that replaces the
need for the separately supplied `i2c-msm-test` binary. It uses standard Linux
EEPROM and NVMEM sysfs interfaces so the bound kernel driver handles device
addressing, page boundaries, and write timing.

No SoC, bus number, peripheral address, EEPROM capacity, or writable range is
hardcoded. The runner discovers I2C-backed EEPROM interfaces and their sizes
from the running target. When discovery is ambiguous, select the sysfs data
file explicitly. A destructive integrity check additionally requires the user
to provide a documented safe offset and length.

On Debian, Ubuntu, and CentOS, the suite uses the shared package provider to
install the mapped `i2c-tools` package when it is missing. Yocto remains
image-managed and never performs runtime package installation. Missing optional
utilities or hardware produce SKIP with discovery evidence.

## Default run

```sh
cd Runner/suites/Kernel/Baseport/Buses
./run.sh
```

The default EEPROM mode is `auto`. It performs a read-only probe when exactly
one I2C-backed EEPROM interface is discovered. It produces SKIP when no
candidate exists or multiple candidates require user selection.

Disable EEPROM validation while retaining controller, adapter, client, and
kernel-health checks:

```sh
./run.sh --eeprom-mode off
```

## Yocto CI defaults

`Buses.yaml` uses the same safe default behavior: automatic read-only EEPROM
discovery, legacy compatibility disabled, active address scanning disabled, and
write authorization disabled. Yocto remains image-managed, so a missing
`i2c-tools` package is reported as SKIP without attempting package installation.

An integrity job must explicitly provide all of the following parameters after
the selected range has been approved for destructive testing:

- `I2C_EEPROM_MODE=integrity`
- `I2C_EEPROM_DEVICE`
- `I2C_EEPROM_OFFSET`
- `I2C_EEPROM_LENGTH`
- `I2C_ALLOW_WRITE=1`

## EEPROM discovery and read-only validation

The runner searches the following runtime interfaces:

- `/sys/bus/i2c/devices/*/eeprom`
- I2C-backed `/sys/bus/nvmem/devices/*/nvmem`

When the NVMEM `type` attribute is exposed, only devices identified as
`EEPROM` are selected. Duplicate compatibility and NVMEM views of the same I2C
client are treated as one candidate.

Run an explicit read-only probe:

```sh
./run.sh --eeprom-mode probe
```

When more than one candidate is reported, select the required data file:

```sh
EEPROM_PATH=/sys/bus/i2c/devices/<bus>-<address>/eeprom
./run.sh --eeprom-mode probe --eeprom-device "$EEPROM_PATH"
```

The probe reads the dynamically reported device capacity and records its
SHA-256 digest without modifying the device.

## EEPROM data-integrity validation

Integrity mode reads the original bytes from a user-approved range, derives a
test pattern from those bytes, writes and reads back the pattern, restores the
original bytes, and verifies the restoration. The test does not assume a
particular EEPROM geometry.

The suite cannot determine which EEPROM bytes are semantically safe to modify.
Obtain the safe range from the board or peripheral documentation and provide it
explicitly:

```sh
EEPROM_PATH=/sys/bus/i2c/devices/<bus>-<address>/eeprom
SAFE_OFFSET=<documented-safe-offset>
SAFE_LENGTH=<documented-safe-length>

./run.sh --eeprom-test \
    --eeprom-device "$EEPROM_PATH" \
    --eeprom-offset "$SAFE_OFFSET" \
    --eeprom-length "$SAFE_LENGTH" \
    --allow-write
```

The equivalent environment form is:

```sh
I2C_EEPROM_MODE=integrity \
I2C_EEPROM_DEVICE="$EEPROM_PATH" \
I2C_EEPROM_OFFSET="$SAFE_OFFSET" \
I2C_EEPROM_LENGTH="$SAFE_LENGTH" \
I2C_ALLOW_WRITE=1 \
./run.sh
```

Integrity mode is rejected unless both the safe range and `--allow-write` are
provided. Restoration is attempted after transfer errors and termination
signals. Power loss or an uncatchable process termination can still interrupt
restoration, so do not use a range containing calibration, identity, boot, or
other persistent production data.

## Explicit i2c-tools operations

These operations are never run automatically. Select an adapter explicitly on
multi-adapter systems and obtain addresses and registers from the board or
peripheral documentation. For a scan with `--adapter auto`, the suite selects
the adapter containing the uniquely discovered EEPROM. If that association is
not unique, the scan is skipped and an explicit adapter is required.

Scan one adapter using SMBus quick-write probes:

```sh
./run.sh --adapter 1 --scan --scan-mode quick
```

Use SMBus receive-byte probes instead when appropriate:

```sh
./run.sh --adapter 1 --scan --scan-mode read
```

Both scan modes can disturb devices whose protocols are not understood.

Read a byte register and optionally validate selected bits:

```sh
./run.sh --adapter 1 --read 0x50 0x00 --read-mode b \
    --expected 0x42 --mask 0xff
```

Write a documented scratch register, verify the value, and restore its original
contents:

```sh
./run.sh --adapter 1 --write 0x50 0x10 0x5a --write-mode b --allow-write
```

## Legacy compatibility

The old image-provided `i2c-msm-test` path is disabled by default. It remains
available temporarily for images that still package the utility:

```sh
./run.sh --legacy-test --adapter 0 --timeout 20
```

When the binary is absent, this optional compatibility check produces SKIP.
The suite does not depend on this legacy binary because the in-repository
EEPROM validator provides the default functional coverage.

## Public options

- `--legacy-test`
- `--eeprom-mode auto|off|probe|integrity`
- `--eeprom-test`
- `--eeprom-device auto|PATH`
- `--eeprom-offset BYTES`
- `--eeprom-length BYTES`
- `--eeprom-timeout SECONDS`
- `--adapter BUS|/dev/i2c-BUS`
- `--timeout SECONDS`
- `--tools-timeout SECONDS`
- `--scan`
- `--scan-mode quick|read`
- `--read ADDRESS REGISTER`
- `--read-mode b|w`
- `--expected VALUE`
- `--mask VALUE`
- `--write ADDRESS REGISTER VALUE`
- `--write-mode b|w`
- `--allow-write`

Every option has a corresponding uppercase environment variable shown by
`./run.sh --help`.

## Results

- `PASS`: applicable runtime topology is healthy and each available or
  explicitly requested validation completes with its required evidence.
- `FAIL`: runtime state is inconsistent, user input is malformed, an operation
  fails after its environment is available, or modified data cannot be
  restored and verified.
- `SKIP`: I2C, a selected adapter or EEPROM, Python, or an optional diagnostic
  utility is unavailable.

Artifacts are retained under `results/Buses/`, including controller, adapter,
client, driver, dmesg, EEPROM discovery, digest, and restoration evidence.
