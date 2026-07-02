#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Common performance-related helpers for KPI-style tests.

# ---------------------------------------------------------------------------
# Logging fallback (avoid repeated command -v checks)
# If functestlib.sh is sourced, these are already defined and we do nothing.
# ---------------------------------------------------------------------------
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${log_fail:=:}"
: "${log_skip:=:}"
: "${log_pass:=:}"

# ---------------------------------------------------------------------------
# Generic timestamp + escaping
# ---------------------------------------------------------------------------

nowstamp() {
    date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s
}

# Basic JSON string escaper (used by KPI tests)
esc() {
    # Escape backslash and double-quote
    printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'
}

# ---------------------------------------------------------------------------
# CPU governor helpers
# ---------------------------------------------------------------------------

# Put all CPUs into performance governor, saving previous governor for restore.
# Uses SAVED_GOV_FILE (auto set if not provided).
set_performance_governor() {
    SAVED_GOV_FILE="${SAVED_GOV_FILE:-/tmp/perf_saved_governors.$$}"
    : >"$SAVED_GOV_FILE" 2>/dev/null || return 0

    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$c" ] || continue
        gov_file="$c/cpufreq/scaling_governor"
        [ -f "$gov_file" ] || continue

        cur_gov=$(cat "$gov_file" 2>/dev/null || echo "")
        # Record current governor
        printf '%s:%s\n' "$gov_file" "$cur_gov" >>"$SAVED_GOV_FILE" 2>/dev/null || true

        # Try to set performance, but do not fail test if it does not exist
        echo performance >"$gov_file" 2>/dev/null || true
    done

    log_info "CPU governors set to performance (saved in $SAVED_GOV_FILE)"
}

# Restore governors from the temp file created by set_performance_governor()
restore_governor() {
    if [ -z "${SAVED_GOV_FILE:-}" ]; then
        return 0
    fi
    if [ ! -f "$SAVED_GOV_FILE" ]; then
        return 0
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        gov_file=${line%%:*}
        old_gov=${line#*:}
        [ -f "$gov_file" ] || continue
        [ -n "$old_gov" ] || continue
        echo "$old_gov" >"$gov_file" 2>/dev/null || true
    done <"$SAVED_GOV_FILE"

    rm -f "$SAVED_GOV_FILE" 2>/dev/null || true

    log_info "Restored original CPU governors from saved state"
}

# ---------------------------------------------------------------------------
# Clocksource
# ---------------------------------------------------------------------------

# Capture the current clocksource into a text file.
# Usage: capture_clocksource /path/to/file
capture_clocksource() {
    out_file=$1
    [ -n "$out_file" ] || out_file="./clocksource.txt"

    if [ -r /sys/devices/system/clocksource/clocksource0/current_clocksource ]; then
        cs=$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null || echo "unknown")
        {
            echo "timestamp=$(nowstamp)"
            echo "clocksource=$cs"
        } >"$out_file" 2>/dev/null || true

        log_info "Clocksource: $cs → $out_file"
    else
        log_warn "current_clocksource not available; skipping clocksource capture"
    fi
}

# ---------------------------------------------------------------------------
# Boot type tag
# ---------------------------------------------------------------------------

# Capture boot type tag (cold/warm/unknown) into a text file.
# Usage: capture_boot_type <tag> <file>
capture_boot_type() {
    tag=$1
    out_file=$2

    [ -n "$tag" ] || tag="unknown"
    [ -n "$out_file" ] || out_file="./boot_type.txt"

    {
        echo "timestamp=$(nowstamp)"
        echo "boot_type=$tag"
    } >"$out_file" 2>/dev/null || true

    log_info "Boot type tagged as '$tag' → $out_file"
}

# ---------------------------------------------------------------------------
# System services / “heavy” log producers
# ---------------------------------------------------------------------------

# Optionally disable heavy services for KPI runs.
# Usage: disable_heavy_services_if_requested <disable_getty_flag> <disable_sshd_flag>
# Flags are "1" to disable, anything else to leave alone.
disable_heavy_services_if_requested() {
    disable_getty=$1
    disable_sshd=$2

    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl not found; cannot apply getty/sshd KPI tweaks"
        return 0
    fi

    if [ "$disable_getty" = "1" ]; then
        systemctl disable serial-getty@ttyS0.service >/dev/null 2>&1 || true
        systemctl stop serial-getty@ttyS0.service >/dev/null 2>&1 || true
        log_info "Disabled serial-getty@ttyS0.service for KPI run"
    fi

    if [ "$disable_sshd" = "1" ]; then
        systemctl disable sshd.service >/dev/null 2>&1 || true
        systemctl stop sshd.service >/dev/null 2>&1 || true
        log_info "Disabled sshd.service for KPI run"
    fi
}

# ---------------------------------------------------------------------------
# Bootchart
# ---------------------------------------------------------------------------

# Check if systemd-bootchart is enabled via kernel cmdline.
# Returns 0 if init=/lib/systemd/systemd-bootchart is present.
bootchart_enabled() {
    if [ -r /proc/cmdline ]; then
        grep -qw 'init=/lib/systemd/systemd-bootchart' /proc/cmdline 2>/dev/null
        return $?
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Boot KPI helpers: systemd-analyze time parsing + UEFI loader times + networkd
# ---------------------------------------------------------------------------

# Convert a single duration token like "3.801s", "174ms", "2min" to seconds.
perf_time_token_to_sec() {
  token="$1"
  [ -n "$token" ] || { echo ""; return 0; }

  printf '%s\n' "$token" | awk '
    {
      v = $1
      if (v ~ /min/) {
        gsub(/[^0-9.]/, "", v)
        if (v == "") { print ""; exit }
        s = v * 60
      } else if (v ~ /ms$/) {
        gsub(/[^0-9.]/, "", v)
        if (v == "") { print ""; exit }
        s = v / 1000.0
      } else if (v ~ /s$/) {
        gsub(/[^0-9.]/, "", v)
        if (v == "") { print ""; exit }
        s = v
      } else {
        s = 0
      }
    }
    END {
      if (s > 0) {
        printf("%.3f\n", s)
      }
    }'
}

# Convert a segment like "2min 7.045s" or "187ms" to seconds.
perf_time_segment_to_sec() {
  seg="$1"
  [ -n "$seg" ] || { echo ""; return 0; }

  printf '%s\n' "$seg" | awk '
    {
      sec = 0
      for (i = 1; i <= NF; i++) {
        v = $i
        if (v ~ /min/) {
          gsub(/[^0-9.]/, "", v)
          if (v != "") sec += v * 60
        } else if (v ~ /ms$/) {
          gsub(/[^0-9.]/, "", v)
          if (v != "") sec += v / 1000.0
        } else if (v ~ /s$/) {
          gsub(/[^0-9.]/, "", v)
          if (v != "") sec += v
        }
      }
    }
    END {
      if (sec > 0) {
        printf("%.3f\n", sec)
      }
    }'
}

# Read UEFI loader times from efivars (if present)
# Sets:
# PERF_UEFI_INIT_SEC, PERF_UEFI_EXEC_SEC, PERF_UEFI_TOTAL_SEC
perf_read_uefi_loader_times() {
  base="/sys/firmware/efi/efivars"
  init_var="$base/LoaderTimeInitUSec-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
  exec_var="$base/LoaderTimeExecUSec-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"

  PERF_UEFI_INIT_SEC=""
  PERF_UEFI_EXEC_SEC=""
  PERF_UEFI_TOTAL_SEC=""

  if [ ! -r "$init_var" ] || [ ! -r "$exec_var" ]; then
    export PERF_UEFI_INIT_SEC PERF_UEFI_EXEC_SEC PERF_UEFI_TOTAL_SEC
    return 0
  fi

  init_us=$(tail -c 8 "$init_var" 2>/dev/null | od -An -t u8 2>/dev/null | awk '{print $1}')
  exec_us=$(tail -c 8 "$exec_var" 2>/dev/null | od -An -t u8 2>/dev/null | awk '{print $1}')

  if [ -n "$init_us" ] && [ -n "$exec_us" ]; then
    PERF_UEFI_INIT_SEC=$(printf '%s\n' "$init_us" | awk '{printf("%.3f", $1/1000000)}')
    PERF_UEFI_EXEC_SEC=$(printf '%s\n' "$exec_us" | awk '{printf("%.3f", $1/1000000)}')
    PERF_UEFI_TOTAL_SEC=$(printf '%s %s\n' "$PERF_UEFI_INIT_SEC" "$PERF_UEFI_EXEC_SEC" \
      | awk '{printf("%.3f", $1 + $2)}')
  fi

  export PERF_UEFI_INIT_SEC PERF_UEFI_EXEC_SEC PERF_UEFI_TOTAL_SEC
}

# Parse systemd-analyze time output + blame, and optionally exclude services.
#
# perf_parse_boot_times <analyze_time.txt> <blame.txt> <exclude_networkd_flag> <exclude_services_list>
#
# Sets:
# PERF_FIRMWARE_SEC
# PERF_LOADER_SEC
# PERF_KERNEL_SEC
# PERF_USERSPACE_SEC
# PERF_TOTAL_SEC
# PERF_NETWORKD_WAIT_ONLINE_SEC
# PERF_EXCLUDED_SERVICES_LIST
# PERF_EXCLUDED_SERVICES_SEC
# PERF_EXCLUDED_TOTAL_SEC
# PERF_USERSPACE_EFFECTIVE_SEC
# PERF_TOTAL_EFFECTIVE_SEC
perf_parse_boot_times() {
  at_file="$1"
  blame_file="$2"
  exclude_networkd="$3"
  exclude_services_raw="$4"

  PERF_FIRMWARE_SEC=""
  PERF_LOADER_SEC=""
  PERF_KERNEL_SEC=""
  PERF_USERSPACE_SEC=""
  PERF_TOTAL_SEC=""
  PERF_NETWORKD_WAIT_ONLINE_SEC=""
  PERF_EXCLUDED_SERVICES_LIST=""
  PERF_EXCLUDED_SERVICES_SEC=""
  PERF_EXCLUDED_TOTAL_SEC=""
  PERF_USERSPACE_EFFECTIVE_SEC=""
  PERF_TOTAL_EFFECTIVE_SEC=""

  if [ ! -f "$at_file" ]; then
    export PERF_FIRMWARE_SEC PERF_LOADER_SEC PERF_KERNEL_SEC PERF_USERSPACE_SEC PERF_TOTAL_SEC \
           PERF_NETWORKD_WAIT_ONLINE_SEC PERF_EXCLUDED_SERVICES_LIST PERF_EXCLUDED_SERVICES_SEC \
           PERF_EXCLUDED_TOTAL_SEC PERF_USERSPACE_EFFECTIVE_SEC PERF_TOTAL_EFFECTIVE_SEC
    return 0
  fi

  line=$(grep -m1 'Startup finished in' "$at_file" 2>/dev/null || true)
  if [ -z "$line" ]; then
    export PERF_FIRMWARE_SEC PERF_LOADER_SEC PERF_KERNEL_SEC PERF_USERSPACE_SEC PERF_TOTAL_SEC \
           PERF_NETWORKD_WAIT_ONLINE_SEC PERF_EXCLUDED_SERVICES_LIST PERF_EXCLUDED_SERVICES_SEC \
           PERF_EXCLUDED_TOTAL_SEC PERF_USERSPACE_EFFECTIVE_SEC PERF_TOTAL_EFFECTIVE_SEC
    return 0
  fi

  firmware_tok=$(printf '%s\n' "$line" \
    | sed -n 's/.*Startup finished in \([^ ]*\) (firmware).*/\1/p')
  loader_tok=$(printf '%s\n' "$line" \
    | sed -n 's/.*(firmware) + \([^ ]*\) (loader).*/\1/p')
  kernel_tok=$(printf '%s\n' "$line" \
    | sed -n 's/.*(loader) + \([^ ]*\) (kernel).*/\1/p')
  userspace_seg=$(printf '%s\n' "$line" \
    | sed -n 's/.*(kernel) + \(.*\) (userspace) =.*/\1/p')
  total_seg=$(printf '%s\n' "$line" \
    | sed -n 's/.*= \(.*\)$/\1/p')

  PERF_FIRMWARE_SEC=$(perf_time_token_to_sec "$firmware_tok")
  PERF_LOADER_SEC=$(perf_time_token_to_sec "$loader_tok")
  PERF_KERNEL_SEC=$(perf_time_token_to_sec "$kernel_tok")
  PERF_USERSPACE_SEC=$(perf_time_segment_to_sec "$userspace_seg")
  PERF_TOTAL_SEC=$(perf_time_segment_to_sec "$total_seg")

  # --- systemd-networkd-wait-online.service contribution ---
  if [ "$exclude_networkd" = "1" ] && [ -f "$blame_file" ]; then
    net_seg=$(grep 'systemd-networkd-wait-online.service' "$blame_file" 2>/dev/null \
      | head -n 1 | awk '{print $1, $2}')
    PERF_NETWORKD_WAIT_ONLINE_SEC=$(perf_time_segment_to_sec "$net_seg")
  fi

  # --- Generic exclude-services list (comma or space separated) ---
  EX_SVC_LIST=""
  EX_SVC_TOTAL_SEC=""
  if [ -n "$exclude_services_raw" ] && [ -f "$blame_file" ]; then
    services=$(printf '%s\n' "$exclude_services_raw" | tr ',' ' ')
    for svc in $services; do
      [ -n "$svc" ] || continue

      # Avoid double-counting networkd if user also passed it in the list.
      if [ "$exclude_networkd" = "1" ] && [ "$svc" = "systemd-networkd-wait-online.service" ]; then
        continue
      fi

      line_svc=$(grep " $svc\$" "$blame_file" 2>/dev/null | head -n 1)
      [ -n "$line_svc" ] || continue

      seg_svc=$(printf '%s\n' "$line_svc" | awk '{print $1, $2}')
      sec_svc=$(perf_time_segment_to_sec "$seg_svc")
      [ -n "$sec_svc" ] || continue

      if [ -n "$EX_SVC_LIST" ]; then
        EX_SVC_LIST="$EX_SVC_LIST,$svc"
      else
        EX_SVC_LIST="$svc"
      fi

      if [ -n "$EX_SVC_TOTAL_SEC" ]; then
        EX_SVC_TOTAL_SEC=$(printf '%s %s\n' "$EX_SVC_TOTAL_SEC" "$sec_svc" \
          | awk '{printf("%.3f", $1 + $2)}')
      else
        EX_SVC_TOTAL_SEC="$sec_svc"
      fi
    done
  fi

  PERF_EXCLUDED_SERVICES_LIST="$EX_SVC_LIST"
  PERF_EXCLUDED_SERVICES_SEC="$EX_SVC_TOTAL_SEC"

  # --- Aggregate excluded total (networkd + generic services) ---
  EXCL_TOTAL=""
  if [ "$exclude_networkd" = "1" ] && [ -n "$PERF_NETWORKD_WAIT_ONLINE_SEC" ]; then
    EXCL_TOTAL="$PERF_NETWORKD_WAIT_ONLINE_SEC"
  fi
  if [ -n "$PERF_EXCLUDED_SERVICES_SEC" ]; then
    if [ -n "$EXCL_TOTAL" ]; then
      EXCL_TOTAL=$(printf '%s %s\n' "$EXCL_TOTAL" "$PERF_EXCLUDED_SERVICES_SEC" \
        | awk '{printf("%.3f", $1 + $2)}')
    else
      EXCL_TOTAL="$PERF_EXCLUDED_SERVICES_SEC"
    fi
  fi
  PERF_EXCLUDED_TOTAL_SEC="$EXCL_TOTAL"

  PERF_USERSPACE_EFFECTIVE_SEC="$PERF_USERSPACE_SEC"
  PERF_TOTAL_EFFECTIVE_SEC="$PERF_TOTAL_SEC"

  if [ -n "$EXCL_TOTAL" ] && [ -n "$PERF_USERSPACE_SEC" ] && [ -n "$PERF_TOTAL_SEC" ]; then
    PERF_USERSPACE_EFFECTIVE_SEC=$(printf '%s %s\n' "$PERF_USERSPACE_SEC" "$EXCL_TOTAL" \
      | awk '{d = $1 - $2; if (d < 0) d = 0; printf("%.3f\n", d)}')
    PERF_TOTAL_EFFECTIVE_SEC=$(printf '%s %s\n' "$PERF_TOTAL_SEC" "$EXCL_TOTAL" \
      | awk '{d = $1 - $2; if (d < 0) d = 0; printf("%.3f\n", d)}')
  fi

  export PERF_FIRMWARE_SEC PERF_LOADER_SEC PERF_KERNEL_SEC PERF_USERSPACE_SEC PERF_TOTAL_SEC \
         PERF_NETWORKD_WAIT_ONLINE_SEC PERF_EXCLUDED_SERVICES_LIST PERF_EXCLUDED_SERVICES_SEC \
         PERF_EXCLUDED_TOTAL_SEC PERF_USERSPACE_EFFECTIVE_SEC PERF_TOTAL_EFFECTIVE_SEC
}

# ---------------------------------------------------------------------------
# Boot-complete detection (multi-user.target)
# ---------------------------------------------------------------------------

# Wait for multi-user.target up to <timeout> seconds.
# Usage: wait_for_multi_user_target <timeout_seconds>
wait_for_multi_user_target() {
    timeout="$1"

    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl not found; cannot verify multi-user.target boot-complete state"
        return 0
    fi

    i=0
    while [ "$i" -lt "$timeout" ]; do
        if systemctl is-active --quiet multi-user.target; then
            log_info "Boot complete: multi-user.target is active"
            return 0
        fi
        sleep 1
        i=$((i+1))
    done

    if systemctl is-active --quiet multi-user.target; then
        log_info "Boot complete: multi-user.target became active after timeout window"
    else
        log_warn "multi-user.target not active after ${timeout}s; continuing KPI collection anyway"
    fi
}

# ---------------------------------------------------------------------------
# Boot KPI loop helpers: state + systemd hook + KPI CSV / averages
# ---------------------------------------------------------------------------

# Internal helper for safe double-quote escaping
perf_kpi_escape_dq() {
    printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'
}

# Write/refresh KPI loop state file.
perf_kpi_write_loop_state() {
    state_file=$1
    iter_total=$2
    iter_done=$3
    boot_type=$4
    disable_getty=$5
    disable_sshd=$6
    exclude_networkd=$7
    exclude_services=$8
    kpi_script=$9
    kpi_out_dir=${10}

    dir=$(dirname "$state_file")
    mkdir -p "$dir" 2>/dev/null || true

    {
        echo "KPI_LOOP_ITERATIONS_TOTAL=$iter_total"
        echo "KPI_LOOP_ITERATIONS_DONE=$iter_done"
        echo "KPI_LOOP_BOOT_TYPE=\"$(perf_kpi_escape_dq "$boot_type")\""
        echo "KPI_LOOP_DISABLE_GETTY=$disable_getty"
        echo "KPI_LOOP_DISABLE_SSHD=$disable_sshd"
        echo "KPI_LOOP_EXCLUDE_NETWORKD=$exclude_networkd"
        echo "KPI_LOOP_EXCLUDE_SERVICES=\"$(perf_kpi_escape_dq "$exclude_services")\""
        echo "KPI_LOOP_KPI_SCRIPT=\"$(perf_kpi_escape_dq "$kpi_script")\""
        echo "KPI_LOOP_KPI_OUT_DIR=\"$(perf_kpi_escape_dq "$kpi_out_dir")\""
    } >"$state_file" 2>/dev/null || true

    log_info "KPI loop state written to $state_file (done=$iter_done, total=$iter_total)"
}

# Load KPI loop state; exports KPI_LOOP_* vars if present.
perf_kpi_load_loop_state() {
    state_file=$1
    if [ ! -f "$state_file" ]; then
        return 1
    fi

    # shellcheck disable=SC1090
    . "$state_file"

    export KPI_LOOP_ITERATIONS_TOTAL KPI_LOOP_ITERATIONS_DONE KPI_LOOP_BOOT_TYPE \
           KPI_LOOP_DISABLE_GETTY KPI_LOOP_DISABLE_SSHD KPI_LOOP_EXCLUDE_NETWORKD \
           KPI_LOOP_EXCLUDE_SERVICES KPI_LOOP_KPI_SCRIPT KPI_LOOP_KPI_OUT_DIR

    log_info "Loaded KPI loop state from $state_file (done=${KPI_LOOP_ITERATIONS_DONE:-0}, total=${KPI_LOOP_ITERATIONS_TOTAL:-1})"
    return 0
}

# Install a systemd hook to run the KPI loop script at each boot.
perf_install_kpi_systemd_hook() {
    kpi_script=$1
    svc_name=$2

    if [ -z "$kpi_script" ] || [ -z "$svc_name" ]; then
        log_error "perf_install_kpi_systemd_hook: missing script or service name"
        return 1
    fi

    case "$svc_name" in
        *.service) svc_name=${svc_name%.service} ;;
        *.timer) svc_name=${svc_name%.timer} ;;
    esac

    script_dir=$(dirname "$kpi_script")
    unit_dir=/etc/systemd/system

    service_unit="$unit_dir/$svc_name.service"
    timer_unit="$unit_dir/$svc_name.timer"

    log_info "Installing KPI loop systemd units: $service_unit + $timer_unit"

    cat >"$service_unit" <<EOF
[Unit]
Description=Perf KPI auto-reboot loop
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=$kpi_script
WorkingDirectory=$script_dir
User=root

# The script's own state file controls:
# - whether AUTO_REBOOT is active
# - when to stop the loop and remove hooks
EOF

    cat >"$timer_unit" <<EOF
[Unit]
Description=Run Perf KPI auto-reboot loop after boot has settled

[Timer]
OnBootSec=30s
Unit=$svc_name.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
        systemctl enable --now "$svc_name.timer" || true
    else
        log_warn "systemctl not found, KPI loop units created but not enabled"
    fi

    return 0
}

# Remove systemd hook and reload daemon.
perf_remove_kpi_systemd_hook() {
    svc_name=$1

    if [ -z "$svc_name" ]; then
        log_error "perf_remove_kpi_systemd_hook: missing service name"
        return 1
    fi

    case "$svc_name" in
        *.service) svc_name=${svc_name%.service} ;;
        *.timer) svc_name=${svc_name%.timer} ;;
    esac

    unit_dir=/etc/systemd/system
    service_unit="$unit_dir/$svc_name.service"
    timer_unit="$unit_dir/$svc_name.timer"

    log_info "Removing KPI loop systemd units: $service_unit + $timer_unit"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$svc_name.timer" 2>/dev/null || true
        systemctl disable "$svc_name.service" 2>/dev/null || true
    fi

    rm -f "$timer_unit" "$service_unit" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
    fi

    return 0
}

# Wait for systemd-analyze time to report a finished boot
wait_analyze_ready() {
    out_file=$1
    jobs_file=$2
    max_wait=${3:-180}
    interval=${4:-5}

    [ -z "$max_wait" ] && max_wait=180
    [ -z "$interval" ] && interval=5

    elapsed=0

    while :; do
        if systemd-analyze time >"$out_file" 2>&1; then
            if grep -q "Bootup is not yet finished" "$out_file"; then
                log_warn "systemd-analyze: boot not finished yet (elapsed=${elapsed}s); capturing systemctl list-jobs → $jobs_file"
                systemctl list-jobs >"$jobs_file" 2>&1 || true

                if [ "$elapsed" -ge "$max_wait" ]; then
                    log_warn "systemd-analyze: boot STILL not finished after ${elapsed}s; keeping analyze_time.txt as-is (KPI times may be 'unknown')."
                    return 1
                fi
            else
                log_info "systemd-analyze: boot finished; analyze_time.txt captured after ${elapsed}s."
                return 0
            fi
        else
            rc=$?
            log_warn "systemd-analyze time failed with rc=$rc; see $out_file for details."
            return 2
        fi

        sleep "$interval" || break
        elapsed=$((elapsed + interval))
    done

    log_warn "systemd-analyze: exited wait loop without finished-boot output; see $out_file / $jobs_file."
    return 1
}

# ---------------------------------------------------------------------------
# KPI file parsing + CSV append + averaging
# ---------------------------------------------------------------------------

kpi_get_line_val() {
    key=$1
    file=$2
    sed -n "s/^ ${key} : //p" "$file" 2>/dev/null | head -n 1
}

kpi_get_num_from_line() {
    key=$1
    file=$2
    val=$(kpi_get_line_val "$key" "$file")
    printf '%s\n' "$val" | awk '{print $1}'
}

perf_kpi_extract_from_file() {
    file=$1

    PERF_KPI_BOOT_TYPE=$(kpi_get_line_val "boot_type" "$file")
    PERF_KPI_ITERATIONS_HINT=$(kpi_get_line_val "iterations" "$file")
    PERF_KPI_CLOCKSOURCE=$(kpi_get_line_val "clocksource" "$file")

    PERF_KPI_UEFI_TIME_SEC=$(kpi_get_num_from_line "uefi_time_sec" "$file")
    PERF_KPI_FIRMWARE_SEC=$(kpi_get_num_from_line "firmware_time_sec" "$file")
    PERF_KPI_BOOTLOADER_SEC=$(kpi_get_num_from_line "bootloader_time_sec" "$file")
    PERF_KPI_KERNEL_SEC=$(kpi_get_num_from_line "kernel_time_sec" "$file")
    PERF_KPI_USERSPACE_SEC=$(kpi_get_num_from_line "userspace_time_sec" "$file")
    PERF_KPI_USERSPACE_EFFECTIVE_SEC=$(kpi_get_num_from_line "userspace_effective_time_sec" "$file")
    PERF_KPI_BOOT_TOTAL_SEC=$(kpi_get_num_from_line "boot_total_sec" "$file")
    PERF_KPI_BOOT_TOTAL_EFFECTIVE_SEC=$(kpi_get_num_from_line "boot_total_effective_sec" "$file")

    export PERF_KPI_BOOT_TYPE PERF_KPI_ITERATIONS_HINT PERF_KPI_CLOCKSOURCE \
           PERF_KPI_UEFI_TIME_SEC PERF_KPI_FIRMWARE_SEC PERF_KPI_BOOTLOADER_SEC \
           PERF_KPI_KERNEL_SEC PERF_KPI_USERSPACE_SEC PERF_KPI_USERSPACE_EFFECTIVE_SEC \
           PERF_KPI_BOOT_TOTAL_SEC PERF_KPI_BOOT_TOTAL_EFFECTIVE_SEC
}

