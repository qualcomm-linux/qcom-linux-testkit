#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# Common, POSIX-compliant helpers for Qualcomm video stack selection and V4L2 testing.
# Requires functestlib.sh: log_info/log_warn/log_pass/log_fail/log_skip,
# check_dependencies, extract_tar_from_url, (optional) run_with_timeout, ensure_network_online.

# -----------------------------------------------------------------------------
# Public env knobs (may be exported by caller or set via CLI in run.sh)
# -----------------------------------------------------------------------------
# VIDEO_STACK auto|upstream|downstream|base|overlay|up|down (default: auto)
# VIDEO_PLATFORM lemans|monaco|kodiak|"" (auto-detect)
# TAR_URL bundle for input clips (used by video_ensure_clips_present_or_fetch)
# VIDEO_APP path to iris_v4l2_test (default /usr/bin/iris_v4l2_test)

# -----------------------------------------------------------------------------
# Constants / tool paths
# -----------------------------------------------------------------------------
IRIS_UP_MOD="qcom_iris"
IRIS_VPU_MOD="iris_vpu"
VENUS_CORE_MOD="venus_core"
VENUS_DEC_MOD="venus_dec"
VENUS_ENC_MOD="venus_enc"

# We purposely avoid persistent blacklist here (no /etc changes).
# Session-only blocks live under /run/modprobe.d
RUNTIME_BLOCK_DIR="/run/modprobe.d"

# Optional custom module sources (set by run.sh only when user opts in)
# NOTE: Leaving these unset keeps the exact existing behavior.
KO_DIRS="${KO_DIRS:-}" # colon-separated dirs containing .ko files
KO_TREE="${KO_TREE:-}" # alt root containing lib/modules/$(uname -r)
KO_PREFER_CUSTOM="${KO_PREFER_CUSTOM:-0}" # 1 = prefer KO_DIRS before system tree

# Firmware path for Kodiak downstream blob
FW_PATH_KODIAK="/lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn"
: "${FW_BACKUP_DIR:=/opt}"

MODPROBE="$(command -v modprobe 2>/dev/null || printf '%s' /sbin/modprobe)"
LSMOD="$(command -v lsmod 2>/dev/null || printf '%s' /sbin/lsmod)"

# Default app path (caller may override via env)
VIDEO_APP="${VIDEO_APP:-/usr/bin/iris_v4l2_test}"

# -----------------------------------------------------------------------------
# NEW: settle / retry tunables (env-only; no CLI)
# -----------------------------------------------------------------------------
: "${MOD_RETRY_COUNT:=3}"
: "${MOD_RETRY_SLEEP:=0.4}"
: "${MOD_SETTLE_SLEEP:=0.5}"

# -----------------------------------------------------------------------------
# Tiny utils
# -----------------------------------------------------------------------------
video_exist_cmd() {
    command -v "$1" >/dev/null 2>&1
}

video_usleep() {
    # Safe sleep wrapper (accepts integers or decimals)
    dur="$1"
    if [ -z "$dur" ]; then
        dur=0
    fi
    sleep "$dur" 2>/dev/null || true
}

video_warn_if_not_root() {
    uid="$(id -u 2>/dev/null || printf '%s' 1)"
    if [ "$uid" -ne 0 ] 2>/dev/null; then
        log_warn "Not running as root; module/blacklist operations may fail."
    fi
}

video_has_module_loaded() {
    "$LSMOD" 2>/dev/null | awk '{print $1}' | grep -q "^$1$"
}

video_devices_present() {
    set -- /dev/video* 2>/dev/null
    [ -e "$1" ]
}

video_step() {
    id="$1"
    msg="$2"
    if [ -n "$id" ]; then
        log_info "[$id] STEP: $msg"
    else
        log_info "STEP: $msg"
    fi
}

# -----------------------------------------------------------------------------
# Optional: log firmware hint after reload
# -----------------------------------------------------------------------------
video_log_fw_hint() {
    if video_exist_cmd dmesg; then
        out="$(dmesg 2>/dev/null | tail -n 200 | grep -Ei 'firmware|iris_vpu|venus' | tail -n 10)"
        if [ -n "$out" ]; then
            printf '%s\n' "$out" | while IFS= read -r ln; do
                log_info "dmesg: $ln"
            done
        fi
    fi
}

# Install a module file into /lib/modules/$(uname -r)/updates and run depmod.
# Usage: video_ensure_moddir_install <module_path> <logical_name>
video_ensure_moddir_install() {
    mp="$1"     # source path to .ko
    mname="$2"  # logical module name for logging
    kr="$(uname -r 2>/dev/null)"
    [ -z "$kr" ] && kr="$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n 1)"

    if [ -z "$mp" ] || [ ! -f "$mp" ]; then
        log_warn "install-ko: invalid module path: $mp"
        return 1
    fi

    updates="/lib/modules/$kr/updates"
    if [ ! -d "$updates" ]; then
        if ! mkdir -p "$updates" 2>/dev/null; then
            log_warn "install-ko: cannot create $updates (read-only FS?)"
            return 1
        fi
    fi

    base="$(basename "$mp")"
    dst="$updates/$base"

    do_copy=1
    if [ -f "$dst" ]; then
        if command -v md5sum >/dev/null 2>&1; then
            src_md5="$(md5sum "$mp" 2>/dev/null | awk '{print $1}')"
            dst_md5="$(md5sum "$dst" 2>/dev/null | awk '{print $1}')"
            [ -n "$src_md5" ] && [ "$src_md5" = "$dst_md5" ] && do_copy=0
        else
            if cmp -s "$mp" "$dst" 2>/dev/null; then
                do_copy=0
            fi
        fi
    fi

    if [ "$do_copy" -eq 1 ]; then
        if ! cp -f "$mp" "$dst" 2>/dev/null; then
            log_warn "install-ko: failed to copy $mp -> $dst"
            return 1
        fi
        chmod 0644 "$dst" 2>/dev/null || true
        sync 2>/dev/null || true
        log_info "install-ko: copied $(basename "$mp") to $dst"
    else
        log_info "install-ko: up-to-date at $dst"
    fi

    if command -v depmod >/dev/null 2>&1; then
        if depmod -a "$kr" >/dev/null 2>&1; then
            log_info "install-ko: depmod -a $kr done"
        else
            log_warn "install-ko: depmod -a $kr failed (continuing)"
        fi
    else
        log_warn "install-ko: depmod not found; modprobe may fail to resolve deps"
    fi

    [ -n "$mname" ] && video_log_resolve "$mname" updates-tree "$dst"
    printf '%s\n' "$dst"
    return 0
}

