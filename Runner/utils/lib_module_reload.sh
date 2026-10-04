#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

MRV_LAST_CMD_PID=""
MRV_LAST_CMD_ELAPSED="0"
MRV_LAST_TIMEOUT_DIR=""
MRV_PROFILE_REASON=""

# Reset all profile-provided variables before sourcing a profile.
mrv_reset_profile_vars() {
  PROFILE_NAME=""
  PROFILE_DESCRIPTION=""
  MODULE_NAME=""
  MODULE_LOAD_CMD=""
  MODULE_UNLOAD_CMD=""
  MODULE_RELOAD_SUPPORTED="yes"
  PROFILE_MODE_DEFAULT="basic"
  PROFILE_REQUIRED_CMDS=""
  PROFILE_SERVICES=""
  PROFILE_PROC_PATTERNS=""
  PROFILE_DEVICE_PATTERNS=""
  PROFILE_SYSFS_PATTERNS=""
  PROFILE_SELECTED_MODE=""
  PROFILE_EXPECT_ABSENT_AFTER_UNLOAD=""
  PROFILE_EXPECT_PRESENT_AFTER_LOAD=""
  PROFILE_SKIP_IF_MODULES_LOADED=""
  PROFILE_TOP_MODULE_CANDIDATES=""
  PROFILE_UNLOAD_STACK=""
  PROFILE_EXTRA_UNLOAD_MODULES=""
  PROFILE_QUIESCE_SERVICES=""
  PROFILE_QUIESCE_PROC_PATTERNS=""
  PROFILE_QUIESCE_DEVICE_PATTERNS=""
  PROFILE_QUIESCE_ONCE="no"
  MRV_PROFILE_QUIESCED="0"
}

# Convert module names to the form used by lsmod and /proc/modules.
mrv_module_lsmod_name() {
  printf '%s\n' "$1" | tr '-' '_'
}

# Return success when a module is either loaded or available through modinfo.
mrv_module_available() {
  mod="$1"

  if mrv_module_loaded "$mod"; then
    return 0
  fi

  if modinfo "$mod" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# Return the first sysfs holder for a module, if any.
mrv_module_first_holder_sysfs() {
  mod="$1"

  for holder_path in /sys/module/"$mod"/holders/*; do
    [ -e "$holder_path" ] || continue
    holder="${holder_path##*/}"
    [ -n "$holder" ] || continue
    printf '%s\n' "$holder"
    return 0
  done

  return 1
}

# Return the first /proc/modules holder for a module, if any.
mrv_module_first_holder_proc() {
  mod="$1"

  [ -r /proc/modules ] || return 1

  awk -v target="$mod" '
    $1 == target && $4 != "-" {
      n = split($4, holders, ",")
      for (i = 1; i <= n; i++) {
        if (holders[i] != "") {
          print holders[i]
          exit
        }
      }
    }
  ' /proc/modules 2>/dev/null
}

# Select the reload target for a stack: holder first, candidates second, primary last.
mrv_select_reload_top_module() {
  primary="$1"
  candidates="$2"
  top_module=""

  top_module="$(mrv_module_first_holder_sysfs "$primary" 2>/dev/null || true)"
  if [ -n "$top_module" ]; then
    printf '%s\n' "$top_module"
    return 0
  fi

  top_module="$(mrv_module_first_holder_proc "$primary" 2>/dev/null || true)"
  if [ -n "$top_module" ]; then
    printf '%s\n' "$top_module"
    return 0
  fi

  for candidate in $candidates; do
    [ -n "$candidate" ] || continue
    if mrv_module_available "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if mrv_module_available "$primary"; then
    printf '%s\n' "$primary"
    return 0
  fi

  return 1
}

# Configure generic stack reload commands from profile data.
#
# Profiles can define:
# MODULE_NAME primary module
# PROFILE_TOP_MODULE_CANDIDATES optional holder/top-module candidates
# PROFILE_UNLOAD_STACK explicit unload order
# PROFILE_EXTRA_UNLOAD_MODULES extra modules to unload after stack
#
# This helper intentionally avoids ${var:-command-with-${m}} expansion because
# nested braces inside command strings can break POSIX shell parsing.
module_reload_profile_setup_stack() {
  primary="${MODULE_NAME:-}"
  top_module=""
  unload_stack=""

  if [ -z "$primary" ]; then
    MODULE_RELOAD_SUPPORTED="no"
    return 0
  fi

  top_module="$(mrv_select_reload_top_module "$primary" "$PROFILE_TOP_MODULE_CANDIDATES" 2>/dev/null || true)"
  if [ -z "$top_module" ]; then
    MODULE_RELOAD_SUPPORTED="no"
    return 0
  fi

  MODULE_NAME="$top_module"
  MODULE_RELOAD_SUPPORTED="${MODULE_RELOAD_SUPPORTED:-yes}"

  if [ -n "$PROFILE_UNLOAD_STACK" ]; then
    unload_stack="$PROFILE_UNLOAD_STACK"
  elif [ "$top_module" != "$primary" ]; then
    unload_stack="$top_module $primary"
  else
    unload_stack="$primary"
  fi

  if [ -n "$PROFILE_EXTRA_UNLOAD_MODULES" ]; then
    unload_stack="$unload_stack $PROFILE_EXTRA_UNLOAD_MODULES"
  fi

  if [ -z "$MODULE_UNLOAD_CMD" ]; then
    MODULE_UNLOAD_CMD="modprobe -r $unload_stack"
  fi

  if [ -z "$MODULE_LOAD_CMD" ]; then
    MODULE_LOAD_CMD="modprobe $top_module"
  fi

  if [ -z "$PROFILE_EXPECT_ABSENT_AFTER_UNLOAD" ]; then
    PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="$top_module"
  fi

  if [ -z "$PROFILE_EXPECT_PRESENT_AFTER_LOAD" ]; then
    PROFILE_EXPECT_PRESENT_AFTER_LOAD="$top_module"
  fi

  return 0
}

# Return success when the module is present in lsmod.
mrv_module_loaded() {
  name="$(mrv_module_lsmod_name "$1")"
  is_module_loaded "$name"
}

# Return success when another mutually exclusive module variant is already active.
mrv_should_skip_for_loaded_conflict_modules() {
  [ -n "$PROFILE_SKIP_IF_MODULES_LOADED" ] || return 1

  for conflict_mod in $PROFILE_SKIP_IF_MODULES_LOADED; do
    [ -n "$conflict_mod" ] || continue

    if mrv_module_loaded "$conflict_mod"; then
      MRV_PROFILE_REASON="conflicting active module is loaded: $conflict_mod"
      return 0
    fi
  done

  return 1
}

# Return success when a module is built into the kernel and cannot be unloaded.
mrv_module_builtin() {
  if [ -f "/lib/modules/$(uname -r)/modules.builtin" ]; then
    mod_pat="$(printf '%s\n' "$1" | sed 's/_/[-_]/g')"
    grep -Eq "/${mod_pat}(\\.ko(\\.[^.]+)*)?$" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null
    return $?
  fi
  return 1
}

# Wait until a module reaches the requested state: present or absent.
mrv_wait_module_state() {
  want="$1"
  name="$2"
  timeout_s="$3"
  elapsed=0

  while [ "$elapsed" -lt "$timeout_s" ] 2>/dev/null; do
    if [ "$want" = "present" ]; then
      if mrv_module_loaded "$name"; then
        return 0
      fi
    else
      if ! mrv_module_loaded "$name"; then
        return 0
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if [ "$want" = "present" ]; then
    mrv_module_loaded "$name"
    return $?
  fi

  if mrv_module_loaded "$name"; then
    return 1
  fi
  return 0
}

