#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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
    missing=0
    missing_cmds=""
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_warn "Required command '$cmd' not found in PATH."
            missing=1
            missing_cmds="$missing_cmds $cmd"
        fi
    done
    if [ "$missing" -ne 0 ]; then
        testname="${TESTNAME:-}"
        log_skip "${testname:-UnknownTest} SKIP: missing dependencies:$missing_cmds"
        if [ -n "$testname" ]; then
            echo "$testname SKIP" > "./$testname.res"
        fi
        exit 0
    fi
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
 
    log_warn "System clock looks invalid (epoch=$now). Attempting quick time sync..."
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true 2>/dev/null || true
    fi
    grace=25
    start="$(date +%s 2>/dev/null || echo 0)"
    end=$((start + grace))
    while :; do
        cur="$(date +%s 2>/dev/null || echo 0)"
        if [ "$cur" -ge "$cutoff" ] 2>/dev/null; then
            log_pass "Clock synchronized."
            return 0
        fi
        if [ "$cur" -ge "$end" ] 2>/dev/null; then
            break
        fi
        sleep 1
    done
 
    log_warn "Clock still invalid; TLS downloads may fail. Treating as limited network."
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

# Is Weston running?
weston_is_running() {
    [ -n "$(weston_pids)" ]
}

# Stop all Weston processes
weston_stop() {
    if weston_is_running; then
        log_info "Stopping Weston..."
        pkill -x weston
        for i in $(seq 1 10); do
			log_info "Waiting for Weston to stop with $i attempt "
            if ! weston_is_running; then
                log_info "Weston stopped successfully"
                return 0
            fi
            sleep 1
        done
        log_error "Failed to stop Weston after waiting."
        return 1
    else
        log_info "Weston is not running."
    fi
    return 0
}

