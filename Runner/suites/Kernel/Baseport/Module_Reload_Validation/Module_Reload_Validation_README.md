# Module_Reload_Validation

## Overview

`Module_Reload_Validation` is a generic, profile-driven kernel module unload/reload regression suite for Qualcomm Linux test coverage.

It is intended to catch issues such as:

- module unload hangs,
- failed reloads,
- missing or incomplete reloads,
- service/device rebind regressions after reload,
- dependency modules left loaded after unload,
- active users keeping a module busy,
- failures that reproduce only on the 1st, 2nd, or later reload iteration.

The suite uses:

- a thin orchestration script in `run.sh`,
- shared generic helper logic in `Runner/utils/lib_module_reload.sh`,
- module-specific profile files under `profiles/`,
- profile list files to group base, overlay, or team-specific coverage.

The design is intentionally profile-driven so new modules can be added without duplicating module-specific logic in `run.sh`.

## Recent framework updates

The current framework has been enhanced to support the following behavior:

- `run.sh` supports both single-profile execution through `--module` and group execution through `--profile-list`.
- `run.sh` logs the selected profile list in the argument summary.
- `lib_module_reload.sh` contains the common reload engine and generic helper functions.
- Profiles are expected to stay minimal and declarative.
- Complex logic should be moved to reusable library helpers instead of being embedded in each profile.
- Profiles can declare service/process/device quiesce metadata separately from warmup/restore metadata.
- Profiles can use `PROFILE_QUIESCE_ONCE="yes"` to avoid repeatedly stopping the same disruptive services on every iteration.
- The framework can snapshot service state and restore previously active services from the test side after profile execution.
- Profiles can skip when conflicting modules are active, for example `ath11k_pci` can skip when `ath11k_ahb` is the active Wi-Fi transport.
- The Qualcomm SoundWire/ASoC profile is minimal and uses a library helper to discover the top-level holder of `snd_soc_qcom_sdw`.
- Modern Adreno GPU/display validation should treat `msm.ko` as the active upstream DRM driver on RB3Gen2/newer platforms. `msm_kgsl` is legacy KGSL and should not be used for modern RB3Gen2-style DRM stacks.

## Folder layout

```text
Runner/suites/Kernel/Baseport/Module_Reload_Validation/
├── run.sh
├── Module_Reload_Validation.yaml
├── Module_Reload_Validation_README.md
├── profiles/
│   ├── enabled.list
│   ├── base.list
│   ├── overlay.list
│   ├── fastrpc.profile
│   ├── dwmac_qcom_eth.profile
│   ├── tc956x_pcie_eth.profile
│   ├── ath11k_pci.profile
│   ├── ath11k_ahb.profile
│   ├── ath12k_pci.profile
│   ├── qcedev_mod_dlkm.profile
│   ├── qcrypto_msm_dlkm.profile
│   ├── qrng_dlkm.profile
│   ├── spcom.profile
│   ├── mvm.profile
│   ├── venus_core.profile
│   ├── qcom_iris.profile
│   ├── snd_soc_qcom_sdw.profile
│   ├── msm.profile
│   ├── msm_kgsl.profile
│   ├── camera.profile
│   ├── iris.profile
│   └── audioreach.profile

Runner/utils/
└── lib_module_reload.sh
```

`msm_kgsl.profile` is legacy KGSL coverage and is expected to skip on modern DRM-based images where `msm.ko` is used instead.

## Main components

### `run.sh`

`run.sh` is the orchestration layer. It should remain thin.

Responsibilities:

- load `init_env`, `functestlib.sh`, and `lib_module_reload.sh`,
- parse CLI arguments,
- resolve selected profile files,
- run each profile through the generic library engine,
- maintain pass/fail/skip counts,
- write `Module_Reload_Validation.res`,
- leave detailed artifacts under `results/Module_Reload_Validation/`.

`run.sh` should not contain module-specific reload logic. Module-specific behavior belongs in profile files or reusable helper functions in `lib_module_reload.sh`.

### `Runner/utils/lib_module_reload.sh`

`lib_module_reload.sh` contains the shared module reload engine.

Responsibilities:

- profile variable reset,
- profile validation,
- module presence and built-in checks,
- loaded-module checks,
- timeout-controlled command execution,
- unload/load validation,
- multi-module stack validation,
- profile hook dispatch,
- service/process quiesce,
- best-effort restore of previously active services,
- optional quiesce-once behavior,
- evidence collection,
- timeout/hang evidence collection,
- helper functions for profiles with dynamic topology.

Examples of reusable helpers:

