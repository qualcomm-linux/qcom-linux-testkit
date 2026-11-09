# SMMU runtime validation

Run `./run.sh` from this directory, or invoke it by absolute path from Runner.
The suite checks registered IOMMU group members and each enabled DT `iommus`
context that exposes a runtime bus device. Runtime attachment determines
applicability, kernel configuration alone does not establish DMA protection.
Device discovery follows `of_node` links across sysfs buses, including AMBA
CoreSight sinks and platform child contexts. An unrelated working trace sink
does not prove that an ETR has an IOMMU attachment.
When several runtime devices share a DT node, discovery prefers a device with
an IOMMU group, then a bound device, ahead of an unbound auxiliary proxy.
The selected device must have a link to its actual kernel group and exact reverse
membership in that group's devices directory. Missing or inconsistent attachment
remains a failure, including when only proxy devices are exposed. A missing
independent driver link is diagnostic, another driver can configure the DMA
device. Verified attachment does not claim driver or functional DMA readiness.
Container parents do not need a group when DMA contexts are declared on children.
Unregistered DT children are not independently asserted, because a parent can
consume them without creating a bus device. Registered contexts lacking group
membership fail. The existing shared `iommu_validate_runtime_devices` helper
handles this registered scope and retains its default all-context mode for other
callers. There is no separate suite-specific collector.
No board-name or device-address mapping is used.

`smmu.res` stays beside `run.sh` for existing plans. Unique diagnostics are under
`$PWD/results/smmu/run-*/`, including `iommu_contexts.tsv`,
`iommu_group_members.tsv`, the DT/device index,
`iommu_device_candidates.tsv`, `dmesg_snapshot.log` and `dmesg_errors.log`.
The candidates file records priority, DT node and device path. Kernel errors
and context failures are also printed to stdout. Group members are printed on
attachment failure. Fault and bypass wording is treated as an error,
never as a benign exclusion. The captured log is reused for all filtering.
The ordinary strict or lazy TLB invalidation policy announcement is benign.
Only the complete policy line is excluded, with optional timestamp/thread
prefixes, whether separated by spaces or adjacent. Invalidation errors, timeouts and
translation or permission faults continue to fail.

The same image-provided shell tools are used on Yocto, Debian, Ubuntu and CentOS.
No packages are installed. Missing tools skip. Unavailable DT or kernel-log
evidence is reported as a skipped subcheck, distinct from validated group
registration. Any discovered attachment or kernel error makes the suite fail.