# Capture existence and metadata for profile-provided path patterns.
mrv_capture_patterns() {
  patterns="$1"
  outfile="$2"

  : > "$outfile"

  if [ -z "$patterns" ]; then
    return 0
  fi

  # Intentional word splitting: patterns are space-separated profile data.
  # shellcheck disable=SC2086
  set -- $patterns
  for pat in "$@"; do
    found=0
    # Intentional glob expansion from profile data.
    # shellcheck disable=SC2086
    for path in $pat; do
      if [ -e "$path" ] || [ -L "$path" ]; then
        found=1
        printf 'PATH: %s\n' "$path" >> "$outfile"
        ls -ld "$path" >> "$outfile" 2>&1 || true
      fi
    done
    if [ "$found" -eq 0 ] 2>/dev/null; then
      printf 'PATH: %s (not present)\n' "$pat" >> "$outfile"
    fi
  done
}

# Capture status and recent logs for profile services.
mrv_capture_services() {
  services="$1"
  outfile="$2"

  : > "$outfile"

  if [ -z "$services" ]; then
    printf 'No profile services defined\n' >> "$outfile"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'systemctl not available\n' >> "$outfile"
    return 0
  fi

  # Intentional word splitting: services are space-separated profile data.
  # shellcheck disable=SC2086
  set -- $services
  for svc in "$@"; do
    printf '===== %s =====\n' "$svc" >> "$outfile"
    systemctl status "$svc" --no-pager >> "$outfile" 2>&1 || true
    if command -v journalctl >/dev/null 2>&1; then
      printf '\n----- journalctl -u %s -----\n' "$svc" >> "$outfile"
      journalctl -u "$svc" --no-pager -n 200 >> "$outfile" 2>&1 || true
    fi
  done
}

# Capture module, process, service, sysfs, and device state for evidence.
mrv_capture_module_state() {
  outdir="$1"
  mkdir -p "$outdir"

  {
    printf 'profile=%s\n' "${PROFILE_NAME:-unknown}"
    printf 'description=%s\n' "${PROFILE_DESCRIPTION:-unknown}"
    printf 'module=%s\n' "${MODULE_NAME:-unknown}"
    printf 'mode=%s\n' "${PROFILE_SELECTED_MODE:-unknown}"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'date=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
  } > "$outdir/state.txt"

  sys_mod="$(mrv_module_lsmod_name "$MODULE_NAME")"

  {
    printf 'Module-focused lsmod view for %s\n' "$sys_mod"
    lsmod 2>/dev/null | awk -v mod="$sys_mod" '
      NR == 1 { print; next }
      $1 == mod { found=1; print }
      END {
        if (!found) {
          printf "module %s not present in lsmod\n", mod
        }
      }
    '
  } > "$outdir/lsmod.log" 2>&1 || true

  modinfo "$MODULE_NAME" > "$outdir/modinfo.log" 2>&1 || true
  ps -ef > "$outdir/ps.log" 2>&1 || true
  dmesg > "$outdir/dmesg.log" 2>&1 || true

  if [ -d "/sys/module/$sys_mod" ]; then
    find "/sys/module/$sys_mod" -maxdepth 3 -print > "$outdir/sys_module_tree.log" 2>&1 || true
    if [ -d "/sys/module/$sys_mod/holders" ]; then
      ls -la "/sys/module/$sys_mod/holders" > "$outdir/holders.log" 2>&1 || true
    fi
  else
    printf '/sys/module/%s not present\n' "$sys_mod" > "$outdir/holders.log"
  fi

  mrv_capture_services "$PROFILE_SERVICES $PROFILE_QUIESCE_SERVICES" "$outdir/services.log"
  mrv_capture_patterns "$PROFILE_DEVICE_PATTERNS" "$outdir/devices.log"
  mrv_capture_patterns "$PROFILE_SYSFS_PATTERNS" "$outdir/profile_sysfs.log"

  if command -v journalctl >/dev/null 2>&1; then
    journalctl -b --no-pager -n 300 > "$outdir/journal.log" 2>&1 || true
  fi
}

# Capture /proc evidence for a command that timed out.
mrv_capture_pid_timeout_snapshot() {
  pid="$1"
  outdir="$2"

  mkdir -p "$outdir"

  if [ -d "/proc/$pid" ]; then
    cat "/proc/$pid/status" > "$outdir/proc_status.log" 2>&1 || true
    cat "/proc/$pid/wchan" > "$outdir/proc_wchan.log" 2>&1 || true
    cat "/proc/$pid/stack" > "$outdir/proc_stack.log" 2>&1 || true
    ps -T -p "$pid" > "$outdir/ps_threads.log" 2>&1 || true
  fi
}

# Execute a shell command with timeout and command evidence logging.
mrv_exec_with_timeout() {
  timeout_s="$1"
  logfile="$2"
  shift 2
  cmd="$*"
  elapsed=0

  : > "$logfile"
  printf 'CMD: %s\n' "$cmd" >> "$logfile"

  sh -c "$cmd" >> "$logfile" 2>&1 &
  cmd_pid=$!
  MRV_LAST_CMD_PID="$cmd_pid"
  MRV_LAST_CMD_ELAPSED=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_s" ] 2>/dev/null; then
      MRV_LAST_CMD_ELAPSED="$elapsed"

      printf 'TIMEOUT: command exceeded %ss (pid=%s)\n' "$timeout_s" "$cmd_pid" >> "$logfile"

      if [ -n "$MRV_LAST_TIMEOUT_DIR" ]; then
        mrv_capture_pid_timeout_snapshot "$cmd_pid" "$MRV_LAST_TIMEOUT_DIR"
      fi

      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 2

      if kill -0 "$cmd_pid" 2>/dev/null; then
        printf 'TIMEOUT: pid %s ignored SIGTERM, sending SIGKILL\n' "$cmd_pid" >> "$logfile"
        kill -KILL "$cmd_pid" 2>/dev/null || true
        sleep 1
      fi

      if kill -0 "$cmd_pid" 2>/dev/null; then
        printf 'TIMEOUT: pid %s still present after SIGKILL (likely stuck in kernel)\n' "$cmd_pid" >> "$logfile"
      fi

      return 124
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$cmd_pid"
  rc=$?
  MRV_LAST_CMD_ELAPSED="$elapsed"
  return "$rc"
}

# Capture hang evidence after unload/load timeout.
mrv_capture_hang_evidence() {
  phase="$1"
  outdir="$2"

  mkdir -p "$outdir"
  mrv_capture_module_state "$outdir"

  if [ "$ENABLE_SYSRQ_HANG_DUMP" -eq 1 ] 2>/dev/null; then
    if [ -w /proc/sysrq-trigger ]; then
      printf 'Triggered sysrq-t and sysrq-w\n' > "$outdir/sysrq_actions.log"
      echo t > /proc/sysrq-trigger 2>/dev/null || true
      echo w > /proc/sysrq-trigger 2>/dev/null || true
      dmesg > "$outdir/dmesg_after_sysrq.log" 2>&1 || true
    fi
  fi

  if command -v fuser >/dev/null 2>&1; then
    : > "$outdir/fuser.log"
    # Intentional word splitting: device patterns are profile data.
    # shellcheck disable=SC2086
    set -- $PROFILE_DEVICE_PATTERNS
    for pat in "$@"; do
      # Intentional glob expansion from profile data.
      # shellcheck disable=SC2086
      for path in $pat; do
        if [ -e "$path" ] || [ -L "$path" ]; then
          printf '===== %s =====\n' "$path" >> "$outdir/fuser.log"
          fuser -vm "$path" >> "$outdir/fuser.log" 2>&1 || true
        fi
      done
    done
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof > "$outdir/lsof.log" 2>&1 || true
  fi

  {
    printf 'phase=%s\n' "$phase"
    printf 'pid=%s\n' "$MRV_LAST_CMD_PID"
    printf 'elapsed=%s\n' "$MRV_LAST_CMD_ELAPSED"
  } > "$outdir/timeout_summary.log"
}

