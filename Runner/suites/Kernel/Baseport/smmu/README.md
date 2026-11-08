# SMMU runtime validation

Run `./run.sh` from this directory, or invoke it by absolute path from Runner.
The suite checks the existing SMMU kernel configuration, registered IOMMU groups
and every enabled DT `iommus` context's exact runtime bus-device attachment.
Device discovery follows `of_node` links across sysfs buses, including AMBA
CoreSight sinks and platform child contexts. An unrelated working trace sink
does not prove that an ETR has an IOMMU attachment.
When several runtime devices share a DT node, discovery prefers a device with
an IOMMU group, then a bound device, ahead of an unbound auxiliary proxy.
The selected device must still have its own group. Missing attachment remains
a failure, including when only proxy devices are exposed.
Container parents do not need a group when DMA contexts are declared on children.
Missing runtime contexts or groups fail, including unresolved driver suppliers.
No board-name or device-address mapping is used.

`smmu.res` stays beside `run.sh` for existing plans. Unique diagnostics are under
`$PWD/results/smmu/run-*/`, including `iommu_contexts.tsv`, the DT/device index,
`iommu_device_candidates.tsv`, `dmesg_snapshot.log` and `dmesg_errors.log`.
The candidates file records priority, DT node and device path. Kernel errors
and context failures
are also printed to stdout. Fault and bypass wording is treated as an error,
never as a benign exclusion. The captured log is reused for all filtering.

The same image-provided shell tools are used on Yocto, Debian, Ubuntu and CentOS.
No packages are installed. Missing tools skip. Unavailable DT or kernel-log
evidence is reported as a skipped subcheck, distinct from validated group
registration. Any discovered attachment or kernel error makes the suite fail.
