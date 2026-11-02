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

# i2c_dt_path_enabled <dt-node>
# Returns 0 only when the node and all parents have absent/okay/ok status.
# No stdout or hardware changes. Resolves firmware symlinks before walking.
i2c_dt_path_enabled() {
    idpe_path=$(readlink -f "$1" 2>/dev/null) || return 1
    [ -d "$idpe_path" ] || return 1
    while [ "$idpe_path" != / ]; do
        if [ -f "$idpe_path/status" ]; then
            idpe_status=$(dt_property_text "$idpe_path" status) || return 1
            case "$idpe_status" in
                ''|okay|ok)
                    ;;
                *)
                    return 1
                    ;;
            esac
        fi
        idpe_path=${idpe_path%/*}
        [ -n "$idpe_path" ] || break
    done
}

# i2c_topology_issue <object> <expected> <observed>
# Records a topology defect in the current report and sets its failure flag.
# Logs to stdout, no hardware changes. Called only by i2c_validate_topology.
i2c_topology_issue() {
    ivt_failed=1
    printf 'FAIL\t%s\t%s\t%s\n' "$1" "$2" "$3" >>"$ivt_report"
    log_fail "[I2C-TOPOLOGY] object=$1 expected=$2 observed=$3 artifact=$ivt_report"
}

# i2c_topology_check_bus <dt-bus> <result-dir> <required|optional-camera>
# Reconciles immediate firmware clients with exact runtime of_node identities.
# Appends absent optional cameras for caller SKIPs. Never scans hardware.
i2c_topology_check_bus() {
    itcb_bus="$1"
    itcb_dir="$2"
    itcb_policy="$3"
    [ ! -d "$itcb_bus/i2c-bus" ] || itcb_bus="$itcb_bus/i2c-bus"
    for itcb_child in "$itcb_bus"/*; do
        [ -d "$itcb_child" ] || continue
        [ -f "$itcb_child/compatible" ] || [ -f "$itcb_child/reg" ] || continue
        case "${itcb_child##*/}" in
            ports|port|port@*)
                continue
                ;;
        esac
        i2c_dt_path_enabled "$itcb_child" || continue
        itcb_node=$(readlink -f "$itcb_child") || return 1
        if awk -F '\t' -v node="$itcb_node" '
            $1 == node { found=1 } END { exit !found }
        ' "$itcb_dir/i2c_client_nodes.tsv"; then
            continue
        fi
        if [ "$itcb_policy" = optional-camera ] &&
           i2c_client_is_camera_sensor "$itcb_node"; then
            I2C_RUNTIME_OPTIONAL_CAMERA_COUNT=$((I2C_RUNTIME_OPTIONAL_CAMERA_COUNT + 1))
            printf '%s\t%s\t%s\n' "dt:${itcb_node##*/}" \
                "not-enumerated" "$itcb_node" >>"$itcb_dir/i2c_optional_camera_clients.tsv" || return 1
            log_warn "[I2C-TOPOLOGY] optional camera node=$itcb_node has no runtime client, captured probe errors still fail"
        else
            i2c_topology_issue "$itcb_node" runtime-i2c-client not-enumerated
        fi
    done
}

# i2c_validate_topology <result-dir> <required|optional-camera>
# Checks discovered controllers, exact DT adapter/client mappings and mux links.
# Requires the inventory TSVs and functestlib.sh. Returns 0 healthy, 1 faulty.
# Retains i2c_topology.tsv and node maps, logs findings, no hardware operations.
i2c_validate_topology() {
    ivt_dir="$1"
    ivt_policy="$2"
    ivt_report="$ivt_dir/i2c_topology.tsv"
    ivt_failed=0
    printf 'status\tobject\texpected\tobserved\n' >"$ivt_report" || return 1
    : >"$ivt_dir/i2c_adapter_nodes.tsv" || return 1
    : >"$ivt_dir/i2c_client_nodes.tsv" || return 1
    while IFS="$(printf '\t')" read -r ivt_id ivt_rest; do
        [ -n "$ivt_id" ] || continue
        ivt_adapter="/sys/bus/i2c/devices/$ivt_id"
        [ -d "$ivt_adapter" ] || ivt_adapter="/sys/class/i2c-adapter/$ivt_id"
        ivt_real=$(readlink -f "$ivt_adapter") || return 1
        ivt_node=""
        if [ -L "$ivt_adapter/of_node" ]; then
            ivt_node=$(readlink -f "$ivt_adapter/of_node") || return 1
        elif [ -L "/sys/class/i2c-adapter/$ivt_id/of_node" ]; then
            ivt_node=$(readlink -f "/sys/class/i2c-adapter/$ivt_id/of_node") || return 1
        fi
        printf '%s\t%s\t%s\n' "$ivt_node" "$ivt_id" "$ivt_real" >>"$ivt_dir/i2c_adapter_nodes.tsv" || return 1
        if [ -L "$ivt_adapter/mux_device" ] && [ ! -d "$ivt_adapter/mux_device" ]; then
            i2c_topology_issue "$ivt_id" accessible-mux-device broken-link
        fi
    done <"$ivt_dir/i2c_adapters.tsv"
    for ivt_client in /sys/bus/i2c/devices/[0-9]*-[0-9a-fA-F]*; do
        [ -d "$ivt_client" ] || continue
        if [ -L "$ivt_client/of_node" ]; then
            ivt_node=$(readlink -f "$ivt_client/of_node") || return 1
            printf '%s\t%s\n' "$ivt_node" "${ivt_client##*/}" >>"$ivt_dir/i2c_client_nodes.tsv" || return 1
        fi
        for ivt_link in "$ivt_client"/channel-*; do
            [ -L "$ivt_link" ] || continue
            [ -d "$ivt_link" ] || i2c_topology_issue "$ivt_link" runtime-mux-adapter broken-link
        done
    done
    # shellcheck disable=SC2034 # Remaining controller columns are retained in the source inventory.
    while IFS="$(printf '\t')" read -r ivt_node ivt_rest; do
        [ -n "$ivt_node" ] || continue
        ivt_device=$(find_platform_device_for_dt_node "$ivt_node" 2>/dev/null || true)
        ivt_device=$(readlink -f "$ivt_device" 2>/dev/null || true)
        ivt_count=0
        if [ -n "$ivt_device" ]; then
            ivt_count=$(awk -F '\t' -v prefix="$ivt_device/" '
                index($3, prefix) == 1 { count++ } END { print count+0 }
            ' "$ivt_dir/i2c_adapter_nodes.tsv")
        fi
        ivt_subbuses=0
        for ivt_bus in "$ivt_node"/i2c-bus@*; do
            [ -d "$ivt_bus" ] || continue
            i2c_dt_path_enabled "$ivt_bus" || continue
            ivt_subbuses=$((ivt_subbuses + 1))
            if ! awk -F '\t' -v node="$ivt_bus" '
                $1 == node { found=1 } END { exit !found }
            ' "$ivt_dir/i2c_adapter_nodes.tsv"; then
                i2c_topology_issue "$ivt_bus" runtime-i2c-adapter not-enumerated
            fi
        done
        ivt_compatible=$(dt_property_text "$ivt_node" compatible)
        case "$ivt_compatible" in
            *-cci*)
                # A CCI parent may legitimately have no enabled master buses.
                ;;
            *)
                [ "$ivt_count" -gt 0 ] || i2c_topology_issue "$ivt_node" owned-i2c-adapter none
                ;;
        esac
        printf 'INFO\t%s\towned-adapters\t%s\n' "$ivt_node" "$ivt_count" >>"$ivt_report" || return 1
        log_info "[I2C-TOPOLOGY] controller=$ivt_node owned_adapters=$ivt_count enabled_child_buses=$ivt_subbuses"
    done <"$ivt_dir/i2c_controllers.tsv"
    while IFS="$(printf '\t')" read -r ivt_node ivt_id ivt_real; do
        [ -d "$ivt_node" ] || continue
        i2c_topology_check_bus "$ivt_node" "$ivt_dir" "$ivt_policy" || return 1
    done <"$ivt_dir/i2c_adapter_nodes.tsv"
    # Mux channel nodes are buses, not I2C clients. Match their own firmware
    # identities, never infer channel numbers from dynamically assigned bus IDs.
    while IFS="$(printf '\t')" read -r ivt_node ivt_id; do
        for ivt_bus in "$ivt_node"/i2c@* "$ivt_node"/i2c-mux/i2c@*; do
            [ -d "$ivt_bus" ] || continue
            i2c_dt_path_enabled "$ivt_bus" || continue
            if ! awk -F '\t' -v node="$ivt_bus" '
                $1 == node { found=1 } END { exit !found }
            ' "$ivt_dir/i2c_adapter_nodes.tsv"; then
                i2c_topology_issue "$ivt_bus" runtime-mux-channel not-enumerated
            fi
        done
    done <"$ivt_dir/i2c_client_nodes.tsv"
    [ "$ivt_failed" -eq 0 ]
}

