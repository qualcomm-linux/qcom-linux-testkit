#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# bus_validation_require_commands <command>...
# Verifies image-provided commands without invoking package recovery.
bus_validation_require_commands() {
    birc_missing=""

    for birc_command in "$@"; do
        if ! command -v "$birc_command" >/dev/null 2>&1; then
            birc_missing="$birc_missing $birc_command"
        fi
    done

    if [ -n "$birc_missing" ]; then
        log_warn "Required image-provided commands are unavailable:$birc_missing"
        return 1
    fi

    return 0
}

# bus_validation_bool_true <value>
# Returns success only for explicit affirmative fixture opt-in values.
bus_validation_bool_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# bus_validation_ancestor_driver_name <sysfs-object>
# Prints the nearest bound ancestor driver for class devices such as TTYs.
bus_validation_ancestor_driver_name() {
    bidn_object="$1"
    [ -n "$bidn_object" ] || return 3

    bidn_current=$(readlink -f "$bidn_object" 2>/dev/null || true)
    [ -n "$bidn_current" ] || bidn_current="$bidn_object"

    while [ "$bidn_current" != "/" ] && [ -n "$bidn_current" ]; do
        if [ -L "$bidn_current/driver" ]; then
            bidn_driver=$(readlink -f "$bidn_current/driver" 2>/dev/null || true)
            if [ -n "$bidn_driver" ]; then
                bidn_driver_name=$(basename "$bidn_driver")
                case "$bidn_driver_name" in
                    port)
                        # serial-core exposes a wrapper on the TTY port.
                        # Continue upward to report the hardware controller.
                        ;;
                    *)
                        printf '%s\n' "$bidn_driver_name"
                        return 0
                        ;;
                esac
            fi
        fi
        bidn_parent=$(dirname "$bidn_current")
        [ "$bidn_parent" != "$bidn_current" ] || break
        bidn_current="$bidn_parent"
    done

    return 1
}

# bus_validation_bound_driver_name <sysfs-object>
# Prints only the driver bound directly to the resolved bus or platform device.
bus_validation_bound_driver_name() {
    bibdn_object="$1"
    [ -n "$bibdn_object" ] || return 3

    bibdn_resolved=$(readlink -f "$bibdn_object" 2>/dev/null || true)
    [ -n "$bibdn_resolved" ] || bibdn_resolved="$bibdn_object"
    [ -L "$bibdn_resolved/driver" ] || return 1
    bibdn_driver=$(readlink -f "$bibdn_resolved/driver" 2>/dev/null || true)
    [ -n "$bibdn_driver" ] || return 1
    basename "$bibdn_driver"
}

# bus_validation_of_node <sysfs-object>
# Prints the nearest resolved runtime device-tree node for a sysfs object.
bus_validation_of_node() {
    bion_object="$1"
    [ -n "$bion_object" ] || return 3

    bion_current=$(readlink -f "$bion_object" 2>/dev/null || true)
    [ -n "$bion_current" ] || bion_current="$bion_object"

    while [ "$bion_current" != "/" ] && [ -n "$bion_current" ]; do
        if [ -L "$bion_current/of_node" ]; then
            bion_node=$(readlink -f "$bion_current/of_node" 2>/dev/null || true)
            if [ -n "$bion_node" ]; then
                printf '%s\n' "$bion_node"
                return 0
            fi
        fi
        bion_parent=$(dirname "$bion_current")
        [ "$bion_parent" != "$bion_current" ] || break
        bion_current="$bion_parent"
    done

    return 1
}

# bus_validation_device_modalias <sysfs-object>
# Prints modalias evidence owned by the exact runtime device without requiring udev.
bus_validation_device_modalias() {
    bim_object="$1"
    [ -n "$bim_object" ] || return 3

    bim_resolved=$(readlink -f "$bim_object" 2>/dev/null || true)
    [ -n "$bim_resolved" ] || bim_resolved="$bim_object"
    if [ -r "$bim_resolved/modalias" ]; then
        tr -d '[:space:]' <"$bim_resolved/modalias"
        return 0
    fi
    if [ -r "$bim_resolved/uevent" ]; then
        bim_value=$(awk -F= '$1 == "MODALIAS" { print $2; exit }' "$bim_resolved/uevent")
        if [ -n "$bim_value" ]; then
            printf '%s\n' "$bim_value"
            return 0
        fi
    fi

    return 1
}

# bus_validation_module_candidates <modalias>
# Prints module aliases when modprobe metadata is available in the image.
bus_validation_module_candidates() {
    bimc_modalias="$1"
    [ -n "$bimc_modalias" ] || return 3
    command -v modprobe >/dev/null 2>&1 || return 2

    modprobe -R "$bimc_modalias" 2>/dev/null |
        awk 'NF && !seen[$0]++ { printf "%s%s", separator, $0; separator="," } END { if (separator != "") print "" }'
}

# bus_validation_module_origins <comma-separated-modules>
# Prints module:origin pairs, distinguishing built-in, loaded, and file-backed support.
bus_validation_module_origins() {
    bimo_modules="$1"
    [ -n "$bimo_modules" ] || return 3
    command -v modinfo >/dev/null 2>&1 || return 2

    bimo_output=""
    bimo_remaining_modules=$bimo_modules
    while [ -n "$bimo_remaining_modules" ]; do
        case "$bimo_remaining_modules" in
            *,*)
                bimo_module=${bimo_remaining_modules%%,*}
                bimo_remaining_modules=${bimo_remaining_modules#*,}
                ;;
            *)
                bimo_module=$bimo_remaining_modules
                bimo_remaining_modules=""
                ;;
        esac
        [ -n "$bimo_module" ] || continue
        bimo_origin=$(modinfo -F filename "$bimo_module" 2>/dev/null || true)
        if [ -z "$bimo_origin" ] && [ -d "/sys/module/$bimo_module" ]; then
            bimo_origin=loaded
        fi
        [ -n "$bimo_origin" ] || bimo_origin=unknown
        bimo_output="${bimo_output}${bimo_output:+,}$bimo_module:$bimo_origin"
    done

    [ -n "$bimo_output" ] || return 1
    printf '%s\n' "$bimo_output"
}