# Takes a logical module name (e.g. iris_vpu), resolves/copies into updates/, depmods, then loads deps+module.
video_insmod_with_deps() {
    m="$1"
    [ -z "$m" ] && { log_warn "insmod-with-deps: empty module name"; return 1; }

    [ -z "$MODPROBE" ] && MODPROBE="modprobe"

    if video_has_module_loaded "$m"; then
        log_info "module already loaded (skip): $m"
        return 0
    fi

    mp="$(video_find_module_file "$m")" || mp=""
    if [ -z "$mp" ] || [ ! -f "$mp" ]; then
        log_warn "insmod fallback: could not locate module file for $m"
        return 1
    fi
    log_info "resolve: $m -> $mp"

    case "$mp" in
        /lib/modules/*) staged="$mp" ;;
        *)
            staged="$(video_ensure_moddir_install "$mp" "$m")" || staged=""
            if [ -z "$staged" ]; then
                log_warn "insmod-with-deps: staging into updates/ failed for $m"
                return 1
            fi
            ;;
    esac

    if "$MODPROBE" -q "$m" 2>/dev/null; then
        video_log_load_success "$m" modprobe "$staged"
        return 0
    fi
    log_warn "modprobe failed: $m (attempting direct insmod)"

    deps=""
    if video_exist_cmd modinfo; then
        deps="$(modinfo -F depends "$staged" 2>/dev/null | tr ',' ' ' | tr -s ' ')"
    fi

    for d in $deps; do
        [ -z "$d" ] && continue
        if video_has_module_loaded "$d"; then
            continue
        fi
        if ! "$MODPROBE" -q "$d" 2>/dev/null; then
            dpath="$(video_find_module_file "$d")" || dpath=""
            if [ -z "$dpath" ] || [ ! -f "$dpath" ]; then
                kr="$(uname -r 2>/dev/null)"
                [ -z "$kr" ] && kr="$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n 1)"
                cand="/lib/modules/$kr/updates/${d}.ko"
                [ -f "$cand" ] && dpath="$cand"
            fi
            if [ -n "$dpath" ] && [ -f "$dpath" ]; then
                if insmod "$dpath" 2>/dev/null; then
                    video_log_load_success "$d" dep-insmod "$dpath"
                else
                    log_warn "dep insmod failed: $d ($dpath)"
                fi
            else
                log_warn "dep resolve failed: $d"
            fi
        else
            video_log_load_success "$d" dep-modprobe
        fi
    done

    if insmod "$staged" 2>/dev/null; then
        video_log_load_success "$m" insmod "$staged"
        return 0
    fi

    log_warn "insmod failed for $staged"
    return 1
}

video_modprobe_dryrun() {
    m="$1"
    out=$("$MODPROBE" -n "$m" 2>/dev/null)
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r ln; do
            log_info "modprobe -n $m: $ln"
        done
    else
        log_info "modprobe -n $m:"
    fi
}

video_list_runtime_blocks() {
    found=0
    for f in "$RUNTIME_BLOCK_DIR"/*.conf; do
        [ -e "$f" ] || continue
        if grep -Eiq '(^|[[:space:]])(blacklist|install)[[:space:]]+(qcom[-_]iris|iris[-_]vpu|venus[-_](core|dec|enc))' "$f" 2>/dev/null; then
            log_info "$f"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        log_info "(none)"
    fi
}

# -------------------------------------------------------------------------
# Path resolution & load logging helpers
# -------------------------------------------------------------------------
video_dump_stack_state() {
    when="$1" # pre|post

    log_info "Modules ($when):"
    log_info "lsmod (iris/venus):"
    "$LSMOD" 2>/dev/null | awk 'NR==1 || $1 ~ /^(iris_vpu|qcom_iris|venus_core|venus_dec|venus_enc)$/ {print}'

    video_modprobe_dryrun qcom_iris
    video_modprobe_dryrun iris_vpu
    video_modprobe_dryrun venus_core
    video_modprobe_dryrun venus_dec
    video_modprobe_dryrun venus_enc

    log_info "runtime blocks:"
    video_list_runtime_blocks
}

video_log_resolve() {
    # usage: video_log_resolve <module> <how> <path>
    # how: modinfo | system-tree | updates-tree | altroot-tree | ko-dir
    m="$1"; how="$2"; p="$3"
    case "$how" in
        modinfo)
            log_info "resolve-path: $m via modinfo -n => $p"
            ;;
        system-tree)
            log_info "resolve-path: $m via /lib/modules => $p"
            ;;
        updates-tree)
            log_info "resolve-path: $m via /lib/modules/*/updates => $p"
            ;;
        altroot-tree)
            log_info "resolve-path: $m via KO_TREE => $p"
            ;;
        ko-dir)
            log_info "resolve-path: $m via KO_DIRS => $p"
            ;;
    esac
}

video_log_load_success() {
    # usage: video_log_load_success <module> <how> [extra]
    # how: modprobe-system | modprobe-altroot | insmod | dep-modprobe | dep-insmod
    m="$1"; how="$2"; extra="$3"
    case "$how" in
        modprobe-system)
            log_info "load-path: modprobe(system): $m"
            ;;
        modprobe-altroot)
            log_info "load-path: modprobe(altroot=$KO_TREE): $m"
            ;;
        insmod)
            # extra = path
            log_info "load-path: insmod: $extra"
            ;;
        dep-modprobe)
            log_info "load-path(dep): modprobe(system): $m"
            ;;
        dep-insmod)
            # extra = path
            log_info "load-path(dep): insmod: $extra"
            ;;
    esac
}

video_find_module_file() {
    # Resolve a module file path for a logical mod name (handles _ vs -).
    # Prefers: modinfo -n, then .../updates/, then general search (and KO_DIRS/KO_TREE if provided).
    m="$1"
    kr="$(uname -r 2>/dev/null)"
 
    if [ -z "$kr" ]; then
        kr="$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n 1)"
    fi
 
    if video_exist_cmd modinfo; then
        p="$(modinfo -n "$m" 2>/dev/null)"
        if [ -n "$p" ] && [ -f "$p" ]; then
            video_log_resolve "$m" modinfo "$p"
            printf '%s\n' "$p"
            return 0
        fi
    fi
 
    m_us="$m"
    m_hy="$(printf '%s' "$m" | tr '_' '-')"
    m_alt="$(printf '%s' "$m" | tr '-' '_')"
 
    # Helper to scan KO_DIRS (bounded search)
    scan_ko_dirs() {
        modbase="$1" # without .ko*
        if [ -z "$KO_DIRS" ]; then
            return 1
        fi
        OLD_IFS="$IFS"
        IFS=':'
        for d in $KO_DIRS; do
            IFS="$OLD_IFS"
            # SC2015 fix: avoid `[ -n "$d" ] && [ -d "$d" ] || continue`
            if [ -z "$d" ] || [ ! -d "$d" ]; then
                continue
            fi
            p="$(find "$d" -maxdepth 3 -type f -name "${modbase}.ko*" -print -quit 2>/dev/null)"
            if [ -n "$p" ]; then
                video_log_resolve "$m" ko-dir "$p"
                printf '%s\n' "$p"
                return 0
            fi
        done
        IFS="$OLD_IFS"
        return 1
    }
 
    # Optional order: prefer KO_DIRS first if requested
    if [ "$KO_PREFER_CUSTOM" -eq 1 ] 2>/dev/null; then
        for pat in "$m_us" "$m_hy" "$m_alt"; do
            if scan_ko_dirs "$pat"; then
                return 0
            fi
        done
    fi
 
    # Optional altroot tree (KO_TREE) first, if provided
    if [ -n "$KO_TREE" ] && [ -d "$KO_TREE" ]; then
        for pat in "$m_us" "$m_hy" "$m_alt"; do
            p="$(find "$KO_TREE/lib/modules/$kr" -type f -name "${pat}.ko*" -print -quit 2>/dev/null)"
            if [ -n "$p" ]; then
                video_log_resolve "$m" altroot-tree "$p"
                printf '%s\n' "$p"
                return 0
            fi
        done
    fi
 
    for pat in "$m_us" "$m_hy" "$m_alt"; do
        p="$(find "/lib/modules/$kr/updates" -type f -name "${pat}.ko*" 2>/dev/null | head -n 1)"
        if [ -n "$p" ]; then
            video_log_resolve "$m" updates-tree "$p"
            printf '%s\n' "$p"
            return 0
        fi
    done
 
    for pat in "$m_us" "$m_hy" "$m_alt"; do
        p="$(find "/lib/modules/$kr" -type f -name "${pat}.ko*" 2>/dev/null | head -n 1)"
        if [ -n "$p" ]; then
            video_log_resolve "$m" system-tree "$p"
            printf '%s\n' "$p"
            return 0
        fi
    done
 
    # If not preferred-first, still try KO_DIRS at the end
    if [ "$KO_PREFER_CUSTOM" -ne 1 ] 2>/dev/null; then
        for pat in "$m_us" "$m_hy" "$m_alt"; do
            if scan_ko_dirs "$pat"; then
                return 0
            fi
        done
    fi
 
    return 1
}

modprobe_dryrun() {
    video_modprobe_dryrun "$@"
}

list_runtime_blocks() {
    video_list_runtime_blocks "$@"
}

dump_stack_state() {
    video_dump_stack_state "$@"
}

# -----------------------------------------------------------------------------
# Runtime-only (session) block/unblock: lives under /run/modprobe.d
# -----------------------------------------------------------------------------
video_block_mod_now() {
    # usage: video_block_mod_now qcom_iris [iris_vpu ...]
    mkdir -p "$RUNTIME_BLOCK_DIR" 2>/dev/null || true

    for m in "$@"; do
        printf 'install %s /bin/false\n' "$m" > "$RUNTIME_BLOCK_DIR/${m}-block.conf"
    done

    depmod -a 2>/dev/null || true

    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi

    video_usleep "${MOD_SETTLE_SLEEP}"
}