# Start weston with correct env if not running
weston_start() {
    if weston_is_running; then
        log_info "Weston already running."
        return 0
    fi
 
    if command -v systemctl >/dev/null 2>&1; then
        log_info "Attempting to start via systemd: weston.service"
        systemctl start weston.service >/dev/null 2>&1 || true
        sleep 1
        if weston_is_running; then
            log_info "Weston started via systemd (weston.service)."
            return 0
        fi
 
        log_info "Attempting to start via systemd: weston@.service"
        systemctl start weston@.service >/dev/null 2>&1 || true
        sleep 1
        if weston_is_running; then
            log_info "Weston started via systemd (weston@.service)."
            return 0
        fi
 
        log_warn "systemd start did not bring Weston up; will try direct spawn."
    fi
 
    # Minimal-friendly direct spawn (no headless module guesses here).
    ensure_xdg_runtime_dir
 
    if ! command -v weston >/dev/null 2>&1; then
        log_fail "weston binary not found in PATH."
        return 1
    fi
 
    log_info "Attempting to spawn Weston (no backend override). Log: /tmp/weston.self.log"
    ( nohup weston --log=/tmp/weston.self.log >/dev/null 2>&1 & ) || true
 
    tries=0
    while [ $tries -lt 5 ]; do
        if weston_is_running; then
            log_info "Weston is now running (PID(s): $(weston_pids))."
            return 0
        fi
        if [ -n "$(find_wayland_sockets | head -n1)" ]; then
            log_info "A Wayland socket appeared after spawn."
            return 0
        fi
        sleep 1
        tries=$((tries+1))
    done
 
    if [ -f /tmp/weston.self.log ]; then
        log_warn "Weston spawn failed; last log lines:"
        tail -n 20 /tmp/weston.self.log 2>/dev/null | sed 's/^/[weston.log] /' || true
    else
        log_warn "Weston spawn failed; no log file present."
    fi
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
# Ensure a private XDG runtime directory exists and is usable (0700).
weston_start() {
    # Already up?
    if weston_is_running; then
        log_info "Weston already running."
        return 0
    fi
 
    # 1) Try systemd user/system units if present
    if command -v systemctl >/dev/null 2>&1; then
        for unit in weston.service weston@.service; do
            log_info "Attempting to start via systemd: $unit"
            systemctl start "$unit" >/dev/null 2>&1 || true
            sleep 1
            if weston_is_running; then
                log_info "Weston started via $unit."
                return 0
            fi
        done
        log_warn "systemd start did not bring Weston up; will try direct spawn."
    fi
 
    # Helper: attempt spawn for a given uid (empty => current user)
    # Tries multiple backend names (to cover distro/plugin differences)
    # Returns 0 if a weston process + socket appears, else non-zero.
    spawn_weston_try() {
        target_uid="$1"  # "" or numeric uid
        backends="${WESTON_BACKENDS:-headless headless-backend.so}"
 
        # Prepare runtime dir
        if [ -n "$target_uid" ]; then
            run_dir="/run/user/$target_uid"
            mkdir -p "$run_dir" 2>/dev/null || true
            chown "$target_uid:$target_uid" "$run_dir" 2>/dev/null || true
        else
            ensure_xdg_runtime_dir
            run_dir="$XDG_RUNTIME_DIR"
        fi
        chmod 700 "$run_dir" 2>/dev/null || true
 
        # Where to log
        log_file="/tmp/weston.${target_uid:-self}.log"
        rm -f "$log_file" 2>/dev/null || true
 
        for be in $backends; do
            log_info "Spawning weston (uid=${target_uid:-$(id -u)}) with backend='$be' …"
            if ! command -v weston >/dev/null 2>&1; then
                log_fail "weston binary not found in PATH."
                return 1
            fi
 
            # Build the command: avoid optional modules that may not exist on minimal builds
            cmd="XDG_RUNTIME_DIR='$run_dir' weston --backend='$be' --log='$log_file'"
 
            if [ -n "$target_uid" ]; then
                # Run as that uid if we can
                if command -v su >/dev/null 2>&1; then
                    su -s /bin/sh -c "$cmd >/dev/null 2>&1 &" "#$target_uid" || true
                elif command -v runuser >/dev/null 2>&1; then
                    runuser -u "#$target_uid" -- sh -c "$cmd >/dev/null 2>&1 &" || true
                else
                    log_warn "No su/runuser available to switch uid=$target_uid; skipping this mode."
                    continue
                fi
            else
                # Current user
                ( nohup sh -c "$cmd" >/dev/null 2>&1 & ) || true
            fi
 
            # Wait up to ~5s for process + a socket to appear
            tries=0
            while [ $tries -lt 5 ]; do
                if weston_is_running; then
                    # See if a fresh socket is visible
                    sock="$(wayland_pick_socket)"
                    if [ -n "$sock" ]; then
                        log_info "Weston up (backend=$be). Socket: $sock"
                        return 0
                    fi
                fi
                sleep 1
                tries=$((tries+1))
            done
 
            # Show weston log tail to aid debugging
            if [ -r "$log_file" ]; then
                log_warn "Weston did not come up with backend '$be'. Last log lines:"
                tail -n 20 "$log_file" | sed 's/^/[weston.log] /'
            else
                log_warn "Weston did not come up with backend '$be' and no log file present ($log_file)."
            fi
        done
 
        return 1
    }
 
    # 2) Try as current user
    if spawn_weston_try ""; then
        return 0
    fi
 
    # 3) Try as 'weston' user (common on embedded images)
    weston_uid=""
    if command -v getent >/dev/null 2>&1; then
        weston_uid="$(getent passwd weston 2>/dev/null | awk -F: '{print $3}')"
    fi
    [ -z "$weston_uid" ] && weston_uid="$(id -u weston 2>/dev/null || true)"
 
    if [ -n "$weston_uid" ]; then
        log_info "Attempting to spawn Weston as uid=$weston_uid (user 'weston')."
        if spawn_weston_try "$weston_uid"; then
            return 0
        fi
    else
        log_info "No 'weston' user found; skipping user-switch spawn."
    fi
 
    log_warn "All weston spawn attempts failed."
    return 1
}

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
    uid="$(id -u 2>/dev/null || echo 0)"
    bases=""
    [ -n "$XDG_RUNTIME_DIR" ] && bases="$bases $XDG_RUNTIME_DIR"
    bases="$bases /dev/socket/weston /run/user/$uid /tmp/wayland-$uid /dev/shm"
    for b in $bases; do
        ensure_private_runtime_dir "$b" >/dev/null 2>&1 || true
        if s="$(find_wayland_socket_in "$b")"; then
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
    XDG_RUNTIME_DIR="$(dirname "$s")"
    WAYLAND_DISPLAY="$(basename "$s")"
    export XDG_RUNTIME_DIR WAYLAND_DISPLAY
    # Best-effort perms fix for minimal systems
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    log_info "Adopting Wayland environment from socket: $s"
    log_info "Adopted Wayland env: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    log_info "Reproduce with:"
    log_info "  export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'"
    log_info "  export WAYLAND_DISPLAY='$WAYLAND_DISPLAY'"
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
    sock="$(discover_wayland_socket_anywhere 2>/dev/null || true)"
    if [ -n "$sock" ]; then
        adopt_wayland_env_from_socket "$sock"
        log_info "Selected Wayland socket: $sock"
        return 0
    fi

    if weston_is_running; then
        log_info "Stopping Weston..."
        weston_stop
        i=0; while weston_is_running && [ "$i" -lt 5 ]; do i=$((i+1)); sleep 1; done
    fi

    log_info "Starting Weston..."
    weston_start
    i=0; sock=""
    while [ "$i" -lt 6 ]; do
        sock="$(find_wayland_socket_in /dev/socket/weston 2>/dev/null || true)"
        [ -n "$sock" ] && break
        sleep 1; i=$((i+1))
    done
    if [ -z "$sock" ]; then
        log_fail "Could not find Wayland socket after starting Weston."
        return 1
    fi
    adopt_wayland_env_from_socket "$sock"
    log_info "Weston started; socket: $sock"
    return 0
}