# bus_validation_capture_driver_names <driver-directory> <output-file>
# Retains registered driver names without following driver-directory contents.
bus_validation_capture_driver_names() {
    bicdn_directory="$1"
    bicdn_output="$2"
    [ -n "$bicdn_directory" ] && [ -n "$bicdn_output" ] || return 3

    : >"$bicdn_output"
    [ -d "$bicdn_directory" ] || return 1
    for bicdn_driver in "$bicdn_directory"/*; do
        [ -e "$bicdn_driver" ] || continue
        basename "$bicdn_driver"
    done | sort -u >"$bicdn_output"

    [ -s "$bicdn_output" ]
}

# bus_validation_waiting_for_supplier <sysfs-object>
# Prints the nearest waiting_for_supplier value, or unknown when not exposed.
bus_validation_waiting_for_supplier() {
    biwfs_object="$1"
    [ -n "$biwfs_object" ] || return 3

    biwfs_current=$(readlink -f "$biwfs_object" 2>/dev/null || true)
    [ -n "$biwfs_current" ] || biwfs_current="$biwfs_object"

    while [ "$biwfs_current" != "/" ] && [ -n "$biwfs_current" ]; do
        if [ -r "$biwfs_current/waiting_for_supplier" ]; then
            tr -d '[:space:]' <"$biwfs_current/waiting_for_supplier"
            return 0
        fi
        biwfs_parent=$(dirname "$biwfs_current")
        [ "$biwfs_parent" != "$biwfs_current" ] || break
        biwfs_current="$biwfs_parent"
    done

    printf '%s\n' unknown
    return 1
}

# bus_validation_find_runtime_by_of_node <dt-node> <sysfs-glob>...
# Prints the first runtime object whose nearest of_node matches the DT node.
bus_validation_find_runtime_by_of_node() {
    bifr_node="$1"
    shift
    [ -n "$bifr_node" ] || return 3

    bifr_target=$(readlink -f "$bifr_node" 2>/dev/null || true)
    [ -n "$bifr_target" ] || bifr_target="$bifr_node"

    for bifr_pattern in "$@"; do
        for bifr_object in $bifr_pattern; do
            [ -e "$bifr_object" ] || continue
            bifr_runtime_node=$(bus_validation_of_node "$bifr_object" 2>/dev/null || true)
            if [ "$bifr_runtime_node" = "$bifr_target" ]; then
                readlink -f "$bifr_object" 2>/dev/null || printf '%s\n' "$bifr_object"
                return 0
            fi
        done
    done

    return 1
}

# bus_validation_dt_nodes <dt-root> <name-regex> <output-file>
# Lists enabled DT nodes whose basename matches the supplied extended regex.
bus_validation_dt_nodes() {
    bidn_root="$1"
    bidn_regex="$2"
    bidn_output="$3"
    [ -d "$bidn_root" ] && [ -n "$bidn_regex" ] && [ -n "$bidn_output" ] || return 3

    : >"$bidn_output"
    find "$bidn_root" -type d 2>/dev/null |
        while IFS= read -r bidn_node; do
            bidn_name=$(basename "$bidn_node")
            printf '%s\n' "$bidn_name" | grep -Eq "$bidn_regex" || continue
            dt_node_enabled "$bidn_node" || continue
            printf '%s\n' "$bidn_node"
        done |
        sort -u >"$bidn_output"

    [ -s "$bidn_output" ]
}

# uart_validate_runtime <result-dir>
# Correlates enabled UART DT nodes with platform drivers, TTYs, and serdev consumers.
uart_validate_runtime() {
    ucri_result_dir="$1"
    [ -n "$ucri_result_dir" ] || return 3
    mkdir -p "$ucri_result_dir" || return 1

    ucri_evidence="$ucri_result_dir/uart_evidence.tsv"
    ucri_dt_nodes="$ucri_result_dir/uart_dt_nodes.log"
    ucri_ttys="$ucri_result_dir/uart_ttys.tsv"
    ucri_dt_root=$(dt_runtime_root 2>/dev/null || true)
    ucri_tty_root="${UART_SYS_CLASS_TTY_ROOT:-/sys/class/tty}"
    ucri_serial_roots="${UART_SYS_BUS_SERIAL_ROOTS:-/sys/bus/serial /sys/bus/serial-base}"
    ucri_registered_drivers="$ucri_result_dir/uart_registered_drivers.log"
    ucri_failures=0
    ucri_dt_count=0
    ucri_runtime_count=0

    printf 'kind\tobject\tdriver\tof_node\tconsumer\tdetails\n' >"$ucri_evidence"
    printf 'tty\tdriver\tof_node\tconsole\tdevice\n' >"$ucri_ttys"
    : >"$ucri_dt_nodes"
    : >"$ucri_registered_drivers"

    for ucri_serial_root in $ucri_serial_roots; do
        bus_validation_capture_driver_names "$ucri_serial_root/drivers" "$ucri_result_dir/.uart_drivers.tmp" || true
        if [ -s "$ucri_result_dir/.uart_drivers.tmp" ]; then
            cat "$ucri_result_dir/.uart_drivers.tmp" >>"$ucri_registered_drivers"
        fi
    done
    if sort -u "$ucri_registered_drivers" >"$ucri_result_dir/.uart_drivers.sorted"; then
        mv "$ucri_result_dir/.uart_drivers.sorted" "$ucri_registered_drivers"
    else
        rm -f "$ucri_result_dir/.uart_drivers.sorted"
    fi
    rm -f "$ucri_result_dir/.uart_drivers.tmp"

    if [ -d "$ucri_tty_root" ]; then
        for ucri_tty_path in "$ucri_tty_root"/*; do
            [ -e "$ucri_tty_path" ] || continue
            [ -e "$ucri_tty_path/device" ] || continue
            ucri_tty=$(basename "$ucri_tty_path")
            ucri_device=$(readlink -f "$ucri_tty_path/device" 2>/dev/null || true)
            case "$ucri_device" in
                /sys/devices/virtual/*)
                    continue
                    ;;
            esac
            ucri_driver=$(bus_validation_ancestor_driver_name "$ucri_tty_path/device" 2>/dev/null || true)
            [ -n "$ucri_driver" ] || continue
            ucri_devnode="${UART_DEV_ROOT:-/dev}/$ucri_tty"
            ucri_devnode_state=missing
            if [ -c "$ucri_devnode" ]; then
                ucri_devnode_state=character-device
            fi
            ucri_of_node=$(bus_validation_of_node "$ucri_tty_path/device" 2>/dev/null || true)
            ucri_console=no
            if [ -r /proc/consoles ] && awk -v tty="$ucri_tty" '$1 == tty { found=1 } END { exit !found }' /proc/consoles; then
                ucri_console=yes
            fi
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$ucri_tty" "$ucri_driver" "${ucri_of_node:-unknown}" "$ucri_console" "${ucri_device:-unknown}" >>"$ucri_ttys"
            log_info "[UART-TTY] tty=$ucri_tty driver=$ucri_driver devnode=$ucri_devnode_state console=$ucri_console of_node=${ucri_of_node:-unknown}"
            ucri_runtime_count=$((ucri_runtime_count + 1))
            if [ "$ucri_devnode_state" != "character-device" ]; then
                log_fail "[UART-FAIL] object=$ucri_tty expected=character-device observed=$ucri_devnode_state path=$ucri_devnode artifact=$ucri_evidence"
                ucri_failures=$((ucri_failures + 1))
            fi
        done
    fi

    if [ -n "$ucri_dt_root" ]; then
        bus_validation_dt_nodes "$ucri_dt_root" '^(serial|uart)@' "$ucri_dt_nodes" || true
    fi

    while IFS= read -r ucri_node; do
        [ -n "$ucri_node" ] || continue
        ucri_dt_count=$((ucri_dt_count + 1))
        ucri_compatible=$(dt_property_text "$ucri_node" compatible 2>/dev/null || printf '%s\n' unknown)
        ucri_device_dir=$(find_platform_device_for_dt_node "$ucri_node" 2>/dev/null || true)
        ucri_driver=""
        if [ -n "$ucri_device_dir" ]; then
            ucri_driver=$(platform_device_driver_name "$ucri_device_dir" 2>/dev/null || true)
        fi

        ucri_tty_names=$(awk -F '\t' -v node="$ucri_node" 'NR > 1 && $3 == node { printf "%s%s", separator, $1; separator="," } END { if (separator != "") print "" }' "$ucri_ttys")
        ucri_serdev_names=""
        ucri_serdev_bound=0
        for ucri_serial_root in $ucri_serial_roots; do
            if [ -d "$ucri_serial_root/devices" ]; then
                for ucri_serdev in "$ucri_serial_root"/devices/*; do
                    [ -e "$ucri_serdev" ] || continue
                    ucri_serdev_node=$(bus_validation_of_node "$ucri_serdev" 2>/dev/null || true)
                    case "$ucri_serdev_node" in
                        "$ucri_node"/*)
                            ucri_serdev_name=$(basename "$ucri_serdev")
                            ucri_serdev_driver=$(bus_validation_bound_driver_name "$ucri_serdev" 2>/dev/null || true)
                            ucri_serdev_names="${ucri_serdev_names}${ucri_serdev_names:+,}$ucri_serdev_name:${ucri_serdev_driver:-unbound}"
                            if [ -n "$ucri_serdev_driver" ]; then
                                ucri_serdev_bound=$((ucri_serdev_bound + 1))
                            fi
                            ;;
                    esac
                done
            fi
        done

        log_info "[UART-DT] node=$ucri_node compatible=$ucri_compatible device=${ucri_device_dir:-missing} driver=${ucri_driver:-unbound} ttys=${ucri_tty_names:-none} serdev=${ucri_serdev_names:-none}"
        printf 'controller\t%s\t%s\t%s\t%s\tcompatible=%s serdev=%s\n' \
            "$ucri_node" "${ucri_driver:-unbound}" "$ucri_node" \
            "${ucri_tty_names:-${ucri_serdev_names:-none}}" "$ucri_compatible" "${ucri_serdev_names:-none}" >>"$ucri_evidence"

        if [ -z "$ucri_device_dir" ]; then
            log_fail "[UART-FAIL] object=$ucri_node expected=runtime-platform-device observed=missing artifact=$ucri_evidence"
            ucri_failures=$((ucri_failures + 1))
        elif [ -z "$ucri_driver" ]; then
            ucri_waiting=$(bus_validation_waiting_for_supplier "$ucri_device_dir" 2>/dev/null || true)
            ucri_modalias=$(bus_validation_device_modalias "$ucri_device_dir" 2>/dev/null || true)
            ucri_candidates=$(bus_validation_module_candidates "$ucri_modalias" 2>/dev/null || true)
            ucri_origins=$(bus_validation_module_origins "$ucri_candidates" 2>/dev/null || true)
            log_fail "[UART-FAIL] object=$(basename "$ucri_device_dir") expected=bound-controller-driver observed=unbound waiting_for_supplier=${ucri_waiting:-unknown} modalias=${ucri_modalias:-unknown} candidates=${ucri_candidates:-unresolved} origins=${ucri_origins:-unknown} evidence=$ucri_evidence registered_drivers=$ucri_registered_drivers"
            ucri_failures=$((ucri_failures + 1))
        elif [ -z "$ucri_tty_names" ] && [ "$ucri_serdev_bound" -eq 0 ]; then
            log_fail "[UART-FAIL] object=$(basename "$ucri_device_dir") expected=TTY-or-bound-serdev-consumer observed=none driver=$ucri_driver artifact=$ucri_evidence"
            ucri_failures=$((ucri_failures + 1))
        fi
    done <"$ucri_dt_nodes"

    log_info "UART runtime summary: dt_controllers=$ucri_dt_count physical_ttys=$ucri_runtime_count failures=$ucri_failures artifact=$ucri_evidence"

    if [ "$ucri_dt_count" -eq 0 ] && [ "$ucri_runtime_count" -eq 0 ]; then
        return 2
    fi
    [ "$ucri_failures" -eq 0 ] || return 1
    return 0
}

# spi_validate_runtime <result-dir>
# Correlates enabled SPI controllers and children with masters, devices, and drivers.
spi_validate_runtime() {
    scri_result_dir="$1"
    [ -n "$scri_result_dir" ] || return 3
    mkdir -p "$scri_result_dir" || return 1

    scri_evidence="$scri_result_dir/spi_evidence.tsv"
    scri_dt_nodes="$scri_result_dir/spi_dt_controllers.log"
    scri_dt_root=$(dt_runtime_root 2>/dev/null || true)
    scri_master_root="${SPI_SYS_CLASS_MASTER_ROOT:-/sys/class/spi_master}"
    scri_bus_root="${SPI_SYS_BUS_ROOT:-/sys/bus/spi}"
    scri_failures=0
    scri_controller_count=0
    scri_master_count=0
    scri_device_count=0
    scri_registered_drivers="$scri_result_dir/spi_registered_drivers.log"

    printf 'kind\tobject\tdriver\tof_node\tmodalias\tfrequency_hex\tmode\terrors\ttimedout\truntime_pm\twaiting_for_supplier\n' >"$scri_evidence"
    : >"$scri_dt_nodes"
    bus_validation_capture_driver_names "$scri_bus_root/drivers" "$scri_registered_drivers" || true

    if [ -n "$scri_dt_root" ]; then
        bus_validation_dt_nodes "$scri_dt_root" '^(spi|qspi)@' "$scri_dt_nodes" || true
    fi

    if [ -d "$scri_master_root" ]; then
        for scri_master in "$scri_master_root"/spi*; do
            [ -e "$scri_master" ] || continue
            scri_master_name=$(basename "$scri_master")
            scri_driver=$(bus_validation_bound_driver_name "$scri_master/device" 2>/dev/null || true)
            scri_node=$(bus_validation_of_node "$scri_master/device" 2>/dev/null || true)
            scri_errors=$(cat "$scri_master/statistics/errors" 2>/dev/null || printf '%s\n' unavailable)
            scri_timeouts=$(cat "$scri_master/statistics/timedout" 2>/dev/null || printf '%s\n' unavailable)
            scri_runtime_pm=$(cat "$scri_master/device/power/runtime_status" 2>/dev/null || printf '%s\n' unavailable)
            log_info "[SPI-MASTER] master=$scri_master_name driver=${scri_driver:-unbound} runtime_pm=$scri_runtime_pm errors=$scri_errors timedout=$scri_timeouts of_node=${scri_node:-unknown}"
            printf 'master\t%s\t%s\t%s\t-\t-\t-\t%s\t%s\t%s\t-\n' \
                "$scri_master_name" "${scri_driver:-unbound}" "${scri_node:-unknown}" \
                "$scri_errors" "$scri_timeouts" "$scri_runtime_pm" >>"$scri_evidence"
            scri_master_count=$((scri_master_count + 1))
            if [ -z "$scri_driver" ]; then
                log_fail "[SPI-FAIL] object=$scri_master_name expected=bound-master-driver observed=unbound artifact=$scri_evidence"
                scri_failures=$((scri_failures + 1))
            fi
        done
    fi

    while IFS= read -r scri_controller; do
        [ -n "$scri_controller" ] || continue
        scri_controller_count=$((scri_controller_count + 1))
        scri_compatible=$(dt_property_text "$scri_controller" compatible 2>/dev/null || printf '%s\n' unknown)
        scri_master_match=$(bus_validation_find_runtime_by_of_node \
            "$scri_controller" "$scri_master_root/spi*" 2>/dev/null || true)
        log_info "[SPI-DT] controller=$scri_controller compatible=$scri_compatible master=${scri_master_match:-missing}"
        if [ -z "$scri_master_match" ]; then
            scri_platform=$(find_platform_device_for_dt_node "$scri_controller" 2>/dev/null || true)
            scri_platform_driver=""
            if [ -n "$scri_platform" ]; then
                scri_platform_driver=$(platform_device_driver_name "$scri_platform" 2>/dev/null || true)
            fi
            log_fail "[SPI-FAIL] object=$scri_controller expected=runtime-spi-master observed=missing platform_device=${scri_platform:-missing} driver=${scri_platform_driver:-unbound} artifact=$scri_evidence"
            scri_failures=$((scri_failures + 1))
        fi
    done <"$scri_dt_nodes"

    if [ -d "$scri_bus_root/devices" ]; then
        for scri_device in "$scri_bus_root"/devices/spi*.*; do
            [ -e "$scri_device" ] || continue
            scri_device_name=$(basename "$scri_device")
            scri_driver=$(bus_validation_bound_driver_name "$scri_device" 2>/dev/null || true)
            scri_node=$(bus_validation_of_node "$scri_device" 2>/dev/null || true)
            scri_modalias=$(bus_validation_device_modalias "$scri_device" 2>/dev/null || true)
            scri_frequency=unknown
            scri_mode=unknown
            if [ -n "$scri_node" ] && [ -r "$scri_node/spi-max-frequency" ]; then
                scri_frequency=$(dt_property_hex "$scri_node" spi-max-frequency 2>/dev/null || printf '%s\n' unknown)
            fi
            if [ -n "$scri_node" ]; then
                scri_mode=mode0
                [ -e "$scri_node/spi-cpol" ] && scri_mode="${scri_mode},cpol"
                [ -e "$scri_node/spi-cpha" ] && scri_mode="${scri_mode},cpha"
                [ -e "$scri_node/spi-cs-high" ] && scri_mode="${scri_mode},cs-high"
                [ -e "$scri_node/spi-lsb-first" ] && scri_mode="${scri_mode},lsb-first"
                [ -e "$scri_node/spi-3wire" ] && scri_mode="${scri_mode},3wire"
            fi
            scri_waiting=$(bus_validation_waiting_for_supplier "$scri_device" 2>/dev/null || true)
            scri_errors=$(cat "$scri_device/statistics/errors" 2>/dev/null || printf '%s\n' unavailable)
            scri_timeouts=$(cat "$scri_device/statistics/timedout" 2>/dev/null || printf '%s\n' unavailable)
            scri_runtime_pm=$(cat "$scri_device/power/runtime_status" 2>/dev/null || printf '%s\n' unavailable)
            log_info "[SPI-DEVICE] device=$scri_device_name driver=${scri_driver:-unbound} modalias=${scri_modalias:-unknown} max_frequency_hex=$scri_frequency mode=$scri_mode runtime_pm=$scri_runtime_pm errors=$scri_errors timedout=$scri_timeouts waiting_for_supplier=${scri_waiting:-unknown} of_node=${scri_node:-unknown}"
            printf 'device\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$scri_device_name" "${scri_driver:-unbound}" "${scri_node:-unknown}" \
                "${scri_modalias:-unknown}" "$scri_frequency" "$scri_mode" \
                "$scri_errors" "$scri_timeouts" "$scri_runtime_pm" \
                "${scri_waiting:-unknown}" >>"$scri_evidence"
            scri_device_count=$((scri_device_count + 1))

            if [ -z "$scri_driver" ]; then
                scri_candidates=$(bus_validation_module_candidates "$scri_modalias" 2>/dev/null || true)
                scri_origins=$(bus_validation_module_origins "$scri_candidates" 2>/dev/null || true)
                log_fail "[SPI-FAIL] object=$scri_device_name expected=bound-client-driver observed=unbound waiting_for_supplier=${scri_waiting:-unknown} modalias=${scri_modalias:-unknown} candidates=${scri_candidates:-unresolved} origins=${scri_origins:-unknown} evidence=$scri_evidence registered_drivers=$scri_registered_drivers"
                scri_failures=$((scri_failures + 1))
            fi
        done
    fi

    while IFS= read -r scri_controller; do
        [ -n "$scri_controller" ] || continue
        for scri_child in "$scri_controller"/*; do
            [ -d "$scri_child" ] || continue
            [ -r "$scri_child/reg" ] || continue
            dt_node_enabled "$scri_child" || continue
            scri_runtime_child=$(bus_validation_find_runtime_by_of_node \
                "$scri_child" "$scri_bus_root/devices/spi*.*" 2>/dev/null || true)
            if [ -z "$scri_runtime_child" ]; then
                scri_child_compatible=$(dt_property_text "$scri_child" compatible 2>/dev/null || printf '%s\n' unknown)
                log_fail "[SPI-FAIL] object=$scri_child expected=runtime-spi-device observed=missing compatible=$scri_child_compatible artifact=$scri_evidence"
                scri_failures=$((scri_failures + 1))
            fi
        done
    done <"$scri_dt_nodes"

    log_info "SPI runtime summary: dt_controllers=$scri_controller_count masters=$scri_master_count devices=$scri_device_count failures=$scri_failures artifact=$scri_evidence"

    if [ "$scri_controller_count" -eq 0 ] && [ "$scri_master_count" -eq 0 ]; then
        return 2
    fi
    [ "$scri_failures" -eq 0 ] || return 1
    return 0
}

# i3c_validate_runtime <result-dir>
# Validates Linux-visible I3C objects and otherwise records firmware-side evidence.
i3c_validate_runtime() {
    icri_result_dir="$1"
    [ -n "$icri_result_dir" ] || return 3
    mkdir -p "$icri_result_dir" || return 1

    icri_evidence="$icri_result_dir/i3c_evidence.tsv"
    icri_dt_nodes="$icri_result_dir/i3c_dt_nodes.log"
    icri_remoteprocs="$icri_result_dir/i3c_remoteproc_evidence.tsv"
    icri_dt_root=$(dt_runtime_root 2>/dev/null || true)
    icri_bus_root="${I3C_SYS_BUS_ROOT:-/sys/bus/i3c}"
    icri_class_root="${I3C_SYS_CLASS_ROOT:-/sys/class/i3c-master}"
    icri_failures=0
    icri_dt_count=0
    icri_runtime_count=0
    icri_master_count=0
    icri_device_count=0
    icri_registered_drivers="$icri_result_dir/i3c_registered_drivers.log"

    printf 'kind\tobject\tdriver\tof_node\tmodalias\twaiting_for_supplier\tdetails\n' >"$icri_evidence"
    printf 'remoteproc\tname\tstate\tfirmware\n' >"$icri_remoteprocs"
    : >"$icri_dt_nodes"
    bus_validation_capture_driver_names "$icri_bus_root/drivers" "$icri_registered_drivers" || true

    if [ -n "$icri_dt_root" ]; then
        bus_validation_dt_nodes "$icri_dt_root" '^i3c@' "$icri_dt_nodes" || true
    fi

    while IFS= read -r icri_node; do
        [ -n "$icri_node" ] || continue
        icri_dt_count=$((icri_dt_count + 1))
    done <"$icri_dt_nodes"

    if [ -d "$icri_bus_root/devices" ]; then
        for icri_object in "$icri_bus_root"/devices/*; do
            [ -e "$icri_object" ] || continue
            icri_name=$(basename "$icri_object")
            icri_node=$(bus_validation_of_node "$icri_object" 2>/dev/null || true)
            icri_resolved=$(readlink -f "$icri_object" 2>/dev/null || true)
            [ -n "$icri_resolved" ] || icri_resolved="$icri_object"
            if [ -r "$icri_resolved/current_master" ] || [ -r "$icri_resolved/i3c_scl_frequency" ]; then
                icri_parent=$(dirname "$icri_resolved")
                icri_driver=$(bus_validation_bound_driver_name "$icri_parent" 2>/dev/null || true)
                icri_mode=$(cat "$icri_resolved/mode" 2>/dev/null || printf '%s\n' unknown)
                icri_scl=$(cat "$icri_resolved/i3c_scl_frequency" 2>/dev/null || printf '%s\n' unknown)
                log_info "[I3C-MASTER] master=$icri_name controller_driver=${icri_driver:-unbound} mode=$icri_mode i3c_scl_hz=$icri_scl of_node=${icri_node:-unknown}"
                printf 'master\t%s\t%s\t%s\t-\t-\tmode=%s i3c_scl_hz=%s\n' \
                    "$icri_name" "${icri_driver:-unbound}" "${icri_node:-unknown}" \
                    "$icri_mode" "$icri_scl" >>"$icri_evidence"
                icri_master_count=$((icri_master_count + 1))
                icri_runtime_count=$((icri_runtime_count + 1))
                if [ -z "$icri_driver" ]; then
                    log_fail "[I3C-FAIL] object=$icri_name expected=bound-parent-controller-driver observed=unbound parent=$icri_parent evidence=$icri_evidence registered_drivers=$icri_registered_drivers"
                    icri_failures=$((icri_failures + 1))
                fi
                continue
            fi

            icri_driver=$(bus_validation_bound_driver_name "$icri_object" 2>/dev/null || true)
            icri_modalias=$(bus_validation_device_modalias "$icri_object" 2>/dev/null || true)
            icri_waiting=$(bus_validation_waiting_for_supplier "$icri_object" 2>/dev/null || true)
            icri_pid=$(cat "$icri_resolved/pid" 2>/dev/null || printf '%s\n' unknown)
            icri_dcr=$(cat "$icri_resolved/dcr" 2>/dev/null || printf '%s\n' unknown)
            icri_address=$(cat "$icri_resolved/dynamic_address" 2>/dev/null || printf '%s\n' unknown)
            log_info "[I3C-DEVICE] device=$icri_name driver=${icri_driver:-unbound} pid=$icri_pid dcr=$icri_dcr dynamic_address=$icri_address modalias=${icri_modalias:-unknown} waiting_for_supplier=${icri_waiting:-unknown} of_node=${icri_node:-unknown}"
            printf 'device\t%s\t%s\t%s\t%s\t%s\tpid=%s dcr=%s dynamic_address=%s\n' \
                "$icri_name" "${icri_driver:-unbound}" "${icri_node:-unknown}" \
                "${icri_modalias:-unknown}" "${icri_waiting:-unknown}" \
                "$icri_pid" "$icri_dcr" "$icri_address" >>"$icri_evidence"
            icri_device_count=$((icri_device_count + 1))
            icri_runtime_count=$((icri_runtime_count + 1))
            if [ -z "$icri_driver" ]; then
                icri_candidates=$(bus_validation_module_candidates "$icri_modalias" 2>/dev/null || true)
                icri_origins=$(bus_validation_module_origins "$icri_candidates" 2>/dev/null || true)
                log_fail "[I3C-FAIL] object=$icri_name expected=bound-runtime-driver observed=unbound waiting_for_supplier=${icri_waiting:-unknown} candidates=${icri_candidates:-unresolved} origins=${icri_origins:-unknown} evidence=$icri_evidence registered_drivers=$icri_registered_drivers"
                icri_failures=$((icri_failures + 1))
            fi
        done
    fi

    if [ -d "$icri_class_root" ]; then
        for icri_master in "$icri_class_root"/*; do
            [ -e "$icri_master" ] || continue
            icri_master_name=$(basename "$icri_master")
            log_info "[I3C-MASTER] master=$icri_master_name path=$(readlink -f "$icri_master" 2>/dev/null || printf '%s' "$icri_master")"
        done
    fi

    for icri_remoteproc in /sys/class/remoteproc/remoteproc*; do
        [ -d "$icri_remoteproc" ] || continue
        icri_rp_name=$(cat "$icri_remoteproc/name" 2>/dev/null || printf '%s\n' unknown)
        printf '%s\n' "$icri_rp_name" | grep -Eqi 'adsp|slpi|ssc|sensor' || continue
        icri_rp_state=$(cat "$icri_remoteproc/state" 2>/dev/null || printf '%s\n' unknown)
        icri_rp_firmware=$(cat "$icri_remoteproc/firmware" 2>/dev/null || printf '%s\n' unknown)
        printf '%s\t%s\t%s\t%s\n' \
            "$(basename "$icri_remoteproc")" "$icri_rp_name" "$icri_rp_state" "$icri_rp_firmware" >>"$icri_remoteprocs"
        log_info "[I3C-INDIRECT] remoteproc=$(basename "$icri_remoteproc") name=$icri_rp_name state=$icri_rp_state firmware=$icri_rp_firmware"
    done

    if [ "$icri_dt_count" -gt 0 ] && [ "$icri_master_count" -eq 0 ]; then
        log_fail "[I3C-FAIL] object=runtime-i3c expected=Linux-runtime-master observed=none dt_nodes=$icri_dt_count artifact=$icri_evidence"
        icri_failures=$((icri_failures + 1))
    fi

    log_info "I3C runtime summary: dt_controllers=$icri_dt_count masters=$icri_master_count devices=$icri_device_count failures=$icri_failures artifact=$icri_evidence indirect_evidence=$icri_remoteprocs"

    [ "$icri_failures" -eq 0 ] || return 1
    if [ "$icri_dt_count" -eq 0 ] && [ "$icri_runtime_count" -eq 0 ]; then
        return 2
    fi
    return 0
}

# can_validate_runtime <result-dir>
# Correlates CAN DT declarations with SocketCAN interfaces and parent drivers.
can_validate_runtime() {
    ccri_result_dir="$1"
    [ -n "$ccri_result_dir" ] || return 3
    mkdir -p "$ccri_result_dir" || return 1

    ccri_evidence="$ccri_result_dir/can_evidence.tsv"
    ccri_dt_nodes="$ccri_result_dir/can_dt_nodes.log"
    ccri_ip_log="$ccri_result_dir/can_ip_details.log"
    ccri_dt_root=$(dt_runtime_root 2>/dev/null || true)
    ccri_net_root="${CAN_SYS_CLASS_NET_ROOT:-/sys/class/net}"
    ccri_spi_root="${SPI_SYS_BUS_ROOT:-/sys/bus/spi}"
    ccri_platform_root="${PLATFORM_SYS_BUS_ROOT:-/sys/bus/platform}"
    ccri_failures=0
    ccri_dt_count=0
    ccri_interface_count=0
    ccri_registered_drivers="$ccri_result_dir/can_parent_registered_drivers.log"

    printf 'kind\tobject\tdriver\tparent\tof_node\toperstate\tcan_state\tbitrate\tdbitrate\tctrlmode\tberr_tx\tberr_rx\trx_errors\ttx_errors\n' >"$ccri_evidence"
    : >"$ccri_dt_nodes"
    : >"$ccri_ip_log"
    bus_validation_capture_driver_names "$ccri_spi_root/drivers" "$ccri_result_dir/.can_spi_drivers.tmp" || true
    bus_validation_capture_driver_names "$ccri_platform_root/drivers" "$ccri_result_dir/.can_platform_drivers.tmp" || true
    cat "$ccri_result_dir/.can_spi_drivers.tmp" "$ccri_result_dir/.can_platform_drivers.tmp" 2>/dev/null |
        sort -u >"$ccri_registered_drivers"
    rm -f "$ccri_result_dir/.can_spi_drivers.tmp" "$ccri_result_dir/.can_platform_drivers.tmp"

    if [ -n "$ccri_dt_root" ]; then
        bus_validation_dt_nodes "$ccri_dt_root" '^can(@|$)' "$ccri_dt_nodes" || true
    fi

    if [ -d "$ccri_net_root" ]; then
        for ccri_iface_path in "$ccri_net_root"/*; do
            [ -e "$ccri_iface_path/type" ] || continue
            ccri_type=$(tr -d '[:space:]' <"$ccri_iface_path/type")
            [ "$ccri_type" = "280" ] || continue
            ccri_iface=$(basename "$ccri_iface_path")
            if [ ! -e "$ccri_iface_path/device" ]; then
                log_info "[CAN-IFACE] interface=$ccri_iface kind=virtual-or-software-only action=ignored"
                continue
            fi
            ccri_driver=$(bus_validation_bound_driver_name "$ccri_iface_path/device" 2>/dev/null || true)
            ccri_parent=$(readlink -f "$ccri_iface_path/device" 2>/dev/null || true)
            ccri_node=$(bus_validation_of_node "$ccri_iface_path/device" 2>/dev/null || true)
            ccri_state=$(cat "$ccri_iface_path/operstate" 2>/dev/null || printf '%s\n' unknown)
            ccri_rx_errors=$(cat "$ccri_iface_path/statistics/rx_errors" 2>/dev/null || printf '%s\n' unknown)
            ccri_tx_errors=$(cat "$ccri_iface_path/statistics/tx_errors" 2>/dev/null || printf '%s\n' unknown)
            ccri_can_state=unknown
            ccri_bitrate=unknown
            ccri_dbitrate=not-configured
            ccri_ctrlmode=unknown
            ccri_berr_tx=unknown
            ccri_berr_rx=unknown
            if command -v ip >/dev/null 2>&1; then
                ccri_ip_tmp="$ccri_result_dir/.can_ip_$ccri_iface.log"
                if ip -details -statistics link show dev "$ccri_iface" >"$ccri_ip_tmp" 2>&1; then
                    printf '===== %s =====\n' "$ccri_iface" >>"$ccri_ip_log"
                    cat "$ccri_ip_tmp" >>"$ccri_ip_log"
                    ccri_can_state=$(awk '/can (<[^>]*> )?state / { for (i = 1; i <= NF; i++) if ($i == "state") { print $(i + 1); exit } }' "$ccri_ip_tmp")
                    ccri_bitrate=$(awk '/bitrate[[:space:]]+[0-9]+/ { for (i = 1; i <= NF; i++) if ($i == "bitrate") { print $(i + 1); exit } }' "$ccri_ip_tmp")
                    ccri_dbitrate=$(awk '/dbitrate[[:space:]]+[0-9]+/ { for (i = 1; i <= NF; i++) if ($i == "dbitrate") { print $(i + 1); exit } }' "$ccri_ip_tmp")
                    ccri_ctrlmode=$(awk '
                        match($0, /can <[^>]*>/) {
                            value = substr($0, RSTART + 5, RLENGTH - 6)
                            print value
                            exit
                        }
                    ' "$ccri_ip_tmp")
                    ccri_berr_tx=$(awk '/berr-counter/ { for (i = 1; i <= NF; i++) if ($i == "tx") { print $(i + 1); exit } }' "$ccri_ip_tmp" | tr -d ')')
                    ccri_berr_rx=$(awk '/berr-counter/ { for (i = 1; i <= NF; i++) if ($i == "rx") { print $(i + 1); exit } }' "$ccri_ip_tmp" | tr -d ')')
                    [ -n "$ccri_can_state" ] || ccri_can_state=unknown
                    [ -n "$ccri_bitrate" ] || ccri_bitrate=not-configured
                    [ -n "$ccri_dbitrate" ] || ccri_dbitrate=not-configured
                    [ -n "$ccri_ctrlmode" ] || ccri_ctrlmode=none-reported
                    [ -n "$ccri_berr_tx" ] || ccri_berr_tx=unknown
                    [ -n "$ccri_berr_rx" ] || ccri_berr_rx=unknown
                else
                    log_warn "[CAN-IFACE] interface=$ccri_iface diagnostic=ip-details-query-failed artifact=$ccri_ip_tmp"
                fi
                rm -f "$ccri_ip_tmp"
            fi
            log_info "[CAN-IFACE] interface=$ccri_iface driver=${ccri_driver:-unbound} operstate=$ccri_state can_state=$ccri_can_state bitrate=$ccri_bitrate dbitrate=$ccri_dbitrate ctrlmode=$ccri_ctrlmode berr_tx=$ccri_berr_tx berr_rx=$ccri_berr_rx rx_errors=$ccri_rx_errors tx_errors=$ccri_tx_errors parent=${ccri_parent:-unknown} of_node=${ccri_node:-unknown}"
            printf 'interface\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$ccri_iface" "${ccri_driver:-unbound}" "${ccri_parent:-unknown}" \
                "${ccri_node:-unknown}" "$ccri_state" "$ccri_can_state" "$ccri_bitrate" \
                "$ccri_dbitrate" "$ccri_ctrlmode" "$ccri_berr_tx" "$ccri_berr_rx" \
                "$ccri_rx_errors" "$ccri_tx_errors" >>"$ccri_evidence"
            ccri_interface_count=$((ccri_interface_count + 1))
            if [ -z "$ccri_driver" ]; then
                log_fail "[CAN-FAIL] object=$ccri_iface expected=bound-CAN-driver observed=unbound parent=${ccri_parent:-unknown} artifact=$ccri_evidence"
                ccri_failures=$((ccri_failures + 1))
            fi
            case "$ccri_can_state" in
                BUS-OFF|ERROR-PASSIVE|ERROR-WARNING)
                    log_fail "[CAN-FAIL] object=$ccri_iface expected=healthy-CAN-state observed=$ccri_can_state berr_tx=$ccri_berr_tx berr_rx=$ccri_berr_rx artifact=$ccri_ip_log"
                    ccri_failures=$((ccri_failures + 1))
                    ;;
            esac
        done
    fi

    while IFS= read -r ccri_node; do
        [ -n "$ccri_node" ] || continue
        ccri_dt_count=$((ccri_dt_count + 1))
        ccri_compatible=$(dt_property_text "$ccri_node" compatible 2>/dev/null || printf '%s\n' unknown)
        ccri_runtime=$(bus_validation_find_runtime_by_of_node \
            "$ccri_node" "$ccri_spi_root/devices/*" "$ccri_platform_root/devices/*" 2>/dev/null || true)
        ccri_driver=""
        ccri_netdevs=""
        if [ -n "$ccri_runtime" ]; then
            ccri_driver=$(bus_validation_bound_driver_name "$ccri_runtime" 2>/dev/null || true)
            if [ -d "$ccri_runtime/net" ]; then
                for ccri_netdev in "$ccri_runtime"/net/*; do
                    [ -e "$ccri_netdev" ] || continue
                    ccri_netdevs="${ccri_netdevs}${ccri_netdevs:+,}$(basename "$ccri_netdev")"
                done
            fi
        fi
        log_info "[CAN-DT] node=$ccri_node compatible=$ccri_compatible runtime=${ccri_runtime:-missing} driver=${ccri_driver:-unbound} interfaces=${ccri_netdevs:-none}"
        printf 'declaration\t%s\t%s\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t-\t-\n' \
            "$ccri_node" "${ccri_driver:-unbound}" "${ccri_runtime:-missing}" \
            "$ccri_node" "interfaces=${ccri_netdevs:-none}" >>"$ccri_evidence"

        if [ -z "$ccri_runtime" ]; then
            log_fail "[CAN-FAIL] object=$ccri_node expected=runtime-CAN-device observed=missing compatible=$ccri_compatible artifact=$ccri_evidence"
            ccri_failures=$((ccri_failures + 1))
        elif [ -z "$ccri_driver" ]; then
            ccri_waiting=$(bus_validation_waiting_for_supplier "$ccri_runtime" 2>/dev/null || true)
            ccri_modalias=$(bus_validation_device_modalias "$ccri_runtime" 2>/dev/null || true)
            ccri_candidates=$(bus_validation_module_candidates "$ccri_modalias" 2>/dev/null || true)
            ccri_origins=$(bus_validation_module_origins "$ccri_candidates" 2>/dev/null || true)
            log_fail "[CAN-FAIL] object=$(basename "$ccri_runtime") expected=bound-CAN-driver observed=unbound waiting_for_supplier=${ccri_waiting:-unknown} modalias=${ccri_modalias:-unknown} candidates=${ccri_candidates:-unresolved} origins=${ccri_origins:-unknown} evidence=$ccri_evidence registered_drivers=$ccri_registered_drivers"
            ccri_failures=$((ccri_failures + 1))
        elif [ -z "$ccri_netdevs" ]; then
            log_fail "[CAN-FAIL] object=$(basename "$ccri_runtime") expected=SocketCAN-interface observed=none driver=$ccri_driver artifact=$ccri_evidence"
            ccri_failures=$((ccri_failures + 1))
        fi
    done <"$ccri_dt_nodes"

    log_info "CAN runtime summary: dt_devices=$ccri_dt_count interfaces=$ccri_interface_count failures=$ccri_failures artifact=$ccri_evidence ip_details=$ccri_ip_log"

    if [ "$ccri_dt_count" -eq 0 ] && [ "$ccri_interface_count" -eq 0 ]; then
        return 2
    fi
    [ "$ccri_failures" -eq 0 ] || return 1
    return 0
}

# bus_validation_suite_run <uart|spi|i3c|can> <test-name> <result-file> <script-dir>
# Runs the common read-only evidence, result, artifact, and kernel-health flow.
bus_validation_suite_run() {
    bisr_bus="$1"
    bisr_test_name="$2"
    bisr_result_file="$3"
    bisr_script_dir="$4"
    [ -n "$bisr_bus" ] && [ -n "$bisr_test_name" ] && [ -n "$bisr_result_file" ] && [ -n "$bisr_script_dir" ] || return 3

    bisr_result_dir="$bisr_script_dir/.${bisr_test_name}.work.$$"

    case "$bisr_bus" in
        uart)
            bisr_intent="correlating enabled DT controllers, platform drivers, TTY devices, consoles, and serdev consumers"
            bisr_success="UART controllers and runtime consumers are functionally ready"
            bisr_failure="UART validation found missing or unbound declared capabilities"
            bisr_absent="no enabled or runtime-visible UART capability is present"
            bisr_dmesg_regex='qcom_geni_serial|msm_serial|serial|tty'
            bisr_dmesg_label="UART"
            ;;
        spi)
            bisr_intent="correlating enabled DT controllers and children with runtime masters, devices, modaliases, and bound drivers"
            bisr_success="SPI controllers, masters, and client drivers are functionally ready"
            bisr_failure="SPI validation found missing or unbound declared capabilities"
            bisr_absent="no enabled or runtime-visible SPI capability is present"
            bisr_dmesg_regex='spi_geni_qcom|spi_qup|spi'
            bisr_dmesg_label="SPI"
            ;;
        i3c)
            bisr_intent="checking direct Linux runtime evidence and recording ADSP, SLPI, or SSC remoteproc state only as indirect evidence"
            bisr_success="Linux-visible I3C runtime objects are bound and internally consistent"
            bisr_failure="Declared or runtime-visible I3C capability is malformed or unbound"
            bisr_absent="no direct Linux I3C interface is exposed, firmware-side remoteproc evidence cannot prove the physical I3C transport"
            bisr_dmesg_regex='i3c|qup|ssc|slpi'
            bisr_dmesg_label="I3C or QUP"
            ;;
        can)
            bisr_intent="correlating enabled CAN DT devices with parent drivers, SocketCAN interfaces, state, and error counters"
            bisr_success="CAN controllers and SocketCAN interfaces are functionally ready"
            bisr_failure="CAN validation found missing drivers or SocketCAN interfaces"
            bisr_absent="no enabled or runtime-visible physical CAN capability is present"
            bisr_dmesg_regex='mcp251|can|spi'
            bisr_dmesg_label="CAN or parent-SPI"
            ;;
        *)
            log_error "Unsupported bus evidence type: $bisr_bus"
            return 3
            ;;
    esac

    test_result_init "$bisr_test_name" "$bisr_result_file" || return 1
    if ! mkdir -p "$bisr_result_dir"; then
        test_result_finish "FAIL" "$bisr_test_name FAIL: cannot create temporary evidence directory"
    fi
    trap 'rm -rf "$bisr_result_dir"' EXIT HUP INT TERM

    log_info "--------------------------------------------------------------------------"
    log_info "Starting $bisr_test_name"
    log_info "${bisr_dmesg_label} validation: $bisr_intent"

    if ! bus_validation_require_commands awk basename cat dirname find grep mkdir mv od readlink rm sort tr; then
        test_result_finish "SKIP" "$bisr_test_name SKIP: required image-provided base utilities are unavailable"
    fi

    case "$bisr_bus" in
        uart)
            uart_validate_runtime "$bisr_result_dir"
            ;;
        spi)
            spi_validate_runtime "$bisr_result_dir"
            ;;
        i3c)
            i3c_validate_runtime "$bisr_result_dir"
            ;;
        can)
            can_validate_runtime "$bisr_result_dir"
            ;;
    esac
    bisr_evidence_status=$?

    case "$bisr_evidence_status" in
        0)
            test_result_record "PASS" "$bisr_success"
            ;;
        1)
            test_result_record "FAIL" "$bisr_failure, detailed per-object diagnostics were emitted in the live log"
            ;;
        2)
            test_result_finish "SKIP" "$bisr_test_name SKIP: $bisr_absent"
            ;;
        *)
            test_result_record "FAIL" "$bisr_dmesg_label validation helper returned unexpected status $bisr_evidence_status"
            ;;
    esac

    if command -v dmesg >/dev/null 2>&1; then
        scan_dmesg_errors \
            "$bisr_result_dir" \
            "$bisr_dmesg_regex" \
            'dummy regulator|supply [^ ]+ not found|using dummy regulator' || true
        if [ -s "$bisr_result_dir/dmesg_errors.log" ]; then
            test_result_record "FAIL" "$bisr_dmesg_label kernel errors were captured, detailed diagnostics were emitted in the live log"
        elif [ -s "$bisr_result_dir/dmesg_snapshot.log" ]; then
            test_result_record "PASS" "No persistent $bisr_dmesg_label kernel errors were found"
        else
            test_result_record "SKIP" "Kernel log access is unavailable for $bisr_dmesg_label health validation"
        fi
    else
        test_result_record "SKIP" "The image does not provide dmesg for $bisr_dmesg_label health validation"
    fi

    test_result_finish
}

# uart_device_is_console <tty-name>
# Returns success when the TTY is an active or boot-configured kernel console.
uart_device_is_console() {
    udic_tty="$1"
    [ -n "$udic_tty" ] || return 3

    if [ -r /proc/consoles ] &&
       awk -v tty="$udic_tty" '$1 == tty { found=1 } END { exit !found }' /proc/consoles; then
        return 0
    fi
    if [ -r /proc/cmdline ] &&
       grep -Eq "(^|[[:space:]])console=${udic_tty}([,[:space:]]|$)" /proc/cmdline; then
        return 0
    fi

    return 1
}

# uart_loopback_device_use_reason <device>
# Prints the first current-process or userspace FD owner that makes a TTY unsafe.
uart_loopback_device_use_reason() {
    uldur_device="$1"
    uldur_target=$(readlink -f "$uldur_device" 2>/dev/null || true)
    [ -n "$uldur_target" ] || return 2

    for uldur_fd in 0 1 2; do
        uldur_fd_target=$(readlink -f "/proc/self/fd/$uldur_fd" 2>/dev/null || true)
        if [ "$uldur_fd_target" = "$uldur_target" ]; then
            printf 'test-process-fd-%s\n' "$uldur_fd"
            return 0
        fi
    done

    for uldur_process in /proc/[0-9]*; do
        [ -d "$uldur_process/fd" ] || continue
        uldur_pid=${uldur_process#/proc/}
        [ "$uldur_pid" = "$$" ] && continue
        for uldur_fd_path in "$uldur_process/fd"/*; do
            [ -e "$uldur_fd_path" ] || continue
            uldur_fd_target=$(readlink -f "$uldur_fd_path" 2>/dev/null || true)
            [ "$uldur_fd_target" = "$uldur_target" ] || continue
            uldur_fd_number=${uldur_fd_path##*/}
            uldur_comm=$(cat "$uldur_process/comm" 2>/dev/null || printf '%s' unknown)
            printf 'process-pid-%s-comm-%s-fd-%s\n' \
                "$uldur_pid" "$uldur_comm" "$uldur_fd_number"
            return 0
        done
    done

    return 1
}