video_unblock_mod_now() {
    # usage: video_unblock_mod_now qcom_iris [iris_vpu ...]
    for m in "$@"; do
        rm -f "$RUNTIME_BLOCK_DIR/${m}-block.conf"
    done

    depmod -a 2>/dev/null || true

    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi

    video_usleep "${MOD_SETTLE_SLEEP}"
}

# -----------------------------------------------------------------------------
# Persistent de-blacklist for a module (handles qcom_iris ↔ qcom-iris)
# -----------------------------------------------------------------------------
video_persistent_unblock_module() {
    m="$1"
    if [ -z "$m" ]; then
        return 0
    fi

    m_us="$(printf '%s' "$m" | tr '-' '_')"
    m_hy="$(printf '%s' "$m" | tr '_' '-')"

    if command -v video_unblock_mod_now >/dev/null 2>&1; then
        video_unblock_mod_now "$m_us" "$m_hy"
    else
        rm -f "/run/modprobe.d/${m_us}-block.conf" "/run/modprobe.d/${m_hy}-block.conf" 2>/dev/null || true
        depmod -a 2>/dev/null || true
        if command -v udevadm >/dev/null 2>&1; then
            udevadm control --reload-rules 2>/dev/null || true
            udevadm settle 2>/dev/null || true
        fi
    fi

    for d in /etc/modprobe.d /lib/modprobe.d; do
        [ -d "$d" ] || continue
        for f in "$d"/*.conf; do
            [ -e "$f" ] || continue
            tmp="$f.tmp.$$"
            awk -v a="$m_us" -v b="$m_hy" '
                BEGIN { IGNORECASE=1 }
                {
                    line = $0
                    bl1 = "^[[:space:]]*blacklist[[:space:]]*" a "([[:space:]]|$)"
                    bl2 = "^[[:space:]]*blacklist[[:space:]]*" b "([[:space:]]|$)"
                    in1 = "^[[:space:]]*install[[:space:]]*" a "([[:space:]]|$).*[/]bin[/]false"
                    in2 = "^[[:space:]]*install[[:space:]]*" b "([[:space:]]|$).*[/]bin[/]false"
                    if (line ~ bl1 || line ~ bl2 || line ~ in1 || line ~ in2) next
                    print line
                }
            ' "$f" >"$tmp" 2>/dev/null || {
                rm -f "$tmp" >/dev/null 2>&1
                continue
            }
            mv "$tmp" "$f"
        done
    done

    for f in "/etc/modprobe.d/blacklist-${m_us}.conf" "/etc/modprobe.d/blacklist-${m_hy}.conf"; do
        [ -e "$f" ] || continue
        if ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$f" 2>/dev/null; then
            rm -f "$f" 2>/dev/null || true
        fi
    done

    depmod -a 2>/dev/null || true
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi

    video_usleep "${MOD_SETTLE_SLEEP}"

    log_info "persistent unblock done for $m (and aliases: $m_us, $m_hy)"
    return 0
}

# -----------------------------------------------------------------------------
# Retry wrapper for modprobe
# -----------------------------------------------------------------------------
video_retry_modprobe() {
    m="$1"
    n="${MOD_RETRY_COUNT}"
    i=0

    if video_has_module_loaded "$m"; then
        log_info "module already loaded (retry path skipped): $m"
        return 0
    fi

    while [ "$i" -lt "$n" ]; do
        i=$((i+1))

        if video_has_module_loaded "$m"; then
            log_info "module became present before attempt $i: $m"
            return 0
        fi

        if [ -n "$KO_TREE" ] && [ -d "$KO_TREE" ]; then
            log_info "modprobe attempt $i/$n (altroot=$KO_TREE): $m"
            if "$MODPROBE" -d "$KO_TREE" "$m" 2>/dev/null; then
                video_log_load_success "$m" modprobe-altroot
                return 0
            fi
        else
            log_info "modprobe attempt $i/$n (system): $m"
            if "$MODPROBE" "$m" 2>/dev/null; then
                video_log_load_success "$m" modprobe-system
                return 0
            fi
        fi

        video_usleep "${MOD_RETRY_SLEEP}"
    done

    if video_has_module_loaded "$m"; then
        log_info "module present after retries: $m"
        return 0
    fi

    log_warn "modprobe failed after $n attempts: $m"
    return 1
}

# -----------------------------------------------------------------------------
# modprobe with insmod fallback (standalone-like resilience)
# -----------------------------------------------------------------------------
video_modprobe_or_insmod() {
    m="$1"

    if video_has_module_loaded "$m"; then
        log_info "module already loaded (modprobe/insmod path skipped): $m"
        return 0
    fi

    if video_retry_modprobe "$m"; then
        return 0
    fi

    log_warn "modprobe $m failed, attempting de-blacklist + retry"
    video_persistent_unblock_module "$m"
    video_usleep "${MOD_SETTLE_SLEEP}"

    if video_retry_modprobe "$m"; then
        return 0
    fi

    if video_insmod_with_deps "$m"; then
        return 0
    fi

    malt="$(printf '%s' "$m" | tr '_-' '-_')"
    if [ "$malt" != "$m" ]; then
        if video_retry_modprobe "$malt"; then
            return 0
        fi
        if video_insmod_with_deps "$malt"; then
            return 0
        fi
    fi

    log_warn "modprobe $m failed, and insmod fallback did not succeed"
    return 1
}

# -----------------------------------------------------------------------------
# Stack normalization & auto preference
# -----------------------------------------------------------------------------
video_normalize_stack() {
    s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$s" in
        upstream|base|up)
            printf '%s\n' "upstream"
            ;;
        downstream|overlay|down)
            printf '%s\n' "downstream"
            ;;
        auto|"")
            printf '%s\n' "auto"
            ;;
        *)
            printf '%s\n' "$s"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Platform detect → lemans|monaco|kodiak|unknown
# -----------------------------------------------------------------------------
video_detect_platform() {
    model=""
    compat=""
 
    if [ -r /proc/device-tree/model ]; then
        model=$(tr -d '\000' </proc/device-tree/model 2>/dev/null)
    fi
 
    if [ -r /proc/device-tree/compatible ]; then
        compat=$(tr -d '\000' </proc/device-tree/compatible 2>/dev/null)
    fi
 
    s=$(printf '%s\n%s\n' "$model" "$compat" | tr '[:upper:]' '[:lower:]')
 
    # Monaco: qcs8300-ride, iq-8275-evk, qcs8275, generic qcs8300, or ride-sx+8300
    monaco_pat='qcs8300-ride|iq-8275-evk|qcs8275|qcs8300|ride-sx.*8300|8300.*ride-sx'
 
    # LeMans: qcs9100-ride, qcs9075, generic qcs9100, or ride-sx+9100
    lemans_pat='qcs9100-ride|qcs9075|qcs9100|ride-sx.*9100|9100.*ride-sx'
 
    # Kodiak: qcs6490, qcm6490, or rb3+6490
    kodiak_pat='qcs6490|qcm6490|rb3.*6490|6490.*rb3'
 
    if printf '%s' "$s" | grep -Eq "$lemans_pat"; then
        printf '%s\n' "lemans"
        return 0
    fi
 
    if printf '%s' "$s" | grep -Eq "$monaco_pat"; then
        printf '%s\n' "monaco"
        return 0
    fi
 
    if printf '%s' "$s" | grep -Eq "$kodiak_pat"; then
        printf '%s\n' "kodiak"
        return 0
    fi
 
    printf '%s\n' "unknown"
}

# -----------------------------------------------------------------------------
# Validation helpers
# -----------------------------------------------------------------------------
video_validate_upstream_loaded() {
    plat="$1"
 
    if [ -z "$plat" ]; then
        plat="$(video_detect_platform)"
    fi
 
    case "$plat" in
        lemans|monaco)
            # Any upstream build has qcom_iris present
            if video_has_module_loaded qcom_iris; then
                return 0
            fi
            return 1
            ;;
 
        kodiak)
            # Upstream valid if Venus trio present OR pure qcom_iris-only present
            if video_has_module_loaded venus_core && video_has_module_loaded venus_dec && video_has_module_loaded venus_enc; then
                return 0
            fi
 
            if video_has_module_loaded qcom_iris && ! video_has_module_loaded iris_vpu; then
                return 0
            fi
 
            return 1
            ;;
    esac
 
    return 1
}

video_validate_downstream_loaded() {
    plat="$1"
    case "$plat" in
        lemans|monaco)
            if video_has_module_loaded "$IRIS_VPU_MOD" && ! video_has_module_loaded "$IRIS_UP_MOD"; then
                return 0
            fi
            return 1
            ;;
        kodiak)
            if video_has_module_loaded "$IRIS_VPU_MOD" && ! video_has_module_loaded "$VENUS_CORE_MOD"; then
                return 0
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

video_assert_stack() {
    plat="$1"
    want="$(video_normalize_stack "$2")"

    case "$want" in
        upstream|up|base)
            if video_validate_upstream_loaded "$plat"; then
                return 0
            fi
            case "$plat" in
                lemans|monaco)
                    log_fail "[STACK] Upstream requested but qcom_iris + iris_vpu are not both present."
                    ;;
                kodiak)
                    log_fail "[STACK] Upstream requested but venus_core/dec/enc are not all present."
                    ;;
                *)
                    log_fail "[STACK] Upstream requested but platform '$plat' is unknown."
                    ;;
            esac
            return 1
            ;;
        downstream|overlay|down)
            if video_validate_downstream_loaded "$plat"; then
                return 0
            fi
            case "$plat" in
                lemans|monaco)
                    log_fail "[STACK] Downstream requested but iris_vpu not present or qcom_iris still loaded."
                    ;;
                kodiak)
                    log_fail "[STACK] Downstream requested but iris_vpu not present or venus_core still loaded."
                    ;;
                *)
                    log_fail "[STACK] Downstream requested but platform '$plat' is unknown."
                    ;;
            esac
            return 1
            ;;
        *)
            log_fail "[STACK] Unknown target stack '$want'."
            return 1
            ;;
    esac
}

video_stack_status() {
    plat="$1"
 
    if [ -z "$plat" ]; then
        plat="$(video_detect_platform)"
    fi
 
    case "$plat" in
        lemans|monaco)
            # Upstream accepted if:
            # - pure upstream build: qcom_iris present and iris_vpu absent
            # - base+overlay build: qcom_iris and iris_vpu both present
            if video_has_module_loaded qcom_iris && ! video_has_module_loaded iris_vpu; then
                printf '%s\n' "upstream"
                return 0
            fi
 
            if video_has_module_loaded qcom_iris && video_has_module_loaded iris_vpu; then
                printf '%s\n' "upstream"
                return 0
            fi
 
            # Downstream if only iris_vpu is present (no qcom_iris)
            if video_has_module_loaded iris_vpu && ! video_has_module_loaded qcom_iris; then
                printf '%s\n' "downstream"
                return 0
            fi
            ;;
 
        kodiak)
            # Upstream accepted if:
            # - Venus trio present (canonical upstream on Kodiak), OR
            # - pure upstream build: qcom_iris present and iris_vpu absent
            if video_has_module_loaded venus_core && video_has_module_loaded venus_dec && video_has_module_loaded venus_enc; then
                printf '%s\n' "upstream"
                return 0
            fi
 
            if video_has_module_loaded qcom_iris && ! video_has_module_loaded iris_vpu; then
                printf '%s\n' "upstream"
                return 0
            fi
 
            # Downstream if iris_vpu present and Venus core not loaded
            if video_has_module_loaded iris_vpu && ! video_has_module_loaded venus_core; then
                printf '%s\n' "downstream"
                return 0
            fi
            ;;
    esac
 
    printf '%s\n' "unknown"
    return 1
}

# -----------------------------------------------------------------------------
# Unload all video modules relevant to platform (standalone-like)
# -----------------------------------------------------------------------------
video_unload_all_video_modules() {
    plat="$1"

    tryrmmod() {
        mod="$1"
        if video_has_module_loaded "$mod"; then
            if "$MODPROBE" -r "$mod" 2>/dev/null; then
                log_info "Removed module: $mod"
            else
                log_warn "Could not remove $mod via modprobe -r; retrying after short delay"
                video_usleep 0.2
                if "$MODPROBE" -r "$mod" 2>/dev/null; then
                    log_info "Removed module after retry: $mod"
                else
                    log_warn "Still could not remove: $mod"
                fi
            fi
        fi
    }

    case "$plat" in
        lemans|monaco)
            tryrmmod "$IRIS_UP_MOD"
            tryrmmod "$IRIS_VPU_MOD"
            tryrmmod "$IRIS_UP_MOD"
            ;;
        kodiak)
            tryrmmod "$VENUS_ENC_MOD"
            tryrmmod "$VENUS_DEC_MOD"
            tryrmmod "$VENUS_CORE_MOD"
            tryrmmod "$IRIS_VPU_MOD"
            tryrmmod "$IRIS_UP_MOD"
            ;;
        *)
            :
            ;;
    esac

    depmod -a 2>/dev/null || true
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle 2>/dev/null || true
    fi
    video_usleep "${MOD_SETTLE_SLEEP}"
}

# -----------------------------------------------------------------------------
# Hot switch (best-effort, no reboot) — mirrors standalone flow
# -----------------------------------------------------------------------------
video_hot_switch_modules() {
    plat="$1"
    stack="$2"
    rc=0

    case "$plat" in
        lemans|monaco)
            if [ "$stack" = "downstream" ]; then
                video_block_upstream_strict
                video_unblock_mod_now "$IRIS_VPU_MOD"
                video_usleep "${MOD_SETTLE_SLEEP}"

                video_unload_all_video_modules "$plat"

                if ! video_modprobe_or_insmod "$IRIS_VPU_MOD"; then
                    rc=1
                fi
                video_usleep "${MOD_SETTLE_SLEEP}"

                if video_has_module_loaded "$IRIS_UP_MOD"; then
                    log_warn "$IRIS_UP_MOD reloaded unexpectedly; unloading and keeping block in place"
                    "$MODPROBE" -r "$IRIS_UP_MOD" 2>/dev/null || rc=1
                    video_usleep 0.2
                fi
            else
                video_unblock_mod_now "$IRIS_UP_MOD" "$IRIS_VPU_MOD"
                video_usleep "${MOD_SETTLE_SLEEP}"

                video_unload_all_video_modules "$plat"

                if ! video_modprobe_or_insmod "$IRIS_UP_MOD"; then
                    log_warn "modprobe $IRIS_UP_MOD failed; printing current runtime blocks & retrying"
                    video_list_runtime_blocks
                    video_unblock_mod_now "$IRIS_UP_MOD"
                    video_usleep "${MOD_SETTLE_SLEEP}"
                    video_modprobe_or_insmod "$IRIS_UP_MOD" || rc=1
                fi
                video_modprobe_or_insmod "$IRIS_VPU_MOD" || true
                video_usleep "${MOD_SETTLE_SLEEP}"
            fi
            ;;
        kodiak)
            if [ "$stack" = "downstream" ]; then
                video_block_mod_now "$VENUS_CORE_MOD" "$VENUS_DEC_MOD" "$VENUS_ENC_MOD" "$IRIS_UP_MOD"
                video_unblock_mod_now "$IRIS_VPU_MOD"
                video_usleep "${MOD_SETTLE_SLEEP}"

                "$MODPROBE" -r "$IRIS_VPU_MOD" 2>/dev/null || true
                "$MODPROBE" -r "$VENUS_ENC_MOD" 2>/dev/null || true
                "$MODPROBE" -r "$VENUS_DEC_MOD" 2>/dev/null || true
                "$MODPROBE" -r "$VENUS_CORE_MOD" 2>/dev/null || true
                "$MODPROBE" -r "$IRIS_UP_MOD" 2>/dev/null || true
                video_usleep "${MOD_SETTLE_SLEEP}"

                if ! video_modprobe_or_insmod "$IRIS_VPU_MOD"; then
                    log_warn "Kodiak: failed to load $IRIS_VPU_MOD"
                    rc=1
                fi

                log_info "Kodiak: invoking firmware swap/reload helper (if VIDEO_FW_DS provided)"
                if ! video_kodiak_swap_and_reload "${VIDEO_FW_DS}"; then
                    log_warn "Kodiak: swap/reload helper reported failure (continuing)"
                fi
                video_usleep "${MOD_SETTLE_SLEEP}"

                video_log_fw_hint
            else
                video_unblock_mod_now "$VENUS_CORE_MOD" "$VENUS_DEC_MOD" "$VENUS_ENC_MOD" "$IRIS_VPU_MOD"
                "$MODPROBE" -r "$IRIS_VPU_MOD" 2>/dev/null || true
                video_usleep "${MOD_SETTLE_SLEEP}"
                video_modprobe_or_insmod "$VENUS_CORE_MOD" || rc=1
                video_modprobe_or_insmod "$VENUS_DEC_MOD" || true
                video_modprobe_or_insmod "$VENUS_ENC_MOD" || true
                video_usleep "${MOD_SETTLE_SLEEP}"
                video_log_fw_hint
            fi
            ;;
        *)
            rc=1
            ;;
    esac

    return $rc
}

# -----------------------------------------------------------------------------
# Entry point: ensure desired stack
# -----------------------------------------------------------------------------
video_ensure_stack() {
    want_raw="$1" # upstream|downstream|auto|base|overlay|up|down
    plat="$2"
 
    if [ -z "$plat" ]; then
        plat="$(video_detect_platform)"
    fi
 
    want="$(video_normalize_stack "$want_raw")"
 
    if [ "$want" = "auto" ]; then
        pref="$(video_auto_preference_from_blacklist "$plat")"
        if [ "$pref" != "unknown" ]; then
            want="$pref"
        else
            cur_aut="$(video_stack_status "$plat")"
            if [ "$cur_aut" != "unknown" ]; then
                want="$cur_aut"
            else
                want="upstream"
            fi
        fi
        log_info "AUTO stack selection => $want"
    fi
 
    # ----------------------------------------------------------------------
    # Early no-op: if current state already equals desired, do NOT hot switch.
    # This covers:
    # - Build #1 (pure upstream: qcom_iris only) on lemans/monaco/kodiak
    # - Build #2 (base+overlay: qcom_iris + iris_vpu) when upstream is requested
    # - Downstream already active (e.g., iris_vpu only on lemans/monaco, or kodiak downstream)
    # Still allow Kodiak downstream FW swap without touching modules.
    # ----------------------------------------------------------------------
    cur_state="$(video_stack_status "$plat")"
 
    if [ "$cur_state" = "$want" ]; then
        if [ "$plat" = "kodiak" ] && [ "$want" = "downstream" ] && [ -n "$VIDEO_FW_DS" ] && [ -f "$VIDEO_FW_DS" ]; then
            log_info "Kodiak: downstream already active; applying FW swap + live reload without hot switch."
            video_kodiak_swap_and_reload "$VIDEO_FW_DS" || log_warn "Kodiak: FW swap/reload failed (continuing)"
        fi
        printf '%s\n' "$cur_state"
        return 0
    fi
 
    # Fast paths (retain existing logic; these also help when cur_state was unknown)
    case "$want" in
        upstream|up|base)
            case "$plat" in
                lemans|monaco)
                    if video_has_module_loaded qcom_iris && ! video_has_module_loaded iris_vpu; then
                        printf '%s\n' "upstream"
                        return 0
                    fi
                    ;;
                kodiak)
                    if video_has_module_loaded venus_core && video_has_module_loaded venus_dec && video_has_module_loaded venus_enc; then
                        printf '%s\n' "upstream"
                        return 0
                    fi
                    if video_has_module_loaded qcom_iris && ! video_has_module_loaded iris_vpu; then
                        printf '%s\n' "upstream"
                        return 0
                    fi
                    ;;
            esac
            if video_validate_upstream_loaded "$plat"; then
                printf '%s\n' "upstream"
                return 0
            fi
            ;;
        downstream|overlay|down)
            if video_validate_downstream_loaded "$plat"; then
                if [ "$plat" = "kodiak" ] && [ -n "$VIDEO_FW_DS" ]; then
                    log_info "Kodiak: downstream already loaded, FW override provided — performing FW swap + live reload."
                    video_kodiak_swap_and_reload "$VIDEO_FW_DS" || log_warn "Kodiak: post-switch FW swap/reload failed (continuing)"
                fi
                printf '%s\n' "downstream"
                return 0
            fi
            ;;
    esac
 
    # Only reach here if a switch is actually required.
    video_apply_blacklist_for_stack "$plat" "$want" || return 1
    video_usleep "${MOD_SETTLE_SLEEP}"
 
    video_hot_switch_modules "$plat" "$want" || true
 
    if [ "$plat" = "kodiak" ] && [ "$want" = "downstream" ] && [ -n "$VIDEO_FW_DS" ] && [ -f "$VIDEO_FW_DS" ]; then
        if video_validate_downstream_loaded "$plat"; then
            log_info "Kodiak: downstream active and FW override detected — ensuring FW swap + live reload."
            video_kodiak_swap_and_reload "$VIDEO_FW_DS" || log_warn "Kodiak: post-switch FW swap/reload failed (continuing)"
        fi
    fi
 
    if [ "$want" = "upstream" ]; then
        if video_validate_upstream_loaded "$plat"; then
            printf '%s\n' "upstream"
            return 0
        fi
    else
        if video_validate_downstream_loaded "$plat"; then
            printf '%s\n' "downstream"
            return 0
        fi
    fi
 
    printf '%s\n' "unknown"
    return 1
}

video_block_upstream_strict() {
    video_block_mod_now "$IRIS_UP_MOD"

    if [ -w /etc/modprobe.d ]; then
        if ! grep -q "install[[:space:]]\+${IRIS_UP_MOD}[[:space:]]\+/bin/false" /etc/modprobe.d/qcom_iris-block.conf 2>/dev/null; then
            printf 'install %s /bin/false\n' "$IRIS_UP_MOD" >> /etc/modprobe.d/qcom_iris-block.conf 2>/dev/null || true
        fi

        depmod -a 2>/dev/null || true

        if command -v udevadm >/dev/null 2>&1; then
            udevadm control --reload-rules 2>/dev/null || true
            udevadm settle 2>/dev/null || true
        fi

        video_usleep "${MOD_SETTLE_SLEEP}"
    fi
}

# -----------------------------------------------------------------------------
# udev refresh + prune stale /dev/video* and /dev/media* nodes
# -----------------------------------------------------------------------------
video_clean_and_refresh_v4l() {
    # Refresh udev-managed nodes (best-effort). Do NOT prune/delete anything.
    if video_exist_cmd udevadm; then
        log_info "udev trigger: video4linux/media"
        udevadm trigger --subsystem-match=video4linux --action=change 2>/dev/null || true
        udevadm trigger --subsystem-match=media --action=change 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi
 
    # Recreate missing /dev nodes using /sys/dev/char mapping.
    # Additive-only: never modify existing nodes (no chmod/chgrp on existing).
    for sysdev in /sys/dev/char/*; do
        [ -e "$sysdev" ] || continue
 
        majmin=$(basename "$sysdev")
        case "$majmin" in
            *:*)
                major=${majmin%:*}
                minor=${majmin#*:}
                ;;
            *)
                continue
                ;;
        esac
 
        case "$major" in ''|*[!0-9]*) continue ;; esac
        case "$minor" in ''|*[!0-9]*) continue ;; esac
 
        tgt=$(readlink -f "$sysdev" 2>/dev/null || true)
        [ -n "$tgt" ] || continue
 
        # Media controller nodes
        case "$tgt" in
            */media[0-9]*)
                bn=$(basename "$tgt")   # e.g. media0
                devnode="/dev/$bn"
 
                # Never touch if it already exists
                if [ -e "$devnode" ]; then
                    continue
                fi
 
                log_info "Recreating missing node: $devnode (c $major $minor)"
                mknod "$devnode" c "$major" "$minor" 2>/dev/null || true
                chgrp video "$devnode" 2>/dev/null || true
                chmod 660 "$devnode" 2>/dev/null || true
                ;;
        esac
 
        # V4L2 video nodes
        case "$tgt" in
            */video4linux/video[0-9]*)
                bn=$(basename "$tgt")   # e.g. video0
                devnode="/dev/$bn"
 
                # Never touch if it already exists
                if [ -e "$devnode" ]; then
                    continue
                fi
 
                log_info "Recreating missing node: $devnode (c $major $minor)"
                mknod "$devnode" c "$major" "$minor" 2>/dev/null || true
                chgrp video "$devnode" 2>/dev/null || true
                chmod 660 "$devnode" 2>/dev/null || true
                ;;
        esac
    done
}
# -----------------------------------------------------------------------------
# DMESG triage
# -----------------------------------------------------------------------------
video_scan_dmesg_if_enabled() {
    dm="$1"
    logdir="$2"
    if [ "$dm" -ne 1 ] 2>/dev/null; then
        return 2
    fi
    MODS='oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error'
    EXCL='using dummy regulator|not found|EEXIST|probe deferred'
    if scan_dmesg_errors "$logdir" "$MODS" "$EXCL"; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# JSON helpers (jq-free) — robust multi-key scan
# -----------------------------------------------------------------------------
video_is_decode_cfg() {
    cfg="$1"
    b=$(basename "$cfg" | tr '[:upper:]' '[:lower:]')

    case "$b" in
        *dec*.json)
            return 0
            ;;
        *enc*.json)
            return 1
            ;;
    esac

    dom=$(sed -n 's/.*"Domain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -n 1)
    dom_l=$(printf '%s' "$dom" | tr '[:upper:]' '[:lower:]')

    case "$dom_l" in
        decoder|decode)
            return 0
            ;;
        encoder|encode)
            return 1
            ;;
    esac

    return 0
}