# Return success when a profile hook function exists.
mrv_profile_override_defined() {
  fn_name="$1"
  command -v "$fn_name" >/dev/null 2>&1
}

# Return success when a systemd service is known on the target.
module_reload_service_known() {
  svc="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  systemctl show "$svc" >/dev/null 2>&1
}

# Read one systemd service state property.
module_reload_service_state_value() {
  svc="$1"
  prop="$2"

  val="$(systemctl show -p "$prop" --value "$svc" 2>/dev/null || true)"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
  else
    printf 'unknown\n'
  fi
}

# Return the file used to track services stopped/masked by module reload tests.
#
# The file is under RESULT_ROOT so it is shared between the profile subshell and
# the top-level run.sh cleanup trap.
module_reload_restore_services_file() {
  printf '%s\n' "${MRV_RESTORE_SERVICES_FILE:-${RESULT_ROOT:-/tmp}/.module_reload_services_to_restore}"
}

# Record services before stopping/masking them.
#
# We store the previous ActiveState so final restore can avoid starting services
# that were already inactive before this test touched them.
module_reload_record_restore_services() {
  services="$1"
  restore_file="$(module_reload_restore_services_file)"
  restore_dir="$(dirname "$restore_file")"

  [ -n "$services" ] || return 0

  mkdir -p "$restore_dir" 2>/dev/null || true

  for svc in $services; do
    [ -n "$svc" ] || continue

    if module_reload_service_known "$svc"; then
      svc_state="$(module_reload_service_state_value "$svc" "ActiveState")"

      if [ ! -f "$restore_file" ] || ! grep -q "^${svc} " "$restore_file" 2>/dev/null; then
        printf '%s %s\n' "$svc" "$svc_state" >> "$restore_file"
      fi
    fi
  done

  return 0
}

# Restore every service previously stopped/masked by the module reload test.
#
# This is best-effort and should not fail the test. It unblocks the target after
# failed unloads, post-unload validation failures, timeouts, or interrupted runs.
#
# Services that were active before quiesce are started again. Services that were
# inactive before quiesce are only unmasked/reset, not force-started.
module_reload_restore_recorded_services() {
  log_tag="${1:-module-reload}"
  restore_file="$(module_reload_restore_services_file)"
 
  [ -f "$restore_file" ] || return 0
 
  if ! command -v systemctl >/dev/null 2>&1; then
    rm -f "$restore_file" 2>/dev/null || true
    return 0
  fi
 
  while IFS=' ' read -r svc old_state rest || [ -n "$svc" ]; do
    : "${rest:=}"
    [ -n "$svc" ] || continue
 
    if module_reload_service_known "$svc"; then
      log_info "[$log_tag] restore: unmasking/resetting $svc"
      module_reload_run_cmd_quiet_timeout 5 systemctl unmask "$svc" || true
      module_reload_run_cmd_quiet_timeout 5 systemctl reset-failed "$svc" || true
 
      case "$old_state" in
        active|activating|reloading)
          log_info "[$log_tag] restore: starting previously active service $svc"
          module_reload_run_cmd_quiet_timeout 15 systemctl start "$svc" || true
          ;;
        *)
          log_info "[$log_tag] restore: not starting $svc because previous state was ${old_state:-unknown}"
          ;;
      esac
    fi
  done < "$restore_file"
 
  rm -f "$restore_file" 2>/dev/null || true
  return 0
}

# List process IDs whose command line contains a pattern.
module_reload_list_pids_by_pattern() {
  proc_pat="$1"

  ps -eo pid=,args= 2>/dev/null | while IFS= read -r line; do
    line_trim="$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//')"
    [ -n "$line_trim" ] || continue

    pid="${line_trim%% *}"
    cmd="${line_trim#"$pid"}"
    cmd="$(printf '%s\n' "$cmd" | sed 's/^[[:space:]]*//')"

    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue

    case "$cmd" in
      *"$proc_pat"*)
        printf '%s\n' "$pid"
        ;;
    esac
  done
}

# Return success when any process matching a pattern is running.
module_reload_proc_running_pattern() {
  proc_pat="$1"
  pids="$(module_reload_list_pids_by_pattern "$proc_pat")"

  if [ -n "$pids" ]; then
    return 0
  fi
  return 1
}

# Signal all processes whose command line contains a pattern.
module_reload_signal_pattern() {
  proc_pat="$1"
  sig="$2"
  log_tag="${3:-module-reload}"
  pids="$(module_reload_list_pids_by_pattern "$proc_pat")"

  for pid in $pids; do
    if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
      log_info "[$log_tag] sending SIG${sig} to pid=$pid pattern=$proc_pat"
      kill "-$sig" "$pid" >/dev/null 2>&1 || true
    fi
  done

  return 0
}

# Wait until no processes match any pattern.
module_reload_wait_no_procs_patterns() {
  proc_patterns="$1"
  timeout_s="${2:-10}"
  elapsed=0

  while [ "$elapsed" -lt "$timeout_s" ] 2>/dev/null; do
    found=0

    for proc_pat in $proc_patterns; do
      if module_reload_proc_running_pattern "$proc_pat"; then
        found=1
        break
      fi
    done

    if [ "$found" -eq 0 ]; then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  for proc_pat in $proc_patterns; do
    if module_reload_proc_running_pattern "$proc_pat"; then
      return 1
    fi
  done

  return 0
}

# Log current service states and matching process command lines.
module_reload_log_service_process_summary() {
  services="$1"
  proc_patterns="$2"
  log_tag="${3:-module-reload}"

  if command -v systemctl >/dev/null 2>&1; then
    for svc in $services; do
      if module_reload_service_known "$svc"; then
        svc_active="$(module_reload_service_state_value "$svc" "ActiveState")"
        svc_sub="$(module_reload_service_state_value "$svc" "SubState")"
        svc_pid="$(module_reload_service_state_value "$svc" "MainPID")"
        log_info "[$log_tag] $svc state=${svc_active}/${svc_sub} mainpid=${svc_pid}"
      fi
    done
  fi

  ps -eo pid=,args= 2>/dev/null | while IFS= read -r line; do
    line_trim="$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//')"
    [ -n "$line_trim" ] || continue

    pid="${line_trim%% *}"
    cmd="${line_trim#"$pid"}"
    cmd="$(printf '%s\n' "$cmd" | sed 's/^[[:space:]]*//')"

    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue

    for proc_pat in $proc_patterns; do
      case "$cmd" in
        *"$proc_pat"*)
          log_info "[$log_tag] proc pid=$pid cmd=$cmd"
          break
          ;;
      esac
    done
  done
}

# Wait until all known services are active.
module_reload_wait_services_active() {
  services="$1"
  timeout_s="${2:-15}"
  elapsed=0

  while [ "$elapsed" -lt "$timeout_s" ] 2>/dev/null; do
    all_ok=1

    for svc in $services; do
      if module_reload_service_known "$svc"; then
        if ! systemctl is-active --quiet "$svc"; then
          all_ok=0
          break
        fi
      fi
    done

    if [ "$all_ok" -eq 1 ]; then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      if ! systemctl is-active --quiet "$svc"; then
        return 1
      fi
    fi
  done

  return 0
}

# Wait until all known services are inactive.
module_reload_wait_services_inactive() {
  services="$1"
  timeout_s="${2:-15}"
  elapsed=0

  while [ "$elapsed" -lt "$timeout_s" ] 2>/dev/null; do
    all_ok=1

    for svc in $services; do
      if module_reload_service_known "$svc"; then
        if systemctl is-active --quiet "$svc"; then
          all_ok=0
          break
        fi
      fi
    done

    if [ "$all_ok" -eq 1 ]; then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      if systemctl is-active --quiet "$svc"; then
        return 1
      fi
    fi
  done

  return 0
}