# i2c_select_eeprom_adapter <tools-dir> <result-dir> <timeout-seconds> <device>
# Prints a unique EEPROM adapter number, returns 1 when unavailable/ambiguous.
# Retains discovery artifacts, no stdout diagnostics or device transfers.
i2c_select_eeprom_adapter() {
    isea_runner="$1/i2c_eeprom_read.sh"
    isea_interpreter="sh"
    if command -v python3 >/dev/null 2>&1; then
        isea_runner="$1/i2c_eeprom_runner.py"
        isea_interpreter=python3
    fi
    isea_log="$2/i2c_eeprom_adapter_discovery.log"
    isea_report="$2/i2c_eeprom_adapter_discovery.tsv"
    [ -f "$isea_runner" ] || return 1
    run_with_timeout_log "$3" "$isea_log" "$isea_interpreter" "$isea_runner" \
        --mode discover --device "$4" --report "$isea_report" || return 1
    grep -q '^I2C_EEPROM_RESULT status=PASS ' "$isea_log" || return 1
    isea_adapter=$(awk -F '\t' '$1 == "adapter" { print $2; exit }' "$isea_report")
    case "$isea_adapter" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    [ -c "/dev/i2c-$isea_adapter" ] || return 1
    printf '%s\n' "$isea_adapter"
}

# i2c_eeprom_client_path <sysfs-data-file>
# Prints the resolved owning I2C client, returns 1 if it cannot be identified.
# No logs or mutations. Used by the shell-only EEPROM discovery path.
i2c_eeprom_client_path() {
    for iecp_candidate in "$1" "${1%/*}/device"; do
        [ -e "$iecp_candidate" ] || continue
        iecp_path=$(readlink -f "$iecp_candidate" 2>/dev/null) || return 1
        while [ -n "$iecp_path" ] && [ "$iecp_path" != / ]; do
            if printf '%s\n' "${iecp_path##*/}" | grep -Eq '^[0-9]+-[0-9a-fA-F]{4}$'; then
                printf '%s\n' "$iecp_path"
                return 0
            fi
            iecp_path=${iecp_path%/*}
        done
    done
    return 1
}

# i2c_eeprom_select <auto|sysfs-file> <result-dir>
# Sets I2C_EEPROM_SELECTED, I2C_EEPROM_CLIENT and I2C_EEPROM_SIZE.
# Retains candidates and logs selection. Returns 0 selected, 1 faulty,
# 2 absent/ambiguous, 3 invalid input. Reads metadata only, never device data.
i2c_eeprom_select() {
    ies_request="$1"
    ies_dir="$2"
    I2C_EEPROM_SELECTED=""
    I2C_EEPROM_CLIENT=""
    I2C_EEPROM_SIZE=""
    : >"$ies_dir/i2c_eeprom_candidates.tsv" || return 1
    if [ "$ies_request" = auto ]; then
        set -- /sys/bus/i2c/devices/*/eeprom /sys/bus/nvmem/devices/*/nvmem
    else
        [ -f "$ies_request" ] || {
            log_fail "Requested EEPROM does not exist: $ies_request"
            return 1
        }
        set -- "$ies_request"
    fi
    ies_seen=" "
    ies_count=0
    for ies_file in "$@"; do
        [ -f "$ies_file" ] || continue
        case "${ies_file##*/}" in
            eeprom)
                ;;
            nvmem)
                ies_type=""
                if [ -r "${ies_file%/*}/type" ]; then
                    ies_type=$(cat "${ies_file%/*}/type") || return 1
                fi
                case "$ies_type" in
                    ''|EEPROM|eeprom)
                        ;;
                    *)
                        [ "$ies_request" = auto ] && continue
                        return 3
                        ;;
                esac
                ;;
            *)
                return 3
                ;;
        esac
        ies_client=$(i2c_eeprom_client_path "$ies_file") || {
            [ "$ies_request" = auto ] && continue
            return 3
        }
        case "$ies_seen" in
            *" $ies_client "*)
                continue
                ;;
        esac
        ies_seen="$ies_seen$ies_client "
        ies_count=$((ies_count + 1))
        printf '%s\t%s\n' "$ies_file" "$ies_client" >>"$ies_dir/i2c_eeprom_candidates.tsv" || return 1
        log_info "[I2C-EEPROM-CANDIDATE] path=$ies_file client=$ies_client"
        I2C_EEPROM_SELECTED="$ies_file"
        I2C_EEPROM_CLIENT="$ies_client"
    done
    if [ "$ies_count" -ne 1 ]; then
        log_warn "EEPROM selection needs exactly one candidate, found=$ies_count, provide --eeprom-device for multiple candidates"
        return 2
    fi
    I2C_EEPROM_SIZE=$(stat -L -c %s "$I2C_EEPROM_SELECTED" 2>/dev/null) || return 1
    if [ "$I2C_EEPROM_SIZE" = 0 ]; then
        for ies_size_file in "${I2C_EEPROM_SELECTED%/*}/size" "${I2C_EEPROM_SELECTED%/*}/../size"; do
            [ -r "$ies_size_file" ] || continue
            I2C_EEPROM_SIZE=$(cat "$ies_size_file") || return 1
            break
        done
    fi
    I2C_EEPROM_SIZE=$(i2c_tools_value_decimal "$I2C_EEPROM_SIZE") || return 1
    [ "$I2C_EEPROM_SIZE" -gt 0 ] || return 2
    log_info "[I2C-EEPROM-SELECT] path=$I2C_EEPROM_SELECTED client=$I2C_EEPROM_CLIENT size=$I2C_EEPROM_SIZE source=$ies_request"
}

