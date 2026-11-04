# SMMU runtime validation

Run `./run.sh` from this suite on Yocto, Debian, Ubuntu or CentOS. Uses image
tools only: cat, grep, sort, readlink, mkdir, tr and sed.

The test inventories all bus devices and IOMMU group membership. It validates
registered devices whose runtime DT node and ancestors are enabled and whose
node declares `iommus`. Device names do not decide applicability. A bound DMA
master must expose both its group link and reverse group membership. Registered
unbound DMA devices FAIL. A parent wrapper without `iommus` is not mistaken for
a DMA master, and an unrelated ancestor group is not accepted as protection.

Nonregistered DT children are not independently asserted, because their parent
driver can consume them without creating a bus device. Empty runtime inventory
SKIPs, actual attachment and captured initialization/translation failures FAIL.
Group inventory is readiness coverage, it does not exercise DMA traffic.
Evidence is retained under CWD `results/smmu/run-*`, including groups.tsv,
masters.tsv, dmesg_snapshot.log, dmesg_errors.log and iommu_errors.log.

Public reference: the kernel's drivers/iommu/of_iommu.c configures a device
from the DT node supplied by its driver. Group membership is documented in
Documentation/ABI/testing/sysfs-kernel-iommu_groups.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