module_reload_run_cmd_quiet_timeout() {
  timeout_s="$1"
  shift
  elapsed=0

  if [ "$#" -eq 0 ]; then
    return 1
  fi

  "$@" >/dev/null 2>&1 &
  cmd_pid=$!

  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_s" ] 2>/dev/null; then
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 1

      if kill -0 "$cmd_pid" 2>/dev/null; then
        kill -KILL "$cmd_pid" 2>/dev/null || true
        sleep 1
      fi

      wait "$cmd_pid" 2>/dev/null || true
      return 124
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$cmd_pid"
  return $?
}

# Start and unmask known services, then wait until active.
module_reload_start_services() {
  services="$1"
  timeout_s="${2:-15}"
  log_tag="${3:-module-reload}"
 
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
 
  for svc in $services; do
    if module_reload_service_known "$svc"; then
      log_info "[$log_tag] start: unmasking $svc"
      module_reload_run_cmd_quiet_timeout 5 systemctl unmask "$svc" || true
 
      log_info "[$log_tag] start: resetting $svc"
      module_reload_run_cmd_quiet_timeout 5 systemctl reset-failed "$svc" || true
 
      log_info "[$log_tag] start: starting $svc"
      module_reload_run_cmd_quiet_timeout "$timeout_s" systemctl start "$svc" || true
    fi
  done
 
  module_reload_wait_services_active "$services" "$timeout_s"
}

# Stop, mask, and kill known services and matching processes.
module_reload_stop_mask_kill_services() {
  services="$1"
  proc_patterns="$2"
  timeout_s="${3:-20}"
  log_tag="${4:-module-reload}"
 
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
 
  module_reload_record_restore_services "$services"
 
  for svc in $services; do
    if module_reload_service_known "$svc"; then
      log_info "[$log_tag] quiesce: stopping $svc"
      if ! module_reload_run_cmd_quiet_timeout "$timeout_s" systemctl stop "$svc"; then
        log_warn "[$log_tag] quiesce: stop timed out or failed for $svc"
      fi
 
      log_info "[$log_tag] quiesce: masking $svc"
      module_reload_run_cmd_quiet_timeout 5 systemctl mask "$svc" || true
 
      log_info "[$log_tag] quiesce: killing remaining $svc cgroup processes"
      module_reload_run_cmd_quiet_timeout 5 systemctl kill --kill-who=all "$svc" || true
    fi
  done
 
  for proc_pat in $proc_patterns; do
    module_reload_signal_pattern "$proc_pat" TERM "$log_tag"
  done
 
  sleep 2
 
  if ! module_reload_wait_no_procs_patterns "$proc_patterns" 5; then
    log_warn "[$log_tag] quiesce: TERM was not enough, sending SIGKILL to remaining processes"
    for proc_pat in $proc_patterns; do
      module_reload_signal_pattern "$proc_pat" KILL "$log_tag"
    done
    sleep 1
  fi
 
  if ! module_reload_wait_services_inactive "$services" "$timeout_s"; then
    log_warn "[$log_tag] quiesce: one or more services still not inactive after timeout"
    return 1
  fi
 
  if ! module_reload_wait_no_procs_patterns "$proc_patterns" 2; then
    log_warn "[$log_tag] quiesce: one or more process patterns still present after timeout"
    return 1
  fi
 
  return 0
}

# Restore known services after a profile finishes.
module_reload_restore_services() {
  services="$1"
  timeout_s="${2:-15}"
  log_tag="${3:-module-reload}"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      log_info "[$log_tag] finalize: restoring $svc"
      systemctl unmask "$svc" >/dev/null 2>&1 || true
      systemctl reset-failed "$svc" >/dev/null 2>&1 || true
      systemctl start "$svc" >/dev/null 2>&1 || true
    fi
  done

  module_reload_wait_services_active "$services" "$timeout_s"
}

# Dump status for a list of services to a file.
module_reload_dump_service_status() {
  services="$1"
  svc_log="$2"

  [ -n "$svc_log" ] || return 0
  : > "$svc_log"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      printf '===== %s =====\n' "$svc" >> "$svc_log"
      systemctl status "$svc" --no-pager >> "$svc_log" 2>&1 || true
    fi
  done

  return 0
}

# Scan /proc/*/fd for open descriptors matching path patterns.
module_reload_scan_open_fds_by_path_patterns() {
  path_patterns="$1"
  out_file="$2"

  : > "$out_file"

  [ -n "$path_patterns" ] || return 1

  for pid_dir in /proc/[0-9]*; do
    [ -d "$pid_dir/fd" ] || continue
    pid="${pid_dir##*/}"

    for fd in "$pid_dir"/fd/*; do
      [ -e "$fd" ] || continue

      target="$(readlink "$fd" 2>/dev/null || true)"
      [ -n "$target" ] || continue
  for pat in $path_patterns; do
        # Intentional glob pattern match from profile data.
        # shellcheck disable=SC2254
        case "$target" in
          $pat)
            cmd="$(tr '\0' ' ' < "$pid_dir/cmdline" 2>/dev/null || true)"
            [ -n "$cmd" ] || cmd="$(cat "$pid_dir/comm" 2>/dev/null || true)"
            printf 'pid=%s fd=%s target=%s cmd=%s\n' "$pid" "${fd##*/}" "$target" "$cmd" >> "$out_file"
            ;;
        esac
      done
    done
  done

  [ -s "$out_file" ]
}

# Terminate processes that keep matching device paths open.
module_reload_kill_open_fd_users_by_path_patterns() {
  path_patterns="$1"
  timeout_s="${2:-10}"
  log_tag="${3:-module-reload}"
  out_file="${4:-/tmp/module_reload_open_fds.log}"

  if ! module_reload_scan_open_fds_by_path_patterns "$path_patterns" "$out_file"; then
    return 0
  fi

  log_warn "[$log_tag] open users found for profiled device paths: $out_file"

  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^pid=/) {
          sub(/^pid=/, "", $i)
          print $i
        }
      }
    }
  ' "$out_file" | sort -u | while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue
    log_warn "[$log_tag] sending SIGTERM to open-fd user pid=$pid"
    kill -TERM "$pid" 2>/dev/null || true
  done

  elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ] 2>/dev/null; do
    if ! module_reload_scan_open_fds_by_path_patterns "$path_patterns" "$out_file"; then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^pid=/) {
          sub(/^pid=/, "", $i)
          print $i
        }
      }
    }
  ' "$out_file" | sort -u | while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue
    log_warn "[$log_tag] sending SIGKILL to remaining open-fd user pid=$pid"
    kill -KILL "$pid" 2>/dev/null || true
  done

  sleep 1

  if module_reload_scan_open_fds_by_path_patterns "$path_patterns" "$out_file"; then
    log_warn "[$log_tag] open users still present after SIGKILL: $out_file"
    return 1
  fi

  return 0
}

# Generic quiesce helper for services, process patterns, and open device users.
module_reload_profile_quiesce_resources() {
  log_tag="${1:-$PROFILE_NAME}"
  iter_dir="${2:-}"
  timeout_s="${3:-20}"

  services="${PROFILE_QUIESCE_SERVICES:-$PROFILE_SERVICES}"
  procs="${PROFILE_QUIESCE_PROC_PATTERNS:-$PROFILE_PROC_PATTERNS}"
  devs="${PROFILE_QUIESCE_DEVICE_PATTERNS:-$PROFILE_DEVICE_PATTERNS}"

  module_reload_log_service_process_summary "$services" "$procs" "$log_tag"

  if [ -n "$services" ] || [ -n "$procs" ]; then
    if ! module_reload_stop_mask_kill_services "$services" "$procs" "$timeout_s" "$log_tag"; then
      log_warn "[$log_tag] service/process quiesce did not fully complete"
      module_reload_log_service_process_summary "$services" "$procs" "$log_tag"
    fi
  fi

  if [ -n "$devs" ]; then
    if [ -n "$iter_dir" ]; then
      open_fd_log="$iter_dir/open_fds_before_unload.log"
    else
      open_fd_log="/tmp/module_reload_open_fds_before_unload.log"
    fi

    if ! module_reload_kill_open_fd_users_by_path_patterns "$devs" 10 "$log_tag" "$open_fd_log"; then
      log_warn "[$log_tag] open device users remain after quiesce; skipping unsafe unload"
      return 1
    fi
  fi

  sleep 2
  return 0
}

