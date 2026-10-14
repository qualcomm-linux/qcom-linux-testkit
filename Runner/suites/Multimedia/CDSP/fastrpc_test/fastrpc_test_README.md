# FastRPC Test Script for Qualcomm Linux-based Platforms

## Overview

The **fastrpc_test** runner validates FastRPC (Fast Remote Procedure Call) on Qualcomm targets,
offloading work to all supported DSP domains (ADSP, MDSP, SDSP, CDSP, CDSP1, GDSP0, GDSP1).
It wraps the public [fastrpc test application](https://github.com/quic/fastrpc) with **robust
logging, parameter control, and CI-friendly output**.

When QRTR and `qrtr-lookup` are available, the suite captures one bounded QRTR
service-topology snapshot with its normal artifacts. This remains diagnostic
evidence and does not make QRTR a prerequisite for FastRPC transports on other
platforms. `QRTR_LOOKUP_TIMEOUT` optionally overrides the ten-second default.

Supported capabilities:
- Uses `fastrpc-healthcheck` when available to discover online DSPs, FastRPC support, signed and
  unsigned PD support, firmware information, and DSP library paths. The reported DMA-BUF system
  heap state is retained and logged as a diagnostic because the healthcheck documents it as
  informational rather than a FastRPC execution gate.
- When healthcheck is unavailable, discovers runnable domains from remoteproc state and FastRPC
  character endpoints. The fallback cannot discover PD support directly, so it uses the documented
  conservative protocol map. The fallback recognizes both `sdsp` and the public `slpi` remoteproc
  identity for the sensor DSP. Host, test, and DSP skeleton libraries remain runtime-discovered.
  The functional invocation is the final capability proof. If an older or vendor-specific test
  payload cannot represent a runtime-ready domain, that invocation is reported as FAIL without
  relying on package-version or distribution checks.
- Multiple iterations with a required finite timeout.
- Precise control over binary location via `--bin-dir`.
- Line-buffered output through `stdbuf` when available.

## Features

- **Calculator**, **HAP**, and **Multithreading** examples (as provided by `fastrpc_test`)
- CI-ready logs with timestamps and per-iteration, per-domain/PD results
- Parameterized control (`--arch`, `--repeat`, `--timeout`, `--bin-dir`, `--domain-mode`,
  `--domain`, `--domain-name`, `--pd-mode`, `--unsigned-pd`, `--verbose`)
- Auto-discovery of system libraries and DSP skeletons for Yocto, Debian, Ubuntu, and RPM layouts
- Runtime domain and PD discovery without SoC-name filtering
- Automatic readiness checks for enabled FastRPC DT declarations, independent of
  successful remoteproc registration

## Prerequisites

Have these on the target (or specify paths with the flags below):

- `fastrpc_test` binary (from [github.com/quic/fastrpc](https://github.com/quic/fastrpc)).
  Supported Debian and Ubuntu image repositories provide it through the
  `fastrpc-tests` package. The mapped runtime set also includes
  `fastrpc-support`.
- Optional `fastrpc-healthcheck`. When installed, this is the primary distro-independent
  capability source. An installed healthcheck that fails, times out, or produces an
  unrecognized or malformed report fails the suite. Runtime fallback is used only when the tool
  is absent.
- FastRPC system libraries and DSP skeletons auto-discovered from standard locations:
  - Yocto: `/usr/local/lib`, `/usr/local/lib/fastrpc_test`, `/usr/local/share/fastrpc_test`
  - Debian/Ubuntu: `/usr/lib/<multiarch>`, `/usr/lib/<multiarch>/fastrpc_test`, `/usr/share/fastrpc_test`
  - CentOS and other RPM-based images: `/usr/lib64`, `/usr/lib64/fastrpc_test`, `/usr/share/fastrpc_test`
- A selected DSP skeleton directory must contain the complete calculator, HAP example, and
  multithreading skeleton set. Discovered directories are prepended to the semicolon-separated
  `DSP_LIBRARY_PATH` used by the public `fastrpc_test` utility while preserving existing DSP
  search entries. The same merged value is exported through the domain-specific library paths.
- Optional but recommended:
  - `stdbuf` for line-buffered output. Execution remains bounded without it.
- When the default `/usr/bin/fastrpc_test` is missing on Debian or Ubuntu, the
  suite uses the shared package provider to recover the complete mapped
  `fastrpc-support fastrpc-tests` set from the target's configured APT sources.
  It does not add Debian `qli` sources on Ubuntu.
- Yocto, CentOS, and distributions without an exact package mapping remain
  image-managed and report SKIP when the binary is absent. A missing binary in
  an explicitly selected `--bin-dir` also reports SKIP without package changes.
  These skips apply only after expected kernel registration passes the preflight
  below. A registration failure takes precedence over a missing test payload.
- Missing optional image assets are reported as SKIP unless the operator explicitly selected a
  domain whose required runtime library is absent.

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
  --domain-name <name>             DSP domain: adsp|mdsp|sdsp|slpi|cdsp|cdsp1|gdsp0|gdsp1
  --domain-mode <all-supported|single>  Discover all domains or run only one (default: all-supported)
  --pd-mode <both|signed-only|unsigned-only>  Select PD mode(s) to run (default: both)
  --unsigned-pd                    Use '-U 1' (user/unsigned PD). Overrides --pd-mode.
  --repeat <N>                     Number of repetitions (default: 1)
  --timeout <sec>                  Timeout for each run (default: 120, must be greater than zero)
  --healthcheck-timeout <sec>      Timeout for fastrpc-healthcheck (default: 15)
  --verbose                        Extra logging for CI debugging
  --help                           Show this help

Env:
  FASTRPC_DOMAIN=0|1|2|3|4|5|6    Forces one domain; CLI --domain/--domain-name wins.
  FASTRPC_DOMAIN_NAME=adsp|...     Forces one named domain; CLI wins.
  FASTRPC_UNSIGNED_PD=0|1          Sets PD (-U value). CLI --unsigned-pd overrides to 1.
  FASTRPC_EXTRA_FLAGS              Extra flags appended (space-separated).
  FASTRPC_HEALTHCHECK_BIN          Optional path to fastrpc-healthcheck.
  ALLOW_BIN_FASTRPC=1              Permit using /bin/fastrpc_test when --bin-dir=/bin.
  QRTR_LOOKUP_TIMEOUT=<sec>        Bound optional QRTR diagnostics (default: 10).
```

### Quick start

```bash
# Default: validate DT-declared domains and discover runnable domains/PD modes
./run.sh

# With repeat and timeout:
./run.sh --repeat 3 --timeout 60
```

To override the default bounded QRTR diagnostic window:

```sh
QRTR_LOOKUP_TIMEOUT=20 ./run.sh --repeat 1 --timeout 60
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

Domain selection uses `CLI > environment > dynamic discovery` precedence. A non-empty
`FASTRPC_DOMAIN_NAME` or `FASTRPC_DOMAIN` selects one domain even when `--domain-mode` remains at
its `all-supported` default. `--domain-mode single` without a CLI or environment domain is invalid.
An explicitly selected domain fails when it is unavailable, lacks its runtime library, or does not
support the requested PD mode. Automatic selection from the runtime fallback excludes domains
without complete remoteproc and endpoint evidence. When `fastrpc-healthcheck` reports an online,
FastRPC-supported domain, a missing endpoint or required runtime library is treated as a broken
installation and fails the suite. The runner does not infer client capability from a distro name or
package version. When runtime fallback discovers a domain but the installed `fastrpc_test` payload
reports that it cannot represent that domain, the invocation is classified as FAIL so the image or
package gap remains visible until a matching payload is provisioned. Other domains still execute.

Automatic selection also reads enabled FastRPC declarations from the running DT,
using the public `qcom,fastrpc` and `qcom,kaanapali-fastrpc` driver match entries
and their `label` property. Newer compatibles with the kaanapali fallback are
covered. A context-bank node or a generic DSP node alone is not an expectation.
The FastRPC node and every ancestor must have absent, `okay`, or `ok` status.
Disabled ancestors therefore do not create false failures.

A mapped DT-declared domain is checked even if healthcheck omits it or reports it
offline/unsupported, or remoteproc registration and the endpoint are absent.
Missing readiness, endpoints, or required runtime libraries record FAIL while
other healthy domains continue. Missing optional shared test assets cannot
overwrite an already recorded readiness failure with SKIP. With no DT or no
enabled FastRPC declarations, the existing healthcheck/runtime fallback remains
in effect. Failed DT traversal, unreadable properties, or a missing required
FastRPC label fail discovery. Labels outside the suite's protocol map are logged
as untestable, not guessed or mapped to another DSP.

Explicit CLI or environment selection checks only the requested domain, without
requiring DT discovery. No SoC/board lists, distro gates, new parameters, or new
package installation paths are introduced.

When the test binary is absent, a read-only registration preflight runs before
the missing-payload SKIP or existing package-provider handling. It checks every
DT-expected domain, or only the explicitly selected domain, for a running
remoteproc and a normal or secure FastRPC endpoint. Missing/offline registration,
missing endpoints, invalid explicit selection and DT discovery failures report
FAIL even without `fastrpc_test`. Healthy registration is logged as readiness,
never as functional PASS. If registration is healthy or no domain is expected,
the existing binary/package policy proceeds, including SKIP for missing optional
payloads on image-managed systems. This preflight neither loads modules nor
starts remoteprocs, creates endpoints, or installs packages.

The installed-binary path is unchanged and still prefers `fastrpc-healthcheck`
for execution capability, with the existing remoteproc fallback when absent.
The missing-binary preflight checks kernel registration only, it cannot prove
client support, PD support or functional RPC execution.

Automatic mode uses only the running system's enabled FastRPC DT declarations
and discovered runtime capabilities. If CDSP is absent from both DT and runtime,
other discovered domains continue, or the suite reports SKIP when none apply.
Removed or disabled DT nodes do not create historical or board-specific domain
requirements. A domain still exposed by runtime discovery remains eligible even
without an enabled DT declaration. Triage determines whether absent hardware was
intentional. Enabled DT declarations with missing/offline registration still fail.
Explicit `--domain-name cdsp` continues to check CDSP only and fails when it is
unavailable. No mandatory-domain CI policy or new requirement option is introduced.

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
  `pd_source`, plus the healthcheck system-heap status when available. Whenever healthcheck is
  executed, its raw output is retained. A normalized six-column table containing domain, state,
  signed-PD support, unsigned-PD support, normalized FastRPC support, and the support reason is
  retained only when strict parsing succeeds.
- **Offline or unsupported automatic domain**: FAIL when an enabled FastRPC DT declaration
  expects it, otherwise logged and excluded. Other runnable domains continue.
- **DT expectation evidence**: `fastrpc_dt_expected_domains.log` records numeric ID, label,
  full node path and compatible list as tab-separated fields. The checked traversal paths
  and errors are retained in `fastrpc_dt_compatible_paths.log` and `fastrpc_dt_scan_errors.log`.
- **Test payload lacks a runtime-ready domain**: A retained invocation log proving that the
  installed client cannot represent the selected numeric domain is classified as FAIL. This is
  feature probing, not a package-version check, so it behaves the same on Yocto, Debian, Ubuntu,
  and CentOS and automatically starts passing when a capable package is provisioned.
- **Offline explicitly requested domain**: Fails with the healthcheck or remoteproc state.
- **Missing runtime artifacts**: When the capability source is `fastrpc-healthcheck`, a domain
  missing its endpoint or required runtime library fails the suite — healthcheck has declared it
  supported, so the absence indicates a broken installation. When the capability source is the
  runtime fallback, such a domain fails if declared by enabled FastRPC DT, otherwise it is
  logged and excluded while other runnable domains continue. Missing shared test libraries
  or DSP skeletons skip execution but do not clear prior readiness failures.
- **Binary resolved to /bin/fastrpc_test**: Blocked by default. Set `ALLOW_BIN_FASTRPC=1` or
  use `--bin-dir` to a non-`/bin` path.
- **Missing binary**: Expected kernel registration is checked first and any failure
  is reported before optional-payload handling. Otherwise the existing package
  policy described under Prerequisites applies, with SKIP on image-managed paths.
- **Session create errors with -U 1**: If unsigned PD returns `0x80000416`, confirm your image
  includes unsigned shells/policies (or use `--pd-mode signed-only`).
- **Domain not discovered**: Check `dmesg` for remoteproc firmware load errors. The test
  requires the DSP remoteproc to be registered and its firmware present in DT.
- **Per-iteration logs**: `logs_fastrpc_test_<timestamp>/<domain>_<pd>_iter<N>.out` (+ `.rc`, `.env`, `.cmd`)
- **Kernel evidence on failure**: one shared `logs_fastrpc_test_<timestamp>/kernel/` snapshot is
  captured through `scan_dmesg_errors` after the invocation matrix.
- **Optional QRTR evidence**: `logs_fastrpc_test_<timestamp>/qrtr_topology.log` when QRTR and
  `qrtr-lookup` are available.
- **Summary result file**: `fastrpc_test.res` (`PASS` / `FAIL` / `SKIP`)
- **Verbose mode**: adds environment, library resolution, and timing details

## Notes

- Domain and PD support are derived from `fastrpc-healthcheck` when available. The fallback is
  selected only when the tool is absent and uses runtime remoteproc and endpoint evidence, with
  a conservative protocol mapping for PD support. Actual invocation output then provides the
  distro-independent functional proof that the installed client supports the selected domain.
- The existing `/usr/lib/dsp` compatibility links are prepared before healthcheck captures its
  capability report, so the report and the subsequent functional run observe the same layout.
- This suite runs the public `fastrpc_test` character-device path and therefore requires either
  `/dev/fastrpc-<domain>` or `/dev/fastrpc-<domain>-secure` for every selected domain.
- DSP skeleton directories are discovered dynamically by locating `.so` artifacts instead of
  assuming fixed ABI directory names such as `v68` or `v75`.
- Override library discovery with `FASTRPC_LIB_SYS_DIR`, `FASTRPC_LIB_TEST_DIR`, or
  `FASTRPC_SKEL_BASE`. CLI domain selection takes precedence over environment selection, which
  takes precedence over runtime discovery.
- If `fastrpc_test` is not in the default path, use `--bin-dir` to specify its location.

## Host regression checks

From the repository root:

```sh
dash scripts/tests/fastrpc-domain-validation.sh
# Focused current-DT/runtime absence policy checks:
dash scripts/tests/fastrpc-domain-validation.sh --absence-only
dash scripts/tests/fastrpc-startup-validation.sh dash
```

These host-only fixtures exercise DT expectations and the actual runner selection
and result-finalization blocks. Remoteproc, endpoint, library, and invocation
boundaries are mocked. Coverage includes missing/offline CDSP with healthy ADSP,
healthcheck omission and unsupported reports, missing endpoints/libraries,
disabled ancestors, explicit overrides, no-DT fallback, optional asset skips,
compatible fallback lists, symlink roots, and malformed labels. They do not
perform DUT operations or establish hardware/cross-distribution validation.
The absence-only subset checks ADSP continuing without CDSP, explicit absent-CDSP
failure, runtime CDSP without a DT declaration, and SKIP with no applicable domain.

The startup harness additionally executes an unchanged copy of the full runner
with a temporary bootstrap and mocked hardware/package boundaries. It checks
missing-binary precedence, CLI/environment selection, absent/offline remoteprocs,
missing endpoints, discovery errors, preservation of the installed-binary path,
and existing provider outcomes. No package installation or real RPC invocation
is performed by these host checks.

## License

SPDX-License-Identifier: BSD-3-Clause
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
