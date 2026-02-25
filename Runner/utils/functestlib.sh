#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# --- Logging helpers ---
log() {
    level=$1
    shift
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}
log_info()  { log "INFO"  "$@"; }
log_pass()  { log "PASS"  "$@"; }
log_fail()  { log "FAIL"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_skip()  { log "SKIP"  "$@"; }
log_warn()  { log "WARN"  "$@"; }

# --- Kernel Log Collection ---
get_kernel_log() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -k -b
    elif command -v dmesg >/dev/null 2>&1; then
        dmesg
    elif [ -f /var/log/kern.log ]; then
        cat /var/log/kern.log
    else
        log_warn "No kernel log source found"
        return 1
    fi
}

# Locate a kernel module (.ko) file by name
# Tries to find it under current kernel version first, then all module trees
find_kernel_module() {
    module_name="$1"
    kver=$(uname -r)

    # Attempt to find module under the currently running kernel
    module_path=$(find "/lib/modules/$kver" -name "${module_name}.ko" 2>/dev/null | head -n 1)

    # If not found, search all available module directories
    if [ -z "$module_path" ]; then
        log_warn "Module not found under /lib/modules/$kver, falling back to full search in /lib/modules/"
        module_path=$(find /lib/modules/ -name "${module_name}.ko" 2>/dev/null | head -n 1)

        # Warn if found outside current kernel version
        if [ -n "$module_path" ]; then
            found_version=$(echo "$module_path" | cut -d'/' -f4)
            if [ "$found_version" != "$kver" ]; then
                log_warn "Found ${module_name}.ko under $found_version, not under current kernel ($kver)"
            fi
        fi
    fi
    echo "$module_path"
}

# Check if a kernel module is currently loaded
is_module_loaded() {
    module_name="$1"
    /sbin/lsmod | awk '{print $1}' | grep -q "^${module_name}$"
}

# load_kernel_module <path-to-ko> [params...]
# 1) If already loaded, no-op
# 2) Try insmod <ko> [params]
# 3) If that fails, try modprobe <modname> [params]
load_kernel_module() {
    module_path="$1"; shift
    params="$*"
    module_name=$(basename "$module_path" .ko)

    if is_module_loaded "$module_name"; then
        log_info "Module $module_name is already loaded"
        return 0
    fi

    if [ ! -f "$module_path" ]; then
        log_error "Module file not found: $module_path"
        # still try modprobe if it exists in modules directory
    else
        log_info "Loading module via insmod: $module_path $params"
        if /sbin/insmod "$module_path" "$params" 2>insmod_err.log; then
            log_info "Module $module_name loaded successfully via insmod"
            return 0
        else
            log_warn "insmod failed: $(cat insmod_err.log)"
        fi
    fi

    # fallback to modprobe
    log_info "Falling back to modprobe $module_name $params"
    if /sbin/modprobe "$module_name" "$params" 2>modprobe_err.log; then
        log_info "Module $module_name loaded successfully via modprobe"
        return 0
    else
        log_error "modprobe failed: $(cat modprobe_err.log)"
        return 1
    fi
}

# Remove a kernel module by name with optional forced removal
unload_kernel_module() {
    module_name="$1"
    force="$2"

    if ! is_module_loaded "$module_name"; then
        log_info "Module $module_name is not loaded, skipping unload"
        return 0
    fi

    log_info "Attempting to remove module: $module_name"
    if /sbin/rmmod "$module_name" 2>rmmod_err.log; then
        log_info "Module $module_name removed via rmmod"
        return 0
    fi

    log_warn "rmmod failed: $(cat rmmod_err.log)"
    log_info "Trying modprobe -r as fallback"
    if /sbin/modprobe -r "$module_name" 2>modprobe_err.log; then
        log_info "Module $module_name removed via modprobe"
        return 0
    fi

    log_warn "modprobe -r failed: $(cat modprobe_err.log)"

    if [ "$force" = "true" ]; then
        log_warn "Trying forced rmmod: $module_name"
        if /sbin/rmmod -f "$module_name" 2>>rmmod_err.log; then
            log_info "Module $module_name force removed"
            return 0
        else
            log_error "Forced rmmod failed: $(cat rmmod_err.log)"
            return 1
        fi
    fi

    log_error "Unable to unload module: $module_name"
    return 1
}

# --- Dependency check ---
check_dependencies() {
    # Support both:
    # check_dependencies date awk sed
    # check_dependencies "$deps" where deps="date awk sed"
    if [ "$#" -eq 1 ]; then
        # Split the single string into args
        # shellcheck disable=SC2086
        set -- $1
    fi

    missing=0
    missing_cmds=""

    for cmd in "$@"; do
        [ -n "$cmd" ] || continue
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_warn "Required command '$cmd' not found in PATH."
            missing=1
            missing_cmds="$missing_cmds $cmd"
        fi
    done

    if [ "$missing" -ne 0 ]; then
        testname="${TESTNAME:-UnknownTest}"
        log_skip "$testname SKIP missing dependencies$missing_cmds"
        if [ -n "${TESTNAME:-}" ]; then
            echo "$TESTNAME SKIP" > "./$TESTNAME.res" 2>/dev/null || true
        fi

        # Default: exit like today. Allow opt-out for callers that want a return code.
        if [ "${CHECK_DEPS_NO_EXIT:-0}" = "1" ]; then
            return 1
        fi
        exit 0
    fi

    return 0
}

# --- Test case directory lookup ---
find_test_case_by_name() {
    test_name=$1
    base_dir="${__RUNNER_SUITES_DIR:-$ROOT_DIR/suites}"
    # Only search under the SUITES directory!
    testpath=$(find "$base_dir" -type d -iname "$test_name" -print -quit 2>/dev/null)
    echo "$testpath"
}

find_test_case_bin_by_name() {
    test_name=$1
    base_dir="${__RUNNER_UTILS_BIN_DIR:-$ROOT_DIR/common}"
    find "$base_dir" -type f -iname "$test_name" -print -quit 2>/dev/null
}

find_test_case_script_by_name() {
    test_name=$1
    base_dir="${__RUNNER_UTILS_BIN_DIR:-$ROOT_DIR/common}"
    find "$base_dir" -type d -iname "$test_name" -print -quit 2>/dev/null
}

# Check each given kernel config is set to y/m in /proc/config.gz, logs result, returns 0/1.
check_kernel_config() {
    cfgs=$1
    for config_key in $cfgs; do
        if command -v zgrep >/dev/null 2>&1; then
            if zgrep -qE "^${config_key}=(y|m)" /proc/config.gz 2>/dev/null; then
                log_pass "Kernel config $config_key is enabled"
            else
                log_fail "Kernel config $config_key is missing or not enabled"
                return 1
            fi
        else
            # Fallback if zgrep is unavailable
            if gzip -dc /proc/config.gz 2>/dev/null | grep -qE "^${config_key}=(y|m)"; then
                log_pass "Kernel config $config_key is enabled"
            else
                log_fail "Kernel config $config_key is missing or not enabled"
                return 1
            fi
        fi
    done
    return 0
}

check_dt_nodes() {
    node_paths="$1"
    log_info "$node_paths"
    found=false
    for node in $node_paths; do
        log_info "$node"
        if [ -d "$node" ] || [ -f "$node" ]; then
            log_pass "Device tree node exists: $node"
            found=true
        fi
    done
 
    if [ "$found" = true ]; then
        return 0
    else
        log_fail "Device tree node(s) missing: $node_paths"
        return 1
    fi
}

check_driver_loaded() {
    drivers="$1"
    for driver in $drivers; do
        if [ -z "$driver" ]; then
            log_fail "No driver/module name provided to check_driver_loaded"
            return 1
        fi
        if grep -qw "$driver" /proc/modules || lsmod | awk '{print $1}' | grep -qw "$driver"; then
            log_pass "Driver/module '$driver' is loaded"
            return 0
        else
            log_fail "Driver/module '$driver' is not loaded"
            return 1
        fi
    done
}

# --- Optional: POSIX-safe repo root detector ---
detect_runner_root() {
    path=$1
    while [ "$path" != "/" ]; do
        if [ -d "$path/suites" ]; then
            echo "$path"
            return
        fi
        path=$(dirname "$path")
    done
    echo ""
}