# i2c_eeprom_read_exact <file> <offset> <length> <output> <result-dir>
# Reads through the kernel driver with a finite timeout and verifies byte count.
# Uses the largest aligned block up to 4096 bytes, compatible with BusyBox dd.
# Returns 0 exact read, 1 failure. Retains output/error artifacts, no device writes.
i2c_eeprom_read_exact() {
    iere_file="$1"
    iere_offset="$2"
    iere_length="$3"
    iere_output="$4"
    iere_dir="$5"
    if ! [ "$iere_offset" -ge 0 ] 2>/dev/null ||
       ! [ "$iere_length" -gt 0 ] 2>/dev/null; then
        log_fail "[I2C-EEPROM-READ] invalid offset=$iere_offset or length=$iere_length"
        return 1
    fi
    iere_block=4096
    for iere_value in "$iere_offset" "$iere_length"; do
        while [ "$iere_value" -ne 0 ]; do
            iere_remainder=$((iere_block % iere_value))
            iere_block=$iere_value
            iere_value=$iere_remainder
        done
    done
    run_with_managed_timeout 10 "$iere_dir" eeprom-read \
        dd iflag=fullblock "if=$iere_file" "of=$iere_output" "bs=$iere_block" \
        "skip=$((iere_offset / iere_block))" "count=$((iere_length / iere_block))" \
        >"$iere_output.log" 2>&1
    iere_status=$?
    iere_bytes=$(wc -c <"$iere_output" 2>/dev/null | tr -d '[:space:]')
    if [ "$iere_status" -ne 0 ] || [ "$iere_bytes" != "$iere_length" ]; then
        log_fail "[I2C-EEPROM-READ] path=$iere_file offset=$iere_offset expected=$iere_length actual=${iere_bytes:-0} rc=$iere_status artifact=$iere_output.log"
        log_file_with_label I2C-EEPROM-ERROR "$iere_output.log" 12
        return 1
    fi
}

# i2c_eeprom_read_matrix <file> <offset> <length> <result-dir>
# Compares bounded repeated reads against a baseline at start, middle and end.
# Returns 0 exact matches, 1 failure. No claims about driver DMA/FIFO selection.
i2c_eeprom_read_matrix() {
    ierm_file="$1"
    ierm_offset="$2"
    ierm_length="$3"
    ierm_dir="$4"
    i2c_eeprom_read_exact "$ierm_file" "$ierm_offset" "$ierm_length" "$ierm_dir/eeprom-baseline.bin" "$ierm_dir" || return 1
    ierm_case=0
    for ierm_size in 1 2 3 16 32 64 "$ierm_length"; do
        [ "$ierm_size" -le "$ierm_length" ] || continue
        for ierm_relative in 0 "$(((ierm_length - ierm_size) / 2))" "$((ierm_length - ierm_size))"; do
            ierm_case=$((ierm_case + 1))
            ierm_expected="$ierm_dir/matrix-$ierm_case-expected.bin"
            ierm_actual="$ierm_dir/matrix-$ierm_case-actual.bin"
            i2c_eeprom_read_exact "$ierm_dir/eeprom-baseline.bin" "$ierm_relative" "$ierm_size" "$ierm_expected" "$ierm_dir" || return 1
            i2c_eeprom_read_exact "$ierm_file" "$((ierm_offset + ierm_relative))" "$ierm_size" "$ierm_actual" "$ierm_dir" || return 1
            if ! cmp -s "$ierm_expected" "$ierm_actual"; then
                log_fail "[I2C-EEPROM-MATRIX] case=$ierm_case offset=$((ierm_offset + ierm_relative)) length=$ierm_size data-mismatch expected=$ierm_expected actual=$ierm_actual"
                return 1
            fi
            ierm_digest=$(sha256sum "$ierm_actual") || return 1
            log_info "[I2C-EEPROM-MATRIX] case=$ierm_case offset=$((ierm_offset + ierm_relative)) bytes=$ierm_size sha256=${ierm_digest%% *} exact-match artifact=$ierm_actual"
        done
    done
}