# Generic smoke helper that validates expected modules are loaded.
module_reload_profile_smoke_modules_present() {
  log_tag="${1:-$PROFILE_NAME}"
  modules="$2"

  [ -n "$modules" ] || modules="$MODULE_NAME"

  for mod in $modules; do
    if ! mrv_module_loaded "$mod"; then
      log_fail "[$log_tag] expected module not loaded after reload: $mod"
      return 1
    fi
  done

  return 0
}

# Dispatch optional profile prepare hook.
module_reload_profile_prepare() {
  profile_root="$1"
  : "${profile_root:=}"

  if mrv_profile_override_defined profile_prepare; then
    profile_prepare "$profile_root"
    return $?
  fi

  return 0
}

# Dispatch optional warmup hook or generic daemon warmup.
module_reload_profile_warmup() {
  iter_dir="$1"
  : "${iter_dir:=}"

  if mrv_profile_override_defined profile_warmup; then
    profile_warmup "$iter_dir"
    return $?
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  case "$PROFILE_SELECTED_MODE" in
    basic)
      return 0
      ;;
    daemon_lifecycle|service_rebind)
      if ! module_reload_start_services "$PROFILE_SERVICES" 15 "$PROFILE_NAME"; then
        module_reload_log_service_process_summary "$PROFILE_SERVICES" "$PROFILE_PROC_PATTERNS" "$PROFILE_NAME"
        log_error "[$PROFILE_NAME] warmup: services failed to become active"
        return 1
      fi
      ;;
    *)
      log_warn "[$PROFILE_NAME] unknown mode '$PROFILE_SELECTED_MODE', continuing without warmup actions"
      ;;
  esac

  return 0
}

# Best-effort restore for services stopped/masked only for quiesce.
#
# Unlike module_reload_restore_services(), this does not require services to
# become active. This is needed for oneshot or optional services such as
# pulseaudio.service, alsa-restore.service, and distro-specific units.
module_reload_restore_quiesce_services_best_effort() {
  services="$1"
  log_tag="${2:-module-reload}"

  [ -n "$services" ] || return 0

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      log_info "[$log_tag] restore: unmasking/resetting $svc"
      systemctl unmask "$svc" >/dev/null 2>&1 || true
      systemctl reset-failed "$svc" >/dev/null 2>&1 || true
      log_info "[$log_tag] restore: starting $svc"
      systemctl start "$svc" >/dev/null 2>&1 || true
    fi
  done

  return 0
}

# Dispatch optional quiesce hook or generic daemon quiesce.
module_reload_profile_quiesce() {
  iter_dir="$1"
  : "${iter_dir:=}"
 
  if mrv_profile_override_defined profile_quiesce; then
    profile_quiesce "$iter_dir"
    return $?
  fi
 
  quiesce_services="${PROFILE_QUIESCE_SERVICES:-$PROFILE_SERVICES}"
  quiesce_proc_patterns="${PROFILE_QUIESCE_PROC_PATTERNS:-$PROFILE_PROC_PATTERNS}"
 
  if [ -z "$quiesce_services" ] && [ -z "$quiesce_proc_patterns" ]; then
    return 0
  fi
 
  if [ "${PROFILE_QUIESCE_ONCE:-no}" = "yes" ] && [ "${MRV_PROFILE_QUIESCED:-0}" = "1" ]; then
    log_info "[$PROFILE_NAME] quiesce: already completed once for this profile, skipping repeated quiesce"
    return 0
  fi
 
  module_reload_log_service_process_summary \
    "$quiesce_services" \
    "$quiesce_proc_patterns" \
    "$PROFILE_NAME"
 
  case "$PROFILE_SELECTED_MODE" in
    basic|daemon_lifecycle|service_rebind)
      if ! module_reload_stop_mask_kill_services \
        "$quiesce_services" \
        "$quiesce_proc_patterns" \
        20 \
        "$PROFILE_NAME"; then
        module_reload_log_service_process_summary \
          "$quiesce_services" \
          "$quiesce_proc_patterns" \
          "$PROFILE_NAME"
        log_error "[$PROFILE_NAME] quiesce: services/processes did not fully stop"
        return 1
      fi
      MRV_PROFILE_QUIESCED="1"
      ;;
    *)
      log_warn "[$PROFILE_NAME] unknown mode '$PROFILE_SELECTED_MODE', continuing without quiesce actions"
      ;;
  esac
 
  return 0
}

# Dispatch optional post-unload hook.
module_reload_profile_post_unload() {
  iter_dir="$1"
  : "${iter_dir:=}"

  if mrv_profile_override_defined profile_post_unload; then
    profile_post_unload "$iter_dir"
    return $?
  fi

  return 0
}

# Dispatch optional post-load hook or generic daemon restart.
module_reload_profile_post_load() {
  iter_dir="$1"
  : "${iter_dir:=}"
  svc_log="$iter_dir/post_load_services.log"
 
  if mrv_profile_override_defined profile_post_load; then
    profile_post_load "$iter_dir"
    return $?
  fi
 
  case "$PROFILE_SELECTED_MODE" in
    basic)
      # Do not restore quiesced services after every basic-mode iteration.
      #
      # Restoring here causes repeated start/stop cycles for services such as
      # pipewire, wireplumber, NetworkManager, and wpa_supplicant. For audio,
      # repeated pipewire-pulse stop/start can stall the test.
      #
      # Services are restored once in module_reload_profile_finalize() or from
      # the run.sh cleanup trap if the test exits early.
      module_reload_dump_service_status "$PROFILE_QUIESCE_SERVICES" "$svc_log"
      return 0
      ;;
    daemon_lifecycle|service_rebind)
      if ! command -v systemctl >/dev/null 2>&1; then
        return 0
      fi
 
      if ! module_reload_start_services "$PROFILE_SERVICES" 15 "$PROFILE_NAME"; then
        module_reload_log_service_process_summary "$PROFILE_SERVICES" "$PROFILE_PROC_PATTERNS" "$PROFILE_NAME"
        log_error "[$PROFILE_NAME] post-load: services failed to become active after reload"
        module_reload_restore_recorded_services "$PROFILE_NAME"
        return 1
      fi
 
      module_reload_dump_service_status "$PROFILE_SERVICES" "$svc_log"
      module_reload_restore_recorded_services "$PROFILE_NAME"
      ;;
    *)
      log_warn "[$PROFILE_NAME] unknown mode '$PROFILE_SELECTED_MODE', continuing without post-load actions"
      ;;
  esac
 
  return 0
}

# Dispatch optional smoke hook.
module_reload_profile_smoke() {
  iter_dir="$1"
  : "${iter_dir:=}"

  if mrv_profile_override_defined profile_smoke; then
    profile_smoke "$iter_dir"
    return $?
  fi

  return 0
}