# Find candidate Wayland sockets in common locations.
# Prints absolute socket paths, one per line, most-preferred first.
find_wayland_sockets() {
    # Enumerate plausible Wayland sockets (one per line)
    uid="$(id -u 2>/dev/null || echo 0)"
 
    # Current env first (if valid)
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
 
    # Any user under /run/user (root can traverse) — covers weston running as uid 1000
    for d in /run/user/*; do
        [ -d "$d" ] || continue
        for f in "$d"/wayland-*; do
            [ -S "$f" ] && echo "$f"
        done
    done 2>/dev/null
 
    # weston-launch sockets
    for f in /dev/socket/weston/wayland-*; do
        [ -S "$f" ] && echo "$f"
    done 2>/dev/null
 
    # Last resort
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
    if command -v wayland-info >/dev/null 2>&1; then
        log_info "Probing Wayland with: wayland-info"
        wayland-info >/dev/null 2>&1 && return 0
        return 1
    fi
    if command -v weston-info >/dev/null 2>&1; then
        log_info "Probing Wayland with: weston-info"
        weston-info >/dev/null 2>&1 && return 0
        return 1
    fi
    if command -v weston-simple-egl >/dev/null 2>&1; then
        log_info "Probing Wayland by briefly starting weston-simple-egl"
        ( weston-simple-egl >/dev/null 2>&1 & echo $! >"/tmp/.wsegl.$$" )
        pid="$(cat "/tmp/.wsegl.$$" 2>/dev/null || echo)"
        rm -f "/tmp/.wsegl.$$" 2>/dev/null || true
        i=0
        while [ $i -lt 2 ]; do
            sleep 1
            i=$((i+1))
        done
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
        fi
        # If it started at all, consider the connection OK (best effort).
        return 0
    fi
    if [ -n "$XDG_RUNTIME_DIR" ] && [ -n "$WAYLAND_DISPLAY" ] && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
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

# Echo lines: "<name>\t<status>\t<type>\t<modes>\t<first_mode>"
# Example: "card0-HDMI-A-1 connected HDMI-A 9 1920x1080"
display_list_connectors() {
    found=0
    for d in /sys/class/drm/*-*; do
        [ -e "$d" ] || continue
        [ -f "$d/status" ] || continue
        name="$(basename "$d")"
        status="$(tr -d '\r\n' <"$d/status" 2>/dev/null)"
 
        # Derive connector type from name: cardX-<TYPE>-N
        # Strip "cardN-" prefix and trailing "-N" index.
        typ="$(printf '%s' "$name" \
            | sed -n 's/^card[0-9]\+-\([A-Za-z0-9+]\+\(-[A-Za-z0-9+]\+\)*\)-[0-9]\+/\1/p')"
        [ -z "$typ" ] && typ="unknown"
 
        # Modes
        modes_file="$d/modes"
        if [ -f "$modes_file" ]; then
            # wc output can have spaces on BusyBox; trim
            mc="$(wc -l <"$modes_file" 2>/dev/null | tr -d '[:space:]')"
            [ -z "$mc" ] && mc=0
            fm="$(head -n 1 "$modes_file" 2>/dev/null | tr -d '\r\n')"
        else
            mc=0
            fm=""
        fi
 
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$typ" "$mc" "$fm"
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

    # DRM nodes (no ls; iterate)
    nodes=""
    for f in /dev/dri/card* /dev/dri/renderD*; do
        if [ -e "$f" ]; then
            if [ -z "$nodes" ]; then nodes="$f"; else nodes="$nodes $f"; fi
        fi
    done
    if [ -n "$nodes" ]; then
        log_info "DRM nodes: $nodes"
    else
        log_warn "No /dev/dri/* nodes found."
    fi

    # Connectors
    have=0
    # shellcheck disable=SC2039
    while IFS="$(printf '\t')" read -r name status typ mc fm; do
        have=1
        if [ -n "$fm" ]; then
            log_info "DRM: ${name} status=${status} type=${typ} modes=${mc} first=${fm}"
        else
            log_info "DRM: ${name} status=${status} type=${typ} modes=${mc}"
        fi
    done <<EOF
$(display_list_connectors 2>/dev/null || true)
EOF
    [ "$have" -eq 1 ] || log_warn "No DRM connectors in /sys/class/drm."

    # Summary + weston outputs (if any)
    sum="$(display_connected_summary 2>/dev/null || echo none)"
    log_info "Connected summary: $sum"
    display_weston_outputs | while IFS= read -r l; do
        [ -n "$l" ] && log_info "$l"
    done

    log_info "----- End display snapshot: $ctx -----"
}

display_debug_snapshot() {
    ctx="$1"
    [ -z "$ctx" ] && ctx="display-snapshot"
    log_info "----- Display snapshot: $ctx -----"
 
    # DRM nodes
    nodes=""
    for f in /dev/dri/card* /dev/dri/renderD*; do
        [ -e "$f" ] && nodes="${nodes:+$nodes }$f"
    done
    if [ -n "$nodes" ]; then
        log_info "DRM nodes: $nodes"
    else
        log_warn "No /dev/dri/* nodes found."
    fi
 
    # Sysfs connectors (expects display_list_connectors to print tab-separated fields)
    have=0
    while IFS="$(printf '\t')" read -r name status typ mc fm; do
        [ -n "$name" ] || continue
        have=1
        if [ -n "$fm" ]; then
            log_info "DRM: ${name} status=${status} type=${typ} modes=${mc} first=${fm}"
        else
            log_info "DRM: ${name} status=${status} type=${typ} modes=${mc}"
        fi
    done <<EOF
$(display_list_connectors 2>/dev/null || true)
EOF
    [ "$have" -eq 1 ] || log_warn "No DRM connectors in /sys/class/drm."
 
    # Connected summary (sysfs)
    sum="$(display_connected_summary 2>/dev/null || echo none)"
    log_info "Connected summary (sysfs): $sum"
 
    # Optional weston outputs (existing helper)
    display_weston_outputs | while IFS= read -r l; do
        [ -n "$l" ] && log_info "$l"
    done
 
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
    iface="$1"
    timeout="${2:-10}"

    current_ip=$(get_ip_address "$iface")
    if [ -n "$current_ip" ] && ! echo "$current_ip" | grep -q '^169\.254'; then
        log_info "$iface already has valid IP: $current_ip. Skipping DHCP."
        return 0
    fi

    if ! command -v udhcpc >/dev/null 2>&1; then
        log_warn "udhcpc not found, skipping DHCP attempt"
        return 1
    fi

    # Use a no-op script to avoid flushing IPs
    safe_dhcp_script="/tmp/dhcp-noop-$$.sh"
    cat <<'EOF' > "$safe_dhcp_script"
#!/bin/sh
exit 0
EOF
    chmod +x "$safe_dhcp_script"

    log_info "Attempting DHCP on $iface safely..."
    (udhcpc -i "$iface" -n -q -s "$safe_dhcp_script" >/dev/null 2>&1) &
    dhcp_pid=$!
    sleep "$timeout"
    kill "$dhcp_pid" 2>/dev/null
    rm -f "$safe_dhcp_script"
    return 0
}

# Remove paired BT device by MAC
bt_cleanup_paired_device() {
    mac="$1"
    log_info "Removing paired device: $mac"
 
    # Non-interactive remove to avoid “AlreadyExists”
    bluetoothctl remove "$mac" >/dev/null 2>&1 || true
 
    # Full Expect cleanup (captures transcript in a logfile)
    cleanup_log="bt_cleanup_${mac}_$(date +%Y%m%d_%H%M%S).log"
    if expect <<EOF >"$cleanup_log" 2>&1
log_user 1
spawn bluetoothctl
set timeout 10
 
# Match the prompt once, then send all commands in sequence
expect -re "#|\\[.*\\]#" {
    send "power on\r"
    send "agent off\r"
    send "agent NoInputNoOutput\r"
    send "default-agent\r"
    send "remove $mac\r"
    send "quit\r"
}
 
expect eof
EOF
    then
        log_info "Device $mac removed successfully (see $cleanup_log)"
    else
        log_warn "Failed to remove device $mac (see $cleanup_log)"
    fi
}

# Retry a shell command N times with sleep
retry_command_bt() {
    cmd="$1"
    msg="$2"
    max="${3:-3}"
    count=1
    while [ "$count" -le "$max" ]; do
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Retry $count/$max failed: $msg"
        count=$((count + 1))
        sleep 2
    done
    return 1
}

# Check if a device (MAC or Name) is in the whitelist
bt_in_whitelist() {
    device_name="$1"
    device_mac="$2"

    whitelist_value="${WHITELIST:-}"
    log_info "Checking if MAC='$device_mac' or NAME='$device_name' is in whitelist: '$whitelist_value'"

    echo "$whitelist_value" | tr -s ' ' '\n' | while IFS= read -r allowed; do
        if [ "$allowed" = "$device_mac" ] || [ "$allowed" = "$device_name" ]; then
            log_info "MAC or NAME matched and allowed: $allowed"
            return 0
        fi
    done

    log_info "MAC matched but neither MAC nor NAME in whitelist"
    return 1
}
# bt_parse_whitelist <whitelist_file>
# Reads a whitelist file where each line has:
bt_parse_whitelist() {
    WHITELIST_ENTRIES=""
    if [ -n "$1" ] && [ -f "$1" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ""|\#*) continue ;;  # Skip blank lines and comments
                *) WHITELIST_ENTRIES="${WHITELIST_ENTRIES}${line}
" ;;
            esac
        done < "$1"
    fi
}

# bt_in_whitelist <mac> <name>
# Checks if a given device (MAC and optional name) exists
# Returns:
#     0 (success) if found
#     1 (failure) if not found
bt_in_whitelist() {
    mac="$1"
    name="$2"

    echo "$WHITELIST_ENTRIES" | while IFS= read -r entry || [ -n "$entry" ]; do
        entry_mac=$(echo "$entry" | awk '{print $1}')
        entry_name=$(echo "$entry" | cut -d' ' -f2-)
        if [ "$mac" = "$entry_mac" ] && { [ -z "$entry_name" ] || [ "$name" = "$entry_name" ]; }; then
            exit 0
        fi
    done

    return 1
}

# bt_scan_devices
# Attempts to detect nearby Bluetooth devices using:
#   1. hcitool scan
#   2. fallback: bluetoothctl scan (via expect)
# Returns:
#   0 - if devices found
#   1 - if no devices found or error
bt_scan_devices() {
    timestamp=$(date '+%Y%m%d_%H%M%S')
    scan_log="scan_${timestamp}.log"
    found_log="found_devices_${timestamp}.log"
 
    : > "$scan_log"
    : > "$found_log"
 
    log_info "Detecting Bluetooth adapter..."
    hcidev=$(hciconfig | awk '/^hci/ { print $1 }' | head -n1)
    if [ -z "$hcidev" ]; then
        log_error "No Bluetooth adapter found"
        return 1
    fi
 
    log_info "Using Bluetooth adapter: $hcidev"
    hciconfig "$hcidev" up
    sleep 1
 
    log_info "Running Bluetooth scan via hcitool (synchronous)..."
    script -q -c "hcitool -i $hcidev scan" "$scan_log"
    grep -E '^(\s)*([0-9A-F]{2}:){5}[0-9A-F]{2}' "$scan_log" | awk '{print $1, $2}' > "$found_log"
 
    if [ -s "$found_log" ]; then
        log_info "hcitool scan found devices, skipping bluetoothctl fallback."
        return 0
    fi
 
    log_warn "hcitool scan returned nothing. Falling back to bluetoothctl scan..."
 
    expect <<EOF >> "$scan_log"
log_user 0
spawn bluetoothctl
expect -re "#|\\\[.*\\\]#" { send "power on\r" }
expect -re "#|\\\[.*\\\]#" { send "agent NoInputNoOutput\r" }
expect -re "#|\\\[.*\\\]#" { send "default-agent\r" }
expect -re "#|\\\[.*\\\]#" { send "scan on\r" }
sleep 10
send "scan off\r"
expect -re "#|\\\[.*\\\]#" { send "quit\r" }
EOF
 
    grep -E "^\s*\[NEW\] Device" "$scan_log" | awk '{print $4, substr($0, index($0, $5))}' > "$found_log"
 
    if [ ! -s "$found_log" ]; then
        log_warn "Scan log is empty. Possible issue with bluetoothctl or adapter."
        return 1
    fi
 
    return 0
}

# Pair with Bluetooth device using MAC (with retries and timestamped logs)
bt_pair_with_mac() {
    bt_mac="$1"
    # Replace colons, strip any whitespace so no trailing spaces in filenames
    safe_mac=$(echo "$bt_mac" | tr ':' '_' | tr -d '[:space:]')
    max_retries=3
    retry=1
 
    while [ "$retry" -le "$max_retries" ]; do
        log_info "Interactive pairing attempt $retry for $bt_mac"
        log_file="$PWD/bt_headless_pair_${safe_mac}_$(date +%s).log"
 
        expect -c "
log_user 1
set timeout 30
set bt_mac \"$bt_mac\"
 
spawn bluetoothctl
 
expect -re {#|\\\[.*\\\]#} { send \"power on\r\" }
expect -re {#|\\\[.*\\\]#} { send \"agent NoInputNoOutput\r\" }
expect -re {#|\\\[.*\\\]#} { send \"default-agent\r\" }
expect -re {#|\\\[.*\\\]#} { send \"scan on\r\" }
sleep 10
send \"scan off\r\"
sleep 1
send \"pair \$bt_mac\r\"
 
expect {
    -re {Confirm passkey.*yes/no} {
        send \"yes\r\"
        exp_continue
    }
    -re {Authorize service.*yes/no} {
        send \"yes\r\"
        exp_continue
    }
    timeout {
        send \"quit\r\"
        exit 0
    }
    eof {
        exit 0
    }
}
" > "$log_file" 2>&1
 
        # Now analyze the log
        if grep -q "Pairing successful" "$log_file"; then
            log_pass "Pairing successful with $bt_mac"
            return 0
        elif grep -q "Failed to pair: org.bluez.Error" "$log_file"; then
            log_warn "Pairing failed with $bt_mac (BlueZ error)"
        elif grep -q "AuthenticationCanceled" "$log_file"; then
            log_warn "Pairing canceled with $bt_mac"
        else
            log_warn "Pairing failed with unknown reason (check $log_file)"
        fi
 
        bt_cleanup_paired_device "$bt_mac"
        retry=$((retry + 1))
        sleep 2
    done
 
    log_fail "Pairing failed after $max_retries attempts for $bt_mac"
    return 1
}

# Utility to reliably scan and pair Bluetooth devices through a unified workflow of repeated attempts.
retry_scan_and_pair() {
    retry=1
    max_retries=2
 
    while [ "$retry" -le "$max_retries" ]; do
        log_info "Bluetooth scan attempt $retry..."
        bt_scan_devices
 
        if [ -n "$BT_MAC" ]; then
            log_info "Matching against: BT_NAME='$BT_NAME', BT_MAC='$BT_MAC', WHITELIST='$WHITELIST'"
            if ! bt_in_whitelist "$BT_MAC" "$BT_NAME"; then
                log_warn "Expected device not found or not in whitelist"
                retry=$((retry + 1))
                continue
            fi
            bt_cleanup_paired_device "$BT_MAC"
            if bt_pair_with_mac "$BT_MAC"; then
                return 0
            fi
 
        elif [ -n "$BT_NAME" ]; then
            matched_mac=$(awk -v name="$BT_NAME" 'tolower($0) ~ tolower(name) { print $1; exit }' "$SCAN_RESULT")
            if [ -n "$matched_mac" ]; then
                log_info "Found matching device by name ($BT_NAME): $matched_mac"
                bt_cleanup_paired_device "$matched_mac"
                if bt_pair_with_mac "$matched_mac"; then
                    BT_MAC="$matched_mac"
                    return 0
                fi
            else
                log_warn "Device with name $BT_NAME not found in scan results"
            fi
 
        else
            log_warn "No MAC or device name provided, and whitelist is empty"
        fi
 
        retry=$((retry + 1))
    done
 
    log_fail "Retry scan and pair failed after $max_retries attempts"
    return 1
}

# Post-pairing connection test with bluetoothctl and l2ping fallback
bt_post_pair_connect() {
    target_mac="$1"
    sanitized_mac=$(echo "$target_mac" | tr ':' '_')
    timestamp=$(date '+%Y%m%d_%H%M%S')
    base_logfile="bt_connect_${sanitized_mac}_${timestamp}"
    max_attempts=3
    attempt=1
 
    if bluetoothctl info "$target_mac" | grep -q "Connected: yes"; then
        log_info "Device $target_mac is already connected, skipping explicit connect"
        log_pass "Post-pair connection successful"
        return 0
    fi
 
    while [ "$attempt" -le "$max_attempts" ]; do
        log_info "Attempting to connect post-pair (try $attempt): $target_mac"
        logfile="${base_logfile}_attempt${attempt}.log"
 
        expect <<EOF >"$logfile" 2>&1
log_user 1
set timeout 10
spawn bluetoothctl
expect -re "#|\\[.*\\]#" { send "trust $target_mac\r" }
expect -re "#|\\[.*\\]#" { send "connect $target_mac\r" }
 
expect {
    -re "Connection successful" { exit 0 }
    -re "Failed to connect|Device not available" { exit 1 }
    timeout { exit 1 }
}
EOF
        result=$?
        if [ "$result" -eq 0 ]; then
            log_pass "Post-pair connection successful"
            return 0
        fi
        log_warn "Connect attempt $attempt failed (check $logfile)"
        attempt=$((attempt + 1))
        sleep 2
    done
 
    # Fallback to l2ping
    log_info "Falling back to l2ping for $target_mac"
    l2ping_log="${base_logfile}_l2ping_${timestamp}.log"
    if command -v l2ping >/dev/null 2>&1; then
        # Capture all output—even if ping succeeds, we log it
        if l2ping -c 3 -t 5 "$target_mac" 2>&1 | tee "$l2ping_log" | grep -q "bytes from"; then
            log_pass "Fallback l2ping succeeded for $target_mac (see $l2ping_log)"
            return 0
        else
            log_warn "l2ping failed or no response for $target_mac (see $l2ping_log)"
        fi
    else
        log_warn "l2ping not available, skipping fallback"
    fi 
    log_fail "Post-pair connection failed for $target_mac"
    return 1
}

# Find MAC address from device name in scan log
bt_find_mac_by_name() {
    target="$1"
    log="$2"
    grep -i "$target" "$log" | awk '{print $3}' | head -n1
}

bt_remove_all_paired_devices() {
    log_info "Removing all previously paired Bluetooth devices..."
    bluetoothctl paired-devices | awk '/Device/ {print $2}' | while read -r dev; do
        log_info "Removing paired device $dev"
        bluetoothctl remove "$dev" >/dev/null
    done
}

# Validate connectivity using l2ping
bt_l2ping_check() {
    target_mac="$1"
    logfile="$2"

    if ! command -v l2ping >/dev/null 2>&1; then
        log_warn "l2ping command not available - skipping"
        return 1
    fi

    log_info "Running l2ping test for $target_mac"
    if l2ping -c 3 -t 5 "$target_mac" >>"$logfile" 2>&1; then
        log_pass "l2ping to $target_mac succeeded"
        return 0
    else
        log_warn "l2ping to $target_mac failed"
        return 1
    fi
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
get_remoteproc_path_by_firmware() {
    name="$1"
    idx path
    # List all remoteproc firmware nodes, match name, and return the remoteproc path
    idx=$(cat /sys/class/remoteproc/remoteproc*/firmware 2>/dev/null | grep -n "$name" | cut -d: -f1 | head -n1)
    [ -z "$idx" ] && return 1
    idx=$((idx - 1))
    path="/sys/class/remoteproc/remoteproc${idx}"
    [ -d "$path" ] && echo "$path" && return 0
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
