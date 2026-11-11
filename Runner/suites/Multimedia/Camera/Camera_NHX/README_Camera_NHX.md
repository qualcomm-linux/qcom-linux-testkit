# Camera_NHX

Camera validation test for the Qualcomm CAMX proprietary camera stack. This test prefers the available NHX launcher (`nhx.sh` or `camera-nhx`) and also supports an explicitly selected native-HAL testcase. It collects generated image dumps, validates dumps (existence, non-zero size and checksums), and produces a PASS/FAIL `.res` file suitable for LAVA gating.

The test supports the legacy/default NHX flow, optional target-specific JSON selection for preview, video, preview+video, and snapshot validation, and an opt-in desktop CAMX package and FIT-DTB selection flow.

---

## Location

- Test script: `Runner/suites/Multimedia/Camera/Camera_NHX/run.sh`
- Utilities:
  - `Runner/utils/functestlib.sh`
  - `Runner/utils/camera/lib_camera.sh`
  - `Runner/utils/lib_pkg_provider.sh` for optional desktop package recovery
  - `Runner/utils/lib_system.sh` for EFI variable discovery and update
- Target-specific NHX JSON configs:
  - `Runner/suites/Multimedia/Camera/Camera_NHX/Kodiak/*.json`
  - `Runner/suites/Multimedia/Camera/Camera_NHX/Lemans/*.json`
  - `Runner/suites/Multimedia/Camera/Camera_NHX/Monaco/*.json`
  - `Runner/suites/Multimedia/Camera/Camera_NHX/Talos/*.json`

---

## Target JSON layout

The test expects target-specific JSON files to be stored under the same directory as `run.sh`:

```text
Camera_NHX/
  run.sh
  README_Camera_NHX.md
  Camera_NHX_Preview.yaml
  Kodiak/
    Preview_YUVNV12_MaxResolution_NHX.json
    Video_YUVNV12_MaxResolution_NHX.json
    Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
    Snapshot_YUVNV12_MaxResolution_NHX.json
  Lemans/
    Preview_YUVNV12_MaxResolution_NHX.json
    Video_YUVNV12_MaxResolution_NHX.json
    Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
  Monaco/
    Preview_YUVNV12_MaxResolution_NHX.json
    Video_YUVNV12_MaxResolution_NHX.json
    Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
  Talos/
    Preview_YUVNV12_MaxResolution_NHX.json
    Video_YUVNV12_MaxResolution_NHX.json
    Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
    Snapshot_YUVNV12_MaxResolution_NHX.json
```

Snapshot JSON files are currently expected only for targets where the files are present, such as `Kodiak` and `Talos`. Do not schedule snapshot for `Lemans` or `Monaco` unless the corresponding JSON files are added.

---

## What this test does

### NHX setup-only check

Run `./run.sh --check-setup` to validate NHX runtime prerequisites without
launching NHX, capturing frames, changing camera services, installing packages,
writing EFI variables or rebooting. This mode writes `Camera_NHX_Setup.res`,
not a capture PASS. `Camera_NHX_Setup.yaml` publishes that separate result.
Do not combine it with `--overlay`, `--fit-dtb`, `--json` or `--target`, including
`NHX_JSON`/`NHX_TARGET` environment selections.

On CentOS it checks the core CAMX packages from the existing package map,
the image-provided `efivar` utility and the `camx` EFI selection. It also retains
cached DNF listings for EPEL, both Qualcomm repositories and both CLO
repositories. Missing repositories or cache are provisioning warnings, not a
reason to fail an already installed offline NHX runtime. No repository is added,
enabled or refreshed in this mode. Use the explicit `--overlay` mode below for
repository and package recovery. If configured repositories cannot supply
`efivar`, the image owner must provision it with matching libraries. This test
does not access private shares or use `--allowerasing`.

The remaining checks reuse the normal launcher, checksum, active CAMX DT,
loaded camera module, ICP firmware and package prerequisites. Missing runtime
prerequisites produce SKIP, package-query failures/timeouts produce FAIL.
PASS confirms NHX readiness only, not physical sensor or capture functionality.
Inspect stdout and `logs/package-*.log`, `logs/repositories.log` and
`logs/repository-*.log` for the CentOS package/repository evidence.