# uart_loopback_select_device
# Prints the first runtime-discovered physical, accessible, non-console TTY.
uart_loopback_select_device() {
    ulsd_tty_root="${UART_SYS_CLASS_TTY_ROOT:-/sys/class/tty}"
    ulsd_dev_root="${UART_DEV_ROOT:-/dev}"
    ulsd_candidate=""
    ulsd_count=0

    [ -d "$ulsd_tty_root" ] || return 2
    for ulsd_tty_path in "$ulsd_tty_root"/*; do
        [ -e "$ulsd_tty_path/device" ] || continue
        ulsd_tty=$(basename "$ulsd_tty_path")
        ulsd_device=$(readlink -f "$ulsd_tty_path/device" 2>/dev/null || true)
        case "$ulsd_device" in
            /sys/devices/virtual/*)
                continue
                ;;
        esac
        ulsd_of_node=$(bus_validation_of_node "$ulsd_tty_path/device" 2>/dev/null || true)
        [ -n "$ulsd_of_node" ] || continue
        ulsd_devnode="$ulsd_dev_root/$ulsd_tty"
        [ -c "$ulsd_devnode" ] || continue
        if [ ! -r "$ulsd_devnode" ] || [ ! -w "$ulsd_devnode" ]; then
            continue
        fi
        uart_device_is_console "$ulsd_tty" && continue
        ulsd_candidate="$ulsd_devnode"
        ulsd_count=$((ulsd_count + 1))
    done

    [ "$ulsd_count" -eq 0 ] && return 2
    [ "$ulsd_count" -eq 1 ] || return 1
    printf '%s\n' "$ulsd_candidate"
    return 0
}

# uart_loopback_select_bauds <device>
# Prints the conservative portable baud default for a selected runtime UART.
uart_loopback_select_bauds() {
    ulsb_device="$1"
    [ -n "$ulsb_device" ] || return 3

    printf '%s\n' '115200'
}

UART_LOOPBACK_DEVICE=""
UART_LOOPBACK_STATE=""
UART_LOOPBACK_READER_PID=""
UART_LOOPBACK_WATCHER_PID=""

# uart_loopback_cleanup
# Stops an active reader and restores the exact saved termios state.
uart_loopback_cleanup() {
    ulc_status=0

    if [ -n "$UART_LOOPBACK_READER_PID" ]; then
        kill "$UART_LOOPBACK_READER_PID" 2>/dev/null || true
        wait "$UART_LOOPBACK_READER_PID" 2>/dev/null || true
        UART_LOOPBACK_READER_PID=""
    fi
    if [ -n "$UART_LOOPBACK_WATCHER_PID" ]; then
        kill "$UART_LOOPBACK_WATCHER_PID" 2>/dev/null || true
        wait "$UART_LOOPBACK_WATCHER_PID" 2>/dev/null || true
        UART_LOOPBACK_WATCHER_PID=""
    fi

    if [ -n "$UART_LOOPBACK_DEVICE" ] && [ -n "$UART_LOOPBACK_STATE" ]; then
        if ! stty -F "$UART_LOOPBACK_DEVICE" "$UART_LOOPBACK_STATE" 2>/dev/null; then
            log_fail "[UART-RESTORE] device=$UART_LOOPBACK_DEVICE expected=saved-termios-state observed=restore-failed"
            ulc_status=1
        else
            log_info "[UART-RESTORE] device=$UART_LOOPBACK_DEVICE state=restored"
        fi
    fi

    UART_LOOPBACK_DEVICE=""
    UART_LOOPBACK_STATE=""
    return "$ulc_status"
}

# uart_loopback_validate <device> <baud> <timeout-seconds> <result-dir> [payload-bytes]
# Runs exact-payload external loopback on an explicitly selected non-console TTY.
uart_loopback_validate() {
    ulv_device="$1"
    ulv_baud="$2"
    ulv_timeout="$3"
    ulv_result_dir="$4"
    ulv_payload_bytes="${5:-4096}"
    [ -n "$ulv_device" ] && [ -n "$ulv_baud" ] && [ -n "$ulv_timeout" ] && [ -n "$ulv_result_dir" ] || return 3

    case "$ulv_baud:$ulv_timeout:$ulv_payload_bytes" in
        *[!0-9:]*|:*|*:)
            return 3
            ;;
    esac

    mkdir -p "$ulv_result_dir" || return 1
    ulv_log="$ulv_result_dir/uart_loopback_${ulv_baud}.log"
    ulv_tx="$ulv_result_dir/uart_loopback_${ulv_baud}_tx.bin"
    ulv_rx="$ulv_result_dir/uart_loopback_${ulv_baud}_rx.bin"
    ulv_tty=$(basename "$ulv_device")
    : >"$ulv_log"
    rm -f "$ulv_tx" "$ulv_rx"

    if [ ! -c "$ulv_device" ]; then
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=character-device observed=missing-or-wrong-type artifact=$ulv_log"
        return 1
    fi
    if [ ! -r "$ulv_device" ] || [ ! -w "$ulv_device" ]; then
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=read-write-access observed=permission-denied artifact=$ulv_log"
        return 1
    fi
    if uart_device_is_console "$ulv_tty"; then
        log_info "[UART-LOOPBACK] device=$ulv_device state=not-runnable reason=kernel-console action=refused artifact=$ulv_log"
        return 2
    fi
    ulv_use_reason=$(uart_loopback_device_use_reason "$ulv_device" 2>/dev/null || true)
    if [ -n "$ulv_use_reason" ]; then
        log_info "[UART-LOOPBACK] device=$ulv_device state=not-runnable reason=active-terminal-or-userspace-owner owner=$ulv_use_reason action=refused artifact=$ulv_log"
        return 2
    fi

    UART_LOOPBACK_DEVICE="$ulv_device"
    UART_LOOPBACK_STATE=$(stty -F "$ulv_device" -g 2>/dev/null || true)
    if [ -z "$UART_LOOPBACK_STATE" ]; then
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=readable-termios-state observed=unavailable artifact=$ulv_log"
        UART_LOOPBACK_DEVICE=""
        return 1
    fi

    if ! stty -F "$ulv_device" "$ulv_baud" raw -echo cs8 -cstopb -parenb -ixon -ixoff -crtscts 2>>"$ulv_log"; then
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=baud-$ulv_baud-configuration observed=stty-failed artifact=$ulv_log"
        uart_loopback_cleanup || true
        return 1
    fi

    if ! awk -v bytes="$ulv_payload_bytes" '
        BEGIN {
            pattern = "QLI_UART_"
            for (i = 0; i < bytes; i++) {
                printf "%s", substr(pattern, (i % length(pattern)) + 1, 1)
            }
        }
    ' >"$ulv_tx"; then
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=generated-$ulv_payload_bytes-byte-payload observed=generation-failed artifact=$ulv_log"
        uart_loopback_cleanup || true
        return 1
    fi
    ulv_length=$(wc -c <"$ulv_tx" | tr -d '[:space:]')
    printf 'device=%s\nbaud=%s\ntimeout=%s\npayload_bytes=%s\n' \
        "$ulv_device" "$ulv_baud" "$ulv_timeout" "$ulv_length" >>"$ulv_log"
    stty -F "$ulv_device" -a >>"$ulv_log" 2>&1 || true

    dd if="$ulv_device" of="$ulv_rx" bs=1 count="$ulv_length" >>"$ulv_log" 2>&1 &
    UART_LOOPBACK_READER_PID=$!
    (
        sleep "$ulv_timeout"
        kill "$UART_LOOPBACK_READER_PID" 2>/dev/null || true
    ) &
    UART_LOOPBACK_WATCHER_PID=$!
    sleep 1

    # shellcheck disable=SC2016
    if ! run_with_timeout "$ulv_timeout" sh -c 'dd if="$1" of="$2" bs=4096' sh "$ulv_tx" "$ulv_device" >>"$ulv_log" 2>&1; then
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=bounded-write observed=write-failed-or-timeout artifact=$ulv_log"
        uart_loopback_cleanup || true
        return 1
    fi

    if ! wait "$UART_LOOPBACK_READER_PID"; then
        UART_LOOPBACK_READER_PID=""
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=$ulv_length-received-bytes observed=reader-failed-or-timeout artifact=$ulv_log"
        uart_loopback_cleanup || true
        return 1
    fi
    UART_LOOPBACK_READER_PID=""
    kill "$UART_LOOPBACK_WATCHER_PID" 2>/dev/null || true
    wait "$UART_LOOPBACK_WATCHER_PID" 2>/dev/null || true
    UART_LOOPBACK_WATCHER_PID=""

    if ! cmp -s "$ulv_tx" "$ulv_rx"; then
        ulv_received=$(od -An -v -tx1 "$ulv_rx" 2>/dev/null | tr -d ' \n')
        ulv_expected=$(od -An -v -tx1 "$ulv_tx" 2>/dev/null | tr -d ' \n')
        log_fail "[UART-LOOPBACK] device=$ulv_device expected_hex=$ulv_expected observed_hex=${ulv_received:-empty} artifact=$ulv_log"
        uart_loopback_cleanup || true
        return 1
    fi

    if ! uart_loopback_cleanup; then
        return 1
    fi

    log_info "[UART-LOOPBACK] device=$ulv_device baud=$ulv_baud bytes=$ulv_length format=8N1 flow_control=off payload=verified artifact=$ulv_log"
    return 0
}

# spi_loopback_select_device
# Prints the first accessible image-provided spidev character device.
spi_loopback_select_device() {
    slsd_dev_root="${SPI_DEV_ROOT:-/dev}"
    slsd_candidate=""
    slsd_count=0

    for slsd_device in "$slsd_dev_root"/spidev*; do
        [ -c "$slsd_device" ] || continue
        if [ ! -r "$slsd_device" ] || [ ! -w "$slsd_device" ]; then
            continue
        fi
        slsd_candidate="$slsd_device"
        slsd_count=$((slsd_count + 1))
    done

    [ "$slsd_count" -eq 0 ] && return 2
    [ "$slsd_count" -eq 1 ] || return 1
    printf '%s\n' "$slsd_candidate"
    return 0
}

# spi_loopback_select_type <spidev-device>
# Requires an explicit loopback type because sysfs does not expose fixture wiring.
spi_loopback_select_type() {
    slst_device="$1"
    [ -n "$slst_device" ] || return 3

    return 2
}

# spi_loopback_validate <device> <speed-hz> <bits> <payload> <timeout-seconds> <result-dir> [mode] [internal|external]
# Runs spidev_test and requires exact TX, RX, and requested payload byte equality.
spi_loopback_validate() {
    slv_device="$1"
    slv_speed="$2"
    slv_bits="$3"
    slv_payload="$4"
    slv_timeout="$5"
    slv_result_dir="$6"
    slv_mode="${7:-0}"
    slv_loopback_type="${8:-external}"
    [ -n "$slv_device" ] && [ -n "$slv_speed" ] && [ -n "$slv_bits" ] && [ -n "$slv_payload" ] && [ -n "$slv_timeout" ] && [ -n "$slv_result_dir" ] || return 3

    case "$slv_speed:$slv_bits:$slv_timeout" in
        *[!0-9:]*|:*|*:)
            return 3
            ;;
    esac
    case "$slv_mode" in
        0|1|2|3)
            ;;
        *)
            return 3
            ;;
    esac
    case "$slv_loopback_type" in
        internal|external)
            ;;
        *)
            return 3
            ;;
    esac

    mkdir -p "$slv_result_dir" || return 1
    slv_case="mode${slv_mode}_${slv_loopback_type}"
    slv_log="$slv_result_dir/spi_loopback_${slv_case}.log"
    slv_tx_file="$slv_result_dir/spi_loopback_${slv_case}_tx.bin"
    slv_rx_file="$slv_result_dir/spi_loopback_${slv_case}_rx.bin"
    slv_spi_name=$(basename "$slv_device")
    slv_sysfs_device="${SPI_SYS_BUS_ROOT:-/sys/bus/spi}/devices/$slv_spi_name"
    slv_errors_before=""
    slv_timeouts_before=""
    : >"$slv_log"
    rm -f "$slv_rx_file"
    printf '%s' "$slv_payload" >"$slv_tx_file"

    if [ ! -c "$slv_device" ]; then
        log_fail "[SPI-LOOPBACK] device=$slv_device expected=spidev-character-device observed=missing-or-wrong-type artifact=$slv_log"
        return 1
    fi
    if ! command -v spidev_test >/dev/null 2>&1; then
        log_info "[SPI-LOOPBACK] device=$slv_device state=not-runnable reason=spidev_test-not-provided"
        return 2
    fi

    if [ -r "$slv_sysfs_device/statistics/errors" ]; then
        slv_errors_before=$(tr -d '[:space:]' <"$slv_sysfs_device/statistics/errors")
        case "$slv_errors_before" in
            ''|*[!0-9]*)
                log_fail "[SPI-LOOPBACK] device=$slv_device expected=numeric-errors-counter observed=${slv_errors_before:-empty} artifact=$slv_log"
                return 1
                ;;
        esac
    fi
    if [ -r "$slv_sysfs_device/statistics/timedout" ]; then
        slv_timeouts_before=$(tr -d '[:space:]' <"$slv_sysfs_device/statistics/timedout")
        case "$slv_timeouts_before" in
            ''|*[!0-9]*)
                log_fail "[SPI-LOOPBACK] device=$slv_device expected=numeric-timeout-counter observed=${slv_timeouts_before:-empty} artifact=$slv_log"
                return 1
                ;;
        esac
    fi
    log_info "[SPI-LOOPBACK] device=$slv_device mode=$slv_mode loopback=$slv_loopback_type errors_before=${slv_errors_before:-unavailable} timedout_before=${slv_timeouts_before:-unavailable} statistics=$slv_sysfs_device/statistics"

    set -- spidev_test -D "$slv_device" -s "$slv_speed" -b "$slv_bits" \
        -p "$slv_payload" -o "$slv_rx_file" -v
    case "$slv_mode" in
        1)
            set -- "$@" -H
            ;;
        2)
            set -- "$@" -O
            ;;
        3)
            set -- "$@" -H -O
            ;;
    esac
    if [ "$slv_loopback_type" = "internal" ]; then
        set -- "$@" -l
    fi

    if ! run_with_timeout_log "$slv_timeout" "$slv_log" "$@"; then
        log_file_with_label "SPI-LOOPBACK" "$slv_log"
        log_fail "[SPI-LOOPBACK] device=$slv_device expected=successful-bounded-transfer observed=command-failed-or-timeout artifact=$slv_log"
        return 1
    fi

    log_file_with_label "SPI-LOOPBACK" "$slv_log"
    if [ ! -f "$slv_rx_file" ]; then
        log_fail "[SPI-LOOPBACK] device=$slv_device expected=fresh-RX-artifact observed=missing artifact=$slv_log"
        return 1
    fi
    if ! cmp -s "$slv_tx_file" "$slv_rx_file"; then
        slv_expected=$(od -An -v -tx1 "$slv_tx_file" | tr -d ' \n' | tr '[:upper:]' '[:lower:]')
        slv_received=$(od -An -v -tx1 "$slv_rx_file" | tr -d ' \n' | tr '[:upper:]' '[:lower:]')
        log_fail "[SPI-LOOPBACK] device=$slv_device expected_hex=$slv_expected observed_hex=${slv_received:-empty} artifact=$slv_log"
        return 1
    fi

    slv_errors_after=""
    slv_timeouts_after=""
    if [ -r "$slv_sysfs_device/statistics/errors" ]; then
        slv_errors_after=$(tr -d '[:space:]' <"$slv_sysfs_device/statistics/errors")
        case "$slv_errors_after" in
            ''|*[!0-9]*)
                log_fail "[SPI-LOOPBACK] device=$slv_device expected=numeric-errors-counter observed=${slv_errors_after:-empty} artifact=$slv_log"
                return 1
                ;;
        esac
    fi
    if [ -r "$slv_sysfs_device/statistics/timedout" ]; then
        slv_timeouts_after=$(tr -d '[:space:]' <"$slv_sysfs_device/statistics/timedout")
        case "$slv_timeouts_after" in
            ''|*[!0-9]*)
                log_fail "[SPI-LOOPBACK] device=$slv_device expected=numeric-timeout-counter observed=${slv_timeouts_after:-empty} artifact=$slv_log"
                return 1
                ;;
        esac
    fi
    log_info "[SPI-LOOPBACK] device=$slv_device mode=$slv_mode loopback=$slv_loopback_type errors_after=${slv_errors_after:-unavailable} timedout_after=${slv_timeouts_after:-unavailable}"
    if [ -n "$slv_errors_before" ] && [ -n "$slv_errors_after" ] &&
       [ "$slv_errors_after" -gt "$slv_errors_before" ] 2>/dev/null; then
        log_fail "[SPI-LOOPBACK] device=$slv_device expected=no-new-controller-errors observed=errors-$slv_errors_before-to-$slv_errors_after artifact=$slv_log"
        return 1
    fi
    if [ -n "$slv_timeouts_before" ] && [ -n "$slv_timeouts_after" ] &&
       [ "$slv_timeouts_after" -gt "$slv_timeouts_before" ] 2>/dev/null; then
        log_fail "[SPI-LOOPBACK] device=$slv_device expected=no-new-controller-timeouts observed=timedout-$slv_timeouts_before-to-$slv_timeouts_after artifact=$slv_log"
        return 1
    fi

    log_info "[SPI-LOOPBACK] device=$slv_device mode=$slv_mode loopback=$slv_loopback_type speed_hz=$slv_speed bits=$slv_bits bytes=$(printf '%s' "$slv_payload" | wc -c | tr -d '[:space:]') payload=verified artifact=$slv_log"
    return 0
}

CAN_LOOPBACK_INTERFACE=""
CAN_LOOPBACK_INITIAL_MODE="off"
CAN_LOOPBACK_INITIAL_BITRATE=""
CAN_LOOPBACK_INITIAL_DBITRATE=""
CAN_LOOPBACK_INITIAL_FD="off"
CAN_LOOPBACK_TEST_MODE="classic"
CAN_LOOPBACK_CHANGED=0
CAN_LOOPBACK_CANDUMP_PID=""

# can_internal_loopback_interface_is_ready <interface>
# Returns success only for a physical SocketCAN interface that is down in sysfs.
can_internal_loopback_interface_is_ready() {
    cili_interface="$1"
    cili_net_root="${CAN_SYS_CLASS_NET_ROOT:-/sys/class/net}"
    cili_path="$cili_net_root/$cili_interface"

    [ -d "$cili_path" ] || return 2
    [ -r "$cili_path/type" ] || return 1
    [ "$(tr -d '[:space:]' <"$cili_path/type")" = "280" ] || return 1
    [ -e "$cili_path/device" ] || return 1
    [ "$(cat "$cili_path/operstate" 2>/dev/null || true)" = "down" ] || return 1
    return 0
}

# can_internal_loopback_select_interface <auto|classic|fd>
# Prints the unique down physical CAN interface that may be configured safely.
can_internal_loopback_select_interface() {
    cilsi_mode="$1"
    cilsi_net_root="${CAN_SYS_CLASS_NET_ROOT:-/sys/class/net}"
    cilsi_candidate=""
    cilsi_count=0
    [ "$cilsi_mode" = "auto" ] || [ "$cilsi_mode" = "classic" ] || [ "$cilsi_mode" = "fd" ] || return 3
    [ -d "$cilsi_net_root" ] || return 2

    for cilsi_path in "$cilsi_net_root"/*; do
        cilsi_interface=$(basename "$cilsi_path")
        can_internal_loopback_interface_is_ready "$cilsi_interface" || continue
        cilsi_candidate="$cilsi_interface"
        cilsi_count=$((cilsi_count + 1))
    done

    [ "$cilsi_count" -eq 0 ] && return 2
    [ "$cilsi_count" -eq 1 ] || return 1
    printf '%s\n' "$cilsi_candidate"
    return 0
}

# can_internal_loopback_select_modes <interface>
# Prints the automatic classic and CAN FD functional matrix.
can_internal_loopback_select_modes() {
    cilsm_interface="$1"
    [ -n "$cilsm_interface" ] || return 3

    cilsm_path="${CAN_SYS_CLASS_NET_ROOT:-/sys/class/net}/$cilsm_interface"
    [ -d "$cilsm_path" ] || return 2
    printf '%s\n' 'classic,fd'
}

# can_internal_loopback_cleanup
# Stops candump, returns the interface down, and restores its loopback flag.
can_internal_loopback_cleanup() {
    cilc_status=0

    if [ -n "$CAN_LOOPBACK_CANDUMP_PID" ]; then
        kill "$CAN_LOOPBACK_CANDUMP_PID" 2>/dev/null || true
        wait "$CAN_LOOPBACK_CANDUMP_PID" 2>/dev/null || true
        CAN_LOOPBACK_CANDUMP_PID=""
    fi

    if [ -n "$CAN_LOOPBACK_INTERFACE" ]; then
        if ! ip link set dev "$CAN_LOOPBACK_INTERFACE" down >/dev/null 2>&1; then
            log_fail "[CAN-RESTORE] interface=$CAN_LOOPBACK_INTERFACE expected=administratively-down observed=down-failed"
            cilc_status=1
        fi
        if [ "$CAN_LOOPBACK_CHANGED" -eq 1 ]; then
            set -- ip link set dev "$CAN_LOOPBACK_INTERFACE" type can
            if [ -n "$CAN_LOOPBACK_INITIAL_BITRATE" ]; then
                set -- "$@" bitrate "$CAN_LOOPBACK_INITIAL_BITRATE"
            fi
            if [ "$CAN_LOOPBACK_INITIAL_FD" = "on" ] && [ -n "$CAN_LOOPBACK_INITIAL_DBITRATE" ]; then
                set -- "$@" dbitrate "$CAN_LOOPBACK_INITIAL_DBITRATE" fd on
            elif [ "$CAN_LOOPBACK_TEST_MODE" = "fd" ]; then
                set -- "$@" fd off
            fi
            set -- "$@" loopback "$CAN_LOOPBACK_INITIAL_MODE"
            if ! "$@" >/dev/null 2>&1; then
                log_fail "[CAN-RESTORE] interface=$CAN_LOOPBACK_INTERFACE expected=original-CAN-configuration observed=restore-failed bitrate=${CAN_LOOPBACK_INITIAL_BITRATE:-unset} dbitrate=${CAN_LOOPBACK_INITIAL_DBITRATE:-unset} fd=$CAN_LOOPBACK_INITIAL_FD loopback=$CAN_LOOPBACK_INITIAL_MODE"
                cilc_status=1
            else
                log_info "[CAN-RESTORE] interface=$CAN_LOOPBACK_INTERFACE admin_state=down bitrate=${CAN_LOOPBACK_INITIAL_BITRATE:-test-default-retained} dbitrate=${CAN_LOOPBACK_INITIAL_DBITRATE:-unset} fd=$CAN_LOOPBACK_INITIAL_FD loopback=$CAN_LOOPBACK_INITIAL_MODE"
            fi
        fi
    fi

    CAN_LOOPBACK_INTERFACE=""
    CAN_LOOPBACK_INITIAL_MODE="off"
    CAN_LOOPBACK_INITIAL_BITRATE=""
    CAN_LOOPBACK_INITIAL_DBITRATE=""
    CAN_LOOPBACK_INITIAL_FD="off"
    CAN_LOOPBACK_TEST_MODE="classic"
    CAN_LOOPBACK_CHANGED=0
    return "$cilc_status"
}

# can_internal_loopback_validate <interface> <classic|fd> <timeout-seconds> <result-dir> <bitrate> <data-bitrate>
# Configures a selected, initially down CAN interface and restores recoverable state.
can_internal_loopback_validate() {
    cilv_interface="$1"
    cilv_mode="$2"
    cilv_timeout="$3"
    cilv_result_dir="$4"
    cilv_requested_bitrate="$5"
    cilv_requested_dbitrate="$6"
    [ -n "$cilv_interface" ] && [ -n "$cilv_mode" ] && [ -n "$cilv_timeout" ] && [ -n "$cilv_result_dir" ] && [ -n "$cilv_requested_bitrate" ] && [ -n "$cilv_requested_dbitrate" ] || return 3

    for cilv_numeric in \
        "$cilv_timeout" \
        "$cilv_requested_bitrate" \
        "$cilv_requested_dbitrate"; do
        case "$cilv_numeric" in
            ''|*[!0-9]*|0)
                return 3
                ;;
        esac
    done
    case "$cilv_mode" in
        classic|fd)
            ;;
        *)
            return 3
            ;;
    esac

    cilv_iface_path="${CAN_SYS_CLASS_NET_ROOT:-/sys/class/net}/$cilv_interface"
    mkdir -p "$cilv_result_dir" || return 1
    cilv_snapshot="$cilv_result_dir/can_loopback_initial_state_${cilv_mode}.log"
    cilv_rx_log="$cilv_result_dir/can_loopback_rx_${cilv_mode}.log"
    cilv_stats_log="$cilv_result_dir/can_loopback_statistics_${cilv_mode}.log"
    : >"$cilv_rx_log"

    if [ ! -d "$cilv_iface_path" ] || [ ! -r "$cilv_iface_path/type" ]; then
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=runtime-interface observed=missing artifact=$cilv_snapshot"
        return 1
    fi
    cilv_type=$(tr -d '[:space:]' <"$cilv_iface_path/type")
    if [ "$cilv_type" != "280" ] || [ ! -e "$cilv_iface_path/device" ]; then
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=physical-SocketCAN-interface observed=type-$cilv_type-or-software-only artifact=$cilv_snapshot"
        return 1
    fi

    if ! ip -details link show dev "$cilv_interface" >"$cilv_snapshot" 2>&1; then
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=readable-CAN-configuration observed=ip-query-failed artifact=$cilv_snapshot"
        return 1
    fi
    cilv_flags=$(ip -o link show dev "$cilv_interface" 2>/dev/null | sed -n 's/.*<\([^>]*\)>.*/\1/p')
    if printf '%s\n' "$cilv_flags" | tr ',' '\n' | grep -qx UP; then
        log_info "[CAN-LOOPBACK] interface=$cilv_interface state=not-runnable reason=interface-is-already-up action=refused"
        return 2
    fi

    CAN_LOOPBACK_INITIAL_BITRATE=$(awk '
        /bitrate[[:space:]]+[0-9]+/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "bitrate") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' "$cilv_snapshot")
    CAN_LOOPBACK_INITIAL_DBITRATE=$(awk '
        /dbitrate[[:space:]]+[0-9]+/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "dbitrate") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' "$cilv_snapshot")

    CAN_LOOPBACK_INITIAL_MODE=off
    if grep -Eq '<[^>]*LOOPBACK([^A-Z-]|[>,])' "$cilv_snapshot"; then
        CAN_LOOPBACK_INITIAL_MODE=on
    fi
    CAN_LOOPBACK_INITIAL_FD=off
    if grep -Eq '<[^>]*FD([^A-Z-]|[>,])' "$cilv_snapshot"; then
        CAN_LOOPBACK_INITIAL_FD=on
    fi
    if [ "$cilv_mode" = "fd" ]; then
        cilv_frames='5A5##1514C492D43414E4644'
        cilv_markers='5A5##1514C492D43414E4644'
        cilv_frame_count=1
    else
        cilv_frames='5A5#514C4943414E 1ABCDE#45585443414E'
        cilv_markers='5A5#514C4943414E 001ABCDE#45585443414E'
        cilv_frame_count=2
    fi

    cilv_rx_packets_before=$(cat "$cilv_iface_path/statistics/rx_packets" 2>/dev/null || printf '%s\n' unknown)
    cilv_tx_packets_before=$(cat "$cilv_iface_path/statistics/tx_packets" 2>/dev/null || printf '%s\n' unknown)
    cilv_rx_errors_before=$(cat "$cilv_iface_path/statistics/rx_errors" 2>/dev/null || printf '%s\n' unknown)
    cilv_tx_errors_before=$(cat "$cilv_iface_path/statistics/tx_errors" 2>/dev/null || printf '%s\n' unknown)
    for cilv_counter in \
        "$cilv_rx_packets_before" \
        "$cilv_tx_packets_before" \
        "$cilv_rx_errors_before" \
        "$cilv_tx_errors_before"; do
        case "$cilv_counter" in
            unknown)
                ;;
            ''|*[!0-9]*)
                log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=numeric-sysfs-counter observed=${cilv_counter:-empty} artifact=$cilv_stats_log"
                return 1
                ;;
        esac
    done
    printf 'before rx_packets=%s tx_packets=%s rx_errors=%s tx_errors=%s\n' \
        "$cilv_rx_packets_before" "$cilv_tx_packets_before" \
        "$cilv_rx_errors_before" "$cilv_tx_errors_before" >"$cilv_stats_log"

    CAN_LOOPBACK_INTERFACE="$cilv_interface"
    CAN_LOOPBACK_TEST_MODE="$cilv_mode"
    if [ "$cilv_mode" = "fd" ]; then
        if ! ip link set dev "$cilv_interface" type can \
            bitrate "$cilv_requested_bitrate" \
            dbitrate "$cilv_requested_dbitrate" \
            fd on \
            loopback on; then
            log_info "[CAN-LOOPBACK] interface=$cilv_interface state=not-runnable reason=CAN-FD-configuration-rejected bitrate=$cilv_requested_bitrate dbitrate=$cilv_requested_dbitrate artifact=$cilv_snapshot"
            can_internal_loopback_cleanup || true
            return 2
        fi
    elif ! ip link set dev "$cilv_interface" type can \
        bitrate "$cilv_requested_bitrate" \
        loopback on; then
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=classic-CAN-configuration observed=ip-command-failed bitrate=$cilv_requested_bitrate artifact=$cilv_snapshot"
        can_internal_loopback_cleanup || true
        return 1
    fi
    CAN_LOOPBACK_CHANGED=1
    cilv_dbitrate_display=not-applicable
    if [ "$cilv_mode" = "fd" ]; then
        cilv_dbitrate_display="$cilv_requested_dbitrate"
    fi
    log_info "[CAN-LOOPBACK] interface=$cilv_interface mode=$cilv_mode configured_bitrate=$cilv_requested_bitrate configured_dbitrate=$cilv_dbitrate_display loopback=on"
    if ! ip link set dev "$cilv_interface" up; then
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=administratively-up observed=ip-command-failed bitrate=$cilv_requested_bitrate artifact=$cilv_snapshot"
        can_internal_loopback_cleanup || true
        return 1
    fi

    candump -L -n "$cilv_frame_count" -T "$((cilv_timeout * 1000))" "$cilv_interface" >"$cilv_rx_log" 2>&1 &
    CAN_LOOPBACK_CANDUMP_PID=$!
    sleep 1
    for cilv_frame in $cilv_frames; do
        log_info "[CAN-LOOPBACK] interface=$cilv_interface mode=$cilv_mode action=transmit frame=$cilv_frame"
        if ! run_with_timeout "$cilv_timeout" cansend "$cilv_interface" "$cilv_frame"; then
            log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=frame-transmit observed=cansend-failed-or-timeout frame=$cilv_frame artifact=$cilv_rx_log"
            can_internal_loopback_cleanup || true
            return 1
        fi
    done
    if ! wait "$CAN_LOOPBACK_CANDUMP_PID"; then
        CAN_LOOPBACK_CANDUMP_PID=""
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=$cilv_frame_count-received-loopback-frames observed=candump-failed-or-timeout frames=$cilv_frames artifact=$cilv_rx_log"
        can_internal_loopback_cleanup || true
        return 1
    fi
    CAN_LOOPBACK_CANDUMP_PID=""

    cilv_normalized=$(tr -d ' .\t\r\n' <"$cilv_rx_log" | tr '[:lower:]' '[:upper:]')
    for cilv_marker in $cilv_markers; do
        if ! printf '%s\n' "$cilv_normalized" | grep -Fq "$cilv_marker"; then
            log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected_frame=$cilv_marker observed_log=$cilv_rx_log artifact=$cilv_rx_log"
            can_internal_loopback_cleanup || true
            return 1
        fi
    done

    cilv_rx_packets_after=$(cat "$cilv_iface_path/statistics/rx_packets" 2>/dev/null || printf '%s\n' unknown)
    cilv_tx_packets_after=$(cat "$cilv_iface_path/statistics/tx_packets" 2>/dev/null || printf '%s\n' unknown)
    cilv_rx_errors_after=$(cat "$cilv_iface_path/statistics/rx_errors" 2>/dev/null || printf '%s\n' unknown)
    cilv_tx_errors_after=$(cat "$cilv_iface_path/statistics/tx_errors" 2>/dev/null || printf '%s\n' unknown)
    for cilv_counter in \
        "$cilv_rx_packets_after" \
        "$cilv_tx_packets_after" \
        "$cilv_rx_errors_after" \
        "$cilv_tx_errors_after"; do
        case "$cilv_counter" in
            unknown)
                ;;
            ''|*[!0-9]*)
                log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=numeric-sysfs-counter observed=${cilv_counter:-empty} artifact=$cilv_stats_log"
                can_internal_loopback_cleanup || true
                return 1
                ;;
        esac
    done
    printf 'after rx_packets=%s tx_packets=%s rx_errors=%s tx_errors=%s\n' \
        "$cilv_rx_packets_after" "$cilv_tx_packets_after" \
        "$cilv_rx_errors_after" "$cilv_tx_errors_after" >>"$cilv_stats_log"
    ip -details -statistics link show dev "$cilv_interface" >>"$cilv_stats_log" 2>&1 || true

    if ! can_internal_loopback_cleanup; then
        return 1
    fi

    if [ "$cilv_rx_packets_before" != "unknown" ] && [ "$cilv_rx_packets_after" != "unknown" ] &&
       [ $((cilv_rx_packets_after - cilv_rx_packets_before)) -lt "$cilv_frame_count" ]; then
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=rx-packet-increase-at-least-$cilv_frame_count observed=$cilv_rx_packets_before-to-$cilv_rx_packets_after artifact=$cilv_stats_log"
        return 1
    fi
    if [ "$cilv_tx_packets_before" != "unknown" ] && [ "$cilv_tx_packets_after" != "unknown" ] &&
       [ $((cilv_tx_packets_after - cilv_tx_packets_before)) -lt "$cilv_frame_count" ]; then
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=tx-packet-increase-at-least-$cilv_frame_count observed=$cilv_tx_packets_before-to-$cilv_tx_packets_after artifact=$cilv_stats_log"
        return 1
    fi
    if [ "$cilv_rx_errors_before" != "unknown" ] && [ "$cilv_rx_errors_after" != "unknown" ] &&
       [ "$cilv_rx_errors_after" -gt "$cilv_rx_errors_before" ] 2>/dev/null; then
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=no-new-rx-errors observed=$cilv_rx_errors_before-to-$cilv_rx_errors_after artifact=$cilv_stats_log"
        return 1
    fi
    if [ "$cilv_tx_errors_before" != "unknown" ] && [ "$cilv_tx_errors_after" != "unknown" ] &&
       [ "$cilv_tx_errors_after" -gt "$cilv_tx_errors_before" ] 2>/dev/null; then
        log_fail "[CAN-LOOPBACK] interface=$cilv_interface expected=no-new-tx-errors observed=$cilv_tx_errors_before-to-$cilv_tx_errors_after artifact=$cilv_stats_log"
        return 1
    fi

    log_info "[CAN-LOOPBACK] interface=$cilv_interface mode=$cilv_mode bitrate=$cilv_requested_bitrate dbitrate=$cilv_dbitrate_display frames=$cilv_frame_count payloads=verified rx_packets=$cilv_rx_packets_before-to-$cilv_rx_packets_after tx_packets=$cilv_tx_packets_before-to-$cilv_tx_packets_after rx_errors=$cilv_rx_errors_before-to-$cilv_rx_errors_after tx_errors=$cilv_tx_errors_before-to-$cilv_tx_errors_after artifacts=$cilv_rx_log,$cilv_stats_log"
    return 0
}
