# qcom-linux-testkit

<!-- Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries. -->
<!-- SPDX-License-Identifier: BSD-3-Clause -->

qcom-linux-testkit provides on-device Linux validation suites for Qualcomm
platforms. It covers kernel interfaces and userspace features, with standalone
shell entry points and LAVA test definitions for automated execution.

Suites support workflows using Yocto, including meta-qcom, and distributions
such as Debian, Ubuntu, and CentOS. Applicability depends on the individual
suite, running kernel, device tree, firmware, installed tools, and connected
hardware. An inventory entry does not mean that a test has passed on every
board or distribution.

## Repository layout

```text
Runner/
  init_env          Environment setup and stdout capture
  run-test.sh       Launcher for named suites
  config/           Shared configuration
  plans/            LAVA test definitions grouping multiple suites
  suites/
    AI_ML/
    Connectivity/
    Kernel/
    Multimedia/
    Performance/
    System/
    Virtualization/
  utils/            Shared shell libraries and result publication
scripts/            Repository maintenance and inventory generation
.github/workflows/  Contribution checks and publishing workflows
```

Existing suites include CPU frequency, buses, Bluetooth, WiFi, Ethernet,
audio playback and recording, camera, graphics, video, and sensors.
Browse [Runner/suites](Runner/suites) or the
[live test inventory](https://qualcomm-linux.github.io/qcom-linux-testkit/)
for the available tests. The inventory is generated from the repository's
`main` branch.

## Prepare the target

Read the selected suite's README, when present, and its `run.sh` options before
running it. Provision the required tools, firmware, configuration, media, and
fixtures in the image or through the lab setup. Some suites require root access,
network peers, attached peripherals, or a display.

A kernel, device tree, firmware, and ramdisk that boots to a shell are sufficient
only for suites whose dependencies are available there. Tests using services,
desktop sessions, multimedia clients, or other rootfs components need those
components or separate driver-level coverage. Python is not a universal DUT
requirement, but individual suites may require it.

Use a dedicated test device. Depending on the suite and options, existing tests
can change services, device state, boot configuration, or packages. Review those
prerequisites and effects before running a suite.

## Run a test

Keep the complete `Runner` directory together so scripts can find `init_env`
and the shared libraries. The installation path is flexible, but the test
directory must be writable for results and logs.

For a DUT with Git and network access, run these commands on the DUT with the
permissions required by the selected suite:

```sh
git clone https://github.com/qualcomm-linux/qcom-linux-testkit.git
cd qcom-linux-testkit/Runner
./run-test.sh CPUFreq_Validation
cat suites/Kernel/Baseport/CPUFreq_Validation/CPUFreq_Validation.res
```

The CPU frequency example changes CPU frequency settings. Select a suite
appropriate to your hardware and validation needs.

If Git is unavailable on the DUT, clone on the host and copy `Runner`.
For example, on the host, replace the example address with your DUT address:

```sh
git clone https://github.com/qualcomm-linux/qcom-linux-testkit.git
cd qcom-linux-testkit
DUT=root@192.0.2.10
ssh "$DUT" 'mkdir -p /var/qcom-linux-testkit'
scp -r Runner "$DUT":/var/qcom-linux-testkit/
```

Then, from a shell on the DUT:

```sh
cd /var/qcom-linux-testkit/Runner
./run-test.sh CPUFreq_Validation
```

You can also invoke a suite directly from its directory:

```sh
cd /var/qcom-linux-testkit/Runner/suites/Kernel/Baseport/CPUFreq_Validation
./run.sh
cat CPUFreq_Validation.res
```

The launcher accepts `./run-test.sh <testcase_name> [arguments...]` and forwards
arguments to a single suite. Options vary by suite. Its summary expects the
default `<testcase_name>.res` filename, so use direct invocation and collect the
matching result file when a suite supports an alternative result name.

Prefer named suites or a device-specific LAVA plan. The launcher's `all` mode
uses a limited directory search and is not a complete inventory runner.

## Results and logs

A result file contains the testcase ID followed by its verdict, for example:

```text
CPUFreq_Validation PASS
```

Use the `.res` verdict and diagnostic logs to assess the run. A zero shell exit
status alone does not establish PASS. The shared result finalizer exits zero
after writing PASS, FAIL, or SKIP so LAVA can publish the result.

The environment bootstrap normally captures stdout and stderr in a
timestamped log in the invocation directory. Suites may also keep detailed
artifacts under `results/`. Collect the current run's `.res` file and logs.
Treat missing results as incomplete execution, not success.

## LAVA integration

Per-suite YAML files launch the test and publish its result using
[send-to-lava.sh](Runner/utils/send-to-lava.sh).
The [plans directory](Runner/plans) contains grouped test definitions, including:

- [meta-qcom nightly config1](Runner/plans/meta-qcom-nightly_config1.yaml)
- [meta-qcom nightly config2](Runner/plans/meta-qcom-nightly_config2.yaml)

These definitions require a LAVA job with appropriate device, boot image,
dependencies, and assets. They are not arguments to `run-test.sh`.
See the public [lava-test-plans](https://github.com/qualcomm-linux/lava-test-plans)
repository for job orchestration.

Other CI systems can invoke the same suites and collect their result files
and artifacts.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for suite layout, shared helper usage,
result and YAML conventions, portability checks, and signed commits.
Report bugs and propose coverage through
[GitHub issues](https://github.com/qualcomm-linux/qcom-linux-testkit/issues),
including the testkit revision, platform, image, command, result, and relevant
logs.

## License

This project uses the BSD-3-Clause license. See [LICENSE](LICENSE).