- module availability checks,
- holder detection using `/sys/module/<module>/holders`,
- holder detection using `/proc/modules`,
- generic top-module selection,
- generic stack setup,
- Qualcomm SoundWire/ASoC stack setup.

### `profiles/*.profile`

Profiles define module-specific metadata and optional hook behavior.

Profiles should be as declarative as possible. A profile should define what needs to be reloaded and what must be quiesced. The library should define how that is done.

## Profile variables

### Required or commonly used fields

```sh
PROFILE_NAME="example_module"
PROFILE_DESCRIPTION="Example module reload validation"
MODULE_NAME="example_module"
MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="basic"
PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed grep"
MODULE_UNLOAD_CMD="modprobe -r example_module"
MODULE_LOAD_CMD="modprobe example_module"
PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="example_module"
PROFILE_EXPECT_PRESENT_AFTER_LOAD="example_module"
PROFILE_SYSFS_PATTERNS="/sys/module/example_module"
```

### Service and process fields

```sh
PROFILE_SERVICES="example.service"
PROFILE_PROC_PATTERNS="example-daemon example-client"
PROFILE_DEVICE_PATTERNS="/dev/example*"
PROFILE_SYSFS_PATTERNS="/sys/module/example_module /sys/class/example/*"
```

These fields are used for service status logging, evidence collection, and profile lifecycle handling.

### Quiesce-specific fields

Use quiesce-specific fields when the services/processes that need to be stopped before unload are different from the services/processes that should be observed or restored.

```sh
PROFILE_QUIESCE_SERVICES="example.service"
PROFILE_QUIESCE_PROC_PATTERNS="example-daemon example-client"
PROFILE_QUIESCE_DEVICE_PATTERNS="/dev/example*"
```

If these are not set, the framework falls back to `PROFILE_SERVICES`, `PROFILE_PROC_PATTERNS`, and `PROFILE_DEVICE_PATTERNS`.

### Quiesce-once behavior

Some profiles are expensive or risky to quiesce repeatedly. For those profiles, use:

```sh
PROFILE_QUIESCE_ONCE="yes"
```

This is useful for profiles such as:

- `fastrpc`,
- `snd_soc_qcom_sdw`,
- `ath11k_ahb`,
- `msm`.

With `PROFILE_QUIESCE_ONCE="yes"`, the first iteration performs the full quiesce path. Later iterations skip repeated service/process stop work and continue with unload/reload validation.

### Conflict skip fields

Use this when two profiles represent alternate transports or mutually exclusive module stacks.

Example:

```sh
PROFILE_SKIP_IF_MODULES_LOADED="ath11k_ahb"
```

This lets `ath11k_pci.profile` skip cleanly on platforms where `ath11k_ahb` is the active Wi-Fi transport.

### Dynamic stack fields

These fields are useful when the module to reload is a top-level holder rather than the originally named module.

```sh
PROFILE_TOP_MODULE_CANDIDATES="snd_soc_sc8280xp snd_soc_sm8450"
PROFILE_UNLOAD_STACK="snd_soc_sc8280xp snd_soc_qcom_sdw"
PROFILE_EXTRA_UNLOAD_MODULES=""
```

For common patterns, prefer a library helper instead of open-coding stack discovery in the profile.

## Profile hooks

Profiles may define optional hooks:

```sh
profile_prepare() { ...; }
profile_warmup() { ...; }
profile_quiesce() { ...; }
profile_post_unload() { ...; }
profile_post_load() { ...; }
profile_smoke() { ...; }
profile_finalize() { ...; }
```

Use hooks only when declarative profile variables are not enough.

Recommended approach:

1. First try generic fields such as `PROFILE_SERVICES`, `PROFILE_PROC_PATTERNS`, `MODULE_UNLOAD_CMD`, and `MODULE_LOAD_CMD`.
2. If multiple profiles need the same behavior, create a reusable helper in `lib_module_reload.sh`.
3. Keep module-specific profiles small.
4. Avoid copying large shell functions into profile files.

## Profile lists

Profile lists let teams or CI jobs run the desired module set without creating a separate YAML for every module.

### `profiles/enabled.list`

Default list used when `./run.sh` is called without `--module` or `--profile-list`.

Keep this conservative for common CI.

Recommended default:

```text
fastrpc
```

### `profiles/base.list`

Base-image or upstream-aligned module coverage.

Example broad base list:

```text
fastrpc
dwmac_qcom_eth
tc956x_pcie_eth
ath11k_pci
ath11k_ahb
ath12k_pci
qcedev_mod_dlkm
qcrypto_msm_dlkm
qrng_dlkm
spcom
mvm
venus_core
qcom_iris
snd_soc_qcom_sdw
```