# Dispatch optional finalize hook or restore services that were managed.
module_reload_profile_finalize() {
  profile_root="$1"
  : "${profile_root:=}"
 
  if mrv_profile_override_defined profile_finalize; then
    profile_finalize "$profile_root"
    profile_finalize_rc=$?
    module_reload_restore_recorded_services "$PROFILE_NAME"
    return "$profile_finalize_rc"
  fi
 
  module_reload_restore_recorded_services "$PROFILE_NAME"
 
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
 
  if ! module_reload_restore_services "$PROFILE_SERVICES" 15 "$PROFILE_NAME"; then
    log_error "[$PROFILE_NAME] finalize: failed to restore services"
    return 1
  fi
 
  return 0
}

# Validate the profile after it is sourced and before iterations run.
mrv_profile_check() {
  requested_mode="$1"

  if [ -z "$PROFILE_NAME" ] || [ -z "$MODULE_NAME" ]; then
    MRV_PROFILE_REASON="profile missing PROFILE_NAME or MODULE_NAME"
    return 2
  fi

  if mrv_should_skip_for_loaded_conflict_modules; then
    return 2
  fi

  if [ "${MODULE_RELOAD_SUPPORTED:-yes}" != "yes" ]; then
    MRV_PROFILE_REASON="profile marks module as non-reloadable"
    return 2
  fi

  if mrv_module_builtin "$MODULE_NAME"; then
    MRV_PROFILE_REASON="module is built-in and cannot be unloaded"
    return 2
  fi

  if ! modinfo "$MODULE_NAME" >/dev/null 2>&1; then
    if ! mrv_module_loaded "$MODULE_NAME"; then
      MRV_PROFILE_REASON="module not present on image"
      return 2
    fi
  fi

  if ! command -v modprobe >/dev/null 2>&1; then
    MRV_PROFILE_REASON="modprobe not available"
    return 2
  fi

  if ! command -v rmmod >/dev/null 2>&1; then
    MRV_PROFILE_REASON="rmmod not available"
    return 2
  fi

  required="${PROFILE_REQUIRED_CMDS:-}"
  if [ -n "$required" ]; then
    # Intentional word splitting: required commands are profile data.
    # shellcheck disable=SC2086
    set -- $required
    for req in "$@"; do
      if ! command -v "$req" >/dev/null 2>&1; then
        MRV_PROFILE_REASON="required command missing: $req"
        return 2
      fi
    done
  fi

  MODULE_LOAD_CMD="${MODULE_LOAD_CMD:-modprobe $MODULE_NAME}"
  MODULE_UNLOAD_CMD="${MODULE_UNLOAD_CMD:-rmmod $MODULE_NAME}"
  PROFILE_SELECTED_MODE="${requested_mode:-${PROFILE_MODE_DEFAULT:-basic}}"

  return 0
}

# Validate that a list of modules is present or absent.
mrv_validate_module_list_state() {
  want="$1"
  modules="$2"

  [ -n "$modules" ] || return 0

  for mod in $modules; do
    [ -n "$mod" ] || continue

    case "$want" in
      absent)
        if mrv_module_loaded "$mod"; then
          log_fail "[$PROFILE_NAME] expected module absent after unload, but still loaded: $mod"
          return 1
        fi
        ;;
      present)
        if ! mrv_module_loaded "$mod"; then
          log_fail "[$PROFILE_NAME] expected module present after load, but missing: $mod"
          return 1
        fi
        ;;
      *)
        log_error "[$PROFILE_NAME] invalid module state request: $want"
        return 1
        ;;
    esac
  done

  return 0
}

# Validate module state after unload completes.
mrv_post_unload_validate() {
  if ! mrv_wait_module_state absent "$MODULE_NAME" "$TIMEOUT_SETTLE"; then
    log_fail "[$PROFILE_NAME] module still present after unload settle timeout"
    return 1
  fi

  if ! mrv_validate_module_list_state absent "$PROFILE_EXPECT_ABSENT_AFTER_UNLOAD"; then
    return 1
  fi

  return 0
}

# Validate module state after load completes.
mrv_post_load_validate() {
  if ! mrv_wait_module_state present "$MODULE_NAME" "$TIMEOUT_SETTLE"; then
    log_fail "[$PROFILE_NAME] module did not reappear after load settle timeout"
    return 1
  fi

  if ! mrv_validate_module_list_state present "$PROFILE_EXPECT_PRESENT_AFTER_LOAD"; then
    return 1
  fi

  return 0
}

# Execute one unload/reload iteration for the active profile.
mrv_run_iteration() {
  iter="$1"
  iter_dir="$RESULT_ROOT/$PROFILE_NAME/iter_$(printf '%02d' "$iter")"
  preload_log="$iter_dir/preload.log"
  unload_log="$iter_dir/unload.log"
  load_log="$iter_dir/load.log"
  unload_elapsed=0
  load_elapsed=0

  mkdir -p "$iter_dir"

  if ! mrv_module_loaded "$MODULE_NAME"; then
    log_info "[$PROFILE_NAME] module not loaded before iteration $iter, creating baseline loaded state"
    MRV_LAST_TIMEOUT_DIR="$iter_dir/preload_timeout"
    mrv_exec_with_timeout "$TIMEOUT_LOAD" "$preload_log" "$MODULE_LOAD_CMD"
    preload_rc=$?
    if [ "$preload_rc" -ne 0 ]; then
      log_fail "[$PROFILE_NAME] failed to create baseline loaded state before iteration $iter (rc=$preload_rc)"
      log_info "[$PROFILE_NAME] preload log: $preload_log"
      return 1
    fi
    if ! mrv_post_load_validate; then
      log_info "[$PROFILE_NAME] baseline post-load validation failed"
      return 1
    fi
  fi

  if ! module_reload_profile_warmup "$iter_dir"; then
    log_fail "[$PROFILE_NAME] warmup stage failed in iteration $iter"
    return 1
  fi

  mrv_capture_module_state "$iter_dir/pre_state"

  if ! module_reload_profile_quiesce "$iter_dir"; then
    log_fail "[$PROFILE_NAME] quiesce stage failed in iteration $iter"
    return 1
  fi

  log_info "[$PROFILE_NAME] iter $iter/$ITERATIONS exec: $MODULE_UNLOAD_CMD"
  MRV_LAST_TIMEOUT_DIR="$iter_dir/unload_timeout"
  mrv_exec_with_timeout "$TIMEOUT_UNLOAD" "$unload_log" "$MODULE_UNLOAD_CMD"
  unload_rc=$?
  unload_elapsed="$MRV_LAST_CMD_ELAPSED"

  if [ "$unload_rc" -eq 124 ]; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS unload timed out after ${unload_elapsed}s (pid=$MRV_LAST_CMD_PID)"
    log_info "[$PROFILE_NAME] unload timeout log: $unload_log"
    log_info "[$PROFILE_NAME] collecting hang evidence in: $iter_dir/hang_evidence"
    mrv_capture_hang_evidence unload "$iter_dir/hang_evidence"
    log_fail "[$PROFILE_NAME] hang evidence captured; failing iteration $iter/$ITERATIONS"
    return 1
  fi

  if [ "$unload_rc" -ne 0 ]; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS unload failed (rc=$unload_rc)"
    log_info "[$PROFILE_NAME] unload log: $unload_log"
    mrv_capture_module_state "$iter_dir/unload_failure_state"
    return 1
  fi

  if ! mrv_post_unload_validate; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS post-unload validation failed"
    mrv_capture_module_state "$iter_dir/post_unload_invalid_state"
    return 1
  fi

  mrv_capture_module_state "$iter_dir/post_unload_state"

  if ! module_reload_profile_post_unload "$iter_dir"; then
    log_fail "[$PROFILE_NAME] post-unload stage failed in iteration $iter"
    return 1
  fi

  log_info "[$PROFILE_NAME] iter $iter/$ITERATIONS exec: $MODULE_LOAD_CMD"
  MRV_LAST_TIMEOUT_DIR="$iter_dir/load_timeout"
  mrv_exec_with_timeout "$TIMEOUT_LOAD" "$load_log" "$MODULE_LOAD_CMD"
  load_rc=$?
  load_elapsed="$MRV_LAST_CMD_ELAPSED"

  if [ "$load_rc" -eq 124 ]; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS load timed out after ${load_elapsed}s (pid=$MRV_LAST_CMD_PID)"
    log_info "[$PROFILE_NAME] load timeout log: $load_log"
    log_info "[$PROFILE_NAME] collecting hang evidence in: $iter_dir/load_hang_evidence"
    mrv_capture_hang_evidence load "$iter_dir/load_hang_evidence"
    log_fail "[$PROFILE_NAME] hang evidence captured, failing iteration $iter/$ITERATIONS"
    return 1
  fi

  if [ "$load_rc" -ne 0 ]; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS load failed (rc=$load_rc)"
    log_info "[$PROFILE_NAME] load log: $load_log"
    mrv_capture_module_state "$iter_dir/load_failure_state"
    return 1
  fi

  if ! mrv_post_load_validate; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS post-load validation failed"
    mrv_capture_module_state "$iter_dir/post_load_invalid_state"
    return 1
  fi

  if ! module_reload_profile_post_load "$iter_dir"; then
    log_fail "[$PROFILE_NAME] post-load stage failed in iteration $iter"
    mrv_capture_module_state "$iter_dir/post_load_hook_failure_state"
    return 1
  fi

  if ! module_reload_profile_smoke "$iter_dir"; then
    log_fail "[$PROFILE_NAME] smoke stage failed in iteration $iter"
    mrv_capture_module_state "$iter_dir/smoke_failure_state"
    return 1
  fi

  mrv_capture_module_state "$iter_dir/post_load_state"

  if command -v diff >/dev/null 2>&1; then
    diff -u "$iter_dir/pre_state/dmesg.log" "$iter_dir/post_load_state/dmesg.log" > "$iter_dir/dmesg.diff" 2>&1 || true
  fi

  {
    printf 'iter=%s\n' "$iter"
    printf 'unload_elapsed=%s\n' "$unload_elapsed"
    printf 'load_elapsed=%s\n' "$load_elapsed"
  } > "$iter_dir/iteration_metrics.log"

  log_pass "[$PROFILE_NAME] iteration $iter/$ITERATIONS passed"
  return 0
}

