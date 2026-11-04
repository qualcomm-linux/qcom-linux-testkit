# FastRPC runtime readiness

Run `./run.sh` from this directory on Yocto, Debian, Ubuntu or CentOS. Uses
image-provided cat, grep, awk, tr, basename, readlink and mkdir. Checks accessible
FastRPC character endpoints and retained kernel errors. It reuses the shared
bounded QRTR topology helper, with qrtr-lookup or its existing optional Python
fallback. Missing endpoints or optional query providers SKIP, present unusable
endpoints, query failures and captured driver errors FAIL.

Evidence remains in CWD results/FastRPC_Runtime_Validation/run-*. This is
readiness, not a DSP transaction or AudioPD functional test. Existing remoteproc
and DSP_AudioPD suites retain their own contracts and missing adsprpcd SKIP.
No firmware loading, package installation or service startup is performed here.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