perf_kpi_append_csv_row() {
    csv=$1
    override_bt=$2

    bt=$override_bt
    [ -n "$bt" ] || bt=$PERF_KPI_BOOT_TYPE

    if [ ! -f "$csv" ]; then
        echo "timestamp,boot_type,iterations_hint,clocksource,uefi_time_sec,firmware_time_sec,bootloader_time_sec,kernel_time_sec,userspace_time_sec,userspace_effective_time_sec,boot_total_sec,boot_total_effective_sec" >"$csv"
    fi

    ts=$(nowstamp)
    echo "$ts,$bt,$PERF_KPI_ITERATIONS_HINT,$PERF_KPI_CLOCKSOURCE,$PERF_KPI_UEFI_TIME_SEC,$PERF_KPI_FIRMWARE_SEC,$PERF_KPI_BOOTLOADER_SEC,$PERF_KPI_KERNEL_SEC,$PERF_KPI_USERSPACE_SEC,$PERF_KPI_USERSPACE_EFFECTIVE_SEC,$PERF_KPI_BOOT_TOTAL_SEC,$PERF_KPI_BOOT_TOTAL_EFFECTIVE_SEC" >>"$csv" 2>/dev/null || true

    log_info "Appended KPI row to $csv (boot_type=$bt, total_sec=${PERF_KPI_BOOT_TOTAL_SEC:-unknown}, total_eff_sec=${PERF_KPI_BOOT_TOTAL_EFFECTIVE_SEC:-unknown})"
}

perf_kpi_compute_average() {
    csv=$1
    bt=$2
    window=$3
    summary_file=$4

    if [ ! -f "$csv" ]; then
        log_warn "perf_kpi_compute_average: CSV not found: $csv"
        return 1
    fi

    tmp_filtered="${csv}.filtered.$$"
    tmp_last="${csv}.last.$$"

    awk -F',' -v bt="$bt" '
        NR == 1 { next }
        $2 == bt { print }
    ' "$csv" >"$tmp_filtered" 2>/dev/null || true

    tail -n "$window" "$tmp_filtered" >"$tmp_last" 2>/dev/null || true

    if [ ! -s "$tmp_last" ]; then
        rm -f "$tmp_filtered" "$tmp_last" 2>/dev/null || true
        log_warn "perf_kpi_compute_average: no entries for boot_type=$bt"
        return 1
    fi

    awk -F',' -v bt="$bt" -v target="$window" '
      {
        n++;
        if ($5 ~ /^[0-9.]+$/) { uefi_sum += $5; uefi_n++ }
        if ($6 ~ /^[0-9.]+$/) { fw_sum += $6; fw_n++ }
        if ($7 ~ /^[0-9.]+$/) { bl_sum += $7; bl_n++ }
        if ($8 ~ /^[0-9.]+$/) { k_sum += $8; k_n++ }
        if ($9 ~ /^[0-9.]+$/) { us_sum += $9; us_n++ }
        if ($10 ~ /^[0-9.]+$/) { use_sum += $10; use_n++ }
        if ($11 ~ /^[0-9.]+$/) { tot_sum += $11; tot_n++ }
        if ($12 ~ /^[0-9.]+$/) { tote_sum += $12; tote_n++ }
      }
      END {
        if (n == 0) { exit 0 }

        if (uefi_n > 0) uefi_avg = uefi_sum / uefi_n; else uefi_avg = -1;
        if (fw_n > 0) fw_avg = fw_sum / fw_n; else fw_avg = -1;
        if (bl_n > 0) bl_avg = bl_sum / bl_n; else bl_avg = -1;
        if (k_n > 0) k_avg = k_sum / k_n; else k_avg = -1;
        if (us_n > 0) us_avg = us_sum / us_n; else us_avg = -1;
        if (use_n > 0) use_avg = use_sum / use_n; else use_avg = -1;
        if (tot_n > 0) tot_avg = tot_sum / tot_n; else tot_avg = -1;
        if (tote_n > 0) tote_avg = tote_sum / tote_n; else tote_avg = -1;

        out = summary_file
        printf("Boot KPI summary (last %d %s boot(s))\n", n, bt) > out
        printf(" entries_used : %d\n", n) >> out
        printf(" target_iterations : %d\n", target) >> out
        printf(" boot_type : %s\n", bt) >> out

        if (uefi_avg >= 0)
          printf(" avg_uefi_time_sec : %.3f\n", uefi_avg) >> out
        if (fw_avg >= 0)
          printf(" avg_firmware_time_sec : %.3f\n", fw_avg) >> out
        if (bl_avg >= 0)
          printf(" avg_bootloader_time_sec : %.3f\n", bl_avg) >> out
        if (k_avg >= 0)
          printf(" avg_kernel_time_sec : %.3f\n", k_avg) >> out
        if (us_avg >= 0)
          printf(" avg_userspace_time_sec : %.3f\n", us_avg) >> out
        if (use_avg >= 0)
          printf(" avg_userspace_effective_time_sec : %.3f\n", use_avg) >> out
        if (tot_avg >= 0)
          printf(" avg_boot_total_sec : %.3f\n", tot_avg) >> out
        if (tote_avg >= 0)
          printf(" avg_boot_total_effective_sec : %.3f\n", tote_avg) >> out
      }
    ' summary_file="$summary_file" "$tmp_last"

    rm -f "$tmp_filtered" "$tmp_last" 2>/dev/null || true

    if [ -f "$summary_file" ]; then
        log_info "perf_kpi_compute_average: summary written to $summary_file"
    fi
}

# ---------------------------------------------------------------------------
# Boot identity + reboot tracking helpers for KPI loops
# ---------------------------------------------------------------------------

perf_kpi_get_boot_identity() {
    PERF_KPI_BOOT_ID="unknown"
    PERF_KPI_UPTIME_SEC=""

    if [ -r /proc/sys/kernel/random/boot_id ]; then
        PERF_KPI_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
    fi

    if [ -r /proc/uptime ]; then
        PERF_KPI_UPTIME_SEC=$(awk '{printf("%.3f\n", $1)}' /proc/uptime 2>/dev/null || echo "")
    fi

    export PERF_KPI_BOOT_ID PERF_KPI_UPTIME_SEC
}

perf_kpi_reboot_state_load() {
    state_file=$1

    PERF_KPI_STATE_BOOT_ID=""
    PERF_KPI_STATE_UPTIME=""
    PERF_KPI_STATE_PENDING="0"
    PERF_KPI_STATE_ITER_DONE=""

    if [ -f "$state_file" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                boot_id) PERF_KPI_STATE_BOOT_ID=$v ;;
                uptime_sec) PERF_KPI_STATE_UPTIME=$v ;;
                pending_reboot) PERF_KPI_STATE_PENDING=$v ;;
                iterations_done) PERF_KPI_STATE_ITER_DONE=$v ;;
            esac
        done <"$state_file"
    fi

    export PERF_KPI_STATE_BOOT_ID PERF_KPI_STATE_UPTIME \
           PERF_KPI_STATE_PENDING PERF_KPI_STATE_ITER_DONE
}

perf_kpi_reboot_state_save() {
    state_file=$1
    boot_id=$2
    uptime=$3
    pending=$4
    iter_done=$5

    {
        echo "boot_id=$boot_id"
        echo "uptime_sec=$uptime"
        echo "pending_reboot=$pending"
        echo "iterations_done=$iter_done"
    } >"$state_file" 2>/dev/null || true
}

perf_kpi_request_reboot() {
    msg=$1

    log_info "Requesting reboot: $msg"

    sync || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot || reboot || shutdown -r now || :
    else
        reboot || shutdown -r now || :
    fi

    sleep 5
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot || reboot || shutdown -r now || :
    else
        reboot || shutdown -r now || :
    fi
}

perf_kpi_check_previous_reboot() {
    state_file=$1

    perf_kpi_reboot_state_load "$state_file"
    perf_kpi_get_boot_identity

    if [ "$PERF_KPI_STATE_PENDING" != "1" ] || [ -z "$PERF_KPI_STATE_BOOT_ID" ]; then
        return 0
    fi

    if [ "$PERF_KPI_STATE_BOOT_ID" = "$PERF_KPI_BOOT_ID" ]; then
        log_warn "Previous reboot request did NOT change boot-id; re-issuing reboot now."
        log_warn "Previous boot_id=$PERF_KPI_STATE_BOOT_ID uptime=${PERF_KPI_STATE_UPTIME:-unknown}s; current uptime=${PERF_KPI_UPTIME_SEC:-unknown}s"
        perf_kpi_request_reboot "Retrying failed reboot for KPI loop"
        return 0
    fi

    log_info "Detected new boot after KPI reboot: old_boot_id=$PERF_KPI_STATE_BOOT_ID, new_boot_id=$PERF_KPI_BOOT_ID"
    log_info "Previous uptime at reboot request=${PERF_KPI_STATE_UPTIME:-unknown}s, current uptime=${PERF_KPI_UPTIME_SEC:-unknown}s"

    perf_kpi_reboot_state_save "$state_file" "$PERF_KPI_BOOT_ID" "$PERF_KPI_UPTIME_SEC" "0" "$PERF_KPI_STATE_ITER_DONE"
}

perf_avg_file() {
    f=$1
    [ -s "$f" ] || { echo ""; return 0; }

    awk '
      /^[0-9]+(\.[0-9]+)?$/ {sum+=$1; n++}
      END { if (n>0) printf("%.3f\n", sum/n); else print "" }
    ' "$f"
}

perf_pct_change_lower_better() {
    cur=$1
    base=$2
    if ! perf_is_number "$cur" || ! perf_is_number "$base"; then
        echo ""
        return 0
    fi
    awk -v c="$cur" -v b="$base" '
      BEGIN{
        if (b<=0) { print ""; exit }
        p=((c-b)/b)*100.0
        printf("%.2f\n", p)
      }'
}

perf_pct_change_higher_better() {
    cur=$1
    base=$2
    if ! perf_is_number "$cur" || ! perf_is_number "$base"; then
        echo ""
        return 0
    fi
    awk -v c="$cur" -v b="$base" '
      BEGIN{
        if (b<=0) { print ""; exit }
        p=((b-c)/b)*100.0
        printf("%.2f\n", p)
      }'
}

perf_metric_check() {
    name=$1
    cur=$2
    base=$3
    direction=$4
    delta=$5

    if [ -z "$base" ]; then
        log_warn "$name: baseline missing → skipping compare (current=$cur)"
        return 2
    fi

    if ! perf_is_number "$cur" || ! perf_is_number "$base"; then
        log_warn "$name: non-numeric compare (current=$cur baseline=$base) → skipping"
        return 2
    fi

    allowed_pct=$(printf '%s\n' "$delta" | awk '{printf("%.2f\n",$1*100.0)}')

    case "$direction" in
        lower) pct=$(perf_pct_change_lower_better "$cur" "$base") ;;
        higher) pct=$(perf_pct_change_higher_better "$cur" "$base") ;;
        *)
            log_warn "$name: unknown direction '$direction' → skipping"
            return 2
            ;;
    esac

    if [ -z "$pct" ]; then
        log_warn "$name: could not compute delta (current=$cur baseline=$base) → skipping"
        return 2
    fi

    pass=$(awk -v p="$pct" -v a="$allowed_pct" 'BEGIN{ if (p <= a) print 1; else print 0 }')
    if [ "$pass" = "1" ]; then
        log_info "$name: PASS current=$cur baseline=$base regression=${pct}% (allowed<=${allowed_pct}%)"
        return 0
    fi

    log_error "$name: FAIL current=$cur baseline=$base regression=${pct}% (allowed<=${allowed_pct}%)"
    return 1
}

perf_baseline_get() {
    key=$1
    file=$2
    [ -f "$file" ] || { echo ""; return 0; }
 
    awk -v k="$key" '
      {
        line=$0
        sub(/^[ \t]*/, "", line)
 
        # exact prefix match on key (string compare, not regex)
        kl = length(k)
        if (substr(line, 1, kl) != k) next
 
        rest = substr(line, kl + 1)
 
        # allow optional spaces then ":" or "=" then optional spaces
        if (rest ~ /^[ \t]*[=:][ \t]*/) {
          sub(/^[ \t]*[=:][ \t]*/, "", rest)
          sub(/\r$/, "", rest)
          print rest
          exit
        }
      }
    ' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Sysbench helpers (run + parse + average + optional CSV)
# ---------------------------------------------------------------------------
# Parse total time (sec) from sysbench 1.0+ output.
# Supports both:
#   "total time: 30.0009s"
#   "total time taken by event execution: 29.9943s"
perf_sysbench_parse_time_sec() {
    log_file=$1
    [ -f "$log_file" ] || { echo ""; return 0; }

    v=$(
        sed -n \
          -e 's/^[[:space:]]*total time taken by event execution:[[:space:]]*\([0-9.][0-9.]*\)s.*/\1/p' \
          -e 's/^[[:space:]]*total time:[[:space:]]*\([0-9.][0-9.]*\)s.*/\1/p' \
          "$log_file" 2>/dev/null | head -n 1
    )
    printf '%s' "$v"
}

# Parse memory throughput (MB/sec) from sysbench memory output:
#   "... transferred (2486.38 MB/sec)"
# Also tolerates MiB/sec
perf_sysbench_parse_mem_mbps() {
    log_file=$1
    [ -f "$log_file" ] || { echo ""; return 0; }

    v=$(
        sed -n \
          -e 's/.*(\([0-9.][0-9.]*\)[[:space:]]*MB\/sec).*/\1/p' \
          -e 's/.*(\([0-9.][0-9.]*\)[[:space:]]*MiB\/sec).*/\1/p' \
	  -e 's/.*(\([0-9.][0-9.]*\)[[:space:]]*MB\/s).*/\1/p' \
	  -e 's/.*(\([0-9.][0-9.]*\)[[:space:]]*MiB\/s).*/\1/p' \
          "$log_file" 2>/dev/null | head -n 1
    )
    printf '%s' "$v"
}

# Append a numeric value to a values file (one per line).
perf_values_append() {
    values_file=$1
    val=$2
    [ -n "$values_file" ] || return 0
    [ -n "$val" ] || return 0
    printf '%s\n' "$val" >>"$values_file" 2>/dev/null || true
}

# Compute average from values file. Prints avg or empty.
perf_values_avg() {
    values_file=$1
    [ -s "$values_file" ] || { echo ""; return 0; }

    awk '
      $1 ~ /^[0-9.]+$/ { s += $1; n++ }
      END { if (n > 0) printf("%.3f\n", s/n); }
    ' "$values_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Sysbench helpers
# ---------------------------------------------------------------------------
# Helper: extract "key=value" from a single line of space-separated kv tokens.
kv_get() {
  line=$1
  key=$2
  printf "%s\n" "$line" | awk -v k="$key" '
    {
      for (i=1; i<=NF; i++) {
        split($i, a, "=")
        if (a[1] == k) { print a[2]; exit }
      }
    }'
}

# helper: extract key=value tokens from perf_sysbench_gate_eval_line output (no function def)
kv() {
  line=$1
  key=$2

  printf "%s\n" "$line" | awk -v k="$key" '
    {
      for (i = 1; i <= NF; i++) {
        split($i, a, "=")
        if (a[1] == k) {
          print a[2]
          exit
        }
      }
    }'
}

run_sysbench_case() {
  label=$1
  out_log=$2
  shift 2

  log_info "Running $label → $out_log"
  log_info "CMD: $*"

  if command -v perf_run_cmd_tee >/dev/null 2>&1; then
    perf_run_cmd_tee "$out_log" "$@"
    return $?
  fi

  # fallback
  "$@" >"$out_log" 2>&1
  cat "$out_log"
  return $?
}

# Convert MiB/s -> MB/s (MB = MiB * 1.048576) to match baseline units
sysbench_mib_to_mb() {
  v=$1
  [ -z "$v" ] && { echo ""; return 0; }
 
  if command -v perf_f_mul >/dev/null 2>&1; then
    perf_f_mul "$v" "1.048576"
  else
    awk -v x="$v" 'BEGIN{printf "%.6f", x*1.048576}'
  fi
}

perf_sysbench_extract_total_time_sec() {
    f=$1
    [ -f "$f" ] || { echo ""; return 0; }

    v=$(grep -E 'total time taken by event execution:' "$f" 2>/dev/null \
        | head -n 1 | sed 's/.*: *//; s/[[:space:]]*s.*$//')
    if [ -z "$v" ]; then
        v=$(grep -E '^total time:' "$f" 2>/dev/null \
            | head -n 1 | sed 's/.*: *//; s/[[:space:]]*s.*$//')
    fi

    v=$(printf '%s\n' "$v" | awk '{print $1}')
    if perf_is_number "$v"; then
        printf '%.3f\n' "$v" 2>/dev/null || printf '%s\n' "$v"
    else
        echo ""
    fi
}

perf_sysbench_extract_memory_mbps() {
    f=$1
    [ -f "$f" ] || { echo ""; return 0; }

    line=$(grep -E 'transferred.*\([0-9.]+[[:space:]]*(MiB|MB)/(sec|s)\)' "$f" 2>/dev/null | head -n 1)
    if [ -z "$line" ]; then
        line=$(grep -E '\([0-9.]+[[:space:]]*(MiB|MB)/(sec|s)\)' "$f" 2>/dev/null | head -n 1)
    fi
    [ -n "$line" ] || { echo ""; return 0; }

    v=$(printf '%s\n' "$line" \
        | sed -n 's/.*(\([0-9.][0-9.]*\)[[:space:]]*\(MiB\|MB\)\/\(sec\|s\)).*/\1/p' \
        | head -n 1)

    if perf_is_number "$v"; then
        printf '%.3f\n' "$v" 2>/dev/null || printf '%s\n' "$v"
    else
        echo ""
    fi
}

perf_sysbench_cmd_prefix() {
    core_list=$1
    if [ -n "$core_list" ]; then
        printf 'taskset -c %s' "$core_list"
        return 0
    fi
    echo ""
}

perf_sysbench_run_to_log() {
    prefix=$1
    out_log=$2
    shift 2

    : >"$out_log" 2>/dev/null || true

    if [ -n "$prefix" ]; then
        # Intentionally word-split prefix (taskset -c ...)
        # shellcheck disable=SC2086
        set -- $prefix sysbench "$@" run
        "$@" >"$out_log" 2>&1
        return $?
    fi

    sysbench "$@" run >"$out_log" 2>&1
}

perf_sysbench_values_file() {
    outdir=$1
    tag=$2
    printf '%s/%s.values' "$outdir" "$tag"
}

perf_sysbench_print_iterations() {
    label=$1
    values_file=$2

    if [ ! -s "$values_file" ]; then
        log_warn "$label: no iteration values recorded"
        return 0
    fi

    i=1
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        log_info "$label: iteration $i = $v"
        i=$((i + 1))
    done <"$values_file"
}

perf_sysbench_run_n_and_avg_time() {
    name=$1
    outdir=$2
    tag=$3
    iterations=$4
    prefix=$5
    shift 5

    values_file=$(perf_sysbench_values_file "$outdir" "$tag")
    : >"$values_file" 2>/dev/null || true

    i=1
    while [ "$i" -le "$iterations" ]; do
        log_file="$outdir/${tag}_iter${i}.log"
        log_info "Running $name (iteration $i/$iterations) → $log_file"

        perf_sysbench_run_to_log "$prefix" "$log_file" "$@"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            log_warn "$name: sysbench exited rc=$rc (continuing; will evaluate parsed metrics)"
        fi

        t=$(perf_sysbench_extract_total_time_sec "$log_file")
        if [ -n "$t" ]; then
            echo "$t" >>"$values_file" 2>/dev/null || true
            log_info "$name: iteration $i time_sec=$t"
        else
            log_warn "$name: iteration $i could not parse time from $log_file"
        fi

        i=$((i + 1))
    done

    perf_avg_file "$values_file"
}

perf_sysbench_run_n_and_avg_mem_mbps() {
    name=$1
    outdir=$2
    tag=$3
    iterations=$4
    prefix=$5
    shift 5

    values_file=$(perf_sysbench_values_file "$outdir" "$tag")
    : >"$values_file" 2>/dev/null || true

    i=1
    while [ "$i" -le "$iterations" ]; do
        log_file="$outdir/${tag}_iter${i}.log"
        log_info "Running $name (iteration $i/$iterations) → $log_file"

        perf_sysbench_run_to_log "$prefix" "$log_file" "$@"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            log_warn "$name: sysbench exited rc=$rc (continuing; will evaluate parsed metrics)"
        fi

        mbps=$(perf_sysbench_extract_memory_mbps "$log_file")
        if [ -n "$mbps" ]; then
            echo "$mbps" >>"$values_file" 2>/dev/null || true
            log_info "$name: iteration $i mem_mbps=$mbps"
        else
            log_warn "$name: iteration $i could not parse mem MB/s from $log_file"
        fi

        i=$((i + 1))
    done

    perf_avg_file "$values_file"
}

# ---------------------------------------------------------------------------
# Optional CSV helpers (per-iteration + average)
# ---------------------------------------------------------------------------

perf_csv_init() {
    csv=$1
    [ -n "$csv" ] || return 0

    if [ ! -f "$csv" ]; then
        echo "timestamp,test,metric,unit,threads,iteration,value,core_list,seed,time_sec,extra" >"$csv"
        log_info "CSV created → $csv"
        log_info "CSV header: timestamp,test,metric,unit,threads,iteration,value,core_list,seed,time_sec,extra"
    fi
}

perf_csv_append_line() {
    csv=$1
    line=$2
    [ -n "$csv" ] || return 0
    [ -n "$line" ] || return 0

    echo "$line" >>"$csv" 2>/dev/null || true
    log_info "CSV: $line"
}

perf_sysbench_csv_append_values_and_avg() {
    csv=$1
    test=$2
    metric=$3
    unit=$4
    threads=$5
    values_file=$6
    avg=$7
    core_list=$8
    seed=$9
    time_sec=${10}
    extra=${11}

    [ -n "$csv" ] || return 0

    perf_csv_init "$csv"
    ts=$(nowstamp)

    if [ -s "$values_file" ]; then
        i=1
        while IFS= read -r v; do
            [ -n "$v" ] || continue
            line="$ts,$test,$metric,$unit,$threads,$i,$v,${core_list:-},${seed:-},${time_sec:-},\"$(esc "${extra:-}")\""
            perf_csv_append_line "$csv" "$line"
            i=$((i + 1))
        done <"$values_file"
    else
        line="$ts,$test,$metric,$unit,$threads,1,,${core_list:-},${seed:-},${time_sec:-},\"$(esc "${extra:-}")\""
        perf_csv_append_line "$csv" "$line"
    fi

    if [ -n "$avg" ]; then
        line="$ts,$test,$metric,$unit,$threads,avg,$avg,${core_list:-},${seed:-},${time_sec:-},\"$(esc "${extra:-}")\""
        perf_csv_append_line "$csv" "$line"
    else
        line="$ts,$test,$metric,$unit,$threads,avg,,${core_list:-},${seed:-},${time_sec:-},\"$(esc "${extra:-}")\""
        perf_csv_append_line "$csv" "$line"
    fi
}

# ---------------------------------------------------------------------------
# Final summary writer
# ---------------------------------------------------------------------------

perf_sysbench_write_final_summary() {
    summary_file=$1
    outdir=$2
    iterations=$3
    core_list=$4
    delta=$5
    cpu_tag=$6
    mem_tag=$7
    thr_tag=$8
    mtx_tag=$9
    cpu_avg=${10}
    mem_avg=${11}
    thr_avg=${12}
    mtx_avg=${13}

    cpu_vals=$(perf_sysbench_values_file "$outdir" "$cpu_tag")
    mem_vals=$(perf_sysbench_values_file "$outdir" "$mem_tag")
    thr_vals=$(perf_sysbench_values_file "$outdir" "$thr_tag")
    mtx_vals=$(perf_sysbench_values_file "$outdir" "$mtx_tag")

    {
        echo "Sysbench Summary"
        echo " timestamp : $(nowstamp)"
        echo " iterations : $iterations"
        echo " core_list : ${core_list:-none}"
        echo " delta_allowed : $delta"
        echo ""
        echo "CPU (time_sec, lower better)"
        if [ -s "$cpu_vals" ]; then
            i=1
            while IFS= read -r v; do
                [ -n "$v" ] || continue
                echo " iteration_$i : $v"
                i=$((i + 1))
            done <"$cpu_vals"
        else
            echo " iteration_1 : "
        fi
        echo " avg : ${cpu_avg:-}"
        echo ""
        echo "Memory (MB/s, higher better)"
        if [ -s "$mem_vals" ]; then
            i=1
            while IFS= read -r v; do
                [ -n "$v" ] || continue
                echo " iteration_$i : $v"
                i=$((i + 1))
            done <"$mem_vals"
        else
            echo " iteration_1 : "
        fi
        echo " avg : ${mem_avg:-}"
        echo ""
        echo "Threads (time_sec, lower better)"
        if [ -s "$thr_vals" ]; then
            i=1
            while IFS= read -r v; do
                [ -n "$v" ] || continue
                echo " iteration_$i : $v"
                i=$((i + 1))
            done <"$thr_vals"
        else
            echo " iteration_1 : "
        fi
        echo " avg : ${thr_avg:-}"
        echo ""
        echo "Mutex (time_sec, lower better)"
        if [ -s "$mtx_vals" ]; then
            i=1
            while IFS= read -r v; do
                [ -n "$v" ] || continue
                echo " iteration_$i : $v"
                i=$((i + 1))
            done <"$mtx_vals"
        else
            echo " iteration_1 : "
        fi
        echo " avg : ${mtx_avg:-}"
        echo ""
        echo "Logs in: $outdir"
    } >"$summary_file" 2>/dev/null || true

    log_info "Final summary written → $summary_file"
}

# -----------------------------------------------------------------------------
# Sysbench helpers: run with live console + file logging
# -----------------------------------------------------------------------------
perf_run_cmd_tee() {
    log_file=$1
    shift

    [ -n "$log_file" ] || return 1

    dir=$(dirname "$log_file")
    mkdir -p "$dir" 2>/dev/null || true

    fifo="${log_file}.fifo.$$"
    rm -f "$fifo" 2>/dev/null || true

    if ! mkfifo "$fifo" 2>/dev/null; then
        # Fallback: no fifo support → just log (no live console)
        "$@" >"$log_file" 2>&1
        return $?
    fi

    # Tee reads from FIFO and writes to both console + log file.
    tee "$log_file" <"$fifo" &
    tee_pid=$!

    # Run command, write both stdout+stderr into FIFO
    "$@" >"$fifo" 2>&1
    rc=$?

    # Wait for tee to finish draining FIFO
    wait "$tee_pid" 2>/dev/null || true
    rm -f "$fifo" 2>/dev/null || true

    return "$rc"
}

# -----------------------------------------------------------------------------
# Sysbench CSV append (consistent schema)
# Header: timestamp,test,threads,metric,iteration,value
# -----------------------------------------------------------------------------
perf_sysbench_csv_append() {
    csv=$1
    test=$2
    threads=$3
    metric=$4
    iteration=$5
    value=$6

    [ -n "$csv" ] || return 0
    [ -n "$value" ] || return 0

    dir=$(dirname "$csv")
    mkdir -p "$dir" 2>/dev/null || true

    if [ ! -f "$csv" ] || [ ! -s "$csv" ]; then
        echo "timestamp,test,threads,metric,iteration,value" >"$csv"
    fi

    if command -v nowstamp >/dev/null 2>&1; then
        ts=$(nowstamp)
    else
        ts=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
    fi

    echo "$ts,$test,$threads,$metric,$iteration,$value" >>"$csv" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Baseline file parsing helpers
# Format: key=value (spaces around '=' allowed), '#' comments allowed.
# -----------------------------------------------------------------------------
perf_baseline_get_value() {
    f=$1
    key=$2
 
    [ -n "$f" ] || return 0
    [ -f "$f" ] || return 0
    [ -n "$key" ] || return 0
 
    awk -v k="$key" '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*$/ {next}
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            pos = index(line, "=")
            if (pos <= 0) next
            kk = substr(line, 1, pos-1)
            vv = substr(line, pos+1)
            sub(/[[:space:]]+$/, "", kk)
            sub(/^[[:space:]]+/, "", vv)
            sub(/[[:space:]]+$/, "", vv)
            if (kk == k) { print vv; exit }
        }
    ' "$f" 2>/dev/null
}

# Construct the expected key used in sysbench_baseline.conf
# Example keys:
#   cpu_time_sec.t4=30.001
#   memory_mem_mbps.t4=7213.250
#   threads_time_sec.t4=30.000
#   mutex_time_sec.t4=0.241
perf_sysbench_baseline_key() {
    sb_case=$1
    metric=$2
    thr=$3
    printf "%s_%s.t%s" "$sb_case" "$metric" "$thr"
}

# -----------------------------------------------------------------------------
# Float helpers (POSIX) using awk
# -----------------------------------------------------------------------------
perf_f_add() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", (a+0)+(b+0)}'; }
perf_f_sub() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", (a+0)-(b+0)}'; }
perf_f_mul() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", (a+0)*(b+0)}'; }
perf_f_div() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b==0) exit 1; printf "%.6f",(a/b)}'; }
# pct = (num/den)*100, prints with 2 decimals; empty if invalid
perf_f_pct() {
    num=$1
    den=$2
    awk -v n="$num" -v d="$den" 'BEGIN{
        if ((d+0) == 0) exit 1
        printf "%.2f", ((n+0)/(d+0))*100.0
    }' 2>/dev/null || true
}

