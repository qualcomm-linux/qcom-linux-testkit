#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Common, POSIX-compliant helpers for Qualcomm video stack selection and V4L2 testing.
# Requires functestlib.sh: log_info/log_warn/log_pass/log_fail/log_skip,
# check_dependencies, extract_tar_from_url, (optional) run_with_timeout, ensure_network_online.

# -----------------------------------------------------------------------------
# Public env knobs (may be exported by caller or set via CLI in run.sh)
# -----------------------------------------------------------------------------
# VIDEO_STACK auto|upstream|downstream|base|overlay|up|down (default: auto)
# VIDEO_PLATFORM lemans|monaco|kodiak|"" (auto-detect)
# VIDEO_FW_DS Downstream FW for Kodiak (e.g. /opt/downstream/vpu20_p1_gen2.mbn)
# VIDEO_FW_BACKUP_DIR Where to backup FW (default: /opt)
# VIDEO_NO_REBOOT 1 = don't suggest reboot; we hot-switch best-effort (default 0)
# VIDEO_FORCE 1 = force re-switch even if looks OK (default 0)
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

BLACKLIST_DIR="/etc/modprobe.d"
BLACKLIST_FILE="$BLACKLIST_DIR/blacklist.conf"

FW_PATH_KODIAK="/lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn"
FW_BACKUP_DIR="${VIDEO_FW_BACKUP_DIR:-/opt}"

MODPROBE="$(command -v modprobe 2>/dev/null || printf '%s' /sbin/modprobe)"
LSMOD="$(command -v lsmod 2>/dev/null || printf '%s' /sbin/lsmod)"

# Default app path (caller may override via env)
VIDEO_APP="${VIDEO_APP:-/usr/bin/iris_v4l2_test}"

# -----------------------------------------------------------------------------
# Tiny utils
# -----------------------------------------------------------------------------
video_exist_cmd() { command -v "$1" >/dev/null 2>&1; }

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
    # Step logger for CI: video_step "[id]" "message"
    id="$1"; msg="$2"
    if [ -n "$id" ]; then
        log_info "[$id] STEP: $msg"
    else
        log_info "STEP: $msg"
    fi
}

# -----------------------------------------------------------------------------
# Stack normalization & auto preference
# -----------------------------------------------------------------------------
video_normalize_stack() {
    s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$s" in
        upstream|base|up) printf '%s\n' "upstream" ;;
        downstream|overlay|down) printf '%s\n' "downstream" ;;
        auto|"") printf '%s\n' "auto" ;;
        *) printf '%s\n' "$s" ;;
    esac
}

video_is_blacklisted() {
    tok="$1"
    [ -f "$BLACKLIST_FILE" ] || return 1
    grep -q "^blacklist[[:space:]]\+$tok$" "$BLACKLIST_FILE" 2>/dev/null
}

video_auto_preference_from_blacklist() {
    plat="$1"
    case "$plat" in
        lemans|monaco)
            if video_is_blacklisted "qcom-iris" || video_is_blacklisted "qcom_iris"; then
                printf '%s\n' "downstream"; return 0
            fi
            ;;
        kodiak)
            if video_is_blacklisted "venus-core" || video_is_blacklisted "venus_core" \
               || video_is_blacklisted "venus-dec" || video_is_blacklisted "venus_dec" \
               || video_is_blacklisted "venus-enc" || video_is_blacklisted "venus_enc"; then
                printf '%s\n' "downstream"; return 0
            fi
            ;;
    esac
    printf '%s\n' "unknown"
    return 0
}

# -----------------------------------------------------------------------------
# Blacklist management
# -----------------------------------------------------------------------------
video_ensure_blacklist() {
    tok="$1"
    mkdir -p "$BLACKLIST_DIR" 2>/dev/null || true
    if [ -f "$BLACKLIST_FILE" ] && grep -q "^blacklist[[:space:]]\+$tok$" "$BLACKLIST_FILE" 2>/dev/null; then
        return 0
    fi
    printf 'blacklist %s\n' "$tok" >>"$BLACKLIST_FILE"
}

video_remove_blacklist() {
    tok="$1"
    if [ -f "$BLACKLIST_FILE" ]; then
        tmp="$BLACKLIST_FILE.tmp.$$"
		sed "/^[[:space:]]*blacklist[[:space:]]\+${tok}[[:space:]]*$/d" "$BLACKLIST_FILE" >"$tmp" 2>/dev/null && mv "$tmp" "$BLACKLIST_FILE"
    fi
}

