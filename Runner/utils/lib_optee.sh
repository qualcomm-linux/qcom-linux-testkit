#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

OPTEE_SAFE_XTEST_CASES="1001 1002"

# optee_select_device <device-inventory>
# Selects the first public OP-TEE character device from a captured TSV.
# Prints "device<TAB>source" with implementation_id preferred over runtime
# driver/path evidence. Returns 0 on selection, 1 when no native candidate is
# present, or 3 for unreadable input, and has no side effects.
optee_select_device() {
    osd_inventory_file="$1"

    [ -r "$osd_inventory_file" ] || return 3
    osd_selection=$(awk -F '\t' '
        $2 == "public" && $6 == "character" && $3 == "1" {
            print $5 "\timplementation-id"
            selected=1
            exit
        }
        $2 == "public" && $6 == "character" && $3 == "unreadable" &&
        $7 == "optee" && fallback == "" {
            fallback=$5 "\truntime-driver"
        }
        $2 == "public" && $6 == "character" && $3 == "unreadable" &&
        (tolower($8) ~ /(^|[\/:])optee([\/:]|$)/ ||
         tolower($9) ~ /(^|[\/:])optee([\/:]|$)/) && fallback == "" {
            fallback=$5 "\truntime-path"
        }
        END {
            if (!selected && fallback != "")
                print fallback
        }
    ' "$osd_inventory_file") || return 1
    [ -n "$osd_selection" ] || return 1
    printf '%s\n' "$osd_selection" | sed -n '1p'
}

# optee_capture_device_inventory <output-file> [tee-class-root] [dev-root]
# Captures public and private TEE devices with sysfs and parent-driver evidence.
# Optional roots support host fixtures and default to /sys/class/tee and /dev.
# Produces no stdout, exports TEE/public/native counts, returns 0 on success, 1
# on file failure, or 3 for invalid arguments, and creates or replaces the
# requested TSV without changing device state.
optee_capture_device_inventory() {
    ocdi_output_file="$1"
    ocdi_class_root="${2:-/sys/class/tee}"
    ocdi_dev_root="${3:-/dev}"

    [ -n "$ocdi_output_file" ] || return 3
    : >"$ocdi_output_file" || return 1

    OPTEE_TEE_DEVICE_COUNT=0
    OPTEE_PUBLIC_DEVICE_COUNT=0
    OPTEE_NATIVE_DEVICE_COUNT=0
    printf 'class\tkind\timplementation_id\trevision\tdevnode\tdevice_type\tdriver\tparent_path\tresolved_path\n' >"$ocdi_output_file"
    for ocdi_class_device in "$ocdi_class_root"/tee*; do
        [ -e "$ocdi_class_device" ] || continue
        ocdi_name=${ocdi_class_device##*/}
        ocdi_impl=$(cat "$ocdi_class_device/implementation_id" 2>/dev/null || true)
        ocdi_revision=$(cat "$ocdi_class_device/revision" 2>/dev/null || true)
        ocdi_devnode="$ocdi_dev_root/$ocdi_name"
        ocdi_resolved=$(readlink -f "$ocdi_class_device" 2>/dev/null || true)
        ocdi_parent=$(readlink -f "$ocdi_class_device/device" 2>/dev/null || true)
        ocdi_driver=""
        if [ -z "$ocdi_parent" ] && [ -n "$ocdi_resolved" ]; then
            ocdi_parent=$(dirname "$ocdi_resolved")
        fi
        ocdi_driver_probe="$ocdi_parent"
        while [ -n "$ocdi_driver_probe" ] &&
              [ "$ocdi_driver_probe" != "/" ] &&
              [ "$ocdi_driver_probe" != "/sys" ]; do
            if [ -L "$ocdi_driver_probe/driver" ]; then
                ocdi_driver=$(basename "$(readlink -f "$ocdi_driver_probe/driver" 2>/dev/null)" 2>/dev/null || true)
                ocdi_parent="$ocdi_driver_probe"
                break
            fi
            ocdi_driver_probe=$(dirname "$ocdi_driver_probe")
        done
        ocdi_impl="${ocdi_impl:-unreadable}"
        ocdi_revision="${ocdi_revision:-unreadable}"
        ocdi_driver="${ocdi_driver:-unreadable}"
        ocdi_parent="${ocdi_parent:-unresolved}"
        ocdi_resolved="${ocdi_resolved:-unresolved}"
        ocdi_kind="public"
        ocdi_type="missing"
        case "$ocdi_name" in
            teepriv*)
                ocdi_kind="private"
                ;;
        esac
        if [ -c "$ocdi_devnode" ]; then
            ocdi_type="character"
        elif [ -e "$ocdi_devnode" ]; then
            ocdi_type="non-character"
        fi
        OPTEE_TEE_DEVICE_COUNT=$((OPTEE_TEE_DEVICE_COUNT + 1))
        if [ "$ocdi_kind" = "public" ] && [ "$ocdi_type" = "character" ]; then
            OPTEE_PUBLIC_DEVICE_COUNT=$((OPTEE_PUBLIC_DEVICE_COUNT + 1))
        fi
        if [ "$ocdi_kind" = "public" ] &&
           [ "$ocdi_type" = "character" ]; then
            if [ "$ocdi_impl" = "1" ]; then
                OPTEE_NATIVE_DEVICE_COUNT=$((OPTEE_NATIVE_DEVICE_COUNT + 1))
            elif [ "$ocdi_impl" = "unreadable" ] &&
                 { [ "$ocdi_driver" = "optee" ] ||
                   printf '%s\n%s\n' "$ocdi_parent" "$ocdi_resolved" |
                       grep -Eiq '(^|[/:])optee([/:]|$)'; }; then
                OPTEE_NATIVE_DEVICE_COUNT=$((OPTEE_NATIVE_DEVICE_COUNT + 1))
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ocdi_name" \
            "$ocdi_kind" \
            "$ocdi_impl" \
            "$ocdi_revision" \
            "$ocdi_devnode" \
            "$ocdi_type" \
            "$ocdi_driver" \
            "$ocdi_parent" \
            "$ocdi_resolved" >>"$ocdi_output_file"
    done

    export OPTEE_TEE_DEVICE_COUNT OPTEE_PUBLIC_DEVICE_COUNT OPTEE_NATIVE_DEVICE_COUNT
}

# optee_log_device_inventory <output-file> [max-devices]
# Replays bounded TEE class inventory before applicability is classified.
# Inputs are a readable inventory and optional unsigned display bound. Produces
# diagnostic logs only, returns 0 on success, 1 for unreadable input, or 3 for
# an invalid bound, and does not modify the inventory.
optee_log_device_inventory() {
    oldi_output_file="$1"
    oldi_max_devices="${2:-16}"
    oldi_emitted=0

    [ -r "$oldi_output_file" ] || return 1
    case "$oldi_max_devices" in
        ''|*[!0-9]*)
            return 3
            ;;
    esac
    while IFS="$(printf '\t')" read -r oldi_class oldi_kind oldi_impl oldi_revision oldi_devnode oldi_type oldi_driver oldi_parent oldi_resolved; do
        [ "$oldi_class" = "class" ] && continue
        if [ "$oldi_emitted" -ge "$oldi_max_devices" ]; then
            break
        fi
        log_info "[OPTEE-DEVICE] class=$oldi_class kind=$oldi_kind implementation_id=$oldi_impl revision=$oldi_revision devnode=$oldi_devnode device_type=$oldi_type driver=$oldi_driver parent=$oldi_parent path=$oldi_resolved"
        oldi_emitted=$((oldi_emitted + 1))
    done <"$oldi_output_file"
    if [ "$OPTEE_TEE_DEVICE_COUNT" -gt "$oldi_emitted" ]; then
        log_info "[OPTEE-DEVICE] omitted=$((OPTEE_TEE_DEVICE_COUNT - oldi_emitted)) total=$OPTEE_TEE_DEVICE_COUNT artifact=$oldi_output_file"
    fi
    log_info "[OPTEE-DISCOVERY] tee_devices=$OPTEE_TEE_DEVICE_COUNT public_devices=$OPTEE_PUBLIC_DEVICE_COUNT native_candidates=$OPTEE_NATIVE_DEVICE_COUNT artifact=$oldi_output_file"
}