video_extract_scalar() {
    k="$1"
    cfg="$2"
    sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\\([^\"\r\n]*\\)\".*/\\1/p" "$cfg"
}

video_extract_array() {
    k="$1"
    cfg="$2"
    sed -n "s/.*\"$k\"[[:space:]]*:\\s*\\[\\(.*\\)\\].*/\\1/p" "$cfg" \
        | tr ',' '\n' \
        | sed -n 's/.*"\([^"]*\)".*/\1/p'
}

video_extract_array_ml() {
    k="$1"
    cfg="$2"
    awk -v k="$k" '
        $0 ~ "\""k"\"[[:space:]]*:" {in=1}
        in {print; if ($0 ~ /\]/) exit}
    ' "$cfg" \
        | sed -n 's/.*"\([^"]*\)".*/\1/p' \
        | grep -vx "$k"
}

video_strings_from_array_key() {
    k="$1"
    cfg="$2"
    {
        video_extract_array_ml "$k" "$cfg"
        video_extract_array "$k" "$cfg"
    } 2>/dev/null \
        | sed '/^$/d' \
        | awk '!seen[$0]++'
}

video_extract_base_dirs() {
    cfg="$1"
    for k in InputDir InputDirectory InputFolder BasePath BaseDir; do
        video_extract_scalar "$k" "$cfg"
    done \
        | sed '/^$/d' \
        | head -n 1
}

