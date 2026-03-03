# FastRPC Test Script for Qualcomm Linux-based Platforms (Yocto)

## Overview

The **fastrpc_test** runner validates FastRPC (Fast Remote Procedure Call) on Qualcomm targets, offloading work to DSP domains (e.g., **CDSP**).  
It wraps the public [fastrpc test application](https://github.com/quic/fastrpc) with **robust logging, parameter control, and CI-friendly output**.

Supported capabilities:
- Auto-detect architecture from SoC ID.
- Multiple iterations and optional timeouts.
- Precise control over where the binary and assets live via `--bin-dir` and `--assets-dir`.
- Unbuffered output via `stdbuf` or `script` when available (falls back gracefully).

## Features

- **Calculator**, **HAP**, and **Multithreading** examples (as provided by `fastrpc_test`)
- CI-ready logs with timestamps and per-iteration results
- Parameterized control (`--arch`, `--repeat`, `--timeout`, `--bin-dir`, `--assets-dir`, `--verbose`)
- Auto-detection fallback for binary and assets
- Silent directory scan (no noisy `ls` dumps)

## Prerequisites

Have these on the target (or specify paths with the flags below):

- `fastrpc_test` binary (from [github.com/quic/fastrpc](https://github.com/quic/fastrpc))
- A **parent directory** that contains a `linux/` subfolder with the required libraries (often alongside the binary), and architecture folders such as `v68`, `v73`, `v75`.
- Optional but recommended:
  - `stdbuf` **or** `script` (for unbuffered stdout/stderr)
  - `timeout` (GNU coreutils) for wall-clock limiting; the script provides a portable fallback if missing.

## Directory Structure

```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── CDSP/
│   │   │   ├── fastrpc_test/
│   │   │   │   ├── run.sh
│   │   │   │   ├── fastrpc_test_README.md 
```

## Usage

### Script arguments

```
Usage: run.sh [OPTIONS]

Options:
  --arch <name> Architecture (only if explicitly provided)
  --bin-dir <path> Directory containing 'fastrpc_test' (default: /usr/bin)
  --assets-dir <path> Directory that CONTAINS 'linux/' (info only; we run from the binary dir)
  --user-pd Use '-U 1' (user/unsigned PD). Default is '-U 0'.
  --repeat <N> Number of repetitions (default: 1)
  --timeout <sec> Timeout for each run (no timeout if omitted)
  --verbose Extra logging for CI debugging
  --help Show this help

Env:
  FASTRPC_USER_PD=0|1 Sets PD (-U value). CLI --user-pd overrides to 1.
  FASTRPC_EXTRA_FLAGS Extra flags appended to the command.
  ALLOW_BIN_FASTRPC=1 Permit using /bin/fastrpc_test (otherwise refused).

The test executes FROM the assets directory so 'fastrpc_test' can find deps.
```

### Quick start

```bash
# If fastrpc_test is already in PATH and assets are discoverable:
./run.sh --repeat 3 --timeout 60
```

### Common scenarios

```bash
# Default expects /usr/bin/fastrpc_test and /usr/bin/linux
./run.sh

Common scenarios

# 1) Use a custom binary directory (we will cd there and run ./fastrpc_test)
./run.sh --bin-dir /tmp/stage/usr/bin

# 2) Opt into user/unsigned PD (-U 1)
./run.sh --user-pd
# or via env
FASTRPC_USER_PD=1 ./run.sh

# 3) Add extra flags (kept intact; -U is appended last as '-U 0/1')
FASTRPC_EXTRA_FLAGS="-d 3" ./run.sh

# 4) Allow /bin explicitly (generally discouraged unless required)
ALLOW_BIN_FASTRPC=1 ./run.sh --bin-dir /bin

# 5) Run multiple iterations with a timeout and verbose logs
./run.sh --repeat 3 --timeout 120 --verbose

Force CDSP explicitly:
  
# 6) ./run.sh --domain 3
# or
# 6) ./run.sh --domain-name cdsp
 
Use ADSP and user PD:
  
# 7) ./run.sh --domain-name adsp --user-pd
 
From env (CI):
 
FASTRPC_DOMAIN=2 FASTRPC_USER_PD=1 ./run.sh
# => SDSP with -U 1
```

### LAVA integration example

```
- $PWD/suites/Multimedia/CDSP/fastrpc_test/run.sh --bin-dir /usr/bin || true
- $PWD/utils/send-to-lava.sh $PWD/suites/Multimedia/CDSP/fastrpc_test/fastrpc_test.res || true
```

### Sample output (trimmed)

```
[INFO] 2025-09-02 10:44:46 - -------------------Starting fastrpc_test Testcase----------------------------
[INFO] 2025-09-02 10:44:46 - Using binary: /usr/bin/fastrpc_test
[INFO] 2025-09-02 10:44:46 - PD setting: -U 0 (use --user-pd to set -U 1)
[INFO] 2025-09-02 10:44:46 - Run dir: /usr/bin (launching ./fastrpc_test)
[INFO] 2025-09-02 10:44:46 - Executing: ./fastrpc_test -d 3 -t linux -U 0
----- iter1 output begin -----
... fastrpc_test output ...
----- iter1 output end -----
[PASS] 2025-09-02 10:44:50 - iter1: success
[PASS] 2025-09-02 10:44:50 - fastrpc_test : Test Passed (1/1)
```

## CI debugging aids
- Binary resolved to /bin/fastrpc_test: By default this is blocked to avoid loader/ramdisk mismatches. Set ALLOW_BIN_FASTRPC=1 and/or --bin-dir /bin if you intentionally need it.
- Error resolving path .../linux: Ensure linux/ is next to the binary (e.g., /usr/bin/linux). The script runs from the binary dir specifically to make this work.
- Session create errors with -U 1: If you opt into user/unsigned PD and see 0x80000416, confirm your image includes unsigned shells/policies (or revert to the default -U 0).
- Per-iteration logs: `logs_fastrpc_test_<timestamp>/iterN.out` (+ `iterN.rc`)
- Summary result file: `fastrpc_test.res` (`PASS` / `FAIL`)
- Verbose mode: adds environment, resolutions, and timing details
- Graceful fallbacks when `stdbuf`, `script`, or `timeout` are missing
- Silent scan (no directory spam) during auto-detection

## Notes

- If `--arch` is omitted, the script maps `/sys/devices/soc0/soc_id` to a known arch (defaulting to `v68` when unknown).
- If `fastrpc_test` isn’t in `PATH`, use `--bin-dir` or add it to `PATH`.
- If you see `Error resolving path .../linux: No such file or directory`, point `--assets-dir` to the **parent** directory that actually contains a `linux/` subfolder.
- The script changes working directory to the resolved **assets** dir before invoking `fastrpc_test`, which is required for the binary to locate its shared libs/skeletons.

## License

SPDX-License-Identifier: BSD-3-ClauseCopyright (c) Qualcomm Technologies, Inc.