For RB3Gen2-style targets, a conservative bring-up list can be smaller:

```text
tc956x_pcie_eth
ath11k_ahb
venus_core
qcom_iris
snd_soc_qcom_sdw
```

`fastrpc` is useful but can be disruptive if the unload path hangs. It may be better to run it explicitly during bring-up.

### `profiles/overlay.list`

Overlay/downstream package coverage.

Current recommended overlay list:

```text
msm
camera
iris
audioreach
```

Notes:

- `msm` represents the modern MSM DRM driver used by RB3Gen2/newer platforms.
- `msm_kgsl` is legacy KGSL and should not be the default for modern DRM-based platforms.
- `camera` and `iris` may mark themselves non-reloadable until a safe reload sequence is validated.
- `audioreach` should skip if downstream AudioReach modules are not present on the image.

## Base module coverage

### `fastrpc.profile`

FastRPC reload validation.

Common services/processes:

```text
adsprpcd.service
cdsprpcd.service
adsprpcd
cdsprpcd
```

Guidance:

- Stop and mask FastRPC users before unload.
- Kill remaining FastRPC cgroup/process users when required.
- Check open file descriptors for FastRPC device nodes before unload.
- Use timeout evidence if unload hangs.
- Run `fastrpc` as a focused test when debugging DSP unload behavior.
- If unload hangs and the kernel task is stuck, the device may need recovery before broad profile testing can continue.

### `dwmac_qcom_eth.profile`

Qualcomm DWMAC/STMMAC Ethernet reload validation.

Typical stack:

```text
dwmac_qcom_eth
stmmac_platform
stmmac
```

Use this only on platforms where `dwmac_qcom_eth` exists.

### `tc956x_pcie_eth.profile`

TC956x PCIe Ethernet reload validation.

Typical module:

```text
tc956x_pcie_eth
```

This is useful on RB3Gen2-style platforms where Ethernet is provided by the TC956x PCIe Ethernet driver instead of `dwmac_qcom_eth`.

The existing `basic` mode continues to unload/reload the module. For QPS615
standalone load/readiness validation on either a base or overlay image, use:

```sh
./run.sh --module tc956x_pcie_eth --mode load_only
```

The profile name selects the workflow, not the module to insert. `load_only`
discovers QPS615 endpoints from runtime DT/PCI topology, resolves the module
through their `driver/module` links or running-kernel modalias database, and
captures `modinfo`. It does not change EFI selection, install packages, force
PCI binding, configure an IP address, or transmit traffic. Ethernet ports must
already be configured in runtime DT or bound by the running image.

An initially loaded or built-in module is left untouched. Otherwise this mode
requires root, image-provided `modprobe` and `rmmod`, loads the discovered module,
and waits for correlated driver/netdev readiness. It then removes only the
target it loaded with non-forced `rmmod`. Dependency modules are preserved.
Use a maintenance window because removal takes newly created netdevs away.

Missing QPS615 hardware or unconfigured Ethernet ports produce `SKIP`. Declared
but missing topology, ambiguous module metadata, failed load/binding, captured
kernel errors, and restoration failures produce `FAIL`. A loaded module alone
is never sufficient to pass. Carrier and traffic belong to the Ethernet suites.

This mode performs one load/readiness check regardless of `--iterations`.
`--timeout-load` bounds module commands and `--timeout-settle` bounds readiness
polling. Evidence is retained in `results/Module_Reload_Validation/tc956x_pcie_eth/load_only/run-*/`,
including before/after runtime inventories and module command logs. Kernel
snapshot/error logs are captured after successful binding. The existing YAML
`PROFILE=tc956x_pcie_eth` and `MODE=load_only` parameters select the same path.
Default mode and other profiles are unchanged.

### `ath11k_pci.profile`

ath11k PCI Wi-Fi reload validation.

Typical stack:

```text
ath11k_pci
ath11k
mac80211
cfg80211
```

Use `PROFILE_SKIP_IF_MODULES_LOADED="ath11k_ahb"` so this profile skips on platforms where AHB transport is active.

### `ath11k_ahb.profile`

ath11k AHB Wi-Fi reload validation.

Typical stack:

```text
ath11k_ahb
ath11k
mac80211
cfg80211
```

Common services to quiesce:

```text
wpa_supplicant.service
NetworkManager.service
systemd-networkd.service
```

Use `PROFILE_QUIESCE_ONCE="yes"` if repeated service stop/start is causing long execution time or unstable network state.

### `ath12k_pci.profile`

ath12k PCI Wi-Fi reload validation.

Typical stack:

```text
ath12k_pci
ath12k
mac80211
cfg80211
```