# -----------------------------------------------------------------------------
# Platform detect → lemans|monaco|kodiak|unknown
# -----------------------------------------------------------------------------
video_detect_platform() {
    model=""; compat=""
    if [ -r /proc/device-tree/model ]; then model=$(tr -d '\000' </proc/device-tree/model 2>/dev/null); fi
    if [ -r /proc/device-tree/compatible ]; then compat=$(tr -d '\000' </proc/device-tree/compatible 2>/dev/null); fi
    s=$(printf '%s\n%s\n' "$model" "$compat" | tr '[:upper:]' '[:lower:]')

    echo "$s" | grep -q "qcs9100" && { printf '%s\n' "lemans"; return 0; }
    echo "$s" | grep -q "qcs8300" && { printf '%s\n' "monaco"; return 0; }
    echo "$s" | grep -q "qcs6490" && { printf '%s\n' "kodiak"; return 0; }
    echo "$s" | grep -q "ride-sx" && echo "$s" | grep -q "9100" && { printf '%s\n' "lemans"; return 0; }
    echo "$s" | grep -q "ride-sx" && echo "$s" | grep -q "8300" && { printf '%s\n' "monaco"; return 0; }
    echo "$s" | grep -q "rb3" && echo "$s" | grep -q "6490" && { printf '%s\n' "kodiak"; return 0; }

    printf '%s\n' "unknown"
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
video_validate_upstream_loaded() {
    plat="$1"
    case "$plat" in
        lemans|monaco)
            video_has_module_loaded "$IRIS_UP_MOD" && video_has_module_loaded "$IRIS_VPU_MOD"
            return $?
            ;;
        kodiak)
            video_has_module_loaded "$VENUS_CORE_MOD" && video_has_module_loaded "$VENUS_DEC_MOD" && video_has_module_loaded "$VENUS_ENC_MOD"
            return $?
            ;;
        *) return 1 ;;
    esac
}

video_validate_downstream_loaded() {
    plat="$1"
    case "$plat" in
        lemans|monaco|kodiak)
            video_has_module_loaded "$IRIS_VPU_MOD"
            return $?
            ;;
        *) return 1 ;;
    esac
}

video_stack_status() {
    plat="$1"
    if video_validate_downstream_loaded "$plat"; then
        printf '%s\n' "downstream"
    elif video_validate_upstream_loaded "$plat"; then
        printf '%s\n' "upstream"
    else
        printf '%s\n' "unknown"
    fi
}

# -----------------------------------------------------------------------------
# Blacklist desired stack
# -----------------------------------------------------------------------------
video_apply_blacklist_for_stack() {
    plat="$1"; stack="$2"
    case "$plat" in
        lemans|monaco)
            if [ "$stack" = "downstream" ]; then
                video_ensure_blacklist "qcom-iris"; video_ensure_blacklist "qcom_iris"
                video_remove_blacklist "iris-vpu"; video_remove_blacklist "iris_vpu"
            else
                video_remove_blacklist "qcom-iris"; video_remove_blacklist "qcom_iris"
                video_remove_blacklist "iris-vpu"; video_remove_blacklist "iris_vpu"
            fi
            ;;
        kodiak)
            if [ "$stack" = "downstream" ]; then
                video_ensure_blacklist "venus-core"; video_ensure_blacklist "venus_core"
                video_ensure_blacklist "venus-dec"; video_ensure_blacklist "venus_dec"
                video_ensure_blacklist "venus-enc"; video_ensure_blacklist "venus_enc"
                video_remove_blacklist "iris-vpu"; video_remove_blacklist "iris_vpu"
            else
                video_remove_blacklist "venus-core"; video_remove_blacklist "venus_core"
                video_remove_blacklist "venus-dec"; video_remove_blacklist "venus_dec"
                video_remove_blacklist "venus-enc"; video_remove_blacklist "venus_enc"
                video_remove_blacklist "iris-vpu"; video_remove_blacklist "iris_vpu"
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# Optional: log firmware hint after reload
# -----------------------------------------------------------------------------
video_log_fw_hint() {
    if video_exist_cmd dmesg; then
        out="$(dmesg 2>/dev/null | tail -n 200 | grep -Ei 'firmware|iris_vpu|venus' | tail -n 10)"
        if [ -n "$out" ]; then
            printf '%s\n' "$out" | while IFS= read -r ln; do log_info "dmesg: $ln"; done
        fi
    fi
}