# ----------------------------
# Additional Utility Functions
# ----------------------------
# Function is to check for network connectivity status
check_network_status() {
    echo "[INFO] Checking network connectivity..."
 
    # Prefer the egress/source IP chosen by the routing table (most accurate).
    ip_addr=$(ip -4 route get 1.1.1.1 2>/dev/null \
              | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
 
    # Fallback: first global IPv4 on any UP interface (works even without a default route).
    if [ -z "$ip_addr" ]; then
        ip_addr=$(ip -o -4 addr show scope global up 2>/dev/null \
                  | awk 'NR==1{split($4,a,"/"); print a[1]}')
    fi
 
    if [ -n "$ip_addr" ]; then
        echo "[PASS] Network is active. IP address: $ip_addr"
 
        # Quick reachability probe (single ICMP). BusyBox-compatible flags.
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "[PASS] Internet is reachable."
            return 0
        else
            echo "[WARN] Network active but no internet access."
            return 2
        fi
    else
        echo "[FAIL] No active network interface found."
        return 1
    fi
}

# --- Make sure system time is sane (TLS needs a sane clock) ---
ensure_reasonable_clock() {
    now="$(date +%s 2>/dev/null || echo 0)"
    cutoff="$(date -d '2020-01-01 UTC' +%s 2>/dev/null || echo 1577836800)"
    [ -z "$cutoff" ] && cutoff=1577836800
 
    [ "$now" -ge "$cutoff" ] 2>/dev/null && return 0
 
    log_warn "System clock looks invalid (epoch=$now). Trying local time sources (no network)..."
 
    # Optional diagnostics file (caller may set this, e.g. CLOCK_DIAG_FILE="$OUT_DIR/clock_diag.txt")
    diag_file="${CLOCK_DIAG_FILE:-}"
 
    # ---- Diagnostics (only when invalid clock) ----
    if [ -n "$diag_file" ]; then
        {
            echo "==== CLOCK DIAGNOSTICS ===="
            echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
            echo "epoch_now=$now cutoff=$cutoff"
            echo
        } >>"$diag_file" 2>/dev/null || true
    fi
 
    # Log minimal summaries to stdout; write full outputs to diag file.
    # date summary
    date_out="$(date 2>&1 || true)"
    if [ -n "$diag_file" ]; then
        {
            echo "---- date ----"
            echo "$date_out"
            echo
        } >>"$diag_file" 2>/dev/null || true
    fi
    log_info "date: $(printf '%s' "$date_out" | head -n 1)"
 
    # timedatectl summaries + full dump
    if command -v timedatectl >/dev/null 2>&1; then
        td_status="$(timedatectl status 2>&1 || true)"
        if [ -n "$diag_file" ]; then
            {
                echo "---- timedatectl status ----"
                echo "$td_status"
                echo
            } >>"$diag_file" 2>/dev/null || true
        fi
 
        # minimal, stable-ish summaries
        td_local="$(printf '%s\n' "$td_status" | sed -n 's/^[[:space:]]*Local time:[[:space:]]*//p' | head -n 1)"
        td_sync="$(printf '%s\n' "$td_status" | sed -n 's/^[[:space:]]*System clock synchronized:[[:space:]]*//p' | head -n 1)"
        td_ntp="$(printf '%s\n' "$td_status" | sed -n 's/^[[:space:]]*NTP service:[[:space:]]*//p' | head -n 1)"
        td_rtc="$(printf '%s\n' "$td_status" | sed -n 's/^[[:space:]]*RTC time:[[:space:]]*//p' | head -n 1)"
 
        [ -n "$td_local" ] && log_info "timedatectl: Local time: $td_local"
        [ -n "$td_rtc" ] && log_info "timedatectl: RTC time: $td_rtc"
        [ -n "$td_sync" ] && log_info "timedatectl: System clock synchronized: $td_sync"
        [ -n "$td_ntp" ] && log_info "timedatectl: NTP service: $td_ntp"
 
        td_show="$(timedatectl show-timesync --all 2>&1 || true)"
        if [ -n "$diag_file" ]; then
            {
                echo "---- timedatectl show-timesync --all ----"
                echo "$td_show"
                echo
            } >>"$diag_file" 2>/dev/null || true
        fi
 
        td_server="$(printf '%s\n' "$td_show" | sed -n 's/^ServerName=//p' | head -n 1)"
        td_addr="$(printf '%s\n' "$td_show" | sed -n 's/^ServerAddress=//p' | head -n 1)"
        td_sysntp="$(printf '%s\n' "$td_show" | sed -n 's/^SystemNTPServers=//p' | head -n 1)"
        td_fallback="$(printf '%s\n' "$td_show" | sed -n 's/^FallbackNTPServers=//p' | head -n 1)"
 
        if [ -n "$td_server" ] || [ -n "$td_addr" ]; then
            log_info "timesync: server=${td_server:-NA} addr=${td_addr:-NA}"
        fi
        if [ -n "$td_sysntp" ]; then
            # Keep it short
            short_sysntp="$(printf '%s' "$td_sysntp" | awk '{print $1" "$2" "$3" "$4}')"
            log_info "timesync: SystemNTPServers: ${short_sysntp:-NA}"
        elif [ -n "$td_fallback" ]; then
            short_fb="$(printf '%s' "$td_fallback" | awk '{print $1" "$2" "$3" "$4}')"
            log_info "timesync: FallbackNTPServers: ${short_fb:-NA}"
        fi
 
        td_ts="$(timedatectl timesync-status 2>&1 || true)"
        if [ -n "$diag_file" ]; then
            {
                echo "---- timedatectl timesync-status ----"
                echo "$td_ts"
                echo
            } >>"$diag_file" 2>/dev/null || true
        fi
 
        td_pkt="$(printf '%s\n' "$td_ts" | sed -n 's/^[[:space:]]*Packet count:[[:space:]]*//p' | head -n 1)"
        td_srvline="$(printf '%s\n' "$td_ts" | sed -n 's/^[[:space:]]*Server:[[:space:]]*//p' | head -n 1)"
        [ -n "$td_srvline" ] && log_info "timesync-status: Server: $td_srvline"
        [ -n "$td_pkt" ] && log_info "timesync-status: Packet count: $td_pkt"
    else
        log_info "timedatectl: not available"
        if [ -n "$diag_file" ]; then
            echo "timedatectl: not available" >>"$diag_file" 2>/dev/null || true
        fi
    fi
 
    # systemctl status summaries + full dump
    if command -v systemctl >/dev/null 2>&1; then
        sdts="$(systemctl status systemd-timesyncd --no-pager --full 2>&1 || true)"
        if [ -n "$diag_file" ]; then
            {
                echo "---- systemctl status systemd-timesyncd ----"
                echo "$sdts"
                echo
            } >>"$diag_file" 2>/dev/null || true
        fi
 
        sd_active="$(printf '%s\n' "$sdts" | sed -n 's/^[[:space:]]*Active:[[:space:]]*//p' | head -n 1)"
        sd_pid="$(printf '%s\n' "$sdts" | sed -n 's/^[[:space:]]*Main PID:[[:space:]]*//p' | head -n 1)"
        [ -n "$sd_active" ] && log_info "systemd-timesyncd: Active: $sd_active"
        [ -n "$sd_pid" ] && log_info "systemd-timesyncd: Main PID: $sd_pid"
    else
        log_info "systemctl: not available"
        if [ -n "$diag_file" ]; then
            echo "systemctl: not available" >>"$diag_file" 2>/dev/null || true
        fi
    fi
 
    # 1) Try RTC (if it is sane)
    if command -v hwclock >/dev/null 2>&1 && [ -e /dev/rtc0 ]; then
        hwclock -s 2>/dev/null || true
        now="$(date +%s 2>/dev/null || echo 0)"
        if [ "$now" -ge "$cutoff" ] 2>/dev/null; then
            log_pass "Clock restored from RTC."
            return 0
        fi
 
        if [ -r /sys/class/rtc/rtc0/since_epoch ]; then
            rtc_epoch="$(tr -cd 0-9 < /sys/class/rtc/rtc0/since_epoch 2>/dev/null)"
            if [ -n "$rtc_epoch" ]; then
                log_info "rtc0: since_epoch=$rtc_epoch"
                if [ -n "$diag_file" ]; then
                    echo "rtc0: since_epoch=$rtc_epoch" >>"$diag_file" 2>/dev/null || true
                fi
            fi
            if [ -n "$rtc_epoch" ] && [ "$rtc_epoch" -ge "$cutoff" ] 2>/dev/null; then
                if date -d "@$rtc_epoch" >/dev/null 2>&1; then
                    date -s "@$rtc_epoch" >/dev/null 2>&1 || true
                fi
                now="$(date +%s 2>/dev/null || echo 0)"
                if [ "$now" -ge "$cutoff" ] 2>/dev/null; then
                    log_pass "Clock restored from rtc0 since_epoch."
                    return 0
                fi
            fi
        fi
    else
        log_info "RTC: hwclock or /dev/rtc0 not available"
        if [ -n "$diag_file" ]; then
            echo "RTC: hwclock or /dev/rtc0 not available" >>"$diag_file" 2>/dev/null || true
        fi
    fi
 
    # 2) Try kernel build timestamp from /proc/version or uname -v
    kb="$(uname -v 2>/dev/null || cat /proc/version 2>/dev/null || true)"
    if [ -n "$diag_file" ]; then
        {
            echo "---- kernel version string ----"
            echo "$kb"
            echo
        } >>"$diag_file" 2>/dev/null || true
    fi
 
    kb_date="$(printf '%s\n' "$kb" | sed -n \
        's/.*\([A-Z][a-z][a-z] [A-Z][a-z][a-z] [ 0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [A-Z][A-Za-z0-9+:-]* [0-9][0-9][0-9][0-9]\).*/\1/p' \
        | head -n 1)"
 
    if [ -n "$kb_date" ]; then
        log_info "kernel-build-time: parsed='$kb_date'"
        kb_epoch="$(date -d "$kb_date" +%s 2>/dev/null || echo 0)"
        if [ "$kb_epoch" -ge "$cutoff" ] 2>/dev/null; then
            date -s "$kb_date" >/dev/null 2>&1 || true
            now="$(date +%s 2>/dev/null || echo 0)"
            if [ "$now" -ge "$cutoff" ] 2>/dev/null; then
                log_pass "Clock seeded from kernel build time: $kb_date"
                return 0
            fi
        fi
    else
        log_info "kernel-build-time: could not parse from uname -v / /proc/version"
    fi
 
    log_warn "Clock still invalid; continuing (timestamps may be epoch)."
    return 1
}

# If the tar file already exists,then function exit. Otherwise function to check the network connectivity and it will download tar from internet.
extract_tar_from_url() {
    url="$1"
    outdir="${LOG_DIR:-.}"
    mkdir -p "$outdir" 2>/dev/null || true
 
    case "$url" in
        /*)
            tarfile="$url"
            ;;
        file://*)
            tarfile="${url#file://}"
            ;;
        *)
            tarfile="$outdir/$(basename "$url")"
            ;;
    esac
    markfile="${tarfile}.extracted"
    skip_sentinel="${outdir}/.asset_fetch_skipped"
 
    # If a previous run already marked "assets unavailable", honor it and SKIP.
    if [ -f "$skip_sentinel" ]; then
        log_info "Previous run marked assets unavailable on this system (${skip_sentinel}); skipping download."
        return 2
    fi
 
    tar_already_extracted() {
        tf="$1"
        od="$2"
        if [ -f "${tf}.extracted" ]; then
            return 0
        fi
        tmp_list="${od}/.tar_ls.$$"
        if tar -tf "$tf" 2>/dev/null | head -n 20 > "$tmp_list"; then
            total=0
            present=0
            while IFS= read -r ent; do
                [ -z "$ent" ] && continue
                total=$((total + 1))
                ent="${ent%/}"
                if [ -e "$od/$ent" ] || [ -e "$od/$(basename "$ent")" ]; then
                    present=$((present + 1))
                fi
            done < "$tmp_list"
            rm -f "$tmp_list" 2>/dev/null || true
            if [ "$present" -ge 3 ]; then
                return 0
            fi
            if [ "$total" -gt 0 ] && [ $((present * 100 / total)) -ge 50 ]; then
                return 0
            fi
        fi
        return 1
    }
 
    if command -v check_tar_file >/dev/null 2>&1; then
        check_tar_file "$url"
        status=$?
    else
        if [ -f "$tarfile" ]; then
            if tar_already_extracted "$tarfile" "$outdir"; then
                status=0
            else
                status=2
            fi
        else
            status=1
        fi
    fi
 
    ensure_reasonable_clock || {
        log_warn "Proceeding in limited-network mode."
        limited_net=1
    }
 
    is_busybox_wget() {
        if command -v wget >/dev/null 2>&1; then
            if wget --help 2>&1 | head -n 1 | grep -qi busybox; then
                return 0
            fi
        fi
        return 1
    }
 
    tls_capable_fetcher_available() {
        scheme_https=0
        case "$url" in
            https://*)
                scheme_https=1
                ;;
        esac
        if [ "$scheme_https" -eq 0 ]; then
            return 0
        fi
        if command -v curl >/dev/null 2>&1; then
            if curl -V 2>/dev/null | grep -qiE 'ssl|tls'; then
                return 0
            fi
        fi
        if command -v aria2c >/dev/null 2>&1; then
            return 0
        fi
        if command -v wget >/dev/null 2>&1; then
            if ! is_busybox_wget; then
                return 0
            fi
            if command -v openssl >/dev/null 2>&1; then
                return 0
            fi
        fi
        return 1
    }
 
    try_download() {
        src="$1"
        dst="$2"
        part="${dst}.part.$$"
        ca=""
 
        for cand in \
            /etc/ssl/certs/ca-certificates.crt \
            /etc/ssl/cert.pem \
            /system/etc/security/cacerts/ca-certificates.crt
        do
            if [ -r "$cand" ]; then
                ca="$cand"
                break
            fi
        done
 
        if command -v curl >/dev/null 2>&1; then
            if [ -n "$ca" ]; then
                curl -4 -L --fail --retry 3 --retry-delay 2 --connect-timeout 10 \
                     -o "$part" --cacert "$ca" "$src"
            else
                curl -4 -L --fail --retry 3 --retry-delay 2 --connect-timeout 10 \
                     -o "$part" "$src"
            fi
            rc=$?
            if [ $rc -eq 0 ]; then
                mv -f "$part" "$dst" 2>/dev/null || true
                return 0
            fi
            rm -f "$part" 2>/dev/null || true
            case "$rc" in
                60|35|22)
                    return 60
                    ;;
            esac
        fi
 
        if command -v aria2c >/dev/null 2>&1; then
            aria2c -x4 -s4 -m3 --connect-timeout=10 \
                   -o "$(basename "$part")" --dir="$(dirname "$part")" "$src"
            rc=$?
            if [ $rc -eq 0 ]; then
                mv -f "$part" "$dst" 2>/dev/null || true
                return 0
            fi
            rm -f "$part" 2>/dev/null || true
        fi
 
        if command -v wget >/dev/null 2>&1; then
            if is_busybox_wget; then
                wget -O "$part" -T 15 "$src"
                rc=$?
                if [ $rc -ne 0 ]; then
                    log_warn "BusyBox wget failed (rc=$rc); final attempt with --no-check-certificate."
                    wget -O "$part" -T 15 --no-check-certificate "$src"
                    rc=$?
                fi
                if [ $rc -eq 0 ]; then
                    mv -f "$part" "$dst" 2>/dev/null || true
                    return 0
                fi
                rm -f "$part" 2>/dev/null || true
                return 60
            else
                if [ -n "$ca" ]; then
                    wget -4 --timeout=15 --tries=3 --ca-certificate="$ca" -O "$part" "$src"
                    rc=$?
                else
                    wget -4 --timeout=15 --tries=3 -O "$part" "$src"
                    rc=$?
                fi
                if [ $rc -ne 0 ]; then
                    log_warn "wget failed (rc=$rc); final attempt with --no-check-certificate."
                    wget -4 --timeout=15 --tries=1 --no-check-certificate -O "$part" "$src"
                    rc=$?
                fi
                if [ $rc -eq 0 ]; then
                    mv -f "$part" "$dst" 2>/dev/null || true
                    return 0
                fi
                rm -f "$part" 2>/dev/null || true
                if [ $rc -eq 5 ]; then
                    return 60
                fi
                return $rc
            fi
        fi
 
        return 127
    }
 
    if [ "$status" -eq 0 ]; then
        log_info "Already extracted. Skipping download."
        return 0
    fi
 
    if [ "$status" -eq 2 ]; then
        log_info "File exists and is valid, but not yet extracted. Proceeding to extract."
    else
        case "$url" in
            /*|file://*)
                if [ ! -f "$tarfile" ]; then
                    log_fail "Local tar file not found: $tarfile"
                    return 1
                fi
                ;;
            *)
                if [ ! -f "$tarfile" ] || [ ! -s "$tarfile" ]; then
                    prestage_dirs=""
                    if [ -n "${ASSET_DIR:-}" ]; then prestage_dirs="$prestage_dirs $ASSET_DIR"; fi
                    if [ -n "${VIDEO_ASSET_DIR:-}" ]; then prestage_dirs="$prestage_dirs $VIDEO_ASSET_DIR"; fi
                    if [ -n "${AUDIO_ASSET_DIR:-}" ]; then prestage_dirs="$prestage_dirs $AUDIO_ASSET_DIR"; fi
                    prestage_dirs="$prestage_dirs . $outdir ${ROOT_DIR:-} ${ROOT_DIR:-}/cache /var/Runner /var/Runner/cache"
 
                    for d in $prestage_dirs; do
                        if [ -d "$d" ] && [ -f "$d/$(basename "$tarfile")" ]; then
                            log_info "Using pre-staged tarball: $d/$(basename "$tarfile")"
                            cp -f "$d/$(basename "$tarfile")" "$tarfile" 2>/dev/null || true
                            break
                        fi
                    done
 
                    if [ ! -s "$tarfile" ]; then
                        for top in /mnt /media; do
                            if [ -d "$top" ]; then
                                for d in "$top"/*; do
                                    if [ -d "$d" ] && [ -f "$d/$(basename "$tarfile")" ]; then
                                        log_info "Using pre-staged tarball: $d/$(basename "$tarfile")"
                                        cp -f "$d/$(basename "$tarfile")" "$tarfile" 2>/dev/null || true
                                        break 2
                                    fi
                                done
                            fi
                        done
                    fi
                fi
 
                if [ ! -s "$tarfile" ]; then
                    if [ -n "$limited_net" ]; then
                        log_warn "Limited network, cannot fetch media bundle. Marking SKIP for callers."
                        : > "$skip_sentinel" 2>/dev/null || true
                        return 2
                    fi
 
                    if ! tls_capable_fetcher_available; then
                        log_warn "No TLS-capable downloader available on this minimal build, cannot fetch: $url"
                        log_warn "Pre-stage $(basename "$url") locally or use a file:// URL."
                        : > "$skip_sentinel" 2>/dev/null || true
                        return 2
                    fi
 
                    log_info "Downloading $url -> $tarfile"
                    if ! try_download "$url" "$tarfile"; then
                        rc=$?
                        if [ $rc -eq 60 ]; then
                            log_warn "TLS/handshake problem while downloading (cert/clock/firewall or minimal wget). Marking SKIP."
                            : > "$skip_sentinel" 2>/dev/null || true
                            return 2
                        fi
                        log_fail "Failed to download $(basename "$url")"
                        return 1
                    fi
                fi
                ;;
        esac
    fi
 
    log_info "Extracting $(basename "$tarfile")..."
    if tar -xvf "$tarfile"; then
        : > "$markfile" 2>/dev/null || true
    # Clear the minimal/offline sentinel only if it exists (SC2015-safe)
        if [ -f "$skip_sentinel" ]; then
            rm -f "$skip_sentinel" 2>/dev/null || true
        fi
 
        first_entry="$(tar -tf "$tarfile" 2>/dev/null | head -n 1 | sed 's#/$##')"
        if [ -n "$first_entry" ]; then
            if [ -e "$first_entry" ] || [ -e "$outdir/$first_entry" ]; then
                log_pass "Files extracted successfully ($(basename "$first_entry") present)."
                return 0
            fi
        fi
        log_warn "Extraction finished but couldn't verify entries. Assuming success."
        return 0
    fi
 
    log_fail "Failed to extract $(basename "$tarfile")"
    return 1
}


# Function to check if a tar file exists
check_tar_file() {
    url="$1"
    outdir="${LOG_DIR:-.}"
    mkdir -p "$outdir" 2>/dev/null || true
 
    case "$url" in
        /*)       tarfile="$url" ;;
        file://*) tarfile="${url#file://}" ;;
        *)        tarfile="$outdir/$(basename "$url")" ;;
    esac
    markfile="${tarfile}.extracted"
 
    # 1) Existence & basic validity
    if [ ! -f "$tarfile" ]; then
        log_info "File $(basename "$tarfile") does not exist in $outdir."
        return 1
    fi
    if [ ! -s "$tarfile" ]; then
        log_warn "File $(basename "$tarfile") exists but is empty."
        return 1
    fi
    if ! tar -tf "$tarfile" >/dev/null 2>&1; then
        log_warn "File $(basename "$tarfile") is not a valid tar archive."
        return 1
    fi
 
    # 2) Already extracted? (marker first)
    if [ -f "$markfile" ]; then
        log_pass "$(basename "$tarfile") has already been extracted (marker present)."
        return 0
    fi
 
    # 3) Heuristic: check multiple entries from the tar exist on disk
    tmp_list="${outdir}/.tar_ls.$$"
    if tar -tf "$tarfile" 2>/dev/null | head -n 20 >"$tmp_list"; then
        total=0; present=0
        while IFS= read -r ent; do
            [ -z "$ent" ] && continue
            total=$((total + 1))
            ent="${ent%/}"
            # check exact relative path and also basename (covers archives with a top-level dir)
            if [ -e "$outdir/$ent" ] || [ -e "$outdir/$(basename "$ent")" ]; then
                present=$((present + 1))
            fi
        done < "$tmp_list"
        rm -f "$tmp_list" 2>/dev/null || true
 
        # If we find a reasonable portion of entries, assume it's extracted
        if [ "$present" -ge 3 ] || { [ "$total" -gt 0 ] && [ $((present * 100 / total)) -ge 50 ]; }; then
            log_pass "$(basename "$tarfile") already extracted ($present/$total entries found)."
            return 0
        fi
    fi
 
    # 4) Exists and valid, but not yet extracted
    log_info "$(basename "$tarfile") exists and is valid, but not yet extracted."
    return 2
}

# Return space-separated PIDs for 'weston' (BusyBox friendly).
weston_pids() {
    pids=""
    if command -v pgrep >/dev/null 2>&1; then
        pids="$(pgrep -x weston 2>/dev/null || true)"
    fi
    if [ -z "$pids" ]; then
        pids="$(ps -eo pid,comm 2>/dev/null | awk '$2=="weston"{print $1}')"
    fi
    echo "$pids"
}

# Is Weston running
weston_is_running() {
    [ -n "$(weston_pids)" ]
}

# Stop all Weston processes, also stop socket activation and instances
weston_stop() {
    if command -v systemctl >/dev/null 2>&1; then
        log_info "Stopping Weston, stopping weston.socket to prevent auto restart"
        systemctl stop weston.socket >/dev/null 2>&1 || true

        log_info "Stopping Weston, stopping weston.service"
        systemctl stop weston.service >/dev/null 2>&1 || true

        log_info "Stopping Weston, stopping weston@root.service if present"
        systemctl stop weston@root.service >/dev/null 2>&1 || true

        # Stop any active weston@*.service instances
        units="$(systemctl list-units 'weston@*.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}')"
        if [ -n "$units" ]; then
            for u in $units; do
                log_info "Stopping Weston, stopping instance unit $u"
                systemctl stop "$u" >/dev/null 2>&1 || true
            done
        fi
    fi

    if ! weston_is_running; then
        log_info "Weston is not running."
        # Still cleanup stale sockets (prevents false positives elsewhere)
        weston_cleanup_stale_sockets
        return 0
    fi

    log_info "Stopping Weston..."

    # First try graceful
    if command -v pkill >/dev/null 2>&1; then
        log_info "Stopping Weston processes"
        pkill -TERM -x weston >/dev/null 2>&1 || true
    elif command -v killall >/dev/null 2>&1; then
        killall weston >/dev/null 2>&1 || true
    else
        # Last resort: kill by PID list
        for p in $(weston_pids); do
            kill "$p" >/dev/null 2>&1 || true
        done
    fi

    i=1
    while [ "$i" -le 10 ]; do
        log_info "Waiting for Weston to stop, attempt $i of 10"
        if ! weston_is_running; then
            weston_cleanup_stale_sockets
            log_info "Weston stopped successfully"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    log_warn "Weston still running after grace period, sending SIGKILL"

    if command -v pkill >/dev/null 2>&1; then
        pkill -KILL -x weston >/dev/null 2>&1 || true
    else
        for p in $(weston_pids); do
            kill -9 "$p" >/dev/null 2>&1 || true
        done
    fi

    i=1
    while [ "$i" -le 5 ]; do
        log_info "Waiting for Weston to stop after SIGKILL, attempt $i of 5"
        if ! weston_is_running; then
            weston_cleanup_stale_sockets
            log_info "Weston stopped successfully"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    log_error "Failed to stop Weston completely"
    # Still attempt cleanup to avoid future false positives
    weston_cleanup_stale_sockets
    return 1
}

# Start weston with correct env if not running
weston_start() {
    if weston_is_running; then
        log_info "Weston already running"
        return 0
    fi

    # If stale sockets exist from previous crash/kill, remove them first
    weston_cleanup_stale_sockets

    if command -v systemctl >/dev/null 2>&1; then
        log_info "Attempting to start Weston, enabling weston.socket if available"
        systemctl start weston.socket >/dev/null 2>&1 || true
        sleep 1

        log_info "Attempting to start Weston via weston.service"
        systemctl start weston.service >/dev/null 2>&1 || true
        sleep 1
        if weston_is_running; then
            log_info "Weston started via weston.service"
            return 0
        fi

        log_info "Attempting to start Weston via weston@root.service"
        systemctl start weston@root.service >/dev/null 2>&1 || true
        sleep 1
        if weston_is_running; then
            log_info "Weston started via weston@root.service"
            return 0
        fi

        # Try one enabled weston@ instance if any exists
        enabled_unit="$(systemctl list-unit-files 'weston@*.service' --no-legend --no-pager 2>/dev/null | awk '$2=="enabled"{print $1; exit}')"
        if [ -n "$enabled_unit" ]; then
            log_info "Attempting to start Weston via enabled instance $enabled_unit"
            systemctl start "$enabled_unit" >/dev/null 2>&1 || true
            sleep 1
            if weston_is_running; then
                log_info "Weston started via instance $enabled_unit"
                return 0
            fi
        fi

        log_warn "systemd start did not bring Weston up, trying direct spawn"
    fi

    # Minimal-friendly direct spawn
    ensure_xdg_runtime_dir

    if ! command -v weston >/dev/null 2>&1; then
        log_fail "weston binary not found in PATH"
        return 1
    fi

    log_info "Spawning Weston directly, log file is /tmp/weston.self.log"
    ( nohup weston --log=/tmp/weston.self.log >/dev/null 2>&1 & ) || true

    tries=0
    while [ "$tries" -lt 8 ]; do
        if weston_is_running; then
            log_info "Weston is now running, PID list is $(weston_pids)"
            return 0
        fi
        if [ -n "$(find_wayland_sockets 2>/dev/null | head -n 1)" ]; then
            log_info "Wayland socket appeared after spawn"
            return 0
        fi
        sleep 1
        tries=$((tries + 1))
    done

    if [ -f /tmp/weston.self.log ]; then
        log_warn "Weston spawn failed, last log lines follow"
        tail -n 20 /tmp/weston.self.log 2>/dev/null | sed 's/^/[weston.log] /' || true
    else
        log_warn "Weston spawn failed, no log file present"
    fi
    return 1
}

overlay_start_weston_drm() {
    # Pick the first matching EGL vendor JSON without using ls|head (ShellCheck SC2012)
    EGL_JSON=""
    for f in /usr/share/glvnd/egl_vendor.d/*EGL_adreno.json; do
        if [ -f "$f" ]; then
            EGL_JSON="$f"
            break
        fi
    done
 
    if [ -n "$EGL_JSON" ]; then
        export __EGL_VENDOR_LIBRARY_FILENAMES="$EGL_JSON"
        log_info "Overlay EGL: using vendor JSON: $EGL_JSON"
    fi
 
    RUNTIME_DIR="/dev/socket/weston"
    if ! mkdir -p "$RUNTIME_DIR"; then
        log_warn "Failed to create runtime dir $RUNTIME_DIR; falling back to /run/user/0"
        RUNTIME_DIR="/run/user/0"
        mkdir -p "$RUNTIME_DIR" || true
    fi
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
 
    XDG_RUNTIME_DIR="$RUNTIME_DIR"
    export XDG_RUNTIME_DIR
 
    # Do NOT force a specific WAYLAND_DISPLAY; let Weston decide.
    unset WAYLAND_DISPLAY
 
    log_dir=${1:-$PWD}
    WESTON_LOG="$log_dir/weston.log"
    log_info "Overlay Weston start: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR (WAYLAND_DISPLAY=<auto>)"
    log_info "Weston log: $WESTON_LOG"
 
    # Start Weston in the background; we intentionally do not track the PID
    # here to avoid killing it while clients are still using the socket.
    weston --continue-without-input --idle-time=0 --log="$WESTON_LOG" \
        >/dev/null 2>&1 &
 
    # Best-effort check: see if ANY wayland-* socket appears, but do not kill Weston.
    i=0
    sock_found=""
    while [ "$i" -lt 10 ]; do
        for candidate in "$XDG_RUNTIME_DIR"/wayland-*; do
            [ -S "$candidate" ] || continue
            sock_found="$candidate"
            break
        done
        [ -n "$sock_found" ] && break
        sleep 1
        i=$((i + 1))
    done
 
    if [ -n "$sock_found" ]; then
        log_info "Overlay Weston created Wayland socket at $sock_found"
        # Caller can discover/adopt env via discover_wayland_socket_anywhere + adopt_wayland_env_from_socket.
        return 0
    fi
 
    log_warn "Overlay Weston did not create a Wayland socket under $XDG_RUNTIME_DIR (see $WESTON_LOG)"
    return 1
}
# Choose a socket (or try to start), adopt env, and echo chosen path.
wayland_choose_or_start() {
    wayland_debug_snapshot "pre-choose"
    sock="$(wayland_pick_socket || true)"
    if [ -z "$sock" ]; then
        log_info "No Wayland socket found; attempting to start Weston…"
        weston_start || log_warn "weston_start() did not succeed."
        # Re-scan a few times
        n=0
        while [ $n -lt 5 ] && [ -z "$sock" ]; do
            sock="$(wayland_pick_socket || true)"
            [ -n "$sock" ] && break
            sleep 1
            n=$((n+1))
        done
    fi
    if [ -n "$sock" ]; then
        adopt_wayland_env_from_socket "$sock"
        wayland_debug_snapshot "post-choose"
        echo "$sock"
        return 0
    fi
    wayland_debug_snapshot "no-socket"
    return 1
}
# Ensure we have a writable XDG_RUNTIME_DIR for the current user.
# Prefers /run/user/<uid>, falls back to /tmp/xdg-runtime-<uid>.
ensure_xdg_runtime_dir() {
    uid="$(id -u 2>/dev/null || echo 0)"
    cand="/run/user/$uid"

    if [ ! -d "$cand" ]; then
        mkdir -p "$cand" 2>/dev/null || cand="/tmp/xdg-runtime-$uid"
    fi

    mkdir -p "$cand" 2>/dev/null || true
    chmod 700 "$cand" 2>/dev/null || true
    export XDG_RUNTIME_DIR="$cand"

    log_info "XDG_RUNTIME_DIR ensured: $XDG_RUNTIME_DIR"
}

# Choose newest socket (by mtime); logs candidates for debugging.
wayland_pick_socket() {
    best=""
    best_mtime=0

    log_info "Wayland sockets found (candidate list):"
    for s in $(find_wayland_sockets | sort -u); do
        mt="$(stat -c %Y "$s" 2>/dev/null || echo 0)"
        log_info "  - $s (mtime=$mt)"
        if [ "$mt" -gt "$best_mtime" ]; then
            best="$s"
            best_mtime="$mt"
        fi
    done

    if [ -n "$best" ]; then
        log_info "Picked Wayland socket (newest): $best"
        echo "$best"
        return 0
    fi
    return 1
}

# ---- Wayland/Weston helpers -----------------------
# Return first Wayland socket under a base dir (prints path or fails).
find_wayland_socket_in() {
    base="$1"
    [ -d "$base" ] || return 1
    for s in "$base"/wayland-*; do
        [ -S "$s" ] || continue
        printf '%s\n' "$s"
        return 0
    done
    return 1
}

# Best-effort discovery of a usable Wayland socket anywhere.
discover_wayland_socket_anywhere() {
    # Prefer an already-configured, valid env
    if [ -n "$XDG_RUNTIME_DIR" ] && [ -n "$WAYLAND_DISPLAY" ] &&
       [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
        printf '%s\n' "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
        return 0
    fi

    uid="$(id -u 2>/dev/null || echo 0)"
    bases=""

    # If caller set XDG_RUNTIME_DIR, keep it as highest priority
    if [ -n "$XDG_RUNTIME_DIR" ]; then
        bases="$bases $XDG_RUNTIME_DIR"
    fi

    # Common locations on Linux/Android
    bases="$bases /dev/socket/weston /run/user/$uid /tmp/wayland-$uid /dev/shm"

    for b in $bases; do
        [ -d "$b" ] || continue
        if s="$(find_wayland_socket_in "$b" 2>/dev/null)"; then
            [ -n "$s" ] || continue
            printf '%s\n' "$s"
            return 0
        fi
    done

    # Fallback: scan all /run/user/* (handles Weston running as a different UID,
    # e.g. weston user with UID 1000 while tests run as root).
    for d in /run/user/*; do
        [ -d "$d" ] || continue
        if s="$(find_wayland_socket_in "$d" 2>/dev/null)"; then
            [ -n "$s" ] || continue
            printf '%s\n' "$s"
            return 0
        fi
    done

    return 1
}

# Adopt env from a Wayland socket path like /run/user/0/wayland-0
# Sets XDG_RUNTIME_DIR and WAYLAND_DISPLAY. Returns 0 on success.
adopt_wayland_env_from_socket() {
    s="$1"
    if [ -z "$s" ] || [ ! -S "$s" ]; then
        log_warn "adopt_wayland_env_from_socket: invalid socket: ${s:-<empty>}"
        return 1
    fi

    dir="$(dirname "$s")"
    name="$(basename "$s")"

    if [ -z "$dir" ] || [ -z "$name" ]; then
        log_warn "adopt_wayland_env_from_socket: could not derive env from '$s'"
        return 1
    fi

    XDG_RUNTIME_DIR="$dir"
    WAYLAND_DISPLAY="$name"
    export XDG_RUNTIME_DIR WAYLAND_DISPLAY

    # Best-effort perms fix for minimal systems (ignore errors)
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

    log_info "Adopting Wayland environment from socket: $s"
    log_info "Adopted Wayland env: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    log_info "Reproduce with:"
    log_info " export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'"
    log_info " export WAYLAND_DISPLAY='$WAYLAND_DISPLAY'"
}

# Try to connect to Wayland. Returns 0 on OK.
wayland_can_connect() {
    if command -v weston-info >/dev/null 2>&1; then
        weston-info >/dev/null 2>&1
        return $?
    fi
    # fallback: quick client probe
    ( env -i XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" true ) >/dev/null 2>&1
    return $?
}

# Ensure a Weston socket exists; if not, stop+start Weston and adopt helper socket.
weston_pick_env_or_start() {
    ctx="${1:-weston_pick_env_or_start}"
    sock=""
 
    # Honor WESTON_LOG_DIR for any Weston logs that helpers might write
    log_dir="${WESTON_LOG_DIR:-/tmp}"
    log_info "$ctx: Weston logs (if any) will be under: $log_dir"
 
    # 0) If env already points to a valid socket, keep it.
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] \
       && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
        log_info "$ctx: Using existing Wayland env: $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
        return 0
    fi
 
    # 1) Try to discover any existing Wayland socket first.
    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        sock="$(discover_wayland_socket_anywhere 2>/dev/null | head -n 1)"
    elif command -v find_wayland_socket_in >/dev/null 2>&1; then
        uid="$(id -u 2>/dev/null || echo 0)"
        bases=""
        [ -n "${XDG_RUNTIME_DIR:-}" ] && bases="$bases $XDG_RUNTIME_DIR"
        bases="$bases /run/user/$uid /dev/socket/weston /tmp/wayland-$uid"
        for b in $bases; do
            [ -z "$b" ] && continue
            if s="$(find_wayland_socket_in "$b" 2>/dev/null || true)"; then
                if [ -n "$s" ]; then
                    sock="$s"
                    break
                fi
            fi
        done
    fi
 
    if [ -n "$sock" ]; then
        if adopt_wayland_env_from_socket "$sock"; then
            log_info "$ctx: Selected existing Wayland socket: $sock"
            return 0
        fi
        log_warn "$ctx: Failed to adopt env from existing socket: $sock"
        return 1
    fi
 
    # 2) No socket found → restart Weston and wait for a new one.
    if weston_is_running; then
        log_info "$ctx: Weston is running but no socket found; stopping..."
        weston_stop
        i=0
        while weston_is_running && [ "$i" -lt 5 ]; do
            i=$((i + 1))
            sleep 1
        done
    fi
 
    uid="$(id -u 2>/dev/null || echo 0)"
 
    # Ensure XDG_RUNTIME_DIR before starting Weston (manual mkdir, no external helpers).
    if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
        if mkdir -p "/run/user/$uid" 2>/dev/null; then
            chmod 700 "/run/user/$uid" 2>/dev/null || true
            XDG_RUNTIME_DIR="/run/user/$uid"
        elif mkdir -p "/dev/socket/weston" 2>/dev/null; then
            chmod 700 "/dev/socket/weston" 2>/dev/null || true
            XDG_RUNTIME_DIR="/dev/socket/weston"
        fi
        export XDG_RUNTIME_DIR
        log_info "$ctx: XDG_RUNTIME_DIR set to '$XDG_RUNTIME_DIR' before starting Weston"
    else
        mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
        chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
        log_info "$ctx: Using existing XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' before starting Weston"
    fi
 
    # Never pre-set WAYLAND_DISPLAY; let Weston choose.
    unset WAYLAND_DISPLAY
 
    log_info "$ctx: Starting Weston..."
    weston_start
 
    # 3) Wait up to ~10 seconds for any Wayland socket to appear.
    i=0
    sock=""
    while [ "$i" -lt 10 ]; do
        if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
            sock="$(discover_wayland_socket_anywhere 2>/dev/null | head -n 1)"
        elif [ -n "${XDG_RUNTIME_DIR:-}" ] && command -v find_wayland_socket_in >/devnull 2>&1; then
            sock="$(find_wayland_socket_in "$XDG_RUNTIME_DIR" 2>/dev/null || true)"
        fi
        if [ -n "$sock" ]; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done
 
    if [ -z "$sock" ]; then
        log_fail "$ctx: Could not find Wayland socket after starting Weston."
        return 1
    fi
 
    if ! adopt_wayland_env_from_socket "$sock"; then
        log_fail "$ctx: Failed to adopt env from socket: $sock"
        return 1
    fi
 
    log_info "$ctx: Weston started; socket: $sock"
    return 0
}

# Find candidate Wayland sockets in common locations.
# Prints absolute socket paths, one per line, most-preferred first.
find_wayland_sockets() {
    uid="$(id -u 2>/dev/null || echo 0)"
 
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] &&
       [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
        echo "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
    fi
 
    # Current uid
    for f in "/run/user/$uid/wayland-0" "/run/user/$uid/wayland-1" "/run/user/$uid/wayland-2"; do
        [ -S "$f" ] && echo "$f"
    done
    for f in /run/user/"$uid"/wayland-*; do
        [ -S "$f" ] && echo "$f"
    done 2>/dev/null
 
    # Any other user under /run/user (covers weston as uid 100, 1000, etc.)
    for d in /run/user/*; do
        [ -d "$d" ] || continue
        [ "$d" = "/run/user/$uid" ] && continue  # skip current uid, already handled above
        for f in "$d"/wayland-*; do
            [ -S "$f" ] && echo "$f"
        done
    done 2>/dev/null
 
    for f in /dev/socket/weston/wayland-*; do
        [ -S "$f" ] && echo "$f"
    done 2>/dev/null
 
    for f in /tmp/wayland-*; do
        [ -S "$f" ] && echo "$f"
    done 2>/dev/null
}

# Ensure XDG_RUNTIME_DIR has owner=current-user and mode 0700.
# Returns 0 if OK (or fixed), non-zero if still not compliant.
ensure_wayland_runtime_dir_perms() {
  dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1

  cur_uid="$(id -u 2>/dev/null || echo 0)"
  cur_gid="$(id -g 2>/dev/null || echo 0)"

  # Best-effort fixups first (don’t error if chown/chmod fail)
  chown "$cur_uid:$cur_gid" "$dir" 2>/dev/null || true
  chmod 0700 "$dir" 2>/dev/null || true

  # Verify using stat (GNU first, then BSD). If stat is unavailable,
  # we can’t verify—assume OK to avoid SC2012 (ls) usage.
  if command -v stat >/dev/null 2>&1; then
    # Mode: GNU: %a ; BSD: %Lp
    mode="$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir" 2>/dev/null || echo '')"
    # Owner uid: GNU: %u ; BSD: %u
    uid="$(stat -c '%u' "$dir" 2>/dev/null || stat -f '%u' "$dir" 2>/dev/null || echo '')"

    [ "$mode" = "700" ] && [ "$uid" = "$cur_uid" ] && return 0
    return 1
  fi

  # No stat available: directory exists and we attempted to fix perms/owner.
  # Treat as success so clients can try; avoids SC2012 warnings.
  return 0
}

# Quick Wayland handshake check.
# Prefers `wayland-info` with a short timeout; otherwise validates socket presence.
# Also enforces/fixes XDG_RUNTIME_DIR permissions so clients won’t reject it.
wayland_connection_ok() {
    sock=""
 
    # Sanity-check the socket path first.
    if [ -z "$XDG_RUNTIME_DIR" ] || [ -z "$WAYLAND_DISPLAY" ]; then
        log_warn "wayland_connection_ok: XDG_RUNTIME_DIR or WAYLAND_DISPLAY not set"
    else
        sock="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
        if [ ! -S "$sock" ]; then
            log_warn "wayland_connection_ok: no Wayland socket at $sock"
            return 1
        fi
        log_info "wayland_connection_ok: using socket $sock"
    fi
 
    if command -v wayland-info >/dev/null 2>&1; then
        log_info "Probing Wayland with: wayland-info"
        wayland-info >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 0 ] && return 0
        # Accept common “killed by timeout/signal” cases as OK (best-effort probe)
        [ "$rc" -eq 143 ] && return 0
        [ "$rc" -eq 124 ] && return 0
        return 1
    fi
 
    if command -v weston-info >/dev/null 2>&1; then
        log_info "Probing Wayland with: weston-info"
        weston-info >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 0 ] && return 0
        [ "$rc" -eq 143 ] && return 0
        [ "$rc" -eq 124 ] && return 0
        return 1
    fi
 
    if command -v weston-simple-egl >/dev/null 2>&1; then
        log_info "Probing Wayland by briefly starting weston-simple-egl"
        (
            weston-simple-egl >/dev/null 2>&1 &
            echo "$!" >"/tmp/.wsegl.$$"
        )
        pid="$(cat "/tmp/.wsegl.$$" 2>/dev/null || echo '')"
        rm -f "/tmp/.wsegl.$$" 2>/dev/null || true
 
        i=0
        while [ "$i" -lt 2 ]; do
            sleep 1
            i=$((i + 1))
        done
 
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
        fi
        # If it started at all, consider the connection OK (best effort).
        return 0
    fi
 
    # Last resort: trust socket existence alone.
    if [ -n "$sock" ] && [ -S "$sock" ]; then
        log_info "No probe tools present; accepting socket existence as OK."
        return 0
    fi
 
    return 1
}
# Very verbose snapshot for debugging (processes, sockets, env, perms).
wayland_debug_snapshot() {
    label="$1"
    [ -n "$label" ] || label="snapshot"
    log_info "----- Wayland/Weston debug snapshot: $label -----"
 
    # Processes
    wpids="$(weston_pids)"
    if [ -n "$wpids" ]; then
        log_info "weston PIDs: $wpids"
        for p in $wpids; do
            if command -v ps >/dev/null 2>&1; then
                ps -o pid,user,group,cmd -p "$p" 2>/dev/null | sed 's/^/[ps] /' || true
            fi
            if [ -r "/proc/$p/cmdline" ]; then
                tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | sed 's/^/[cmdline] /' || true
            fi
        done
    else
        log_info "weston PIDs: (none)"
    fi
 
    # Sockets (meta) — use stat instead of ls (SC2012)
    for s in $(find_wayland_sockets | sort -u); do
        log_info "socket: $s"
        stat -c '[stat] %n -> owner=%U:%G mode=%A size=%s mtime=%y' "$s" 2>/dev/null || true
    done
 
    # Current env
    log_info "Env now: XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        stat -c '[stat] %n -> owner=%U:%G mode=%A size=%s mtime=%y' "$XDG_RUNTIME_DIR" 2>/dev/null || true
    fi
 
    log_info "Suggested export (current env):"
    log_info "  export XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR:-}'"
    log_info "  export WAYLAND_DISPLAY='${WAYLAND_DISPLAY:-}'"
 
    log_info "----- End snapshot: $label -----"
}

# Print concise metadata for a path (portable).
# Prefers stat(1) (GNU or BSD); falls back to ls(1) only if needed.
# Usage: print_path_meta "/some/path"
print_path_meta() {
  p=$1
  if [ -z "$p" ]; then
    return 1
  fi
  # GNU stat
  if stat -c '%A %U %G %a %n' "$p" >/dev/null 2>&1; then
    stat -c '%A %U %G %a %n' "$p"
    return 0
  fi
  # BSD/Mac stat
  if stat -f '%Sp %Su %Sg %OLp %N' "$p" >/dev/null 2>&1; then
    stat -f '%Sp %Su %Sg %OLp %N' "$p"
    return 0
  fi
  # shellcheck disable=SC2012
  ls -ld -- "$p" 2>/dev/null
}

###############################################################################
# DRM / Display helpers (portable, minimal-build friendly)
###############################################################################
# Best-effort: return current mode for a DRM connector using debugfs state.
# Input : full connector name like "card0-HDMI-A-1"
# Output: "1920x1080@60.00" (or "1920x1080@60") or "-" if unknown/unavailable
display_connector_cur_mode() {
    full="$1"
    [ -n "$full" ] || { echo "-"; return; }
 
    card="${full%%-*}"    # card0
    con="${full#*-}"      # HDMI-A-1
    idx="${card#card}"    # 0
 
    state="/sys/kernel/debug/dri/${idx}/state"
 
    # debugfs may not be mounted; best-effort mount (ignore failures)
    if [ ! -r "$state" ] && [ -r /proc/mounts ] && command -v mount >/dev/null 2>&1; then
        if ! grep -q " /sys/kernel/debug " /proc/mounts 2>/dev/null; then
            mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
        fi
    fi
 
    [ -r "$state" ] || { echo "-"; return; }
 
    awk -v CON="$con" '
    BEGIN { crtc=""; in_conn=0; in_crtc=0; mode=""; vr=""; active="" }
 
    # Connector block -> capture bound CRTC id
    $0 ~ /^connector/ {
        in_conn=0
        if ($0 ~ CON) in_conn=1
    }
    in_conn && $0 ~ /crtc/ {
        if (match($0, /[0-9]+/, m)) crtc=m[0]
    }
    in_conn && $0 ~ /^$/ { in_conn=0 }
 
    # CRTC block -> capture active + mode + refresh
    crtc != "" && $0 ~ /^crtc/ {
        in_crtc=0
        if ($0 ~ ("crtc " crtc)) in_crtc=1
    }
    in_crtc && $0 ~ /active/ {
        if ($0 ~ /(yes|true|1)/) active="1"
    }
    in_crtc && $0 ~ /mode/ {
        if (match($0, /[0-9]+x[0-9]+/, m)) mode=m[0]
    }
    in_crtc && ($0 ~ /vrefresh/ || $0 ~ /refresh/) {
        if (match($0, /[0-9]+(\.[0-9]+)?/, m)) vr=m[0]
    }
    in_crtc && $0 ~ /^$/ { in_crtc=0 }
 
    END {
        if (crtc == "" || mode == "" || active != "1") { print "-"; exit }
        if (vr != "") print mode "@" vr
        else print mode
    }' "$state" 2>/dev/null || echo "-"
}

# Echo lines: "<name>\t<status>\t<type>\t<modes>\t<first_mode>"
# Example: "card0-HDMI-A-1 connected HDMI-A 9 1920x1080"
display_list_connectors() {
    found=0
    for d in /sys/class/drm/*-*; do
        [ -e "$d" ] || continue
        [ -f "$d/status" ] || continue
        name="$(basename "$d")"
        status="$(tr -d '\r\n' <"$d/status" 2>/dev/null)"
 
        # enabled (best-effort; may not exist on some kernels)
        enabled="unknown"
        if [ -f "$d/enabled" ]; then
            enabled="$(tr -d '\r\n' <"$d/enabled" 2>/dev/null)"
            [ -z "$enabled" ] && enabled="unknown"
        fi
 
        # Derive connector type from name: cardX-<TYPE>-N
        typ="$(printf '%s' "$name" \
            | sed -n 's/^card[0-9]\+-\([A-Za-z0-9+]\+\(-[A-Za-z0-9+]\+\)*\)-[0-9]\+/\1/p')"
        [ -z "$typ" ] && typ="unknown"
 
        # Modes
        modes_file="$d/modes"
        if [ -f "$modes_file" ]; then
            mc="$(wc -l <"$modes_file" 2>/dev/null | tr -d '[:space:]')"
            [ -z "$mc" ] && mc=0
            fm="$(head -n 1 "$modes_file" 2>/dev/null | tr -d '\r\n')"
            [ -z "$fm" ] && fm="<none>"
        else
            mc=0
            fm="<none>"
        fi
 
        # Current mode (best-effort via debugfs helper)
        cur="$(display_connector_cur_mode "$name")"
        [ -z "$cur" ] && cur="-"
 
        # NOTE: 7 columns: name status enabled typ mc fm cur
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$status" "$enabled" "$typ" "$mc" "$fm" "$cur"
        found=1
    done
    [ "$found" -eq 1 ] || return 1
    return 0
}
# Return 0 if any connector is connected; else 1
display_any_attached() {
    for d in /sys/class/drm/*-*; do
        [ -f "$d/status" ] || continue
        st="$(tr -d '\r\n' <"$d/status" 2>/dev/null)"
        if [ "$st" = "connected" ]; then
            return 0
        fi
    done
    return 1
}

# Print one compact human line summarizing connected outputs
display_connected_summary() {
    have=0
    line=""
    # shellcheck disable=SC2039
    while IFS="$(printf '\t')" read -r name status typ mc fm; do
        [ "$status" = "connected" ] || continue
        have=1
        if [ -n "$fm" ]; then
            seg="${name}(${typ},${fm})"
        else
            seg="${name}(${typ})"
        fi
        if [ -z "$line" ]; then line="$seg"; else line="$line, $seg"; fi
    done <<EOF
$(display_list_connectors 2>/dev/null || true)
EOF
    if [ "$have" -eq 1 ]; then
        echo "$line"
        return 0
    fi
    echo "none"
    return 1
}

# Best-effort "primary" guess: first connected with a mode; else first connected; echoes name
display_primary_guess() {
    best=""
    # Prefer one with modes
    # shellcheck disable=SC2039
    while IFS="$(printf '\t')" read -r name status typ mc fm; do
        [ "$status" = "connected" ] || continue
        if [ -n "$fm" ]; then echo "$name"; return 0; fi
        [ -z "$best" ] && best="$name"
    done <<EOF
$(display_list_connectors 2>/dev/null || true)
EOF
    [ -n "$best" ] && { echo "$best"; return 0; }
    return 1
}

# Optional enrichment via weston-info (if available)
# Prints lines: "weston: <output_name> model=<model> make=<make> phys=<WxH>mm"
display_weston_outputs() {
    if ! command -v weston-info >/dev/null 2>&1; then
        return 0
    fi
    # Very light parse; tolerate different locales
    weston-info 2>/dev/null \
    | awk '
        $1=="output" && $2~/^[0-9]+:$/ {out=$2; sub(":","",out)}
        /make:/ {make=$2}
        /model:/ {model=$2}
        /physical size:/ {w=$3; h=$5; sub("mm","",h)}
        /scale:/ {
          if (out!="") {
            printf("weston: %s make=%s model=%s phys=%sx%sm\n", out, make, model, w, h);
            out=""; make=""; model=""; w=""; h="";
          }
        }
    '
    return 0
}

# One-stop debug snapshot
display_debug_snapshot() {
    ctx="$1"
    [ -z "$ctx" ] && ctx="display-snapshot"
    log_info "----- Display snapshot: $ctx -----"
 
    have=0
    while IFS="$(printf '\t')" read -r name status enabled typ mc fm cur; do
        [ -n "$name" ] || continue
        have=1
        [ -z "$fm" ] && fm="<none>"
        [ -z "$cur" ] && cur="-"
        log_info "DRM: ${name} status=${status} enabled=${enabled} type=${typ} modes=${mc} first=${fm} cur=${cur}"
    done <<EOF
$(display_list_connectors 2>/dev/null || true)
EOF
    [ "$have" -eq 1 ] || log_warn "No DRM connectors in /sys/class/drm."
 
    log_info "----- End display snapshot: $ctx -----"
}

# Returns true (0) if interface is administratively and physically up
is_interface_up() {
    iface="$1"
    if [ -f "/sys/class/net/$iface/operstate" ]; then
        [ "$(cat "/sys/class/net/$iface/operstate")" = "up" ]
    elif command -v ip >/dev/null 2>&1; then
        ip link show "$iface" 2>/dev/null | grep -qw "state UP"
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$iface" 2>/dev/null | grep -qw "UP"
    else
        return 1
    fi
}

# Returns true (0) if physical link/carrier is detected (cable plugged in)
is_link_up() {
    iface="$1"
    [ -f "/sys/class/net/$iface/carrier" ] && [ "$(cat "/sys/class/net/$iface/carrier")" = "1" ]
}

# Returns true (0) if interface is Ethernet type (type 1 in sysfs)
is_ethernet_interface() {
    iface="$1"
    [ -f "/sys/class/net/$iface/type" ] && [ "$(cat "/sys/class/net/$iface/type")" = "1" ]
}

# Get all Ethernet interfaces (excluding common virtual types)
get_ethernet_interfaces() {
    for path in /sys/class/net/*; do
        iface=$(basename "$path")
        case "$iface" in
            lo|docker*|br-*|veth*|virbr*|tap*|tun*|wl*) continue ;;
        esac
        if is_ethernet_interface "$iface"; then
            echo "$iface"
        fi
    done
}

# Bring up interface with retries (down before up).
bringup_interface() {
    iface="$1"; retries="${2:-3}"; sleep_sec="${3:-2}"; i=0
    while [ $i -lt "$retries" ]; do
        if command -v ip >/dev/null 2>&1; then
            ip link set "$iface" down
            sleep 1
            ip link set "$iface" up
            sleep "$sleep_sec"
            ip link show "$iface" | grep -q "state UP" && return 0
        elif command -v ifconfig >/dev/null 2>&1; then
            ifconfig "$iface" down
            sleep 1
            ifconfig "$iface" up
            sleep "$sleep_sec"
            ifconfig "$iface" | grep -q "UP" && return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# Wait for a valid IPv4 address on the given interface, up to a timeout (default 30s)
wait_for_ip_address() {
    iface="$1"
    timeout="${2:-30}"
    elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        ip_addr=$(get_ip_address "$iface")
        if [ -n "$ip_addr" ]; then
            if echo "$ip_addr" | grep -q '^169\.254'; then
                echo "$ip_addr"
                return 2
            fi
            echo "$ip_addr"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# Get the IPv4 address for a given interface.
get_ip_address() {
    iface="$1"
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show "$iface" | awk '{print $4}' | cut -d/ -f1 | head -n1
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -n1
    fi
}

# Run a command with a timeout (in seconds)
run_with_timeout() {
    timeout="$1"; shift
    ( "$@" ) &
    pid=$!
    ( sleep "$timeout"; kill "$pid" 2>/dev/null ) &
    watcher=$!
    wait $pid 2>/dev/null
    status=$?
    kill $watcher 2>/dev/null
    return $status
}

# Only apply a timeout if TIMEOUT is set; prefer `timeout`; avoid functestlib here
runWithTimeoutIfSet() {
  # Normalize TIMEOUT: treat empty or non-numeric as 0
  t="${TIMEOUT:-}"
  case "$t" in
    ''|*[!0-9]*)
      t=0
      ;;
  esac
 
  if [ "$t" -gt 0 ] && command -v run_with_timeout >/dev/null 2>&1; then
    # Correct signature: run_with_timeout <seconds> <cmd> [args...]
    run_with_timeout "$t" "$@"
  else
    # No timeout -> run command directly
    "$@"
  fi
}

# DHCP client logic (dhclient and udhcpc with timeouts)
run_dhcp_client() {
    iface="$1"
    timeout="${2:-10}"
    ip_addr=""
    log_info "Attempting DHCP on $iface (timeout ${timeout}s)..."
    if command -v dhclient >/dev/null 2>&1; then
        log_info "Trying dhclient for $iface"
        run_with_timeout "$timeout" dhclient "$iface"
        ip_addr=$(wait_for_ip_address "$iface" 5)
        if [ -n "$ip_addr" ]; then
            echo "$ip_addr"
            return 0
        fi
    fi
    if command -v udhcpc >/dev/null 2>&1; then
        log_info "Trying udhcpc for $iface"
        run_with_timeout "$timeout" udhcpc -i "$iface" -T 3 -t 3
        ip_addr=$(wait_for_ip_address "$iface" 5)
        if [ -n "$ip_addr" ]; then
            echo "$ip_addr"
            return 0
        fi
    fi
    log_warn "DHCP failed for $iface"
    return 1
}

# Safely run DHCP client without disrupting existing config
try_dhcp_client_safe() {
    iface=$1
    timeout=${2:-10}
 
    [ -n "$iface" ] || return 1
 
    # Debug breadcrumb: track which path we took
    dhcp_path="unknown"
    dhcp_note=""
 
    # Ensure interface is up (best-effort)
    ip link set "$iface" up >/dev/null 2>&1 || true
 
    # If link is down/no cable, don't try DHCP
    if command -v is_link_up >/dev/null 2>&1; then
        if ! is_link_up "$iface"; then
            log_warn "$iface link is down; skipping DHCP"
            return 1
        fi
    elif command -v ethIsLinkUp >/dev/null 2>&1; then
        if ! ethIsLinkUp "$iface"; then
            log_warn "$iface link is down; skipping DHCP"
            return 1
        fi
    fi
 
    current_ip=$(get_ip_address "$iface")
    if [ -n "$current_ip" ] && ! echo "$current_ip" | grep -q '^169\.254'; then
        dhcp_path="skip_existing_ip"
        log_info "$iface DHCP path: ${dhcp_path} (ip=${current_ip})"
        log_info "$iface already has valid IP: $current_ip. Skipping DHCP."
        return 0
    fi
 
    # If NetworkManager/systemd-networkd is active, avoid fighting it:
    # just wait for IP to appear.
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet NetworkManager 2>/dev/null \
           || systemctl is-active --quiet systemd-networkd 2>/dev/null; then
            dhcp_path="systemd_nm_wait"
            log_info "$iface DHCP path: ${dhcp_path} (timeout=${timeout}s)"
            log_info "Network manager detected; waiting up to ${timeout}s for IP on $iface..."
            i=0
            while [ "$i" -lt "$timeout" ]; do
                current_ip=$(get_ip_address "$iface")
                if [ -n "$current_ip" ] && ! echo "$current_ip" | grep -q '^169\.254'; then
                    log_info "$iface obtained IP via network manager: $current_ip"
                    log_info "$iface DHCP path: ${dhcp_path} success (ip=${current_ip})"
                    return 0
                fi
                i=$((i + 1))
                sleep 1
            done
            log_warn "$iface did not obtain a valid IP within ${timeout}s"
            log_warn "$iface DHCP path: ${dhcp_path} failed (no valid IP within ${timeout}s)"
            return 1
        fi
    fi
 
    # Minimal/kernel-only builds might not have udhcpc. Try other clients first if needed.
    if ! command -v udhcpc >/dev/null 2>&1; then
        log_warn "udhcpc not found (kernel/minimal build). Trying fallback DHCP clients..."
        dhcp_path="fallback_clients"
        log_info "$iface DHCP path: ${dhcp_path} (trying dhclient/dhcpcd)"
 
        if command -v dhclient >/dev/null 2>&1; then
            dhcp_note="dhclient"
            log_info "$iface DHCP path: ${dhcp_path}/${dhcp_note} (timeout=${timeout}s)"
            # Best-effort: try bounded dhclient
            if command -v run_with_timeout >/dev/null 2>&1; then
                run_with_timeout "${timeout}s" dhclient -1 -v "$iface" >/dev/null 2>&1 || true
            else
                dhclient -1 -v "$iface" >/dev/null 2>&1 || true
            fi
 
            current_ip=$(get_ip_address "$iface")
            if [ -n "$current_ip" ] && ! echo "$current_ip" | grep -q '^169\.254'; then
                log_info "$iface DHCP path: ${dhcp_path}/${dhcp_note} success (ip=${current_ip})"
                return 0
            fi
        fi
 
        if command -v dhcpcd >/dev/null 2>&1; then
            dhcp_note="dhcpcd"
            log_info "$iface DHCP path: ${dhcp_path}/${dhcp_note} (timeout=${timeout}s)"
            # dhcpcd: try a bounded attempt and then stop
            if command -v run_with_timeout >/dev/null 2>&1; then
                run_with_timeout "${timeout}s" dhcpcd -4 -t "$timeout" "$iface" >/dev/null 2>&1 || true
            else
                dhcpcd -4 -t "$timeout" "$iface" >/dev/null 2>&1 || true
            fi
            # Avoid leaving daemon running if it spawned
            dhcpcd -k "$iface" >/dev/null 2>&1 || true
 
            current_ip=$(get_ip_address "$iface")
            if [ -n "$current_ip" ] && ! echo "$current_ip" | grep -q '^169\.254'; then
                log_info "$iface DHCP path: ${dhcp_path}/${dhcp_note} success (ip=${current_ip})"
                return 0
            fi
        fi
 
        log_warn "$iface DHCP path: ${dhcp_path} failed (no client succeeded)"
        return 1
    fi
 
    # Safe udhcpc script:
    # - Avoid aggressive flushes
    # - Remove only link-local (169.254/16) if present
    # - Apply lease IP/route
    safe_dhcp_script=$(mktemp /tmp/udhcpc-safe-"$iface".XXXXXX 2>/dev/null || echo "/tmp/udhcpc-safe-$iface-$$.sh")
    cat <<'EOF' > "$safe_dhcp_script"
#!/bin/sh
# udhcpc env: interface ip subnet mask router dns ...
mask_to_prefix() {
    m="$1"
    case "$m" in
        *.*.*.*)
            echo "$m" | awk -F. '
            function bits8(n,  b) {
                b=0
                while (n>0) { b += (n%2); n=int(n/2) }
                return b
            }
            {
                p=0
                for (i=1; i<=4; i++) {
                    n=$i+0
                    # count bits set in each octet (valid for contiguous netmasks)
                    if      (n==255) p+=8
                    else if (n==254) p+=7
                    else if (n==252) p+=6
                    else if (n==248) p+=5
                    else if (n==240) p+=4
                    else if (n==224) p+=3
                    else if (n==192) p+=2
                    else if (n==128) p+=1
                    else if (n==0)   p+=0
                    else { p="" ; break }
                }
                if (p!="") print p
            }'
            ;;
        *)
            case "$m" in
                ''|*[!0-9]*) echo "" ;;
                *) echo "$m" ;;
            esac
            ;;
    esac
}
 
case "$1" in
    bound|renew)
        # Drop link-local if present
        ip -4 addr show dev "$interface" 2>/dev/null | awk '/inet 169\.254\./{print $2}' \
        | while IFS= read -r cidr; do
            [ -n "$cidr" ] || continue
            ip addr del "$cidr" dev "$interface" >/dev/null 2>&1 || true
        done
 
        # Add/replace address (best-effort)
        if [ -n "$ip" ]; then
            pfx=""
            if [ -n "$mask" ]; then
                pfx=$(mask_to_prefix "$mask" 2>/dev/null)
            fi
            if [ -n "$pfx" ]; then
                ip addr replace "$ip/$pfx" dev "$interface" >/dev/null 2>&1 || true
            else
                ip addr add "$ip" dev "$interface" >/dev/null 2>&1 || true
            fi
        fi
 
        # Default route
        if [ -n "$router" ]; then
            ip route replace default via "$router" dev "$interface" >/dev/null 2>&1 || true
        fi
        exit 0
        ;;
    deconfig)
        # Do nothing (avoid flushing)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$safe_dhcp_script"
 
    dhcp_path="udhcpc_safe_script"
    log_info "$iface DHCP path: ${dhcp_path} (timeout=${timeout}s)"
    log_info "Attempting DHCP on $iface (udhcpc) for up to ${timeout}s..."
    if command -v run_with_timeout >/dev/null 2>&1; then
        run_with_timeout "${timeout}s" udhcpc -i "$iface" -n -q -s "$safe_dhcp_script" >/dev/null 2>&1 || true
    else
        # Best-effort bounded retries if run_with_timeout isn't available
        udhcpc -i "$iface" -n -q -t 3 -T 3 -s "$safe_dhcp_script" >/dev/null 2>&1 || true
    fi
 
    rm -f "$safe_dhcp_script" >/dev/null 2>&1 || true
 
    # Verify outcome
    current_ip=$(get_ip_address "$iface")
    if [ -n "$current_ip" ] && ! echo "$current_ip" | grep -q '^169\.254'; then
        log_info "$iface obtained IP after DHCP: $current_ip"
        log_info "$iface DHCP path: ${dhcp_path} success (ip=${current_ip})"
        return 0
    fi
 
    log_warn "$iface still has no valid IP after DHCP attempt"
    log_warn "$iface DHCP path: ${dhcp_path} failed (no valid IP after attempt)"
    return 1
}

ethLinkDetected() {
    iface=$1
    [ -n "$iface" ] || return 1

    command -v ethtool >/dev/null 2>&1 || return 1
    # Prints: yes/no (or nothing on parse failure)
    ethtool "$iface" 2>/dev/null \
        | awk -F': ' '/^[[:space:]]*Link detected:/ {print $2; exit 0}'
}

ethIsLinkUp() {
    iface=$1
    [ -n "$iface" ] || return 1
 
    # 1) If carrier says 1, we are good (fast path)
    if [ -r "/sys/class/net/$iface/carrier" ]; then
        [ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" = "1" ] && return 0
        # If carrier is 0, do NOT return yet — fall through to other hints.
    fi
 
    # 2) If helper exists and says up, accept it (but don't fail early)
    if command -v is_link_up >/dev/null 2>&1; then
        is_link_up "$iface" && return 0
    fi
 
    # 3) operstate can sometimes reflect link sooner than carrier in some stacks
    if [ -r "/sys/class/net/$iface/operstate" ]; then
        st=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || true)
        [ "$st" = "up" ] && return 0
    fi
 
    # 4) ip link LOWER_UP (physical) is a good signal if ip exists
    if command -v ip >/dev/null 2>&1; then
        ip link show "$iface" 2>/dev/null | grep -qw "LOWER_UP" && return 0
    fi
 
    # 5) Last resort: ethtool parse
    if command -v ethtool >/dev/null 2>&1; then
        ld=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/^[[:space:]]*Link detected:/ {print $2; exit 0}' || true)
        [ "$ld" = "yes" ] && return 0
    fi
 
    return 1
}
 
ethWaitLinkUp() {
    iface=$1
    timeout_s=$2
    i=0
 
    [ -n "$iface" ] || return 1
    [ -n "$timeout_s" ] || timeout_s=5
 
    while [ "$i" -lt "$timeout_s" ]; do
        if ethIsLinkUp "$iface"; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
 
    return 1
}

ethGetLinkSpeedMbps() {
    iface=$1
    sp=""

    [ -n "$iface" ] || return 1

    # Only meaningful when link is up
    if ! ethIsLinkUp "$iface"; then
        return 1
    fi

    # Prefer sysfs (but can be -1 even when link is up)
    if [ -r "/sys/class/net/$iface/speed" ]; then
        sp=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || true)
        case "$sp" in ""|-1|*[!0-9]*) sp="" ;; esac
        if [ -n "$sp" ] && [ "$sp" -gt 0 ] 2>/dev/null; then
            printf '%s\n' "$sp"
            return 0
        fi
    fi

    # Fallback: ethtool parse ("100Mb/s", "2500Mb/s", etc.)
    if command -v ethtool >/dev/null 2>&1; then
        sp=$(ethtool "$iface" 2>/dev/null \
            | awk -F': ' '/^[[:space:]]*Speed:/ {print $2; exit 0}')
        sp=$(printf '%s\n' "$sp" | sed -n 's/^\([0-9][0-9]*\)Mb\/s.*/\1/p')
        case "$sp" in ""|*[!0-9]*) sp="" ;; esac
        if [ -n "$sp" ]; then
            printf '%s\n' "$sp"
            return 0
        fi
    fi

    return 1
}

