# FastCV Simple Deinterleave Validation

This suite runs the image-provided `fastcv_simple_test64` utility as a bounded
FastCV functional regression. It validates the utility status and its exact
deinterleave data-integrity result instead of treating binary or library
presence as a functional pass.

## Coverage

The suite:

- discovers `fastcv_simple_test64` using CLI, environment, then `PATH`
  precedence;
- runs the utility with a configurable timeout;
- requires a zero process status;
- requires the exact `Results match, Deinterleave Test passed` marker;
- rejects the exact `Results mismatch, Deinterleave Test failed` marker;
- retains and replays bounded utility output; and
- captures one FastRPC-related kernel-log snapshot through
  `scan_dmesg_errors`.

The public meta-qcom 1.8.9 recipe packages this utility in `fastcv-apps` and
installs it as `/usr/bin/fastcv_simple_test64`. General-purpose distribution
package layouts can differ, so the suite verifies the installed executable
after runtime package preparation.

The inspected 1.8.9 utility selects FastCV CPU performance mode. This suite
therefore proves FastCV API execution and deinterleave data integrity, but it
does **not** prove CDSP offload. CDSP validation requires a separate utility
that explicitly selects `FASTCV_OP_EXT_CDSP`, performs an operation, and
provides observable offload evidence.

## Portability and prerequisites

The suite is intended for Yocto, Debian, Ubuntu, CentOS, and Red Hat targets.

On Yocto and other image-managed systems, the suite performs no package-manager
operations. The validation ramdisk or image must already contain the FastCV
libraries and `fastcv_simple_test64`.

On Debian and Ubuntu, the suite checks and installs these missing packages:

```text
qcom-fastcv-binaries libfastcvopt-dev
```

On CentOS Stream 10 and compatible Red Hat Enterprise Linux 10 aarch64 systems,
it first installs `epel-release`, then ensures that the Qualcomm CentOS 10
`aarch64` and `noarch` repositories are enabled:

```text
https://softwarecenter.qualcomm.com/nexus/rpm/centos/10/os/aarch64/
https://softwarecenter.qualcomm.com/nexus/rpm/centos/10/os/noarch/
```

When needed, their definitions are written to
`/etc/yum.repos.d/qualcomm-linux.repo`. The suite runs the documented metadata
cleanup and cache refresh before it checks and installs:

```text
qcom-fastcv-binaries libfastcvopt-devel
```

No installed package is upgraded. Package recovery needs root privileges,
network access, and working distro repositories only when a required package
or repository is missing. An incomplete pre-existing Qualcomm repository
configuration fails rather than being overwritten.
The RPM path also verifies that the `epel` repository is enabled after
installing `epel-release`. Automatic repository creation is rejected on other
CentOS or Red Hat major versions because the configured repository URLs are
specific to version 10.

After package preparation, the selected package split must provide
`fastcv_simple_test64` in `PATH`. The suite verifies this dynamically before
execution. To inspect it manually:

```sh
command -v fastcv_simple_test64
fastcv_simple_test64
```

If the optional FastCV utility is absent from automatic discovery, the test
skips cleanly. An explicitly requested missing binary fails because the
override declares that binary as required.

The `--binary` override must identify the packaged `fastcv_simple_test64`
deinterleave utility. It must not point to the separately sideloaded
`fastcv_test` module runner, which requires a test-data directory and exposes a
different CLI and result-marker contract. The suite detects that module CLI and
fails with an explicit wrong-binary diagnostic.

A present utility that cannot execute, times out, exits nonzero, reports a
mismatch, or omits its success marker fails the functional check.

## Usage

Run with automatic discovery:

```sh
./run.sh
```

On a supported general-purpose distribution, this command also performs the
automatic missing-package and repository preparation described above.
Use `sudo ./run.sh` when that preparation is needed and the current shell is
not already root.

Select a utility explicitly:

```sh
./run.sh --binary /usr/bin/fastcv_simple_test64
```

The following is intentionally invalid because `fastcv_test` is the separate
module runner and requires its matching test-data directory:

```sh
./run.sh --binary /var/fastcv/fastcv_test
```

Change the execution bound:

```sh
./run.sh --timeout 90
```

Environment equivalents are `FASTCV_BINARY` and `FASTCV_TIMEOUT`. CLI values
take precedence over environment values. An empty binary value keeps automatic
discovery enabled.

## Results

- **PASS**: the utility exits zero, reports at least one exact success marker,
  and reports no exact mismatch marker.
- **FAIL**: required host-distribution package recovery fails, an explicitly
  requested binary is absent, the discovered binary is not executable,
  execution fails or exceeds the timeout, a mismatch is reported, or the
  required success marker is absent.
- **SKIP**: automatic discovery finds no image-provided utility. Kernel-log
  health is also a separate SKIP when the target does not expose readable
  kernel logs.

Kernel errors matched for FastRPC support are reported as a separate failure
and do not change the scope into a CDSP-offload claim.

## Evidence

Each run stores artifacts below:

```text
results/FastCV_Simple_Deinterleave_Validation/run-<timestamp>-<pid>/
```

Artifacts include:

- `fastcv_binary.log`: selected path, source, architecture, and file metadata;
- `fastcv_simple_test.log`: complete utility stdout and stderr;
- `kernel/dmesg_snapshot.log`: captured kernel log when access is available;
- `kernel/dmesg_errors.log`: filtered FastRPC-related errors; and
- `kernel/dmesg_access.log`: kernel-log provider and access diagnostics.

Live stdout includes the selection source, bounded utility output, exit status,
marker counts, artifact paths, and final PASS, FAIL, or SKIP reasons.
