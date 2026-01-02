#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Common performance-related helpers for KPI-style tests.

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

# ---------------------------------------------------------------------------
# Small math / parsing helpers (POSIX)
# ---------------------------------------------------------------------------
perf_is_number() {
    printf '%s\n' "$1" | awk '
      BEGIN{ok=0}
      /^[0-9]+(\.[0-9]+)?$/ {ok=1}
      END{exit(ok?0:1)}'
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

# Run a command and stream output to console while also writing to a logfile.
# POSIX-safe: uses mkfifo + tee to preserve command exit code.
# Usage: perf_run_cmd_tee /path/to/log -- cmd args...
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
 
    # Start tee first (reader)
    tee "$log_file" <"$fifo" &
    tee_pid=$!
 
    # Run command, write both stdout+stderr into FIFO (writer)
    "$@" >"$fifo" 2>&1
    rc=$?
 
    # Give tee a short window to drain+exit; then kill if still alive (avoid hangs)
    i=0
    while kill -0 "$tee_pid" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -ge 5 ] && break
        sleep 1
    done
 
    if kill -0 "$tee_pid" 2>/dev/null; then
        # tee is still alive unexpectedly → terminate and move on
        kill "$tee_pid" 2>/dev/null || true
        wait "$tee_pid" 2>/dev/null || true
    else
        wait "$tee_pid" 2>/dev/null || true
    fi
 
    rm -f "$fifo" 2>/dev/null || true
    return $rc
}

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

# Optional CSV append (only if CSV_FILE is non-empty).
# CSV format:
# timestamp,test,threads,metric,iteration,value
perf_sysbench_csv_append() {
    csv=$1
    test=$2
    threads=$3
    metric=$4
    iteration=$5
    value=$6
    status=${7:-}
    baseline=${8:-}
    goal=${9:-}
    op=${10:-}
    score_pct=${11:-}
    delta=${12:-}
 
    [ -n "$csv" ] || return 0
    [ -n "$value" ] || return 0
 
    dir=$(dirname "$csv")
    mkdir -p "$dir" 2>/dev/null || true
 
    if [ ! -f "$csv" ] || [ ! -s "$csv" ]; then
        # Backward-compatible: old columns first, new columns appended.
        echo "timestamp,test,threads,metric,iteration,value,status,baseline,goal,op,score_pct,delta" >"$csv"
    fi
 
    if command -v nowstamp >/dev/null 2>&1; then
        ts=$(nowstamp)
    else
        ts=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
    fi
 
    # Always write all columns; empty fields are OK.
    echo "$ts,$test,$threads,$metric,$iteration,$value,$status,$baseline,$goal,$op,$score_pct,$delta" >>"$csv" 2>/dev/null || true
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
