# I2C Buses Validation

This suite performs a read-only, capability-driven I2C runtime validation. It
correlates enabled Qualcomm GENI I2C device-tree controllers with kernel
adapters and registered clients, reports driver binding, dynamically resolves
client modaliases against the running image, and retains bounded inventory and
kernel-health artifacts. It does not use board-specific client-to-driver
mappings.

The default run does not scan arbitrary bus addresses or read device registers.
Those operations can disturb devices whose protocols are not known to the
test. When the image provides `i2c-msm-test`, the compatibility path runs
automatically against the selected character device. It can be disabled or
explicitly required through configuration.

On Debian, Ubuntu, and CentOS, the suite recovers the standard `i2c-tools`
package after I2C applicability is established. The default path uses
`i2cdetect -l` and `i2cdetect -F` to list adapters and query controller
functionality without probing peripheral addresses. Yocto and qcom-distro
remain image-managed and do not install packages. The Qualcomm-specific
`i2c-msm-test` utility remains optional and image-provided on every distro.

## Run

```sh
cd Runner/suites/Kernel/Baseport/Buses
./run.sh
```

Require legacy functional validation on the first exposed character device:

```sh
./run.sh --legacy-test
```

Select a validated adapter and timeout explicitly:

```sh
./run.sh --legacy-test --adapter 0 --timeout 20
```

Equivalent environment variables are:

```sh
I2C_LEGACY_TEST_ENABLE=1 I2C_TEST_ADAPTER=0 I2C_TEST_TIMEOUT=20 I2C_DMESG_STRICT=1 ./run.sh
```

## Explicit i2c-tools operations

The following operations can affect attached devices and never run by default.
The suite auto-selects the adapter only when exactly one I2C character adapter
exists. Select it explicitly on multi-adapter systems and obtain addresses and
registers from the board or peripheral documentation.

Scan one adapter using SMBus quick-write probes:

```sh
./run.sh --adapter 1 --scan --scan-mode quick
```

Quick-write probing can corrupt some EEPROM-style devices.

Use SMBus receive-byte probes instead when the selected devices require them:

```sh
./run.sh --adapter 1 --scan --scan-mode read
```

Receive-byte probing can also confuse devices or leave them in an unexpected
state. Use either scan mode only when the selected bus topology is understood.

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

Register writes require explicit confirmation. The suite reads the original
value first, rejects a test value equal to the original value, verifies the
write, restores the original value, and verifies restoration. Restoration
cannot undo device behavior triggered immediately by a write, so only a
documented test or scratch register should be selected.

## Results

- `PASS`: applicable controllers, adapters, and declared clients have a
  consistent runtime state, adapter capability queries pass, and every
  explicitly requested scan or register transaction succeeds.
- `FAIL`: an enabled controller lacks a runtime adapter or driver, a declared
  client is unbound or waiting for an unresolved supplier, an installed
  diagnostic fails, an explicit scan or read fails, or a write cannot be
  verified and restored.
- `SKIP`: I2C is not exposed, or an optional tool or functional test is not
  available.

Artifacts are retained under `results/Buses/`, including controller, adapter,
client, registered-driver, modalias, module-origin, supplier-wait, DT-resource,
and mux-channel evidence for diagnosing unbound clients.
