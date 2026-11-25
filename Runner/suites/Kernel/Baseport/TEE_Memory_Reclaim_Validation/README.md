# TEE_Memory_Reclaim_Validation

Validate repeated TEE user-memory registration, release and re-registration.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/TEE_Memory_Reclaim_Validation/run-*` and the result is `TEE_Memory_Reclaim_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--binary` | `unset` | Installed tee-shm-reclaim executable, otherwise PATH discovery |
| `--rounds` | `20` | Registration rounds per buffer, at least 2 |
| `--pages` | `1 64 1024` | Unique positive decimal buffer sizes in pages |
| `--min-ranges` | `0` | Optional minimum physical ranges for the final size |
| `--transport` | `any` | any or ffa, verified against the tested TEE device |
| `--timeout` | `120` | Maximum helper runtime in seconds |

Requires an image-provided `tee-shm-reclaim` compatible with the public
OpenBootStack helper. That helper operates on `/dev/tee0`, this suite does not
claim coverage of other TEE devices or MinkIPC memory objects. The helper is
never built or downloaded at runtime.

The default validates re-registration without assuming fragmented physical
allocation. Select `--transport ffa --min-ranges 300` with a sufficiently large
final buffer and pagemap privileges to require fragmented-descriptor coverage.
FF-A applicability is checked against the tested device, not any unrelated bus
device. Size memory and timeout options for the target before increasing them.


Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