Direct NHX is intentionally not gated on GStreamer, QMMF, `sscrpcd` or an active
`qti-cam-server`. Those belong to camera-service/GStreamer integration testing.
An initially inactive or absent camera server stays that way. If NHX stops an
active camera server, it must restore it and verify the active state. A start
failure, timeout or inactive post-start state makes the final result FAIL.
Exit and signal cleanup attempt restoration only for the service owned by this
run. Service start is bounded to 60 seconds and its output is retained in
`logs/service-restore.log`.

Examples:

```sh
# Read-only readiness, no package/EFI/service mutations
./run.sh --check-setup

# Execute NHX against the image-provided runtime
./run.sh

# Existing explicit overlay preparation, manual reboot if requested by the log
./run.sh --overlay
```

1. **Environment setup**
   - Locates and sources `init_env`
   - Sources `functestlib.sh` and `lib_camera.sh`

2. **Dependency checks**
   - Uses `check_dependencies` from `functestlib.sh` to ensure required commands exist.
   - Uses `dtc` when available. `diff` is optional and only compares checksums with a previous run, its absence does not skip NHX or weaken current-run dump validation.
   - Requires one image-provided checksum utility, selected in order: `sha256sum`, `md5sum`, then `cksum`. It does not require all three. If none is available, the suite skips before launching NHX and identifies the missing prerequisite.
   - The CentOS `--overlay` package set includes `dtc` and `diffutils`, which provide `dtc`, `fdtdump`, and `diff`.
   - Direct runs without `--overlay` do not install packages. This dependency policy is the same on Yocto, Debian, Ubuntu and CentOS.

3. **CAMX proprietary prechecks**
   - Decodes the active runtime tree with `dtc -I fs -O dts` from the resolved `/sys/firmware/devicetree/base` or `/proc/device-tree` root.
   - Uses enabled runtime nodes, rather than text matches in the full DTS, as authoritative CAMX evidence. Downstream CAMX-style nodes include:
     - `qcom,cam-sensor`
     - `qcom,cam-gmsl-sensor`
     - `qcom,cam-gmsl-deserializer`
     - `qcom,eeprom`
     - `qcom,cci`
     - `qcom,csiphy`
     - `qcom,cam-tpg1031`
     - `qcom,camera`
   - Retains line-numbered camera and sensor matches from the decoded DTS for diagnosis. These artifacts can include disabled nodes and are not used alone to declare the CAMX runtime active.
   - Uses `fdtdump` only as optional secondary raw-FDT evidence.
   - Camera kernel module detection and loaded-state validation, including `camera_x1e80100` on Glymur
   - ICP firmware presence check (`CAMERA_ICP`)
   - `dmesg` scan for camera warnings/errors
   - CAMX package presence check through the available `opkg`, Debian, or RPM package database
   - With `--overlay`, an unavailable package inventory is warn-only after the package set was verified successfully
   - Sensor presence check is warn-only because NHX may still work depending on target/test config

4. **Runs NHX**
   - Resolves legacy `nhx.sh` from `PATH` first, then `camera-nhx` from `PATH`, and finally the packaged CAMX location `/usr/libexec/camx/nhx.sh`.
   - Default mode runs the selected NHX launcher with no argument, preserving the existing SoC-specific default behavior.
   - Optional mode accepts one selected JSON via `--json` and optionally `--target`.
   - The selected JSON is staged to the location expected by the selected NHX launcher.

5. **Dump validation**
   - Collects dump file list from NHX output and/or dump directory based on a marker timestamp.
   - Validates:
     - Dump list is non-empty
     - Each dump file exists
     - Each dump file size is greater than `0` bytes
   - Generates checksums using the selected utility and writes checksum files. A failed checksum command fails validation even if it prints partial output.
   - Previous-run comparison is advisory. Without `diff` it is omitted with an INFO message. A comparison error is reported separately from changed checksums and does not fail current-run validation.

6. **Result decision**
   - Parses `Final Report -> [X PASSED] [Y FAILED] [Z SKIPPED]` from the NHX log.
   - FAIL if:
     - Final Report is missing or unparseable
     - The NHX launcher exits nonzero, even if a success summary was printed
     - No NHX tests passed
     - NHX reports `FAILED > 0`
     - No dumps are detected
     - Any dump is missing or zero bytes
     - Dump checksum validation helper fails
     - Restoration of a camera server stopped by the test fails
   - Writes final result to: `Camera_NHX.res`