# Returns 0 if true, 1 if false
perf_f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0) >= (b+0))}'; }
perf_f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0) <= (b+0))}'; }

# Metric direction:
# - time_sec: lower is better
perf_metric_direction() {
    m=$1
 
    # Lower is better only for explicit time metrics
    case "$m" in
        *time_sec*) echo "lower"; return 0 ;;
    esac
 
    # Everything else (mem_mbps, fileio_*_mbps, etc.) is higher-is-better
    echo "higher"
    return 0
}

# Get baseline value for a given key from key=value file.
# - Ignores blank lines and comments (# ...)
# - Accepts optional whitespace around '='
# Prints value (or empty string if not found).
perf_sysbench_baseline_get() {
    file=$1
    key=$2
 
    [ -f "$file" ] || { printf '%s' ""; return 0; }
    [ -n "$key" ] || { printf '%s' ""; return 0; }
 
    key_esc=$(perf_sed_escape_bre "$key")
 
    # Match "key = value" (value is first token-ish number)
    v=$(
        sed -n \
          -e 's/[[:space:]]*#.*$//' \
          -e '/^[[:space:]]*$/d' \
          -e "s/^[[:space:]]*${key_esc}[[:space:]]*=[[:space:]]*\\([0-9][0-9.]*\\).*$/\\1/p" \
          "$file" 2>/dev/null | head -n 1
    )
    printf '%s' "$v"
}

# -----------------------------------------------------------------------------
# Baseline gating evaluation
#
# Inputs:
#   baseline_file, sb_case, threads, metric, avg_value, allowed_deviation
#
# Output via globals:
#   PERF_GATE_STATUS   = PASS|FAIL|NO_BASELINE|NO_AVG
#   PERF_GATE_BASELINE = baseline numeric
#   PERF_GATE_GOAL     = goal numeric
#   PERF_GATE_SCORE_PCT= score percent (higher is better)
#   PERF_GATE_OP       = ">=" or "<="
#
# Return:
#   0 PASS
#   1 FAIL
#   2 No baseline / cannot evaluate
# -----------------------------------------------------------------------------
perf_sysbench_gate_eval() {
    file=$1
    case_name=$2
    threads=$3
    metric=$4
    value=$5
    delta=$6
 
    PERF_GATE_KEY="${case_name}_${metric}.t${threads}"
    PERF_GATE_OP=""
    PERF_GATE_BASELINE=""
    PERF_GATE_GOAL=""
    PERF_GATE_SCORE_PCT=""
    PERF_GATE_STATUS="SKIP"
 
    # Export for external consumers (run.sh) → fixes SC2034
    export PERF_GATE_KEY PERF_GATE_OP PERF_GATE_BASELINE PERF_GATE_GOAL PERF_GATE_SCORE_PCT PERF_GATE_STATUS
 
    [ -f "$file" ] || return 2
    [ -n "$case_name" ] || return 2
    [ -n "$threads" ] || return 2
    [ -n "$metric" ] || return 2
    [ -n "$value" ] || return 2
    [ -n "$delta" ] || delta=0
 
    base=$(perf_sysbench_baseline_get "$file" "$PERF_GATE_KEY")
    [ -n "$base" ] || return 2
 
    PERF_GATE_BASELINE="$base"
    export PERF_GATE_BASELINE
 
    # Decide direction:
    # - Throughput (mem_mbps): higher is better
    # - time_sec: lower is better
    higher_is_better=0
    if [ "$metric" = "mem_mbps" ] || echo "$metric" | grep -q "mbps"; then
        higher_is_better=1
    fi
 
    if [ "$higher_is_better" -eq 1 ]; then
        PERF_GATE_OP=">="
        goal=$(awk -v b="$base" -v d="$delta" 'BEGIN{printf "%.6f", (b*(1-d))}')
        PERF_GATE_GOAL="$goal"
        score=$(awk -v b="$base" -v v="$value" 'BEGIN{ if (b==0) print ""; else printf "%.2f", (v/b*100) }')
        PERF_GATE_SCORE_PCT="$score"
        export PERF_GATE_OP PERF_GATE_GOAL PERF_GATE_SCORE_PCT
 
        pass=$(awk -v v="$value" -v g="$goal" 'BEGIN{print (v+0 >= g+0) ? 1 : 0}')
    else
        PERF_GATE_OP="<="
        goal=$(awk -v b="$base" -v d="$delta" 'BEGIN{printf "%.6f", (b*(1+d))}')
        PERF_GATE_GOAL="$goal"
        # score_pct: convert to "bigger is better" by using base/value
        score=$(awk -v b="$base" -v v="$value" 'BEGIN{ if (v==0) print ""; else printf "%.2f", (b/v*100) }')
        PERF_GATE_SCORE_PCT="$score"
        export PERF_GATE_OP PERF_GATE_GOAL PERF_GATE_SCORE_PCT
 
        pass=$(awk -v v="$value" -v g="$goal" 'BEGIN{print (v+0 <= g+0) ? 1 : 0}')
    fi
 
    if [ "$pass" -eq 1 ]; then
        PERF_GATE_STATUS="PASS"
        export PERF_GATE_STATUS
        return 0
    fi
 
    PERF_GATE_STATUS="FAIL"
    export PERF_GATE_STATUS
    return 1
}

# -----------------------------------------------------------------------------
# Optional sanity warning: epoch timestamps (RTC not set)
# -----------------------------------------------------------------------------
perf_clock_sanity_warn() {
    y=$(date "+%Y" 2>/dev/null || echo "")
    case "$y" in
      ""|*[!0-9]*) return 0 ;;
    esac
    if [ "$y" -lt 2000 ]; then
        if command -v log_warn >/dev/null 2>&1; then
            log_warn "System clock looks unset (year=$y). Timestamps in logs/CSV may be misleading."
        else
            echo "[WARN] System clock looks unset (year=$y). Timestamps in logs/CSV may be misleading." >&2
        fi
    fi
}

# -----------------------------------------------------------------------------
# Gate evaluation (no globals). Prints a single machine-parsable line:
#   status=<PASS|FAIL|NO_BASELINE|NO_AVG> baseline=<..> goal=<..> op=<>=|<=> score_pct=<..> key=<..>
#
# Return:
#   0 PASS
#   1 FAIL
#   2 cannot evaluate (no baseline or no avg)
# -----------------------------------------------------------------------------
perf_sysbench_gate_eval_line() {
    f=$1
    sb_case=$2
    thr=$3
    metric=$4
    avg=$5
    delta=$6
 
    if [ -z "$avg" ]; then
        echo "status=NO_AVG baseline=NA goal=NA op=NA score_pct=NA key=NA"
        return 2
    fi
 
    key=$(perf_sysbench_baseline_key "$sb_case" "$metric" "$thr")
    base=$(perf_baseline_get_value "$f" "$key")
    if [ -z "$base" ]; then
        echo "status=NO_BASELINE baseline=NA goal=NA op=NA score_pct=NA key=$key"
        return 2
    fi
 
    dir=$(perf_metric_direction "$metric")
 
    if [ "$dir" = "higher" ]; then
        one_minus=$(perf_f_sub "1.0" "$delta")
        goal=$(perf_f_mul "$base" "$one_minus")
        score=$(perf_f_pct "$avg" "$base")
        if perf_f_ge "$avg" "$goal"; then
            echo "status=PASS baseline=$base goal=$goal op=>= score_pct=${score:-NA} key=$key"
            return 0
        fi
        echo "status=FAIL baseline=$base goal=$goal op=>= score_pct=${score:-NA} key=$key"
        return 1
    fi
 
    # lower-is-better
    one_plus=$(perf_f_add "1.0" "$delta")
    goal=$(perf_f_mul "$base" "$one_plus")
    score=$(perf_f_pct "$base" "$avg")  # higher is better (baseline/avg)
    if perf_f_le "$avg" "$goal"; then
        echo "status=PASS baseline=$base goal=$goal op=<= score_pct=${score:-NA} key=$key"
        return 0
    fi
    echo "status=FAIL baseline=$base goal=$goal op=<= score_pct=${score:-NA} key=$key"
    return 1
}

# Warn when a path is on tmpfs/ramfs (fileio numbers will be meaningless for storage perf)
perf_fs_sanity_warn() {
    p=$1
    [ -n "$p" ] || return 0

    # Find fstype for the *longest matching* mountpoint in /proc/mounts
    fs=$(
        awk -v path="$p" '
          function is_prefix(mp, s) {
            if (mp == "/") return 1
            return (index(s, mp) == 1)
          }
          BEGIN { best_len = -1; best_fs = "" }
          {
            mp = $2
            f  = $3
            if (is_prefix(mp, path)) {
              l = length(mp)
              if (l > best_len) { best_len = l; best_fs = f }
            }
          }
          END { print best_fs }
        ' /proc/mounts 2>/dev/null
    )

    if [ "$fs" = "tmpfs" ] || [ "$fs" = "ramfs" ]; then
        log_warn "FILEIO safety: FILEIO_DIR=$p is on $fs. Results will reflect RAM/tmpfs, not storage."
        log_warn "FILEIO safety: choose ext4/xfs-backed path (example: /var/tmp/sysbench_fileio or under /)."
    fi
}

# Parse sysbench fileio throughput. sysbench prints:
#   read, MiB/s:  <num>
#   written, MiB/s: <num>
# Some builds show MB/s; handle both.
perf_sysbench_parse_fileio_read_mibps() {
    log_file=$1
    [ -f "$log_file" ] || { echo ""; return 0; }

    v=$(
        sed -n \
          -e 's/^[[:space:]]*read,[[:space:]]*MiB\/s:[[:space:]]*\([0-9.][0-9.]*\).*$/\1/p' \
          -e 's/^[[:space:]]*read,[[:space:]]*MB\/s:[[:space:]]*\([0-9.][0-9.]*\).*$/\1/p' \
          "$log_file" 2>/dev/null | head -n 1
    )
    printf '%s' "$v"
}

perf_sysbench_parse_fileio_written_mibps() {
    log_file=$1
    [ -f "$log_file" ] || { echo ""; return 0; }

    v=$(
        sed -n \
          -e 's/^[[:space:]]*written,[[:space:]]*MiB\/s:[[:space:]]*\([0-9.][0-9.]*\).*$/\1/p' \
          -e 's/^[[:space:]]*written,[[:space:]]*MB\/s:[[:space:]]*\([0-9.][0-9.]*\).*$/\1/p' \
          "$log_file" 2>/dev/null | head -n 1
    )
    printf '%s' "$v"
}

perf_mibps_to_gbps() {
    mibps=$1
    [ -n "$mibps" ] || { echo ""; return 0; }
    awk -v v="$mibps" 'BEGIN{printf "%.4f", (v/1024.0)}'
}

perf_sysbench_fileio_prepare() {
    dir=$1
    threads=$2
    seed=$3
    total=$4
    num=$5
    blksz=$6
    iomode=$7
    extra=$8
    out_log=$9
 
    [ -n "$dir" ] || return 1
    mkdir -p "$dir" 2>/dev/null || true
 
    (
        cd "$dir" 2>/dev/null || exit 1
 
        set -- sysbench --rand-seed="$seed" --threads="$threads" fileio \
          --file-total-size="$total" \
          --file-num="$num" \
          --file-block-size="$blksz" \
          --file-io-mode="$iomode" \
          --file-test-mode=seqwr
 
        if [ -n "$extra" ]; then
          # shellcheck disable=SC2086
          set -- "$@" $extra
        fi
 
        set -- "$@" prepare
        perf_run_cmd_tee "$out_log" "$@"
    )
}
 
perf_sysbench_fileio_cleanup() {
    dir=$1
    total=$2
    num=$3
    blksz=$4
    iomode=$5
    extra=$6
 
    [ -n "$dir" ] || return 0
 
    (
        cd "$dir" 2>/dev/null || exit 0
 
        set -- sysbench fileio \
          --file-total-size="$total" \
          --file-num="$num" \
          --file-block-size="$blksz" \
          --file-io-mode="$iomode" \
          --file-test-mode=seqwr
 
        if [ -n "$extra" ]; then
          # shellcheck disable=SC2086
          set -- "$@" $extra
        fi
 
        set -- "$@" cleanup
        "$@" >/dev/null 2>&1 || true
    )
    return 0
}
 
# Runs one fileio mode and prints one line of kv tokens:
#   mode=seqwr mibps=0.40 gbps=0.0004
perf_sysbench_fileio_run_mode() {
    dir=$1
    threads=$2
    seed=$3
    time=$4
    total=$5
    num=$6
    blksz=$7
    iomode=$8
    extra=$9
    mode=${10}
    out_log=${11}
 
    [ -n "$dir" ] || { echo ""; return 1; }
 
    (
        cd "$dir" 2>/dev/null || exit 1
 
        set -- sysbench --time="$time" --rand-seed="$seed" --threads="$threads" fileio \
          --file-total-size="$total" \
          --file-num="$num" \
          --file-block-size="$blksz" \
          --file-io-mode="$iomode" \
          --file-test-mode="$mode"
 
        if [ -n "$extra" ]; then
          # shellcheck disable=SC2086
          set -- "$@" $extra
        fi
 
        set -- "$@" run
        perf_run_cmd_tee "$out_log" "$@"
    ) || true
 
    case "$mode" in
      seqrd)
        r=$(perf_sysbench_parse_fileio_read_mibps "$out_log")
        g=$(perf_mibps_to_gbps "$r")
        printf 'mode=%s mibps=%s gbps=%s\n' "$mode" "${r:-}" "${g:-}"
        ;;
      seqwr|rndwr)
        w=$(perf_sysbench_parse_fileio_written_mibps "$out_log")
        printf 'mode=%s mibps=%s gbps=\n' "$mode" "${w:-}"
        ;;
      *)
        printf 'mode=%s mibps= gbps=\n' "$mode"
        ;;
    esac
    return 0
}

# Extract sysbench fileio throughput (MiB/s) for "read" or "written"
# Example lines:
#   Throughput:
#     read, MiB/s:                  4755.69
#     written, MiB/s:               3849.61
perf_sysbench_parse_fileio_mibps() {
    log_file=$1
    which=$2  # "read" or "written"

    [ -f "$log_file" ] || { printf '%s' ""; return 0; }
    [ -n "$which" ] || which="read"

    v=$(
        sed -n \
          -e "s/^[[:space:]]*$which,[[:space:]]*MiB\/s:[[:space:]]*\\([0-9][0-9.]*\\).*$/\\1/p" \
          "$log_file" 2>/dev/null | head -n 1
    )
    printf '%s' "$v"
}