# -----------------------------------------------------------------------------
# Hot switch (best-effort, no reboot)
# -----------------------------------------------------------------------------
video_hot_switch_modules() {
    plat="$1"; stack="$2"; rc=0

    case "$plat" in
        lemans|monaco)
            if [ "$stack" = "downstream" ]; then
                if video_has_module_loaded "$IRIS_UP_MOD"; then "$MODPROBE" -r "$IRIS_UP_MOD" 2>/dev/null || rc=1; fi
                if ! video_has_module_loaded "$IRIS_VPU_MOD"; then "$MODPROBE" "$IRIS_VPU_MOD" 2>/dev/null || rc=1; fi
            else
                if video_has_module_loaded "$IRIS_VPU_MOD"; then "$MODPROBE" -r "$IRIS_VPU_MOD" 2>/dev/null || true; fi
                "$MODPROBE" "$IRIS_UP_MOD" 2>/dev/null || rc=1
                "$MODPROBE" "$IRIS_VPU_MOD" 2>/dev/null || true
            fi
            ;;
        kodiak)
            if [ "$stack" = "downstream" ]; then
                if video_has_module_loaded "$IRIS_VPU_MOD"; then "$MODPROBE" -r "$IRIS_VPU_MOD" 2>/dev/null || rc=1; fi
                "$MODPROBE" -r "$VENUS_ENC_MOD" 2>/dev/null || true
                "$MODPROBE" -r "$VENUS_DEC_MOD" 2>/dev/null || true
                "$MODPROBE" -r "$VENUS_CORE_MOD" 2>/dev/null || true
                if [ -n "$VIDEO_FW_DS" ]; then
                    mkdir -p "$(dirname "$FW_PATH_KODIAK")" 2>/dev/null || true
                    mkdir -p "$FW_BACKUP_DIR" 2>/dev/null || true
                    ts=$(date +%Y%m%d%H%M%S 2>/dev/null || printf '%s' "now")
                    if [ -f "$FW_PATH_KODIAK" ]; then
                        cp -f "$FW_PATH_KODIAK" "$FW_BACKUP_DIR/vpu20_p1_gen2.mbn.$ts.bak" 2>/dev/null || true
                    fi
                    if [ -f "$VIDEO_FW_DS" ]; then
                        cp -f "$VIDEO_FW_DS" "$FW_PATH_KODIAK" 2>/dev/null || rc=1
                    else
                        log_warn "Downstream FW not found: $VIDEO_FW_DS"
                        rc=1
                    fi
                fi
                "$MODPROBE" "$IRIS_VPU_MOD" 2>/dev/null || rc=1
                video_log_fw_hint
            else
                "$MODPROBE" -r "$IRIS_VPU_MOD" 2>/dev/null || true
                "$MODPROBE" "$VENUS_CORE_MOD" 2>/dev/null || rc=1
                "$MODPROBE" "$VENUS_DEC_MOD" 2>/dev/null || true
                "$MODPROBE" "$VENUS_ENC_MOD" 2>/dev/null || true
                video_log_fw_hint
            fi
            ;;
        *) rc=1 ;;
    esac
    return $rc
}

# -----------------------------------------------------------------------------
# Entry point: ensure desired stack
# -----------------------------------------------------------------------------
video_ensure_stack() {
    want_raw="$1" # upstream|downstream|auto|base|overlay|up|down
    plat="$2"

    if [ -z "$plat" ]; then plat=$(video_detect_platform); fi
    want="$(video_normalize_stack "$want_raw")"

    if [ "$want" = "auto" ]; then
        pref="$(video_auto_preference_from_blacklist "$plat")"
        if [ "$pref" != "unknown" ]; then want="$pref"; else
            cur="$(video_stack_status "$plat")"
            if [ "$cur" != "unknown" ]; then want="$cur"; else
                want="upstream"
            fi
        fi
        log_info "AUTO stack selection => $want"
    fi

    if [ "$want" = "upstream" ]; then
        if video_validate_upstream_loaded "$plat"; then printf '%s\n' "upstream"; return 0; fi
    else
        if video_validate_downstream_loaded "$plat"; then printf '%s\n' "downstream"; return 0; fi
    fi

    video_apply_blacklist_for_stack "$plat" "$want" || return 1
    video_hot_switch_modules "$plat" "$want" || true

    if [ "$want" = "upstream" ]; then
        if video_validate_upstream_loaded "$plat"; then printf '%s\n' "upstream"; return 0; fi
    else
        if video_validate_downstream_loaded "$plat"; then printf '%s\n' "downstream"; return 0; fi
    fi

    printf '%s\n' "unknown"
    return 1
}