---

## Desktop CAMX overlay flow

On Debian and Ubuntu, an explicit overlay request ensures the complete mapped
`camera-nhx` package set:

```text
camx-dkms camx-glymur libcamx-glymur1 camx-firmware-glymur camx-nhx
```

On CentOS Stream 10, the runner ensures the complete mapped Kodiak package set:

```text
camx-dkms camx-firmware-kodiak camx-kodiak libcamx-kodiak1 dtc diffutils
```

Ubuntu uses the APT sources already configured in the image. Debian may use the
Qualcomm `qli-staging` source. CentOS prepares EPEL and the Qualcomm Linux
`aarch64` and `noarch` RPM repositories plus `clo-rpm-aarch64` and
`clo-rpm-noarch` before recovery when the mapped CAMX package set is incomplete.
When the complete set is already installed, the runner reuses it without
repository preparation, metadata refresh or package installation. An absent
`efivar` may still require the existing explicit-overlay command recovery.
The CLO repositories use
`https://artifacts.codelinaro.org/artifactory/qli-rpm/centos/10/os/`, with
`aarch64/` and `noarch/` respectively, `priority=10` and `gpgcheck=0` as specified
by the LRH setup procedure. Missing CLO definitions are written to a separate
`qcom-testkit-camx-clo.repo` alongside the Qualcomm repository file. Existing
enabled definitions are preserved. Disabled or conflicting definitions require
administrator correction and are not overwritten. Metadata is refreshed and
both CLO package listings are verified, with diagnostics retained in
`logs/camx-*-repositories.log` and `logs/camx-*-packages.log`.
Yocto does not use
this package-recovery flow and continues with its image-provided camera stack.
The runner passes the complete mapped package list to the shared package
provider instead of selecting a suite-local subset. If package recovery fails,
the explicit `--overlay` request reports FAIL with the complete required list.

`--overlay` requires the CAMX FIT DTB and uses the compatibility name `camx`.
The same requirement can be stated explicitly with `--fit-dtb camx`:

```sh
./run.sh --overlay --fit-dtb camx
```

On Debian, Ubuntu and CentOS, explicit overlay preparation first reuses an
installed `efivar` or recovers the mapped package from configured repositories.
It mounts `efivarfs` at the runtime EFI directory only if not already mounted,
then verifies the filesystem type. A newly created mount remains mounted.
Existing read-only mounts are restored to read-only after EFI write handling.
An unavailable EFI runtime produces SKIP, while package recovery or mount
failures produce FAIL with diagnostics. A failed `efivar` query or duplicate
`VendorDtbOverlays` variables produces FAIL, not a missing-variable SKIP.
Base and setup-only runs do not install
`efivar` or mount efivarfs.

The test discovers the platform's `VendorDtbOverlays` EFI variable with
`efivar -l`. The EFI variable GUID is never supplied by the user or hardcoded
in the test. It verifies the complete payload through a bounded `efivar -p`
read, accepting `camx` with optional trailing NUL bytes. Read errors and
unrecognized output fail without writing EFI. A confirmed different value
permits an initial write of `camx` without a trailing newline, followed by
readback and storage synchronization. Raw before, write and readback evidence
is retained separately under `logs/Camera_NHX_camx_efi_*.log`, with `.write`
and `.write.readback` suffixes, and replayed to stdout.

When a new DTB selection is written, the test records `Camera_NHX SKIP` with a
reboot-required message instead of rebooting within the LAVA test shell. Reboot
the target, then rerun the same command to perform NHX validation with the new
device tree:

```sh
reboot
./run.sh --overlay --fit-dtb camx
```

The EFI value is a comma-separated overlay list. A complete `camx` entry in
`camx,el2gh` or `el2gh,camx` counts as selected, but `camx2` and `xcamx` do not.
There is no fixed entry count, order or allowlist of other overlay names.
Existing entries are preserved when adding a missing selection. Printable
ASCII names are treated as opaque entries, separated by commas. Malformed
lists and unreadable EFI values fail without a write. This list comparison is
limited to CAMX selection, other EFI comparisons and immediate write readback
still require the exact payload.

