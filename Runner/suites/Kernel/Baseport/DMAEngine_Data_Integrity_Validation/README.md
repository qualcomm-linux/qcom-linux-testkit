# DMAEngine data-integrity validation

`DMAEngine_Data_Integrity_Validation` uses the upstream kernel `dmatest`
driver to perform bounded DMA memcpy operations with verification enabled.
`dmatest` initializes source and destination buffers with different patterns,
executes DMA transfers at varied offsets and lengths, and verifies the copied
region, untouched bytes, byte ordering, and source-buffer integrity.

This is stronger evidence of a working DMA data path than traffic counters
alone. It can expose DMA driver, mapping, cache-maintenance, or data-corruption
problems, but it does not identify CCI as the unique cause of a failure.

## Options

```text
--channel NAME|auto
--iterations N
--timeout-ms N
--run-timeout N
```

The equivalent LAVA environment variables are `DMA_CHANNEL`, `ITERATIONS`,
`TIMEOUT_MS`, and `RUN_TIMEOUT_SECONDS`. Command-line values take precedence.

With `auto`, the suite selects the first idle channel accepted by `dmatest`.
Use an explicit channel when the platform reserves particular DMA channels for
validation.

The suite records the running kernel's `CONFIG_DMATEST` value before checking
the runtime driver. It skips with an image-build recommendation when the option
is disabled or the running-kernel configuration is unavailable. If
`CONFIG_DMATEST=m` declares module support but the matching `dmatest.ko` is
missing, or `CONFIG_DMATEST=y` is reported without the built-in runtime
parameters, the suite fails because the running image is incomplete or broken.
Modules found only under a different kernel tree are not loaded.
It refuses to interrupt an existing dmatest run or configured test list. If it
loads the module, it unloads only that module. For a pre-existing idle module,
it restores scalar parameters after releasing the selected channel.

Kernel log snapshots and the new dmatest result lines are retained for LAVA
triage. No package is installed at runtime.