# optee_log_xtest_summary <log-file> <case-id>
# Replays bounded xtest result markers without dumping the complete case log.
# Inputs are a readable xtest log and case identifier. Produces diagnostic logs
# only, returns 0 on success or 1 for unreadable input, creates then removes a
# temporary summary beside the log, and leaves the complete log unchanged.
optee_log_xtest_summary() {
    olxs_log_file="$1"
    olxs_case_id="$2"
    olxs_summary_file="${olxs_log_file}.summary"

    [ -r "$olxs_log_file" ] || return 1
    grep -Ei 'test cases?|subtests?|passed|failed|skipped|aborted|result' \
        "$olxs_log_file" >"$olxs_summary_file" 2>/dev/null || true
    if [ -s "$olxs_summary_file" ]; then
        log_file_with_label "OPTEE-XTEST-$olxs_case_id" "$olxs_summary_file" 20
    else
        log_info "[OPTEE-XTEST-$olxs_case_id] summary_markers=none artifact=$olxs_log_file"
    fi
    rm -f "$olxs_summary_file"
}

# optee_xtest_case_is_allowed <case-id>
# Restricts automation to the reviewed, non-destructive native OP-TEE subset.
# The case identifier is required. Produces no stdout, returns 0 for an allowed
# identifier or 1 otherwise, and has no side effects.
optee_xtest_case_is_allowed() {
    oxcia_case_id="$1"

    for oxcia_allowed in $OPTEE_SAFE_XTEST_CASES; do
        if [ "$oxcia_case_id" = "$oxcia_allowed" ]; then
            return 0
        fi
    done

    return 1
}

# optee_validate_xtest_log <log-file>
# Returns 0 for an executed passing case, 2 for an xtest-reported skip, and 1
# for missing, failed, or aborted summary evidence.
# The path must contain retained xtest output. Produces no stdout and has no
# side effects.
optee_validate_xtest_log() {
    ovxl_log_file="$1"

    [ -s "$ovxl_log_file" ] || return 1

    if grep -Eq 'Test suite was ABORTED|[1-9][0-9]* (subtests?|test cases?) of which [1-9][0-9]* failed' \
        "$ovxl_log_file"; then
        return 1
    fi

    # A filtered xtest invocation reports every non-selected case in its final
    # "test cases skipped" count. That count does not mean the requested case
    # was skipped. The allowlisted cases emit an explicit skip marker when
    # their optional PTA or feature is unavailable, so use that marker instead.
    if grep -Eiq 'skip test|skipping' \
        "$ovxl_log_file"; then
        return 2
    fi

    if grep -Eq '1 test case of which 0 failed' "$ovxl_log_file"; then
        return 0
    fi

    return 1
}
