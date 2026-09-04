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

## Results

- `PASS`: applicable controllers, adapters, and declared clients have a
  consistent runtime state.
- `FAIL`: an enabled controller lacks a runtime adapter or driver, a declared
  client is unbound or waiting for an unresolved supplier, an installed
  diagnostic fails, or an enabled functional test fails.
- `SKIP`: I2C is not exposed, or an optional tool or functional test is not
  available.

Artifacts are retained under `results/Buses/`, including controller, adapter,
client, registered-driver, modalias, module-origin, supplier-wait, DT-resource,
and mux-channel evidence for diagnosing unbound clients.