# Return filesystem type of the mount backing a path (best-effort)
perf_path_fstype() {
    p=$1
    [ -n "$p" ] || { echo "unknown"; return 0; }

    # Normalize path
    case "$p" in
        /*) : ;;
        *) p="/$p" ;;
    esac

    # Pick the longest mountpoint prefix match from /proc/mounts
    awk -v P="$p" '
      function is_prefix(mp, path) {
        if (mp == "/") return 1
        return (index(path, mp "/") == 1 || path == mp)
      }
      {
        mp=$2; fs=$3
        if (is_prefix(mp, P)) {
          if (length(mp) > bestlen) { bestlen=length(mp); bestfs=fs; bestmp=mp }
        }
      }
      END {
        if (bestfs == "") bestfs="unknown"
        print bestfs
      }
    ' /proc/mounts 2>/dev/null
}

perf_is_tmpfs_path() {
    p=$1
    fs=$(perf_path_fstype "$p")
    case "$fs" in
        tmpfs|ramfs) return 0 ;;
    esac
    return 1
}

# Choose a writable directory that is NOT on tmpfs/ramfs.
# Echoes chosen dir (creates it).
perf_pick_fileio_dir() {
    # Candidates (prefer real disk)
    for d in \
        "/var/tmp/sysbench_fileio" \
        "/root/sysbench_fileio" \
        "/home/root/sysbench_fileio" \
        "/sysbench_fileio"
    do
        mkdir -p "$d" 2>/dev/null || continue
        if ! perf_is_tmpfs_path "$d"; then
            echo "$d"
            return 0
        fi
    done

    # Last resort (will be tmpfs on many systems)
    d="/tmp/sysbench_fileio"
    mkdir -p "$d" 2>/dev/null || true
    echo "$d"
    return 0
}

# Sysbench default threads is 1. Only pass --threads for non-1 to keep behavior consistent.
sysbench_threads_opt() {
  t=$1
  if [ -n "$t" ] && [ "$t" != "1" ]; then
    printf '%s' "--threads=$t"
  fi
}

# Treat placeholder baselines (__FILL_ME__) as "no baseline" (report-only, no gate fail).
perf_sysbench_gate_eval_line_safe() {
  f=$1
  sb_case=$2
  thr=$3
  metric=$4
  avg=$5
  delta=$6

  if [ -z "$avg" ]; then
    echo "status=NO_AVG baseline=NA goal=NA op=NA score_pct=NA key=NA"
    return 2
  fi

  if command -v perf_sysbench_baseline_key >/dev/null 2>&1 && command -v perf_baseline_get_value >/dev/null 2>&1; then
    key=$(perf_sysbench_baseline_key "$sb_case" "$metric" "$thr")
    base=$(perf_baseline_get_value "$f" "$key")
    if [ -z "$base" ] || [ "$base" = "__FILL_ME__" ]; then
      echo "status=NO_BASELINE baseline=NA goal=NA op=NA score_pct=NA key=$key"
      return 2
    fi
  fi

  perf_sysbench_gate_eval_line "$f" "$sb_case" "$thr" "$metric" "$avg" "$delta"
  return $?
}

###############################################################################
# Tiotest helpers (Storage_Tiotest)
###############################################################################
tiotest_is_tmpfs_path() {
  # Best-effort: detect if a path is on tmpfs
  # Usage: tiotest_is_tmpfs_path /path ; returns 0 if tmpfs, 1 otherwise
  p=$1
  [ -z "$p" ] && return 1
  if command -v df >/dev/null 2>&1; then
    # BusyBox df prints "Filesystem" and type may not be available.
    # Use /proc/mounts as primary.
    :
  fi
  if [ -r /proc/mounts ]; then
    # Find the mountpoint for p and check fstype
    # Simple heuristic: if any mount entry matches prefix and fstype=tmpfs
    mp=""
    while read -r _dev mnt fstype rest; do
      case "$p" in
        "$mnt"|"$mnt"/*)
          # pick longest matching mountpoint
          if [ -z "$mp" ] || [ "${#mnt}" -gt "${#mp}" ]; then
            mp="$mnt"
            mpfstype="$fstype"
          fi
          ;;
      esac
    done </proc/mounts
    [ "${mpfstype:-}" = "tmpfs" ] && return 0
  fi
  return 1
}

tiotest_drop_caches_best_effort() {
  # Avoid SC2015; best-effort only
  if command -v perf_drop_caches >/dev/null 2>&1; then
    perf_drop_caches 2>/dev/null || true
    return 0
  fi
  # fallback
  if [ -w /proc/sys/vm/drop_caches ]; then
    sync 2>/dev/null || true
    echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
    return 0
  fi
  return 1
}

tiotest_extract_mbps() {
  # Extract MB/s rate from tiotest tables; returns the LAST matching row.
  # Args: <logfile> <label_regex>   (ex: "Write" or "Read")
  logf=$1
  lbl=$2
 
  awk -v lbl="$lbl" '
    BEGIN{v=""}
    /^[[:space:]]*\|/ && $0 ~ lbl {
      if (match($0, /[0-9]+(\.[0-9]+)?[[:space:]]*MB\/s/)) {
        s=substr($0, RSTART, RLENGTH)
        gsub(/[[:space:]]*MB\/s/, "", s)
        v=s
      }
    }
    END{
      if (v=="") exit 1
      print v
    }
  ' "$logf"
}

tiotest_extract_iops() {
  # Many tiotest builds print IOPS only for random rows; if absent returns empty.
  # Args: <logfile> <label_regex>
  logf=$1
  lbl=$2

  # Try to capture number in an "IOPS" column if present.
  # We do not assume fixed column count; instead grep a number near "IOPS".
  awk -v lbl="$lbl" '
    BEGIN{v=""}
    /^\|/ && $0 ~ lbl {
      # If line contains IOPS number, try to pick it.
      # Common format: "... | 11624 | ..."
      # We take the largest integer on the line as a heuristic.
      nmax=""
      for (i=1;i<=NF;i++){
        if ($i ~ /^[0-9]+$/) {
          if (nmax=="" || $i+0 > nmax+0) nmax=$i
        }
      }
      v=nmax
    }
    END{ print v }
  ' "$logf" 2>/dev/null
}

tiotest_extract_latency_block() {
  logf=$1
  item=$2   # "Write" / "Read" / "Random Write" / "Random Read"
 
  awk -v item="$item" '
    BEGIN { inblk=0; la=""; lm=""; p2=""; p10="" }
 
    /^Tiotest latency results/ { inblk=1; next }
    inblk==1 && /^`/ { inblk=0 }                  # end of ascii table (best-effort)
 
    # Match the latency row for the requested item
    inblk==1 && $0 ~ /^\|/ && $0 ~ ("|[[:space:]]*" item "[[:space:]]*\\|") {
      # Extract numbers that appear *after* the item label.
      # Latency rows look like:
      # | Write | 0.002 ms | 0.022 ms | 0.00000 | 0.00000 |
      # We collect numeric tokens only, ignoring "ms" and pipes.
      n=0
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
          n++
          if (n==1) la=$i
          else if (n==2) lm=$i
          else if (n==3) p2=$i
          else if (n==4) p10=$i
        }
      }
    }
 
    END {
      # Print only numeric fields; empty means "not found"
      printf "%s\t%s\t%s\t%s\n", la, lm, p2, p10
    }
  ' "$logf" 2>/dev/null
}

tiotest_metrics_append() {
  mf=$1; mode=$2; thr=$3; mbps=$4; iops=$5; latavg=$6; latmax=$7; pct2=$8; pct10=$9
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$mode" "$thr" "${mbps:-}" "${iops:-}" "${latavg:-}" "${latmax:-}" "${pct2:-}" "${pct10:-}" >>"$mf"
}

# ---------------- perf helpers: normalize/validate numeric metrics ----------------
 
perf_norm_metric() {
  case "${1:-}" in
    ""|"unknown"|"UNKNOWN"|"NA"|"N/A"|"n/a") printf "%s" "NA" ;;
    *) printf "%s" "$1" ;;
  esac
}
 
perf_is_number() {
  # integer or decimal (e.g., 10, 10.5, 0.000)
  echo "${1:-}" | awk '
    $0 ~ /^[0-9]+([.][0-9]+)?$/ { exit 0 }
    { exit 1 }
  '
}
 
perf_append_if_number() {
  # $1=file $2=value
  if perf_is_number "${2:-}"; then
    perf_values_append "$1" "$2"
  fi
}

tiotest_build_common_args() {
  # Helper: build common flags list for tiotest
  # Echoes args; caller can use: set -- $(tiotest_build_common_args ...)
  # Args:
  # threads dir use_raw block_bytes file_mb rnd_ops hide_lat terse W S c debug offset_mb offset_first
  tt=$1; dir=$2; use_raw=$3
  bs=$4; fmb=$5; rops=$6
  hide_lat=$7; terse=$8; wphase=$9; syncw=${10}; cons=${11}; dbg=${12}
  offmb=${13}; ofirst=${14}

  args="-t $tt -d $dir -b $bs -f $fmb"
  if [ "$use_raw" = "1" ]; then
    args="$args -R"
    [ -n "$offmb" ] && args="$args -o $offmb"
    [ "$ofirst" = "1" ] && args="$args -O"
  fi
  [ -n "$rops" ] && args="$args -r $rops"
  [ "$hide_lat" = "1" ] && args="$args -L"
  [ "$terse" = "1" ] && args="$args -T"
  [ "$wphase" = "1" ] && args="$args -W"
  [ "$syncw" = "1" ] && args="$args -S"
  [ "$cons" = "1" ] && args="$args -c"
  [ -n "$dbg" ] && args="$args -D $dbg"

  echo "$args"
}

perf_tiotest_run_seq_pair() {
  # Run sequential Write+Read in ONE invocation and collect:
  #  - MB/s for Write and Read
  #  - IOPS (estimated from MB/s and block size)
  #  - Latency stats if present (avg/max/%>2s/%>10s), otherwise leave empty
  #
  # Args:
  # bin threads dir use_raw seq_block seq_file_mb hide_lat terse W S c debug offset_mb offset_first logf metrics
  bin=$1; tt=$2; dir=$3; use_raw=$4
  bs=$5; fmb=$6
  hide_lat=$7; terse=$8; wphase=$9; syncw=${10}; cons=${11}; dbg=${12}
  offmb=${13}; ofirst=${14}
  logf=${15}; metrics=${16}
 
  : >"$logf" 2>/dev/null || true
 
  common=$(tiotest_build_common_args "$tt" "$dir" "$use_raw" "$bs" "$fmb" "" \
    "$hide_lat" "$terse" "$wphase" "$syncw" "$cons" "$dbg" "$offmb" "$ofirst")
 
  log_info "RUN: $bin $common -k 1 -k 3"
  # shellcheck disable=SC2086
  "$bin" $common -k 1 -k 3 >>"$logf" 2>&1 || true
 
  # ---------------- MB/s ----------------
  seqwr_mbps=$(tiotest_extract_mbps "$logf" "Write" 2>/dev/null || true)
  seqrd_mbps=$(tiotest_extract_mbps "$logf" "Read" 2>/dev/null || true)
 
  # ---------------- IOPS estimate ----------------
  seqwr_iops=""
  seqrd_iops=""
  if [ -n "$bs" ] && [ "$bs" -gt 0 ] 2>/dev/null; then
    if [ -n "$seqwr_mbps" ]; then
      seqwr_iops=$(awk -v mbps="$seqwr_mbps" -v b="$bs" 'BEGIN{ if (b>0) printf "%.0f", (mbps*1024*1024)/b }' 2>/dev/null)
    fi
    if [ -n "$seqrd_mbps" ]; then
      seqrd_iops=$(awk -v mbps="$seqrd_mbps" -v b="$bs" 'BEGIN{ if (b>0) printf "%.0f", (mbps*1024*1024)/b }' 2>/dev/null)
    fi
  fi
 
  # ---------------- Latency (best-effort) ----------------
  # Strictly parse numeric columns from:
  # | Write | <avg> ms | <max> ms | <pct2> | <pct10> |
  # | Read  | <avg> ms | <max> ms | <pct2> | <pct10> |
  # Ensures we never output "Write"/"|" into metrics.tsv.
  seqwr_latavg=""; seqwr_latmax=""; seqwr_pct2=""; seqwr_pct10=""
  seqrd_latavg=""; seqrd_latmax=""; seqrd_pct2=""; seqrd_pct10=""
 
  row=$(awk '
    BEGIN { inlat=0; la=""; lm=""; p2=""; p10="" }
    /^Tiotest latency results/ { inlat=1; next }
    inlat==1 && $0 ~ /^\|/ && $0 ~ /|[[:space:]]*Write[[:space:]]*\|/ {
      n=0
      for (i=1;i<=NF;i++){
        if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
          n++
          if (n==1) la=$i
          else if (n==2) lm=$i
          else if (n==3) p2=$i
          else if (n==4) p10=$i
        }
      }
    }
    END {
      if (la=="") exit 1
      printf "%s\t%s\t%s\t%s\n", la, lm, p2, p10
    }
  ' "$logf" 2>/dev/null || true)
 
  if [ -n "$row" ]; then
    # split by tabs
    seqwr_latavg=$(printf '%s' "$row" | awk -F'\t' '{print $1}')
    seqwr_latmax=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
    seqwr_pct2=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
    seqwr_pct10=$(printf '%s' "$row" | awk -F'\t' '{print $4}')
  fi
 
  row=$(awk '
    BEGIN { inlat=0; la=""; lm=""; p2=""; p10="" }
    /^Tiotest latency results/ { inlat=1; next }
    inlat==1 && $0 ~ /^\|/ && $0 ~ /|[[:space:]]*Read[[:space:]]*\|/ {
      n=0
      for (i=1;i<=NF;i++){
        if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
          n++
          if (n==1) la=$i
          else if (n==2) lm=$i
          else if (n==3) p2=$i
          else if (n==4) p10=$i
        }
      }
    }
    END {
      if (la=="") exit 1
      printf "%s\t%s\t%s\t%s\n", la, lm, p2, p10
    }
  ' "$logf" 2>/dev/null || true)
 
  if [ -n "$row" ]; then
    seqrd_latavg=$(printf '%s' "$row" | awk -F'\t' '{print $1}')
    seqrd_latmax=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
    seqrd_pct2=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
    seqrd_pct10=$(printf '%s' "$row" | awk -F'\t' '{print $4}')
  fi
 
  # ---------------- Emit metrics (8 columns) ----------------
  tiotest_metrics_append "$metrics" "seqwr" "$tt" "$seqwr_mbps" "$seqwr_iops" \
    "$seqwr_latavg" "$seqwr_latmax" "$seqwr_pct2" "$seqwr_pct10"
 
  tiotest_metrics_append "$metrics" "seqrd" "$tt" "$seqrd_mbps" "$seqrd_iops" \
    "$seqrd_latavg" "$seqrd_latmax" "$seqrd_pct2" "$seqrd_pct10"
 
  if [ -z "$seqwr_mbps" ] && [ -z "$seqrd_mbps" ]; then
    return 1
  fi
  return 0
}

perf_tiotest_run_rnd_pair() {
  # Random pair runner with robust rndwr + rndrd capture and clean 8-column TSV emission.
  # Primary: run BOTH (Write+Read) using -k 1 -k 3 (matches your proven manual command).
  # Fallback: legacy probing if Read doesn't appear (some builds behave oddly / pid-file issues).
  #
  # Args:
  # bin threads dir use_raw rnd_block rnd_file_mb rnd_ops hide_lat terse W S c debug offset_mb offset_first logf metrics
  bin=$1; tt=$2; dir=$3; use_raw=$4
  bs=$5; fmb=$6; rops=$7
  hide_lat=$8; terse=$9; wphase=${10}; syncw=${11}; cons=${12}; dbg=${13}
  offmb=${14}; ofirst=${15}
  logf=${16}; metrics=${17}
 
  : >"$logf" 2>/dev/null || true
 
  common=$(tiotest_build_common_args "$tt" "$dir" "$use_raw" "$bs" "$fmb" "$rops" \
    "$hide_lat" "$terse" "$wphase" "$syncw" "$cons" "$dbg" "$offmb" "$ofirst")
 
  tmp_both="${logf}.rndboth.tmp"
  tmp_wr="${logf}.rndwr.tmp"
  tmp_rd="${logf}.rndrd.tmp"
  : >"$tmp_both" 2>/dev/null || true
  : >"$tmp_wr" 2>/dev/null || true
  : >"$tmp_rd" 2>/dev/null || true
 
  rndwr_mbps=""; rndwr_iops=""; rndwr_latavg=""; rndwr_latmax=""; rndwr_pct2=""; rndwr_pct10=""
  rndrd_mbps=""; rndrd_iops=""; rndrd_latavg=""; rndrd_latmax=""; rndrd_pct2=""; rndrd_pct10=""
 
  # ---------------- Primary: BOTH random write + random read ----------------
  log_info "RUN (rnd both): $bin $common -k 1 -k 3"
  # shellcheck disable=SC2086
  "$bin" $common -k 1 -k 3 >"$tmp_both" 2>&1 || true
  cat "$tmp_both" >>"$logf" 2>/dev/null || true
 
  rndwr_mbps=$(tiotest_extract_mbps "$tmp_both" "Write" 2>/dev/null || true)
  rndrd_mbps=$(tiotest_extract_mbps "$tmp_both" "Read" 2>/dev/null || true)
 
  # Latency parsing (best-effort): strict match "| Write |" and "| Read |"
  row=$(awk '
    BEGIN { inlat=0; la=""; lm=""; p2=""; p10="" }
    /^Tiotest latency results/ { inlat=1; next }
    inlat==1 && $0 ~ /^\|/ && $0 ~ /|[[:space:]]*Write[[:space:]]*\|/ {
      n=0
      for (i=1;i<=NF;i++){
        if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
          n++
          if (n==1) la=$i
          else if (n==2) lm=$i
          else if (n==3) p2=$i
          else if (n==4) p10=$i
        }
      }
    }
    END {
      if (la=="") exit 1
      printf "%s\t%s\t%s\t%s\n", la, lm, p2, p10
    }
  ' "$tmp_both" 2>/dev/null || true)
  if [ -n "$row" ]; then
    rndwr_latavg=$(printf '%s' "$row" | awk -F'\t' '{print $1}')
    rndwr_latmax=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
    rndwr_pct2=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
    rndwr_pct10=$(printf '%s' "$row" | awk -F'\t' '{print $4}')
  fi
 
  row=$(awk '
    BEGIN { inlat=0; la=""; lm=""; p2=""; p10="" }
    /^Tiotest latency results/ { inlat=1; next }
    inlat==1 && $0 ~ /^\|/ && $0 ~ /|[[:space:]]*Read[[:space:]]*\|/ {
      n=0
      for (i=1;i<=NF;i++){
        if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
          n++
          if (n==1) la=$i
          else if (n==2) lm=$i
          else if (n==3) p2=$i
          else if (n==4) p10=$i
        }
      }
    }
    END {
      if (la=="") exit 1
      printf "%s\t%s\t%s\t%s\n", la, lm, p2, p10
    }
  ' "$tmp_both" 2>/dev/null || true)
  if [ -n "$row" ]; then
    rndrd_latavg=$(printf '%s' "$row" | awk -F'\t' '{print $1}')
    rndrd_latmax=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
    rndrd_pct2=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
    rndrd_pct10=$(printf '%s' "$row" | awk -F'\t' '{print $4}')
  fi
 
  # If Read missing, fallback to legacy probing
  if [ -z "$rndrd_mbps" ]; then
    log_info "rndrd missing in primary run; falling back to legacy probing"
 
    # Phase 1: try to collect write
    log_info "RUN (rndwr fallback): $bin $common -k 0 -k 2 -k 3"
    # shellcheck disable=SC2086
    "$bin" $common -k 0 -k 2 -k 3 >"$tmp_wr" 2>&1 || true
    cat "$tmp_wr" >>"$logf" 2>/dev/null || true
    [ -z "$rndwr_mbps" ] && rndwr_mbps=$(tiotest_extract_mbps "$tmp_wr" "Write" 2>/dev/null || true)
 
    # Phase 2: prep + attempt read (best-effort)
    log_info "RUN (rndrd+prep fallback): $bin -t $tt -d $dir -b $bs -f $fmb -k 1 -k 2 -k 3 ; then $bin $common -k 0 -k 1 -k 2"
    "$bin" -t "$tt" -d "$dir" -b "$bs" -f "$fmb" -k 1 -k 2 -k 3 >>"$tmp_rd" 2>&1 || true
    # shellcheck disable=SC2086
    "$bin" $common -k 0 -k 1 -k 2 >>"$tmp_rd" 2>&1 || true
    cat "$tmp_rd" >>"$logf" 2>/dev/null || true
 
    [ -z "$rndwr_mbps" ] && rndwr_mbps=$(tiotest_extract_mbps "$tmp_rd" "Write" 2>/dev/null || true)
    rndrd_mbps=$(tiotest_extract_mbps "$tmp_rd" "Read" 2>/dev/null || true)
 
    # Latency from fallback read log (if any)
    if [ -z "$rndwr_latavg" ]; then
      row=$(awk '
        BEGIN { inlat=0; la=""; lm=""; p2=""; p10="" }
        /^Tiotest latency results/ { inlat=1; next }
        inlat==1 && $0 ~ /^\|/ && $0 ~ /|[[:space:]]*Write[[:space:]]*\|/ {
          n=0
          for (i=1;i<=NF;i++){
            if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
              n++
              if (n==1) la=$i
              else if (n==2) lm=$i
              else if (n==3) p2=$i
              else if (n==4) p10=$i
            }
          }
        }
        END { if (la=="") exit 1; printf "%s\t%s\t%s\t%s\n", la, lm, p2, p10 }
      ' "$tmp_rd" 2>/dev/null || true)
      if [ -n "$row" ]; then
        rndwr_latavg=$(printf '%s' "$row" | awk -F'\t' '{print $1}')
        rndwr_latmax=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
        rndwr_pct2=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
        rndwr_pct10=$(printf '%s' "$row" | awk -F'\t' '{print $4}')
      fi
    fi
 
    if [ -z "$rndrd_latavg" ]; then
      row=$(awk '
        BEGIN { inlat=0; la=""; lm=""; p2=""; p10="" }
        /^Tiotest latency results/ { inlat=1; next }
        inlat==1 && $0 ~ /^\|/ && $0 ~ /|[[:space:]]*Read[[:space:]]*\|/ {
          n=0
          for (i=1;i<=NF;i++){
            if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
              n++
              if (n==1) la=$i
              else if (n==2) lm=$i
              else if (n==3) p2=$i
              else if (n==4) p10=$i
            }
          }
        }
        END { if (la=="") exit 1; printf "%s\t%s\t%s\t%s\n", la, lm, p2, p10 }
      ' "$tmp_rd" 2>/dev/null || true)
      if [ -n "$row" ]; then
        rndrd_latavg=$(printf '%s' "$row" | awk -F'\t' '{print $1}')
        rndrd_latmax=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
        rndrd_pct2=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
        rndrd_pct10=$(printf '%s' "$row" | awk -F'\t' '{print $4}')
      fi
    fi
  fi
 
  # ---------------- IOPS estimation ----------------
  if [ -n "$bs" ] && [ "$bs" -gt 0 ] 2>/dev/null; then
    if [ -n "$rndwr_mbps" ]; then
      rndwr_iops=$(awk -v mbps="$rndwr_mbps" -v b="$bs" 'BEGIN{ if (b>0) printf "%.0f", (mbps*1024*1024)/b }' 2>/dev/null)
    fi
    if [ -n "$rndrd_mbps" ]; then
      rndrd_iops=$(awk -v mbps="$rndrd_mbps" -v b="$bs" 'BEGIN{ if (b>0) printf "%.0f", (mbps*1024*1024)/b }' 2>/dev/null)
    fi
  fi
 
  # ---------------- Emit metrics (8 columns) ----------------
  tiotest_metrics_append "$metrics" "rndwr" "$tt" "$rndwr_mbps" "$rndwr_iops" \
    "$rndwr_latavg" "$rndwr_latmax" "$rndwr_pct2" "$rndwr_pct10"
 
  tiotest_metrics_append "$metrics" "rndrd" "$tt" "$rndrd_mbps" "$rndrd_iops" \
    "$rndrd_latavg" "$rndrd_latmax" "$rndrd_pct2" "$rndrd_pct10"
 
  rm -f "$tmp_both" "$tmp_wr" "$tmp_rd" 2>/dev/null || true
 
  # Success if we got rndwr or rndrd
  [ -n "$rndwr_mbps" ] && return 0
  [ -n "$rndrd_mbps" ] && return 0
  return 1
}

# --- Tiotest baseline format support (suite=... threads=... metric=... baseline=... goal=... op=...) ---
perf_tiotest_baseline_lookup_kv() {
  f=$1; suite=$2; thr=$3; metric=$4
  # prints: "baseline op goal" or empty
  awk -v s="$suite" -v t="$thr" -v m="$metric" '
    {
      sv=""; tv=""; mv=""; b=""; g=""; o="";
      for (i=1; i<=NF; i++) {
        split($i, a, "=");
        if (a[1]=="suite") sv=a[2];
        else if (a[1]=="threads") tv=a[2];
        else if (a[1]=="metric") mv=a[2];
        else if (a[1]=="baseline") b=a[2];
        else if (a[1]=="goal") g=a[2];
        else if (a[1]=="op") o=a[2];
      }
      if (sv==s && tv==t && mv==m) {
        print b, o, g;
        exit;
      }
    }
  ' "$f"
}

perf_tiotest_baseline_prefix() {
  suite=$1
  thr=$2
  metric=$3
  echo "${suite}.${thr}.${metric}"
}

# Tiotest-specific gating wrapper.
# Purpose: isolate tiotest gating logic from sysbench helpers to avoid regressions.
# Contract: returns 0=PASS, 1=FAIL, 2=NO_BASELINE/NO_AVG style (same shape as sysbench wrapper).
perf_tiotest_gate_eval_line_safe() {
  f=$1
  suite=$2
  thr=$3
  metric=$4
  avg=$5
  delta=$6

  if [ -z "$avg" ]; then
    echo "status=NO_AVG baseline=NA goal=NA op=NA score_pct=NA key=NA"
    return 2
  fi

  prefix=$(perf_tiotest_baseline_prefix "$suite" "$thr" "$metric")

  base=$(perf_baseline_get_value "$f" "${prefix}.baseline")
  goal=$(perf_baseline_get_value "$f" "${prefix}.goal")
  op=$(perf_baseline_get_value "$f" "${prefix}.op")

  if [ -z "$base" ] || [ -z "$op" ] || [ "$base" = "__FILL_ME__" ]; then
    echo "status=NO_BASELINE baseline=NA goal=NA op=NA score_pct=NA key=${prefix}"
    return 2
  fi

  # If goal missing, derive from baseline and delta (best-effort).
  if [ -z "$goal" ] || [ "$goal" = "__FILL_ME__" ]; then
    # delta default to 0 if empty/non-numeric
    case "$delta" in
      ""|*[!0-9.]*)
        delta=0
        ;;
    esac

    case "$op" in
      ">="|">")
        goal=$(awk -v b="$base" -v d="$delta" 'BEGIN{ printf "%.6f", (b+0)*(1.0-(d+0)) }' 2>/dev/null)
        ;;
      "<="|"<")
        goal=$(awk -v b="$base" -v d="$delta" 'BEGIN{ printf "%.6f", (b+0)*(1.0+(d+0)) }' 2>/dev/null)
        ;;
      "="|"==")
        goal=$base
        ;;
      *)
        echo "status=BAD_OP baseline=$base goal=NA op=$op score_pct=NA key=${prefix}"
        return 2
        ;;
    esac
  fi

  if [ -z "$goal" ]; then
    echo "status=NO_BASELINE baseline=$base goal=NA op=$op score_pct=NA key=${prefix}"
    return 2
  fi

  score=$(awk -v a="$avg" -v b="$base" 'BEGIN{ if ((b+0)>0) printf "%.1f", ((a+0)/(b+0))*100; else print "NA" }' 2>/dev/null)

  fail=0
  case "$op" in
    ">=") awk -v a="$avg" -v g="$goal" 'BEGIN{exit ((a+0) >= (g+0))?0:1}' || fail=1 ;;
    "<=") awk -v a="$avg" -v g="$goal" 'BEGIN{exit ((a+0) <= (g+0))?0:1}' || fail=1 ;;
    ">")  awk -v a="$avg" -v g="$goal" 'BEGIN{exit ((a+0) >  (g+0))?0:1}' || fail=1 ;;
    "<")  awk -v a="$avg" -v g="$goal" 'BEGIN{exit ((a+0) <  (g+0))?0:1}' || fail=1 ;;
    "="|"==") awk -v a="$avg" -v g="$goal" 'BEGIN{exit ((a+0) == (g+0))?0:1}' || fail=1 ;;
    *)
      echo "status=BAD_OP baseline=$base goal=$goal op=$op score_pct=$score key=${prefix}"
      return 2
      ;;
  esac

  if [ "$fail" -eq 0 ]; then
    echo "status=PASS baseline=$base goal=$goal op=$op score_pct=$score key=${prefix}"
    return 0
  fi

  echo "status=FAIL baseline=$base goal=$goal op=$op score_pct=$score key=${prefix}"
  return 1
}

###############################################################################
# Geekbench / Performance reusable helpers for lib_performance.sh
###############################################################################
# -----------------------------------------------------------------------------
# Small local-safe helpers (do not depend on other libs)
# -----------------------------------------------------------------------------
perf_nowstamp_safe() {
  if command -v nowstamp >/dev/null 2>&1; then
    nowstamp
  else
    date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date
  fi
}

perf_is_number_safe() {
  v=$1
  [ -n "$v" ] || return 1
  # Accept: 123 or 123.45
  case "$v" in
    *[!0-9.]*|"."|*.*.*) return 1 ;;
  esac
  w=$v
  if printf '%s' "$v" | grep -q '\.' 2>/dev/null; then
    w=$(printf '%s' "$v" | tr -d '.')
  fi
  [ -n "$w" ] || return 1
  case "$w" in *[!0-9]*) return 1 ;; esac
  return 0
}

perf_avg_file_safe() {
  file=$1
  [ -f "$file" ] || return 0
  awk '
    $0 ~ /^[0-9]+(\.[0-9]+)?$/ { n++; s+=$0 }
    END { if (n>0) printf "%.3f", s/n }
  ' "$file" 2>/dev/null
}

perf_csv_escape() {
  # Escape for putting inside "...", double quotes
  printf '%s' "$1" | sed 's/"/""/g'
}

# POSIX-safe: preserve rc without PIPESTATUS (no tee pipeline).
# If perf_run_cmd_tee exists, use it (it should already be POSIX-safe in your tree).
perf_run_cmd_tee_safe() {
  # perf_run_cmd_tee_safe LOGFILE -- cmd...
  logfile=$1
  shift
  if [ "${1:-}" = "--" ]; then
    shift
  fi

  : >"$logfile" 2>/dev/null || true

  if command -v perf_run_cmd_tee >/dev/null 2>&1; then
    perf_run_cmd_tee "$logfile" "$@"
    return $?
  fi

  # Fallback: capture output to logfile, then print logfile to console.
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL "$@" >"$logfile" 2>&1
    rc=$?
  else
    "$@" >"$logfile" 2>&1
    rc=$?
  fi

  cat "$logfile" 2>/dev/null || true
  return "$rc"
}

# -----------------------------------------------------------------------------
# Basic file + log helper
# -----------------------------------------------------------------------------

# perf_write_and_log FILE MESSAGE...
# Append message to file and also log_info to console
perf_write_and_log() {
  file=$1
  shift
  msg=$*
  [ -n "$file" ] || return 1
  printf "%s\n" "$msg" >>"$file" 2>/dev/null || true
  if command -v log_info >/dev/null 2>&1; then
    log_info "$msg"
  else
    printf "[INFO] %s\n" "$msg"
  fi
}

# -----------------------------------------------------------------------------
# Live progress runner
# -----------------------------------------------------------------------------

# perf_run_cmd_with_progress OUTDIR RUN_LOG HEARTBEAT_SECS LABEL -- CMD...
# - Streams raw command output to console
# - Writes raw output to RUN_LOG
# - Emits log_info progress + heartbeat lines while running
#
# Requires: mkfifo, sleep, awk (stdbuf optional)
perf_run_cmd_with_progress() {
  outdir=$1
  run_log=$2
  heartbeat_secs=$3
  label=$4
  shift 4
 
  mkdir -p "${outdir:-.}" 2>/dev/null || true
  : >"$run_log" 2>/dev/null || true
 
  case "${heartbeat_secs:-}" in
    ""|*[!0-9]*) heartbeat_secs=15 ;;
  esac
  if [ "$heartbeat_secs" -lt 1 ] 2>/dev/null; then
    heartbeat_secs=15
  fi
 
  if [ "${1:-}" != "--" ]; then
    log_warn "perf_run_cmd_with_progress: missing -- separator, falling back to tee"
    perf_run_cmd_tee_safe "$run_log" -- "$@"
    return $?
  fi
  shift
 
  tmpdir=$(mktemp -d "$outdir/.perftmp.XXXXXX" 2>/dev/null)
  if [ -z "${tmpdir:-}" ] || [ ! -d "$tmpdir" ]; then
    tmpdir=$(mktemp -d 2>/dev/null)
  fi
  if [ -z "${tmpdir:-}" ] || [ ! -d "$tmpdir" ]; then
    log_warn "perf_run_cmd_with_progress: mktemp failed, falling back to tee"
    perf_run_cmd_tee_safe "$run_log" -- "$@"
    return $?
  fi
 
  fifo="$tmpdir/fifo"
  status_file="$tmpdir/status"
  : >"$status_file" 2>/dev/null || true
 
  if ! mkfifo "$fifo" 2>/dev/null; then
    rm -rf "$tmpdir" 2>/dev/null || true
    log_warn "perf_run_cmd_with_progress: mkfifo failed, falling back to tee"
    perf_run_cmd_tee_safe "$run_log" -- "$@"
    return $?
  fi
 
  log_info "Progress, $label, started"
  log_info "Progress, command, $*"
  printf "%s\n" "$label, invoked, waiting for output" >"$status_file" 2>/dev/null || true
 
  if command -v stdbuf >/dev/null 2>&1; then
    (stdbuf -oL -eL "$@" >"$fifo" 2>&1) &
  else
    ("$@" >"$fifo" 2>&1) &
  fi
  pid=$!
 
  (
    while kill -0 "$pid" 2>/dev/null; do
      sleep "$heartbeat_secs" 2>/dev/null || break
      if kill -0 "$pid" 2>/dev/null; then
        s=$(cat "$status_file" 2>/dev/null)
        if [ -n "${s:-}" ]; then
          log_info "Progress, $s, still running"
        fi
      fi
    done
  ) &
  hbpid=$!
 
  mode=""
  sc=0
  mc=0
 
  while IFS= read -r line; do
    printf "%s\n" "$line"
    printf "%s\n" "$line" >>"$run_log" 2>/dev/null || true
 
    case "$line" in
      "Single-Core")
        mode="Single-Core"
        sc=0
        printf "%s\n" "$label, entered Single-Core" >"$status_file" 2>/dev/null || true
        log_info "Progress, $label, entered Single-Core"
        continue
        ;;
      "Multi-Core")
        mode="Multi-Core"
        mc=0
        printf "%s\n" "$label, entered Multi-Core" >"$status_file" 2>/dev/null || true
        log_info "Progress, $label, entered Multi-Core"
        continue
        ;;
      "Benchmark Summary")
        # Fix-1: stop workload tracking at summary to avoid
        # "Single-Core Score / Integer Score / Floating Point Score" being seen as workloads.
        mode=""
        printf "%s\n" "$label, entered Benchmark Summary" >"$status_file" 2>/dev/null || true
        log_info "Progress, $label, entered Benchmark Summary"
        continue
        ;;
      "System Information"|"CPU Information"|"Memory Information")
        # Defensive: these are not workloads; stop tracking.
        mode=""
        printf "%s\n" "$label, entered $line" >"$status_file" 2>/dev/null || true
        log_info "Progress, $label, entered $line"
        continue
        ;;
    esac
 
    if [ -n "$mode" ]; then
      name=$(
        printf "%s\n" "$line" |
          awk '
            function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
            {
              first=0
              for(i=1;i<=NF;i++){
                if($i ~ /^[0-9]+$/){ first=i; break }
              }
              if(first<=1) exit 1
              out=""
              for(i=1;i<first;i++){
                out = (out=="" ? $i : out " " $i)
              }
              out=trim(out)
              # Extra safety (even though we clear mode at Benchmark Summary)
              if (out=="Single-Core Score" || out=="Multi-Core Score" ||
                  out=="Integer Score" || out=="Floating Point Score") exit 1
              print out
            }
          ' 2>/dev/null
      )
 
      if [ -n "${name:-}" ]; then
        if [ "$mode" = "Single-Core" ]; then
          sc=$((sc + 1))
          printf "%s\n" "$label, Single-Core, $sc, $name" >"$status_file" 2>/dev/null || true
          log_info "Progress, $label, Single-Core, $sc, $name"
        else
          mc=$((mc + 1))
          printf "%s\n" "$label, Multi-Core, $mc, $name" >"$status_file" 2>/dev/null || true
          log_info "Progress, $label, Multi-Core, $mc, $name"
        fi
      fi
    fi
  done <"$fifo"
 
  wait "$pid"
  rc=$?
 
  kill "$hbpid" 2>/dev/null || true
  wait "$hbpid" 2>/dev/null || true
 
  rm -rf "$tmpdir" 2>/dev/null || true
 
  if [ "$rc" -eq 0 ]; then
    log_info "Progress, $label, completed, rc, 0"
  else
    log_warn "Progress, $label, completed, rc, $rc"
  fi
 
  return "$rc"
}

# -----------------------------------------------------------------------------
# Parsers, summary + workloads
# -----------------------------------------------------------------------------
# perf_parse_geekbench_summary_scores LOGFILE
# Prints: single_total single_int single_fp multi_total multi_int multi_fp
# Prints: st|si|sf|mt|mi|mf
perf_parse_geekbench_summary_scores() {
  logfile=$1
  [ -n "$logfile" ] || return 1
  [ -f "$logfile" ] || return 1
 
  awk '
    function clean(line) {
      gsub(/\r/, "", line)
      # strip common ANSI CSI sequences (best effort)
      gsub(/\033\[[0-9;]*[A-Za-z]/, "", line)
      return line
    }
    function last_int(line, n,a,i,t) {
      n=split(line, a, /[[:space:]]+/)
      for (i=n; i>=1; i--) {
        t=a[i]
        gsub(/\033\[[0-9;]*[A-Za-z]/, "", t)
        if (t ~ /^[0-9]+$/) return t
      }
      return ""
    }
 
    BEGIN{
      in_summary=0
      cur=""
      st=""; si=""; sf=""
      mt=""; mi=""; mf=""
    }
 
    { $0 = clean($0) }
 
    # Start summary (allow indentation)
    /^[[:space:]]*Benchmark Summary[[:space:]]*$/ { in_summary=1; cur=""; next }
 
    in_summary==1 {
      # If a new big header begins, stop
      if ($0 ~ /^[[:space:]]*System Information[[:space:]]*$/) { in_summary=0; next }
      if ($0 ~ /^[[:space:]]*CPU Information[[:space:]]*$/) { in_summary=0; next }
      if ($0 ~ /^[[:space:]]*Memory Information[[:space:]]*$/) { in_summary=0; next }
 
      if (index($0, "Single-Core Score") > 0) {
        v = last_int($0)
        if (v != "") { st=v; cur="single" }
        next
      }
      if (index($0, "Multi-Core Score") > 0) {
        v = last_int($0)
        if (v != "") { mt=v; cur="multi" }
        next
      }
 
      if (index($0, "Integer Score") > 0) {
        v = last_int($0)
        if (v != "") {
          if (cur=="single" && si=="") si=v
          else if (cur=="multi" && mi=="") mi=v
        }
        next
      }
      if (index($0, "Floating Point Score") > 0) {
        v = last_int($0)
        if (v != "") {
          if (cur=="single" && sf=="") sf=v
          else if (cur=="multi" && mf=="") mf=v
        }
        next
      }
      next
    }
 
    END{
      if (st!="" || mt!="") {
        printf "%s|%s|%s|%s|%s|%s\n", st, si, sf, mt, mi, mf
      }
    }
  ' "$logfile" 2>/dev/null
}

# perf_append_geekbench_workloads_csv LOGFILE TIMESTAMP TESTNAME ITER CSVFILE
# Appends rows:
# timestamp,test,iter,core_mode,workload,score,throughput
perf_append_geekbench_workloads_csv() {
  logfile=$1
  ts=$2
  testname=$3
  iter=$4
  csvfile=$5

  [ -n "$logfile" ] || return 1
  [ -n "$ts" ] || return 1
  [ -n "$testname" ] || return 1
  [ -n "$iter" ] || return 1
  [ -n "$csvfile" ] || return 1

  awk -v ts="$ts" -v test="$testname" -v iter="$iter" '
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    BEGIN{ mode=""; }

    /^[[:space:]]*Benchmark Summary/ { exit }

    /^[[:space:]]*Single-Core[[:space:]]*$/ { mode="Single-Core"; next }
    /^[[:space:]]*Multi-Core[[:space:]]*$/ { mode="Multi-Core"; next }

    mode!="" {
      score=""; name=""; thr=""; first=0

      for (i=1;i<=NF;i++){
        if ($i ~ /^[0-9]+$/) { first=i; score=$i; break }
      }
      if (first==0) next

      for (i=1;i<first;i++){
        name = (name=="" ? $i : name " " $i)
      }
      name=trim(name)

      # Skip summary-style score names if they ever appear in section output
      if (name=="Single-Core Score" || name=="Multi-Core Score" ||
          name=="Integer Score" || name=="Floating Point Score") {
        next
      }

      for (i=first+1;i<=NF;i++){
        thr = (thr=="" ? $i : thr " " $i)
      }
      thr=trim(thr)

      gsub(/"/, "\"\"", name)
      gsub(/"/, "\"\"", thr)

      printf "%s,%s,%s,%s,\"%s\",%s,\"%s\"\n", ts, test, iter, mode, name, score, thr
    }
  ' "$logfile" >>"$csvfile" 2>/dev/null || true
}


# -----------------------------------------------------------------------------
# Geekbench “readable” CSV init helpers (2 files)
# -----------------------------------------------------------------------------
perf_geekbench_summary_csv_init() {
  csvfile=$1
  [ -n "$csvfile" ] || return 0
  if [ ! -f "$csvfile" ] || [ ! -s "$csvfile" ]; then
    printf '%s\n' "timestamp,test,iteration,single_total,single_integer,single_float,multi_total,multi_integer,multi_float" >"$csvfile" 2>/dev/null || true
  fi
  return 0
}

# perf_geekbench_workloads_csv_init FILE
perf_geekbench_workloads_csv_init() {
  csvfile=$1
  [ -n "$csvfile" ] || return 0
  if [ ! -f "$csvfile" ] || [ ! -s "$csvfile" ]; then
    printf '%s\n' "timestamp,test,iteration,core_mode,workload,score,throughput" >"$csvfile" 2>/dev/null || true
  fi
  return 0
}


perf_geekbench_write_iter_summary_txt() {
  st=$1; si=$2; sf=$3
  mt=$4; mi=$5; mf=$6
  outfile=$7
 
  [ -n "$outfile" ] || return 1
 
  : >"$outfile" 2>/dev/null || true
 
  if [ -n "${st:-}" ]; then
    echo "Benchmark Summary" >>"$outfile"
    echo "  Single-Core Score: ${st}" >>"$outfile"
    [ -n "${si:-}" ] && echo "    Integer Score: ${si}" >>"$outfile"
    [ -n "${sf:-}" ] && echo "    Floating Point Score: ${sf}" >>"$outfile"
    echo "" >>"$outfile"
  fi
 
  if [ -n "${mt:-}" ]; then
    echo "Benchmark Summary" >>"$outfile"
    echo "  Multi-Core Score: ${mt}" >>"$outfile"
    [ -n "${mi:-}" ] && echo "    Integer Score: ${mi}" >>"$outfile"
    [ -n "${mf:-}" ] && echo "    Floating Point Score: ${mf}" >>"$outfile"
    echo "" >>"$outfile"
  fi
 
  if [ -z "${st:-}" ] && [ -z "${mt:-}" ]; then
    echo "Benchmark Summary present but totals could not be parsed." >>"$outfile"
  fi
 
  return 0
}

# perf_geekbench_write_iter_subscores_txt LOGFILE OUTFILE
# Writes a readable list:
# Single-Core workloads:
# - Foo: 123
# Multi-Core workloads:
# - Bar: 456
perf_geekbench_write_iter_subscores_txt() {
  logfile=$1
  outfile=$2

  [ -n "$logfile" ] || return 1
  [ -n "$outfile" ] || return 1
  [ -f "$logfile" ] || return 1

  awk '
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    BEGIN{ mode=""; printed_sc=0; printed_mc=0 }

    /^[[:space:]]*Benchmark Summary/ { exit }

    /^[[:space:]]*Single-Core[[:space:]]*$/ {
      mode="Single-Core"
      if (!printed_sc) { print "Single-Core workloads:"; printed_sc=1 }
      next
    }
    /^[[:space:]]*Multi-Core[[:space:]]*$/ {
      mode="Multi-Core"
      if (!printed_mc) { print ""; print "Multi-Core workloads:"; printed_mc=1 }
      next
    }

    mode!="" {
      score=""; name=""; first=0

      for (i=1;i<=NF;i++){
        if ($i ~ /^[0-9]+$/) { first=i; score=$i; break }
      }
      if (first==0) next

      for (i=1;i<first;i++){
        name = (name=="" ? $i : name " " $i)
      }
      name=trim(name)
      if (name=="") next

      # Skip summary score lines (defensive)
      if (name=="Single-Core Score" || name=="Multi-Core Score" ||
          name=="Integer Score" || name=="Floating Point Score") {
        next
      }

      print " - " name ": " score
    }
  ' "$logfile" >"$outfile" 2>/dev/null || true
}

# perf_geekbench_scores_to_vars SCORELINE
# Input: "st|si|sf|mt|mi|mf"
# Output: prints 6 lines "st=..", etc (for eval)
perf_geekbench_scores_to_vars() {
  s=$1
  [ -n "$s" ] || return 1
 
  # Split without relying on bash arrays
  st=$(printf '%s' "$s" | awk -F'|' '{print $1}')
  si=$(printf '%s' "$s" | awk -F'|' '{print $2}')
  sf=$(printf '%s' "$s" | awk -F'|' '{print $3}')
  mt=$(printf '%s' "$s" | awk -F'|' '{print $4}')
  mi=$(printf '%s' "$s" | awk -F'|' '{print $5}')
  mf=$(printf '%s' "$s" | awk -F'|' '{print $6}')
 
  # Quote values safely for eval. Values are numeric/empty, but keep it robust.
  printf "st='%s'\n" "$(printf '%s' "$st" | sed "s/'/'\\\\''/g")"
  printf "si='%s'\n" "$(printf '%s' "$si" | sed "s/'/'\\\\''/g")"
  printf "sf='%s'\n" "$(printf '%s' "$sf" | sed "s/'/'\\\\''/g")"
  printf "mt='%s'\n" "$(printf '%s' "$mt" | sed "s/'/'\\\\''/g")"
  printf "mi='%s'\n" "$(printf '%s' "$mi" | sed "s/'/'\\\\''/g")"
  printf "mf='%s'\n" "$(printf '%s' "$mf" | sed "s/'/'\\\\''/g")"
}

# perf_geekbench_has_benchmark_summary LOGFILE
# Returns 0 if "Benchmark Summary" header appears (allow indentation)
perf_geekbench_has_benchmark_summary() {
  f=$1
  [ -n "$f" ] || return 1
  [ -f "$f" ] || return 1
  grep -q '[[:space:]]*Benchmark Summary[[:space:]]*$' "$f" 2>/dev/null
}

# perf_geekbench_log_subscores_file FILE
# Prints file lines using log_info (if available), otherwise echo.
perf_geekbench_log_subscores_file() {
  f=$1
  [ -n "$f" ] || return 1
  [ -s "$f" ] || return 1

  if command -v log_info >/dev/null 2>&1; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      log_info "$line"
    done <"$f"
  else
    cat "$f"
  fi
  return 0
}

# perf_geekbench_log_summary_scores ST SI SF MT MI MF
# Logs a "Benchmark Summary (this run)" block (single-only or multi-only)
perf_geekbench_log_summary_scores() {
  st=$1; si=$2; sf=$3
  mt=$4; mi=$5; mf=$6

  if command -v log_info >/dev/null 2>&1; then
    log_info "Geekbench summary (this run):"
    if [ -n "${st:-}" ] && perf_is_number_safe "$st"; then
      log_info " Single-Core Score : $st"
      if [ -n "${si:-}" ] && perf_is_number_safe "$si"; then log_info " Integer Score : $si"; fi
      if [ -n "${sf:-}" ] && perf_is_number_safe "$sf"; then log_info " FP Score : $sf"; fi
    fi
    if [ -n "${mt:-}" ] && perf_is_number_safe "$mt"; then
      log_info " Multi-Core Score : $mt"
      if [ -n "${mi:-}" ] && perf_is_number_safe "$mi"; then log_info " Integer Score : $mi"; fi
      if [ -n "${mf:-}" ] && perf_is_number_safe "$mf"; then log_info " FP Score : $mf"; fi
    fi
  else
    echo "Geekbench summary (this run):"
    [ -n "${st:-}" ] && echo " Single-Core Score : $st"
    [ -n "${si:-}" ] && echo " Integer Score : $si"
    [ -n "${sf:-}" ] && echo " FP Score : $sf"
    [ -n "${mt:-}" ] && echo " Multi-Core Score : $mt"
    [ -n "${mi:-}" ] && echo " Integer Score : $mi"
    [ -n "${mf:-}" ] && echo " FP Score : $mf"
  fi
  return 0
}
# -----------------------------------------------------------------------------
# Geekbench bin + unlock helpers
# -----------------------------------------------------------------------------
perf_geekbench_pick_bin() {
  # Optional override: can be a directory or a file or a command name
  # Backward compatible: if not given, uses $GEEKBENCH_BIN then PATH.
  spec=$1
 
  if [ -z "${spec:-}" ]; then
    spec=${GEEKBENCH_BIN:-}
  fi
 
  # If user provided a directory, pick executable inside it and fix +x
  if [ -n "${spec:-}" ] && [ -d "$spec" ]; then
    # try common names inside bundle
    for cand in "$spec/geekbench_aarch64" "$spec/geekbench" "$spec/geekbench6_aarch64" "$spec/geekbench6"; do
      if [ -f "$cand" ]; then
        if [ ! -x "$cand" ]; then
          chmod +x "$cand" 2>/dev/null || true
        fi
        # Also fix common wrapper scripts if present (best effort)
        for w in "$spec/run.sh" "$spec/Geekbench" "$spec/geekbench.sh"; do
          if [ -f "$w" ] && [ ! -x "$w" ]; then
            chmod +x "$w" 2>/dev/null || true
          fi
        done
        if [ -x "$cand" ]; then
          echo "$cand"
          return 0
        fi
      fi
    done
    echo ""
    return 1
  fi
 
  # If user provided a file path, chmod +x if needed
  if [ -n "${spec:-}" ] && [ -f "$spec" ]; then
    if [ ! -x "$spec" ]; then
      chmod +x "$spec" 2>/dev/null || true
    fi
    if [ -x "$spec" ]; then
      echo "$spec"
      return 0
    fi
    echo ""
    return 1
  fi
 
  # If user provided a command name present in PATH
  if [ -n "${spec:-}" ] && command -v "$spec" >/dev/null 2>&1; then
    p=$(command -v "$spec" 2>/dev/null)
    # best effort chmod if it is a file and not exec (rare)
    if [ -n "${p:-}" ] && [ -f "$p" ] && [ ! -x "$p" ]; then
      chmod +x "$p" 2>/dev/null || true
    fi
    if [ -n "${p:-}" ] && [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  fi
 
  # Default PATH lookup
  if command -v geekbench_aarch64 >/dev/null 2>&1; then
    p=$(command -v geekbench_aarch64 2>/dev/null)
    if [ -n "${p:-}" ] && [ -f "$p" ] && [ ! -x "$p" ]; then
      chmod +x "$p" 2>/dev/null || true
    fi
    if [ -n "${p:-}" ] && [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  fi
 
  if command -v geekbench >/dev/null 2>&1; then
    p=$(command -v geekbench 2>/dev/null)
    if [ -n "${p:-}" ] && [ -f "$p" ] && [ ! -x "$p" ]; then
      chmod +x "$p" 2>/dev/null || true
    fi
    if [ -n "${p:-}" ] && [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  fi
 
  echo ""
  return 1
}

# -----------------------------------------------------------------------------
# Geekbench bin resolver + chmod fix (reusable)
# -----------------------------------------------------------------------------
perf_geekbench_fix_exec_perms_dir() {
  d=$1
  [ -n "$d" ] || return 1
  [ -d "$d" ] || return 1
 
  # Best effort: known names in Geekbench bundles
  for f in \
    "$d/geekbench_aarch64" \
    "$d/geekbench" \
    "$d/Geekbench"* \
    "$d/geekbench"*; do
    [ -f "$f" ] || continue
    if [ ! -x "$f" ]; then
      chmod +x "$f" 2>/dev/null || true
    fi
  done
  return 0
}
 
# perf_geekbench_resolve_bin_and_fix_perms REQUESTED
# - REQUESTED can be: empty, command, file path, or directory path
# - Prints resolved executable path to stdout
perf_geekbench_resolve_bin_and_fix_perms() {
  req=$1
 
  # empty -> try PATH candidates
  if [ -z "${req:-}" ]; then
    if command -v geekbench_aarch64 >/dev/null 2>&1; then
      command -v geekbench_aarch64 2>/dev/null
      return 0
    fi
    if command -v geekbench >/dev/null 2>&1; then
      command -v geekbench 2>/dev/null
      return 0
    fi
    return 1
  fi
 
  # directory provided
  if [ -d "$req" ]; then
    perf_geekbench_fix_exec_perms_dir "$req" 2>/dev/null || true
 
    if [ -f "$req/geekbench_aarch64" ]; then
      [ -x "$req/geekbench_aarch64" ] || chmod +x "$req/geekbench_aarch64" 2>/dev/null || true
      echo "$req/geekbench_aarch64"
      return 0
    fi
    if [ -f "$req/geekbench" ]; then
      [ -x "$req/geekbench" ] || chmod +x "$req/geekbench" 2>/dev/null || true
      echo "$req/geekbench"
      return 0
    fi
 
    # last resort: pick first file matching geekbench*
    for f in "$req"/geekbench* "$req"/Geekbench*; do
      [ -f "$f" ] || continue
      [ -x "$f" ] || chmod +x "$f" 2>/dev/null || true
      echo "$f"
      return 0
    done
    return 1
  fi
 
  # file provided
  if [ -f "$req" ]; then
    [ -x "$req" ] || chmod +x "$req" 2>/dev/null || true
    echo "$req"
    return 0
  fi
 
  # command provided
  if command -v "$req" >/dev/null 2>&1; then
    p=$(command -v "$req" 2>/dev/null)
    [ -n "$p" ] || return 1
    echo "$p"
    return 0
  fi
 
  return 1
}

perf_geekbench_unlock_if_requested() {
  bin=$1
  email=$2
  key=$3
  logf=$4

  [ -n "$bin" ] || return 1
  [ -n "$email" ] || return 0
  [ -n "$key" ] || return 0
  [ -n "$logf" ] || logf="./geekbench_unlock.log"

  : >"$logf" 2>/dev/null || true
  if command -v log_info >/dev/null 2>&1; then
    log_info "Geekbench, unlock requested, log, $logf"
  fi

  perf_run_cmd_tee_safe "$logf" -- "$bin" --unlock "$email" "$key"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    if command -v log_info >/dev/null 2>&1; then
      log_info "Geekbench, unlock done, rc, 0"
    fi
    return 0
  fi

  if grep -qi "already" "$logf" 2>/dev/null; then
    if command -v log_info >/dev/null 2>&1; then
      log_info "Geekbench, already unlocked, continuing"
    fi
    return 0
  fi

  if command -v log_warn >/dev/null 2>&1; then
    log_warn "Geekbench, unlock failed, rc, $rc, continuing"
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Runner: run Geekbench N times and dump 2 readable CSVs (summary + workloads)
# Uses live progress streaming via perf_run_cmd_with_progress
# -----------------------------------------------------------------------------

# perf_geekbench_run_and_dump_csv BIN OUTDIR TESTNAME ITERS SUMMARY_CSV WORKLOADS_CSV HEARTBEAT_SECS -- GEEKBENCH_ARGS...
perf_geekbench_run_and_dump_csv() {
  bin=$1
  outdir=$2
  testname=$3
  iters=$4
  summary_csv=$5
  workloads_csv=$6
  heartbeat_secs=$7
  shift 7

  if [ "${1:-}" = "--" ]; then
    shift
  fi

  [ -n "$bin" ] || return 1
  [ -n "$outdir" ] || outdir="."
  [ -n "$testname" ] || testname="geekbench"
  case "${iters:-}" in ""|*[!0-9]*) iters=1 ;; esac
  [ "$iters" -lt 1 ] && iters=1

  mkdir -p "$outdir" 2>/dev/null || true
  perf_geekbench_summary_csv_init "$summary_csv"
  perf_geekbench_workloads_csv_init "$workloads_csv"

  vst="$outdir/${testname}_sum_single_total.values"
  vsi="$outdir/${testname}_sum_single_integer.values"
  vsf="$outdir/${testname}_sum_single_fp.values"
  vmt="$outdir/${testname}_sum_multi_total.values"
  vmi="$outdir/${testname}_sum_multi_integer.values"
  vmf="$outdir/${testname}_sum_multi_fp.values"
  : >"$vst" 2>/dev/null || true
  : >"$vsi" 2>/dev/null || true
  : >"$vsf" 2>/dev/null || true
  : >"$vmt" 2>/dev/null || true
  : >"$vmi" 2>/dev/null || true
  : >"$vmf" 2>/dev/null || true

  i=1
  while [ "$i" -le "$iters" ]; do
    ts=$(perf_nowstamp_safe)
    run_log="$outdir/${testname}_iter${i}.log"
    label="$testname, iter, $i, of, $iters"

    if command -v log_info >/dev/null 2>&1; then
      log_info "Geekbench, iteration, $i, of, $iters"
    fi

    perf_run_cmd_with_progress "$outdir" "$run_log" "$heartbeat_secs" "$label" -- "$bin" "$@"
    rc=$?

    if [ "$rc" -ne 0 ] && command -v log_warn >/dev/null 2>&1; then
      log_warn "Geekbench, iteration, $i, rc, $rc, continuing, parse"
    fi

    if grep -q '^Benchmark Summary' "$run_log" 2>/dev/null; then
      scores=$(perf_parse_geekbench_summary_scores "$run_log")
      st=$(printf '%s\n' "$scores" | awk '{print $1}')
      si=$(printf '%s\n' "$scores" | awk '{print $2}')
      sf=$(printf '%s\n' "$scores" | awk '{print $3}')
      mt=$(printf '%s\n' "$scores" | awk '{print $4}')
      mi=$(printf '%s\n' "$scores" | awk '{print $5}')
      mf=$(printf '%s\n' "$scores" | awk '{print $6}')

      echo "$ts,$testname,$i,$st,$si,$sf,$mt,$mi,$mf" >>"$summary_csv" 2>/dev/null || true
      perf_append_geekbench_workloads_csv "$run_log" "$ts" "$testname" "$i" "$workloads_csv"

      # POSIX-safe, ShellCheck-safe (no A&&B||true)
      if perf_is_number_safe "$st"; then
        printf '%s\n' "$st" >>"$vst" 2>/dev/null || true
      fi
      if perf_is_number_safe "$si"; then
        printf '%s\n' "$si" >>"$vsi" 2>/dev/null || true
      fi
      if perf_is_number_safe "$sf"; then
        printf '%s\n' "$sf" >>"$vsf" 2>/dev/null || true
      fi
      if perf_is_number_safe "$mt"; then
        printf '%s\n' "$mt" >>"$vmt" 2>/dev/null || true
      fi
      if perf_is_number_safe "$mi"; then
        printf '%s\n' "$mi" >>"$vmi" 2>/dev/null || true
      fi
      if perf_is_number_safe "$mf"; then
        printf '%s\n' "$mf" >>"$vmf" 2>/dev/null || true
      fi
    else
      if command -v log_info >/dev/null 2>&1; then
        log_info "Geekbench, no benchmark summary for iter, $i, mode like sysinfo or list is ok"
      fi
    fi

    i=$((i + 1))
  done

  ast=$(perf_avg_file_safe "$vst")
  asi=$(perf_avg_file_safe "$vsi")
  asf=$(perf_avg_file_safe "$vsf")
  amt=$(perf_avg_file_safe "$vmt")
  ami=$(perf_avg_file_safe "$vmi")
  amf=$(perf_avg_file_safe "$vmf")

  if [ -n "$ast" ] || [ -n "$amt" ]; then
    ts=$(perf_nowstamp_safe)
    echo "$ts,$testname,avg,$ast,$asi,$asf,$amt,$ami,$amf" >>"$summary_csv" 2>/dev/null || true
  fi

  if command -v log_info >/dev/null 2>&1; then
    log_info "Geekbench, csv, summary, $summary_csv"
    log_info "Geekbench, csv, workloads, $workloads_csv"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# ALL-metrics extraction (long-format CSV)
# -----------------------------------------------------------------------------

perf_geekbench_sanitize_key() {
  printf '%s' "$1" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-'
}

# perf_geekbench_extract_metrics_from_text FILE
# Emits TSV: metric<TAB>value<TAB>unit<TAB>kind
perf_geekbench_extract_metrics_from_text() {
  file=$1
  [ -f "$file" ] || return 1

  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function join_name(a, start, end, s,i) {
      s=""
      for (i=start; i<=end; i++) {
        if (s=="") s=a[i]; else s=s" "a[i]
      }
      return s
    }
    function emit(metric, value, unit, kind) {
      if (unit=="") unit="NA"
      if (kind=="") kind="NA"
      printf "%s\t%s\t%s\t%s\n", metric, value, unit, kind
    }

    BEGIN { section=""; sum_mode="" }

    /^Single-Core[[:space:]]*$/ { section="single"; next }
    /^Multi-Core[[:space:]]*$/ { section="multi"; next }
    /^Benchmark Summary[[:space:]]*$/ { section="summary"; sum_mode=""; next }

    section=="summary" {
      line=$0
      if (match(line, /Single-Core Score[[:space:]]+[0-9]+/)) {
        sum_mode="single"
        v=line; sub(/.*Single-Core Score[[:space:]]+/, "", v); v=trim(v)
        emit("geekbench.summary.single.total_score", v, "score", "summary")
        next
      }
      if (match(line, /Multi-Core Score[[:space:]]+[0-9]+/)) {
        sum_mode="multi"
        v=line; sub(/.*Multi-Core Score[[:space:]]+/, "", v); v=trim(v)
        emit("geekbench.summary.multi.total_score", v, "score", "summary")
        next
      }
      if (sum_mode!="") {
        if (match(line, /Integer Score[[:space:]]+[0-9]+/)) {
          v=line; sub(/.*Integer Score[[:space:]]+/, "", v); v=trim(v)
          emit("geekbench.summary."sum_mode".integer_score", v, "score", "summary")
          next
        }
        if (match(line, /Floating Point Score[[:space:]]+[0-9]+/)) {
          v=line; sub(/.*Floating Point Score[[:space:]]+/, "", v); v=trim(v)
          emit("geekbench.summary."sum_mode".floating_point_score", v, "score", "summary")
          next
        }
      }
      next
    }

    (section=="single" || section=="multi") {
      line=trim($0)
      if (line=="") next
      if (line ~ /^Geekbench /) next
      if (line ~ /^System Information/ || line ~ /^CPU Information/ || line ~ /^Memory Information/) next
      if (line ~ /^Operating System/ || line ~ /^Kernel/ || line ~ /^Model/ || line ~ /^Motherboard/) next
      if (line ~ /^Name/ || line ~ /^Topology/ || line ~ /^Identifier/ || line ~ /^Base Frequency/) next
      if (line ~ /^Size/) next
      if (line ~ /^Benchmark Summary/) next

      n=split(line, a, /[[:space:]]+/)
      if (n < 4) next

      unit=a[n]
      thr=a[n-1]
      score=""
      score_i=0

      for (i=n-2; i>=1; i--) {
        if (a[i] ~ /^[0-9]+$/) { score=a[i]; score_i=i; break }
      }
      if (score=="") next

      name=join_name(a, 1, score_i-1)
      name=trim(name)
      if (name=="") next

      emit("geekbench."section".workload."name".score", score, "score", "workload")

      if (thr ~ /^[0-9]+(\.[0-9]+)?$/) {
        emit("geekbench."section".workload."name".throughput", thr, unit, "throughput")
      } else {
        emit("geekbench."section".workload."name".throughput", "", unit, "throughput")
      }
      next
    }
  ' "$file"
}

# Long CSV append: timestamp,test,metric,iteration,value,extra
perf_geekbench_csv_append() {
  csv=$1
  test=$2
  metric=$3
  iter=$4
  value=$5
  extra=$6

  [ -n "$csv" ] || return 0

  dir=$(dirname "$csv")
  mkdir -p "$dir" 2>/dev/null || true

  if [ ! -f "$csv" ] || [ ! -s "$csv" ]; then
    echo "timestamp,test,metric,iteration,value,extra" >"$csv"
  fi

  ts=$(perf_nowstamp_safe)

  mq=$(perf_csv_escape "$metric")
  eq=$(perf_csv_escape "${extra:-}")

  echo "$ts,$test,\"$mq\",$iter,$value,\"$eq\"" >>"$csv" 2>/dev/null || true
}

perf_geekbench_metric_seen_add() {
  listf=$1
  metric=$2
  [ -n "$listf" ] || return 0
  [ -n "$metric" ] || return 0
  if [ ! -f "$listf" ] || ! grep -qxF "$metric" "$listf" 2>/dev/null; then
    echo "$metric" >>"$listf" 2>/dev/null || true
  fi
}

perf_geekbench_values_file_for_metric() {
  outdir=$1
  metric=$2
  safe=$(perf_geekbench_sanitize_key "$metric")
  printf '%s/%s.values' "$outdir" "$safe"
}

perf_geekbench_append_if_number() {
  file=$1
  value=$2
  [ -n "$file" ] || return 0
  [ -n "$value" ] || return 0
  if perf_is_number_safe "$value"; then
    printf '%s\n' "$value" >>"$file" 2>/dev/null || true
  fi
}

# perf_geekbench_run_n_dump_all_metrics BIN OUTDIR TESTNAME ITERS LONGCSV EXTRA HEARTBEAT_SECS -- GEEKBENCH_ARGS...
# Prints: single_total_avg=... multi_total_avg=...
perf_geekbench_run_n_dump_all_metrics() {
  bin=$1
  outdir=$2
  testname=$3
  iters=$4
  csv=$5
  extra=$6
  heartbeat_secs=$7
  shift 7

  if [ "${1:-}" = "--" ]; then
    shift
  fi

  [ -n "$bin" ] || return 1
  [ -n "$outdir" ] || outdir="."
  [ -n "$testname" ] || testname="geekbench"
  case "${iters:-}" in ""|*[!0-9]*) iters=1 ;; esac
  [ "$iters" -lt 1 ] && iters=1

  mkdir -p "$outdir" 2>/dev/null || true

  metrics_list="$outdir/${testname}_metrics.list"
  : >"$metrics_list" 2>/dev/null || true

  single_vals="$outdir/${testname}_single_total.values"
  multi_vals="$outdir/${testname}_multi_total.values"
  : >"$single_vals" 2>/dev/null || true
  : >"$multi_vals" 2>/dev/null || true

  i=1
  while [ "$i" -le "$iters" ]; do
    run_log="$outdir/${testname}_iter${i}.log"
    txt_out="$outdir/${testname}_iter${i}.txt"
    met_out="$outdir/${testname}_iter${i}.metrics.tsv"
    label="$testname, metrics, iter, $i, of, $iters"

    if command -v log_info >/dev/null 2>&1; then
      log_info "Geekbench, iteration, $i, of, $iters, export-text, $txt_out"
    fi

    perf_run_cmd_with_progress "$outdir" "$run_log" "$heartbeat_secs" "$label" -- \
      "$bin" "$@" --export-text "$txt_out"
    rc=$?

    if [ "$rc" -ne 0 ] && command -v log_warn >/dev/null 2>&1; then
      log_warn "Geekbench, iter, $i, rc, $rc, continuing"
    fi

    src="$txt_out"
    if [ ! -f "$src" ]; then
      src="$run_log"
    fi

    : >"$met_out" 2>/dev/null || true
    perf_geekbench_extract_metrics_from_text "$src" >"$met_out" 2>/dev/null || true

    if [ ! -s "$met_out" ]; then
      if command -v log_warn >/dev/null 2>&1; then
        log_warn "Geekbench, iter, $i, no metrics extracted"
      fi
      i=$((i + 1))
      continue
    fi

    while IFS="$(printf '\t')" read -r metric value unit kind; do
      [ -n "$metric" ] || continue

      perf_geekbench_metric_seen_add "$metrics_list" "$metric"
      ex="$extra unit=${unit:-NA} kind=${kind:-NA}"
      perf_geekbench_csv_append "$csv" "$testname" "$metric" "$i" "${value:-}" "$ex"

      vf=$(perf_geekbench_values_file_for_metric "$outdir" "$metric")
      perf_geekbench_append_if_number "$vf" "$value"

      if [ "$metric" = "geekbench.summary.single.total_score" ]; then
        perf_geekbench_append_if_number "$single_vals" "$value"
      fi
      if [ "$metric" = "geekbench.summary.multi.total_score" ]; then
        perf_geekbench_append_if_number "$multi_vals" "$value"
      fi
    done <"$met_out"

    i=$((i + 1))
  done

  if [ -s "$metrics_list" ]; then
    while IFS= read -r metric; do
      [ -n "$metric" ] || continue
      vf=$(perf_geekbench_values_file_for_metric "$outdir" "$metric")
      avg=$(perf_avg_file_safe "$vf")
      if [ -n "$avg" ]; then
        perf_geekbench_csv_append "$csv" "$testname" "$metric" "avg" "$avg" "$extra kind=avg"
      fi
    done <"$metrics_list"
  fi

  single_total_avg=$(perf_avg_file_safe "$single_vals")
  multi_total_avg=$(perf_avg_file_safe "$multi_vals")

  printf "single_total_avg=%s multi_total_avg=%s\n" "${single_total_avg:-}" "${multi_total_avg:-}"
  return 0
}

# ---------------------------------------------------------------------------
# Boot KPI goal/gating helpers
# ---------------------------------------------------------------------------

perf_goal_file_get() {
    goal_file=$1
    metric=$2

    [ -n "$goal_file" ] || {
        echo ""
        return 0
    }

    [ -f "$goal_file" ] || {
        echo ""
        return 0
    }

    perf_baseline_get "$metric" "$goal_file"
}

perf_goal_inline_get() {
    goal_spec=$1
    metric=$2

    [ -n "$goal_spec" ] || {
        echo ""
        return 0
    }

    # Accept either:
    # --goal 35
    # --goal boot_total_effective_sec=35
    # --goal boot_total_effective_sec:35
    case "$goal_spec" in
        *=*|*:*)
            printf '%s\n' "$goal_spec" | tr ',' ' ' | tr ';' ' ' | awk -v k="$metric" '
              {
                for (i = 1; i <= NF; i++) {
                  token = $i
                  split(token, a, /[=:]/)
                  if (a[1] == k && a[2] != "") {
                    print a[2]
                    exit
                  }
                }
              }'
            ;;
        *)
            # Plain numeric goal applies to selected/default metric.
            printf '%s\n' "$goal_spec"
            ;;
    esac
}

perf_goal_resolve() {
    metric=$1
    goal_spec=$2
    goal_file=$3

    goal=""

    goal="$(perf_goal_inline_get "$goal_spec" "$metric")"
    if [ -z "$goal" ]; then
        goal="$(perf_goal_file_get "$goal_file" "$metric")"
    fi

    printf '%s\n' "$goal"
}

perf_goal_check_max_sec() {
    metric=$1
    current=$2
    goal=$3
    report_file=$4

    [ -n "$report_file" ] || report_file="/dev/null"

    {
        echo "metric=$metric"
        echo "current_sec=${current:-unknown}"
        echo "goal_sec=${goal:-unknown}"
        echo "direction=lower_or_equal"
    } >"$report_file" 2>/dev/null || true

    if ! perf_is_number "$goal"; then
        log_fail "Goal gating requested, but invalid/missing goal for $metric: ${goal:-<empty>}"
        echo "result=FAIL" >>"$report_file" 2>/dev/null || true
        echo "reason=invalid_or_missing_goal" >>"$report_file" 2>/dev/null || true
        return 1
    fi

    if ! perf_is_number "$current"; then
        log_fail "Goal gating requested, but current KPI is not numeric for $metric: ${current:-unknown}"
        echo "result=FAIL" >>"$report_file" 2>/dev/null || true
        echo "reason=invalid_or_missing_current_value" >>"$report_file" 2>/dev/null || true
        return 1
    fi

    pass="$(awk -v cur="$current" -v goal="$goal" 'BEGIN { if (cur <= goal) print 1; else print 0 }')"
    delta="$(awk -v cur="$current" -v goal="$goal" 'BEGIN { printf("%.3f", cur - goal) }')"

    echo "delta_sec=$delta" >>"$report_file" 2>/dev/null || true

    if [ "$pass" = "1" ]; then
        log_pass "Goal check PASS: $metric current=${current}s goal<=${goal}s"
        echo "result=PASS" >>"$report_file" 2>/dev/null || true
        return 0
    fi

    log_fail "Goal check FAIL: $metric current=${current}s goal<=${goal}s delta=${delta}s"
    echo "result=FAIL" >>"$report_file" 2>/dev/null || true
    return 1
}

perf_normalize_key() {
    printf '%s\n' "$1" |
        tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z0-9]/ /g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

perf_platform_probe_string() {
    platform_override="${1:-}"

    if [ -n "$platform_override" ]; then
        printf '%s\n' "$platform_override"
        return 0
    fi

    {
        cat /proc/device-tree/model 2>/dev/null
        cat /sys/devices/soc0/machine 2>/dev/null
        cat /sys/devices/soc0/family 2>/dev/null
        cat /sys/devices/soc0/soc_id 2>/dev/null
        uname -n 2>/dev/null
    } | tr '\000' '\n' | tr '\n' ' '
}

perf_alias_matches_platform() {
    alias_list="$1"
    platform_text="$2"
 
    platform_norm="$(perf_normalize_key "$platform_text")"
    [ -n "$platform_norm" ] || return 1
 
    alias_lines="$(printf '%s\n' "$alias_list" | tr ',' '\n')"
 
    while IFS= read -r alias; do
        alias_norm="$(perf_normalize_key "$alias")"
        [ -n "$alias_norm" ] || continue
 
        haystack=" $platform_norm "
        needle=" $alias_norm "
 
        case "$haystack" in
            *"$needle"*)
                return 0
                ;;
        esac
    done <<EOF
$alias_lines
EOF
 
    return 1
}

perf_goal_file_get_for_platform() {
    goal_file="$1"
    metric="$2"
    platform_override="$3"

    [ -f "$goal_file" ] || return 1

    platform_text="$(perf_platform_probe_string "$platform_override")"

    while read -r aliases file_metric goal_value tolerance_value _rest; do
        case "$aliases" in
            ""|\#*) continue ;;
        esac

        [ "$file_metric" = "$metric" ] || continue

        if perf_alias_matches_platform "$aliases" "$platform_text"; then
            printf '%s:%s:%s\n' "$goal_value" "${tolerance_value:-}" "$aliases"
            return 0
        fi
    done < "$goal_file"

    return 1
}

perf_goal_check_max_sec_with_tolerance() {
    metric="$1"
    current="$2"
    goal="$3"
    tolerance_percent="$4"
    report_file="$5"

    [ -n "$report_file" ] || report_file="/dev/null"
    [ -n "$tolerance_percent" ] || tolerance_percent=0

    {
        echo "metric=$metric"
        echo "current_sec=${current:-unknown}"
        echo "goal_sec=${goal:-unknown}"
        echo "tolerance_percent=$tolerance_percent"
        echo "direction=lower_or_equal_with_tolerance"
    } >"$report_file" 2>/dev/null || true

    if ! perf_is_number "$goal"; then
        log_fail "Goal gating requested, but invalid/missing goal for $metric: ${goal:-<empty>}"
        echo "result=FAIL" >>"$report_file" 2>/dev/null || true
        echo "reason=invalid_or_missing_goal" >>"$report_file" 2>/dev/null || true
        return 1
    fi

    if ! perf_is_number "$current"; then
        log_fail "Goal gating requested, but current KPI is not numeric for $metric: ${current:-unknown}"
        echo "result=FAIL" >>"$report_file" 2>/dev/null || true
        echo "reason=invalid_or_missing_current_value" >>"$report_file" 2>/dev/null || true
        return 1
    fi

    if ! perf_is_number "$tolerance_percent"; then
        log_fail "Invalid goal tolerance percent: $tolerance_percent"
        echo "result=FAIL" >>"$report_file" 2>/dev/null || true
        echo "reason=invalid_tolerance_percent" >>"$report_file" 2>/dev/null || true
        return 1
    fi

    allowed_max="$(awk -v goal="$goal" -v pct="$tolerance_percent" \
        'BEGIN { printf("%.3f", goal + ((goal * pct) / 100.0)) }')"

    delta="$(awk -v cur="$current" -v allowed="$allowed_max" \
        'BEGIN { printf("%.3f", cur - allowed) }')"

    pass="$(awk -v cur="$current" -v allowed="$allowed_max" \
        'BEGIN { if (cur <= allowed) print 1; else print 0 }')"

    {
        echo "allowed_max_sec=$allowed_max"
        echo "delta_from_allowed_sec=$delta"
    } >>"$report_file" 2>/dev/null || true

    if [ "$pass" = "1" ]; then
        log_pass "Goal check PASS: $metric current=${current}s goal=${goal}s tolerance=${tolerance_percent}% allowed<=${allowed_max}s"
        echo "result=PASS" >>"$report_file" 2>/dev/null || true
        return 0
    fi

    log_fail "Goal check FAIL: $metric current=${current}s goal=${goal}s tolerance=${tolerance_percent}% allowed<=${allowed_max}s delta=${delta}s"
    echo "result=FAIL" >>"$report_file" 2>/dev/null || true
    return 1
}

dump_debug_file() {
  title="$1"
  file_path="$2"
  max_lines="${3:-80}"

  [ -f "$file_path" ] || return 0

  log_info "===== ${title}: ${file_path} ====="

  awk -v max_lines="$max_lines" '
    NR <= max_lines {
      print
      next
    }
    NR == max_lines + 1 {
      print "... truncated after " max_lines " lines ..."
      exit
    }
  ' "$file_path" 2>/dev/null || true

  log_info "===== end ${title} ====="
}

# ---------------------------------------------------------------------------
# Memory map collection helpers
# ---------------------------------------------------------------------------

perf_mem_hex_bytes_to_dec() {
  hex="$1"

  [ -n "$hex" ] || {
    printf '\n'
    return 0
  }

  awk -v hex="$hex" '
    function hexval(c) {
      c = tolower(c)
      if (c >= "0" && c <= "9") return c + 0
      if (c == "a") return 10
      if (c == "b") return 11
      if (c == "c") return 12
      if (c == "d") return 13
      if (c == "e") return 14
      if (c == "f") return 15
      return 0
    }

    BEGIN {
      total = 0
      for (i = 1; i <= length(hex); i++) {
        total = (total * 16) + hexval(substr(hex, i, 1))
      }
      printf "%.0f\n", total
    }
  '
}

perf_mem_dt_u32_prop() {
  prop="$1"

  [ -r "$prop" ] || {
    printf '\n'
    return 0
  }

  hex="$(
    od -An -tx1 -N 4 -v "$prop" 2>/dev/null \
      | tr -d ' \n'
  )"

  perf_mem_hex_bytes_to_dec "$hex"
}

perf_mem_dt_cells_to_bytes() {
  file_path="$1"
  start_cell="$2"
  cell_count="$3"

  [ -r "$file_path" ] || {
    printf '\n'
    return 0
  }

  byte_skip=$((start_cell * 4))
  byte_count=$((cell_count * 4))

  hex="$(
    dd if="$file_path" bs=1 skip="$byte_skip" count="$byte_count" 2>/dev/null \
      | od -An -tx1 -v 2>/dev/null \
      | tr -d ' \n'
  )"

  perf_mem_hex_bytes_to_dec "$hex"
}

perf_mem_dt_reg_total_size_kb() {
  reg_file="$1"
  address_cells="$2"
  size_cells="$3"

  [ -r "$reg_file" ] || {
    printf '\n'
    return 0
  }

  case "$address_cells" in
    ''|*[!0-9]*) address_cells=2 ;;
  esac

  case "$size_cells" in
    ''|*[!0-9]*) size_cells=2 ;;
  esac

  tuple_cells=$((address_cells + size_cells))
  total_bytes="$(wc -c <"$reg_file" 2>/dev/null || echo 0)"
  total_cells=$((total_bytes / 4))

  if [ "$tuple_cells" -le 0 ] || [ "$total_cells" -le 0 ]; then
    printf '\n'
    return 0
  fi

  total="0"
  cell_index=0

  while [ "$cell_index" -lt "$total_cells" ]; do
    size_start=$((cell_index + address_cells))
    size_bytes="$(perf_mem_dt_cells_to_bytes "$reg_file" "$size_start" "$size_cells")"

    if [ -n "$size_bytes" ]; then
      total="$(
        awk -v a="$total" -v b="$size_bytes" '
          BEGIN { printf "%.0f\n", a + b }
        '
      )"
    fi

    cell_index=$((cell_index + tuple_cells))
  done

  awk -v bytes="$total" '
    BEGIN { printf "%.0f\n", bytes / 1024 }
  '
}

perf_mem_dt_size_prop_total_kb() {
  prop="$1"
  size_cells="$2"

  [ -r "$prop" ] || {
    printf '\n'
    return 0
  }

  case "$size_cells" in
    ''|*[!0-9]*) size_cells=2 ;;
  esac

  hex="$(
    od -An -tx1 -v "$prop" 2>/dev/null \
      | tr -d ' \n'
  )"

  [ -n "$hex" ] || {
    printf '\n'
    return 0
  }

  awk -v hex="$hex" -v size_cells="$size_cells" '
    function hexval(c) {
      c = tolower(c)
      if (c >= "0" && c <= "9") return c + 0
      if (c == "a") return 10
      if (c == "b") return 11
      if (c == "c") return 12
      if (c == "d") return 13
      if (c == "e") return 14
      if (c == "f") return 15
      return 0
    }

    function hex2dec(s, i, n, v) {
      n = 0
      for (i = 1; i <= length(s); i++) {
        v = hexval(substr(s, i, 1))
        n = (n * 16) + v
      }
      return n
    }

    BEGIN {
      chars = size_cells * 8
      if (length(hex) < chars) {
        exit
      }
      size_hex = substr(hex, 1, chars)
      size_bytes = hex2dec(size_hex)
      printf "%.0f\n", size_bytes / 1024
    }
  '
}

perf_mem_total_physical_kb_from_dt_memory() {
  base=""

  if [ -d /sys/firmware/devicetree/base ]; then
    base="/sys/firmware/devicetree/base"
  elif [ -d /proc/device-tree ]; then
    base="/proc/device-tree"
  fi

  [ -n "$base" ] || {
    printf '\n'
    return 0
  }

  address_cells="$(perf_mem_dt_u32_prop "$base/#address-cells")"
  size_cells="$(perf_mem_dt_u32_prop "$base/#size-cells")"

  [ -n "$address_cells" ] || address_cells=2
  [ -n "$size_cells" ] || size_cells=2

  total_kb="0"

  for mem_node in "$base"/memory "$base"/memory@*; do
    [ -d "$mem_node" ] || continue
    [ -r "$mem_node/reg" ] || continue

    node_kb="$(perf_mem_dt_reg_total_size_kb "$mem_node/reg" "$address_cells" "$size_cells")"

    if [ -n "$node_kb" ]; then
      total_kb="$(
        awk -v a="$total_kb" -v b="$node_kb" '
          BEGIN { printf "%.0f\n", a + b }
        '
      )"
    fi
  done

  if [ "$total_kb" = "0" ]; then
    printf '\n'
  else
    printf '%s\n' "$total_kb"
  fi
}

perf_mem_reserved_nhlos_kb_from_dt_mode() {
  out_dir="$1"
  mode="$2"
  base=""

  case "$mode" in
    all)
      detail_file="$out_dir/nhlos_reserved_memory_dt_all.tsv"
      ;;
    non_reusable)
      detail_file="$out_dir/nhlos_reserved_memory_dt_non_reusable.tsv"
      ;;
    *)
      detail_file="$out_dir/nhlos_reserved_memory_dt_all.tsv"
      mode="all"
      ;;
  esac

  if [ -d /sys/firmware/devicetree/base/reserved-memory ]; then
    base="/sys/firmware/devicetree/base/reserved-memory"
  elif [ -d /proc/device-tree/reserved-memory ]; then
    base="/proc/device-tree/reserved-memory"
  fi

  {
    printf 'node\tname\tsource\tsize_kb\tsize_mb\tno_map\treusable\tlinux_cma_default\tincluded\n'
  } >"$detail_file"

  [ -n "$base" ] || {
    printf '\n'
    return 0
  }

  address_cells="$(perf_mem_dt_u32_prop "$base/#address-cells")"
  size_cells="$(perf_mem_dt_u32_prop "$base/#size-cells")"

  [ -n "$address_cells" ] || address_cells=2
  [ -n "$size_cells" ] || size_cells=2

  total_kb="0"

  for node in "$base"/*; do
    [ -d "$node" ] || continue

    node_base="$(basename "$node")"

    if [ -r "$node/name" ]; then
      node_name="$(tr -d '\0' <"$node/name" 2>/dev/null)"
    else
      node_name="$node_base"
    fi

    if [ -e "$node/no-map" ]; then
      no_map="yes"
    else
      no_map="no"
    fi

    if [ -e "$node/reusable" ]; then
      reusable="yes"
    else
      reusable="no"
    fi

    if [ -e "$node/linux,cma-default" ]; then
      linux_cma_default="yes"
    else
      linux_cma_default="no"
    fi

    size_kb=""
    source=""

    if [ -r "$node/reg" ]; then
      size_kb="$(perf_mem_dt_reg_total_size_kb "$node/reg" "$address_cells" "$size_cells")"
      source="reg"
    elif [ -r "$node/size" ]; then
      size_kb="$(perf_mem_dt_size_prop_total_kb "$node/size" "$size_cells")"
      source="size"
    fi

    [ -n "$size_kb" ] || continue
    [ "$size_kb" != "0" ] || continue

    included="yes"
    if [ "$mode" = "non_reusable" ]; then
      if [ "$reusable" = "yes" ] || [ "$linux_cma_default" = "yes" ]; then
        included="no"
      fi
    fi

    size_mb="$(
      awk -v kb="$size_kb" '
        BEGIN { printf "%.2f\n", kb / 1024 }
      '
    )"

    if [ "$included" = "yes" ]; then
      total_kb="$(
        awk -v a="$total_kb" -v b="$size_kb" '
          BEGIN { printf "%.0f\n", a + b }
        '
      )"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$node_base" "$node_name" "$source" "$size_kb" "$size_mb" \
      "$no_map" "$reusable" "$linux_cma_default" "$included" >>"$detail_file"
  done

  if [ "$total_kb" = "0" ]; then
    printf '\n'
  else
    printf '%s\n' "$total_kb"
  fi
}

perf_mem_reserved_nhlos_kb_from_dt() {
  perf_mem_reserved_nhlos_kb_from_dt_mode "$1" "all"
}

perf_mem_reserved_nhlos_non_reusable_kb_from_dt() {
  perf_mem_reserved_nhlos_kb_from_dt_mode "$1" "non_reusable"
}

perf_mem_dt_gap_nhlos_kb() {
  memtotal_kb="$1"
  total_physical_kb="$(perf_mem_total_physical_kb_from_dt_memory)"

  if [ -z "$total_physical_kb" ] || [ -z "$memtotal_kb" ]; then
    printf '\n'
    return 0
  fi

  awk -v total="$total_physical_kb" -v memtotal="$memtotal_kb" '
    BEGIN {
      v = total - memtotal
      if (v < 0) v = 0
      printf "%.0f\n", v
    }
  '
}

perf_mem_iomem_reserved_regions_all_kb() {
  iomem_file="$1"
  detail_file="$2"

  [ -r "$iomem_file" ] || {
    printf '\n'
    return 0
  }

  awk -v detail_file="$detail_file" '
    function hexval(c) {
      c = tolower(c)
      if (c >= "0" && c <= "9") return c + 0
      if (c == "a") return 10
      if (c == "b") return 11
      if (c == "c") return 12
      if (c == "d") return 13
      if (c == "e") return 14
      if (c == "f") return 15
      return 0
    }

    function hex2dec(s, i, n, v) {
      gsub(/^0x/, "", s)
      n = 0
      for (i = 1; i <= length(s); i++) {
        v = hexval(substr(s, i, 1))
        n = (n * 16) + v
      }
      return n
    }

    function add_top_range(s, e, name, is_system) {
      if (e < s) return

      all_count++
      all_starts[all_count] = s
      all_ends[all_count] = e
      all_names[all_count] = name
      all_system[all_count] = is_system

      /*
       * DDR span is inferred from top-level System RAM plus common Qualcomm
       * firmware/reserved labels. The final NHLOS is span - System RAM, so
       * unnamed holes/gaps are counted too.
       */
      lname = tolower(name)
      if (is_system == 1 || lname ~ /(reserved|nomap|no-map|modem|mpss|adsp|cdsp|gpdsp|wpss|slpi|spss|tz|hyp|pil|rmtfs|venus|vpu|video|camera|cam|ipa|gpu|gmu|qsee|secure|xbl|aop|smem|cpucp|memory)/) {
        if (have_span == 0) {
          span_start = s
          span_end = e
          have_span = 1
        } else {
          if (s < span_start) span_start = s
          if (e > span_end) span_end = e
        }
      }
    }

    BEGIN {
      printf "item\trange\tname\tstart_dec\tend_dec\tsize_kb\tsize_mb\tincluded\n" > detail_file
      have_span = 0
      all_count = 0
    }

    /*
     * Use only top-level /proc/iomem ranges. Child lines are indented and
     * would double count Kernel code/data under System RAM.
     */
    /^[0-9a-fA-F]+-[0-9a-fA-F]+[[:space:]]*:/ {
      split($1, range, "-")
      start = hex2dec(range[1])
      end = hex2dec(range[2])

      name = $0
      sub(/^[0-9a-fA-F]+-[0-9a-fA-F]+[[:space:]]*:[[:space:]]*/, "", name)

      is_system = 0
      if (tolower(name) == "system ram") {
        is_system = 1
      }

      add_top_range(start, end, name, is_system)
    }

    END {
      if (all_count == 0 || have_span == 0) {
        exit
      }

      sys_count = 0

      for (i = 1; i <= all_count; i++) {
        if (all_system[i] != 1) {
          continue
        }

        if (all_ends[i] < span_start || all_starts[i] > span_end) {
          continue
        }

        sys_count++
        sys_starts[sys_count] = all_starts[i]
        sys_ends[sys_count] = all_ends[i]
      }

      if (sys_count == 0) {
        exit
      }

      for (i = 1; i <= sys_count; i++) {
        for (j = i + 1; j <= sys_count; j++) {
          if (sys_starts[j] < sys_starts[i]) {
            ts = sys_starts[i]
            te = sys_ends[i]
            sys_starts[i] = sys_starts[j]
            sys_ends[i] = sys_ends[j]
            sys_starts[j] = ts
            sys_ends[j] = te
          }
        }
      }

      merged_count = 0

      for (i = 1; i <= sys_count; i++) {
        if (merged_count == 0) {
          merged_count = 1
          mstarts[merged_count] = sys_starts[i]
          mends[merged_count] = sys_ends[i]
          continue
        }

        if (sys_starts[i] <= mends[merged_count] + 1) {
          if (sys_ends[i] > mends[merged_count]) {
            mends[merged_count] = sys_ends[i]
          }
        } else {
          merged_count++
          mstarts[merged_count] = sys_starts[i]
          mends[merged_count] = sys_ends[i]
        }
      }

      system_bytes = 0
      for (i = 1; i <= merged_count; i++) {
        system_bytes += mends[i] - mstarts[i] + 1
      }

      span_bytes = span_end - span_start + 1
      nhlos_bytes = span_bytes - system_bytes

      if (nhlos_bytes < 0) {
        nhlos_bytes = 0
      }

      printf "DDR_SPAN\t%.0f-%.0f\tDDR span inferred from /proc/iomem\t%.0f\t%.0f\t%.0f\t%.2f\tyes\n", \
        span_start, span_end, span_start, span_end, span_bytes / 1024, span_bytes / 1024 / 1024 >> detail_file

      printf "SYSTEM_RAM_TOTAL\t-\tMerged top-level System RAM\t0\t0\t%.0f\t%.2f\tno\n", \
        system_bytes / 1024, system_bytes / 1024 / 1024 >> detail_file

      printf "NHLOS_ALL\t-\tDDR span minus System RAM, includes reserved regions and holes\t0\t0\t%.0f\t%.2f\tyes\n", \
        nhlos_bytes / 1024, nhlos_bytes / 1024 / 1024 >> detail_file

      for (i = 1; i <= all_count; i++) {
        if (all_ends[i] < span_start || all_starts[i] > span_end) {
          continue
        }

        size_bytes = all_ends[i] - all_starts[i] + 1
        included = "debug"

        if (all_system[i] == 1) {
          included = "system_ram"
        } else {
          included = "non_system_or_reserved"
        }

        printf "TOP_LEVEL_RANGE\t%.0f-%.0f\t%s\t%.0f\t%.0f\t%.0f\t%.2f\t%s\n", \
          all_starts[i], all_ends[i], all_names[i], all_starts[i], all_ends[i], \
          size_bytes / 1024, size_bytes / 1024 / 1024, included >> detail_file
      }

      printf "%.0f\n", nhlos_bytes / 1024
    }
  ' "$iomem_file" 2>/dev/null
}