ethRestartAutoneg() {
    iface=$1
    [ -n "$iface" ] || return 1
    command -v ethtool >/dev/null 2>&1 || return 1

    # Restart autoneg/link training (if supported by driver)
    ethtool -r "$iface" >/dev/null 2>&1 || return 1
    return 0
}

ethForceSpeedMbps() {
    iface=$1
    mbps=$2
 
    [ -n "$iface" ] || return 1
    command -v ethtool >/dev/null 2>&1 || return 1
    case "$mbps" in ""|*[!0-9]*) return 1 ;; esac
 
    ethtool -s "$iface" speed "$mbps" duplex full autoneg off >/dev/null 2>&1 || return 1
    return 0
}

ethEnableAutoneg() {
    iface=$1

    [ -n "$iface" ] || return 1
    command -v ethtool >/dev/null 2>&1 || return 1

    ethtool -s "$iface" autoneg on >/dev/null 2>&1 || return 1
    return 0
}

ethSupportsSpeedMbps() {
    iface=$1
    mbps=$2
 
    [ -n "$iface" ] || return 1
    case "$mbps" in ""|*[!0-9]*) return 1 ;; esac
    command -v ethtool >/dev/null 2>&1 || return 1
 
    ethtool "$iface" 2>/dev/null | grep -Eq "[[:space:]]${mbps}baseT/Full|[[:space:]]${mbps}baseT1/Full|[[:space:]]${mbps}baseX/Full"
}

