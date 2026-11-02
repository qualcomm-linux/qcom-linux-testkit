# I2C Buses Validation

This suite performs capability-driven I2C runtime validation. It correlates
enabled Qualcomm GENI, QUP and CCI device-tree controllers with runtime adapters and clients,
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

Yocto, Debian, Ubuntu and CentOS all use image-provided components. The suite
does not install packages or require systemd. Missing optional utilities or
hardware produce SKIP with discovery evidence. An I/O error or short read after
selecting an available EEPROM is FAIL, not an unavailable-environment SKIP.

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

When Python is absent, `i2c_eeprom_read.sh` provides the read-only path using
image-provided `sh`, `dd`, `stat`, `sha256sum`, `cmp` and the base shell utilities.
The helper probes `dd` for `iflag=fullblock` support before device access and
skips if it is unavailable, partial kernel reads must not truncate a block.
It preserves candidate deduplication, explicit selection, exact byte counts and
failure reporting. This fallback reads at most 1 MiB per selected range. For a
larger EEPROM, provide `--eeprom-offset` and `--eeprom-length`. Reads use aligned
blocks where possible, not a fixed one-byte read for every EEPROM access.
Python remains required for destructive integrity mode, there is no shell write
fallback. A missing explicitly selected file fails rather than selecting a
different device. Ordinary automatic mode still skips an absent or ambiguous
EEPROM.

Metadata-only EEPROM discovery for automatic adapter selection does not require
the data-read tools or apply the 1 MiB read limit. It does not read EEPROM data.
Missing read tools therefore do not prevent identification of an adapter for a
separately requested operation whose own prerequisites are available.

## Additional read-only coverage

These explicit modes work with ramdisk tools and do not require Python:

```sh
./run.sh --eeprom-mode matrix
./run.sh --eeprom-mode pm
```

`matrix` takes a baseline and compares repeated reads at the beginning, middle
and end of the selected range. It exercises lengths 1, 2, 3, 16, 32, 64 and the
selected range length where they fit, at most 21 comparisons. The default range
is the first `min(capacity, 4096)` bytes. A mismatch or transfer error fails.
This is sysfs read consistency coverage, not proof of a particular FIFO, DMA,
GPI or repeated-start transfer mode. The kernel driver controls those details.

`pm` takes a baseline, observes the selected client/controller ancestry for
natural runtime suspend for at most ten seconds, then verifies an identical
fresh read. It skips if no natural suspend is observed. It never writes
`power/control`, changes autosuspend delays, unbinds drivers, or suspends the
whole system. A post-idle read failure or mismatch fails. This is a read-after-
idle check, not exhaustive power-management transition coverage.

Select a device and read range explicitly when needed:

```sh
./run.sh --eeprom-mode matrix --eeprom-device "$EEPROM_PATH" \
    --eeprom-offset 0 --eeprom-length 256 --eeprom-timeout 60
I2C_EEPROM_MODE=pm I2C_EEPROM_DEVICE="$EEPROM_PATH" ./run.sh
```

The existing `I2C_EEPROM_MODE`, `I2C_EEPROM_DEVICE`, `I2C_EEPROM_OFFSET`,
`I2C_EEPROM_LENGTH` and `I2C_EEPROM_TIMEOUT` parameters apply to these modes.
CLI values override environment values. The suite bounds the complete EEPROM
operation with `--eeprom-timeout`, each shell data read also has a ten-second
watchdog with termination escalation. No multi-device operation is inferred
from enumeration order. Use explicit invocations for multiple EEPROMs.

Each shell-helper invocation retains a separate visible `eeprom-read.XXXXXX/`
directory under the suite results. Evidence includes `i2c_eeprom_candidates.tsv`, the EEPROM report,
read data and SHA-256 for probe mode, matrix expected/actual buffers and read
logs, and `i2c_runtime_pm.tsv` plus before/after buffers for PM mode.

Stuck-bus, NACK injection and recovery testing are not part of these modes.
They require a separately selected controlled fixture and a documented
injection/recovery interface. Never use automatic address scans or raw register
writes as a substitute for a fault injector on production peripherals.

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
- `--eeprom-mode auto|off|probe|integrity|matrix|pm`
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
- `FAIL`: controller or required-client runtime state is inconsistent, user
  input is malformed, an operation fails after its environment is available,
  a controller/client driver error is captured, or modified data cannot be
  restored and verified.
