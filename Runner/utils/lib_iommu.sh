#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# iommu_collect_runtime <output-directory>
# Correlate runtime group members with enabled, registered DT DMA masters.
# Wrapper names and unrelated ancestor groups do not prove DMA protection.
iommu_collect_runtime() {
    iommu_output="$1"
    IOMMU_GROUP_COUNT=0
    IOMMU_MEMBER_COUNT=0
    IOMMU_MASTER_COUNT=0
    IOMMU_ATTACHED_COUNT=0
    IOMMU_FAILURE_COUNT=0
    mkdir -p "$iommu_output" || return 1
    : >"$iommu_output/groups.tsv"
    : >"$iommu_output/masters.tsv"
    : >"$iommu_output/devices.tsv"
    for iommu_group in /sys/kernel/iommu_groups/*; do
        [ -d "$iommu_group" ] || continue
        IOMMU_GROUP_COUNT=$((IOMMU_GROUP_COUNT + 1))
        for iommu_member in "$iommu_group"/devices/*; do
            [ -e "$iommu_member" ] || continue
            iommu_member_path=$(readlink -f "$iommu_member") || return 1
            IOMMU_MEMBER_COUNT=$((IOMMU_MEMBER_COUNT + 1))
            printf '%s|%s\n' "${iommu_group##*/}" "$iommu_member_path" \
                >>"$iommu_output/groups.tsv"
        done
    done

    # Every bus can expose a DMA device, platform-only inventory misses PCI,
    # auxiliary and other runtime devices.
    for iommu_of_link in /sys/bus/*/devices/*/of_node; do
        [ -e "$iommu_of_link" ] || continue
        iommu_dt=$(readlink -f "$iommu_of_link") || continue
        [ -s "$iommu_dt/iommus" ] || continue
        iommu_enabled=1
        iommu_ancestor="$iommu_dt"
        while [ -n "$iommu_ancestor" ] && [ "$iommu_ancestor" != / ]; do
            if ! dt_node_enabled "$iommu_ancestor"; then
                iommu_enabled=0
                break
            fi
            iommu_ancestor=${iommu_ancestor%/*}
        done
        [ "$iommu_enabled" -eq 1 ] || continue
        iommu_device=$(readlink -f "${iommu_of_link%/of_node}") || continue
        printf '%s|%s\n' "$iommu_device" "$iommu_dt" >>"$iommu_output/devices.tsv"
    done
    sort -u "$iommu_output/devices.tsv" >"$iommu_output/devices-unique.tsv" || return 1
    while IFS='|' read -r iommu_device iommu_dt; do
        [ -n "$iommu_device" ] || continue
        iommu_driver=$(platform_device_driver_name "$iommu_device" 2>/dev/null) || iommu_driver=""
        if [ -z "$iommu_driver" ]; then
            log_warn "[IOMMU] DT DMA device is unbound: device=$iommu_device node=$iommu_dt"
            printf '%s|%s|unbound|none\n' "$iommu_device" "$iommu_dt" >>"$iommu_output/masters.tsv"
            IOMMU_FAILURE_COUNT=$((IOMMU_FAILURE_COUNT + 1))
            continue
        fi
        IOMMU_MASTER_COUNT=$((IOMMU_MASTER_COUNT + 1))
        iommu_attached=$(readlink -f "$iommu_device/iommu_group" 2>/dev/null) || iommu_attached=""
        # Require the group's reverse device membership as well as a link.
        iommu_group_id=${iommu_attached##*/}
        if [ -n "$iommu_group_id" ] &&
           grep -Fx "$iommu_group_id|$iommu_device" "$iommu_output/groups.tsv" >/dev/null; then
            IOMMU_ATTACHED_COUNT=$((IOMMU_ATTACHED_COUNT + 1))
            log_info "[IOMMU] attached: device=$iommu_device driver=$iommu_driver node=$iommu_dt group=$iommu_group_id"
        else
            IOMMU_FAILURE_COUNT=$((IOMMU_FAILURE_COUNT + 1))
            log_fail "[IOMMU] DT DMA master lacks group membership: device=$iommu_device driver=$iommu_driver node=$iommu_dt"
        fi
        printf '%s|%s|%s|%s\n' "$iommu_device" "$iommu_dt" "$iommu_driver" \
            "${iommu_group_id:-none}" >>"$iommu_output/masters.tsv"
    done <"$iommu_output/devices-unique.tsv"
    log_info "IOMMU inventory: groups=$IOMMU_GROUP_COUNT members=$IOMMU_MEMBER_COUNT bound_masters=$IOMMU_MASTER_COUNT attached=$IOMMU_ATTACHED_COUNT failures=$IOMMU_FAILURE_COUNT"
    [ "$IOMMU_FAILURE_COUNT" -eq 0 ]
}