video_guess_codec_from_cfg() {
    cfg="$1"

    for k in Codec codec CodecName codecName VideoCodec videoCodec DecoderName EncoderName Name name; do
        v=$(video_extract_scalar "$k" "$cfg" | head -n 1)
        if [ -n "$v" ]; then
            printf '%s\n' "$v"
            return 0
        fi
    done

    for tok in hevc h265 h264 av1 vp9 vp8 mpeg4 mpeg2 h263 avc; do
        if grep -qiE "(^|[^A-Za-z0-9])${tok}([^A-Za-z0-9]|$)" "$cfg" 2>/dev/null; then
            printf '%s\n' "$tok"
            return 0
        fi
    done

    b=$(basename "$cfg" | tr '[:upper:]' '[:lower:]')
    for tok in hevc h265 h264 av1 vp9 vp8 mpeg4 mpeg2 h263 avc; do
        case "$b" in
            *"$tok"*)
                printf '%s\n' "$tok"
                return 0
                ;;
        esac
    done

    printf '%s\n' "unknown"
    return 0
}

video_canon_codec() {
    c=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$c" in
        h265|hevc)
            printf '%s\n' "hevc"
            ;;
        h264|avc)
            printf '%s\n' "h264"
            ;;
        vp9)
            printf '%s\n' "vp9"
            ;;
        vp8)
            printf '%s\n' "vp8"
            ;;
        av1)
            printf '%s\n' "av1"
            ;;
        mpeg4)
            printf '%s\n' "mpeg4"
            ;;
        mpeg2)
            printf '%s\n' "mpeg2"
            ;;
        h263)
            printf '%s\n' "h263"
            ;;
        *)
            printf '%s\n' "$c"
            ;;
    esac
}

