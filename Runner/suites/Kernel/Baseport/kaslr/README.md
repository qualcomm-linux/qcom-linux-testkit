# KASLR validation

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

```sh
cd Runner/suites/Kernel/Baseport/kaslr
./run.sh
cat kaslr.res
```

The suite uses `kaslr_check_runtime` in `functestlib.sh` to check activation
on the running kernel. It supports Yocto, Debian, Ubuntu, CentOS and shell-only
ramdisks using the same runtime evidence, without SoC or board mappings.

- PASS requires the exact current-boot kernel message `KASLR enabled`.
  The equivalent `KASLR: enabled` format is also accepted.
  Hidden kallsyms addresses or an unavailable kernel configuration do not
  prevent PASS when this message confirms activation.
- FAIL means `nokaslr` is a standalone boot argument, the running configuration
  explicitly disables `CONFIG_RANDOMIZE_BASE`, or the kernel reports
  `KASLR disabled ...` or `Kernel Offset: disabled`. Disable evidence takes
  precedence over an activation message, including `KASLR: disabled` formats.
  Artifact or parser errors also fail.
- SKIP means runtime activation cannot be verified because the kernel log is
  inaccessible or the early activation message is absent. The reason identifies
  the missing evidence. An enabled config, nonzero text address, nonzero offset
  or KPTI message alone does not prove KASLR activation.

The test does not reboot, alter boot arguments, change kernel-log permissions
or verify randomness across reboots. `CONFIG_RANDOMIZE_BASE` is the relevant
kernel option, searching config names for `kaslr` will not find it.

`./run.sh --help` prints usage. The suite accepts no other options. For manual
confirmation using already installed tools:

```sh
# Compressed configuration is optional, the suite also searches matching
# /boot/config-$(uname -r) and running-kernel build/header configuration files.
zcat /proc/config.gz | grep -E 'CONFIG_RANDOMIZE_BASE|CONFIG_RANDOMIZE_MODULE_REGION_FULL'
cat /proc/cmdline
# Inspect the retained capture rather than requesting a second kernel-log scan.
cat results/kaslr/run-*/kaslr_boot_evidence.log
```

The result stays beside `run.sh`. Kernel diagnostics are retained under
the invocation CWD in separate `results/kaslr/run-*` directories. Each directory
contains `kaslr_runtime.log` (kernel/config/cmdline and diagnostic symbol data),
`kaslr_boot_evidence.log`, `dmesg_snapshot.log`, `dmesg_errors.log` and
`dmesg_access.log`. Decisive evidence is also printed to stdout. The shared
capture helper uses the current boot only, including its existing optional
`KERNEL_LOG_JOURNAL_FALLBACK=1` path when journalctl is already available.
Only image-provided tools are used, no packages are installed at runtime.