# -----------------------------------------------------------------------------
# DMESG triage
# -----------------------------------------------------------------------------
video_scan_dmesg_if_enabled() {
    dm="$1"; logdir="$2"
    if [ "$dm" -ne 1 ] 2>/dev/null; then return 2; fi
    MODS='oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error'
    EXCL='using dummy regulator|not found|EEXIST|probe deferred'
    if scan_dmesg_errors "$logdir" "$MODS" "$EXCL"; then return 0; fi
    return 1
}

# -----------------------------------------------------------------------------
# JSON helpers (jq-free)
# -----------------------------------------------------------------------------
video_is_decode_cfg() {
    cfg="$1"
    b=$(basename "$cfg" | tr '[:upper:]' '[:lower:]')
    case "$b" in *dec*.json) return 0 ;; *enc*.json) return 1 ;; esac
    dom=$(sed -n 's/.*"Domain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -n 1)
    dom_l=$(printf '%s' "$dom" | tr '[:upper:]' '[:lower:]')
    case "$dom_l" in decoder|decode) return 0 ;; encoder|encode) return 1 ;; esac
    return 0
}

video_extract_scalar() { k="$1"; cfg="$2"; sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\\([^\"\r\n]*\\)\".*/\\1/p" "$cfg"; }
video_extract_array() { k="$1"; cfg="$2"; sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\\[\\(.*\\)\\].*/\\1/p" "$cfg" | tr ',' '\n' | sed -n 's/.*"\([^"]*\)".*/\1/p'; }

video_extract_input_clips() {
    cfg="$1"
    {
        video_extract_scalar "InputPath" "$cfg"
        video_extract_scalar "Inputpath" "$cfg"
        video_extract_scalar "inputPath" "$cfg"
        video_extract_scalar "input" "$cfg"
        video_extract_scalar "InputFile" "$cfg"
        video_extract_scalar "Source" "$cfg"
        video_extract_scalar "Clip" "$cfg"
        video_extract_array "Inputs" "$cfg"
        video_extract_array "Clips" "$cfg"
        video_extract_array "Files" "$cfg"
    } 2>/dev/null | sed '/^$/d' | sort -u
}

video_guess_codec_from_cfg() {
    cfg="$1"
    for k in Codec codec CodecName codecName VideoCodec videoCodec DecoderName EncoderName Name name; do
        v=$(video_extract_scalar "$k" "$cfg" | head -n 1)
        if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
    done
    for tok in hevc h265 h264 av1 vp9 vp8 mpeg4 mpeg2 h263 avc; do
        if grep -qiE "(^|[^A-Za-z0-9])${tok}([^A-Za-z0-9]|$)" "$cfg" 2>/dev/null; then printf '%s\n' "$tok"; return 0; fi
    done
    b=$(basename "$cfg" | tr '[:upper:]' '[:lower:]')
    for tok in hevc h265 h264 av1 vp9 vp8 mpeg4 mpeg2 h263 avc; do case "$b" in *"$tok"*) printf '%s\n' "$tok"; return 0 ;; esac; done
    printf '%s\n' "unknown"
    return 0
}

video_canon_codec() {
    c=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$c" in
        h265|hevc) printf '%s\n' "hevc" ;;
        h264|avc) printf '%s\n' "h264" ;;
        vp9) printf '%s\n' "vp9" ;;
        vp8) printf '%s\n' "vp8" ;;
        av1) printf '%s\n' "av1" ;;
        mpeg4) printf '%s\n' "mpeg4" ;;
        mpeg2) printf '%s\n' "mpeg2" ;;
        h263) printf '%s\n' "h263" ;;
        *) printf '%s\n' "$c" ;;
    esac
}