Keep this profile even if it skips on RB3Gen2. Other targets may use ath12k.

### `qcedev_mod_dlkm.profile`

QCEDEV crypto DLKM reload validation.

Typical modules:

```text
qcedev_mod_dlkm
qce50_dlkm
```

### `qcrypto_msm_dlkm.profile`

QCrypto MSM DLKM reload validation.

Some builds may have dependency/cyclic unload issues. Capture unload logs and holder state before deciding whether the profile should stay enabled for a specific platform.

### `qrng_dlkm.profile`

QRNG DLKM reload validation.

Some builds may have service naming or service lifecycle issues. Missing service units should not fail the profile by themselves.

### `spcom.profile`

Secure Processor communication reload validation.

Common services to quiesce where present:

```text
spdaemon.service
qseecomd.service
keymaster-4-0.service
```

Missing services are non-fatal.

### `mvm.profile`

MVM DLKM reload validation.

Expected service where present:

```text
mvm.service
```

### `venus_core.profile`

Upstream Venus video reload validation.

Typical stack:

```text
venus_enc
venus_dec
venus_core
```

### `qcom_iris.profile`

Upstream Qualcomm Iris video reload validation.

Typical module:

```text
qcom_iris
```

Use this on platforms where the active Iris module is `qcom_iris`.

### `snd_soc_qcom_sdw.profile`

Qualcomm ASoC/SoundWire reload validation.

This profile should stay minimal. The topology and unload stack are handled by the library helper:

```sh
module_reload_qcom_sdw_profile_setup
```

The helper detects the top-level holder of `snd_soc_qcom_sdw`, for example:

```text
snd_soc_sc8280xp -> snd_soc_qcom_sdw
```

Then it unloads the top-level machine/card driver before `snd_soc_qcom_sdw`, and reloads the top-level module.

Recommended profile behavior:

```sh
PROFILE_NAME="snd_soc_qcom_sdw"
PROFILE_DESCRIPTION="Qualcomm ASoC/SoundWire reload validation"
PROFILE_QUIESCE_ONCE="yes"

module_reload_qcom_sdw_profile_setup
```

Use `QCOM_SDW_TOP_MODULE_CANDIDATES` to extend platform support without changing the profile:

```sh
QCOM_SDW_TOP_MODULE_CANDIDATES="snd_soc_sc8280xp snd_soc_sm8450 snd_soc_sc7280" \
  ./run.sh --module snd_soc_qcom_sdw
```

## Overlay module coverage

### `msm.profile`

Modern MSM DRM GPU/display reload validation.

Typical module:

```text
msm
```

Important distinction:

- `msm.ko` is the modern DRM driver used by RB3Gen2/newer platforms.
- `msm_kgsl.ko` is legacy KGSL and is not expected on modern DRM-based images.

`msm` is highly disruptive because it can be held by DRM/KMS clients, display, GPU, Weston, or console users.

Common consumers to quiesce:

```text
weston.service
display-manager.service
gpu-service.service
```

Common device paths:

```text
/dev/dri/card*
/dev/dri/renderD*
```

Guidance:

- Do not enable `msm` in broad CI until the platform-specific quiesce path is validated.
- If `modprobe -r msm` fails with `rc=1` and the unload log has no extra detail, inspect `holders.log`, `lsmod.log`, `ps.log`, `/dev/dri/*` users, and DRM clients.
- If the display stack is active, `msm` may be a valid skip/non-reloadable profile for that environment.
- Keep `msm` separate from `msm_kgsl` to avoid confusing modern DRM and legacy KGSL validation.

### `msm_kgsl.profile`

Legacy KGSL reload validation.

Typical module:

```text
msm_kgsl
```

This is only for old KGSL-based systems. It should skip on RB3Gen2/newer DRM systems.

### `camera.profile`

CAMX/downstream camera KMD reload validation.

Common module candidates:

```text
camera
camera_kmd
camx_kmd
```

Upstream camera on RB3Gen2-style images may use:

```text
qcom_camss
imx412
camcc_sc7280
```

Do not treat upstream `qcom_camss` as the same thing as CAMX overlay. If the CAMX module is not present, the CAMX overlay profile should skip.

### `iris.profile`

Downstream Iris video overlay reload validation.

Common module candidates:

```text
iris
iris_vpu
```

Upstream Iris uses `qcom_iris`. Keep downstream `iris` / `iris_vpu` separate from upstream `qcom_iris`.

### `audioreach.profile`

Downstream AudioReach reload validation.

Typical modules:

```text
snd_soc_qdsp6
q6asm
q6adm
q6afe
apr
```