# Returns: on/off/unknown (best-effort)
ethGetAutonegState() {
    iface=$1
    [ -n "$iface" ] || return 1
    command -v ethtool >/dev/null 2>&1 || { echo "unknown"; return 0; }

    st=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/^[[:space:]]*Auto-negotiation:/ {print $2; exit 0}' || true)
    case "$st" in
        on|off) echo "$st" ;;
        *) echo "unknown" ;;
    esac
    return 0
}

# Heuristic: decide force order for 100M-only/locked ports
# Echoes a space-separated list like: "1000 100" or "100 1000"
ethPickForceOrder() {
    iface=$1
    [ -n "$iface" ] || { echo "1000 100"; return 0; }
    command -v ethtool >/dev/null 2>&1 || { echo "1000 100"; return 0; }

    # Pull supported/advertised modes blocks (best-effort)
    modes=$(ethtool "$iface" 2>/dev/null | awk '
        BEGIN{cap=0}
        /^[[:space:]]*Supported link modes:/ {cap=1; print; next}
        /^[[:space:]]*Advertised link modes:/ {cap=1; print; next}
        cap==1 && /^[[:space:]]+[0-9]/ {print; next}
        cap==1 && /^[^[:space:]]/ {cap=0}
    ' || true)

    # Default
    order="1000 100"

    # If we see no gig/2.5g/10g capability mentioned at all, prefer trying 100 first.
    if [ -n "$modes" ]; then
        if ! printf '%s\n' "$modes" | grep -Eq '1000baseT|2500baseT|5000baseT|10000baseT'; then
            order="100 1000"
        fi
    fi

    echo "$order"
    return 0
}

ethEnsureLinkUpWithFallback() {
    iface=$1
    timeout_s=$2
    [ -n "$iface" ] || return 1
    [ -n "$timeout_s" ] || timeout_s=5
    init_autoneg=$(ethGetAutonegState "$iface" 2>/dev/null || echo "unknown")
    
    # Bring interface up using existing helper (admin-up)
    if command -v bringup_interface >/dev/null 2>&1; then
        bringup_interface "$iface" 3 2 >/dev/null 2>&1 || true
    else
        ip link set "$iface" up >/dev/null 2>&1 || true
        sleep 1
    fi
 
    # Let PHY settle a bit after admin-up
    sleep 1
 
    # 1) Wait for normal autoneg link
    if ethWaitLinkUp "$iface" "$timeout_s"; then
        return 0
    fi
 
    # If no ethtool, we cannot do fallback forcing
    command -v ethtool >/dev/null 2>&1 || return 1
 
    # 2) Try restarting autoneg once
    if ethRestartAutoneg "$iface"; then
        # Give retrain a moment before polling
        sleep 1
        if ethWaitLinkUp "$iface" "$timeout_s"; then
            return 0
        fi
    fi
 
    # 3) Force speeds (smart order: may try 100 first for 100M-only setups)
    force_order=$(ethPickForceOrder "$iface" 2>/dev/null || echo "1000 100")
    for sp in $force_order; do
        if ethForceSpeedMbps "$iface" "$sp"; then
            # After forcing speed, some PHYs need a short settle window
            sleep 1
 
            # Best-effort retrain
            ethtool -r "$iface" >/dev/null 2>&1 || true
            sleep 1
 
            if ethWaitLinkUp "$iface" "$timeout_s"; then
                # IMPORTANT: Do NOT restore autoneg here.
                # If we had to force speed (autoneg off), keeping it avoids regression
                # on 100M-only / locked ports (your exact case).
                return 0
            fi
        fi
    done
 
    # Bring-up failed:
    # If autoneg was originally on, restore it (best-effort) so we don't leave user in forced mode.
    if [ "$init_autoneg" = "on" ]; then
        ethEnableAutoneg "$iface" >/dev/null 2>&1 || true
    fi
    return 1
}
###############################################################################
# get_remoteproc_by_firmware <short-fw-name> [outfile] [all]
# - If outfile is given: append *all* matches as "<path>|<state>|<firmware>|<name>"
#   (one per line) and return 0 if at least one match.
# - If no outfile: print the *first* match to stdout and return 0.
# - Returns 1 if nothing matched, 3 if misuse (no fw argument).
###############################################################################
get_remoteproc_by_firmware() {
    fw="$1"
    out="$2"      # optional: filepath to append results
    list_all="$3" # set to "all" to continue past first match 

    [ -n "$fw" ] || return 3 # misuse if no firmware provided

    found=0
    for p in /sys/class/remoteproc/remoteproc*; do
        [ -d "$p" ] || continue

        # read name, firmware, state
        name=""
        [ -r "$p/name" ]     && IFS= read -r name     <"$p/name"
        firmware=""
        [ -r "$p/firmware" ] && IFS= read -r firmware <"$p/firmware"
        state="unknown"
        [ -r "$p/state" ]    && IFS= read -r state    <"$p/state"

        case "$name $firmware" in
            *"$fw"*)
                line="${p}|${state}|${firmware}|${name}"
                if [ -n "$out" ]; then
                    printf '%s\n' "$line" >>"$out"
                    found=1
                    continue
                fi

                # print to stdout and possibly stop
                printf '%s\n' "$line"
                found=1
                [ "$list_all" = "all" ] || return 0
                ;;
        esac
    done

    # if we appended to a file, success if found>=1
    if [ "$found" -eq 1 ]; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# dt_has_remoteproc_fw <fw-short>
#   Return:
#     0 = DT describes this remoteproc firmware
#     1 = DT does not describe it
#     3 = misuse (no argument)
# ------------------------------------------------------------------------------
dt_has_remoteproc_fw() {
    fw="$1"
    [ -n "$fw" ] || return 3
 
    base="/proc/device-tree"
    [ -d "$base" ] || return 1
 
    # lower-case match key
    fw_lc=$(printf '%s\n' "$fw" | tr '[:upper:]' '[:lower:]')
 
    # new fast-path (any smp2p-<fw>* or remoteproc-<fw>* directory)
    found=0
    for d in "$base"/smp2p-"$fw"* "$base"/remoteproc-"$fw"*; do
        [ -d "$d" ] && found=1 && break
    done
    [ "$found" -eq 1 ] && return 0
 
    # 2) Shallow find (<depth 2) for any node/prop name containing fw
    if find "$base" -maxdepth 2 -iname "*$fw_lc*" -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi
 
    # 3) Grep soc@0 and aliases for a first match
    if grep -Iq -m1 -F "$fw_lc" "$base/soc@0" "$base/aliases" 2>/dev/null; then
        return 0
    fi
 
    # 4) Fallback: grep entire DT tree
    if grep -Iq -m1 -F "$fw_lc" "$base" 2>/dev/null; then
        return 0
    fi
 
    return 1
}

# Find the remoteproc path for a given firmware substring (e.g., "adsp", "cdsp", "gdsp").
# Logic:
#   - grep -n over /sys/class/remoteproc/remoteproc*/firmware (one line per remoteproc)
#   - Take the first matching line number (1-based)
#   - Subtract 1 → remoteproc index → /sys/class/remoteproc/remoteproc${idx}
get_remoteproc_path_by_firmware() {
    name=$1
 
    [ -n "$name" ] || return 1
    [ -d /sys/class/remoteproc ] || return 1
 
    for fw in /sys/class/remoteproc/remoteproc*/firmware; do
        # Skip if glob didn't match any file
        [ -f "$fw" ] || continue
 
        # Read first line from firmware file without using cat
        if IFS= read -r fwname <"$fw"; then
            case "$fwname" in
                *"$name"*)
                    # Map firmware file back to its remoteproc directory
                    dir=${fw%/firmware}
                    if [ -d "$dir" ]; then
                        printf '%s\n' "$dir"
                        return 0
                    fi
                    ;;
            esac
        fi
    done
 
    return 1
}