video_pretty_name_from_cfg() {
    cfg="$1"; base=$(basename "$cfg" .json)
    nm=$(video_extract_scalar "name" "$cfg"); [ -z "$nm" ] && nm=$(video_extract_scalar "Name" "$cfg")
    if video_is_decode_cfg "$cfg"; then cd_op="Decode"; else cd_op="Encode"; fi
    codec=$(video_extract_scalar "codec" "$cfg"); [ -z "$codec" ] && codec=$(video_extract_scalar "Codec" "$cfg")
    nice="$cd_op:$base"
    if [ -n "$nm" ]; then nice="$nm"; elif [ -n "$codec" ]; then nice="$cd_op:$codec ($base)"; fi
    safe=$(printf '%s' "$nice" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')
    printf '%s|%s\n' "$nice" "$safe"
}

# -----------------------------------------------------------------------------
# Network-aware clip ensure/fetch
# Returns:
# 0 = ok (clips present or fetched)
# 2 = offline/limited network → caller should SKIP decode cases
# 1 = attempted online but fetch/extract failed → caller should FAIL
# -----------------------------------------------------------------------------
video_ensure_clips_present_or_fetch() {
    cfg="$1"; tu="$2"
    clips=$(video_extract_input_clips "$cfg")
    if [ -z "$clips" ]; then return 0; fi

    tmp_list="${LOG_DIR:-.}/.video_missing.$$"
    : > "$tmp_list"
    printf '%s\n' "$clips" | while IFS= read -r p; do
        [ -z "$p" ] && continue
        case "$p" in /*) abs="$p" ;; *) abs=$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)/$p ;; esac
        [ -f "$abs" ] || printf '%s\n' "$abs" >> "$tmp_list"
    done

    if [ ! -s "$tmp_list" ]; then
        rm -f "$tmp_list" 2>/dev/null || true
        return 0
    fi

    log_warn "Some input clips are missing (list: $tmp_list)"
    [ -z "$tu" ] && tu="$TAR_URL"

    # Network awareness (uses functestlib's ensure_network_online if available)
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
    of="$1"; class="$2"; name="$3"; t="$4"; st="$5"; logf="$6"
    [ -n "$of" ] || return 0
    tailtxt=""
    if [ -f "$logf" ]; then
        tailtxt=$(tail -n 50 "$logf" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
    fi
    {
        printf ' <testcase classname="%s" name="%s" time="%s">\n' "$class" "$name" "$t"
        case "$st" in
            PASS) : ;;
            SKIP) printf ' <skipped/>\n' ;;
            FAIL) printf ' <failure message="%s">\n' "failed"; printf '%s\n' "$tailtxt"; printf ' </failure>\n' ;;
        esac
        printf ' </testcase>\n'
    } >> "$of"
}

# -----------------------------------------------------------------------------
# Timeout wrapper availability + single run
# -----------------------------------------------------------------------------
video_have_run_with_timeout() { video_exist_cmd run_with_timeout; }

video_run_once() {
    cfg="$1"; logf="$2"; tmo="$3"; suc="$4"; lvl="$5"
    : > "$logf"

    # Header lines for per-case debugging (captured in log)
    {
        iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo now)"
        printf 'BEGIN-RUN %s\n' "$iso_now"
        printf 'APP=%s\n' "$VIDEO_APP"
        printf 'CFG=%s\n' "$cfg"
        printf 'LOGLEVEL=%s TIMEOUT=%s\n' "$lvl" "${tmo:-none}"
        printf 'CMD=%s %s %s %s\n' "$VIDEO_APP" "--config" "$cfg" "--loglevel $lvl"
    } >>"$logf" 2>&1

    if video_have_run_with_timeout; then
        if run_with_timeout "$tmo" "$VIDEO_APP" --config "$cfg" --loglevel "$lvl" >>"$logf" 2>&1; then :; else
            rc=$?
            if [ "$rc" -eq 124 ] 2>/dev/null; then log_fail "[run] timeout after ${tmo}s"; else log_fail "[run] $VIDEO_APP exited rc=$rc"; fi
            # Footer with explicit run result
            printf 'END-RUN rc=%s\n' "$rc" >>"$logf"
            grep -Eq "$suc" "$logf"
            return $?
        fi
    else
        if "$VIDEO_APP" --config "$cfg" --loglevel "$lvl" >>"$logf" 2>&1; then :; else
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

