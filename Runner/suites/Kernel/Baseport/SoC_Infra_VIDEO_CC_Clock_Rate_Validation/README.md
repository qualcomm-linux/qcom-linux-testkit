Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# SoC_Infra_VIDEO_CC_Clock_Rate_Validation

Registration and readability smoke test for the video clock controller (video_cc)
clocks. It checks that the video_cc clocks exposed by the Linux clock framework in
debugfs (`/sys/kernel/debug/clk/video_cc*/clk_rate`) are registered and that every
`clk_rate` value is a valid integer.

## Coverage

This is registration and readability smoke coverage. It catches:

- a `clk_rate` file that cannot be read or does not hold a single integer;
- no `video_cc*` clock being registered although the device tree has a video clock
  controller and the debugfs clock interface is available.

It does not verify that a rate is correct, that a frequency transition succeeds,
that the expected set of clocks is registered, or the physical frequency or clock
enable state. A numeric but wrong rate still passes. Checking those needs a
separate test that exercises the hardware through supported runtime interfaces.

## Prerequisites

- Root access, because debugfs is readable by root only.
- debugfs mounted at `/sys/kernel/debug` (or `/debug`) with the clock tree under
  `<debugfs>/clk`, which needs `CONFIG_DEBUG_FS`. The test does not mount it.
  debugfs is optional on production images, so the test skips when it is not
  available. A video clock controller node in the device tree does not change that.
- The video clock controller driver loaded on platforms that have one.
- Base utilities: `find`, `grep`, `cat`, `tr`, `readlink`, `dirname`, `basename`, `mktemp`.
  The test never installs packages. It skips when a utility is missing.

The test only reads files. It changes no module, service, mount or setting, so
there is nothing to clean up on the device.

## Applicability

The runtime device tree decides whether the platform has a video clock controller:
an enabled node whose compatible string is `qcom,<soc>-videocc`, for example
`qcom,sm8550-videocc`.

## Scope

Only clocks whose debugfs name starts with `video_cc` are checked.

## Usage

The suite has no command-line options and no environment overrides.

```sh
cd Runner
./run-test.sh SoC_Infra_VIDEO_CC_Clock_Rate_Validation
```

It can also be run directly:

```sh
cd Runner/suites/Kernel/Baseport/SoC_Infra_VIDEO_CC_Clock_Rate_Validation
./run.sh
```

## Results and logs

All files are written to the directory the test is started from. That is the suite
directory when the test runs through `run-test.sh`, the LAVA definition, or
`./run.sh` inside the suite directory:

| File | Content |
|---|---|
| `SoC_Infra_VIDEO_CC_Clock_Rate_Validation.res` | Final verdict: `PASS`, `FAIL` or `SKIP` |
| `video_cc_clk_rates.log` | One `<clock> <rate>` line per clock, with the rate in Hz; a bad value shows as `NOT_INTEGER(<value>)` and an unreadable file as `READ_ERROR` |
| `SoC_Infra_VIDEO_CC_Clock_Rate_Validation_stdout_<time>.log` | Captured console output of the run |

The lines of `video_cc_clk_rates.log` are also replayed in the console output with
the `[VIDEO-CC-CLK-RATE-HZ]` label, so a LAVA job log shows every clock and its rate
in Hz.

These files are runtime output and must not be committed.

## PASS, FAIL and SKIP

| Verdict | Condition |
|---|---|
| PASS | At least one `video_cc*` clock exists and each `clk_rate` file holds exactly one non-negative integer. A rate of `0` passes: this check covers readability and format only and does not establish the physical frequency or clock enable state. |
| FAIL | A `video_cc*` clock rate is not a single integer (for example `12 34`, which is not merged into `1234`) or cannot be read. |
| FAIL | debugfs and `<debugfs>/clk` are available and the device tree has a video clock controller, but no `video_cc*` clock is registered. This points to a missing or failed video clock controller driver. |
| SKIP | debugfs is not mounted or not readable, whatever the device tree says. |
| SKIP | `<debugfs>/clk` is not available, whatever the device tree says. |
| SKIP | debugfs and `<debugfs>/clk` are available, no `video_cc*` clock is registered, and the device tree has no video clock controller. |
| SKIP | A required base utility is missing. |

Each `clk_rate` value is validated with `is_unsigned_number` exactly as read. Only
the trailing newline is dropped, so embedded whitespace makes the value invalid.

## LAVA publication

The LAVA definition publishes the result with
`send-to-lava.sh SoC_Infra_VIDEO_CC_Clock_Rate_Validation.res --strict --expected-testcase-id SoC_Infra_VIDEO_CC_Clock_Rate_Validation`.
If `run.sh` exits early and leaves no valid result, the publish step fails instead
of reporting nothing. The step is the last one in the definition, so its failure
status is kept.

## Shared helpers

The suite uses two helpers from `Runner/utils/functestlib.sh`, which the
`SoC_Infra_GPU_Clock_Rate_Validation` suite introduced:

- `socinfra_debugfs_root` prints the mounted debugfs root.
- `socinfra_check_clk_rates` reads `clk_rate` for a clock name prefix and checks
  the value with `is_unsigned_number`.