# Get remoteproc state
get_remoteproc_state() {
    rp="$1"
    [ -z "$rp" ] && { printf '\n'; return 1; }
 
    case "$rp" in
        /sys/*) rpath="$rp" ;;
        *)      rpath="/sys/class/remoteproc/$rp" ;;
    esac
 
    state_file="$rpath/state"
    if [ -r "$state_file" ]; then
        IFS= read -r state < "$state_file" || state=""
        printf '%s\n' "$state"
        return 0
    fi
    printf '\n'
    return 1
}

# wait_remoteproc_state <sysfs-path> <desired_state> <timeout_s> <poll_interval_s>
wait_remoteproc_state() {
    rp="$1"; want="$2"; to=${3:-10}; poll=${4:-1}
 
    case "$rp" in
        /sys/*) rpath="$rp" ;;
        *)      rpath="/sys/class/remoteproc/$rp" ;;
    esac
 
    start_ts=$(date +%s)
    while :; do
        cur=$(get_remoteproc_state "$rpath")
        [ "$cur" = "$want" ] && return 0
 
        now_ts=$(date +%s)
        [ $((now_ts - start_ts)) -ge "$to" ] && {
            log_info "Waiting for state='$want' timed out (got='$cur')..."
            return 1
        }
        sleep "$poll"
    done
}

# Stop remoteproc
stop_remoteproc() {
    rproc_path="$1"
 
    # Resolve to a real sysfs dir if only a name was given
    case "$rproc_path" in
        /sys/*) path="$rproc_path" ;;
        remoteproc*) path="/sys/class/remoteproc/$rproc_path" ;;
        *) path="$rproc_path" ;;  # last resort, assume caller passed full path
    esac
 
    statef="$path/state"
    if [ ! -w "$statef" ]; then
        log_warn "stop_remoteproc: state file not found/writable: $statef"
        return 1
    fi
 
    printf 'stop\n' >"$statef" 2>/dev/null || return 1
    wait_remoteproc_state "$path" offline 6
}
 
# Start remoteproc
start_remoteproc() {
    rproc_path="$1"
 
    case "$rproc_path" in
        /sys/*) path="$rproc_path" ;;
        remoteproc*) path="/sys/class/remoteproc/$rproc_path" ;;
        *) path="$rproc_path" ;;
    esac
 
    statef="$path/state"
    if [ ! -w "$statef" ]; then
        log_warn "start_remoteproc: state file not found/writable: $statef"
        return 1
    fi
 
    printf 'start\n' >"$statef" 2>/dev/null || return 1
    wait_remoteproc_state "$path" running 6
}
# Validate remoteproc running state with retries and logging
validate_remoteproc_running() {
    fw_name="$1"
    log_file="${2:-/dev/null}"
    max_wait_secs="${3:-10}"
    delay_per_try_secs="${4:-1}"

    rproc_path=$(get_remoteproc_path_by_firmware "$fw_name")
    if [ -z "$rproc_path" ]; then
        echo "[ERROR] Remoteproc for '$fw_name' not found" >> "$log_file"
        {
            echo "---- Last 20 remoteproc dmesg logs ----"
            dmesg | grep -i "remoteproc" | tail -n 20
            echo "----------------------------------------"
        } >> "$log_file"
        return 1
    fi

    total_waited=0
    while [ "$total_waited" -lt "$max_wait_secs" ]; do
        state=$(get_remoteproc_state "$rproc_path")
        if [ "$state" = "running" ]; then
            return 0
        fi
        sleep "$delay_per_try_secs"
        total_waited=$((total_waited + delay_per_try_secs))
    done

    echo "[ERROR] $fw_name remoteproc did not reach 'running' state within ${max_wait_secs}s (last state: $state)" >> "$log_file"
    {
        echo "---- Last 20 remoteproc dmesg logs ----"
        dmesg | grep -i "remoteproc" | tail -n 20
        echo "----------------------------------------"
    } >> "$log_file"
    return 1
}

# acquire_test_lock <testname>
acquire_test_lock() {
    lockfile="/var/lock/$1.lock"
    exec 9>"$lockfile"
    if ! flock -n 9; then
        log_warn "Could not acquire lock on $lockfile → SKIP"
        echo "$1 SKIP" > "./$1.res"
        exit 0
    fi
    log_info "Acquired lock on $lockfile"
}

# release_test_lock
release_test_lock() {
    flock -u 9
    log_info "Released lock"
}

# summary_report <testname> <mode> <stop_time_s> <start_time_s> <rpmsg_result>
# Appends a machine‐readable summary line to the test log
summary_report() {
    test="$1"
    mode="$2"
    stop_t="$3"
    start_t="$4"
    rp="$5"
    log_info "Summary for ${test}: mode=${mode} stop_time_s=${stop_t} start_time_s=${start_t} rpmsg=${rp}"
}

# dump_rproc_logs <sysfs-path> <label>
# Captures debug trace + filtered dmesg into a timestamped log
dump_rproc_logs() {
    rpath="$1"; label="$2"
    ts=$(date +%Y%m%d_%H%M%S)
    base=$(basename "$rpath")
    logfile="rproc_${base}_${label}_${ts}.log"
    log_info "Dumping ${base} [${label}] → ${logfile}"
    [ -r "$rpath/trace" ] && cat "$rpath/trace" >"$logfile"
    dmesg | grep -i "$base" >>"$logfile" 2>/dev/null || :
}

# find_rpmsg_ctrl_for <short-name>
# e.g. find_rpmsg_ctrl_for adsp
find_rpmsg_ctrl_for() {
    want="$1"  # e.g. "adsp"

    for dev in /dev/rpmsg_ctrl*; do
        [ -e "$dev" ] || continue

        base=$(basename "$dev")
        sysfs="/sys/class/rpmsg/${base}"

        # resolve the rpmsg_ctrl node’s real path
        target=$(readlink -f "$sysfs/device")
        # climb up to the remoteprocX directory
        remoteproc_dir=$(dirname "$(dirname "$(dirname "$target")")")

        # Try the 'name' file
        if [ -r "$remoteproc_dir/name" ]; then
            rpname=$(cat "$remoteproc_dir/name")
            if echo "$rpname" | grep -qi "^${want}"; then
                printf '%s\n' "$dev"
                return 0
            fi
        fi

        # Fallback: try the 'firmware' file, strip extension
        if [ -r "$remoteproc_dir/firmware" ]; then
            fw=$(basename "$(cat "$remoteproc_dir/firmware")")   # adsp.mbn
            short="${fw%%.*}"                                    # adsp
            if echo "$short" | grep -qi "^${want}"; then
                printf '%s\n' "$dev"
                return 0
            fi
        fi
    done

    return 1
}

# Given a remoteproc *absolute* path (e.g. /sys/class/remoteproc/remoteproc2),
# return the FIRST matching /sys/class/rpmsg/rpmsg_ctrlN path.
find_rpmsg_ctrl_for_rproc() {
    rproc_path="$1"
    for c in /sys/class/rpmsg/rpmsg_ctrl*; do
        [ -e "$c" ] || continue
        # device symlink for ctrl points into ...remoteprocX/...rpmsg_ctrl...
        devlink=$(readlink -f "$c/device" 2>/dev/null) || continue
        case "$devlink" in
            "$rproc_path"/*) printf '%s\n' "$c"; return 0 ;;
        esac
    done
    return 1
}

# Ensure /dev node exists for a sysfs rpmsg item (ctrl or data). Echo /dev/… path.
rpmsg_sys_to_dev() {
    sys="$1"
    dev="/dev/$(basename "$sys")"
    if [ ! -e "$dev" ]; then
        [ -r "$sys/dev" ] || return 1
        IFS=: read -r maj min < "$sys/dev" || return 1
        mknod "$dev" c "$maj" "$min" 2>/dev/null || return 1
        chmod 600 "$dev" 2>/dev/null
    fi
    printf '%s\n' "$dev"
}

# Find existing rpmsg data endpoints that belong to this remoteproc path.
# Echo all matching /dev/rpmsgN (one per line). Return 0 if any, 1 if none.
find_rpmsg_data_for_rproc() {
    rproc_path="$1"
    found=0
    for d in /sys/class/rpmsg/rpmsg[0-9]*; do
        [ -e "$d" ] || continue
        devlink=$(readlink -f "$d/device" 2>/dev/null) || continue
        case "$devlink" in
            "$rproc_path"/*)
                if node=$(rpmsg_sys_to_dev "$d"); then
                    printf '%s\n' "$node"
                    found=1
                fi
                ;;
        esac
    done
    [ "$found" -eq 1 ]
}

# Create a new endpoint via ctrl/create (no hardcoded name: we pick the first free)
# If firmware doesn't expose ping service, this may still not respond; we just create.
# Returns /dev/rpmsgN or empty on failure.
rpmsg_create_ep_generic() {
    ctrl_sys="$1"
    name="${2:-gen-test}"   # generic endpoint name
    src="${3:-0}"
    dst="${4:-0}"
 
    create_file="$(readlink -f "$ctrl_sys")/create"
    [ -w "$create_file" ] || return 1
 
    # Request endpoint creation
    printf '%s %s %s\n' "$name" "$src" "$dst" >"$create_file" 2>/dev/null || return 1
 
    # Pick the newest rpmsg* sysfs node without using 'ls -t' (SC2012)
    new_sys=$(
        find -L /sys/class/rpmsg -maxdepth 1 -type l -name 'rpmsg[0-9]*' \
            -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2}'
    )
 
    [ -n "$new_sys" ] || return 1
 
    rpmsg_sys_to_dev "$new_sys"
}

# Try to exercise the channel by write-read loopback.
# Without protocol knowledge, we can only do a heuristic:
# write "PING\n", read back; if anything comes, treat as success.
rpmsg_try_echo() {
    node="$1"
    # write
    printf 'PING\n' >"$node" 2>/dev/null || return 1
    # read (2s timeout if available)
    if command -v timeout >/dev/null 2>&1; then
        reply=$(timeout 2 cat "$node" 2>/dev/null)
    else
        reply=$(dd if="$node" bs=256 count=1 2>/dev/null)
    fi
    [ -n "$reply" ] || return 1
    return 0
}

# Clean up WiFi test environment (reusable for other tests)
wifi_cleanup() {
    iface="$1"
    log_info "Cleaning up WiFi test environment..."
    killall -q wpa_supplicant 2>/dev/null
    rm -f /tmp/wpa_supplicant.conf nmcli.log wpa.log
    if [ -n "$iface" ]; then
        ip link set "$iface" down 2>/dev/null || ifconfig "$iface" down 2>/dev/null
    fi
}

# Extract credentials from args/env/file
get_wifi_credentials() {
    ssid="$1"
    pass="$2"
    if [ -z "$ssid" ] || [ -z "$pass" ]; then
        ssid="${SSID:-$ssid}"
        pass="${PASSWORD:-$pass}"
    fi
    if [ -z "$ssid" ] || [ -z "$pass" ]; then
        if [ -f "./ssid_list.txt" ]; then
            read -r ssid pass _ < ./ssid_list.txt
        fi
    fi
    ssid=$(echo "$ssid" | xargs)
    pass=$(echo "$pass" | xargs)
    if [ -z "$ssid" ] || [ -z "$pass" ]; then
        return 1
    fi
    printf '%s %s\n' "$ssid" "$pass"
    return 0
}

# POSIX-compliant: Retry a shell command up to N times with delay
retry_command() {
    cmd="$1"
    retries="$2"
    delay="$3"
    i=1
    while [ "$i" -le "$retries" ]; do
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Attempt $i/$retries failed: $cmd"
        i=$((i + 1))
        sleep "$delay"
    done
    return 1
}

# Connect to Wi-Fi using nmcli, with fallback when key-mgmt is required
wifi_connect_nmcli() {
    iface="$1"
    ssid="$2"
    pass="$3"

    if ! command -v nmcli >/dev/null 2>&1; then
        return 1
    fi

    log_info "Trying to connect using nmcli..."
    mkdir -p "${LOG_DIR:-.}" 2>/dev/null || true
    nm_log="${LOG_DIR:-.}/nmcli_${iface}_$(printf '%s' "$ssid" | tr ' /' '__').log"

    # First try the simple connect path (what you already had)
    if [ -n "$pass" ]; then
        retry_command "nmcli dev wifi connect \"$ssid\" password \"$pass\" ifname \"$iface\" 2>&1 | tee \"$nm_log\"" 3 3
    else
        retry_command "nmcli dev wifi connect \"$ssid\" ifname \"$iface\" 2>&1 | tee \"$nm_log\"" 3 3
    fi
    rc=$?
    [ $rc -eq 0 ] && return 0

    # Look for the specific error and fall back to creating a connection profile
    if grep -qi '802-11-wireless-security\.key-mgmt.*missing' "$nm_log"; then
        log_warn "nmcli connect complained about missing key-mgmt; creating an explicit connection profile..."

        nmcli -t -f WIFI nm status >/dev/null 2>&1 || nmcli r wifi on >/dev/null 2>&1 || true
        nmcli dev set "$iface" managed yes >/dev/null 2>&1 || true
        nmcli dev disconnect "$iface" >/dev/null 2>&1 || true
        nmcli dev wifi rescan >/dev/null 2>&1 || true

        con_name="$ssid"
        # If a connection with the same name exists, drop it to avoid conflicts
        if nmcli -t -f NAME con show 2>/dev/null | grep -Fxq "$con_name"; then
            nmcli con delete "$con_name" >/dev/null 2>&1 || true
        fi

        if [ -n "$pass" ]; then
            # Try WPA2 PSK first (most common)
            if nmcli con add type wifi ifname "$iface" con-name "$con_name" ssid "$ssid" \
                   wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" >>"$nm_log" 2>&1; then
                if nmcli con up "$con_name" ifname "$iface" >>"$nm_log" 2>&1; then
                    log_pass "Connected to $ssid via explicit profile (wpa-psk)."
                    return 0
                fi
            fi

            # If that failed, try WPA3-Personal (SAE), some APs require it
            log_warn "Profile up failed; trying WPA3 (sae) profile..."
            nmcli con delete "$con_name" >/dev/null 2>&1 || true
            if nmcli con add type wifi ifname "$iface" con-name "$con_name" ssid "$ssid" \
                   wifi-sec.key-mgmt sae wifi-sec.psk "$pass" >>"$nm_log" 2>&1; then
                if nmcli con up "$con_name" ifname "$iface" >>"$nm_log" 2>&1; then
                    log_pass "Connected to $ssid via explicit profile (sae)."
                    return 0
                fi
            fi
        else
            # Open network (no passphrase)
            if nmcli con add type wifi ifname "$iface" con-name "$con_name" ssid "$ssid" \
                   wifi-sec.key-mgmt none >>"$nm_log" 2>&1; then
                if nmcli con up "$con_name" ifname "$iface" >>"$nm_log" 2>&1; then
                    log_pass "Connected to open network $ssid."
                    return 0
                fi
            fi
        fi

        log_fail "Failed to connect to $ssid even after explicit key-mgmt profile. See $nm_log"
        return 1
    fi

    # Different error — just bubble up the original failure
    log_fail "nmcli failed to connect to $ssid. See $nm_log"
    return $rc
}

# Connect using wpa_supplicant+udhcpc with retries (returns 0 on success)
wifi_connect_wpa_supplicant() {
    iface="$1"
    ssid="$2"
    pass="$3"
    if command -v wpa_supplicant >/dev/null 2>&1 && command -v udhcpc >/dev/null 2>&1; then
        log_info "Falling back to wpa_supplicant + udhcpc"
        WPA_CONF="/tmp/wpa_supplicant.conf"
        {
            echo "ctrl_interface=/var/run/wpa_supplicant"
            echo "network={"
            echo " ssid=\"$ssid\""
            echo " key_mgmt=WPA-PSK"
            echo " pairwise=CCMP TKIP"
            echo " group=CCMP TKIP"
            echo " psk=\"$pass\""
            echo "}"
        } > "$WPA_CONF"
        killall -q wpa_supplicant 2>/dev/null
        retry_command "wpa_supplicant -B -i \"$iface\" -D nl80211 -c \"$WPA_CONF\" 2>&1 | tee wpa.log" 3 2
        sleep 4
        udhcpc -i "$iface" >/dev/null 2>&1
        sleep 2
        return 0
    fi
    log_error "Neither nmcli nor wpa_supplicant+udhcpc available"
    return 1
}

# Get IPv4 address (returns IP or empty)
wifi_get_ip() {
    iface="$1"
    ip=""
    if command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2; exit}')
    fi
    if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
        ip=$(ip addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
    fi
    echo "$ip"
}

# Log+exit helpers with optional cleanup
log_pass_exit() {
    # Usage: log_pass_exit "$TESTNAME" "Message" cleanup_func arg
    TESTNAME="$1"
    MSG="$2"
    CLEANUP_FUNC="$3"
    CLEANUP_ARG="$4"
    log_pass "$MSG"
    echo "$TESTNAME PASS" > "./$TESTNAME.res"
    if [ -n "$CLEANUP_FUNC" ] && command -v "$CLEANUP_FUNC" >/dev/null 2>&1; then
        "$CLEANUP_FUNC" "$CLEANUP_ARG"
    fi
    exit 0
}

log_fail_exit() {
    # Usage: log_fail_exit "$TESTNAME" "Message" cleanup_func arg
    TESTNAME="$1"
    MSG="$2"
    CLEANUP_FUNC="$3"
    CLEANUP_ARG="$4"
    log_fail "$MSG"
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    if [ -n "$CLEANUP_FUNC" ] && command -v "$CLEANUP_FUNC" >/dev/null 2>&1; then
        "$CLEANUP_FUNC" "$CLEANUP_ARG"
    fi
    exit 1
}

log_skip_exit() {
    # Usage: log_skip_exit "$TESTNAME" "Message" cleanup_func arg
    TESTNAME="$1"
    MSG="$2"
    CLEANUP_FUNC="$3"
    CLEANUP_ARG="$4"
    log_skip "$MSG"
    echo "$TESTNAME SKIP" > "./$TESTNAME.res"
    if [ -n "$CLEANUP_FUNC" ] && command -v "$CLEANUP_FUNC" >/dev/null 2>&1; then
        "$CLEANUP_FUNC" "$CLEANUP_ARG"
    fi
    exit 0
}

# Robust systemd service check: returns 0 if networkd up, 0 if systemd missing, 1 if error
check_systemd_services() {
    # If systemd not present, pass for minimal or kernel-only builds
    if ! command -v systemctl >/dev/null 2>&1; then
        log_info "systemd/systemctl not found (kernel/minimal build). Skipping service checks."
        return 0
    fi
    for service in "$@"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            if ! systemctl is-active --quiet "$service"; then
                log_warn "$service not running. Retrying start..."
                retry_command "systemctl start $service" 3 2
                if ! systemctl is-active --quiet "$service"; then
                    log_fail "$service failed to start after 3 retries."
                    return 1
                else
                    log_pass "$service started after retry."
                fi
            fi
        else
            log_warn "$service not enabled or not found."
        fi
    done
    return 0
}

# Ensure udhcpc default.script exists, create if missing
ensure_udhcpc_script() {
    udhcpc_dir="/usr/share/udhcpc"
    udhcpc_script="$udhcpc_dir/default.script"
    udhcpc_backup="$udhcpc_script.bak"

    if [ ! -d "$udhcpc_dir" ]; then
        mkdir -p "$udhcpc_dir" || return 1
    fi

    # Backup if script already exists and is not a backup yet
    if [ -f "$udhcpc_script" ] && [ ! -f "$udhcpc_backup" ]; then
        cp "$udhcpc_script" "$udhcpc_backup"
    fi

    if [ ! -x "$udhcpc_script" ]; then
        cat > "$udhcpc_script" <<'EOF'
#!/bin/sh
case "$1" in
    deconfig)
        ip addr flush dev "$interface"
        ;;
    renew|bound)
        echo "[INFO] Configuring $interface with IP: $ip/$subnet"
        ip addr flush dev "$interface"
        ip addr add "$ip/$subnet" dev "$interface"
        ip link set "$interface" up
        if [ -n "$router" ]; then
            ip route del default dev "$interface" 2>/dev/null
            ip route add default via "$router" dev "$interface"
        fi
echo "[INFO] Setting DNS to 8.8.8.8"
echo "nameserver 8.8.8.8" > /etc/resolv.conf
        ;;
esac
exit 0
EOF
        chmod +x "$udhcpc_script"
    fi

    echo "$udhcpc_script"
}

# Resotre back the default.script
restore_udhcpc_script() {
    udhcpc_dir="/usr/share/udhcpc"
    udhcpc_script="$udhcpc_dir/default.script"
    udhcpc_backup="$udhcpc_script.bak"

    if [ -f "$udhcpc_backup" ]; then
        mv -f "$udhcpc_backup" "$udhcpc_script"
        echo "[INFO] Restored original udhcpc default.script"
    fi
}

# Bring an interface up or down using available tools
# Usage: bring_interface_up_down <iface> <up|down>
bring_interface_up_down() {
    iface="$1"
    state="$2"
    if command -v ip >/dev/null 2>&1; then
        ip link set "$iface" "$state"
    elif command -v ifconfig >/dev/null 2>&1; then
        if [ "$state" = "up" ]; then
            ifconfig "$iface" up
        else
            ifconfig "$iface" down
        fi
    else
        log_error "No ip or ifconfig tools found to bring $iface $state"
        return 1
    fi
}

is_valid_ipv4() {
    ip="$1"
    [ -n "$ip" ] || return 1
    echo "$ip" | grep -q '^169\.254' && return 1
    return 0
}

iface_link_up() {
    iface="$1"
    [ -n "$iface" ] || return 1

    # Prefer functestlib helpers if present
    if command -v ethIsLinkUp >/dev/null 2>&1; then
        ethIsLinkUp "$iface"
        return $?
    fi
    if command -v is_link_up >/dev/null 2>&1; then
        is_link_up "$iface"
        return $?
    fi

    # Fallback to carrier
    [ -r "/sys/class/net/$iface/carrier" ] || return 1
    [ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" = "1" ]
}

run_ping_check() {
    iface="$1"

    i=1
    while [ "$i" -le "$PING_RETRIES" ]; do
        log_info "Ping attempt $i/$PING_RETRIES: ping -I $iface -c $PING_COUNT -W $PING_WAIT_S $PING_TARGET"
        ping_out="$(ping -I "$iface" -c "$PING_COUNT" -W "$PING_WAIT_S" "$PING_TARGET" 2>&1)"
        ping_rc=$?

        printf '%s\n' "$ping_out" | while IFS= read -r l; do
            [ -n "$l" ] && log_info "[ping:$iface] $l"
        done

        if [ "$ping_rc" -eq 0 ]; then
            return 0
        fi

        log_warn "Ping failed for $iface (rc=$ping_rc) (attempt $i/$PING_RETRIES)"
        i=$((i + 1))
        sleep 2
    done

    return 1
}

wifi_write_wpa_conf() {
    iface="$1"
    ssid="$2"
    pass="$3"
    conf_file="/tmp/wpa_supplicant_${iface}.conf"
    {
        echo "ctrl_interface=/var/run/wpa_supplicant"
        echo "network={"
        echo " ssid=\"$ssid\""
        echo " key_mgmt=WPA-PSK"
        echo " pairwise=CCMP TKIP"
        echo " group=CCMP TKIP"
        echo " psk=\"$pass\""
        echo "}"
    } > "$conf_file"
    echo "$conf_file"
}

# Find the first available WiFi interface (wl* or wlan0), using 'ip' or 'ifconfig'.
# Prints the interface name, or returns non-zero if not found.
get_wifi_interface() {
    WIFI_IF=""

    # Prefer 'ip' if available.
    if command -v ip >/dev/null 2>&1; then
        WIFI_IF=$(ip link | awk -F: '/ wl/ {print $2}' | tr -d ' ' | head -n1)
        if [ -z "$WIFI_IF" ]; then
            WIFI_IF=$(ip link | awk -F: '/^[0-9]+: wl/ {print $2}' | tr -d ' ' | head -n1)
        fi
        if [ -z "$WIFI_IF" ] && ip link show wlan0 >/dev/null 2>&1; then
            WIFI_IF="wlan0"
        fi
    else
        # Fallback to 'ifconfig' if 'ip' is missing.
        if command -v ifconfig >/dev/null 2>&1; then
            WIFI_IF=$(ifconfig -a 2>/dev/null | grep -o '^wl[^:]*' | head -n1)
            if [ -z "$WIFI_IF" ] && ifconfig wlan0 >/dev/null 2>&1; then
                WIFI_IF="wlan0"
            fi
        fi
    fi

    if [ -n "$WIFI_IF" ]; then
        echo "$WIFI_IF"
        return 0
    else
        return 1
    fi
}

# Auto-detect eMMC block device (non-removable, not UFS)
detect_emmc_partition_block() {
    if command -v lsblk >/dev/null 2>&1 && command -v udevadm >/dev/null 2>&1; then
        for part in $(lsblk -lnpo NAME,TYPE | awk '$2 == "part" {print $1}'); do
            if udevadm info --query=all --name="$part" 2>/dev/null | grep -qi "mmcblk"; then
                echo "$part"
                return 0
            fi
        done
    fi

    for part in /dev/mmcblk*p[0-9]*; do
        [ -e "$part" ] || continue
        if command -v udevadm >/dev/null 2>&1 && udevadm info --query=all --name="$part" | grep -qi "mmcblk"; then
            echo "$part"
            return 0
        fi
    done
    return 1
}

# Auto-detect UFS block device (via udev vendor info or path hint)
detect_ufs_partition_block() {
    if command -v lsblk >/dev/null 2>&1 && command -v udevadm >/dev/null 2>&1; then
        for part in $(lsblk -lnpo NAME,TYPE | awk '$2 == "part" {print $1}'); do
            if udevadm info --query=all --name="$part" 2>/dev/null | grep -qi "ufs"; then
                echo "$part"
                return 0
            fi
        done
    fi

    for part in /dev/sd[a-z][0-9]*; do
        [ -e "$part" ] || continue
        if command -v udevadm >/dev/null 2>&1 &&
           udevadm info --query=all --name="$part" 2>/dev/null | grep -qi "ufs"; then
            echo "$part"
            return 0
        fi
    done
    return 1
}

###############################################################################
# scan_dmesg_errors
#
# Only scans *new* dmesg lines for true error patterns (since last test run).
# Keeps a timestamped error log history for each run.
# Handles dmesg with/without timestamps. Cleans up markers/logs if test dir is gone.
# Usage: scan_dmesg_errors "$SCRIPT_DIR" [optional_extra_keywords...]
###############################################################################
scan_dmesg_errors() {
    prefix="$1"
    module_regex="$2"   # e.g. 'qcom_camss|camss|isp'
    exclude_regex="${3:-"dummy regulator|supply [^ ]+ not found|using dummy regulator"}"
    shift 3

    mkdir -p "$prefix"

    DMESG_SNAPSHOT="$prefix/dmesg_snapshot.log"
    DMESG_ERRORS="$prefix/dmesg_errors.log"
    DATE_STAMP=$(date +%Y%m%d-%H%M%S)
    DMESG_HISTORY="$prefix/dmesg_errors_$DATE_STAMP.log"

    # Error patterns (edit as needed for your test coverage)
    err_patterns='Unknown symbol|probe failed|fail(ed)?|error|timed out|not found|invalid|corrupt|abort|panic|oops|unhandled|can.t (start|init|open|allocate|find|register)'

    rm -f "$DMESG_SNAPSHOT" "$DMESG_ERRORS"
    dmesg > "$DMESG_SNAPSHOT" 2>/dev/null

    # 1. Match lines with correct module and error pattern
    # 2. Exclude lines with harmless patterns (using dummy regulator etc)
    grep -iE "^\[[^]]+\][[:space:]]+($module_regex):.*($err_patterns)" "$DMESG_SNAPSHOT" \
        | grep -vEi "$exclude_regex" > "$DMESG_ERRORS" || true

    cp "$DMESG_ERRORS" "$DMESG_HISTORY"

    if [ -s "$DMESG_ERRORS" ]; then
        log_info "dmesg scan: found non-benign module errors in $DMESG_ERRORS (history: $DMESG_HISTORY)"
        while IFS= read -r line; do
            log_info "[dmesg] $line"
        done < "$DMESG_ERRORS"
        return 0
    fi
    log_info "No relevant, non-benign errors for modules [$module_regex] in recent dmesg."
    return 1
}

# wait_for_path <path> [timeout_sec]
wait_for_path() {
    _p="$1"; _t="${2:-3}"
    i=0
    while [ "$i" -lt "$_t" ]; do
        [ -e "$_p" ] && return 0
        sleep 1
        i=$((i+1))
    done
    return 1
}

# ---------------------------------------------------------------------
# Ultra-light DT matchers (no indexing; BusyBox-safe; O(first hit))
# ---------------------------------------------------------------------
DT_ROOT="/proc/device-tree"

# Print matches for EVERY pattern given; return 0 if any matched, else 1.
# Output format (unchanged):
#  - node name match:      "<pattern>: ./path/to/node"
#  - compatible file match:"<pattern>: ./path/to/compatible:vendor,chip[,...]"
dt_confirm_node_or_compatible_all() {
    LC_ALL=C
    any=0

    for pattern in "$@"; do
        pl=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')

        # -------- Pass 1: node name strict match (^pat(@|$)) in .../name files --------
        # BusyBox grep: -r (recursive), -s (quiet errors), -i (CI), -a (treat binary as text),
        # -E (ERE), -l (print file names), -m1 (stop after first match).
        name_file="$(grep -r -s -i -a -E -l -m1 "^${pl}(@|$)" "$DT_ROOT" 2>/dev/null | grep '/name$' -m1 || true)"
        if [ -n "$name_file" ]; then
            rel="${name_file#"$DT_ROOT"/}"
            rel="${rel%/name}"
            log_info "[DTFIND] Node name strict match: /$rel (pattern: $pattern)"
            printf '%s: ./%s\n' "$pattern" "$rel"
            any=1
            continue
        fi

        # -------- Pass 2: compatible matches --------
        # Heuristic:
        #   - If pattern has a comma (e.g. "sony,imx577"), treat it as a full vendor:part token.
        #     We just need the first compatible file that contains that exact substring.
        #   - Else (e.g. "isp", "cam", "camss"), treat as IP family:
        #       token == pat    OR  token ends with -pat   OR  token prefix pat
        #     We still find a small candidate set via grep and vet tokens precisely.
        case "$pattern" in *,*)
            # label as chip (the part after the last comma) to avoid "swapped" look
            chip_label="${pattern##*,}"
            comp_file="$(grep -r -s -i -F -l -m1 -- "$pattern" "$DT_ROOT" 2>/dev/null | grep '/compatible$' -m1 || true)"
            if [ -n "$comp_file" ]; then
                comp_print="$(tr '\0' ' ' <"$comp_file" 2>/dev/null)"
                comp_csv="$(tr '\0' ',' <"$comp_file" 2>/dev/null)"; comp_csv="${comp_csv%,}"
                rel="${comp_file#"$DT_ROOT"/}"
                log_info "[DTFIND] Compatible strict match: /$rel (${comp_print}) (pattern: $pattern)"
                # Label by chip (e.g., "imx577: ./…:sony,imx577")
                printf '%s: ./%s:%s\n' "$chip_label" "$rel" "$comp_csv"
                any=1
                continue
            fi
            ;;
        *)
            cand_list="$(grep -r -s -i -F -l -- "$pattern" "$DT_ROOT" 2>/dev/null | grep '/compatible$' | head -n 64 || true)"
            if [ -n "$cand_list" ]; then
                for comp_file in $cand_list; do
                    hit=0
                    while IFS= read -r tok; do
                        tokl=$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')
                        case "$tokl" in
                            "$pl"|*-"$pl"|"$pl"*) hit=1; break ;;
                        esac
                    done <<EOF
$(tr '\0' '\n' <"$comp_file" 2>/dev/null)
EOF
                    if [ "$hit" -eq 1 ]; then
                        comp_print="$(tr '\0' ' ' <"$comp_file" 2>/dev/null)"
                        comp_csv="$(tr '\0' ',' <"$comp_file" 2>/dev/null)"; comp_csv="${comp_csv%,}"
                        rel="${comp_file#"$DT_ROOT"/}"
                        log_info "[DTFIND] Compatible strict match: /$rel (${comp_print}) (pattern: $pattern)"
                        # Label stays as the generic pattern (isp/cam/camss)
                        printf '%s: ./%s:%s\n' "$pattern" "$rel" "$comp_csv"
                        any=1
                        break
                    fi
                done
            fi
            ;;
        esac
        # if neither pass matched, we stay silent for this pattern
    done

    [ "$any" -eq 1 ]
}

# Back-compat: single-pattern wrapper
dt_confirm_node_or_compatible() {
    dt_confirm_node_or_compatible_all "$@"
}

# Detects and returns the first available media node (e.g., /dev/media0).
# Returns failure if no media nodes are present.
detect_media_node() {
    for node in /dev/media*; do
        if [ -e "$node" ]; then
            printf '%s\n' "$node"
            return 0
        fi
    done
    return 1
}

# Runs the Python pipeline parser with a topology file to emit camera blocks.
# Returns structured per-pipeline output for further processing.
run_camera_pipeline_parser() {
    # Input: path to topo file (e.g., /tmp/cam_topo.txt)
    # Output: emits parse output to stdout
    TOPO_FILE="$1"

    if [ ! -f "$TOPO_FILE" ]; then
        log_error "Topology file $TOPO_FILE not found"
        return 1
    fi

PYTHON_SCRIPT="$TOOLS/camera/parse_media_topology.py"
    if [ ! -x "$PYTHON_SCRIPT" ]; then
        log_error "Camera pipeline parser script not found at $PYTHON_SCRIPT"
        return 1
    fi

    log_info "Invoking camera pipeline parser with $TOPO_FILE"
    python3 "$PYTHON_SCRIPT" "$TOPO_FILE"
}

# Shortcut to detect a media node, dump topology, and run the parser on it.
# Intended for quick standalone camera pipeline detection.
get_camera_pipeline_blocks() {
    TOPO_FILE="/tmp/parse_topo.$$"
    MEDIA_NODE=$(detect_media_node)
    if [ -z "$MEDIA_NODE" ]; then
        echo "[ERROR] Failed to detect media node" >&2
        return 1
    fi
    media-ctl -p -d "$MEDIA_NODE" >"$TOPO_FILE" 2>/dev/null
    PARSE_SCRIPT="${TOOLS}/camera/parse_media_topology.py"
    if [ ! -f "$PARSE_SCRIPT" ]; then
        echo "[ERROR] Python script $PARSE_SCRIPT not found" >&2
        rm -f "$TOPO_FILE"
        return 1
    fi
    python3 "$PARSE_SCRIPT" "$TOPO_FILE"
    ret=$?
    rm -f "$TOPO_FILE"
    return "$ret"
}

# Parses a single pipeline block file into shell variables and lists.
# Each key-value line sets up variables for media-ctl or yavta operations.
parse_pipeline_block() {
    block_file="$1"

    # Unset and export all variables that will be assigned
    unset SENSOR VIDEO FMT YAVTA_DEV YAVTA_FMT YAVTA_W YAVTA_H
    unset MEDIA_CTL_V_LIST MEDIA_CTL_L_LIST
    unset YAVTA_CTRL_PRE_LIST YAVTA_CTRL_LIST YAVTA_CTRL_POST_LIST

    export SENSOR VIDEO FMT YAVTA_DEV YAVTA_FMT YAVTA_W YAVTA_H
    export MEDIA_CTL_V_LIST MEDIA_CTL_L_LIST
    export YAVTA_CTRL_PRE_LIST YAVTA_CTRL_LIST YAVTA_CTRL_POST_LIST

    while IFS= read -r bline || [ -n "$bline" ]; do
        key=$(printf "%s" "$bline" | awk -F':' '{print $1}')
        val=$(printf "%s" "$bline" | sed 's/^[^:]*://')
        case "$key" in
            SENSOR) SENSOR=$val ;;
            VIDEO) VIDEO=$val ;;
            YAVTA_DEV) YAVTA_DEV=$val ;;
            YAVTA_W) YAVTA_W=$val ;;
            YAVTA_H) YAVTA_H=$val ;;
            YAVTA_FMT) YAVTA_FMT=$val ;;
            MEDIA_CTL_V) MEDIA_CTL_V_LIST="$MEDIA_CTL_V_LIST
$val" ;;
            MEDIA_CTL_L) MEDIA_CTL_L_LIST="$MEDIA_CTL_L_LIST
$val" ;;
            YAVTA_CTRL_PRE) YAVTA_CTRL_PRE_LIST="$YAVTA_CTRL_PRE_LIST
$val" ;;
            YAVTA_CTRL) YAVTA_CTRL_LIST="$YAVTA_CTRL_LIST
$val" ;;
            YAVTA_CTRL_POST) YAVTA_CTRL_POST_LIST="$YAVTA_CTRL_POST_LIST
$val" ;;
        esac
    done < "$block_file"

    # Fallback: if VIDEO is not emitted, use YAVTA_DEV
    if [ -z "$VIDEO" ] && [ -n "$YAVTA_DEV" ]; then
        VIDEO="$YAVTA_DEV"
    fi
}

# Applies media configuration (format and links) using media-ctl from parsed pipeline block.
# Mirrors manual flow:
#  - Global reset (prefer 'reset', fallback to -r)
#  - Pads use MBUS code (never '*P'); if USER_FORMAT ends with P, strip P for pads
#  - Strip any 'field:*' tokens from -V lines
#  - Apply ONLY these 2 links:
#      csiphy*:1 -> csid*:0
#      csid*:1   -> *rdi*:0
#  - Small settle before capture
configure_pipeline_block() {
    MEDIA_NODE="$1"
    USER_FORMAT="$2"
 
    # Reset graph
    if ! media-ctl -d "$MEDIA_NODE" reset >/dev/null 2>&1; then
        media-ctl -d "$MEDIA_NODE" -r >/dev/null 2>&1 || true
    fi
 
    # Apply pad formats (MBUS, never *P). Also strip 'field:*'.
    printf "%s\n" "$MEDIA_CTL_V_LIST" | while IFS= read -r vline || [ -n "$vline" ]; do
        [ -z "$vline" ] && continue
 
        curfmt="$(printf "%s" "$vline" | sed -n 's/.*fmt:\([^/]*\)\/.*/\1/p')"
        newfmt="$curfmt"
 
        if [ -n "$USER_FORMAT" ]; then
            case "$USER_FORMAT" in
                *P) newfmt="${USER_FORMAT%P}" ;;
                 *) newfmt="$USER_FORMAT" ;;
            esac
        else
            case "$curfmt" in
                *P) newfmt="${curfmt%P}" ;;
                 *) newfmt="$curfmt" ;;
            esac
        fi
 
        vline_new="$(printf "%s" "$vline" | sed -E "s/fmt:[^/]+/fmt:${newfmt}/")"
        vline_new="$(printf "%s" "$vline_new" | sed -E 's/ field:[^]]*//g')"
 
        if [ -n "$YAVTA_W" ] && [ -n "$YAVTA_H" ]; then
            vline_new="$(printf "%s" "$vline_new" \
                | sed -E "s/(fmt:[^/]+\/)[0-9]+x[0-9]+/\1${YAVTA_W}x${YAVTA_H}/")"
        fi
 
        media-ctl -d "$MEDIA_NODE" -V "$vline_new" >/dev/null 2>&1
    done
 
    # Apply ONLY the two links (no fragile case patterns; avoids ShellCheck parse issues).
    printf "%s\n" "$MEDIA_CTL_L_LIST" | while IFS= read -r lline || [ -n "$lline" ]; do
        [ -z "$lline" ] && continue
        sline="$(printf "%s" "$lline" | tr -d '"')"
        if [ "${sline#*csiphy*:1->*csid*:0*}" != "$sline" ]; then
            media-ctl -d "$MEDIA_NODE" -l "$lline" >/dev/null 2>&1
        elif [ "${sline#*csid*:1->*rdi*:0*}" != "$sline" ]; then
            media-ctl -d "$MEDIA_NODE" -l "$lline" >/dev/null 2>&1
        else
            : # ignore others
        fi
    done
 
    sleep 0.15
}
 
