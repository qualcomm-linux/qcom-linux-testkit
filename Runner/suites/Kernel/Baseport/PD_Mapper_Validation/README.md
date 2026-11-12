# PD Mapper validation

`PD_Mapper_Validation` checks the Qualcomm PD Mapper runtime without assuming a
board-specific process-domain list. It prefers the modern kernel implementation
exposed through `CONFIG_QCOM_PD_MAPPER`, the `qcom-pdm-mapper` auxiliary driver,
and runtime devices named `qcom_common.pd-mapper.*`. When those runtime devices
are absent, it falls back to an installed `pd-mapper.service` or running
`pd-mapper` process. A binary in `PATH` alone does not make the test applicable.

This follows the public kernel implementation in
[`drivers/soc/qcom/qcom_pd_mapper.c`](https://github.com/qualcomm-linux/kernel/blob/qcom-next/drivers/soc/qcom/qcom_pd_mapper.c),
the `CONFIG_QCOM_PD_MAPPER` description in
[`drivers/soc/qcom/Kconfig`](https://github.com/qualcomm-linux/kernel/blob/qcom-next/drivers/soc/qcom/Kconfig),
and the auxiliary-device creation in
[`drivers/remoteproc/qcom_common.c`](https://github.com/qualcomm-linux/kernel/blob/qcom-next/drivers/remoteproc/qcom_common.c).
The fallback follows the public
[`linux-msm/pd-mapper`](https://github.com/linux-msm/pd-mapper) daemon and the
[`meta-qcom` recipe](https://github.com/qualcomm-linux/meta-qcom/blob/master/recipes-support/pd-mapper/pd-mapper_1.1.bb).

The suite is not configured per SoC. Run `./run.sh` without target-specific
parameters. It dynamically checks whether PD Mapper applies, discovers the live
QRTR topology, and derives service-registry files from running remote processors.
The required `64:1:1` QRTR tuple is common to the public PD Mapper protocol
rather than a board-specific service guess. The kernel and userspace sources
declare QMI version `0x101`; QRTR packs that value into an eight-bit displayed
version and the upper instance bits, which `qrtr-lookup` renders as version `1`,
instance `1`.

When Python and runtime registry data are available, the suite also sends the
read-only QMI `SERVREG_LOC_GET_DOMAIN_LIST` request (`0x21`) to the unique live
mapper endpoint. By default it tries a bounded, deterministic set of services
derived from the registry and selects the first service with returned domains.
It requires the returned domain and instance set to match that registry. If a
kernel mapper has no registry service in common, it queries the public kernel
contract `tms/servreg` and requires a nonempty, structurally valid domain list.
The same kernel query is used when no registry file is installed.
The userspace daemon has no such synthetic service, so its functional result
must match registry data.
It uses local AF_QIPCRTR communication and does not require Ethernet, Wi-Fi, or
access to an external server. The client uses Python's named address-family
constant when available and the public Linux family number otherwise.

This discovery model is portable across image types. meta-qcom Yocto images can
provide either the kernel driver or the userspace daemon depending on the
machine and image revision. Ubuntu and Debian images are not assumed to install
either implementation, so the same runtime kernel, unit, process, QRTR, and
registry checks decide applicability without installing packages.

Applicability comes from runtime auxiliary devices or the live protocol tuple,
not from kernel configuration alone. Every discovered auxiliary device must be
bound to the registered auxiliary driver whose kernel-generated name ends in
`.qcom-pdm-mapper`, and an instantiated mapper must advertise the public service
registry locator tuple `64:1:1`. The suite also derives service-registry `.jsn` and
`.jsn.xz` files from the firmware paths of running remote processors. When
Python is image-provided, those files are parsed and checked for the public
`sr_domain` object and `sr_service` array. Missing optional registry files or a
JSON validator is reported as a subcheck `SKIP`, not hidden as success.

## Run

```sh
./run.sh
./run.sh --timeout 15
./run.sh --service avs/audio
```

`--timeout` overrides `PD_MAPPER_TIMEOUT`, whose default is 10 seconds. It only
changes probe bounds and does not select a target or service.

`--service` overrides `PD_MAPPER_SERVICE`. Ordinary users should leave it empty
so a service and expected domains are selected from live registry files. An
override must name a `provider/service` entry present in those files and should
come from a product or CI requirement. Precedence is CLI, environment, then
dynamic registry discovery. The suite does not maintain per-SoC service lists.

## Result policy

- `PASS`: the selected kernel or userspace implementation is ready, QRTR service
  `64:1:1` is advertised, registry data is well formed, and the functional QMI
  query returns the exact registry-derived domains when its optional Python
  transport is available. Without the Python `lzma` module the `.jsn.xz` files
  stay unread, so the reply must contain the domains of the readable files
  and may hold more (`comparison=readable-registry-subset`).
- `FAIL`: a kernel auxiliary device is incorrectly bound, a provisioned
  userspace service is inactive, the required QRTR advertisement is missing,
  topology collection fails, registry data is malformed, the functional reply
  is invalid or disagrees with the registry, or relevant kernel errors exist.
- `SKIP`: no kernel device, userspace unit/process, or live protocol
  advertisement is present. Missing registry files, Python, both QRTR lookup
  providers, or kernel-log access can also skip only the affected subcheck.

Use `[PD-MAPPER-KERNEL]`, `[PD-MAPPER-AUX]`, `[PD-MAPPER-USERSPACE]`,
`[PD-MAPPER-SELECTION]`, `[PD-MAPPER-QRTR-ENDPOINT]`,
`[PD-MAPPER-REGISTRY-FILE]`, `[PD-MAPPER-FUNCTIONAL]`,
`PD_MAPPER_SELECTION`, `PD_MAPPER_PROBE`, `PD_MAPPER_IO`, and
`PD_MAPPER_FUNCTIONAL` to identify the implementation, endpoint, bounded
candidate set, selected service, QMI packet proof, and returned domains in stdout.
`[PD-MAPPER-POLICY]` confirms the dynamically selected applicability path and
the protocol-defined service tuple. Service status, journal, process, topology,
registry, functional domain report, and kernel evidence is retained under the printed
`results/PD_Mapper_Validation/run-*/` directory. Object lists are bounded in
stdout and report the omitted count plus the complete artifact path when the
limit is exceeded.

Kernel health capture prefers `dmesg` and falls back to image-provided
`journalctl -k`; `kernel/dmesg_access.log` retains provider and permission
diagnostics.
