# SystemReady_ACS_Result_Validation

Validate and import the compliance verdicts of an existing Arm SystemReady ACS report.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/SystemReady_ACS_Result_Validation/run-*` and the result is `SystemReady_ACS_Result_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--results` | `unset` | Explicit ACS results directory containing acs_summary/acs_jsons |
| `--required-suites` | `unset` | Optional comma-separated suite names required by the validation job |
| `--summary-sha256` | `unset` | Optional expected merged_results.json digest from the producing job |

Run Arm's ACS live image separately and finish its official log parser before
providing `--results`. This suite imports the supplied report, it does not execute
UEFI/SCT/BSA/FWTS tests or establish certification for the current Testkit target.
It never mounts a partition or auto-selects potentially stale results.

Use `--required-suites` to match the producing job's intended coverage and
`--summary-sha256` to bind the import to that job's artifact. The retained source,
digest, band and date identify exactly which report was imported. Unknown,
missing or duplicate verdicts fail. Optional not-run results skip. Official
compliance with waivers is retained as PASS with a visible warning. Counts in
this suite are imported compliance verdicts, not newly executed functional TCs.


Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