# Executes yavta capture with the same semantics as your manual call.
# Return codes:
#   0: PASS (>=1 frame captured)
#   1: FAIL (capture error)
#   2: SKIP (unsupported format)
#   3: SKIP (missing data)
execute_capture_block() {
    FRAMES="$1"
    FORMAT="$2"

    [ -z "$YAVTA_DEV" ] && return 3
    [ -z "$FORMAT" ] && return 3
    [ -z "$YAVTA_W" ] && return 3
    [ -z "$YAVTA_H" ] && return 3

    # Build args as separate, quoted tokens (fixes SC2086 safely)
    SFLAG="-s"
    SRES="${YAVTA_W}x${YAVTA_H}"

    CAPS="$(v4l2-ctl -D -d "$YAVTA_DEV" 2>/dev/null || true)"
    BFLAG="-B"
    if printf '%s\n' "$CAPS" | grep -qi 'MPlane'; then
        BMODE="capture-mplane"
    else
        BMODE="capture"
    fi

    sleep 0.12

    do_capture_once() {
        # $1 = mode (capture|capture-mplane)
        yavta "$BFLAG" "$1" -c -I -n "$FRAMES" -f "$FORMAT" "$SFLAG" "$SRES" \
              -F "$YAVTA_DEV" --capture="$FRAMES" --file='frame-#.bin' 2>&1
        return $?
    }

    OUT="$(do_capture_once "$BMODE")"; RET=$?
    if [ $RET -eq 0 ] && echo "$OUT" | grep -q "Captured [1-9][0-9]* frames"; then
        return 0
    fi
    echo "$OUT" | grep -qi "Unsupported video format" && return 2

    sleep 0.10
    OUT="$(do_capture_once "$BMODE")"; RET=$?
    if [ $RET -eq 0 ] && echo "$OUT" | grep -q "Captured [1-9][0-9]* frames"; then
        return 0
    fi
    echo "$OUT" | grep -qi "Unsupported video format" && return 2

    # Plane flip
    case "$BMODE" in
        capture) FLIPMODE="capture-mplane" ;;
        *)       FLIPMODE="capture" ;;
    esac
    OUT="$(do_capture_once "$FLIPMODE")"; RET=$?
    if [ $RET -eq 0 ] && echo "$OUT" | grep -q "Captured [1-9][0-9]* frames"; then
        return 0
    fi
    echo "$OUT" | grep -qi "Unsupported video format" && return 2

    # Try P<->non-P sibling of FORMAT
    case "$FORMAT" in *P) ALT="${FORMAT%P}" ;; *) ALT="${FORMAT}P" ;; esac
    FORMAT="$ALT"
    OUT="$(do_capture_once "$BMODE")"; RET=$?
    if [ $RET -eq 0 ] && echo "$OUT" | grep -q "Captured [1-9][0-9]* frames"; then
        return 0
    fi
    echo "$OUT" | grep -qi "Unsupported video format" && return 2

    OUT="$(do_capture_once "$FLIPMODE")"; RET=$?
    if [ $RET -eq 0 ] && echo "$OUT" | grep -q "Captured [1-9][0-9]* frames"; then
        return 0
    fi
    echo "$OUT" | grep -qi "Unsupported video format" && return 2

    return 1
}