# Run one profile in a subshell so profile variables and hooks do not leak.
mrv_run_one_profile() (
  profile_file="$1"
  requested_mode="$2"

  mrv_reset_profile_vars

  # shellcheck disable=SC1090
  . "$profile_file"

  mrv_profile_check "$requested_mode"
  check_rc=$?
  if [ "$check_rc" -eq 2 ]; then
    log_skip "[$(basename "$profile_file" .profile)] SKIP - $MRV_PROFILE_REASON"
    exit 2
  fi
  if [ "$check_rc" -ne 0 ]; then
    log_fail "[$(basename "$profile_file" .profile)] FAIL - profile validation error"
    exit 1
  fi

  profile_root="$RESULT_ROOT/$PROFILE_NAME"
  mkdir -p "$profile_root"

  {
    printf 'profile=%s\n' "$PROFILE_NAME"
    printf 'description=%s\n' "${PROFILE_DESCRIPTION:-unknown}"
    printf 'module=%s\n' "$MODULE_NAME"
    printf 'mode=%s\n' "$PROFILE_SELECTED_MODE"
  } > "$profile_root/profile_info.txt"

  log_info "[$PROFILE_NAME] module=$MODULE_NAME mode=$PROFILE_SELECTED_MODE iterations=$ITERATIONS"

  if ! module_reload_profile_prepare "$profile_root"; then
    log_fail "[$PROFILE_NAME] prepare stage failed"
    exit 1
  fi

  iter=1
  while [ "$iter" -le "$ITERATIONS" ] 2>/dev/null; do
    if ! mrv_run_iteration "$iter"; then
      module_reload_profile_finalize "$profile_root" >/dev/null 2>&1 || true
      exit 1
    fi
    iter=$((iter + 1))
  done

  if ! module_reload_profile_finalize "$profile_root"; then
    log_fail "[$PROFILE_NAME] finalize stage failed"
    exit 1
  fi

  exit 0
)

# Resolve explicit module, profile list, enabled list, or all profile files.
mrv_resolve_profiles() {
  target_module="$1"
  profile_dir="$2"
  profile_list_file="$3"

  if [ -n "$target_module" ]; then
    candidate="$profile_dir/$target_module.profile"
    if [ ! -f "$candidate" ]; then
      log_error "Profile not found: $candidate"
      return 1
    fi
    printf '%s\n' "$candidate"
    return 0
  fi

  if [ -f "$profile_list_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|'#'*) continue ;;
      esac
      candidate="$profile_dir/$line.profile"
      if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
      else
        log_warn "Enabled profile listed but missing: $candidate"
      fi
    done < "$profile_list_file"
    return 0
  fi

  for candidate in "$profile_dir"/*.profile; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
    fi
  done

  return 0
}

###############################################################################
# Qualcomm GPU boot-state helpers
###############################################################################

# Report the GPU ownership selected during the current boot.
#
# Output:
#   kgsl    - msm skip_gpu is enabled and KGSL owns the GPU
#   msm     - upstream MSM/freedreno owns the GPU
#   unknown - the state is incomplete or contradictory
mrv_qcom_gpu_boot_mode() {
    mqgbm_kgsl_module="${1:-msm_kgsl}"
    mqgbm_kgsl_device="${2:-/dev/kgsl-3d0}"
    mqgbm_msm_module="${3:-msm}"
    mqgbm_skip_gpu=""
    mqgbm_kgsl_loaded=0
    mqgbm_msm_loaded=0

    if [ -r "/sys/module/$mqgbm_msm_module/parameters/skip_gpu" ]; then
        mqgbm_skip_gpu="$(
            cat "/sys/module/$mqgbm_msm_module/parameters/skip_gpu" \
                2>/dev/null || true
        )"
    fi

    if mrv_module_loaded "$mqgbm_kgsl_module"; then
        mqgbm_kgsl_loaded=1
    fi

    if mrv_module_loaded "$mqgbm_msm_module"; then
        mqgbm_msm_loaded=1
    fi

    case "$mqgbm_skip_gpu" in
        Y|y|1)
            if [ "$mqgbm_kgsl_loaded" -eq 1 ] &&
               [ -e "$mqgbm_kgsl_device" ]; then
                printf '%s\n' "kgsl"
                return 0
            fi
            ;;
        N|n|0)
            if [ "$mqgbm_msm_loaded" -eq 1 ] &&
               [ "$mqgbm_kgsl_loaded" -eq 0 ] &&
               [ ! -e "$mqgbm_kgsl_device" ]; then
                printf '%s\n' "msm"
                return 0
            fi
            ;;
    esac

    printf '%s\n' "unknown"
    return 1
}

# Return success when the current boot contains the known unsafe KGSL reload
# failure. The msm_kgsl module must not be unloaded/reloaded after this event.
mrv_qcom_gpu_unsafe_reload_detected() {
    if ! command -v dmesg >/dev/null 2>&1; then
        return 1
    fi

    dmesg 2>/dev/null |
        grep -Eq "kobject_add_internal failed for genpd:kgsl_cx_pd|cannot create duplicate filename.*/devices/genpd:kgsl_cx_pd"
}

# Validate the requested Qualcomm GPU boot ownership.
#
# Usage:
#   mrv_qcom_gpu_validate_boot_mode msm
#   mrv_qcom_gpu_validate_boot_mode kgsl
#
# Return values:
#   0 - requested boot mode is active
#   1 - state is contradictory or unavailable
#   2 - the requested boot policy is not active, so reboot is required
mrv_qcom_gpu_validate_boot_mode() {
    mqgvbm_expected="$1"
    mqgvbm_kgsl_module="${2:-msm_kgsl}"
    mqgvbm_kgsl_device="${3:-/dev/kgsl-3d0}"
    mqgvbm_msm_module="${4:-msm}"
    mqgvbm_mode="unknown"
    mqgvbm_skip_gpu="<unavailable>"

    if mrv_qcom_gpu_unsafe_reload_detected; then
        log_warn "Unsafe msm_kgsl reload failure detected in this boot"
        log_warn "A reboot is required before further GPU validation"
        return 2
    fi

    mqgvbm_mode="$(
        mrv_qcom_gpu_boot_mode \
            "$mqgvbm_kgsl_module" \
            "$mqgvbm_kgsl_device" \
            "$mqgvbm_msm_module" 2>/dev/null || true
    )"

    [ -n "$mqgvbm_mode" ] || mqgvbm_mode="unknown"

    if [ -r "/sys/module/$mqgvbm_msm_module/parameters/skip_gpu" ]; then
        mqgvbm_skip_gpu="$(
            cat "/sys/module/$mqgvbm_msm_module/parameters/skip_gpu" \
                2>/dev/null || true
        )"
        [ -n "$mqgvbm_skip_gpu" ] || mqgvbm_skip_gpu="<empty>"
    fi

    log_info "Detected Qualcomm GPU boot mode: $mqgvbm_mode"
    log_info "$mqgvbm_msm_module skip_gpu=$mqgvbm_skip_gpu"

    if mrv_module_loaded "$mqgvbm_kgsl_module"; then
        log_info "$mqgvbm_kgsl_module loaded=yes"
    else
        log_info "$mqgvbm_kgsl_module loaded=no"
    fi

    if [ -e "$mqgvbm_kgsl_device" ]; then
        log_info "KGSL device present: $mqgvbm_kgsl_device"
    else
        log_info "KGSL device missing: $mqgvbm_kgsl_device"
    fi

    case "$mqgvbm_expected:$mqgvbm_mode" in
        msm:msm|kgsl:kgsl)
            return 0
            ;;
        msm:kgsl|kgsl:msm)
            return 2
            ;;
    esac

    # A newly installed GPU module can leave both drivers visible until the
    # next boot. The msm skip_gpu setting is authoritative for that transition:
    # it cannot be changed safely for the current boot, even when the remaining
    # runtime evidence is contradictory and the detected mode is "unknown".
    case "$mqgvbm_expected:$mqgvbm_skip_gpu" in
        kgsl:N|kgsl:n|kgsl:0|msm:Y|msm:y|msm:1)
            return 2
            ;;
    esac

    return 1
}