video_pretty_name_from_cfg() {
    cfg="$1"
    base=$(basename "$cfg" .json)
    nm=$(video_extract_scalar "name" "$cfg")
    if [ -z "$nm" ]; then
        nm=$(video_extract_scalar "Name" "$cfg")
    fi
    if video_is_decode_cfg "$cfg"; then
        cd_op="Decode"
    else
        cd_op="Encode"
    fi
    codec=$(video_extract_scalar "codec" "$cfg")
    if [ -z "$codec" ]; then
        codec=$(video_extract_scalar "Codec" "$cfg")
    fi
    nice="$cd_op:$base"
    if [ -n "$nm" ]; then
        nice="$nm"
    elif [ -n "$codec" ]; then
        nice="$cd_op:$codec ($base)"
    fi
    safe=$(printf '%s' "$nice" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')
    printf '%s|%s\n' "$nice" "$safe"
}

# Collect input clip paths from varied schemas (expanded keys)
video_extract_input_clips() {
    cfg="$1"

    {
        for k in \
            InputPath inputPath Inputpath input InputFile input_file infile InFile InFileName \
            FilePath Source Clip File Bitstream BitstreamFile YUV YUVFile YuvFileName Path RawFile RawInput RawYUV \
            Sequence
        do
            video_extract_scalar "$k" "$cfg"
        done
    } 2>/dev/null | sed '/^$/d'

    {
        for k in Inputs InputFiles input_files Clips Files FileList Streams Bitstreams FileNames InputStreams; do
            video_strings_from_array_key "$k" "$cfg"
        done
    } 2>/dev/null | sed '/^$/d'

    basedir=$(video_extract_base_dirs "$cfg")
    if [ -n "$basedir" ]; then
        for arr in Files Inputs Clips InputFiles FileNames; do
            video_strings_from_array_key "$arr" "$cfg" | sed '/^\//! s_^_'"$basedir"'/_'
        done
    fi
}

# -----------------------------------------------------------------------------
# Network-aware clip ensure/fetch
# -----------------------------------------------------------------------------
video_ensure_clips_present_or_fetch() {
    cfg="$1"
    tu="$2"

    clips=$(video_extract_input_clips "$cfg")
    if [ -z "$clips" ]; then
        return 0
    fi

    tmp_list="${LOG_DIR:-.}/.video_missing.$$"
    : > "$tmp_list"

    printf '%s\n' "$clips" | while IFS= read -r p; do
        [ -z "$p" ] && continue
        case "$p" in
            /*)
                abs="$p"
                ;;
            *)
                abs=$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)/$p
                ;;
        esac
        [ -f "$abs" ] || printf '%s\n' "$abs" >> "$tmp_list"
    done

    if [ ! -s "$tmp_list" ]; then
        rm -f "$tmp_list" 2>/dev/null || true
        return 0
    fi

    log_warn "Some input clips are missing (list: $tmp_list)"

    if [ -z "$tu" ]; then
        tu="$TAR_URL"
    fi

    if command -v ensure_network_online >/dev/null 2>&1; then
        if ! ensure_network_online; then
            log_warn "Network offline/limited; cannot fetch media bundle"
            rm -f "$tmp_list" 2>/dev/null || true
            return 2
        fi
    fi

    if [ -n "$tu" ]; then
        log_info "Attempting fetch via TAR_URL=$tu"
        if extract_tar_from_url "$tu"; then
            rm -f "$tmp_list" 2>/dev/null || true
            return 0
        fi
        log_warn "Fetch/extract failed for TAR_URL"
        rm -f "$tmp_list" 2>/dev/null || true
        return 1
    fi

    log_warn "No TAR_URL provided; cannot fetch media bundle."
    rm -f "$tmp_list" 2>/dev/null || true
    return 1
}

# -----------------------------------------------------------------------------
# JUnit helper
# -----------------------------------------------------------------------------
video_junit_append_case() {
    of="$1"
    class="$2"
    name="$3"
    t="$4"
    st="$5"
    logf="$6"

    if [ -z "$of" ]; then
        return 0
    fi

    tailtxt=""
    if [ -f "$logf" ]; then
        tailtxt=$(tail -n 50 "$logf" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
    fi

    {
        printf ' <testcase classname="%s" name="%s" time="%s">\n' "$class" "$name" "$t"
        case "$st" in
            PASS)
                :
                ;;
            SKIP)
                printf ' <skipped/>\n'
                ;;
            FAIL)
                printf ' <failure message="%s">\n' "failed"
                printf '%s\n' "$tailtxt"
                printf ' </failure>\n'
                ;;
        esac
        printf ' </testcase>\n'
    } >> "$of"
}

# -----------------------------------------------------------------------------
# Timeout wrapper availability + single run
# -----------------------------------------------------------------------------
video_have_run_with_timeout() {
    video_exist_cmd run_with_timeout
}

video_prepare_app() {
    app="${VIDEO_APP:-/usr/bin/iris_v4l2_test}"

    if [ -z "$app" ] || [ ! -e "$app" ]; then
        log_fail "App not found: $app"
        return 1
    fi

    if [ -x "$app" ]; then
        return 0
    fi

    if chmod +x "$app" 2>/dev/null; then
        log_info "Set executable bit on $app"
        return 0
    fi

    tmp="/tmp/$(basename "$app").$$"
    if cp -f "$app" "$tmp" 2>/dev/null && chmod +x "$tmp" 2>/dev/null; then
        VIDEO_APP="$tmp"
        log_info "Using temp executable copy: $VIDEO_APP"
        return 0
    fi

    log_warn "Could not make app executable (chmod/copy failed). Execution may fail."
    return 1
}

video_run_once() {
    cfg="$1"
    logf="$2"
    tmo="$3"
    suc="$4"
    lvl="$5"

    video_prepare_app || true

    : > "$logf"

    {
        iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo now)"
        printf 'BEGIN-RUN %s\n' "$iso_now"
        printf 'APP=%s\n' "$VIDEO_APP"
        printf 'CFG=%s\n' "$cfg"
        printf 'LOGLEVEL=%s TIMEOUT=%s\n' "$lvl" "${tmo:-none}"
        printf 'CMD=%s %s %s %s\n' "$VIDEO_APP" "--config" "$cfg" "--loglevel $lvl"
    } >>"$logf" 2>&1

    if video_have_run_with_timeout; then
        if run_with_timeout "$tmo" "$VIDEO_APP" --config "$cfg" --loglevel "$lvl" >>"$logf" 2>&1; then
            :
        else
            rc=$?
            if [ "$rc" -eq 124 ] 2>/dev/null; then
                log_fail "[run] timeout after ${tmo}s"
            else
                log_fail "[run] $VIDEO_APP exited rc=$rc"
            fi
            printf 'END-RUN rc=%s\n' "$rc" >>"$logf"
            grep -Eq "$suc" "$logf"
            return $?
        fi
    else
        if "$VIDEO_APP" --config "$cfg" --loglevel "$lvl" >>"$logf" 2>&1; then
            :
        else
            rc=$?
            log_fail "[run] $VIDEO_APP exited rc=$rc (no timeout enforced)"
            printf 'END-RUN rc=%s\n' "$rc" >>"$logf"
            grep -Eq "$suc" "$logf"
            return $?
        fi
    fi

    printf 'END-RUN rc=0\n' >>"$logf"
    grep -Eq "$suc" "$logf"
}

# -----------------------------------------------------------------------------
# Kodiak firmware swap + live reload (no reboot)
# -----------------------------------------------------------------------------
video_kodiak_fw_basename() {
    printf '%s\n' "vpu20_p1_gen2.mbn"
}

video_kodiak_install_fw() {
    # usage: video_kodiak_install_fw /path/to/vpuw20_1v.mbn
    src="$1"

    if [ -z "$src" ] || [ ! -f "$src" ]; then
        log_warn "Kodiak FW src missing: $src"
        return 1
    fi

    dst="$FW_PATH_KODIAK"
    tmp="${dst}.new.$$"

    mkdir -p "$(dirname "$dst")" 2>/dev/null || true

    if [ -f "$dst" ]; then
        mkdir -p "$FW_BACKUP_DIR" 2>/dev/null || true
        ts=$(date +%Y%m%d%H%M%S 2>/dev/null || printf '%s' "now")
        cp -f "$dst" "$FW_BACKUP_DIR/vpu20_p1_gen2.mbn.$ts.bak" 2>/dev/null || true
    fi

    if ! cp -f "$src" "$tmp" 2>/dev/null; then
        log_warn "FW copy to temp failed: $tmp"
        return 1
    fi

    chmod 0644 "$tmp" 2>/dev/null || true
    chown root:root "$tmp" 2>/dev/null || true

    if ! mv -f "$tmp" "$dst" 2>/dev/null; then
        log_warn "FW mv into place failed: $dst"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    sync || true

    if command -v restorecon >/dev/null 2>&1; then
        restorecon "$dst" 2>/dev/null || true
    fi

    log_info "Kodiak FW installed at: $dst (from: $(basename "$src"))"
    return 0
}

video_kodiak_install_firmware() {
    src_dir="${VIDEO_FW_BACKUP_DIR:-/opt}"
    dest="/lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn"

    if [ ! -d "$src_dir" ]; then
        log_warn "Backup dir not found: $src_dir"
        return 0
    fi

    mkdir -p "$(dirname "$dest")" 2>/dev/null || true

    candidates=""
    for g in \
        "$src_dir"/vpu20_p1_gen2_*.mbn \
        "$src_dir"/vpu20_p1_gen2.mbn.* \
        "$src_dir"/vpu20_p1_gen2*.mbn.bak \
        "$src_dir"/vpu20_p1_gen2*.bak \
        "$src_dir"/vpu20_p1_gen2*.mbn.* \
    ; do
        for f in $g; do
            if [ -f "$f" ]; then
                candidates="$candidates
$f"
            fi
        done
    done

    if [ -z "$candidates" ]; then
        log_warn "No backup firmware found under $src_dir (tried patterns: vpu20_p1_gen2_*.mbn, vpu20_p1_gen2.mbn.*, *.mbn.bak, *.bak)"
        return 0
    fi

    newest=""
    for f in $candidates; do
        [ -f "$f" ] || continue
        if [ -z "$newest" ] || [ -n "$(find "$f" -prune -newer "$newest" -print -quit 2>/dev/null)" ]; then
            newest="$f"
        fi
    done

    if [ -z "$newest" ]; then
        newest="$(printf '%s\n' "$candidates" | head -n1)"
    fi

    log_info "Using backup firmware: $newest → $dest"

    if cp -f "$newest" "$dest" 2>/dev/null; then
        chmod 0644 "$dest" 2>/dev/null || true
        log_pass "Installed Kodiak upstream firmware to $dest"
        return 0
    fi

    log_warn "cp failed; trying install -D"

    if install -m 0644 -D "$newest" "$dest" 2>/dev/null; then
        log_pass "Installed Kodiak upstream firmware to $dest"
        return 0
    fi

    log_error "Failed to install firmware from $newest to $dest"
    return 1
}

# remoteproc reload must reference the *destination* basename
video_kodiak_fw_basename() {
    printf '%s\n' "vpu20_p1_gen2.mbn"
}

video_kodiak_try_remoteproc_reload() {
    bn="$(video_kodiak_fw_basename)"
    did=0

    for rp in /sys/class/remoteproc/remoteproc*; do
        [ -d "$rp" ] || continue
        name="$(tr '[:upper:]' '[:lower:]' < "$rp/name" 2>/dev/null)"
        case "$name" in
            *vpu*|*video*|*iris*)
                log_info "remoteproc: $rp (name=$name)"
                if [ -r "$rp/state" ]; then
                    log_info "remoteproc state (pre): $(cat "$rp/state" 2>/dev/null)"
                fi
                if [ -w "$rp/state" ]; then
                    echo stop > "$rp/state" 2>/dev/null || true
                fi
                if [ -w "$rp/firmware" ]; then
                    printf '%s' "$bn" > "$rp/firmware" 2>/dev/null || true
                fi
                if [ -w "$rp/state" ]; then
                    echo start > "$rp/state" 2>/dev/null || true
                fi
                video_usleep 1
                if [ -r "$rp/state" ]; then
                    log_info "remoteproc state (post): $(cat "$rp/state" 2>/dev/null)"
                fi
                did=1
                ;;
        esac
    done

    if [ $did -eq 1 ]; then
        log_info "remoteproc reload attempted with $bn"
        return 0
    fi

    return 1
}

video_kodiak_try_module_reload() {
    rc=1

    if video_has_module_loaded "$IRIS_VPU_MOD"; then
        log_info "module reload: rmmod $IRIS_VPU_MOD"
        "$MODPROBE" -r "$IRIS_VPU_MOD" 2>/dev/null || true
        video_usleep 1
    fi

    log_info "module reload: modprobe $IRIS_VPU_MOD"

    if "$MODPROBE" "$IRIS_VPU_MOD" 2>/dev/null; then
        rc=0
    else
        ko=$("$MODPROBE" -n -v "$IRIS_VPU_MOD" 2>/dev/null | awk '/(^| )insmod( |$)/ {print $2; exit}')
        if [ -n "$ko" ] && [ -f "$ko" ]; then
            log_info "module reload: insmod $ko"
            if insmod "$ko" 2>/dev/null; then
                rc=0
            else
                rc=1
            fi
        fi
    fi

    if [ $rc -eq 0 ]; then
        log_info "iris_vpu module reloaded"
    fi

    return $rc
}

video_kodiak_try_unbind_bind() {
    did=0

    for drv in /sys/bus/platform/drivers/*; do
        [ -d "$drv" ] || continue
        case "$(basename "$drv")" in
            *iris*|*vpu*|*video*)
                for dev in "$drv"/*; do
                    [ -L "$dev" ] || continue
                    dn="$(basename "$dev")"
                    log_info "platform: unbind $dn from $(basename "$drv")"
                    if [ -w "$drv/unbind" ]; then
                        echo "$dn" > "$drv/unbind" 2>/dev/null || true
                    fi
                    video_usleep 1
                    log_info "platform: bind $dn to $(basename "$drv")"
                    if [ -w "$drv/bind" ]; then
                        echo "$dn" > "$drv/bind" 2>/dev/null || true
                    fi
                    did=1
                done
                ;;
        esac
    done

    if [ $did -eq 1 ]; then
        log_info "platform unbind/bind attempted"
        return 0
    fi

    return 1
}

video_kodiak_swap_and_reload() {
    # usage: video_kodiak_swap_and_reload /path/to/newfw.mbn
    newsrc="$1"

    if [ -z "$newsrc" ] || [ ! -f "$newsrc" ]; then
        log_warn "No FW source to install (VIDEO_FW_DS unset or missing)"
        return 1
    fi

    video_kodiak_install_fw "$newsrc" || return 1

    if video_kodiak_try_remoteproc_reload; then
        video_clean_and_refresh_v4l
        return 0
    fi

    if video_kodiak_try_module_reload; then
        video_clean_and_refresh_v4l
        return 0
    fi

    if video_kodiak_try_unbind_bind; then
        video_clean_and_refresh_v4l
        return 0
    fi

    log_warn "FW reload attempts did not confirm success (remoteproc/module/unbind)."
    return 1
}

if ! command -v video_try_modprobe_then_insmod >/dev/null 2>&1; then
video_try_modprobe_then_insmod() {
    m="$1"

    if "$MODPROBE" "$m" 2>/dev/null; then
        return 0
    fi

    p="$("$MODPROBE" -n -v "$m" 2>/dev/null | awk '/(^| )insmod( |$)/ {print $2; exit}')"
    if [ -n "$p" ] && [ -f "$p" ]; then
        if insmod "$p" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}
fi

# --- Persistent blacklist storage (if not already defined) ---
: "${BLACKLIST_DIR:=/etc/modprobe.d}"
: "${BLACKLIST_FILE:=$BLACKLIST_DIR/blacklist.conf}"

video_is_blacklisted() {
    tok="$1"
    if [ ! -f "$BLACKLIST_FILE" ]; then
        return 1
    fi
    grep -q "^blacklist[[:space:]]\+$tok$" "$BLACKLIST_FILE" 2>/dev/null
}

video_ensure_blacklist() {
    tok="$1"
    mkdir -p "$BLACKLIST_DIR" 2>/dev/null || true
    if ! video_is_blacklisted "$tok"; then
        printf 'blacklist %s\n' "$tok" >>"$BLACKLIST_FILE"
        log_info "Added persistent blacklist for: $tok"
    fi
}

video_remove_blacklist() {
    tok="$1"
    if [ ! -f "$BLACKLIST_FILE" ]; then
        return 0
    fi
    tmp="$BLACKLIST_FILE.tmp.$$"
    sed "/^[[:space:]]*blacklist[[:space:]]\+${tok}[[:space:]]*$/d" \
        "$BLACKLIST_FILE" >"$tmp" 2>/dev/null && mv "$tmp" "$BLACKLIST_FILE"
    log_info "Removed persistent blacklist for: $tok"
}

# -----------------------------------------------------------------------------
# Blacklist desired stack (persistent, cross-boot)
# -----------------------------------------------------------------------------
video_apply_blacklist_for_stack() {
    plat="$1"
    stack="$2"

    case "$plat" in
        lemans|monaco)
            if [ "$stack" = "downstream" ]; then
                video_ensure_blacklist "qcom-iris"
                video_ensure_blacklist "qcom_iris"
                video_remove_blacklist "iris-vpu"
                video_remove_blacklist "iris_vpu"
            else
                video_remove_blacklist "qcom-iris"
                video_remove_blacklist "qcom_iris"
                video_remove_blacklist "iris-vpu"
                video_remove_blacklist "iris_vpu"
            fi
            ;;
        kodiak)
            if [ "$stack" = "downstream" ]; then
                video_ensure_blacklist "venus-core"
                video_ensure_blacklist "venus_core"
                video_ensure_blacklist "venus-dec"
                video_ensure_blacklist "venus_dec"
                video_ensure_blacklist "venus-enc"
                video_ensure_blacklist "venus_enc"
                video_remove_blacklist "iris-vpu"
                video_remove_blacklist "iris_vpu"
            else
                video_remove_blacklist "venus-core"
                video_remove_blacklist "venus_core"
                video_remove_blacklist "venus-dec"
                video_remove_blacklist "venus_dec"
                video_remove_blacklist "venus-enc"
                video_remove_blacklist "venus_enc"
                video_remove_blacklist "iris-vpu"
                video_remove_blacklist "iris_vpu"
            fi
            ;;
        *)
            return 1
            ;;
    esac

    depmod -a 2>/dev/null || true
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi
    video_usleep "${MOD_SETTLE_SLEEP}"

    return 0
}

# -----------------------------------------------------------------------------
# AUTO preference helper using persistent blacklists
# -----------------------------------------------------------------------------
video_auto_preference_from_blacklist() {
    plat="$1"

    case "$plat" in
        lemans|monaco)
            if video_is_blacklisted "qcom-iris" || video_is_blacklisted "qcom_iris"; then
                printf '%s\n' "downstream"
                return 0
            fi
            ;;
        kodiak)
            if video_is_blacklisted "venus-core" || video_is_blacklisted "venus_core" \
               || video_is_blacklisted "venus-dec" || video_is_blacklisted "venus_dec" \
               || video_is_blacklisted "venus-enc" || video_is_blacklisted "venus_enc"; then
                printf '%s\n' "downstream"
                return 0
            fi
            ;;
    esac

    printf '%s\n' "unknown"
    return 0
}