# i2c_eeprom_read_after_idle <file> <client> <offset> <length> <result-dir>
# Observes natural runtime suspend on the client/controller path for at most
# ten seconds, then verifies a fresh identical read. No power/control writes.
# Returns 0 verified, 1 transfer failure, 2 no observable natural suspend.
i2c_eeprom_read_after_idle() {
    ierai_file="$1"
    ierai_client="$2"
    ierai_offset="$3"
    ierai_length="$4"
    ierai_dir="$5"
    i2c_eeprom_read_exact "$ierai_file" "$ierai_offset" "$ierai_length" "$ierai_dir/pm-before.bin" "$ierai_dir" || return 1
    ierai_attempt=0
    ierai_suspended=""
    while [ "$ierai_attempt" -lt 10 ]; do
        ierai_path="$ierai_client"
        while [ -n "$ierai_path" ] && [ "$ierai_path" != / ]; do
            if [ -r "$ierai_path/power/runtime_status" ]; then
                ierai_state=$(cat "$ierai_path/power/runtime_status") || return 1
                printf '%s\t%s\t%s\n' "$ierai_attempt" "$ierai_path" "$ierai_state" >>"$ierai_dir/i2c_runtime_pm.tsv" || return 1
                if [ "$ierai_state" = suspended ]; then
                    ierai_suspended="$ierai_path"
                    break
                fi
            fi
            ierai_path=${ierai_path%/*}
        done
        [ -z "$ierai_suspended" ] || break
        sleep 1
        ierai_attempt=$((ierai_attempt + 1))
    done
    if [ -z "$ierai_suspended" ]; then
        log_warn "[I2C-EEPROM-PM] no natural runtime suspend observed in 10 seconds, power policy unchanged"
        return 2
    fi
    i2c_eeprom_read_exact "$ierai_file" "$ierai_offset" "$ierai_length" "$ierai_dir/pm-after.bin" "$ierai_dir" || return 1
    if ! cmp -s "$ierai_dir/pm-before.bin" "$ierai_dir/pm-after.bin"; then
        log_fail "[I2C-EEPROM-PM] post-idle data mismatch expected=$ierai_dir/pm-before.bin actual=$ierai_dir/pm-after.bin"
        return 1
    fi
    ierai_after=$(cat "$ierai_suspended/power/runtime_status" 2>/dev/null || printf '%s' unavailable)
    log_info "[I2C-EEPROM-PM] suspended_object=$ierai_suspended subsequent_read=exact-match bytes=$ierai_length post_read_state=$ierai_after"
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
                    port|ctrl)
                        # serial-core exposes wrappers around the controller.
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

# uart_validate_bluetooth_transport <uart-dt-node> <result-dir>
# Correlates a Bluetooth serdev UART with HCI and runs a bounded control probe.
uart_validate_bluetooth_transport() {
    uvbt_uart_node="$1"
    uvbt_result_dir="$2"
    [ -n "$uvbt_uart_node" ] && [ -n "$uvbt_result_dir" ] || return 3

    uvbt_log="$uvbt_result_dir/uart_bluetooth_hci.log"
    uvbt_class_root="${UART_SYS_CLASS_BLUETOOTH_ROOT:-/sys/class/bluetooth}"
    uvbt_matches=0
    uvbt_failures=0
    : >>"$uvbt_log"

    log_info "[UART-BT] validation=starting uart_node=$uvbt_uart_node intent=correlate-serdev-to-HCI-and-run-bounded-control-probe"
    for uvbt_hci_path in "$uvbt_class_root"/hci*; do
        [ -e "$uvbt_hci_path/device" ] || continue
        uvbt_hci=$(basename "$uvbt_hci_path")
        uvbt_hci_node=$(bus_validation_of_node "$uvbt_hci_path/device" 2>/dev/null || true)
        case "$uvbt_hci_node" in
            "$uvbt_uart_node"|"$uvbt_uart_node"/*)
                ;;
            *)
                continue
                ;;
        esac

        uvbt_matches=$((uvbt_matches + 1))
        uvbt_device=$(readlink -f "$uvbt_hci_path/device" 2>/dev/null || true)
        uvbt_driver=$(bus_validation_ancestor_driver_name "$uvbt_hci_path/device" 2>/dev/null || true)
        uvbt_address=$(cat "$uvbt_hci_path/address" 2>/dev/null || printf '%s\n' unavailable)
        uvbt_name=$(cat "$uvbt_hci_path/name" 2>/dev/null || printf '%s\n' unavailable)
        uvbt_probe=none
        uvbt_probe_status=unavailable
        uvbt_probe_output="$uvbt_result_dir/uart_bluetooth_${uvbt_hci}_probe.log"
        : >"$uvbt_probe_output"

        if command -v btmgmt >/dev/null 2>&1; then
            uvbt_probe=btmgmt
            uvbt_index=${uvbt_hci#hci}
            if run_with_timeout 5 btmgmt --index "$uvbt_index" info >"$uvbt_probe_output" 2>&1 &&
               [ -s "$uvbt_probe_output" ]; then
                uvbt_probe_status=pass
            else
                uvbt_probe_status=fail
                uvbt_failures=$((uvbt_failures + 1))
            fi
        elif command -v hciconfig >/dev/null 2>&1; then
            uvbt_probe=hciconfig
            if run_with_timeout 5 hciconfig -a "$uvbt_hci" >"$uvbt_probe_output" 2>&1 &&
               [ -s "$uvbt_probe_output" ]; then
                uvbt_probe_status=pass
            else
                uvbt_probe_status=fail
                uvbt_failures=$((uvbt_failures + 1))
            fi
        elif command -v bluetoothctl >/dev/null 2>&1; then
            uvbt_probe=bluetoothctl
            if run_with_timeout 5 bluetoothctl show "$uvbt_address" >"$uvbt_probe_output" 2>&1 &&
               grep -q 'Controller' "$uvbt_probe_output"; then
                uvbt_probe_status=pass
            else
                uvbt_probe_status=diagnostic-unavailable
            fi
        fi

        printf 'uart_node=%s hci=%s device=%s driver=%s address=%s name=%s probe=%s status=%s artifact=%s\n' \
            "$uvbt_uart_node" "$uvbt_hci" "${uvbt_device:-unknown}" \
            "${uvbt_driver:-unbound}" "$uvbt_address" "$uvbt_name" \
            "$uvbt_probe" "$uvbt_probe_status" "$uvbt_probe_output" >>"$uvbt_log"

        case "$uvbt_probe_status" in
            pass)
                log_info "[UART-BT] uart_node=$uvbt_uart_node hci=$uvbt_hci driver=${uvbt_driver:-unbound} address=$uvbt_address probe=$uvbt_probe status=pass artifact=$uvbt_probe_output"
                ;;
            fail)
                log_fail "[UART-BT-FAIL] uart_node=$uvbt_uart_node hci=$uvbt_hci expected=successful-HCI-control-probe observed=$uvbt_probe-failed artifact=$uvbt_probe_output"
                ;;
            *)
                log_warn "[UART-BT] uart_node=$uvbt_uart_node hci=$uvbt_hci driver=${uvbt_driver:-unbound} address=$uvbt_address probe=$uvbt_probe status=$uvbt_probe_status kernel_transport=registered artifact=$uvbt_probe_output"
                ;;
        esac
    done

    if [ "$uvbt_matches" -eq 0 ]; then
        log_fail "[UART-BT-FAIL] uart_node=$uvbt_uart_node expected=HCI-adapter-for-bound-Bluetooth-serdev observed=none artifact=$uvbt_log"
        return 1
    fi
    [ "$uvbt_failures" -eq 0 ] || return 1
    return 0
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
    ucri_bt_transport_count=0

    printf 'kind\tobject\tdriver\tof_node\tconsumer\tdetails\n' >"$ucri_evidence"
    printf 'tty\tdriver\tof_node\tconsole\tdevice\n' >"$ucri_ttys"
    : >"$ucri_dt_nodes"
    : >"$ucri_registered_drivers"

    for ucri_serial_root in $ucri_serial_roots; do
        bus_validation_capture_driver_names "$ucri_serial_root/drivers" "$ucri_result_dir/uart_drivers_tmp.log" || true
        if [ -s "$ucri_result_dir/uart_drivers_tmp.log" ]; then
            cat "$ucri_result_dir/uart_drivers_tmp.log" >>"$ucri_registered_drivers"
        fi
    done
    if sort -u "$ucri_registered_drivers" >"$ucri_result_dir/uart_drivers_sorted.log"; then
        mv "$ucri_result_dir/uart_drivers_sorted.log" "$ucri_registered_drivers"
    else
        rm -f "$ucri_result_dir/uart_drivers_sorted.log"
    fi
    rm -f "$ucri_result_dir/uart_drivers_tmp.log"

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
        ucri_bluetooth_serdev=0
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
                                case "$ucri_serdev_driver:$ucri_serdev_name" in
                                    *hci*|*bluetooth*|*btqca*)
                                        ucri_bluetooth_serdev=1
                                        ;;
                                esac
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

        if [ "$ucri_bluetooth_serdev" -eq 1 ]; then
            if uart_validate_bluetooth_transport "$ucri_node" "$ucri_result_dir"; then
                ucri_bt_transport_count=$((ucri_bt_transport_count + 1))
            else
                ucri_failures=$((ucri_failures + 1))
            fi
        fi
    done <"$ucri_dt_nodes"

    log_info "UART runtime summary: dt_controllers=$ucri_dt_count physical_ttys=$ucri_runtime_count bluetooth_transports=$ucri_bt_transport_count failures=$ucri_failures artifact=$ucri_evidence"

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
    bus_validation_capture_driver_names "$ccri_spi_root/drivers" "$ccri_result_dir/can_spi_drivers_tmp.log" || true
    bus_validation_capture_driver_names "$ccri_platform_root/drivers" "$ccri_result_dir/can_platform_drivers_tmp.log" || true
    cat "$ccri_result_dir/can_spi_drivers_tmp.log" "$ccri_result_dir/can_platform_drivers_tmp.log" 2>/dev/null |
        sort -u >"$ccri_registered_drivers"
    rm -f "$ccri_result_dir/can_spi_drivers_tmp.log" "$ccri_result_dir/can_platform_drivers_tmp.log"

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
                ccri_ip_tmp="$ccri_result_dir/can_ip_${ccri_iface}_tmp.log"
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

    bisr_result_dir="$bisr_script_dir/results/$bisr_test_name/run-$(date '+%Y%m%d-%H%M%S')-$$"

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
        test_result_finish "FAIL" "$bisr_test_name FAIL: cannot create retained evidence directory $bisr_result_dir"
    fi

    log_info "--------------------------------------------------------------------------"
    log_info "Starting $bisr_test_name"
    log_info "Evidence directory: $bisr_result_dir"
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

# uart_loopback_list_devices
# Prints every runtime-discovered physical, accessible, unused non-console TTY.
uart_loopback_list_devices() {
    ulld_tty_root="${UART_SYS_CLASS_TTY_ROOT:-/sys/class/tty}"
    ulld_dev_root="${UART_DEV_ROOT:-/dev}"
    ulld_count=0

    [ -d "$ulld_tty_root" ] || return 2
    for ulld_tty_path in "$ulld_tty_root"/*; do
        [ -e "$ulld_tty_path/device" ] || continue
        ulld_tty=$(basename "$ulld_tty_path")
        ulld_device=$(readlink -f "$ulld_tty_path/device" 2>/dev/null || true)
        case "$ulld_device" in
            /sys/devices/virtual/*)
                continue
                ;;
        esac
        ulld_of_node=$(bus_validation_of_node "$ulld_tty_path/device" 2>/dev/null || true)
        [ -n "$ulld_of_node" ] || continue
        ulld_devnode="$ulld_dev_root/$ulld_tty"
        [ -c "$ulld_devnode" ] || continue
        if [ ! -r "$ulld_devnode" ] || [ ! -w "$ulld_devnode" ]; then
            continue
        fi
        uart_device_is_console "$ulld_tty" && continue
        if uart_loopback_device_use_reason "$ulld_devnode" >/dev/null 2>&1; then
            continue
        fi
        printf '%s\n' "$ulld_devnode"
        ulld_count=$((ulld_count + 1))
    done

    [ "$ulld_count" -gt 0 ] || return 2
    return 0
}

# uart_loopback_select_device
# Prints the unique eligible UART and rejects ambiguous multi-device selection.
uart_loopback_select_device() {
    ulsd_candidates=$(uart_loopback_list_devices)
    ulsd_status=$?
    [ "$ulsd_status" -eq 0 ] || return "$ulsd_status"

    ulsd_count=$(printf '%s\n' "$ulsd_candidates" | awk 'NF { count++ } END { print count + 0 }')
    [ "$ulsd_count" -eq 1 ] || return 1
    printf '%s\n' "$ulsd_candidates"
    return 0
}

# uart_loopback_report_candidates <output-file>
# Logs why each DT-backed physical TTY is eligible or rejected for loopback.
uart_loopback_report_candidates() {
    ulrc_output="$1"
    ulrc_tty_root="${UART_SYS_CLASS_TTY_ROOT:-/sys/class/tty}"
    ulrc_dev_root="${UART_DEV_ROOT:-/dev}"
    [ -n "$ulrc_output" ] || return 3

    printf 'tty\tdevnode\tdriver\tof_node\tconsole\taccess\towner\truntime_pm\teligible\n' >"$ulrc_output" || return 1
    [ -d "$ulrc_tty_root" ] || return 2

    for ulrc_tty_path in "$ulrc_tty_root"/*; do
        [ -e "$ulrc_tty_path/device" ] || continue
        ulrc_tty=$(basename "$ulrc_tty_path")
        ulrc_device=$(readlink -f "$ulrc_tty_path/device" 2>/dev/null || true)
        case "$ulrc_device" in
            /sys/devices/virtual/*)
                continue
                ;;
        esac
        ulrc_of_node=$(bus_validation_of_node "$ulrc_tty_path/device" 2>/dev/null || true)
        [ -n "$ulrc_of_node" ] || continue
        ulrc_driver=$(bus_validation_ancestor_driver_name "$ulrc_tty_path/device" 2>/dev/null || true)
        ulrc_devnode="$ulrc_dev_root/$ulrc_tty"
        ulrc_console=no
        uart_device_is_console "$ulrc_tty" && ulrc_console=yes
        ulrc_access=unavailable
        if [ -c "$ulrc_devnode" ] && [ -r "$ulrc_devnode" ] && [ -w "$ulrc_devnode" ]; then
            ulrc_access=read-write
        fi
        ulrc_owner=$(uart_loopback_device_use_reason "$ulrc_devnode" 2>/dev/null || true)
        [ -n "$ulrc_owner" ] || ulrc_owner=none
        ulrc_runtime_pm=$(cat "$ulrc_tty_path/device/power/runtime_status" 2>/dev/null || printf '%s\n' unavailable)
        ulrc_eligible=yes
        if [ "$ulrc_console" = yes ]; then
            ulrc_eligible=no-console
        elif [ "$ulrc_access" != read-write ]; then
            ulrc_eligible=no-access
        elif [ "$ulrc_owner" != none ]; then
            ulrc_eligible=no-active-owner
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ulrc_tty" "$ulrc_devnode" "${ulrc_driver:-unbound}" "$ulrc_of_node" \
            "$ulrc_console" "$ulrc_access" "$ulrc_owner" "$ulrc_runtime_pm" \
            "$ulrc_eligible" >>"$ulrc_output"
        log_info "[UART-DISCOVERY] device=$ulrc_devnode driver=${ulrc_driver:-unbound} console=$ulrc_console access=$ulrc_access owner=$ulrc_owner runtime_pm=$ulrc_runtime_pm eligible=$ulrc_eligible of_node=$ulrc_of_node"
    done

    return 0
}

# uart_loopback_capture_failure_diagnostics <device> <result-dir> <case-id>
# Retains bounded UART, Bluetooth-topology, rfkill, and kernel-error evidence.
uart_loopback_capture_failure_diagnostics() {
    ulfd_device="$1"
    ulfd_result_dir="$2"
    ulfd_case="$3"
    [ -n "$ulfd_device" ] && [ -n "$ulfd_result_dir" ] && [ -n "$ulfd_case" ] || return 3

    mkdir -p "$ulfd_result_dir" || return 1
    ulfd_tty=$(basename "$ulfd_device")
    ulfd_tty_path="${UART_SYS_CLASS_TTY_ROOT:-/sys/class/tty}/$ulfd_tty"
    ulfd_output="$ulfd_result_dir/uart_failure_${ulfd_case}.log"
    ulfd_bt_class_root="${UART_SYS_CLASS_BLUETOOTH_ROOT:-/sys/class/bluetooth}"
    ulfd_rfkill_class_root="${UART_SYS_CLASS_RFKILL_ROOT:-/sys/class/rfkill}"
    ulfd_sysfs_device=$(readlink -f "$ulfd_tty_path/device" 2>/dev/null || true)
    ulfd_of_node=$(bus_validation_of_node "$ulfd_tty_path/device" 2>/dev/null || true)
    ulfd_driver=$(bus_validation_ancestor_driver_name "$ulfd_tty_path/device" 2>/dev/null || true)
    ulfd_runtime_pm=$(cat "$ulfd_tty_path/device/power/runtime_status" 2>/dev/null || printf '%s\n' unavailable)
    ulfd_owner=$(uart_loopback_device_use_reason "$ulfd_device" 2>/dev/null || true)
    [ -n "$ulfd_owner" ] || ulfd_owner=none
    ulfd_console=no
    uart_device_is_console "$ulfd_tty" && ulfd_console=yes

    printf 'device=%s\nsysfs_device=%s\ndriver=%s\nof_node=%s\nconsole=%s\nowner=%s\nruntime_pm=%s\n' \
        "$ulfd_device" "${ulfd_sysfs_device:-unknown}" "${ulfd_driver:-unbound}" \
        "${ulfd_of_node:-unknown}" "$ulfd_console" "$ulfd_owner" \
        "$ulfd_runtime_pm" >"$ulfd_output"
    log_info "[UART-DIAG] device=$ulfd_device driver=${ulfd_driver:-unbound} console=$ulfd_console owner=$ulfd_owner runtime_pm=$ulfd_runtime_pm of_node=${ulfd_of_node:-unknown} artifact=$ulfd_output"

    ulfd_bt_count=0
    ulfd_bt_related=0
    for ulfd_hci in "$ulfd_bt_class_root"/hci*; do
        [ -e "$ulfd_hci/device" ] || continue
        ulfd_bt_count=$((ulfd_bt_count + 1))
        ulfd_hci_device=$(readlink -f "$ulfd_hci/device" 2>/dev/null || true)
        ulfd_hci_node=$(bus_validation_of_node "$ulfd_hci/device" 2>/dev/null || true)
        ulfd_hci_driver=$(bus_validation_ancestor_driver_name "$ulfd_hci/device" 2>/dev/null || true)
        ulfd_relation=distinct
        case "$ulfd_hci_node" in
            "$ulfd_of_node"|"$ulfd_of_node"/*)
                if [ -n "$ulfd_of_node" ]; then
                    ulfd_relation=same-uart-controller
                    ulfd_bt_related=1
                fi
                ;;
        esac
        printf 'bluetooth=%s device=%s driver=%s of_node=%s relation=%s\n' \
            "$(basename "$ulfd_hci")" "${ulfd_hci_device:-unknown}" \
            "${ulfd_hci_driver:-unbound}" "${ulfd_hci_node:-unknown}" \
            "$ulfd_relation" >>"$ulfd_output"
        log_info "[UART-BLUETOOTH] adapter=$(basename "$ulfd_hci") driver=${ulfd_hci_driver:-unbound} relation=$ulfd_relation of_node=${ulfd_hci_node:-unknown}"
    done

    ulfd_rfkill_count=0
    for ulfd_rfkill in "$ulfd_rfkill_class_root"/rfkill*; do
        [ -r "$ulfd_rfkill/type" ] || continue
        ulfd_rfkill_type=$(tr -d '[:space:]' <"$ulfd_rfkill/type")
        [ "$ulfd_rfkill_type" = bluetooth ] || continue
        ulfd_rfkill_count=$((ulfd_rfkill_count + 1))
        ulfd_rfkill_soft=$(cat "$ulfd_rfkill/soft" 2>/dev/null || printf '%s\n' unavailable)
        ulfd_rfkill_hard=$(cat "$ulfd_rfkill/hard" 2>/dev/null || printf '%s\n' unavailable)
        printf 'rfkill=%s soft=%s hard=%s\n' \
            "$(basename "$ulfd_rfkill")" "$ulfd_rfkill_soft" "$ulfd_rfkill_hard" >>"$ulfd_output"
        log_info "[UART-BLUETOOTH] rfkill=$(basename "$ulfd_rfkill") soft=$ulfd_rfkill_soft hard=$ulfd_rfkill_hard"
    done

    if [ "$ulfd_bt_related" -eq 1 ]; then
        log_warn "[UART-RECOVERY] Bluetooth shares the selected UART controller, automatic disable is refused because the port ownership and restoration contract is not safe"
    elif [ "$ulfd_bt_count" -gt 0 ] || [ "$ulfd_rfkill_count" -gt 0 ]; then
        log_info "[UART-RECOVERY] Bluetooth runtime evidence is present on a distinct controller, action=none reason=not-related-to-selected-uart"
    else
        log_info "[UART-RECOVERY] Bluetooth runtime evidence is absent, action=none reason=not-applicable"
    fi

    ulfd_kernel_dir="$ulfd_result_dir/kernel"
    mkdir -p "$ulfd_kernel_dir" || return 1
    scan_dmesg_errors \
        "$ulfd_kernel_dir" \
        'qcom_geni_serial|msm_serial|uart|serial|tty|hci_uart|bluetooth|btqca|qca' \
        'dummy regulator|supply [^ ]+ not found|using dummy regulator' || true
    log_info "[UART-DIAG] kernel evidence retained under $ulfd_kernel_dir"
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
UART_LOOPBACK_LOG=""

# uart_loopback_log_payload <direction> <payload-file>
# Logs bounded payload proof while retaining the complete payload artifact.
uart_loopback_log_payload() {
    ullp_direction="$1"
    ullp_file="$2"
    [ -n "$ullp_direction" ] && [ -r "$ullp_file" ] || return 3

    ullp_bytes=$(wc -c <"$ullp_file" 2>/dev/null | tr -d '[:space:]')
    ullp_checksum=$(cksum "$ullp_file" 2>/dev/null | awk '{ print $1 }')
    ullp_preview=$(od -An -N 32 -v -tx1 "$ullp_file" 2>/dev/null | tr -d ' \n')
    ullp_preview_bytes="${ullp_bytes:-0}"
    if [ "$ullp_preview_bytes" -gt 32 ] 2>/dev/null; then
        ullp_preview_bytes=32
    fi
    log_info "[UART-PAYLOAD] direction=$ullp_direction bytes=${ullp_bytes:-0} cksum=${ullp_checksum:-unavailable} preview_hex=${ullp_preview:-empty} preview_bytes=$ullp_preview_bytes artifact=$ullp_file"
    return 0
}

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
        if ulc_restore_error=$(stty -F "$UART_LOOPBACK_DEVICE" "$UART_LOOPBACK_STATE" 2>&1); then
            log_info "[UART-RESTORE] device=$UART_LOOPBACK_DEVICE state=restored"
        else
            ulc_current_state=$(stty -F "$UART_LOOPBACK_DEVICE" -g 2>/dev/null || true)
            if [ -n "$UART_LOOPBACK_LOG" ]; then
                printf '%s\n' "$ulc_restore_error" >>"$UART_LOOPBACK_LOG"
            fi
            ulc_restore_error=$(printf '%s' "$ulc_restore_error" | tr '\n' ' ')
            if [ "$ulc_current_state" = "$UART_LOOPBACK_STATE" ]; then
                log_warn "[UART-RESTORE] device=$UART_LOOPBACK_DEVICE state=verified-restored stty_status=nonzero stty_error=${ulc_restore_error:-none}"
            else
                log_fail "[UART-RESTORE] device=$UART_LOOPBACK_DEVICE expected_state=$UART_LOOPBACK_STATE observed_state=${ulc_current_state:-unavailable} observed=restore-failed stty_error=${ulc_restore_error:-none}"
                ulc_status=1
            fi
        fi
    fi

    UART_LOOPBACK_DEVICE=""
    UART_LOOPBACK_STATE=""
    UART_LOOPBACK_LOG=""
    return "$ulc_status"
}

# uart_loopback_validate <device> <baud> <timeout-seconds> <result-dir> [payload-bytes] [data-bits] [flow-control] [loopback-type] [internal-helper]
# Runs exact-payload internal or external loopback on a selected non-console TTY.
uart_loopback_validate() {
    ulv_device="$1"
    ulv_baud="$2"
    ulv_timeout="$3"
    ulv_result_dir="$4"
    ulv_payload_bytes="${5:-4096}"
    ulv_data_bits="${6:-8}"
    ulv_flow_control="${7:-none}"
    ulv_loopback_type="${8:-external}"
    ulv_internal_helper="${9:-}"
    [ -n "$ulv_device" ] && [ -n "$ulv_baud" ] && [ -n "$ulv_timeout" ] && [ -n "$ulv_result_dir" ] || return 3

    case "$ulv_baud:$ulv_timeout:$ulv_payload_bytes" in
        *[!0-9:]*|:*|*:)
            return 3
            ;;
    esac
    case "$ulv_data_bits" in
        5|6|7|8)
            ;;
        *)
            return 3
            ;;
    esac
    case "$ulv_flow_control" in
        none)
            ulv_flow_flag="-crtscts"
            ;;
        rtscts)
            ulv_flow_flag="crtscts"
            ;;
        *)
            return 3
            ;;
    esac
    case "$ulv_loopback_type" in
        internal)
            [ -n "$ulv_internal_helper" ] && [ -r "$ulv_internal_helper" ] || return 3
            ;;
        external)
            ;;
        *)
            return 3
            ;;
    esac

    mkdir -p "$ulv_result_dir" || return 1
    ulv_case="${ulv_baud}_${ulv_data_bits}bit_${ulv_flow_control}_${ulv_loopback_type}"
    ulv_log="$ulv_result_dir/uart_loopback_${ulv_case}.log"
    ulv_tx="$ulv_result_dir/uart_loopback_${ulv_case}_tx.bin"
    ulv_rx="$ulv_result_dir/uart_loopback_${ulv_case}_rx.bin"
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
        log_info "[UART-LOOPBACK] device=$ulv_device state=not-runnable reason=kernel-console action=refused"
        return 2
    fi
    ulv_use_reason=$(uart_loopback_device_use_reason "$ulv_device" 2>/dev/null || true)
    if [ -n "$ulv_use_reason" ]; then
        log_info "[UART-LOOPBACK] device=$ulv_device state=not-runnable reason=active-terminal-or-userspace-owner owner=$ulv_use_reason action=refused"
        return 2
    fi

    UART_LOOPBACK_DEVICE="$ulv_device"
    UART_LOOPBACK_LOG="$ulv_log"
    UART_LOOPBACK_STATE=$(stty -F "$ulv_device" -g 2>/dev/null || true)
    if [ -z "$UART_LOOPBACK_STATE" ]; then
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=readable-termios-state observed=unavailable artifact=$ulv_log"
        UART_LOOPBACK_DEVICE=""
        return 1
    fi
    log_info "[UART-STATE] device=$ulv_device phase=pre-config termios=snapshot-captured"

    ulv_controller_loopback=not-requested
    if [ "$ulv_loopback_type" = internal ]; then
        ulv_controller_loopback=requested
        log_info "[UART-STATE] device=$ulv_device phase=configuration-pending owner=internal-helper baud=$ulv_baud format=${ulv_data_bits}N1 flow_control=$ulv_flow_control controller_loopback=$ulv_controller_loopback"
    else
        if ! stty -F "$ulv_device" "$ulv_baud" raw -echo "cs$ulv_data_bits" \
            -cstopb -parenb -ixon -ixoff "$ulv_flow_flag" clocal cread 2>>"$ulv_log"; then
            log_fail "[UART-LOOPBACK] device=$ulv_device expected=termios-configuration observed=stty-failed baud=$ulv_baud data_bits=$ulv_data_bits flow_control=$ulv_flow_control artifact=$ulv_log"
            uart_loopback_cleanup || true
            return 1
        fi
        log_info "[UART-STATE] device=$ulv_device phase=configured baud=$ulv_baud format=${ulv_data_bits}N1 flow_control=$ulv_flow_control controller_loopback=$ulv_controller_loopback"
    fi

    case "$ulv_data_bits" in
        5)
            ulv_character_range=31
            ;;
        6)
            ulv_character_range=63
            ;;
        7)
            ulv_character_range=127
            ;;
        8)
            ulv_character_range=0
            ;;
    esac
    ulv_generation_failed=0
    if [ "$ulv_character_range" -eq 0 ]; then
        LC_ALL=C awk -v bytes="$ulv_payload_bytes" '
            BEGIN {
                pattern = "QLI_UART_"
                for (i = 0; i < bytes; i++) {
                    printf "%s", substr(pattern, (i % length(pattern)) + 1, 1)
                }
            }
        ' >"$ulv_tx" || ulv_generation_failed=1
    else
        LC_ALL=C awk -v bytes="$ulv_payload_bytes" -v range="$ulv_character_range" '
            BEGIN {
                for (i = 0; i < bytes; i++) {
                    printf "%c", 1 + (i % range)
                }
            }
        ' >"$ulv_tx" || ulv_generation_failed=1
    fi
    if [ "$ulv_generation_failed" -ne 0 ]; then
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=generated-$ulv_payload_bytes-byte-payload observed=generation-failed artifact=$ulv_log"
        uart_loopback_cleanup || true
        return 1
    fi
    ulv_length=$(wc -c <"$ulv_tx" | tr -d '[:space:]')
    uart_loopback_log_payload tx "$ulv_tx" || true
    printf 'device=%s\nloopback=%s\nbaud=%s\ndata_bits=%s\nflow_control=%s\ntimeout=%s\npayload_bytes=%s\n' \
        "$ulv_device" "$ulv_loopback_type" "$ulv_baud" "$ulv_data_bits" "$ulv_flow_control" \
        "$ulv_timeout" "$ulv_length" >>"$ulv_log"
    stty -F "$ulv_device" -a >>"$ulv_log" 2>&1 || true

    if [ "$ulv_loopback_type" = internal ]; then
        ulv_internal_log="$ulv_result_dir/uart_internal_${ulv_case}.log"
        ulv_outer_timeout=$((ulv_timeout + 5))
        log_info "[UART-INTERNAL] device=$ulv_device phase=enable-request ioctl=TIOCM_LOOP timeout=${ulv_timeout}s artifact=$ulv_internal_log"
        run_with_timeout "$ulv_outer_timeout" \
            python3 "$ulv_internal_helper" \
            --device "$ulv_device" \
            --tx-file "$ulv_tx" \
            --rx-file "$ulv_rx" \
            --timeout "$ulv_timeout" \
            --baud "$ulv_baud" \
            --data-bits "$ulv_data_bits" \
            --flow-control "$ulv_flow_control" >"$ulv_internal_log" 2>&1
        ulv_internal_status=$?
        log_file_with_label "UART-INTERNAL" "$ulv_internal_log"
        case "$ulv_internal_status" in
            0)
                ;;
            2)
                log_info "[UART-LOOPBACK] device=$ulv_device state=not-runnable reason=internal-loopback-unsupported action=skipped artifact=$ulv_internal_log"
                if ! uart_loopback_cleanup; then
                    return 1
                fi
                return 2
                ;;
            *)
                log_fail "[UART-LOOPBACK] device=$ulv_device expected=verified-TIOCM_LOOP-transfer observed=internal-helper-failed status=$ulv_internal_status artifact=$ulv_internal_log"
                uart_loopback_cleanup || true
                return 1
                ;;
        esac
    else
        dd if="$ulv_device" of="$ulv_rx" bs=1 count="$ulv_length" >>"$ulv_log" 2>&1 &
        UART_LOOPBACK_READER_PID=$!
        log_info "[UART-IO] device=$ulv_device phase=reader-started pid=$UART_LOOPBACK_READER_PID expected_bytes=$ulv_length timeout=${ulv_timeout}s"
        (
            sleep "$ulv_timeout"
            kill "$UART_LOOPBACK_READER_PID" 2>/dev/null || true
        ) &
        UART_LOOPBACK_WATCHER_PID=$!
        sleep 1

        # shellcheck disable=SC2016
        if ! run_with_timeout "$ulv_timeout" sh -c 'dd if="$1" of="$2" bs=4096' sh "$ulv_tx" "$ulv_device" >>"$ulv_log" 2>&1; then
            uart_loopback_log_payload rx "$ulv_rx" || true
            log_fail "[UART-LOOPBACK] device=$ulv_device expected=bounded-write observed=write-failed-or-timeout artifact=$ulv_log"
            uart_loopback_cleanup || true
            return 1
        fi
        log_info "[UART-IO] device=$ulv_device phase=write-complete bytes=$ulv_length"

        if ! wait "$UART_LOOPBACK_READER_PID"; then
            UART_LOOPBACK_READER_PID=""
            ulv_received_bytes=$(wc -c <"$ulv_rx" 2>/dev/null | tr -d '[:space:]')
            uart_loopback_log_payload rx "$ulv_rx" || true
            log_fail "[UART-LOOPBACK] device=$ulv_device expected=${ulv_length}-received-bytes observed=reader-failed-or-timeout received_bytes=${ulv_received_bytes:-0} fixture=external-tx-rx-loopback-not-observed artifact=$ulv_log"
            uart_loopback_cleanup || true
            return 1
        fi
        UART_LOOPBACK_READER_PID=""
        kill "$UART_LOOPBACK_WATCHER_PID" 2>/dev/null || true
        wait "$UART_LOOPBACK_WATCHER_PID" 2>/dev/null || true
        UART_LOOPBACK_WATCHER_PID=""
        ulv_received_bytes=$(wc -c <"$ulv_rx" 2>/dev/null | tr -d '[:space:]')
        log_info "[UART-IO] device=$ulv_device phase=read-complete expected_bytes=$ulv_length received_bytes=${ulv_received_bytes:-0}"
    fi

    uart_loopback_log_payload rx "$ulv_rx" || true

    if ! cmp -s "$ulv_tx" "$ulv_rx"; then
        ulv_first_mismatch=$(cmp -l "$ulv_tx" "$ulv_rx" 2>/dev/null | awk 'NR == 1 { printf "offset=%s expected_octal=%s observed_octal=%s", $1, $2, $3; exit }')
        log_fail "[UART-LOOPBACK] device=$ulv_device expected=byte-for-byte-match observed=mismatch first_difference=${ulv_first_mismatch:-size-or-content-mismatch} tx_artifact=$ulv_tx rx_artifact=$ulv_rx"
        uart_loopback_cleanup || true
        return 1
    fi
    log_info "[UART-PROOF] device=$ulv_device comparison=byte-for-byte result=match bytes=$ulv_length tx_artifact=$ulv_tx rx_artifact=$ulv_rx"

    if ! uart_loopback_cleanup; then
        return 1
    fi

    log_info "[UART-LOOPBACK] device=$ulv_device loopback=$ulv_loopback_type baud=$ulv_baud bytes=$ulv_length format=${ulv_data_bits}N1 flow_control=$ulv_flow_control payload=verified artifact=$ulv_log"
    return 0
}

# spi_loopback_list_devices
# Prints every accessible image-provided spidev character device.
spi_loopback_list_devices() {
    slld_dev_root="${SPI_DEV_ROOT:-/dev}"
    slld_count=0

    for slld_device in "$slld_dev_root"/spidev*; do
        [ -c "$slld_device" ] || continue
        if [ ! -r "$slld_device" ] || [ ! -w "$slld_device" ]; then
            continue
        fi
        printf '%s\n' "$slld_device"
        slld_count=$((slld_count + 1))
    done

    [ "$slld_count" -gt 0 ] || return 2
    return 0
}

# spi_loopback_select_device
# Prints the unique accessible spidev device and rejects ambiguous selection.
spi_loopback_select_device() {
    slsd_candidates=$(spi_loopback_list_devices)
    slsd_status=$?
    [ "$slsd_status" -eq 0 ] || return "$slsd_status"

    slsd_count=$(printf '%s\n' "$slsd_candidates" | awk 'NF { count++ } END { print count + 0 }')
    [ "$slsd_count" -eq 1 ] || return 1
    printf '%s\n' "$slsd_candidates"
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

# can_internal_loopback_list_interfaces <auto|classic|fd>
# Prints every down physical CAN interface that may be configured safely.
can_internal_loopback_list_interfaces() {
    cilli_mode="$1"
    cilli_net_root="${CAN_SYS_CLASS_NET_ROOT:-/sys/class/net}"
    cilli_count=0
    [ "$cilli_mode" = "auto" ] || [ "$cilli_mode" = "classic" ] || [ "$cilli_mode" = "fd" ] || return 3
    [ -d "$cilli_net_root" ] || return 2

    for cilli_path in "$cilli_net_root"/*; do
        cilli_interface=$(basename "$cilli_path")
        can_internal_loopback_interface_is_ready "$cilli_interface" || continue
        printf '%s\n' "$cilli_interface"
        cilli_count=$((cilli_count + 1))
    done

    [ "$cilli_count" -gt 0 ] || return 2
    return 0
}

# can_internal_loopback_select_interface <auto|classic|fd>
# Prints the unique eligible CAN interface and rejects ambiguous selection.
can_internal_loopback_select_interface() {
    cilsi_candidates=$(can_internal_loopback_list_interfaces "$1")
    cilsi_status=$?
    [ "$cilsi_status" -eq 0 ] || return "$cilsi_status"

    cilsi_count=$(printf '%s\n' "$cilsi_candidates" | awk 'NF { count++ } END { print count + 0 }')
    [ "$cilsi_count" -eq 1 ] || return 1
    printf '%s\n' "$cilsi_candidates"
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