The profile should skip if downstream AudioReach modules are not present.

## Execution flow

For each selected profile:

1. Reset profile variables.
2. Source the profile file.
3. Run any profile setup helper.
4. Validate the profile.
5. Skip if the module is not present, built-in, marked non-reloadable, or conflicts with an active mutually exclusive module.
6. Ensure the module is loaded before iteration work starts.
7. Run warmup logic when configured.
8. Capture pre-state evidence.
9. Log service/process state for the profile.
10. Quiesce configured services/processes before unload.
11. Optionally skip repeated quiesce if `PROFILE_QUIESCE_ONCE="yes"` was already completed.
12. Execute the unload command with timeout.
13. Validate that `MODULE_NAME` and `PROFILE_EXPECT_ABSENT_AFTER_UNLOAD` are absent.
14. Run post-unload hook.
15. Execute the load command with timeout.
16. Validate that `MODULE_NAME` and `PROFILE_EXPECT_PRESENT_AFTER_LOAD` are present.
17. Run post-load hook.
18. Run smoke hook.
19. Capture post-load evidence.
20. Repeat for all iterations.
21. Run finalize hook and restore previously active services where applicable.

## Result policy

### PASS

A profile passes when all requested iterations complete successfully.

### FAIL

A profile fails on:

- unload timeout,
- load timeout,
- unload command failure,
- load command failure,
- module state validation failure,
- profile hook failure,
- smoke validation failure.

### SKIP

A profile skips when:

- module is not present on the image,
- module is built into the kernel,
- required command is missing,
- profile marks the module as non-reloadable,
- profile declares a conflicting active module through `PROFILE_SKIP_IF_MODULES_LOADED`.

## Evidence collected

Per profile and iteration, the suite can capture:

- command logs,
- `lsmod`,
- `modinfo`,
- `ps`,
- `dmesg`,
- service status,
- recent service journal,
- profiled device path presence,
- profiled sysfs path presence,
- `/sys/module/<module>/holders`,
- timeout PID `/proc` snapshots,
- optional sysrq task/block dumps.

Results are stored under:

```text
Runner/suites/Kernel/Baseport/Module_Reload_Validation/results/Module_Reload_Validation/<profile>/iter_XX/
```

Useful files:

```text
unload.log
load.log
pre_state/lsmod.log
pre_state/holders.log
unload_failure_state/lsmod.log
unload_failure_state/holders.log
hang_evidence/dmesg_after_sysrq.log
```

## Hang handling policy

Sysrq dump is not triggered on normal passing iterations.

It is triggered only when unload/load times out and sysrq dump policy is enabled.

Default behavior:

- normal pass: no sysrq dump,
- quick non-timeout failure: normal failure evidence only,
- timeout/hang: hang evidence bundle plus optional sysrq task/block dumps.

Disable sysrq dumps when needed:

```sh
./run.sh --module fastrpc --disable-sysrq-hang-dump
```

## CLI usage

### Standard repo-style launch

Most LAVA tests in this repo launch from `Runner`.

```sh
cd Runner
$PWD/suites/Kernel/Baseport/Module_Reload_Validation/run.sh
$PWD/utils/send-to-lava.sh $PWD/suites/Kernel/Baseport/Module_Reload_Validation/Module_Reload_Validation.res
$PWD/utils/result_parse.sh
```

### Direct local launch from the test directory

```sh
cd Runner/suites/Kernel/Baseport/Module_Reload_Validation
./run.sh
```

### Run one profile

```sh
./run.sh --module fastrpc
./run.sh --module ath11k_ahb
./run.sh --module snd_soc_qcom_sdw
./run.sh --module msm
```

### Run a profile list

```sh
./run.sh --profile-list profiles/base.list
./run.sh --profile-list profiles/overlay.list
```

### Run with more iterations

```sh
./run.sh --module ath11k_ahb --iterations 5
```

### Override mode

```sh
./run.sh --module fastrpc --mode basic
./run.sh --module fastrpc --mode daemon_lifecycle
```

If `--mode` is not provided, the profile default is used.

### Override timeouts

```sh
./run.sh --module fastrpc \
  --timeout-unload 60 \
  --timeout-load 60 \
  --timeout-settle 30
```

### Enable verbose shell logging

```sh
./run.sh --module snd_soc_qcom_sdw --verbose
```

### Disable sysrq timeout dumps

```sh
./run.sh --module fastrpc --disable-sysrq-hang-dump
```

### Run SoundWire/audio with candidate override

```sh
QCOM_SDW_TOP_MODULE_CANDIDATES="snd_soc_sc8280xp snd_soc_sm8450 snd_soc_sc7280" \
  ./run.sh --module snd_soc_qcom_sdw --iterations 1 --timeout-unload 60 --timeout-load 60
```