print_planned_commands() {
    media_node="$1"
    pixfmt="$2"
 
    # Pads should use MBUS code (strip trailing 'P' if present)
    padfmt="$(printf '%s' "$pixfmt" | sed 's/P$//')"
 
    log_info "[CI] Planned sequence:"
    log_info " media-ctl -d $media_node --reset"
 
    # Pad formats: show MBUS (non-P) on -V lines
    if [ -n "$MEDIA_CTL_V_LIST" ]; then
        printf '%s\n' "$MEDIA_CTL_V_LIST" | while IFS= read -r vline; do
            [ -z "$vline" ] && continue
            vline_out="$(printf '%s' "$vline" | sed -E "s/fmt:[^/]+\/([0-9]+x[0-9]+)/fmt:${padfmt}\/\1/g")"
            log_info " media-ctl -d $media_node -V '$vline_out'"
        done
    fi
 
    # Links unchanged
    if [ -n "$MEDIA_CTL_L_LIST" ]; then
        printf '%s\n' "$MEDIA_CTL_L_LIST" | while IFS= read -r lline; do
            [ -z "$lline" ] && continue
            log_info " media-ctl -d $media_node -l '$lline'"
        done
    fi
 
    # Any pre/post yavta register writes (unchanged)
    if [ -n "$YAVTA_CTRL_PRE_LIST" ]; then
        printf '%s\n' "$YAVTA_CTRL_PRE_LIST" | while IFS= read -r ctrl; do
            [ -z "$ctrl" ] && continue
            dev="$(printf '%s' "$ctrl" | awk '{print $1}')"
            reg="$(printf '%s' "$ctrl" | awk '{print $2}')"
            val="$(printf '%s' "$ctrl" | awk '{print $3}')"
            [ -n "$dev" ] && [ -n "$reg" ] && [ -n "$val" ] && \
              log_info " yavta --no-query -w '$reg $val' $dev"
        done
    fi
 
    size_arg=""
    if [ -n "$YAVTA_W" ] && [ -n "$YAVTA_H" ]; then
        size_arg="-s ${YAVTA_W}x${YAVTA_H}"
    fi
    if [ -n "$YAVTA_DEV" ]; then
        # Show pixel format (SRGGB10P) only on the video node
        log_info " yavta -B capture-mplane -c -I -n $FRAMES -f $pixfmt $size_arg -F $YAVTA_DEV --capture=$FRAMES --file='frame-#.bin'"
    fi
 
    if [ -n "$YAVTA_CTRL_POST_LIST" ]; then
        printf '%s\n' "$YAVTA_CTRL_POST_LIST" | while IFS= read -r ctrl; do
            [ -z "$ctrl" ] && continue
            dev="$(printf '%s' "$ctrl" | awk '{print $1}')"
            reg="$(printf '%s' "$ctrl" | awk '{print $2}')"
            val="$(printf '%s' "$ctrl" | awk '{print $3}')"
            [ -n "$dev" ] && [ -n "$reg" ] && [ -n "$val" ] && \
              log_info " yavta --no-query -w '$reg $val' $dev"
        done
    fi
}

log_soc_info() {
    m=""; s=""; pv=""
    [ -r /sys/devices/soc0/machine ] && m="$(cat /sys/devices/soc0/machine 2>/dev/null)"
    [ -r /sys/devices/soc0/soc_id ] && s="$(cat /sys/devices/soc0/soc_id 2>/dev/null)"
    [ -r /sys/devices/soc0/platform_version ] && pv="$(cat /sys/devices/soc0/platform_version 2>/dev/null)"
    [ -n "$m" ] && log_info "SoC.machine: $m"
    [ -n "$s" ] && log_info "SoC.soc_id: $s"
    [ -n "$pv" ] && log_info "SoC.platform_version: $pv"
}