# Remove stale KGSL boot policy after kgsl-dkms has been removed and rebuild
# the boot metadata that can retain msm skip_gpu=1 or msm_kgsl.
#
# Arguments:
#   $1 - KGSL package name, default kgsl-dkms
#   $2 - force refresh: 1 when the package set changed, otherwise 0
#
# Return values:
#   0 - no boot artifacts changed
#   1 - cleanup failed
#   2 - boot artifacts changed/refreshed; reboot is required
mrv_qcom_gpu_cleanup_kgsl_boot_artifacts() {
    mqgc_kernel="${1:-$(uname -r)}"
    mqgc_changed=0
    mqgc_modules_file="${MRV_QCOM_GPU_INITRAMFS_MODULES_FILE:-/etc/initramfs-tools/modules}"
 
    # Do not remove boot configuration while the KGSL package is installed.
    if command -v dpkg-query >/dev/null 2>&1; then
        if dpkg-query -W \
            -f='${db:Status-Abbrev}' \
            kgsl-dkms 2>/dev/null |
            grep -q '^ii'; then
            log_info "kgsl-dkms is still installed; KGSL boot artifacts are retained"
            return 1
        fi
    elif command -v rpm >/dev/null 2>&1; then
        if rpm -q kgsl-dkms >/dev/null 2>&1; then
            log_info "kgsl-dkms is still installed; KGSL boot artifacts are retained"
            return 1
        fi
    fi
 
    # Remove only known KGSL-specific configuration files.
    for mqgc_path in \
        /etc/modprobe.d/kgsl-dkms.conf \
        /usr/lib/modprobe.d/kgsl-dkms.conf \
        /lib/modprobe.d/kgsl-dkms.conf \
        /etc/modules-load.d/kgsl-dkms.conf \
        /usr/lib/modules-load.d/kgsl-dkms.conf \
        /lib/modules-load.d/kgsl-dkms.conf \
        /etc/modules-load.d/msm_kgsl.conf \
        /usr/lib/modules-load.d/msm_kgsl.conf \
        /lib/modules-load.d/msm_kgsl.conf \
        /etc/initramfs-tools/hooks/kgsl \
        /etc/initramfs-tools/hooks/kgsl-dkms \
        /etc/initramfs-tools/hooks/msm_kgsl \
        /usr/share/initramfs-tools/hooks/kgsl \
        /usr/share/initramfs-tools/hooks/kgsl-dkms \
        /usr/share/initramfs-tools/hooks/msm_kgsl
    do
        if [ -e "$mqgc_path" ] || [ -L "$mqgc_path" ]; then
            log_info "Removing stale KGSL boot artifact: $mqgc_path"
 
            if ! rm -f "$mqgc_path"; then
                log_error "Failed to remove KGSL boot artifact: $mqgc_path"
                return 2
            fi
 
            mqgc_changed=1
        fi
    done
 
    # Remove only an active msm_kgsl entry from initramfs-tools/modules.
    # Preserve all unrelated module entries and comments.
    if [ -f "$mqgc_modules_file" ] &&
       grep -Eq '^[[:space:]]*msm_kgsl([[:space:]]|$)' \
           "$mqgc_modules_file" 2>/dev/null; then
        mqgc_tmp="${mqgc_modules_file}.tmp.$$"
 
        log_info "Removing msm_kgsl from $mqgc_modules_file"
 
        if ! awk '$1 != "msm_kgsl"' \
            "$mqgc_modules_file" >"$mqgc_tmp"; then
            rm -f "$mqgc_tmp"
            log_error "Failed to filter $mqgc_modules_file"
            return 2
        fi
 
        if ! cat "$mqgc_tmp" >"$mqgc_modules_file"; then
            rm -f "$mqgc_tmp"
            log_error "Failed to update $mqgc_modules_file"
            return 2
        fi
 
        rm -f "$mqgc_tmp"
        mqgc_changed=1
    fi
 
    # No files were modified. Do not rebuild initramfs and do not request
    # another reboot.
    if [ "$mqgc_changed" -eq 0 ]; then
        log_pass "No stale KGSL boot artifacts found"
        return 1
    fi
 
    if command -v depmod >/dev/null 2>&1; then
        log_info "Refreshing module dependency metadata"
 
        if ! depmod -a "$mqgc_kernel"; then
            log_error "Failed to refresh module metadata for $mqgc_kernel"
            return 2
        fi
    fi
 
    if command -v update-initramfs >/dev/null 2>&1; then
        log_info "Refreshing initramfs for kernel $mqgc_kernel"
 
        if ! update-initramfs -u -k "$mqgc_kernel"; then
            log_error "Failed to refresh initramfs for $mqgc_kernel"
            return 2
        fi
    elif command -v dracut >/dev/null 2>&1; then
        mqgc_initramfs="/boot/initramfs-${mqgc_kernel}.img"
        log_info "Refreshing initramfs for kernel $mqgc_kernel"
 
        if ! dracut -f "$mqgc_initramfs" "$mqgc_kernel"; then
            log_error "Failed to refresh initramfs for $mqgc_kernel"
            return 2
        fi
    else
        log_warn "No initramfs update utility found"
    fi
 
    log_pass "Stale KGSL boot artifacts were removed"
    return 0
}
