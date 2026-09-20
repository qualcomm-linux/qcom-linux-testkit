Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# RMTFS QMI Service Validation

Uses `qrtr-lookup` to validate the service published by public
`linux-msm/rmtfs`:

- service: `14`
- version: `1`
- instance: `0`

The lookup uses the shared bounded QRTR topology helper. The same retained
inventory and service-matching contract can be reused by FastRPC diagnostics
and focused PD Mapper, TQFTP, and time-service validation without duplicating
QRTR parsing or introducing unbounded waits.

The values can be overridden with `RMTFS_QMI_SERVICE`, `RMTFS_QMI_VERSION`, and
`RMTFS_QMI_INSTANCE` for a documented downstream implementation. The bounded
lookup defaults to ten seconds and can be adjusted with
`QRTR_LOOKUP_TIMEOUT`.

On an applicable mainline platform, the suite temporarily loads `rmtfs_mem`
and starts the image-provided service when necessary. Failure to start the
daemon is a test failure. It returns `SKIP` for non-RMTFS platforms, legacy
`rmt_storage` deployments, or images without the optional `qrtr-lookup`
diagnostic. Module and service state are restored after the lookup.

```sh
cd Runner
./run-test.sh RMTFS_QMI_Service_Validation
```

Run the suite directly on the target when investigating the service:

```sh
cd Runner/suites/Kernel/Baseport/Storage/RMTFS_QMI_Service_Validation
./run.sh
```

Without overrides, this validates service `14`, version `1`, instance `0`,
using a ten-second bounded QRTR lookup. The effective values are printed at
startup.

Optionally override the default bounded lookup timeout:

```sh
QRTR_LOOKUP_TIMEOUT=20 ./run.sh
```

Check the result and retained QRTR topology:

```sh
cat RMTFS_QMI_Service_Validation.res
test -r qrtr_lookup_rmtfs.log && cat qrtr_lookup_rmtfs.log
```

An applicable RMTFS platform fails when the bounded query is broken or the
expected `14 1 0` service row is absent. A platform without runtime RMTFS
evidence, or an image without optional `qrtr-lookup`, is reported as SKIP.