perf_mem_nhlos_kb_from_iomem_patterns() {
  iomem_file="$1"

  [ -r "$iomem_file" ] || {
    printf '\n'
    return 0
  }

  awk '
    function hexval(c) {
      c = tolower(c)
      if (c >= "0" && c <= "9") return c + 0
      if (c == "a") return 10
      if (c == "b") return 11
      if (c == "c") return 12
      if (c == "d") return 13
      if (c == "e") return 14
      if (c == "f") return 15
      return 0
    }

    function hex2dec(s, i, n, v) {
      gsub(/^0x/, "", s)
      n = 0
      for (i = 1; i <= length(s); i++) {
        v = hexval(substr(s, i, 1))
        n = (n * 16) + v
      }
      return n
    }

    BEGIN {
      pattern = "modem|mpss|adsp|cdsp|gpdsp|wpss|slpi|spss|tz|hyp|pil|rmtfs|venus|vpu|video|camera|cam|ipa|gpu|gmu|qsee|secure"
    }

    tolower($0) ~ pattern && $1 ~ /^[0-9a-fA-F]+-[0-9a-fA-F]+$/ {
      split($1, range, "-")
      start = hex2dec(range[1])
      end = hex2dec(range[2])

      if (end >= start) {
        total += end - start + 1
      }
    }

    END {
      if (total > 0) {
        printf "%.0f\n", total / 1024
      }
    }
  ' "$iomem_file" 2>/dev/null
}

