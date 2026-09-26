#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# dmabuf_heap_classify <heap-name>
# Prints the public heap class for one device name. Returns 0 only for Linux
# heap names whose buffers are documented as CPU-mappable, or 1 when an exact
# product policy is required. It has no side effects or diagnostic output.
dmabuf_heap_classify() {
    dmabuf_classify_name="$1"

    case "$dmabuf_classify_name" in
        system)
            printf '%s\n' "linux-system"
            return 0
            ;;
        system_cc_shared)
            printf '%s\n' "linux-system-cc-shared"
            return 0
            ;;
        default_cma_region)
            printf '%s\n' "linux-default-cma"
            return 0
            ;;
        reserved|linux,cma|default-pool)
            printf '%s\n' "linux-legacy-default-cma"
            return 0
            ;;
        *)
            printf '%s\n' "product-policy-required"
            return 1
            ;;
    esac
}

# dmabuf_heap_capture_inventory <device-root> <output-file>
# Inventories every entry below DEVICE_ROOT into a TSV with node type, access,
# public class, and automatic-selection status. It emits no stdout, returns 0
# on success or 1 on an artifact error, and does not modify device state.
dmabuf_heap_capture_inventory() {
    dmabuf_inventory_root="$1"
    dmabuf_inventory_output="$2"

    : >"$dmabuf_inventory_output" || return 1
    printf 'name\tpath\tcharacter\treadable\twritable\tclass\tauto_safe\n' \
        >"$dmabuf_inventory_output" || return 1

    for dmabuf_inventory_path in "$dmabuf_inventory_root"/*; do
        if [ ! -e "$dmabuf_inventory_path" ] &&
           [ ! -L "$dmabuf_inventory_path" ]; then
            continue
        fi

        dmabuf_inventory_name=${dmabuf_inventory_path##*/}
        dmabuf_inventory_character=0
        dmabuf_inventory_readable=0
        dmabuf_inventory_writable=0
        dmabuf_inventory_auto_safe=0
        [ -c "$dmabuf_inventory_path" ] && dmabuf_inventory_character=1
        [ -r "$dmabuf_inventory_path" ] && dmabuf_inventory_readable=1
        [ -w "$dmabuf_inventory_path" ] && dmabuf_inventory_writable=1

        if dmabuf_inventory_class=$(
            dmabuf_heap_classify "$dmabuf_inventory_name"
        ); then
            dmabuf_inventory_auto_safe=1
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$dmabuf_inventory_name" \
            "$dmabuf_inventory_path" \
            "$dmabuf_inventory_character" \
            "$dmabuf_inventory_readable" \
            "$dmabuf_inventory_writable" \
            "$dmabuf_inventory_class" \
            "$dmabuf_inventory_auto_safe" \
            >>"$dmabuf_inventory_output" || return 1
    done
}

# dmabuf_heap_select <inventory-file> <policy> <output-file>
# Selects automatic public CPU-mappable heaps or exact whitespace-separated
# heap names. It writes one unique name per line, exports
# DMABUF_SELECTION_REASON, returns 0 on success, 1 for an invalid or unavailable
# explicit heap, or 3 for invalid arguments, and emits no stdout.
dmabuf_heap_select() {
    dmabuf_select_inventory="$1"
    dmabuf_select_policy="$2"
    dmabuf_select_output="$3"
    dmabuf_select_requested="${dmabuf_select_output}.requested"
    dmabuf_select_unique="${dmabuf_select_output}.unique"

    DMABUF_SELECTION_REASON=""
    export DMABUF_SELECTION_REASON

    if [ ! -r "$dmabuf_select_inventory" ] ||
       [ -z "$dmabuf_select_output" ]; then
        DMABUF_SELECTION_REASON="invalid-selector-arguments"
        export DMABUF_SELECTION_REASON
        return 3
    fi

    : >"$dmabuf_select_output" || return 1
    rm -f "$dmabuf_select_requested" "$dmabuf_select_unique"

    case "$dmabuf_select_policy" in
        auto|'')
            awk -F '\t' \
                'NR > 1 && $3 == 1 && $7 == 1 { print $1 }' \
                "$dmabuf_select_inventory" \
                >"$dmabuf_select_output" || return 1
            DMABUF_SELECTION_REASON="public-cpu-mappable"
            ;;
        *)
            printf '%s\n' "$dmabuf_select_policy" |
                awk '
                    {
                        for (field_number = 1; field_number <= NF; field_number++)
                            print $field_number
                    }
                ' >"$dmabuf_select_requested" || return 1

            if [ ! -s "$dmabuf_select_requested" ]; then
                DMABUF_SELECTION_REASON="empty-explicit-policy"
                export DMABUF_SELECTION_REASON
                rm -f "$dmabuf_select_requested" "$dmabuf_select_unique"
                return 1
            fi

            dmabuf_select_rc=0
            while IFS= read -r dmabuf_select_name; do
                case "$dmabuf_select_name" in
                    ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,._+@-]*)
                        DMABUF_SELECTION_REASON="invalid-heap-name-$dmabuf_select_name"
                        dmabuf_select_rc=1
                        break
                        ;;
                esac

                if ! awk -F '\t' -v heap_name="$dmabuf_select_name" '
                    NR > 1 && $1 == heap_name && $3 == 1 {
                        found = 1
                    }
                    END {
                        exit !found
                    }
                ' "$dmabuf_select_inventory"; then
                    DMABUF_SELECTION_REASON="requested-heap-unavailable-$dmabuf_select_name"
                    dmabuf_select_rc=1
                    break
                fi
            done <"$dmabuf_select_requested"

            if [ "$dmabuf_select_rc" -ne 0 ]; then
                export DMABUF_SELECTION_REASON
                rm -f "$dmabuf_select_requested" "$dmabuf_select_unique"
                return 1
            fi

            awk '!seen[$0]++' "$dmabuf_select_requested" \
                >"$dmabuf_select_unique" || return 1
            mv "$dmabuf_select_unique" "$dmabuf_select_output" || return 1
            rm -f "$dmabuf_select_requested"
            DMABUF_SELECTION_REASON="explicit-product-policy"
            ;;
    esac

    export DMABUF_SELECTION_REASON
    return 0
}

# dmabuf_heap_find_python
# Prints the image-provided Python 3 command path, returns 0 when found or 1
# when unavailable, emits no diagnostics, and does not install dependencies.
dmabuf_heap_find_python() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi

    if command -v python >/dev/null 2>&1 &&
       python -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' \
            >/dev/null 2>&1; then
        command -v python
        return 0
    fi

    return 1
}