###############################################################################
# Platform detection (SoC / Target / Machine / OS) — POSIX, no sourcing files
# Sets & exports:
#   PLATFORM_KERNEL, PLATFORM_ARCH, PLATFORM_UNAME_S, PLATFORM_HOSTNAME
#   PLATFORM_SOC_MACHINE, PLATFORM_SOC_ID, PLATFORM_SOC_FAMILY
#   PLATFORM_DT_MODEL, PLATFORM_DT_COMPAT
#   PLATFORM_OS_LIKE, PLATFORM_OS_NAME
#   PLATFORM_TARGET, PLATFORM_MACHINE
###############################################################################
detect_platform() {
    # --- Basic uname/host ---
    PLATFORM_KERNEL="$(uname -r 2>/dev/null)"
    PLATFORM_ARCH="$(uname -m 2>/dev/null)"
    PLATFORM_UNAME_S="$(uname -s 2>/dev/null)"
    PLATFORM_HOSTNAME="$(hostname 2>/dev/null)"
 
    # --- soc0 details ---
    if [ -r /sys/devices/soc0/machine ]; then
        PLATFORM_SOC_MACHINE="$(cat /sys/devices/soc0/machine 2>/dev/null)"
    else
        PLATFORM_SOC_MACHINE=""
    fi
 
    if [ -r /sys/devices/soc0/soc_id ]; then
        PLATFORM_SOC_ID="$(cat /sys/devices/soc0/soc_id 2>/dev/null)"
    else
        PLATFORM_SOC_ID=""
    fi
 
    if [ -r /sys/devices/soc0/family ]; then
        PLATFORM_SOC_FAMILY="$(cat /sys/devices/soc0/family 2>/dev/null)"
    else
        PLATFORM_SOC_FAMILY=""
    fi
 
    # --- Device Tree model / compatible (strip NULs) ---
    if [ -r /proc/device-tree/model ]; then
        PLATFORM_DT_MODEL="$(tr -d '\000' </proc/device-tree/model 2>/dev/null | head -n 1)"
    else
        PLATFORM_DT_MODEL=""
    fi
 
    PLATFORM_DT_COMPAT=""
    if [ -d /proc/device-tree ]; then
        for f in /proc/device-tree/compatible /proc/device-tree/*/compatible; do
            if [ -f "$f" ]; then
                PLATFORM_DT_COMPAT="$(tr -d '\000' <"$f" 2>/dev/null | tr '\n' ' ')"
                break
            fi
        done
    fi
 
    # --- OS (parse, do not source /etc/os-release) ---
    PLATFORM_OS_LIKE=""
    PLATFORM_OS_NAME=""
    if [ -r /etc/os-release ]; then
        PLATFORM_OS_LIKE="$(
            awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null
        )"
        if [ -z "$PLATFORM_OS_LIKE" ]; then
            PLATFORM_OS_LIKE="$(
                awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null
            )"
        fi
        PLATFORM_OS_NAME="$(
            awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null
        )"
    fi
 
    # --- Target guess (mutually-exclusive; generic names only) ---
    lc_compat="$(printf '%s %s' "$PLATFORM_DT_MODEL" "$PLATFORM_DT_COMPAT" \
                 | tr '[:upper:]' '[:lower:]')"
 
    case "$lc_compat" in
        # Kodiak: qcs6490 / RB3 Gen2
        *qcs6490*|*kodiak*|*rb3gen2*|*rb3-gen2*|*rb3*gen2*)
            PLATFORM_TARGET="Kodiak"
            ;;
        # LeMans family: qcs9100, qcs9075, SA8775P, IQ-9075-EVK (accept 'lemand' too)
        *qcs9100*|*qcs9075*|*lemans*|*lemand*|*sa8775p*|*iq-9075-evk*)
            PLATFORM_TARGET="LeMans"
            ;;
        # Monaco: qcs8300
        *qcs8300*|*monaco*)
            PLATFORM_TARGET="Monaco"
            ;;
        # Agatti: QRB2210 RB1 Core Kit
        *qrb2210*|*agatti*|*rb1-core-kit*)
            PLATFORM_TARGET="Agatti"
            ;;
        # Talos: QCS615 ADP Air
        *qcs615*|*talos*|*adp-air*)
            PLATFORM_TARGET="Talos"
            ;;
        *)
            PLATFORM_TARGET="unknown"
            ;;
    esac
 
    # --- Human-friendly machine name ---
    if [ -n "$PLATFORM_DT_MODEL" ]; then
        PLATFORM_MACHINE="$PLATFORM_DT_MODEL"
    else
        if [ -n "$PLATFORM_SOC_MACHINE" ]; then
            PLATFORM_MACHINE="$PLATFORM_SOC_MACHINE"
        else
            PLATFORM_MACHINE="$PLATFORM_HOSTNAME"
        fi
    fi
 
    # Export for callers (and to silence SC2034 in this file)
    export \
      PLATFORM_KERNEL PLATFORM_ARCH PLATFORM_UNAME_S PLATFORM_HOSTNAME \
      PLATFORM_SOC_MACHINE PLATFORM_SOC_ID PLATFORM_SOC_FAMILY \
      PLATFORM_DT_MODEL PLATFORM_DT_COMPAT PLATFORM_OS_LIKE PLATFORM_OS_NAME \
      PLATFORM_TARGET PLATFORM_MACHINE
 
    return 0
}

# ---------- minimal root / FS helpers (Yocto-safe, no underscores) ----------
isroot() { uid="$(id -u 2>/dev/null || echo 1)"; [ "$uid" -eq 0 ]; }

iswritabledir() { d="$1"; [ -d "$d" ] && [ -w "$d" ]; }

mountpointfor() {
  p="$1"
  awk -v p="$p" '
    BEGIN{best="/"; bestlen=1}
    {
      mp=$2
      if (index(p, mp)==1 && length(mp)>bestlen) { best=mp; bestlen=length(mp) }
    }
    END{print best}
  ' /proc/mounts 2>/dev/null
}

tryremountrw() {
  path="$1"
  mp="$(mountpointfor "$path")"
  [ -n "$mp" ] || mp="/"
  if mount -o remount,rw "$mp" 2>/dev/null; then
    printf '%s\n' "$mp"
    return 0
  fi
  return 1
}

# ---------------- DSP autolink (generic, sudo-free, no underscores) ----------------
# Env:
#   FASTRPC_DSP_AUTOLINK=yes|no    (default: yes)
#   FASTRPC_DSP_SRC=/path/to/dsp   (force a source dir)
#   FASTRPC_AUTOREMOUNT=yes|no     (default: no)  allow remount rw if needed
#   FASTRPC_AUTOREMOUNT_RO=yes|no  (default: yes) remount ro after linking
ensure_usr_lib_dsp_symlinks() {
  [ "${FASTRPC_DSP_AUTOLINK:-yes}" = "yes" ] || { log_info "DSP autolink disabled"; return 0; }
 
  dsptgt="/usr/lib/dsp"
 
  # If already populated, skip
  if [ -d "$dsptgt" ]; then
    if find "$dsptgt" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      log_info "$dsptgt already populated, skipping DSP autolink"
      return 0
    fi
  fi
 
  # Choose source: explicit env wins, else discover
  if [ -n "${FASTRPC_DSP_SRC:-}" ] && [ -d "$FASTRPC_DSP_SRC" ]; then
    dspsrc="$FASTRPC_DSP_SRC"
  else
    # Best-effort platform hints (detect_platform may exist in functestlib)
    if command -v detect_platform >/dev/null 2>&1; then detect_platform >/dev/null 2>&1 || true; fi
    hintstr="$(printf '%s %s %s %s' \
      "${PLATFORM_SOC_ID:-}" "${PLATFORM_DT_MODEL:-}" "${PLATFORM_DT_COMPAT:-}" "${PLATFORM_TARGET:-}" \
      | tr '[:upper:]' '[:lower:]')"
 
    candidateslist="$(find /usr/share/qcom -maxdepth 6 -type d -name dsp 2>/dev/null | sort)"
    best=""; bestscore=-1; bestcount=-1
    IFS='
'
    for d in $candidateslist; do
      [ -d "$d" ] || continue
      if ! find "$d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        continue
      fi
      score=0
      pathlc="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
      for tok in $hintstr; do
        [ -n "$tok" ] || continue
        case "$pathlc" in *"$tok"*) score=$((score+1));; esac
      done
      cnt="$(find "$d" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c | tr -d ' ')"
      if [ "$score" -gt "$bestscore" ] || { [ "$score" -eq "$bestscore" ] && [ "$cnt" -gt "$bestcount" ]; }; then
        best="$d"; bestscore="$score"; bestcount="$cnt"
      fi
    done
    unset IFS
    dspsrc="$best"
  fi
 
  if [ -z "$dspsrc" ]; then
    log_warn "No DSP skeleton source found under /usr/share/qcom, skipping autolink."
    return 0
  fi
 
  # Must be root on Yocto (no sudo). If not root, skip safely.
  if ! isroot; then
    log_warn "Not root; cannot write to $dsptgt on Yocto (no sudo). Skipping DSP autolink."
    return 0
  fi
 
  # Ensure target dir exists; handle read-only rootfs if requested
  remounted=""
  mountpt=""
  if ! mkdir -p "$dsptgt" 2>/dev/null; then
    if [ "${FASTRPC_AUTOREMOUNT:-no}" = "yes" ]; then
      mountpt="$(tryremountrw "$dsptgt")" || {
        log_warn "Rootfs read-only and remount failed, skipping DSP autolink."
        return 0
      }
      remounted="yes"
      if ! mkdir -p "$dsptgt" 2>/dev/null; then
        log_warn "mkdir -p $dsptgt still failed after remount, skipping."
        if [ -n "$mountpt" ] && [ "${FASTRPC_AUTOREMOUNT_RO:-yes}" = "yes" ]; then
          mount -o remount,ro "$mountpt" 2>/dev/null || true
        fi
        return 0
      fi
    else
      log_warn "Rootfs likely read-only. Set FASTRPC_AUTOREMOUNT=yes to remount rw automatically."
      return 0
    fi
  fi
 
  # If something appeared meanwhile, stop (idempotent)
  if find "$dsptgt" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    log_info "$dsptgt now contains entries, not linking from $dspsrc"
    if [ -n "$remounted" ] && [ -n "$mountpt" ] && [ "${FASTRPC_AUTOREMOUNT_RO:-yes}" = "yes" ]; then
      mount -o remount,ro "$mountpt" 2>/dev/null || true
    fi
    return 0
  fi
 
  # Link both files and directories; don't clobber existing names
  log_info "Linking DSP artifacts from: $dspsrc → $dsptgt"
  linked=0
  for f in "$dspsrc"/*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    if [ ! -e "$dsptgt/$base" ]; then
      if ln -s "$f" "$dsptgt/$base" 2>/dev/null; then
        linked=$((linked+1))
      else
        log_warn "ln -s failed: $f"
      fi
    fi
  done
 
  # Final visibility + sanity
  if find "$dsptgt" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    log_info "DSP autolink complete ($linked link(s))"
    find "$dsptgt" \
      -mindepth 1 \
      -maxdepth 1 \
      -printf '%M %u %g %6s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null \
      | sed 's/^/[INFO] /' \
      || true
  else
    log_warn "DSP autolink finished but $dsptgt is still empty, source may contain only nested content or FS is RO."
  fi
 
  # Optionally restore read-only
  if [ -n "$remounted" ] && [ -n "$mountpt" ] && [ "${FASTRPC_AUTOREMOUNT_RO:-yes}" = "yes" ]; then
    mount -o remount,ro "$mountpt" 2>/dev/null || true
  fi
}

# --- Ensure rootfs has minimum size (defaults to 2GiB) -----------------------
# Usage: ensure_rootfs_min_size [min_gib]
# - Checks / size (df -P /) in KiB. If < min, runs resize2fs on the rootfs device.
# - Logs to $LOG_DIR/resize2fs.log if LOG_DIR is set, else /tmp/resize2fs.log.
ensure_rootfs_min_size() {
    min_gib="${1:-2}"
    min_kb=$((min_gib*1024*1024))

    total_kb="$(df -P / 2>/dev/null | awk 'NR==2{print $2}')"
    [ -n "$total_kb" ] || { log_warn "df check failed; skipping resize."; return 0; }

    if [ "$total_kb" -ge "$min_kb" ] 2>/dev/null; then
        log_info "Rootfs size OK (>=${min_gib}GiB)."
        return 0
    fi

    # Pick root device: prefer by-partlabel/rootfs, else actual source of /
    root_dev="/dev/disk/by-partlabel/rootfs"
    if [ ! -e "$root_dev" ]; then
        if command -v findmnt >/dev/null 2>&1; then
            root_dev="$(findmnt -n -o SOURCE / 2>/dev/null | head -n1)"
        else
            root_dev="$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null)"
        fi
    fi

    # Detect filesystem type robustly
    fstype=""
    if command -v blkid >/dev/null 2>&1; then
        fstype="$(blkid -o value -s TYPE "$root_dev" 2>/dev/null | head -n1)"
        case "$fstype" in
            *TYPE=*)
                fstype="$(printf '%s' "$fstype" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')"
                ;;
        esac
        if [ -z "$fstype" ] && command -v lsblk >/dev/null 2>&1; then
            fstype="$(lsblk -no FSTYPE "$root_dev" 2>/dev/null | head -n1)"
        fi
        if [ -z "$fstype" ]; then
            fstype="$(blkid "$root_dev" 2>/dev/null | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')"
        fi
        case "$fstype" in
            ext2|ext3|ext4) : ;;
            *)
                log_warn "Rootfs type '${fstype:-unknown}' not ext*, skipping resize."
                return 0
                ;;
        esac
    fi

    log_dir="${LOG_DIR:-/tmp}"
    mkdir -p "$log_dir" 2>/dev/null || true

    if command -v resize2fs >/dev/null 2>&1; then
        mib="$(printf '%s\n' "$total_kb" | awk '{printf "%d",$1/1024}')"
        log_info "Rootfs <${min_gib}GiB (${mib} MiB). Resizing filesystem on $root_dev ..."
        if resize2fs "$root_dev" >>"$log_dir/resize2fs.log" 2>&1; then
            log_pass "resize2fs completed on $root_dev (see $log_dir/resize2fs.log)."
        else
            log_warn "resize2fs failed on $root_dev (see $log_dir/resize2fs.log)."
        fi
    else
        log_warn "resize2fs not available; skipping resize."
    fi
    return 0
}
# ---- Connectivity probe (0 OK, 2 IP/no-internet, 1 no IP) ----
# Env overrides:
#   NET_PROBE_ROUTE_IP=1.1.1.1
#   NET_PING_HOST=8.8.8.8
check_network_status_rc() {
    net_probe_route_ip="${NET_PROBE_ROUTE_IP:-1.1.1.1}"
    net_ping_host="${NET_PING_HOST:-8.8.8.8}"

    if command -v ip >/dev/null 2>&1; then
        net_ip_addr="$(ip -4 route get "$net_probe_route_ip" 2>/dev/null \
            | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
        if [ -z "$net_ip_addr" ]; then
            net_ip_addr="$(ip -o -4 addr show scope global up 2>/dev/null \
                | awk 'NR==1{split($4,a,"/"); print a[1]}')"
        fi
    else
        net_ip_addr=""
    fi

    if [ -n "$net_ip_addr" ]; then
        if command -v ping >/dev/null 2>&1; then
            if ping -c 1 -W 2 "$net_ping_host" >/dev/null 2>&1 \
               || ping -c 1 -w 2 "$net_ping_host" >/dev/null 2>&1; then
                unset net_probe_route_ip net_ping_host net_ip_addr
                return 0
            fi
            unset net_probe_route_ip net_ping_host net_ip_addr
            return 2
        else
            unset net_probe_route_ip net_ping_host net_ip_addr
            return 2
        fi
    fi

    unset net_probe_route_ip net_ping_host net_ip_addr
    return 1
}

# ---- Interface snapshot (INFO log only) ----
net_log_iface_snapshot() {
    net_ifc="$1"
    [ -n "$net_ifc" ] || { unset net_ifc; return 0; }

    net_admin="DOWN"
    net_oper="unknown"
    net_carrier="0"
    net_ip="none"

    if command -v ip >/dev/null 2>&1 && ip -o link show "$net_ifc" >/dev/null 2>&1; then
        if ip -o link show "$net_ifc" | awk -F'[<>]' '{print $2}' | grep -qw UP; then
            net_admin="UP"
        fi
    fi
    [ -r "/sys/class/net/$net_ifc/operstate" ] && net_oper="$(cat "/sys/class/net/$net_ifc/operstate" 2>/dev/null)"
    [ -r "/sys/class/net/$net_ifc/carrier"   ] && net_carrier="$(cat "/sys/class/net/$net_ifc/carrier"   2>/dev/null)"

    if command -v get_ip_address >/dev/null 2>&1; then
        net_ip="$(get_ip_address "$net_ifc" 2>/dev/null)"
        [ -n "$net_ip" ] || net_ip="none"
    fi

    log_info "[NET] ${net_ifc}: admin=${net_admin} oper=${net_oper} carrier=${net_carrier} ip=${net_ip}"

    unset net_ifc net_admin net_oper net_carrier net_ip
}

# ---- Bring the system online if possible (0 OK, 2 IP/no-internet, 1 no IP) ----
ensure_network_online() {
    check_network_status_rc; net_rc=$?
    if [ "$net_rc" -eq 0 ]; then
        ensure_reasonable_clock || log_warn "Proceeding in limited-network mode."
        unset net_rc
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && command -v check_systemd_services >/dev/null 2>&1; then
        check_systemd_services NetworkManager systemd-networkd connman || true
    fi

    net_had_any_ip=0

    # -------- Ethernet pass --------
    net_ifaces=""
    if command -v get_ethernet_interfaces >/dev/null 2>&1; then
        net_ifaces="$(get_ethernet_interfaces 2>/dev/null)"
    fi

    for net_ifc in $net_ifaces; do
        net_log_iface_snapshot "$net_ifc"

        if command -v is_link_up >/dev/null 2>&1; then
            if ! is_link_up "$net_ifc"; then
                log_info "[NET] ${net_ifc}: link=down → skipping DHCP"
                continue
            fi
        fi

        log_info "[NET] ${net_ifc}: bringing up and requesting DHCP..."
        if command -v bringup_interface >/dev/null 2>&1; then
            bringup_interface "$net_ifc" 2 2 || true
        fi

        if command -v run_dhcp_client >/dev/null 2>&1; then
            run_dhcp_client "$net_ifc" 10 >/dev/null 2>&1 || true
        elif command -v try_dhcp_client_safe >/dev/null 2>&1; then
            try_dhcp_client_safe "$net_ifc" 8 || true
        fi

        net_log_iface_snapshot "$net_ifc"

        check_network_status_rc; net_rc=$?
        case "$net_rc" in
            0)
                log_pass "[NET] ${net_ifc}: internet reachable"
                ensure_reasonable_clock || log_warn "Proceeding in limited-network mode."
                unset net_ifaces net_ifc net_rc net_had_any_ip
                return 0
                ;;
            2)
                log_warn "[NET] ${net_ifc}: IP assigned but internet not reachable"
                net_had_any_ip=1
                ;;
            1)
                log_info "[NET] ${net_ifc}: still no IP after DHCP attempt"
                ;;
        esac
    done

    # -------- Wi-Fi pass (with bounded retry) --------
    net_wifi=""
    if command -v get_wifi_interface >/dev/null 2>&1; then
        net_wifi="$(get_wifi_interface 2>/dev/null || echo "")"
    fi
    if [ -n "$net_wifi" ]; then
        net_log_iface_snapshot "$net_wifi"
        log_info "[NET] ${net_wifi}: bringing up Wi-Fi..."

        if command -v bringup_interface >/dev/null 2>&1; then
            bringup_interface "$net_wifi" 2 2 || true
        fi

        net_creds=""
        if command -v get_wifi_credentials >/dev/null 2>&1; then
            net_creds="$(get_wifi_credentials "" "" 2>/dev/null || true)"
        fi

        # ---- New: retry knobs (env-overridable) ----
        wifi_max_attempts="${NET_WIFI_RETRIES:-2}"
        wifi_retry_delay="${NET_WIFI_RETRY_DELAY:-5}"
        if [ -z "$wifi_max_attempts" ] || [ "$wifi_max_attempts" -lt 1 ] 2>/dev/null; then
            wifi_max_attempts=1
        fi
        if [ -z "$wifi_retry_delay" ] || [ "$wifi_retry_delay" -lt 0 ] 2>/dev/null; then
            wifi_retry_delay=0
        fi

        wifi_attempt=1
        while [ "$wifi_attempt" -le "$wifi_max_attempts" ]; do
            if [ "$wifi_max_attempts" -gt 1 ]; then
                log_info "[NET] ${net_wifi}: Wi-Fi attempt ${wifi_attempt}/${wifi_max_attempts}"
            fi

            if [ -n "$net_creds" ]; then
                net_ssid="$(printf '%s\n' "$net_creds" | awk '{print $1}')"
                net_pass="$(printf '%s\n' "$net_creds" | awk '{print $2}')"
                log_info "[NET] ${net_wifi}: trying nmcli for SSID='${net_ssid}'"
                if command -v wifi_connect_nmcli >/dev/null 2>&1; then
                    wifi_connect_nmcli "$net_wifi" "$net_ssid" "$net_pass" || true
                fi

                # If nmcli brought us up, do NOT fall back to wpa_supplicant
                check_network_status_rc; net_rc=$?
                if [ "$net_rc" -ne 0 ]; then
                    log_info "[NET] ${net_wifi}: falling back to wpa_supplicant + DHCP"
                    if command -v wifi_connect_wpa_supplicant >/dev/null 2>&1; then
                        wifi_connect_wpa_supplicant "$net_wifi" "$net_ssid" "$net_pass" || true
                    fi
                    if command -v run_dhcp_client >/dev/null 2>&1; then
                        run_dhcp_client "$net_wifi" 10 >/dev/null 2>&1 || true
                    fi
                fi
            else
                log_info "[NET] ${net_wifi}: no credentials provided → DHCP only"
                if command -v run_dhcp_client >/dev/null 2>&1; then
                    run_dhcp_client "$net_wifi" 10 >/dev/null 2>&1 || true
                fi
            fi

            net_log_iface_snapshot "$net_wifi"
            check_network_status_rc; net_rc=$?
            case "$net_rc" in
                0)
                    log_pass "[NET] ${net_wifi}: internet reachable"
                    ensure_reasonable_clock || log_warn "Proceeding in limited-network mode."
                    unset net_wifi net_ifaces net_ifc net_rc net_had_any_ip net_creds net_ssid net_pass wifi_attempt wifi_max_attempts wifi_retry_delay
                    return 0
                    ;;
                2)
                    log_warn "[NET] ${net_wifi}: IP assigned but internet not reachable"
                    net_had_any_ip=1
                    ;;
                1)
                    log_info "[NET] ${net_wifi}: still no IP after connect/DHCP attempt"
                    ;;
            esac

            # If not last attempt, cooldown + cleanup before retry
            if [ "$wifi_attempt" -lt "$wifi_max_attempts" ]; then
                if command -v wifi_cleanup >/dev/null 2>&1; then
                    wifi_cleanup "$net_wifi" || true
                fi
                if command -v bringup_interface >/dev/null 2>&1; then
                    bringup_interface "$net_wifi" 2 2 || true
                fi
                if [ "$wifi_retry_delay" -gt 0 ] 2>/dev/null; then
                    log_info "[NET] ${net_wifi}: retrying in ${wifi_retry_delay}s…"
                    sleep "$wifi_retry_delay"
                fi
            fi

            wifi_attempt=$((wifi_attempt + 1))
        done
    fi

    # -------- DHCP/route/DNS fixup (udhcpc script) --------
    net_script_path=""
    if command -v ensure_udhcpc_script >/dev/null 2>&1; then
        net_script_path="$(ensure_udhcpc_script 2>/dev/null || echo "")"
    fi
    if [ -n "$net_script_path" ]; then
        log_info "[NET] udhcpc default.script present → refreshing leases"
        for net_ifc in $net_ifaces $net_wifi; do
            [ -n "$net_ifc" ] || continue
            if command -v run_dhcp_client >/dev/null 2>&1; then
                run_dhcp_client "$net_ifc" 8 >/dev/null 2>&1 || true
            fi
        done
        check_network_status_rc; net_rc=$?
        case "$net_rc" in
            0)
                log_pass "[NET] connectivity restored after udhcpc fixup"
                ensure_reasonable_clock || log_warn "Proceeding in limited-network mode."
                unset net_script_path net_ifaces net_wifi net_ifc net_rc net_had_any_ip
                return 0
                ;;
            2)
                log_warn "[NET] IP present but still no internet after udhcpc fixup"
                net_had_any_ip=1
                ;;
        esac
    fi

    if [ "$net_had_any_ip" -eq 1 ] 2>/dev/null; then
        unset net_script_path net_ifaces net_wifi net_ifc net_rc net_had_any_ip
        return 2
    fi
    unset net_script_path net_ifaces net_wifi net_ifc net_rc net_had_any_ip
    return 1
}

# Return the first numeric token found in input (helps when tools return multi-PID / noisy output)
sanitize_pid() {
    # Return first numeric token from input (single PID) or empty
    printf '%s' "$1" \
      | tr -d '\r' \
      | tr -c '0-9 \n' ' ' \
      | awk '{print $1; exit}'
}

get_pids_by_name() {
    name="$1"
 
    if [ -z "$name" ]; then
        return 1
    fi
 
    # Print one PID per line (sanitized), for all processes whose basename matches $name
    ps -ef 2>/dev/null | awk -v n="$name" '
        NR==1 { next }
        {
            cmd=$8
            sub(".*/", "", cmd)
            if (cmd == n) { print $2 }
        }' | while IFS= read -r p; do
            p_clean=$(sanitize_pid "$p")
            if [ -n "$p_clean" ]; then
                printf '%s\n' "$p_clean"
            fi
        done
}
 
# Backward-compatible wrapper:
#   get_one_pid_by_name <name>        -> first PID
#   get_one_pid_by_name <name> all    -> all PIDs (newline-separated)
get_one_pid_by_name() {
    name="$1"
    mode="${2:-}"
 
    pids=""
    first_pid=""
 
    for d in /proc/[0-9]*; do
        [ -r "$d/comm" ] || continue
        comm=$(tr -d '\r\n' <"$d/comm" 2>/dev/null)
        [ "$comm" = "$name" ] || continue
 
        pid=${d#/proc/}
        case "$pid" in
            ''|*[!0-9]*)
                continue
                ;;
        esac
 
        if [ -z "$first_pid" ] || [ "$pid" -lt "$first_pid" ]; then
            first_pid="$pid"
        fi
 
        if [ -z "$pids" ]; then
            pids="$pid"
        else
            pids="$pids $pid"
        fi
    done
 
    [ -n "$pids" ] || return 1
 
    if [ "$mode" = "all" ]; then
        printf '%s\n' "$pids"
    else
        printf '%s\n' "$first_pid"
    fi
}

# Wait until PID is alive (kill -0 succeeds) or timeout seconds elapse.
wait_pid_alive() {
    pid="$1"
    timeout="${2:-10}"
 
    pid=$(sanitize_pid "$pid")
    case "$pid" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
 
    i=0
    while [ "$i" -lt "$timeout" ]; do
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# Kill process for the given PID
kill_process() {
    PID="$1"
    KILL_TERM_GRACE="${KILL_TERM_GRACE:-5}"
    KILL_KILL_GRACE="${KILL_KILL_GRACE:-5}"
    SELF_PID="$$"
 
    case "$PID" in
        ''|*[!0-9]*)
            log_warn "Refusing to kill non-numeric PID '$PID'"
            return 1
            ;;
    esac
 
    # Safety checks
    if [ "$PID" -eq 1 ] || [ "$PID" -eq "$SELF_PID" ]; then
        log_warn "Refusing to kill PID $PID (init or self)"
        return 1
    fi
 
    if ! kill -0 "$PID" 2>/dev/null; then
        log_info "Process $PID not running"
        return 0
    fi
 
    log_info "Sending SIGTERM to PID $PID"
    kill -TERM "$PID" 2>/dev/null
    sleep "$KILL_TERM_GRACE"
 
    if kill -0 "$PID" 2>/dev/null; then
        log_info "Sending SIGKILL to PID $PID"
        kill -KILL "$PID" 2>/dev/null
        sleep "$KILL_KILL_GRACE"
    fi
 
    if kill -0 "$PID" 2>/dev/null; then
        log_warn "Failed to kill process $PID"
        return 1
    fi
 
    log_info "Process $PID terminated successfully"
    return 0
}

is_process_running() {
    name="$1"
 
    pids=$(get_one_pid_by_name "$name" all 2>/dev/null) || {
        log_info "Process '$name' is not running."
        return 1
    }
 
    log_info "Process '$name' is running."
 
    # Only add extra debug if multiple instances exist
    case "$pids" in
        *" "*)
            log_info "Process '$name' instances: $pids"
            ;;
        *)
            return 0
            ;;
    esac
 
    for pid in $pids; do
        case "$pid" in
            ''|*[!0-9]*)
                continue
                ;;
        esac
 
        cmd=""
        if [ -r "/proc/$pid/cmdline" ]; then
            cmd=$(tr '\000' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
        fi
 
        if [ -n "$cmd" ]; then
            log_info "Process '$name' PID $pid cmdline: $cmd"
        else
            comm=""
            if [ -r "/proc/$pid/comm" ]; then
                comm=$(tr -d '\r\n' <"/proc/$pid/comm" 2>/dev/null)
            fi
            log_info "Process '$name' PID $pid comm: ${comm:-unknown}"
        fi
    done
 
    return 0
}

get_pid() {
    if [ -z "$1" ]; then
        log_info "Usage: get_pid <process_name>"
        return 1
    fi

    process_name="$1"
    pid=""

    # Prefer pgrep if available (fast + clean)
    if command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -x "$process_name" 2>/dev/null | awk 'NR==1 {print; exit}')
    fi

    # POSIX fallback: ps
    if [ -z "$pid" ]; then
        pid=$(ps -e 2>/dev/null | awk -v name="$process_name" '$NF == name { print $1; exit }')
    fi

    if [ -n "$pid" ]; then
        printf '%s\n' "$pid"
        return 0
    fi

    log_info "Process '$process_name' not found."
    return 1
}

# Returns count of "Test service" lines
get_qrtr_test_service_count() {
    if ! command -v qrtr-lookup >/dev/null 2>&1; then
        echo "0"
        return
    fi
    qrtr-lookup | grep -F -c 'Test service'
}

# Check if a specific Node ID (column 3) exists
qrtr_id_exists() {
    target="$1"
    if ! command -v qrtr-lookup >/dev/null 2>&1; then
        return 1
    fi
    qrtr-lookup | awk -v target="$target" '$3 == target { found=1; exit } END { if(!found) exit 1 }'
}

# Map human-readable names to IDs
get_qrtr_id_from_name() {
    key=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$key" in
        "adsp" | "adsp-root")         echo "32" ;;
        "adsp-audiopd" | "audio")     echo "33" ;;
        "adsp-sensorpd" | "sensor")   echo "34" ;;
        "adsp-chargerpd" | "charger") echo "35" ;;
        "mpss" | "modem")             echo "5" ;;
        "mpss-oempd" | "modem-oempd") echo "6" ;;
        "cdsp")                       echo "64" ;;
        "cdsp1")                      echo "72" ;;
        "gpdsp0" | "gpdsp0-root")     echo "112" ;;
        "gpdsp0-user")                echo "113" ;;
        "gpdsp1" | "gpdsp1-root")     echo "120" ;;
        "gpdsp1-user")                echo "121" ;;
        "soccp")                      echo "141" ;;
        "dcp")                        echo "142" ;;
        "wpss")                       echo "128" ;;
        *)                            echo "" ;;
    esac
}

# Reverse mapping for display
get_qrtr_name_from_id() {
    id="$1"
    case "$id" in
        "32")  echo "ADSP Root" ;;
        "33")  echo "ADSP AudioPD" ;;
        "34")  echo "ADSP SensorPD" ;;
        "35")  echo "ADSP ChargerPD" ;;
        "5")   echo "MPSS Modem" ;;
        "6")   echo "MPSS OEMPD" ;;
        "64")  echo "CDSP Root" ;;
        "72")  echo "CDSP1" ;;
        "112") echo "GPDSP0 Root" ;;
        "113") echo "GPDSP0 User" ;;
        "120") echo "GPDSP1 Root" ;;
        "121") echo "GPDSP1 User" ;;
        "141") echo "SOCCP" ;;
        "142") echo "DCP" ;;
        "128") echo "WPSS" ;;
        *)     echo "Unknown Subsystem" ;;
    esac
}