perf_mem_roundup_installed_kb() {
  memtotal_kb="$1"

  case "$memtotal_kb" in
    ''|*[!0-9.]*)
      printf '\n'
      return 0
      ;;
  esac

  awk -v kb="$memtotal_kb" '
    BEGIN {
      split("512 1024 1536 2048 3072 4096 6144 8192 12288 16384 24576 32768 49152 65536", sizes, " ")
      mb = kb / 1024

      for (i = 1; i <= length(sizes); i++) {
        if (mb <= sizes[i]) {
          printf "%.0f\n", sizes[i] * 1024
          exit
        }
      }

      printf "%.0f\n", mb * 1024
    }
  '
}

perf_mem_collect_file() {
  src="$1"
  dst="$2"

  if [ -r "$src" ]; then
    cat "$src" >"$dst" 2>/dev/null || true
  else
    printf 'missing or unreadable: %s\n' "$src" >"$dst"
  fi
}

perf_mem_collect_cmd() {
  dst="$1"
  shift

  "$@" >"$dst" 2>&1 || true
}

perf_mem_append_manifest() {
  out_dir="$1"
  name="$2"
  path="$3"

  if [ -e "$path" ]; then
    size="$(wc -c <"$path" 2>/dev/null || echo 0)"
    printf '%s\t%s\t%s\n' "$name" "$size" "$path" >>"$out_dir/manifest.tsv"
  fi
}