## Team-specific launch examples

Teams do not need separate YAML files for every profile. They can call the same module reload suite with `--module <profile>`.

### FastRPC team example

```sh
cd Runner
$PWD/suites/Multimedia/CDSP/fastrpc_test/run.sh || true
$PWD/utils/send-to-lava.sh $PWD/suites/Multimedia/CDSP/fastrpc_test/fastrpc_test.res || true
$PWD/suites/Kernel/Baseport/Module_Reload_Validation/run.sh --module fastrpc || true
$PWD/utils/send-to-lava.sh $PWD/suites/Kernel/Baseport/Module_Reload_Validation/Module_Reload_Validation.res || true
$PWD/utils/result_parse.sh
```

### Wi-Fi team examples

```sh
cd Runner
$PWD/suites/Kernel/Baseport/Module_Reload_Validation/run.sh --module ath11k_ahb || true
$PWD/utils/send-to-lava.sh $PWD/suites/Kernel/Baseport/Module_Reload_Validation/Module_Reload_Validation.res || true
$PWD/utils/result_parse.sh
```

```sh
cd Runner
$PWD/suites/Kernel/Baseport/Module_Reload_Validation/run.sh --module ath12k_pci || true
$PWD/utils/send-to-lava.sh $PWD/suites/Kernel/Baseport/Module_Reload_Validation/Module_Reload_Validation.res || true
$PWD/utils/result_parse.sh
```

### Audio team example

```sh
cd Runner
$PWD/suites/Kernel/Baseport/Module_Reload_Validation/run.sh --module snd_soc_qcom_sdw --iterations 1 --timeout-unload 60 --timeout-load 60 || true
$PWD/utils/send-to-lava.sh $PWD/suites/Kernel/Baseport/Module_Reload_Validation/Module_Reload_Validation.res || true
$PWD/utils/result_parse.sh
```

### Overlay bring-up example

```sh
cd Runner
$PWD/suites/Kernel/Baseport/Module_Reload_Validation/run.sh --profile-list suites/Kernel/Baseport/Module_Reload_Validation/profiles/overlay.list || true
$PWD/utils/send-to-lava.sh $PWD/suites/Kernel/Baseport/Module_Reload_Validation/Module_Reload_Validation.res || true
$PWD/utils/result_parse.sh
```

## YAML usage in LAVA

`Module_Reload_Validation.yaml` should remain generic. Do not duplicate module-specific reload logic in YAML.

Recommended params:

```yaml
params:
  PROFILE: ""
  PROFILE_LIST: ""
  ITERATIONS: "3"
  MODE: ""
  TIMEOUT_UNLOAD: "30"
  TIMEOUT_LOAD: "30"
  TIMEOUT_SETTLE: "20"
  ENABLE_SYSRQ_HANG_DUMP: "1"
```

Recommended repo-aligned run steps:

```yaml
run:
  steps:
    - cd Runner
    - MRV_ARGS=""
    - if [ -n "${PROFILE}" ]; then MRV_ARGS="${MRV_ARGS} --module ${PROFILE}"; fi
    - if [ -n "${PROFILE_LIST}" ]; then MRV_ARGS="${MRV_ARGS} --profile-list ${PROFILE_LIST}"; fi
    - if [ -n "${ITERATIONS}" ]; then MRV_ARGS="${MRV_ARGS} --iterations ${ITERATIONS}"; fi
    - if [ -n "${MODE}" ]; then MRV_ARGS="${MRV_ARGS} --mode ${MODE}"; fi
    - if [ -n "${TIMEOUT_UNLOAD}" ]; then MRV_ARGS="${MRV_ARGS} --timeout-unload ${TIMEOUT_UNLOAD}"; fi
    - if [ -n "${TIMEOUT_LOAD}" ]; then MRV_ARGS="${MRV_ARGS} --timeout-load ${TIMEOUT_LOAD}"; fi
    - if [ -n "${TIMEOUT_SETTLE}" ]; then MRV_ARGS="${MRV_ARGS} --timeout-settle ${TIMEOUT_SETTLE}"; fi
    - if [ "${ENABLE_SYSRQ_HANG_DUMP}" = "0" ]; then MRV_ARGS="${MRV_ARGS} --disable-sysrq-hang-dump"; fi
    - $PWD/suites/Kernel/Baseport/Module_Reload_Validation/run.sh ${MRV_ARGS} || true
    - $PWD/utils/send-to-lava.sh $PWD/suites/Kernel/Baseport/Module_Reload_Validation/Module_Reload_Validation.res || true
    - $PWD/utils/result_parse.sh
```

