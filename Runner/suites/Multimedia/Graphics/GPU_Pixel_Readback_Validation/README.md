# GPU_Pixel_Readback_Validation

Validate hardware GPU rendering through expected-pixel readback without a display.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/GPU_Pixel_Readback_Validation/run-*` and the result is `GPU_Pixel_Readback_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--binary` | `unset` | Image-provided egl-readback executable, otherwise PATH discovery |
| `--expected-node` | `unset` | Optional exact render-node expectation for the helper-selected device |
| `--timeout` | `120` | Maximum render-helper runtime in seconds |

Uses the public qcom-buildroot `egl-readback` helper, which renders through
GBM/EGL/GLES and checks triangle/background pixels plus the final frame. The
image must provide that helper and its graphics libraries. The suite never
installs packages, compiles code or starts a compositor.

The helper supports MSM DRM and chooses its own render node. `--expected-node`
checks the actual selected device, it does not redirect the helper. Coverage
applies only to that reported node. Current helper releases limit their node
search internally, a newer helper is needed for nodes outside its supported
range. Software renderers, incomplete output and GPU faults fail.


Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