perf_mem_try_mount_debugfs() {
  mount_debugfs="$1"

  [ "$mount_debugfs" -eq 1 ] 2>/dev/null || return 0
  [ -d /sys/kernel/debug ] || return 0

  if grep -q ' debugfs /sys/kernel/debug ' /proc/mounts 2>/dev/null; then
    return 0
  fi

  mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
}

perf_mem_dump_process_mem_tsv() {
  out="$1"
  tmp="${out}.tmp"

  printf 'pid\tcomm\tuid\tpss_kb\trss_rollup_kb\tswap_pss_kb\tvmrss_kb\trssanon_kb\trssfile_kb\tshmem_kb\tvmdata_kb\tvmpte_kb\tvmswap_kb\tthreads\tcmdline\n' >"$tmp"

  for proc_dir in /proc/[0-9]*; do
    [ -d "$proc_dir" ] || continue

    pid="${proc_dir#/proc/}"
    [ -r "$proc_dir/status" ] || continue

    comm="$(cat "$proc_dir/comm" 2>/dev/null || echo unknown)"
    cmdline="$(tr '\0' ' ' <"$proc_dir/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//')"
    [ -n "$cmdline" ] || cmdline="[$comm]"

    status_vals="$(
      awk '
        /^Uid:/ { uid=$2 }
        /^Threads:/ { threads=$2 }
        /^VmRSS:/ { vmrss=$2 }
        /^RssAnon:/ { rssanon=$2 }
        /^RssFile:/ { rssfile=$2 }
        /^RssShmem:/ { shmem=$2 }
        /^VmData:/ { vmdata=$2 }
        /^VmPTE:/ { vmpte=$2 }
        /^VmSwap:/ { vmswap=$2 }
        END {
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s",
            uid+0, vmrss+0, rssanon+0, rssfile+0,
            shmem+0, vmdata+0, vmpte+0, vmswap+0, threads+0
        }
      ' "$proc_dir/status" 2>/dev/null
    )"

    if [ -r "$proc_dir/smaps_rollup" ]; then
      rollup_vals="$(
        awk '
          /^Pss:/ { pss=$2 }
          /^Rss:/ { rss=$2 }
          /^SwapPss:/ { swappss=$2 }
          END {
            printf "%s\t%s\t%s", pss+0, rss+0, swappss+0
          }
        ' "$proc_dir/smaps_rollup" 2>/dev/null
      )"
    else
      rollup_vals="0 0 0"
    fi

    uid="$(printf '%s\n' "$status_vals" | awk -F '\t' '{print $1}')"
    vmrss="$(printf '%s\n' "$status_vals" | awk -F '\t' '{print $2}')"
    rssanon="$(printf '%s\n' "$status_vals" | awk -F '\t' '{print $3}')"
    rssfile="$(printf '%s\n' "$status_vals" | awk -F '\t' '{print $4}')"
    shmem="$(printf '%s\n' "$status_vals" | awk -F '\t' '{print $5}')"
    vmdata="$(printf '%s\n' "$status_vals" | awk -F '\t' '{print $6}')"
    vmpte="$(printf '%s\n' "$status_vals" | awk -F '\t' '{print $7}')"
    vmswap="$(printf '%s\n' "$status_vals" | awk -F '\t' '{print $8}')"
    threads="$(printf '%s\n' "$status_vals" | awk -F '\t' '{print $9}')"

    pss="$(printf '%s\n' "$rollup_vals" | awk -F '\t' '{print $1}')"
    rss_rollup="$(printf '%s\n' "$rollup_vals" | awk -F '\t' '{print $2}')"
    swap_pss="$(printf '%s\n' "$rollup_vals" | awk -F '\t' '{print $3}')"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pid" "$comm" "$uid" "$pss" "$rss_rollup" "$swap_pss" \
      "$vmrss" "$rssanon" "$rssfile" "$shmem" "$vmdata" "$vmpte" \
      "$vmswap" "$threads" "$cmdline" >>"$tmp"
  done

  {
    head -n 1 "$tmp"
    tail -n +2 "$tmp" 2>/dev/null | sort -k4,4nr
  } >"$out"

  rm -f "$tmp"
}

perf_mem_dump_process_top_pss() {
  in_file="$1"
  out_file="$2"
  count="$3"

  {
    printf 'Top %s processes by PSS\n' "$count"
    printf 'pid\tpss_kb\trss_kb\tswap_pss_kb\tcomm\tcmdline\n'
    awk -F '\t' 'NR > 1 {
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $4, $5, $6, $2, $15
    }' "$in_file" | head -n "$count"
  } >"$out_file"
}

perf_mem_dump_process_smaps_availability() {
  out="$1"
  total=0
  readable=0

  for proc_dir in /proc/[0-9]*; do
    [ -d "$proc_dir" ] || continue
    total=$((total + 1))

    if [ -r "$proc_dir/smaps_rollup" ]; then
      readable=$((readable + 1))
    fi
  done

  {
    echo "proc_count=$total"
    echo "smaps_rollup_readable=$readable"
  } >"$out"
}

perf_mem_dump_memory_summary() {
  out="$1"

  awk '
    /^MemTotal:/ { memtotal=$2 }
    /^MemFree:/ { memfree=$2 }
    /^MemAvailable:/ { memavailable=$2 }
    /^Buffers:/ { buffers=$2 }
    /^Cached:/ { cached=$2 }
    /^SwapCached:/ { swapcached=$2 }
    /^Active:/ { active=$2 }
    /^Inactive:/ { inactive=$2 }
    /^Shmem:/ { shmem=$2 }
    /^Slab:/ { slab=$2 }
    /^SReclaimable:/ { sreclaimable=$2 }
    /^SUnreclaim:/ { sunreclaim=$2 }
    /^KernelStack:/ { kernelstack=$2 }
    /^PageTables:/ { pagetables=$2 }
    /^VmallocUsed:/ { vmallocused=$2 }
    /^CmaTotal:/ { cmatotal=$2 }
    /^CmaFree:/ { cmafree=$2 }
    /^SwapTotal:/ { swaptotal=$2 }
    /^SwapFree:/ { swapfree=$2 }
    END {
      used = memtotal - memavailable
      filecache = cached + buffers + sreclaimable - shmem
      if (filecache < 0) filecache = 0

      printf "MemTotal_kB=%d\n", memtotal
      printf "MemFree_kB=%d\n", memfree
      printf "MemAvailable_kB=%d\n", memavailable
      printf "UsedApprox_kB=%d\n", used
      printf "Buffers_kB=%d\n", buffers
      printf "Cached_kB=%d\n", cached
      printf "FileCacheApprox_kB=%d\n", filecache
      printf "SwapCached_kB=%d\n", swapcached
      printf "Active_kB=%d\n", active
      printf "Inactive_kB=%d\n", inactive
      printf "Shmem_kB=%d\n", shmem
      printf "Slab_kB=%d\n", slab
      printf "SReclaimable_kB=%d\n", sreclaimable
      printf "SUnreclaim_kB=%d\n", sunreclaim
      printf "KernelStack_kB=%d\n", kernelstack
      printf "PageTables_kB=%d\n", pagetables
      printf "VmallocUsed_kB=%d\n", vmallocused
      printf "CmaTotal_kB=%d\n", cmatotal
      printf "CmaFree_kB=%d\n", cmafree
      printf "CmaUsed_kB=%d\n", cmatotal - cmafree
      printf "SwapTotal_kB=%d\n", swaptotal
      printf "SwapFree_kB=%d\n", swapfree
      printf "SwapUsed_kB=%d\n", swaptotal - swapfree
    }
  ' /proc/meminfo >"$out" 2>/dev/null || true
}

perf_mem_dump_reserved_memory_dt() {
  out="$1"
  base=""

  if [ -d /sys/firmware/devicetree/base/reserved-memory ]; then
    base="/sys/firmware/devicetree/base/reserved-memory"
  elif [ -d /proc/device-tree/reserved-memory ]; then
    base="/proc/device-tree/reserved-memory"
  fi

  {
    printf 'node\tname\tcompatible\tstatus\treg_hex\tsize_hex\tno_map\n'

    if [ -z "$base" ]; then
      return 0
    fi

    for node in "$base"/*; do
      [ -d "$node" ] || continue

      node_name="$(basename "$node")"

      if [ -r "$node/name" ]; then
        name="$(tr -d '\0' <"$node/name" 2>/dev/null)"
      else
        name="$node_name"
      fi

      if [ -r "$node/compatible" ]; then
        compatible="$(tr '\0' ',' <"$node/compatible" 2>/dev/null | sed 's/,$//')"
      else
        compatible=""
      fi

      if [ -r "$node/status" ]; then
        status="$(tr -d '\0' <"$node/status" 2>/dev/null)"
      else
        status=""
      fi

      if [ -r "$node/reg" ]; then
        reg_hex="$(od -An -tx1 -v "$node/reg" 2>/dev/null | tr -d ' \n')"
      else
        reg_hex=""
      fi

      if [ -r "$node/size" ]; then
        size_hex="$(od -An -tx1 -v "$node/size" 2>/dev/null | tr -d ' \n')"
      else
        size_hex=""
      fi

      if [ -e "$node/no-map" ]; then
        no_map="yes"
      else
        no_map="no"
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$node_name" "$name" "$compatible" "$status" "$reg_hex" "$size_hex" "$no_map"
    done
  } >"$out" 2>/dev/null || true
}

perf_mem_dump_dmabuf_fd_owners() {
  out="$1"
  tmp="${out}.tmp"

  printf 'pid\tcomm\tfd\ttarget\n' >"$tmp"

  for fd in /proc/[0-9]*/fd/*; do
    [ -e "$fd" ] || continue

    target="$(readlink "$fd" 2>/dev/null || true)"

    case "$target" in
      *dmabuf*|*dma-buf*|*dma_buf*)
        proc_dir="$(dirname "$(dirname "$fd")")"
        pid="${proc_dir#/proc/}"
        comm="$(cat "$proc_dir/comm" 2>/dev/null || echo unknown)"
        fd_num="$(basename "$fd")"
        printf '%s\t%s\t%s\t%s\n' "$pid" "$comm" "$fd_num" "$target" >>"$tmp"
        ;;
    esac
  done

  sort -k1,1n "$tmp" >"$out" 2>/dev/null || cp "$tmp" "$out"
  rm -f "$tmp"
}

perf_mem_dump_dmabuf_summary() {
  out="$1"
  raw="$2"
  owners="$3"

  {
    echo "debugfs_dma_buf_bufinfo=$raw"

    if [ -s "$raw" ] && ! grep -q '^missing or unreadable:' "$raw" 2>/dev/null; then
      echo "bufinfo_available=yes"
      grep -E 'size|exp_name|name|pid|ino|count|refs' "$raw" 2>/dev/null | head -n 80 || true
    else
      echo "bufinfo_available=no"
    fi

    echo
    echo "dmabuf fd owner count:"

    if [ -s "$owners" ]; then
      awk -F '\t' 'NR > 1 { count[$2]++ } END { for (c in count) print count[c], c }' "$owners" \
        | sort -nr | head -n 20
    else
      echo "no dma-buf fd owners found from /proc/*/fd"
    fi
  } >"$out" 2>/dev/null || true
}