Behavior:

- `PROFILE="fastrpc"` runs only `fastrpc.profile`.
- `PROFILE="snd_soc_qcom_sdw"` runs only the audio/SoundWire profile.
- `PROFILE_LIST="suites/Kernel/Baseport/Module_Reload_Validation/profiles/base.list"` runs the base list.
- `PROFILE_LIST="suites/Kernel/Baseport/Module_Reload_Validation/profiles/overlay.list"` runs the overlay list.
- If both `PROFILE` and `PROFILE_LIST` are empty, `run.sh` uses `profiles/enabled.list`.
- If both `PROFILE` and `PROFILE_LIST` are set, prefer single-profile behavior through `PROFILE` and avoid setting both in LAVA unless the test definition intentionally supports that combination.

### Example: generic YAML invocation for FastRPC only

```yaml
params:
  PROFILE: "fastrpc"
  PROFILE_LIST: ""
  ITERATIONS: "3"
```

### Example: generic YAML invocation for base list

```yaml
params:
  PROFILE: ""
  PROFILE_LIST: "suites/Kernel/Baseport/Module_Reload_Validation/profiles/base.list"
  ITERATIONS: "3"
```

### Example: generic YAML invocation for overlay list

```yaml
params:
  PROFILE: ""
  PROFILE_LIST: "suites/Kernel/Baseport/Module_Reload_Validation/profiles/overlay.list"
  ITERATIONS: "3"
```

### Do we need one YAML per profile?

No. The preferred approach is one generic YAML plus params.

Use separate YAML files only when a team wants to combine module reload validation with another functional test flow, for example FastRPC functional validation followed by `--module fastrpc` reload validation.

## How to add a new profile

1. Create a profile file:

   ```text
   profiles/example_module.profile
   ```

2. Start with minimal metadata:

   ```sh
   PROFILE_NAME="example_module"
   PROFILE_DESCRIPTION="Example module reload validation"
   MODULE_NAME="example_module"
   MODULE_RELOAD_SUPPORTED="yes"
   PROFILE_MODE_DEFAULT="basic"
   PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed grep"
   MODULE_UNLOAD_CMD="modprobe -r example_module"
   MODULE_LOAD_CMD="modprobe example_module"
   PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="example_module"
   PROFILE_EXPECT_PRESENT_AFTER_LOAD="example_module"
   PROFILE_SYSFS_PATTERNS="/sys/module/example_module"
   ```

3. Add quiesce data only if the module has active users:

   ```sh
   PROFILE_QUIESCE_SERVICES="example.service"
   PROFILE_QUIESCE_PROC_PATTERNS="example-daemon example-client"
   PROFILE_DEVICE_PATTERNS="/dev/example*"
   ```

4. Use `PROFILE_QUIESCE_ONCE="yes"` if repeated service quiesce should happen only once per profile run.

5. Add conflict rules if this profile is mutually exclusive with another profile:

   ```sh
   PROFILE_SKIP_IF_MODULES_LOADED="other_transport_module"
   ```

6. If the module has holders, unload the top-level holder first:

   ```sh
   PROFILE_TOP_MODULE_CANDIDATES="example_card example_machine"
   module_reload_profile_setup_stack
   ```

   Or create a purpose-built helper in `lib_module_reload.sh` if the logic is reusable.

7. Add optional hooks only when required.

8. Add the profile basename to the appropriate list:

   - `enabled.list` for default CI,
   - `base.list` for base-image modules,
   - `overlay.list` for overlay/downstream modules,
   - team-specific lists if needed.

9. Run locally:

   ```sh
   ./run.sh --module example_module --iterations 1
   ```

10. Run shellcheck:

    ```sh
    shellcheck -s sh Runner/suites/Kernel/Baseport/Module_Reload_Validation/run.sh
    shellcheck -s sh Runner/utils/lib_module_reload.sh
    shellcheck -s sh Runner/suites/Kernel/Baseport/Module_Reload_Validation/profiles/example_module.profile
    ```

## Customizing profile lists

### Create a team-specific list

Example:

```text
profiles/wifi.list
```

```text
ath11k_pci
ath11k_ahb
ath12k_pci
```

Run it:

```sh
./run.sh --profile-list profiles/wifi.list
```

### Create a platform-specific list

Example:

```text
profiles/rb3gen2.list
```

```text
tc956x_pcie_eth
ath11k_ahb
venus_core
qcom_iris
snd_soc_qcom_sdw
```

Run it:

```sh
./run.sh --profile-list profiles/rb3gen2.list
```

