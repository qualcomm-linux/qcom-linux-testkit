# Manual PR validation on LAVA OSS

`LAVA PR validation` reuses published meta-qcom nightly images. It does not
compile images or run on pushes. Every selected target runs the applicable
meta-qcom pre-merge groups, then uncovered PR test definitions in the matching
group. Device exclusions and baseline parameters come from the pinned
`qualcomm-linux/lava-test-plans` revision in `.github/ci/lava-pr-validation.json`.
All baseline and added Testkit definitions use the PR repository and full SHA.

## Configure once

- Grant this repository access to the kernel self-hosted runner group used in
  the workflows, with HTTPS access to GitHub, the artifact service and LAVA OSS.
- Create the `lava-oss` environment, restrict it to `main`, and configure its
  maintainer approval policy.
- Set `LAVA_OSS_USER` and `LAVA_OSS_TOKEN` secrets for the OSS submitter.
- If the workflow token cannot download cross-repository artifacts, set
  `META_QCOM_READ_TOKEN` with Actions read access to `qualcomm-linux/meta-qcom`.
- Set `QLI_ARTIFACT_TOKEN` for artifact availability checks. Register the same
  artifact credential under the OSS submitter and set the environment variable
  `LAVA_ARTIFACT_TOKEN_NAME` to its registered name. The name, never the secret,
  appears in LAVA definitions. Foundries token registration does not cover OSS.
- Confirm the image-machine to OSS device-type mapping in the JSON config,
  deployment methods, device tags, camera setup and media overlay support on
  that lab. Preparation does not establish that a board has passed validation.

OSS invokes QDL through `to: flasher` and `flash.settings`, as kernel-config's
Yocto validation does. The small template adapter under `.github/ci/lava-oss` uses the
existing meta-qcom flasher template, preserving media and camera postprocessing.
It does not use Foundries' direct `to: qdl` action.
OSS also uses `from: git` with the full PR SHA, since its current schema does
not accept `from: url`. The dispatcher fetches the definitions, so the DUT
does not need git.

## Run

From Actions, choose **LAVA PR validation**, use `main`, enter the PR number
and keep `targets=meta-qcom` for the pre-merge target set except `qcm6490-idp`.
That target is excluded by `excluded_targets` in the trusted config. The workflow
reads `devices_premerge` from meta-qcom's current `master` workflow and records
that exact source revision. It does not include targets enabled only for boot tests.
An explicit comma-separated subset, such as `iq-9075-evk,rb1-core-kit`, remains
available for focused validation.
Leave revision empty to resolve the PR head. A full earlier commit must belong
to that PR. The default image is `qcom-distro`. An alternative published distro
directory must match an enabled pre-merge profile and have images for every selected
target in the same producer run. `qcom-distro_linux-qcom-6.18` selects the 6.18 list.
Choose `multimedia` or `proprietary` for the published image variant. The workflow
does not substitute a base image when the requested proprietary image is absent.
An empty nightly run selects the newest suitable run among the latest 30 successful
Nightly and 30 Extended Builds with matching build URL manifests. Use an explicit
run ID for older images. Missing published images stop preparation.

As of 13 November 2026, the default selects 12 qcom-next targets: `glymur-crd`, `iq-8275-evk`,
`iq-9075-evk`, `iq-x7181-evk`, `kaanapali-mtp`, `qcs615-ride`,
`rb3gen2-core-kit`, `qcs8300-ride-sx`, `qcs9100-ride-sx`, `rb1-core-kit`,
`shikra-evk`, and `sm8750-mtp`. The 6.18 profile selects nine, the same list except
Glymur, Kaanapali and SM8750.

RB1 remains enabled as `rb1-core-kit`, mapped to OSS device type `rb1`.
Missing mappings or templates for selected targets stop preparation before image
downloads or job submission. `target-matrix.json` records the upstream list,
configured exclusions and selected targets, even when this preflight fails.
OSS device access is checked using the configured submitter. Unavailable selected
targets report an error and are never silently dropped.

First leave **submit** disabled and inspect the `lava-request-*` artifact.
It contains the complete jobs and selection manifest. Enable **submit** for
hardware validation. All jobs are checked with the OSS schema before submission.
At most two jobs are queued or running at once. Identical requests reuse their
existing jobs, including failures. A changed commit, image or test selection
creates a different request. Cancellation requests cleanup of this run's
outstanding LAVA jobs. Server-side queue and job deadlines remain active if the
runner becomes unavailable. Use the manual recovery below if finalization cannot run.

Changed suite files, including parsers and data, select their actual YAML.
Shared references expand through consumers. Add dynamic dependency associations
to `associations` in the trusted config when needed. Unresolved shared scope
expands conservatively and ambiguous or absent YAML stops preparation.
The job budget grows with the selected targets and permits 32 additional jobs.
The baseline is never reduced to satisfy it. The two-active-job limit and bounded
request deadline remain in effect for full-fleet runs.

For an ambiguous definition, use **selections**, for example:

```json
{"Runner/suites/Kernel/Baseport/Remoteproc_Restart_Validation": {"path": "Runner/suites/Kernel/Baseport/Remoteproc_Restart_Validation/Remoteproc_Restart_Validation.yaml", "group": "pre-merge-basic", "minutes": 20}}
```

Selections accept `params`, `expected` result names and `fresh_boot: true`.
Crash/reboot profiles need an explicit selection and a fresh boot. Ordinary
additions follow the baseline in their environment. Missing setup must be
resolved before selecting a test, camera NHX is not equivalent to libcamera.

The reusable **LAVA PR results** workflow runs after validation, including failure
or cancellation, and posts one PR table for the tested SHA.
It distinguishes baseline, additions, failures, skips and missing results.
An all-SKIP or incomplete job is not successful validation. For manual recovery,
dispatch **LAVA PR results** on `main` with the original `validation_run` ID and
optional `validation_attempt`. Recovery verifies the source workflow, repository,
branch and attempt before reading its request. It requires the source run to
have completed and never submits or reflashes jobs. Its artifacts retain the
complete table and testcase evidence. A newer PR head does not inherit old results.