perf_mem_dump_zram_summary() {
  out="$1"

  {
    printf 'device\torig_data_size\tcompr_data_size\tmem_used_total\tmem_limit\tmem_used_max\tsame_pages\tpages_compacted\n'

    for stat in /sys/block/zram*/mm_stat; do
      [ -r "$stat" ] || continue
      dev="$(basename "$(dirname "$stat")")"

      awk -v dev="$dev" '{
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", dev, $1, $2, $3, $4, $5, $6, $7
      }' "$stat"
    done
  } >"$out" 2>/dev/null || true
}

perf_mem_dump_kgsl_summary() {
  out="$1"

  {
    echo "KGSL summary"

    if [ ! -d /sys/class/kgsl/kgsl ]; then
      echo "kgsl_available=no"
    else
      echo "kgsl_available=yes"

      for f in \
        /sys/class/kgsl/kgsl/page_alloc \
        /sys/class/kgsl/kgsl/vmalloc \
        /sys/class/kgsl/kgsl/mapped \
        /sys/class/kgsl/kgsl/mapped_max \
        /sys/class/kgsl/kgsl/mapped_memtype; do
        if [ -r "$f" ]; then
          echo
          echo "===== $f ====="
          cat "$f" 2>/dev/null || true
        fi
      done

      if [ -d /sys/class/kgsl/kgsl/proc ]; then
        echo
        echo "===== /sys/class/kgsl/kgsl/proc ====="
        ls -la /sys/class/kgsl/kgsl/proc 2>/dev/null || true

        for p in /sys/class/kgsl/kgsl/proc/*; do
          [ -d "$p" ] || continue

          echo
          echo "===== $p ====="

          for f in "$p"/*; do
            [ -r "$f" ] || continue
            printf '%s: ' "$(basename "$f")"
            cat "$f" 2>/dev/null || true
          done
        done
      fi
    fi
  } >"$out" 2>/dev/null || true
}

perf_mem_dump_console_file() {
  title="$1"
  file_path="$2"
  max_lines="${3:-80}"

  [ -f "$file_path" ] || return 0

  log_info "===== ${title}: ${file_path} ====="

  awk -v max_lines="$max_lines" '
    NR <= max_lines {
      print
      next
    }
    NR == max_lines + 1 {
      print "... truncated after " max_lines " lines ..."
      exit
    }
  ' "$file_path" 2>/dev/null || true

  log_info "===== end ${title} ====="
}

perf_mem_get_machine_name() {
  machine="unknown"

  if [ -r /proc/device-tree/model ]; then
    machine="$(tr -d '\0' </proc/device-tree/model 2>/dev/null)"
  elif [ -r /sys/firmware/devicetree/base/model ]; then
    machine="$(tr -d '\0' </sys/firmware/devicetree/base/model 2>/dev/null)"
  elif command -v hostname >/dev/null 2>&1; then
    machine="$(hostname 2>/dev/null || echo unknown)"
  fi

  [ -n "$machine" ] || machine="unknown"
  printf '%s\n' "$machine"
}

perf_mem_read_summary_kb() {
  file_path="$1"
  key="$2"

  awk -F '=' -v key="$key" '
    $1 == key {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) print ""
    }
  ' "$file_path" 2>/dev/null
}

perf_mem_kb_to_mb() {
  kb="$1"

  case "$kb" in
    ''|*[!0-9.]*)
      printf 'unknown\n'
      return 0
      ;;
  esac

  awk -v kb="$kb" 'BEGIN { printf "%.2f\n", kb / 1024 }'
}

perf_mem_system_ram_kb_from_iomem() {
  iomem_file="$1"

  [ -r "$iomem_file" ] || {
    printf '\n'
    return 0
  }

  awk '
    function hexval(c) {
      c = tolower(c)
      if (c >= "0" && c <= "9") return c + 0
      if (c == "a") return 10
      if (c == "b") return 11
      if (c == "c") return 12
      if (c == "d") return 13
      if (c == "e") return 14
      if (c == "f") return 15
      return 0
    }

    function hex2dec(s, i, n, v) {
      gsub(/^0x/, "", s)
      n = 0
      for (i = 1; i <= length(s); i++) {
        v = hexval(substr(s, i, 1))
        n = (n * 16) + v
      }
      return n
    }

    /^[[:space:]]*[0-9a-fA-F]+-[0-9a-fA-F]+[[:space:]]*:[[:space:]]*System RAM([[:space:]]*)$/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      split(line, parts, /[[:space:]]+/)
      split(parts[1], range, "-")

      start = hex2dec(range[1])
      end = hex2dec(range[2])

      if (end > start) {
        count++
        starts[count] = start
        ends[count] = end
      }
    }

    END {
      if (count == 0) {
        exit
      }

      for (i = 1; i <= count; i++) {
        for (j = i + 1; j <= count; j++) {
          if (starts[j] < starts[i]) {
            ts = starts[i]
            te = ends[i]
            starts[i] = starts[j]
            ends[i] = ends[j]
            starts[j] = ts
            ends[j] = te
          }
        }
      }

      merged_count = 0

      for (i = 1; i <= count; i++) {
        if (merged_count == 0) {
          merged_count = 1
          mstarts[merged_count] = starts[i]
          mends[merged_count] = ends[i]
          continue
        }

        if (starts[i] <= mends[merged_count] + 1) {
          if (ends[i] > mends[merged_count]) {
            mends[merged_count] = ends[i]
          }
        } else {
          merged_count++
          mstarts[merged_count] = starts[i]
          mends[merged_count] = ends[i]
        }
      }

      total_bytes = 0

      for (i = 1; i <= merged_count; i++) {
        total_bytes += mends[i] - mstarts[i] + 1
      }

      if (total_bytes <= 1024) {
        exit
      }

      printf "%.0f\n", total_bytes / 1024
    }
  ' "$iomem_file" 2>/dev/null
}

perf_mem_resolve_nhlos_kb() {
  out_dir="$1"
  memtotal_kb="$2"
 
  source_file="$out_dir/nhlos_source.txt"
  iomem_file="$out_dir/iomem.txt"
 
  nhlos_kb=""
  installed_kb=""
  systemram_kb=""
 
  installed_kb="$(perf_mem_roundup_installed_kb "$memtotal_kb")"
  systemram_kb="$(perf_mem_system_ram_kb_from_iomem "$iomem_file")"
 
  if [ -n "$installed_kb" ] && [ -n "$systemram_kb" ]; then
    nhlos_kb="$(
      awk -v installed="$installed_kb" -v linux="$systemram_kb" '
        BEGIN {
          v = installed - linux
          if (v < 0) {
            v = 0
          }
          printf "%.0f\n", v
        }
      '
    )"
    source="installed_total_ram_minus_iomem_system_ram"
  else
    nhlos_kb=""
    source="unavailable_iomem_system_ram"
    log_warn "Unable to calculate NHLOS: /proc/iomem System RAM is missing/restricted. Run as root."
  fi
 
  {
    echo "nhlos_source=$source"
    echo "formula=Installed Total RAM - Total Linux System RAM from /proc/iomem"
    echo "nhlos_kb=${nhlos_kb:-unknown}"
    echo "installed_total_ram_kb=${installed_kb:-unknown}"
    echo "systemram_kb=${systemram_kb:-unknown}"
    echo "memtotal_kb=${memtotal_kb:-unknown}"
  } >"$source_file"
 
  printf '%s\n' "$nhlos_kb"
}

perf_mem_write_component_summary() {
  out_dir="$1"

  summary_file="$out_dir/memory_component_summary.txt"
  machine="$(perf_mem_get_machine_name)"

  mem_summary="$out_dir/memory_summary.txt"
  iomem_file="$out_dir/iomem.txt"

  memtotal_kb="$(perf_mem_read_summary_kb "$mem_summary" "MemTotal_kB")"
  memavailable_kb="$(perf_mem_read_summary_kb "$mem_summary" "MemAvailable_kB")"
  slab_kb="$(perf_mem_read_summary_kb "$mem_summary" "Slab_kB")"
  pagetables_kb="$(perf_mem_read_summary_kb "$mem_summary" "PageTables_kB")"
  kernelstack_kb="$(perf_mem_read_summary_kb "$mem_summary" "KernelStack_kB")"
  vmalloc_kb="$(perf_mem_read_summary_kb "$mem_summary" "VmallocUsed_kB")"
  cmaused_kb="$(perf_mem_read_summary_kb "$mem_summary" "CmaUsed_kB")"
  swapused_kb="$(perf_mem_read_summary_kb "$mem_summary" "SwapUsed_kB")"

  systemram_kb="$(perf_mem_system_ram_kb_from_iomem "$iomem_file")"
  nhlos_kb="$(perf_mem_resolve_nhlos_kb "$out_dir" "$memtotal_kb")"

  total_physical_kb=""
  if [ -f "$out_dir/nhlos_source.txt" ]; then
    total_physical_kb="$(
      sed -n 's/^total_physical_kb=//p' "$out_dir/nhlos_source.txt" 2>/dev/null \
        | head -n 1
    )"
  fi

  if [ -n "$systemram_kb" ] && [ -n "$memtotal_kb" ]; then
    kernel_static_kb="$(
      awk -v linux="$systemram_kb" -v memtotal="$memtotal_kb" '
        BEGIN {
          v = linux - memtotal
          if (v < 0) v = 0
          printf "%.0f\n", v
        }
      '
    )"
  else
    kernel_static_kb=""
    log_warn "Unable to calculate Kernel Static: /proc/iomem System RAM is missing/restricted. Run as root."
  fi

  if [ -n "$memtotal_kb" ] && [ -n "$memavailable_kb" ]; then
    apps_framework_kb="$(
      awk -v memtotal="$memtotal_kb" -v free="$memavailable_kb" '
        BEGIN {
          v = memtotal - free
          if (v < 0) v = 0
          printf "%.0f\n", v
        }
      '
    )"
  else
    apps_framework_kb=""
  fi

  {
    printf '%s\n' "------------------------------------------------------------"
    printf '%-36s %s\n' "Mem Component (in MB)" "$machine"
    printf '%s\n' "------------------------------------------------------------"

    printf '%-36s %s\n' "NHLOS" "$(perf_mem_kb_to_mb "$nhlos_kb")"
    printf '%-36s %s\n' "Kernel Static" "$(perf_mem_kb_to_mb "$kernel_static_kb")"
    printf '%-36s %s\n' "Apps + Framework" "$(perf_mem_kb_to_mb "$apps_framework_kb")"
    printf '%-36s %s\n' "Free Mem" "$(perf_mem_kb_to_mb "$memavailable_kb")"

    printf '%s\n' "------------------------------------------------------------"
    printf '%-36s %s\n' "MemTotal" "$(perf_mem_kb_to_mb "$memtotal_kb")"
    printf '%-36s %s\n' "System RAM" "$(perf_mem_kb_to_mb "$systemram_kb")"

    if [ -n "$total_physical_kb" ] && [ "$total_physical_kb" != "unknown" ]; then
      printf '%-36s %s\n' "Total Physical" "$(perf_mem_kb_to_mb "$total_physical_kb")"
    fi

    printf '%-36s %s\n' "Slab" "$(perf_mem_kb_to_mb "$slab_kb")"
    printf '%-36s %s\n' "PageTables" "$(perf_mem_kb_to_mb "$pagetables_kb")"
    printf '%-36s %s\n' "KernelStack" "$(perf_mem_kb_to_mb "$kernelstack_kb")"
    printf '%-36s %s\n' "VmallocUsed" "$(perf_mem_kb_to_mb "$vmalloc_kb")"
    printf '%-36s %s\n' "CMA Used" "$(perf_mem_kb_to_mb "$cmaused_kb")"
    printf '%-36s %s\n' "Swap Used" "$(perf_mem_kb_to_mb "$swapused_kb")"
    printf '%s\n' "------------------------------------------------------------"
  } >"$summary_file"

  printf '%s\n' "$summary_file"
}

perf_mem_print_component_summary() {
  out_dir="$1"
  summary_file="$out_dir/memory_component_summary.txt"

  [ -f "$summary_file" ] || return 0

  printf '\n'
  cat "$summary_file"
  printf '\n'
}

perf_mem_collect_all() {
  out_dir="$1"
  delay_secs="$2"
  top_process_count="$3"
  mount_debugfs="$4"
  verbose="$5"

  mkdir -p "$out_dir" 2>/dev/null || {
    log_fail "Failed to create output directory: $out_dir"
    return 1
  }

  case "$delay_secs" in ''|*[!0-9]*) delay_secs=0 ;; esac
  case "$top_process_count" in ''|*[!0-9]*) top_process_count=20 ;; esac
  case "$mount_debugfs" in ''|*[!0-9]*) mount_debugfs=0 ;; esac
  case "$verbose" in ''|*[!0-9]*) verbose=0 ;; esac

  log_info "Output directory: $out_dir"
  log_info "Collect delay: ${delay_secs}s"
  log_info "Top process count: $top_process_count"

  if [ "$delay_secs" -gt 0 ]; then
    log_info "Waiting ${delay_secs}s before memory capture"
    sleep "$delay_secs"
  fi

  : >"$out_dir/manifest.tsv"

  log_info "Preparing optional debugfs access"
  perf_mem_try_mount_debugfs "$mount_debugfs"

  log_info "Collecting platform and boot context"

  perf_mem_collect_cmd "$out_dir/uname.txt" uname -a
  perf_mem_append_manifest "$out_dir" "uname" "$out_dir/uname.txt"

  perf_mem_collect_cmd "$out_dir/date.txt" date -u
  perf_mem_append_manifest "$out_dir" "date" "$out_dir/date.txt"

  perf_mem_collect_file /proc/version "$out_dir/proc_version.txt"
  perf_mem_append_manifest "$out_dir" "proc_version" "$out_dir/proc_version.txt"

  perf_mem_collect_file /proc/cmdline "$out_dir/cmdline.txt"
  perf_mem_append_manifest "$out_dir" "cmdline" "$out_dir/cmdline.txt"

  perf_mem_collect_file /proc/cpuinfo "$out_dir/cpuinfo.txt"
  perf_mem_append_manifest "$out_dir" "cpuinfo" "$out_dir/cpuinfo.txt"

  if [ -r /proc/config.gz ]; then
    zcat /proc/config.gz >"$out_dir/config.txt" 2>/dev/null || true
  else
    printf 'missing: /proc/config.gz\n' >"$out_dir/config.txt"
  fi
  perf_mem_append_manifest "$out_dir" "config" "$out_dir/config.txt"

  log_info "Collecting core /proc memory snapshots"

  perf_mem_collect_file /proc/meminfo "$out_dir/meminfo.txt"
  perf_mem_append_manifest "$out_dir" "meminfo" "$out_dir/meminfo.txt"

  perf_mem_collect_cmd "$out_dir/free.txt" free
  perf_mem_append_manifest "$out_dir" "free" "$out_dir/free.txt"

  perf_mem_collect_file /proc/vmstat "$out_dir/vmstat.txt"
  perf_mem_append_manifest "$out_dir" "vmstat" "$out_dir/vmstat.txt"

  perf_mem_collect_cmd "$out_dir/vmstat_cmd.txt" vmstat
  perf_mem_append_manifest "$out_dir" "vmstat_cmd" "$out_dir/vmstat_cmd.txt"

  perf_mem_collect_file /proc/zoneinfo "$out_dir/zoneinfo.txt"
  perf_mem_append_manifest "$out_dir" "zoneinfo" "$out_dir/zoneinfo.txt"

  perf_mem_collect_file /proc/pagetypeinfo "$out_dir/pagetypeinfo.txt"
  perf_mem_append_manifest "$out_dir" "pagetypeinfo" "$out_dir/pagetypeinfo.txt"

  perf_mem_collect_file /proc/buddyinfo "$out_dir/buddyinfo.txt"
  perf_mem_append_manifest "$out_dir" "buddyinfo" "$out_dir/buddyinfo.txt"

  perf_mem_collect_file /proc/slabinfo "$out_dir/slabinfo.txt"
  perf_mem_append_manifest "$out_dir" "slabinfo" "$out_dir/slabinfo.txt"

  perf_mem_collect_file /proc/vmallocinfo "$out_dir/vmallocinfo.txt"
  perf_mem_append_manifest "$out_dir" "vmallocinfo" "$out_dir/vmallocinfo.txt"

  perf_mem_collect_file /proc/modules "$out_dir/modules.txt"
  perf_mem_append_manifest "$out_dir" "modules" "$out_dir/modules.txt"

  perf_mem_collect_cmd "$out_dir/lsmod.txt" lsmod
  perf_mem_append_manifest "$out_dir" "lsmod" "$out_dir/lsmod.txt"

  perf_mem_collect_file /proc/iomem "$out_dir/iomem.txt"
  perf_mem_append_manifest "$out_dir" "iomem" "$out_dir/iomem.txt"

  perf_mem_collect_file /proc/uptime "$out_dir/uptime.txt"
  perf_mem_append_manifest "$out_dir" "uptime" "$out_dir/uptime.txt"

  perf_mem_collect_file /proc/sys/vm/swappiness "$out_dir/swappiness.txt"
  perf_mem_append_manifest "$out_dir" "swappiness" "$out_dir/swappiness.txt"

  perf_mem_collect_cmd "$out_dir/df.txt" df
  perf_mem_append_manifest "$out_dir" "df" "$out_dir/df.txt"

  perf_mem_collect_cmd "$out_dir/mount.txt" mount
  perf_mem_append_manifest "$out_dir" "mount" "$out_dir/mount.txt"

  perf_mem_collect_cmd "$out_dir/ps_A.txt" ps -A
  perf_mem_append_manifest "$out_dir" "ps_A" "$out_dir/ps_A.txt"

  perf_mem_collect_cmd "$out_dir/ps_eT.txt" ps -eT
  perf_mem_append_manifest "$out_dir" "ps_eT" "$out_dir/ps_eT.txt"

  log_info "Collecting optional debugfs and sysfs memory artifacts"

  perf_mem_collect_file /sys/kernel/debug/memblock/reserved "$out_dir/memblock_reserved.txt"
  perf_mem_append_manifest "$out_dir" "memblock_reserved" "$out_dir/memblock_reserved.txt"

  perf_mem_collect_file /sys/kernel/debug/tracing/buffer_total_size_kb "$out_dir/tracing_buffer_total_size_kb.txt"
  perf_mem_append_manifest "$out_dir" "tracing_buffer_total_size_kb" "$out_dir/tracing_buffer_total_size_kb.txt"

  perf_mem_collect_file /sys/kernel/debug/dma_buf/bufinfo "$out_dir/dma_buf_bufinfo.txt"
  perf_mem_append_manifest "$out_dir" "dma_buf_bufinfo" "$out_dir/dma_buf_bufinfo.txt"

  perf_mem_collect_file /sys/kernel/debug/ion/heaps/system "$out_dir/ion_heap_system.txt"
  perf_mem_append_manifest "$out_dir" "ion_heap_system" "$out_dir/ion_heap_system.txt"

  log_info "Generating memory summary"

  perf_mem_dump_memory_summary "$out_dir/memory_summary.txt"
  perf_mem_append_manifest "$out_dir" "memory_summary" "$out_dir/memory_summary.txt"

  perf_mem_dump_process_smaps_availability "$out_dir/process_smaps_availability.txt"
  perf_mem_append_manifest "$out_dir" "process_smaps_availability" "$out_dir/process_smaps_availability.txt"

  log_info "Scanning process memory from /proc/*/smaps_rollup"

  perf_mem_dump_process_mem_tsv "$out_dir/process_mem.tsv"
  perf_mem_append_manifest "$out_dir" "process_mem" "$out_dir/process_mem.tsv"

  perf_mem_dump_process_top_pss "$out_dir/process_mem.tsv" "$out_dir/process_top_pss.txt" "$top_process_count"
  perf_mem_append_manifest "$out_dir" "process_top_pss" "$out_dir/process_top_pss.txt"

  log_info "Generating reserved-memory, DMA-BUF, zram and KGSL summaries"

  perf_mem_dump_reserved_memory_dt "$out_dir/reserved_memory_dt.tsv"
  perf_mem_append_manifest "$out_dir" "reserved_memory_dt" "$out_dir/reserved_memory_dt.tsv"

  perf_mem_dump_dmabuf_fd_owners "$out_dir/dmabuf_fd_owners.tsv"
  perf_mem_append_manifest "$out_dir" "dmabuf_fd_owners" "$out_dir/dmabuf_fd_owners.tsv"

  perf_mem_dump_dmabuf_summary "$out_dir/dmabuf_summary.txt" "$out_dir/dma_buf_bufinfo.txt" "$out_dir/dmabuf_fd_owners.tsv"
  perf_mem_append_manifest "$out_dir" "dmabuf_summary" "$out_dir/dmabuf_summary.txt"

  perf_mem_dump_zram_summary "$out_dir/zram_summary.tsv"
  perf_mem_append_manifest "$out_dir" "zram_summary" "$out_dir/zram_summary.tsv"

  perf_mem_dump_kgsl_summary "$out_dir/kgsl_summary.txt"
  perf_mem_append_manifest "$out_dir" "kgsl_summary" "$out_dir/kgsl_summary.txt"

  {
    for state in /sys/devices/system/memory/memory*/state; do
      [ -r "$state" ] || continue
      printf '%s\t%s\n' "$state" "$(cat "$state" 2>/dev/null)"
    done
  } >"$out_dir/mem_bank_state.txt" 2>/dev/null || true
  perf_mem_append_manifest "$out_dir" "mem_bank_state" "$out_dir/mem_bank_state.txt"

  perf_mem_collect_cmd "$out_dir/dmesg.txt" dmesg
  perf_mem_append_manifest "$out_dir" "dmesg" "$out_dir/dmesg.txt"

  log_info "Generating final memory component summary"

  component_summary_file="$(perf_mem_write_component_summary "$out_dir")"
  perf_mem_append_manifest "$out_dir" "memory_component_summary" "$component_summary_file"

  if [ -f "$out_dir/nhlos_source.txt" ]; then
    perf_mem_append_manifest "$out_dir" "nhlos_source" "$out_dir/nhlos_source.txt"
  fi

  if [ -f "$out_dir/nhlos_iomem_reserved_regions_all.tsv" ]; then
    perf_mem_append_manifest "$out_dir" "nhlos_iomem_reserved_regions_all" "$out_dir/nhlos_iomem_reserved_regions_all.tsv"
  fi

  if [ -f "$out_dir/nhlos_reserved_memory_dt_all.tsv" ]; then
    perf_mem_append_manifest "$out_dir" "nhlos_reserved_memory_dt_all" "$out_dir/nhlos_reserved_memory_dt_all.tsv"
  fi

  if [ -f "$out_dir/nhlos_reserved_memory_dt_non_reusable.tsv" ]; then
    perf_mem_append_manifest "$out_dir" "nhlos_reserved_memory_dt_non_reusable" "$out_dir/nhlos_reserved_memory_dt_non_reusable.tsv"
  fi

  log_info "Collected memory artifacts:"
  perf_mem_dump_console_file "manifest" "$out_dir/manifest.tsv" 80

  log_info "Memory summary:"
  perf_mem_dump_console_file "memory summary" "$out_dir/memory_summary.txt" 80

  log_info "Top process memory summary:"
  perf_mem_dump_console_file "top processes by PSS" "$out_dir/process_top_pss.txt" 80

  log_info "DMA-BUF summary:"
  perf_mem_dump_console_file "dma-buf summary" "$out_dir/dmabuf_summary.txt" 80

  if [ "$verbose" -eq 1 ]; then
    perf_mem_dump_console_file "reserved memory from DT" "$out_dir/reserved_memory_dt.tsv" 120

    if [ -f "$out_dir/nhlos_iomem_reserved_regions_all.tsv" ]; then
      perf_mem_dump_console_file "NHLOS iomem non-System-RAM DDR ranges" "$out_dir/nhlos_iomem_reserved_regions_all.tsv" 160
    fi

    if [ -f "$out_dir/nhlos_reserved_memory_dt_all.tsv" ]; then
      perf_mem_dump_console_file "NHLOS DT reserved memory all" "$out_dir/nhlos_reserved_memory_dt_all.tsv" 160
    fi

    if [ -f "$out_dir/nhlos_reserved_memory_dt_non_reusable.tsv" ]; then
      perf_mem_dump_console_file "NHLOS DT non-reusable reserved memory" "$out_dir/nhlos_reserved_memory_dt_non_reusable.tsv" 160
    fi

    if [ -f "$out_dir/nhlos_source.txt" ]; then
      perf_mem_dump_console_file "NHLOS source" "$out_dir/nhlos_source.txt" 40
    fi

    perf_mem_dump_console_file "zram summary" "$out_dir/zram_summary.tsv" 80
    perf_mem_dump_console_file "KGSL summary" "$out_dir/kgsl_summary.txt" 120
  fi

  if [ ! -s "$out_dir/meminfo.txt" ]; then
    log_fail "Failed to collect /proc/meminfo"
    return 1
  fi

  log_info "Final memory component summary"
  perf_mem_print_component_summary "$out_dir"

  return 0
}

