# Kubernetes_Kernel_Config

Validates the required Linux kernel configuration options for Kubernetes support on the target.

## What this test checks

The test verifies that the following kernel configs are present with the exact expected values:

- `CONFIG_CGROUP_FAVOR_DYNMODS=y`
- `CONFIG_CFS_BANDWIDTH=y`
- `CONFIG_CGROUP_HUGETLB=y`
- `CONFIG_NETFILTER_XT_MATCH_COMMENT=m`
- `CONFIG_IP_NF_TARGET_REDIRECT=m`
- `CONFIG_HUGETLBFS=y`

## Validation method

The test uses the shared `check_kernel_config()` helper from `Runner/utils/functestlib.sh`.

This helper is expected to support exact config checks such as:

- `CONFIG_FOO=y`
- `CONFIG_BAR=m`

The test fails if any required config is missing or does not match the expected value.

## Result semantics

- `PASS` when all required Kubernetes kernel configs are present with the expected values
- `FAIL` when any required config is missing or mismatched

## Output

The test writes its final result to:

- `Kubernetes_Kernel_Config.res`

Expected result format:

- `Kubernetes_Kernel_Config PASS`
- `Kubernetes_Kernel_Config FAIL`