### Keep disruptive profiles out of default CI

Do not put every profile into `enabled.list`.

Profiles that can disrupt board access or display state should be run explicitly or through prepared profile lists:

- `fastrpc`,
- `ath11k_ahb`,
- `ath11k_pci`,
- `snd_soc_qcom_sdw`,
- `msm`,
- `camera`,
- `iris`,
- `audioreach`.

## Troubleshooting

### Profile skips with “module not present on image”

Check:

```sh
lsmod | grep <module>
modinfo <module>
find /lib/modules/$(uname -r) /usr/lib/modules/$(uname -r) -name '<module>.ko*'
```

This is expected when a profile is valid for another target but not present on the current image.

### Profile skips with “conflicting active module is loaded”

This means the profile is for an alternate transport/stack.

Example:

```text
ath11k_pci SKIP - conflicting active module is loaded: ath11k_ahb
```

Run the active transport profile instead:

```sh
./run.sh --module ath11k_ahb
```

### `modprobe -r <module>` fails with `rc=1`

Inspect:

```sh
cat results/Module_Reload_Validation/<profile>/iter_01/unload.log
cat results/Module_Reload_Validation/<profile>/iter_01/unload_failure_state/holders.log
cat results/Module_Reload_Validation/<profile>/iter_01/unload_failure_state/lsmod.log
cat results/Module_Reload_Validation/<profile>/iter_01/unload_failure_state/ps.log
```

Common causes:

- another module is holding the target,
- a userspace process has an open device node,
- a service restarted after quiesce,
- the module is part of the active display/audio/network path,
- the profile is targeting the wrong module variant for the platform.

### `fastrpc` unload times out

Check:

```sh
cat results/Module_Reload_Validation/fastrpc/iter_01/hang_evidence/timeout_summary.log
cat results/Module_Reload_Validation/fastrpc/iter_01/hang_evidence/holders.log
cat results/Module_Reload_Validation/fastrpc/iter_01/hang_evidence/ps.log
cat results/Module_Reload_Validation/fastrpc/iter_01/hang_evidence/dmesg_after_sysrq.log
```

If the unload task is stuck in kernel space, the framework can capture evidence but cannot always recover the kernel unload path in-place.

### `snd_soc_qcom_sdw` takes too long

Use:

```sh
PROFILE_QUIESCE_ONCE="yes"
```

Also run with fewer iterations during bring-up:

```sh
./run.sh --module snd_soc_qcom_sdw --iterations 1 --timeout-unload 60 --timeout-load 60
```

### `msm` unload fails

`msm.ko` is the modern DRM display/GPU driver and may be held by active display/GPU clients.

Inspect:

```sh
lsmod | grep '^msm '
ls -l /dev/dri/
cat results/Module_Reload_Validation/msm/iter_01/unload_failure_state/holders.log
cat results/Module_Reload_Validation/msm/iter_01/unload_failure_state/ps.log
```

If active display is required for the test environment, keep `msm` out of broad overlay lists or mark it non-reloadable for that platform until a safe quiesce path is validated.

## Safety notes

This suite is intended for profiled, supported modules only. It should not blindly reload every loaded kernel module.

Some profiles are disruptive:

- Wi-Fi reload can interrupt network access.
- Ethernet reload can interrupt remote access.
- Display/GPU reload can stop Weston or display-manager.
- Camera reload can stop camera pipelines.
- Audio reload can stop active audio services.
- FastRPC reload can impact DSP clients.

Keep `enabled.list` conservative for common CI. Run disruptive profiles explicitly or through prepared profile lists when the test plan expects those side effects.

## Platform notes

Module names differ across Qualcomm platforms and image combinations.

Examples:

- Wi-Fi can appear as `ath11k_pci`, `ath11k_ahb`, or `ath12k_pci`.
- Ethernet can appear as `dwmac_qcom_eth` or `tc956x_pcie_eth`.
- Upstream video can appear as `venus_core` or `qcom_iris`.
- Downstream video overlay can appear as `iris` or `iris_vpu`.
- Modern GPU/display uses `msm.ko`.
- Legacy KGSL uses `msm_kgsl.ko` and is not expected on modern RB3Gen2/newer DRM stacks.
- SoundWire/ASoC reload should target the top-level holder of `snd_soc_qcom_sdw`, not always `snd_soc_qcom_sdw` directly.

Use these commands before deciding which profile belongs in a platform list:

```sh
lsmod
ls /sys/module/<module>/holders 2>/dev/null
modinfo <module>
find /lib/modules/$(uname -r) /usr/lib/modules/$(uname -r) -name '*.ko*' | grep -E '<module>|<subsystem>'
```

