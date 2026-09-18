# FastRPC Test Script for Qualcomm Linux-based Platforms

## Overview

The **fastrpc_test** runner validates FastRPC (Fast Remote Procedure Call) on Qualcomm targets,
offloading work to all supported DSP domains (ADSP, MDSP, SDSP, CDSP, CDSP1, GDSP0, GDSP1).
It wraps the public [fastrpc test application](https://github.com/quic/fastrpc) with **robust
logging, parameter control, and CI-friendly output**.

Supported capabilities:
- Uses `fastrpc-healthcheck` when available to discover online DSPs, FastRPC support, signed and
  unsigned PD support, firmware information, DSP library paths, and DMA-BUF heap readiness.
- When healthcheck is unavailable, discovers runnable domains from remoteproc state and FastRPC
  character endpoints. The fallback cannot discover PD support directly, so it uses the documented
  conservative protocol map. Host, test, and DSP skeleton libraries remain runtime-discovered.
- Multiple iterations with a required finite timeout.
- Precise control over binary location via `--bin-dir`.
- Line-buffered output through `stdbuf` when available.

## Features

- **Calculator**, **HAP**, and **Multithreading** examples (as provided by `fastrpc_test`)
- CI-ready logs with timestamps and per-iteration, per-domain/PD results
- Parameterized control (`--arch`, `--repeat`, `--timeout`, `--bin-dir`, `--domain-mode`,
  `--domain`, `--domain-name`, `--pd-mode`, `--unsigned-pd`, `--verbose`)
- Auto-discovery of system libraries and DSP skeletons for both Yocto and Debian layouts
- Runtime domain and PD discovery without SoC-name filtering

## Prerequisites

Have these on the target (or specify paths with the flags below):

- `fastrpc_test` binary (from [github.com/quic/fastrpc](https://github.com/quic/fastrpc))
- Optional `fastrpc-healthcheck`. When installed, this is the primary distro-independent
  capability source.
- FastRPC system libraries and DSP skeletons auto-discovered from standard locations:
  - Yocto: `/usr/local/lib`, `/usr/local/lib/fastrpc_test`, `/usr/local/share/fastrpc_test`
  - Debian: `/usr/lib/<multiarch>`, `/usr/lib/<multiarch>/fastrpc_test`, `/usr/share/fastrpc_test`
  - RPM-based images: `/usr/lib64`, `/usr/lib64/fastrpc_test`, `/usr/share/fastrpc_test`
- Optional but recommended:
  - `stdbuf` for line-buffered output. Execution remains bounded without it.

## Directory Structure

```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── CDSP/
│   │   │   ├── fastrpc_test/
│   │   │   │   ├── run.sh
│   │   │   │   ├── fastrpc_test_README.md
│   │   │   │   ├── fastrpc_test.yaml
```

## Usage

### Script arguments

```
Usage: run.sh [OPTIONS]

Options:
  --arch <name>                    Architecture (only if explicitly provided)
  --bin-dir <path>                 Directory containing 'fastrpc_test' (default: /usr/bin)
  --domain <0|1|2|3|4|5|6>        DSP domain: 0=ADSP 1=MDSP 2=SDSP 3=CDSP 4=CDSP1 5=GDSP0 6=GDSP1
  --domain-name <name>             DSP domain: adsp|mdsp|sdsp|cdsp|cdsp1|gdsp0|gdsp1
  --domain-mode <all-supported|single>  Discover all domains or run only one (default: all-supported)
  --pd-mode <both|signed-only|unsigned-only>  Select PD mode(s) to run (default: both)
  --unsigned-pd                    Use '-U 1' (user/unsigned PD). Overrides --pd-mode.
  --repeat <N>                     Number of repetitions (default: 1)
  --timeout <sec>                  Timeout for each run (default: 120, must be greater than zero)
  --healthcheck-timeout <sec>      Timeout for fastrpc-healthcheck (default: 15)
  --verbose                        Extra logging for CI debugging
  --help                           Show this help

Env:
  FASTRPC_DOMAIN=0|1|2|3|4|5|6    Sets domain; CLI --domain/--domain-name wins.
  FASTRPC_DOMAIN_NAME=adsp|...     Named domain; CLI wins.
  FASTRPC_UNSIGNED_PD=0|1          Sets PD (-U value). CLI --unsigned-pd overrides to 1.
  FASTRPC_EXTRA_FLAGS              Extra flags appended (space-separated).
  FASTRPC_HEALTHCHECK_BIN          Optional path to fastrpc-healthcheck.
  ALLOW_BIN_FASTRPC=1              Permit using /bin/fastrpc_test when --bin-dir=/bin.
```

### Quick start

```bash
# Default: dynamically discover runnable domains and supported PD modes
./run.sh

# With repeat and timeout:
./run.sh --repeat 3 --timeout 60
```

### Common scenarios

```bash
# 1) Use a custom binary directory
./run.sh --bin-dir /tmp/stage/usr/bin

# 2) Run only unsigned (user) PD across all domains
./run.sh --pd-mode unsigned-only

# 3) Run only signed PD
./run.sh --pd-mode signed-only

# 4) Force a specific domain (CDSP)
./run.sh --domain 3
# or by name:
./run.sh --domain-name cdsp

# 5) Force GDSP0 with unsigned PD
./run.sh --domain-name gdsp0 --pd-mode unsigned-only

# 6) Run SDSP via environment variable with unsigned PD
FASTRPC_DOMAIN=2 FASTRPC_UNSIGNED_PD=1 ./run.sh

# 7) Run multiple iterations with verbose logs
./run.sh --repeat 3 --timeout 120 --verbose

# 8) Allow /bin explicitly (generally discouraged)
ALLOW_BIN_FASTRPC=1 ./run.sh --bin-dir /bin
```

### LAVA integration example

```
- $PWD/suites/Multimedia/CDSP/fastrpc_test/run.sh --bin-dir /usr/bin || true
- $PWD/utils/send-to-lava.sh $PWD/suites/Multimedia/CDSP/fastrpc_test/fastrpc_test.res || true
```

### Sample output (trimmed)

```
[INFO] 2025-09-02 10:44:46 - -------------------Starting fastrpc_test Testcase----------------------------
[INFO] 2025-09-02 10:44:46 - Domain mode: all-supported
[INFO] 2025-09-02 10:44:46 - Domains to test: 0 3
[INFO] 2025-09-02 10:44:46 - PD mode: both
[INFO] 2025-09-02 10:44:46 - Running ADSP_signed_iter1 | domain=ADSP | pd=signed
[INFO] 2025-09-02 10:44:46 - Executing: ./fastrpc_test -d 0 -t linux -U 0
----- ADSP_signed_iter1 output begin -----
... fastrpc_test output ...
----- ADSP_signed_iter1 output end -----
[PASS] 2025-09-02 10:44:50 - ADSP_signed_iter1: success
...
[INFO] ================================================================================
[INFO]  FastRPC Test Summary
[INFO] ================================================================================
[INFO] Domain     | PD Mode     |  Total |   Pass |   Fail |   Skip | Status
[INFO] --------------------------------------------------------------------------------
[INFO] ADSP       | Signed      |      5 |      5 |      0 |      0 | PASS
[INFO] CDSP       | Signed      |      5 |      5 |      0 |      0 | PASS
[INFO] CDSP       | Unsigned    |      5 |      5 |      0 |      0 | PASS
[PASS] 2025-09-02 10:44:50 - fastrpc_test : Test Passed (3/3)
```

## CI debugging aids

- **Capability source**: The startup log reports `capability_source`, `domain_source`, and
  `pd_source`. Raw and normalized healthcheck output is retained in the run log directory.
- **Offline automatic domain**: Logged and excluded from automatic selection. Other runnable
  domains continue.
- **Offline explicitly requested domain**: Fails with the healthcheck or remoteproc state.
- **Missing runtime artifacts**: Skips before executing `fastrpc_test` and prints the missing
  system library, test library, or skeleton evidence.
- **Binary resolved to /bin/fastrpc_test**: Blocked by default. Set `ALLOW_BIN_FASTRPC=1` or
  use `--bin-dir` to a non-`/bin` path.
- **Session create errors with -U 1**: If unsigned PD returns `0x80000416`, confirm your image
  includes unsigned shells/policies (or use `--pd-mode signed-only`).
- **Domain not discovered**: Check `dmesg` for remoteproc firmware load errors. The test
  requires the DSP remoteproc to be registered and its firmware present in DT.
- **Per-iteration logs**: `logs_fastrpc_test_<timestamp>/<domain>_<pd>_iter<N>.out` (+ `.rc`, `.env`, `.cmd`)
- **Summary result file**: `fastrpc_test.res` (`PASS` / `FAIL` / `SKIP`)
- **Verbose mode**: adds environment, library resolution, and timing details

## Notes

- Domain and PD support are derived from `fastrpc-healthcheck` when available. The fallback uses
  runtime remoteproc and endpoint evidence, with a conservative protocol mapping for PD support.
- This suite runs the public `fastrpc_test` character-device path and therefore requires either
  `/dev/fastrpc-<domain>` or `/dev/fastrpc-<domain>-secure` for every selected domain.
- DSP skeleton directories are discovered dynamically by locating `.so` artifacts instead of
  assuming fixed ABI directory names such as `v68` or `v75`.
- Override library discovery with `FASTRPC_LIB_SYS_DIR`, `FASTRPC_LIB_TEST_DIR`, or
  `FASTRPC_SKEL_BASE`. CLI domain selection takes precedence over environment selection, which
  takes precedence over runtime discovery.
- If `fastrpc_test` is not in the default path, use `--bin-dir` to specify its location.

## License

SPDX-License-Identifier: BSD-3-Clause
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