If the CAMX FIT DTB is already selected, the test continues with runtime DT and
camera-module checks without rewriting EFI. The read-only `--check-setup` path
uses the same complete-entry comparison. A newly attempted write records
the variable, requested value and kernel boot ID in
`logs/camx-fit-selection.pending`. A repeat on the same boot only reminds the
operator to reboot, it does not rewrite the variable. After reboot, the runner
requires both the requested entry in EFI and enabled CamX runtime DT nodes before
retiring that record and proceeding. A missing entry, missing runtime nodes or
invalid pending record produces FAIL, not another automatic setup attempt.
The record is not a cached setup-success flag and never bypasses live checks.
Keep it across the manual reboot. After a failed write or firmware-selection
failure, inspect the retained diagnostics and correct the cause before
explicitly removing this one pending file to retry setup. Do not remove it
merely to bypass a failed post-reboot check.

Qualcomm UEFI uses SoC and board identifiers from CDT to
select a compatible FIT configuration. Linux does not expose the firmware's
raw CDT decision directly, so the test validates its result: EFI selection,
the decoded active runtime tree, enabled downstream CamX nodes, and the loaded
board-specific camera module. This is generic across FIT-enabled Qualcomm SoCs
and does not hardcode a SoC-to-DTB table in the test.

The implementation follows the public Qualcomm FIT metadata flow documented in
[`qcom-dtb-metadata`](https://github.com/qualcomm-linux/qcom-dtb-metadata/blob/main/Documentation.md)
and generated by the public
[`meta-qcom` FIT image class](https://github.com/qualcomm-linux/meta-qcom/blob/master/classes-recipe/dtb-fit-image.bbclass).

If EFI is set to `camx` but the active runtime tree has no enabled downstream
CamX nodes, the test records FAIL because the selected FIT configuration and
the running tree disagree. If the enabled nodes are present but the camera
module artifact is present but the module is not loaded, the explicit EFI
selection path records FAIL and asks for module/probe diagnostics. It does not
repeatedly ask for another reboot. The test never issues a reboot itself.

---

## NHX JSON selection

### Default behavior

```sh
./run.sh
```

This preserves the existing behavior and runs the first available launcher in this order:

```text
nhx.sh from PATH
camera-nhx from PATH
/usr/libexec/camx/nhx.sh
```

The selected launcher then selects the default JSON based on SoC ID:

- Kodiak (`497`, `498`, `575`) -> `NHX.YUV_NV12_Prev_MaxRes`
- Lemans/Monaco (`534`, `606`, `667`, `674`, `675`, `676`) -> `NHX.YUV_NV12_Prev_MaxRes`
- Talos (`680`) -> `NHX.YUV_NV12_Prev_1920x1440`

### Run one selected JSON

Use `--json` to run exactly one selected JSON config:

```sh
./run.sh --json Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
```

```sh
./run.sh --json Kodiak/Snapshot_YUVNV12_MaxResolution_NHX.json
```

```sh
./run.sh --json Talos/Video_YUVNV12_MaxResolution_NHX.json
```

### Run by filename with target

When passing only a filename, use `--target` so the resolver can select the correct target folder:

```sh
./run.sh --json Snapshot_YUVNV12_MaxResolution_NHX.json --target Kodiak
```

```sh
./run.sh --json Video_YUVNV12_MaxResolution_NHX.json --target Monaco
```

Supported target names:

```text
Kodiak
Lemans
Monaco
Talos
```

### Environment variable style

The same selection can be done through environment variables:

```sh
NHX_JSON=Talos/Video_YUVNV12_MaxResolution_NHX.json ./run.sh
```

```sh
NHX_JSON=Snapshot_YUVNV12_MaxResolution_NHX.json NHX_TARGET=Talos ./run.sh
```

### Ambiguous filename handling

Many JSON filenames exist under multiple target folders. For example:

```sh
./run.sh --json Preview_YUVNV12_MaxResolution_NHX.json
```

is ambiguous because the same file can exist under `Kodiak`, `Lemans`, `Monaco`, and `Talos`.

In that case, pass `--target`:

```sh
./run.sh --json Preview_YUVNV12_MaxResolution_NHX.json --target Lemans
```

---

## How JSON staging works

The NHX launcher does not accept an arbitrary absolute JSON path. It expects a JSON name and internally checks:

```sh
/etc/camera/test/NHX/${JSON_FILE}.json
```

For wrapper execution, `--json` resolves the source file from the test directory and stages it under:

```text
/etc/camera/test/NHX/<target>/<json-file>.json
```

Then it calls the selected launcher with the launcher argument without `.json`, for example:

```sh
camera-nhx Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX
```

The same argument is used when legacy `nhx.sh` is selected. This causes the launcher to load:

```text
/etc/camera/test/NHX/Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
```

If no wrapper is installed, the selected native executable receives the JSON
basename through `--test`. Native mode stages the file directly under
`/etc/camera/test/NHX/`, not its target subdirectory. `--target` still selects
the source folder. For example:

```sh
./run.sh --json Preview_YUVNV12_MaxResolution_NHX.json --target Kodiak
# Native invocation when only nativehaltest is available:
# /usr/libexec/camx-kodiak/nativehaltest --test Preview_YUVNV12_MaxResolution_NHX

# Explicit native selection even when a wrapper is installed:
./run.sh --json Kodiak/Preview_YUVNV12_MaxResolution_NHX.json --native-bin /usr/libexec/camx-kodiak/nativehaltest
./run.sh --overlay --json Kodiak/Preview_YUVNV12_MaxResolution_NHX.json
```

Native JSON execution preserves all JSON settings. It does not append frames,
camera, timeout or dump CLI overrides. A separate 180-second process deadline
still applies. Native JSON filenames must contain letters, digits, underscores
or hyphens, start with a letter or underscore, and end in `.json`.
An identical existing destination is reused unchanged. A different existing
file or a symlink produces FAIL rather than being overwritten. New files staged
by the run are removed after capture or during interruption cleanup, provided
their contents remain unchanged. Modified files are preserved and cleanup fails.
The selected JSON is retained under `logs/native-json.*/selected.json`.

The run log and summary include:

```text
NHX JSON requested
NHX target requested
NHX JSON resolved
NHX JSON argument
```

---

## Command usage

### Native HAL executable mode

Some CentOS CAMX packages provide only `nativehaltest`, for example
`camx-kodiak-1.0.45` installs `/usr/libexec/camx-kodiak/nativehaltest` without an
NHX wrapper. The runner preserves wrapper discovery order (`nhx.sh` in PATH,
`camera-nhx` in PATH, `/usr/libexec/camx/nhx.sh`). If no wrapper is found, it
discovers `nativehaltest` in PATH, then executable
`/usr/libexec/camx*/nativehaltest` files. This is a runtime path search, not a
board-to-path table. Symlinks to the same binary count once. Multiple different
binaries require `--native-bin /absolute/path/nativehaltest`.

`--native-test Suite.Case` explicitly selects native mode even when a wrapper
exists. Use one exact testcase supported by the installed client, without
wildcards or multi-test filters. There is no guessed default testcase, automatic
full-binary run, or unadvertised test-list probe. Without a testcase or JSON, native
capture records an actionable SKIP. An unknown selected testcase, zero tests,
or a failed native CLI probe must not produce PASS.

An explicit zero-test report fails with the requested testcase and executable
identified. Capture validation is not exercised in that case, so a missing
capture directory is not reported as a second failure. Obtain the exact
`Suite.Case` from the installed client's documentation or an advertised listing
interface, or use a supported `--json` configuration. The runner does not guess another testcase or run an unfiltered
suite. Help output is retained in `logs/native-hal-help.log`, but advertising
`--test` alone does not prove that a particular testcase is installed.

Current dump-list and checksum artifacts are initialized even when captures
are absent. Other missing or invalid captures still fail validation, without
reading a nonexistent list or reusing an older run's list.

On a native failure, the final diagnostic points to any camera warnings/errors
captured before invocation. A provisioned ICP firmware file does not prove it
loaded successfully. Historical boot errors are not attributed to this capture
or used alone to reject a successful capture. Likewise, `cam --list` describes
libcamera inventory, not the proprietary CAMX HAL's physical sensor inventory.

Native-only options have no environment-variable equivalents:

- `--native-test NAME`: exact `Suite.Case`, an alternative to `--json`.
- `--native-bin PATH`: absolute executable override, otherwise runtime discovery.
- `--native-frames N`: 1 through 10000, default 150. The total time limit still applies.
- `--native-camera ID`: optional nonnegative integer camera ID. When omitted,
  leave selection to the installed client, whose supplied help defaults to
  physical cameras. Do not infer camera ID 0 from a board name.
- `--native-dump-dir PATH`: absolute directory where this binary writes images,
  default `/var/cache/camera/nativehaltest`. This selects the validation root,
  it does not redirect the binary output. Confirm the directory from client
  documentation or an observed capture before overriding it.

Readiness can discover and inspect the native CLI without running a testcase:

```sh
./run.sh --check-setup
./run.sh --check-setup --native-bin /usr/libexec/camx-kodiak/nativehaltest
```

For capture, substitute a verified installed testcase for the placeholder below:

```sh
native_case='Suite.Case' # Replace with a testcase supported by this client.
./run.sh --native-test "$native_case"
./run.sh --native-test "$native_case" --native-frames 60 --native-camera 0
./run.sh --native-test "$native_case" --native-bin /usr/libexec/camx-kodiak/nativehaltest --native-dump-dir /var/cache/camera/nativehaltest
./run.sh --overlay --native-test "$native_case"
```

The example camera ID is an explicit operator choice, not a detected default.
Native capture flags cannot be combined with `--check-setup`, except the
read-only `--native-bin` discovery override. Native JSON mode accepts the same
`--json`, `--target`, `NHX_JSON` and `NHX_TARGET` selections as the wrapper route.
Do not combine JSON with `--native-test`, `--native-frames` or `--native-camera`,
which would conflict with the configuration. These combinations fail before
overlay preparation. `--native-bin` and `--native-dump-dir` are allowed with JSON.

The native CLI is checked with a bounded `--help` query. If it returns usage
status 1, 2 or 255 and advertises `--h`, the probe retries that option. Each query
has a 15-second limit. These nonzero statuses are accepted only when the output
contains usage text and all required capture options. Crashes, timeouts and
missing options still fail. When retried, the first response is retained in
`logs/native-hal-help-long.log` and the final response in
`logs/native-hal-help.log`. This probes help only, never the full test binary.
Explicit `Suite.Case` execution uses the advertised `--test` or `--gtest_filter` selector,
`--frames`, `--p` for stdout
and `--timeout 5000` for per-buffer/result waits. A separate 180-second managed
deadline bounds the whole capture. No `--nid` option is passed, image dumping
must remain enabled. Raw output is retained in the normal run log and replayed
to stdout when execution ends. Help evidence is retained in
`logs/native-hal-help.log`. Capture timeout, nonzero exit and service-restoration
failure all fail the result. Interrupted native captures stop their owned
process and timeout watcher before camera-service restoration.
JSON mode requires only the advertised `--test` option and invokes the verified
JSON basename, without the other capture options described above.

Explicit `Suite.Case` result parsing requires exactly one matching `RUN` and `OK` testcase
marker plus either a completed single-test GoogleTest summary or one CAMX
`Final Report -> [1 PASSED] [0 FAILED] [0 SKIPPED]`. Missing or unfamiliar
result formats fail closed and require the retained native stdout for diagnosis,
they are not treated as successful capture. JSON mode accepts one CAMX report
with exactly one passed, zero failed and zero skipped tests. It does not require
GoogleTest-style markers that the JSON-backed native client may omit. If RUN/OK
markers are emitted, they must be a single matching pair, whose internal name
may differ from the JSON basename. Zero tests, multiple reports, partial markers
and reported failures remain FAIL. Process exit and fresh dump validation are
required in both modes, a summary alone is not a capture PASS.

CAMX per-test lines such as `"NativeHalX.OmniTest" report -> [PASSED]` are
parsed separately from GoogleTest numeric totals such as `[ PASSED ] 1 test.`.
When present, exactly one successful per-test report is allowed and its name
must agree with any RUN/OK markers. Failed, skipped, malformed or duplicate
per-test reports still fail, even when the final summary claims success.

Native capture also uses the existing fresh-file, nonempty-file and checksum
diversity validation. It permits untagged `.yuv`, `.raw`, `.bin`, `.jpg` and
`.jpeg` images in the selected output directory and its subdirectories, while
ignoring logs and stale files. Wrapper dump discovery and invocation are
unchanged. No packages are installed for native base runs. The existing Yocto
YAML interface remains unchanged. Its existing JSON selection also works when
runtime discovery finds only a native executable.

The [Kodiak configuration notes](Kodiak/README.md) describe the stream settings
preserved by both JSON launch paths.

```sh
./run.sh [--overlay] [--fit-dtb NAME] [--json JSON_FILE] [--target TARGET] [--help]
```

Options:

```text
--overlay          Verify the Camera NHX CAMX package set on Debian, Ubuntu,
                   or CentOS, install missing packages, and ensure the CAMX
                   FIT DTB is selected.

--fit-dtb NAME     Select NAME as the FIT DTB compatibility name for the next
                   boot. Requires --overlay on a supported desktop distro.
                   Camera_NHX accepts camx, which is the --overlay default.

--json JSON_FILE   NHX JSON file to pass to the selected NHX launcher.
                   Can be absolute, relative to Camera_NHX/, or relative
                   to the target folder when --target is provided.

--target TARGET    Target folder name: Kodiak, Lemans, Monaco, Talos.
                   Used to resolve/stage --json under /etc/camera/test/NHX.

--help             Show usage.
```

Examples:

```sh
./run.sh
```

```sh
./run.sh --overlay
```

```sh
./run.sh --json Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
```

```sh
./run.sh --json Snapshot_YUVNV12_MaxResolution_NHX.json --target Kodiak
```

```sh
NHX_JSON=Talos/Video_YUVNV12_MaxResolution_NHX.json ./run.sh
```

---

## Outputs

Created under the test directory:

- Logs:
  - `logs/Camera_NHX_<timestamp>.log`
  - `logs/Camera_NHX_dtc_<timestamp>.log`
  - `logs/dmesg_<timestamp>/dmesg_snapshot.log`
  - `logs/dmesg_<timestamp>/dmesg_errors.log` when matches exist

- Out files:
  - `out/Camera_NHX_summary_<timestamp>.txt`
  - `out/Camera_NHX_running_<timestamp>.dts`, when `dtc` is available
  - `out/Camera_NHX_runtime_camera_<timestamp>.log`, when `dtc` is available
  - `out/Camera_NHX_runtime_sensors_<timestamp>.log`, when `dtc` is available
  - `out/Camera_NHX_enabled_camx_nodes_<timestamp>.log`
  - `out/Camera_NHX_enabled_sensor_nodes_<timestamp>.log`
  - Dump list file, usually under `out/nhx_<timestamp>/`
  - Checksum file(s), when checksum tool/helper is available

- LAVA gating result:
  - `Camera_NHX.res`

---

## Dump directory

By default, the test expects NHX dumps under:

```text
/var/cache/camera/nativehaltest
```

This is referenced in `run.sh` as `DUMP_DIR`.

---

## How to run locally

From the test folder:

```sh
cd Runner/suites/Multimedia/Camera/Camera_NHX
./run.sh
cat Camera_NHX.res
```

Run a selected NHX config:

```sh
./run.sh --json Lemans/Preview_YUVNV12_MaxResolution_NHX.json
cat Camera_NHX.res
```

After environment initialization this script exits `0` on FAIL/SKIP, gating is
via `.res`. A missing repository bootstrap or result-initialization failure
exits nonzero instead of publishing stale results.

---

## How to run in LAVA

Default NHX preview flow:

```yaml
metadata:
  name: camera_nhx_preview
  format: "Lava-Test Test Definition 1.0"
  description: "Camera NHX default validation"
  os:
    - linux
  scope:
    - functional

run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Multimedia/Camera/Camera_NHX
    - ./run.sh || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh Camera_NHX.res
```

Selected NHX config flow:

```yaml
metadata:
  name: camera_nhx_selected_config
  format: "Lava-Test Test Definition 1.0"
  description: "Camera NHX selected JSON validation"
  os:
    - linux
  scope:
    - functional

params:
  NHX_JSON: "Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json"

run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Multimedia/Camera/Camera_NHX
    - ./run.sh --json "${NHX_JSON}" || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh Camera_NHX.res
```

Selected filename plus target:

```yaml
params:
  NHX_JSON: "Snapshot_YUVNV12_MaxResolution_NHX.json"
  NHX_TARGET: "Kodiak"

run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Multimedia/Camera/Camera_NHX
    - ./run.sh --json "${NHX_JSON}" --target "${NHX_TARGET}" || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh Camera_NHX.res
```

---

## PASS/FAIL/SKIP semantics

### PASS

- NHX `Final Report` parsed successfully
- `FAILED=0`
- `PASSED` is greater than zero and the NHX launcher exited zero
- Dump list is non-empty
- All dump files exist and are non-zero
- Dump checksum validation helper did not fail, when used
- Any camera server stopped by the test was successfully restored

### FAIL

- Any PASS condition is not met
- Explicit `--overlay` package recovery fails or leaves the mapped package set incomplete
- EFI selects `camx`, but the active runtime DT has no enabled downstream CamX nodes
- EFI read/parse/write/readback fails, or a pending selection does not persist after reboot
- EFI selects `camx` and the camera module artifact exists, but the module is not loaded
- NHX reports one or more failed cases
- Final Report is missing/unparseable
- No dumps are detected
- Any dump is missing or zero bytes
- Dump checksum validation helper fails
- The NHX launcher exits nonzero or reports no passing tests
- A camera server stopped by the test cannot be restored to active state

### SKIP

- Missing CAMX prerequisites, such as DT patterns, camera module artifact/loaded state, ICP firmware, CAMX packages, or an executable NHX launcher (`nhx.sh` or `camera-nhx` in `PATH`, or `/usr/libexec/camx/nhx.sh`)
- The CAMX FIT DTB selection was written and a manual reboot is required before validation
- `VendorDtbOverlays` is unavailable when `--overlay` was requested
- No enabled downstream CamX node exists when `camx` was not explicitly selected
- Requested `--json` file is not found
- Requested JSON filename is ambiguous and `--target` was not supplied
- JSON staging under `/etc/camera/test/NHX` fails

---

## Notes and troubleshooting

### Timestamps show 1970-01-01

If logs show `1970-01-01`, the device clock is not set. This is common on early boot images or minimal init environments. It does not affect functional correctness, but it can make log browsing confusing.

### The NHX launcher reports JSON file not found

If you see a message similar to:

```text
Warning: JSON file not found: /etc/camera/test/NHX/<name>.json
```

check that:

- `run.sh` logged a valid `NHX JSON resolved`
- `run.sh` logged a valid `NHX JSON argument`
- the selected JSON was staged under `/etc/camera/test/NHX`
- the argument passed to the selected NHX launcher does not include an absolute `/tmp/...` path
- the argument passed to the selected NHX launcher does not include the `.json` suffix

Correct expected example:

```text
NHX JSON argument: Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX
```

### Camera_NHX SKIPs due to DT mismatch

The test checks CAMX-related DT patterns. For downstream CAMX overlays, useful matches include:

```text
qcom,cam-sensor
qcom,cam-gmsl-sensor
qcom,cam-gmsl-deserializer
qcom,eeprom
qcom,cci
qcom,csiphy
qcom,cam-tpg1031
qcom,camera
```

If the test still SKIPs, inspect the saved logs and confirm the active DT overlay exposes camera/CAMX nodes.

### No dumps detected

- Confirm NHX actually produced dumps and the dump path matches `DUMP_DIR`
- Check `logs/Camera_NHX_<timestamp>.log` for `Saving image to file:` lines
- Check permissions and free space under `/var/cache/camera/nativehaltest`

### dmesg warnings

The script scans dmesg and reports warnings, but does not fail only because camera warnings exist. Use the saved snapshot/errors logs to debug.

### CAMX bind graph not observed

If CAMX bind graph markers are not seen, the script logs a warning. This usually indicates CAMX stack did not fully initialize or relevant drivers/services did not come up.
