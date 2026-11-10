# DSP_AudioPD

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

The suite validates registered ADSP readiness, its character-device FastRPC
endpoint and an enabled allocator owned by that ADSP. It supports endpoint DT
ancestry and registered ADSP DT descendants with `memory-region` and `qcom,vmids`.
Legacy stacks exposing only a valid ADSP RPC remote heap retain that fallback.
An exposed malformed allocator fails, unrelated compute DSP allocators do not
establish ADSP readiness. Missing optional daemon/endpoint evidence skips.

It reuses an existing `adsprpcd`, or starts and stops only its exact owned child.
The daemon must remain alive. Process wait state is diagnostic readiness evidence,
not proof of an AudioPD transaction. Captured FastRPC/ADSP faults fail.
No packages are installed, no systemd session is required, and logs stay in CWD.

```sh
cd Runner/suites/Multimedia/DSP_AudioPD
./run.sh
cat DSP_AudioPD.res
```