- `SKIP`: I2C or its character interface is unavailable, automatic EEPROM
  selection is absent or ambiguous, a required optional utility is missing,
  an optional camera is unbound, or natural runtime suspend is not observed.
  An explicitly selected missing EEPROM is `FAIL`.

Artifacts are retained under `results/Buses/`, including controller, adapter,
client, driver, dmesg, EEPROM discovery, digest, and restoration evidence.
The result is initialized before argument validation so a malformed invocation
cannot publish an earlier PASS. An unavailable selected operation does not
override an existing failure or bypass the final kernel-health checks.

### Topology completeness

`i2c_topology.tsv` records controller-to-adapter ownership. One unrelated working
adapter cannot satisfy another controller. Enabled CCI master buses require
their own runtime adapters, while a CCI parent with no enabled buses does not
create an adapter requirement. Enabled DT client nodes are reconciled against
exact runtime `of_node` identities, including nodes that never became clients.
Disabled ancestors are excluded. Mux channel links and enabled channel nodes are
checked against runtime adapters. Framework-owned adapter objects do not need a
client-style direct driver binding. Optional-camera readiness keeps its separate
classification, driver errors still fail independently.

### Client probe diagnostics

The controller-only kernel scan does not establish client health. The suite
also filters the retained `dmesg_snapshot.log` using client addresses, names,
bound drivers, and module candidates from `i2c_clients.tsv`. Matching lines are
saved verbatim in `i2c_client_dmesg.log`, including probe failures and their
supporting messages. No additional kernel-log capture, module loading, bus scan,
or hardware write is performed.

When runtime validation fails or an optional camera sensor is skipped, up to
120 client log lines are also printed to stdout. The complete filtered file
remains available for larger logs. An empty
file means no matching messages were retained, not that probing succeeded.
Unavailable kernel logs are reported without hiding an existing runtime FAIL.
Explicit errors from discovered I2C controller and client drivers are also
retained in `i2c_driver_errors.log` and printed with `I2C-DRIVER-ERROR` labels.
The full matching context is saved in `i2c_driver_dmesg.log`. Probe errors,
firmware-load failures, chip-ID read failures and other explicit driver errors
fail Buses even with `I2C_DMESG_STRICT=0`. The existing strict option still
controls additional findings from the legacy controller scan, it cannot
suppress this driver-error check. Errors remain failures even if the driver
subsequently binds successfully.

Normal initialization and dummy-regulator notices alone are not failures.
Matching covers runtime-discovered controllers, adapter identities and clients, including optional
cameras, not unrelated drivers elsewhere in the kernel. If the kernel snapshot
is unavailable, the check cannot certify driver health. No second kernel-log
capture or hardware operation is performed.

### Optional camera sensors

Buses validates controller and required-client readiness, not image capture.
An unbound optional camera sensor is recorded as an individual capture-readiness
SKIP while bus and kernel-health checks continue. Runtime DT identification
requires a `camera@...` or
`sensor@...` node with `compatible` and `reg` properties and a media endpoint
under `port` or `ports` exposing both `remote-endpoint` and `data-lanes`.
This conservative structural check uses no board, sensor-model, driver-name or
I2C-address list. A name alone is insufficient. Unclassified unbound clients,
including bridges and embedded controllers, remain FAIL, as do controller
failures. Bound cameras are still included in the bound-client inventory.

The skipped clients are listed in `i2c_optional_camera_clients.tsv` and their
probe evidence remains in the client diagnostic log and stdout. SKIP means
camera capture readiness is outside this bus check, not that disconnection was
proven.
A failed chip-ID read can also indicate a power, reset, wiring or driver issue.
Camera functionality belongs to `Libcamera_cam` or `Camera_NHX`, using the
appropriate stack and an attached sensor. Those suites may themselves SKIP
when their required environment is unavailable, so a Buses PASS is not proof
of camera coverage or health.

For a setup without cameras, the default `./run.sh` may PASS its bus checks
with a camera SKIP only when no other gating failure is observed. A captured
camera probe error still makes the overall result FAIL, even if the camera
is known to be disconnected. Disable the unused camera DT node or omit its
optional overlay in that setup to avoid attempting an invalid probe. A camera
SKIP cannot hide an embedded-controller or other driver failure. Explicitly
requested
I2C scans, register operations and EEPROM checks keep their existing result
policy. No DT nodes, overlays, services or drivers are modified by the test.
