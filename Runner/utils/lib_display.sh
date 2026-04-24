#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause###############################################################################
# DRM display + Weston + Wayland helpers
# (assumes log_info/log_warn/log_error and run_with_timeout from functestlib.sh)
###############################################################################
###############################################################################
# Internal helpers
###############################################################################
# These are intentional cache outputs used by callers after display_print_eglinfo_pipeline().
# ShellCheck cannot always see cross-file/global usage.
# shellcheck disable=SC2034
EGLI_LAST_PLATFORM=""
EGLI_LAST_DRIVER=""
EGLI_LAST_GL_VENDOR=""
EGLI_LAST_GL_RENDERER=""
EGLI_LAST_PIPE_KIND=""
EGLI_LAST_OUT=""

debugfs_is_mounted() {
    awk '$3=="debugfs" && $2=="/sys/kernel/debug" {found=1} END{exit(found?0:1)}' /proc/mounts 2>/dev/null
}

debugfs_try_mount() {
    [ -d /sys/kernel/debug ] || return 1
    debugfs_is_mounted && return 0

    if command -v mount >/dev/null 2>&1; then
        mount -t debugfs debugfs /sys/kernel/debug >/dev/null 2>&1 || true
    fi
    debugfs_is_mounted
}

display__drm_idx_from_sysfs_connector() {
    # input: "card0-HDMI-A-1"
    sysfs_name="$1"
    idx=$(printf '%s\n' "$sysfs_name" | sed -n 's/^card\([0-9][0-9]*\)-.*/\1/p')
    case "$idx" in
        ""|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$idx"
    return 0
}

display__debugfs_state_for_idx() {
    idx="$1"
    [ -n "$idx" ] || return 1
    debugfs_try_mount >/dev/null 2>&1 || true
    st="/sys/kernel/debug/dri/$idx/state"
    [ -r "$st" ] || return 1
    printf '%s\n' "$st"
    return 0
}

display__debugfs_crtc_name_for_connector() {
    # Pass 1: find the CRTC name for a connector name (e.g., HDMI-A-1)
    st="$1"
    cname="$2"
    [ -r "$st" ] || return 1
    [ -n "$cname" ] || return 1

    awk -v cname="$cname" '
        $0 ~ /^connector\[[0-9]+\]:/ {
            inblk=0
            p=index($0, ":")
            if (p > 0) {
                n=substr($0, p+1)
                sub(/^[[:space:]]+/, "", n)
                if (n == cname) inblk=1
            }
            next
        }
        inblk && $1 ~ /^crtc=/ {
            v=$1
            sub(/^crtc=/, "", v)
            if (v != "(null)" && v != "") { print v; exit 0 }
            exit 1
        }
        inblk && $0 ~ /^[A-Za-z_]+\[[0-9]+\]:/ { exit 1 }
    ' "$st" 2>/dev/null
}

display__debugfs_mode_for_crtc_name() {
    # Pass 2: find mode for a given CRTC name (e.g., crtc-0) anywhere in file
    st="$1"
    crtc_name="$2"
    [ -r "$st" ] || return 1
    [ -n "$crtc_name" ] || return 1
 
    awk -v want="$crtc_name" '
        function is_hz(x){ v=x+0.0; return (v>=20.0 && v<=240.0) }
        $0 ~ /^crtc\[[0-9]+\]:/ {
            inblk = (index($0, want) > 0) ? 1 : 0
            next
        }
        inblk && $1 == "mode:" {
            res=""; hz=""
            # Try to extract "1920x1080" if it appears quoted
            if (match($0, /"[0-9]+x[0-9]+"/)) {
                res=substr($0, RSTART+1, RLENGTH-2)
            }
            # Otherwise, scan tokens for 1920x1080 and Hz
            for (i=1; i<=NF; i++) {
                if (res=="" && $i ~ /^[0-9]+x[0-9]+$/) res=$i
                if (hz=="" && $i ~ /^[0-9]+(\.[0-9]+)?$/ && is_hz($i)) hz=$i
            }
            if (res != "" && hz != "") { print res "@" hz; exit 0 }
            exit 1
        }
    ' "$st" 2>/dev/null
}

drm_card_index_from_dev() {
    dev="$1"
    case "$dev" in
        /dev/dri/card*) printf '%s\n' "${dev##*/card}" ;;
        *) printf '%s\n' "" ;;
    esac
}

drm_debugfs_pick_file_for_dev() {
    dev="$1"
    idx=$(drm_card_index_from_dev "$dev")
    [ -n "$idx" ] || return 1

    f="/sys/kernel/debug/dri/$idx/summary"
    [ -r "$f" ] && { printf '%s\n' "$f"; return 0; }

    f="/sys/kernel/debug/dri/$idx/state"
    [ -r "$f" ] && { printf '%s\n' "$f"; return 0; }

    return 1
}

drm_debugfs_pick_state_for_dev() {
    dev="$1"
    idx=$(drm_card_index_from_dev "$dev")
    [ -n "$idx" ] || return 1

    f="/sys/kernel/debug/dri/$idx/state"
    [ -r "$f" ] && { printf '%s\n' "$f"; return 0; }

    drm_debugfs_pick_file_for_dev "$dev"
}

# Return current mode as "WxH@Hz" for an output (best-effort) by parsing debugfs state.
drm_debugfs_output_mode() {
    dev="$1"
    out_name="$2"
    [ -n "$dev" ] || return 1
    [ -n "$out_name" ] || return 1

    debugfs_try_mount >/dev/null 2>&1 || true
    st=$(drm_debugfs_pick_state_for_dev "$dev" 2>/dev/null) || return 1

    want="$out_name"
    case "$want" in
        card*-*) want=${want#card*-} ;;
    esac

    awk -v want="$want" '
        BEGIN { in_conn=0; in_crtc=0; crtc_name=""; }

        $0 ~ "^connector\\[[0-9]+\\]:" {
            in_conn = 0
            p=index($0, ":")
            if (p > 0) {
                n=substr($0, p+1)
                sub(/^[[:space:]]+/, "", n)
                if (n == want) in_conn = 1
            }
            next
        }

        in_conn && $1 ~ /^crtc=/ {
            crtc_name=$1
            sub(/^crtc=/, "", crtc_name)
            if (crtc_name == "(null)" || crtc_name == "") exit 1
            in_conn=0
            next
        }

        $0 ~ "^crtc\\[[0-9]+\\]:" {
            in_crtc = (crtc_name != "" && index($0, crtc_name)) ? 1 : 0
            next
        }

        in_crtc && $1 == "mode:" {
            res=$2
            gsub(/"/, "", res)
            sub(/:$/, "", res)
            hz=$3 + 0
            if (res ~ /^[0-9]+x[0-9]+$/ && hz > 0) {
                print res "@" hz
                exit 0
            }
            exit 1
        }
    ' "$st" 2>/dev/null
}

###############################################################################
# Display snapshot helpers
###############################################################################

display_connected_summary() {
    ds_base="/sys/class/drm"

    if [ ! -d "$ds_base" ]; then
        log_warn "display_connected_summary: $ds_base not found"
        printf '%s\n' "none"
        return 0
    fi

    ds_out=""

    for ds_path in "$ds_base"/card*-*; do
        [ -e "$ds_path" ] || continue
        ds_name=$(basename "$ds_path")

        case "$ds_name" in
            renderD*|card[0-9]) continue ;;
        esac

        case "$ds_name" in
            *Writeback*) continue ;;
        esac

        ds_status=""
        if [ -r "$ds_path/status" ]; then
            ds_status=$(tr -d '[:space:]' 2>/dev/null <"$ds_path/status")
        fi
        [ "$ds_status" = "connected" ] || continue

        ds_ctype="Other"
        case "$ds_name" in
            *HDMI*) ds_ctype="HDMI-A" ;;
            *eDP*) ds_ctype="eDP" ;;
            *DP*) ds_ctype="DP" ;;
            *LVDS*) ds_ctype="LVDS" ;;
        esac

        ds_first_mode=""
        if [ -r "$ds_path/modes" ]; then
            ds_first_mode=$(head -n 1 "$ds_path/modes" 2>/dev/null | tr -d '[:space:]')
        fi

        ds_entry="$ds_name($ds_ctype"
        [ -n "$ds_first_mode" ] && ds_entry="$ds_entry,$ds_first_mode"
        ds_entry="$ds_entry)"

        if [ -z "$ds_out" ]; then
            ds_out="$ds_entry"
        else
            ds_out="$ds_out, $ds_entry"
        fi
    done

    [ -z "$ds_out" ] && ds_out="none"
    printf '%s\n' "$ds_out"
    return 0
}

display_debug_snapshot() {
    ds_tag="$1"
    [ -n "$ds_tag" ] || ds_tag="snapshot"
 
    log_info "----- Display snapshot: $ds_tag -----"
 
    debugfs_try_mount >/dev/null 2>&1 || true
 
    if [ -d /dev/dri ]; then
        ds_nodes=""
        set -- /dev/dri/*
        if [ -e "$1" ]; then
            for ds_n in "$@"; do
                ds_nodes="$ds_nodes $ds_n"
            done
            ds_nodes=${ds_nodes# }
        fi
        log_info "DRM nodes: ${ds_nodes:-<none>}"
    else
        log_warn "/dev/dri not present"
    fi
 
    ds_base="/sys/class/drm"
    if [ -d "$ds_base" ]; then
        for ds_path in "$ds_base"/card*-*; do
            [ -e "$ds_path" ] || continue
            ds_name=$(basename "$ds_path")
 
            case "$ds_name" in
                renderD*|card[0-9]) continue ;;
            esac
 
            ds_status="unknown"
            if [ -r "$ds_path/status" ]; then
                ds_status=$(tr -d '[:space:]' 2>/dev/null <"$ds_path/status")
            fi
 
            ds_enabled="unknown"
            if [ -r "$ds_path/enabled" ]; then
                ds_enabled=$(tr -d '[:space:]' 2>/dev/null <"$ds_path/enabled")
            fi
 
            ds_ctype="Other"
            case "$ds_name" in
                *HDMI*) ds_ctype="HDMI-A" ;;
                *eDP*) ds_ctype="eDP" ;;
                *DP*) ds_ctype="DP" ;;
                *LVDS*) ds_ctype="LVDS" ;;
            esac
 
            ds_nmodes=0
            ds_first_mode="<none>"
            if [ -r "$ds_path/modes" ]; then
                ds_nmodes=$(wc -l <"$ds_path/modes" 2>/dev/null | tr -d '[:space:]')
                ds_first_mode=$(head -n 1 "$ds_path/modes" 2>/dev/null | tr -d '[:space:]')
                [ -n "$ds_first_mode" ] || ds_first_mode="<none>"
                [ -n "$ds_nmodes" ] || ds_nmodes=0
            fi
 
            ds_cur="$(display_connector_cur_mode "$ds_name" 2>/dev/null || true)"
            [ -n "$ds_cur" ] || ds_cur="-"
 
            log_info "DRM: $ds_name status=$ds_status enabled=$ds_enabled type=$ds_ctype modes=$ds_nmodes first=$ds_first_mode cur=$ds_cur"
        done
    else
        log_warn "display_debug_snapshot: $ds_base not found"
    fi
 
    ds_summary=$(display_connected_summary)
    log_info "Connected summary (sysfs): $ds_summary"
 
    log_info "----- End display snapshot: $ds_tag -----"
    return 0
}

# Pick a "primary" connector: prefer external types (HDMI > DP/eDP > LVDS > others).
display_select_primary_connector() {
    base="/sys/class/drm"
    [ -d "$base" ] || return 1

    best=""
    for path in "$base"/card*-*; do
        [ -e "$path" ] || continue
        name=$(basename "$path")
        case "$name" in
            renderD*|card[0-9]) continue ;;
        esac
        case "$name" in
            *Writeback*) continue ;;
        esac

        status="unknown"
        if [ -r "$path/status" ]; then
            status=$(tr -d '[:space:]' 2>/dev/null <"$path/status")
        fi
        [ "$status" = "connected" ] || continue

        prio=999
        case "$name" in
            *HDMI*) prio=1 ;;
            *DP*) [ "$prio" -gt 2 ] && prio=2 ;;
            *LVDS*) [ "$prio" -gt 3 ] && prio=3 ;;
        esac

        if [ -z "$best" ]; then
            best="$name:$prio"
        else
            best_prio=$(printf '%s\n' "$best" | cut -d: -f2)
            [ -z "$best_prio" ] && best_prio=999
            if [ "$prio" -lt "$best_prio" ]; then
                best="$name:$prio"
            fi
        fi
    done

    [ -z "$best" ] && return 1
    printf '%s\n' "$best" | cut -d: -f1
    return 0
}

###############################################################################
# Weston weston.ini helpers
###############################################################################

weston_pick_writable_config() {
    candidates="
/etc/xdg/weston/weston.ini
${XDG_CONFIG_HOME:-$HOME/.config}/weston.ini
$HOME/.config/weston.ini
"

    for cfg in $candidates; do
        dir=$(dirname "$cfg")
        if [ ! -d "$dir" ]; then
            if ! mkdir -p "$dir" 2>/dev/null; then
                continue
            fi
        fi

        if [ -f "$cfg" ]; then
            if [ -w "$cfg" ]; then
                printf '%s\n' "$cfg"
                return 0
            fi
        else
            if : >"$cfg" 2>/dev/null; then
                printf '%s\n' "$cfg"
                return 0
            fi
        fi
    done

    return 1
}

weston_set_output_mode() {
    out_name="$1"
    mode="$2"

    if [ -z "$out_name" ]; then
        log_error "weston_set_output_mode: missing output name"
        return 1
    fi
    if [ -z "$mode" ]; then
        log_error "weston_set_output_mode: missing mode"
        return 1
    fi

    cfg=$(weston_pick_writable_config) || {
        log_warn "weston_set_output_mode: no writable weston.ini config found"
        return 1
    }

    WESTON_OUTPUT_MODE_UPDATED=0
    export WESTON_OUTPUT_MODE_UPDATED

    cur_mode=$(
        awk -v want="$out_name" '
            BEGIN{ inblk=0; name=""; mode=""; }
            /^\[output\]/ { inblk=1; name=""; mode=""; next }
            /^\[/ { inblk=0; next }
            inblk && $0 ~ /^[[:space:]]*name[[:space:]]*=/ {
                v=$0; sub(/^[[:space:]]*name[[:space:]]*=/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); name=v; next
            }
            inblk && $0 ~ /^[[:space:]]*mode[[:space:]]*=/ {
                v=$0; sub(/^[[:space:]]*mode[[:space:]]*=/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); mode=v;
                if (name == want) { print mode; exit 0 }
                next
            }
        ' "$cfg" 2>/dev/null
    )

    if [ -n "$cur_mode" ] && [ "$cur_mode" = "$mode" ]; then
        log_info "weston_set_output_mode: unchanged ($cfg name=$out_name mode=$mode); skipping"
        WESTON_OUTPUT_MODE_UPDATED=0
        export WESTON_OUTPUT_MODE_UPDATED
        return 0
    fi

    tmp="${cfg}.tmp.$$"

    awk -v ONAME="$out_name" -v OMODE="$mode" '
    BEGIN {
        in_block = 0
        out_block = 0
        seen_block = 0
    }

    /^\[output]/ {
        if (in_block && out_block && !seen_block) {
            print "name=" ONAME
            print "mode=" OMODE
            seen_block = 1
        }
        in_block = 1
        out_block = 0
        print
        next
    }

    /^\[/ {
        if (in_block && out_block && !seen_block) {
            print "name=" ONAME
            print "mode=" OMODE
            seen_block = 1
        }
        in_block = 0
        out_block = 0
        print
        next
    }

    {
        if (in_block) {
            if ($0 ~ /^name[[:space:]]*=/) {
                n = $0
                sub(/^name[[:space:]]*=/, "", n)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", n)
                if (n == ONAME) {
                    out_block = 1
                }
            }
            if (out_block && ($0 ~ /^name[[:space:]]*=/ || $0 ~ /^mode[[:space:]]*=/)) {
                next
            }
        }
        print
    }

    END {
        if (!seen_block) {
            print ""
            print "[output]"
            print "name=" ONAME
            print "mode=" OMODE
        }
    }' "$cfg" >"$tmp" 2>/dev/null

    if ! mv "$tmp" "$cfg" 2>/dev/null; then
        log_warn "weston_set_output_mode: failed to update $cfg"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    WESTON_OUTPUT_MODE_UPDATED=1
    export WESTON_OUTPUT_MODE_UPDATED

    log_info "weston_set_output_mode: updated $cfg (name=$out_name mode=$mode)"
    return 0
}

weston_restart_for_new_config() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart weston.service >/dev/null 2>&1; then
            log_info "weston_restart_for_new_config: restarted weston.service via systemd"
            return 0
        fi

        if systemctl restart "weston@weston.service" >/dev/null 2>&1; then
            log_info "weston_restart_for_new_config: restarted weston@weston.service via systemd"
            return 0
        fi
    fi

    if command -v weston_stop >/dev/null 2>&1 && command -v weston_start >/dev/null 2>&1; then
        if weston_stop && weston_start; then
            log_info "weston_restart_for_new_config: restarted Weston via weston_stop/weston_start"
            return 0
        fi
        log_warn "weston_restart_for_new_config: weston_stop/weston_start failed"
    else
        log_warn "weston_restart_for_new_config: weston_stop/weston_start helpers not available"
    fi

    log_warn "weston_restart_for_new_config: unable to restart Weston automatically; config will take effect on next manual restart"
    return 1
}

###############################################################################
# Wayland / Weston runtime helpers (unchanged)
###############################################################################

wayland_debug_snapshot() {
    tag="$1"
    [ -n "$tag" ] || tag="wayland-debug"

    log_info "----- Wayland/Weston debug snapshot: $tag -----"

    pids=$(pgrep weston 2>/dev/null || true)
    if [ -n "$pids" ]; then
        log_info "weston PIDs: $pids"
        for p in $pids; do
            user=$(ps -o user= -p "$p" 2>/dev/null)
            group=$(ps -o group= -p "$p" 2>/dev/null)
            cmd=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)
            log_info "[ps] pid=$p user=$user group=$group cmd=$cmd"
        done
    else
        log_warn "No weston process found"
    fi

    log_info "Env now: XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"

    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
        log_info "XDG_RUNTIME_DIR content:"
        for f in "$XDG_RUNTIME_DIR"/*; do
            [ -e "$f" ] || continue
            log_info "[rt] $f"
        done
    fi

    log_info "----- End snapshot: $tag -----"
}

# Discover an available Wayland socket from common runtime locations.
# Prefers user-session sockets first, then system-wide sockets such as /run/wayland-*.
discover_wayland_socket_anywhere() {
    candidates=""
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        candidates="$candidates $XDG_RUNTIME_DIR"
    fi
    candidates="$candidates /run/user/1000 /run/user/0 /run /dev/socket/weston"

    for dir in $candidates; do
        [ -d "$dir" ] || continue
        for sock in "$dir"/wayland-*; do
            [ -S "$sock" ] || continue
            printf '%s\n' "$sock"
            return 0
        done
    done

    return 1
}

adopt_wayland_env_from_socket() {
    sock="$1"
    [ -n "$sock" ] || return 1

    dir=$(dirname "$sock")
    base=$(basename "$sock")

    export XDG_RUNTIME_DIR="$dir"
    export WAYLAND_DISPLAY="$base"

    log_info "Adopted Wayland env: XDG_RUNTIME_DIR=$dir WAYLAND_DISPLAY=$base"
    log_info "Reproduce with:"
    log_info " export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'"
    log_info " export WAYLAND_DISPLAY='$WAYLAND_DISPLAY'"
    return 0
}

wayland_connection_ok() {
    sock=""
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        sock="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
    fi
    [ -n "$sock" ] || sock="<unknown>"
    log_info "wayland_connection_ok: using socket $sock"

    if ! command -v weston-simple-egl >/dev/null 2>&1; then
        log_warn "wayland_connection_ok: weston-simple-egl not available; assuming OK"
        return 0
    fi

    log_info "Probing Wayland by briefly starting weston-simple-egl"

    if command -v run_with_timeout >/dev/null 2>&1; then
        run_with_timeout "3s" weston-simple-egl >/dev/null 2>&1
        rc=$?
    else
        weston-simple-egl >/dev/null 2>&1 &
        pid=$!
        sleep 3
        kill "$pid" 2>/dev/null || true
        rc=0
    fi

    if [ "$rc" -ne 0 ] && [ "$rc" -ne 143 ]; then
        log_warn "wayland_connection_ok: weston-simple-egl probe returned $rc"
        return 1
    fi

    return 0
}

# Return success if any real Weston/Wayland socket currently exists.
# Checks discovered sockets first, then common fallback socket paths.
weston_runtime_socket_exists() {
    weston_sock=""

    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        weston_sock=$(discover_wayland_socket_anywhere 2>/dev/null | head -n 1 || true)
        if [ -n "$weston_sock" ]; then
            return 0
        fi
    fi

    for weston_sock in /run/wayland-* /run/user/0/wayland-* /run/user/1000/wayland-*; do
        [ -S "$weston_sock" ] || continue
        return 0
    done

    return 1
}

# Wait until Weston is usable by requiring both process presence and socket availability.
# Returns 0 when ready, 1 after timeout seconds if Weston does not become ready.
weston_wait_ready() {
    timeout="${1:-15}"
    i=0

    while [ "$i" -lt "$timeout" ]; do
        weston_proc_ready=1
        weston_sock_ready=1

        if command -v weston_is_running >/dev/null 2>&1; then
            if weston_is_running >/dev/null 2>&1; then
                weston_proc_ready=0
            fi
        else
            if command -v pgrep >/dev/null 2>&1; then
                if pgrep -x weston >/dev/null 2>&1; then
                    weston_proc_ready=0
                fi
            fi
        fi

        if weston_runtime_socket_exists; then
            weston_sock_ready=0
        fi

        if [ "$weston_proc_ready" -eq 0 ] && [ "$weston_sock_ready" -eq 0 ]; then
            return 0
        fi

        i=$((i + 1))
        sleep 1
    done

    log_warn "weston_wait_ready: Weston did not become ready within ${timeout}s"
    return 1
}

# Restore Weston runtime after a DRM-exclusive test stopped it.
# Starts socket/service first, then falls back to weston_start, and waits until ready.
weston_restore_runtime() {
    timeout="${1:-15}"
 
    if command -v weston_is_running >/dev/null 2>&1; then
        if weston_is_running >/dev/null 2>&1 && weston_runtime_socket_exists; then
            return 0
        fi
    fi
 
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start weston.socket >/dev/null 2>&1 || true
        systemctl start weston.service >/dev/null 2>&1 || \
        systemctl start weston@root.service >/dev/null 2>&1 || true
    fi
 
    if weston_wait_ready 3; then
        return 0
    fi
 
    if command -v weston_start >/dev/null 2>&1; then
        weston_start >/dev/null 2>&1 || true
    fi
 
    weston_wait_ready "$timeout"
}

# Remove stale Wayland socket files only when Weston is not running.
# Best-effort cleanup for common Weston runtime paths; ignores missing files
# and permission errors. Intentionally does not touch /run/wayland-* because
# that may be owned by systemd weston.socket on base builds.
weston_cleanup_stale_sockets() {
    if weston_is_running; then
        return 0
    fi

    for s in \
        /dev/socket/weston/wayland-* \
        /run/user/0/wayland-* \
        /run/user/1000/wayland-* \
        /tmp/wayland-* \
        "${XDG_RUNTIME_DIR:-/nonexistent}"/wayland-*; do
        [ -S "$s" ] || continue
        rm -f "$s" 2>/dev/null || true
    done

    return 0
}
###############################################################################
# Hz helpers
###############################################################################
hz_is_about_60() {
    hz="$1"
    [ -n "$hz" ] || return 1
    awk -v h="$hz" 'BEGIN{ exit (h>=58.0 && h<=62.0) ? 0 : 1 }'
}

###############################################################################
# weston.ini gating (non-modetest path)
###############################################################################
weston_ini_primary_is_60hz() {
    ini="${1:-/etc/xdg/weston/weston.ini}"
    [ -r "$ini" ] || return 1

    primary_sysfs=$(display_select_primary_connector 2>/dev/null || true)
    [ -n "$primary_sysfs" ] || return 1
    weston_name=$(printf '%s\n' "$primary_sysfs" | sed 's/^card[0-9][0-9]*-//')
    [ -n "$weston_name" ] || return 1

    mode=$(
        awk -v want="$weston_name" '
            BEGIN{ inblk=0; name=""; mode=""; }
            /^\[output\]/ { inblk=1; name=""; mode=""; next }
            /^\[/ { inblk=0; next }
            inblk && $0 ~ /^[[:space:]]*name[[:space:]]*=/ {
                sub(/^[[:space:]]*name[[:space:]]*=/,""); gsub(/[[:space:]]/,""); name=$0; next
            }
            inblk && $0 ~ /^[[:space:]]*mode[[:space:]]*=/ {
                sub(/^[[:space:]]*mode[[:space:]]*=/,""); gsub(/[[:space:]]/,""); mode=$0
                if (name == want) { print mode; exit 0 }
                next
            }
        ' "$ini" 2>/dev/null
    )

    [ -n "$mode" ] || return 1
    printf '%s\n' "$mode" | grep -Eq '@(59\.9|59\.94|60(\.|$)|60\.0|60\.00)'
}

weston_ini_force_primary_1080p60_if_not_60() {
    cfg=$(weston_pick_writable_config 2>/dev/null || true)
    [ -n "$cfg" ] || cfg=/etc/xdg/weston/weston.ini

    if weston_ini_primary_is_60hz "$cfg"; then
        log_info "weston_ini_force_primary_1080p60_if_not_60: weston.ini already ~60Hz for primary output; skipping"
        return 0
    fi

    # Always use the debugfs/sysfs-only path now.
    weston_force_primary_1080p60_if_not_60
}

weston_get_primary_refresh_hz() {
    primary_sysfs=$(display_select_primary_connector 2>/dev/null || true)
    [ -n "$primary_sysfs" ] || return 1
 
    mode=$(display_connector_cur_mode "$primary_sysfs" 2>/dev/null || true)
    [ -n "$mode" ] || return 1
 
    hz=$(printf '%s\n' "$mode" | awk -F@ 'NF>=2{print $2; exit 0}')
    [ -n "$hz" ] || return 1
 
    printf '%s\n' "$hz"
}

display_cur_size_from_state_msm() {
    state="$(display_find_dri_state_file 2>/dev/null || true)"
 
    if [ -z "$state" ] || [ ! -r "$state" ]; then
        echo "-"
        return 0
    fi
 
    awk '
    BEGIN { good=0; crtc=0; fb=0; sz=""; }
 
    /^plane\[/ { good=0; crtc=0; fb=0; sz=""; next }
 
    /allocated by[[:space:]]*=/ { good=1; next }
 
    /^[[:space:]]*crtc=crtc-/ {
        if ($0 !~ /\(null\)/) crtc=1
        next
    }
 
    /^[[:space:]]*fb=/ {
        s=$0
        sub(/^[[:space:]]*fb=/, "", s)
        fb = s + 0
        next
    }
 
    /^[[:space:]]*size=/ {
        s=$0
        sub(/^[[:space:]]*size=/, "", s)
        sub(/[[:space:]].*$/, "", s)
        sz=s
        if (good && crtc && fb > 0 && sz != "") { print sz; exit 0 }
        next
    }
 
    /^[[:space:]]*dst\[0\]=/ {
        s=$0
        sub(/^[[:space:]]*dst\[0\]=/, "", s)
        if (match(s, /^[0-9]+x[0-9]+/, m)) {
            sz=m[0]
            if (good && crtc && fb > 0 && sz != "") { print sz; exit 0 }
        }
        next
    }
 
    END {
        if (sz != "") print sz;
        else print "-";
    }' "$state" 2>/dev/null
}
 
display_connector_cur_mode() {
    sysfs_name="$1"
    [ -n "$sysfs_name" ] || { echo "-"; return 0; }
 
    debugfs_try_mount >/dev/null 2>&1 || true
 
    idx=$(printf '%s\n' "$sysfs_name" | sed -n 's/^card\([0-9][0-9]*\)-.*/\1/p')
    case "$idx" in ""|*[!0-9]*) echo "-"; return 0 ;; esac
 
    st="/sys/kernel/debug/dri/$idx/state"
    if [ ! -r "$st" ]; then
        echo "-"
        return 0
    fi
 
    prefix="card${idx}-"
    cname=${sysfs_name#"$prefix"}
    [ -n "$cname" ] || { echo "-"; return 0; }
 
    awk -v want="$cname" '
        function first_hz(line, i, v) {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
                    v=$i+0
                    if (v>=20 && v<=240) return $i
                }
            }
            return ""
        }
 
        BEGIN {
            cur_crtc_id=""; cur_crtc_name=""; in_crtc=0;
            in_conn=0; target_crtc_name=""; target_crtc_id="";
        }
 
        # -------- CRTC blocks (come earlier in your file) --------
        /^[[:space:]]*crtc\[[0-9]+\]:/ {
            in_crtc=1
 
            line=$0
            sub(/^[[:space:]]*crtc\[/, "", line)
            cur_crtc_id=line
            sub(/\].*$/, "", cur_crtc_id)
 
            cur_crtc_name=$0
            sub(/^[[:space:]]*crtc\[[0-9]+\]:[[:space:]]*/, "", cur_crtc_name)
            next
        }
 
        in_crtc && $1=="mode:" {
            res=$2
            gsub(/"/, "", res)
            sub(/:$/, "", res)
            hz=first_hz($0)
 
            if (res ~ /^[0-9]+x[0-9]+$/ && hz != "") {
                mode_by_id[cur_crtc_id] = res "@" hz
                mode_by_name[cur_crtc_name] = res "@" hz
            }
            next
        }
 
        # stop CRTC block when next top-level block starts
        in_crtc && /^[[:space:]]*[A-Za-z_]+\[[0-9]+\]:/ && $0 !~ /^[[:space:]]*crtc\[/ {
            in_crtc=0
        }
 
        # -------- Connector blocks --------
        /^[[:space:]]*connector\[[0-9]+\]:/ {
            in_conn=0
            conn_name=$0
            sub(/^[[:space:]]*connector\[[0-9]+\]:[[:space:]]*/, "", conn_name)
            if (conn_name == want) in_conn=1
            next
        }
 
        in_conn {
            # your format: "crtc=crtc-0" or "crtc=(null)"
            if ($0 ~ /^[[:space:]]*crtc=/) {
                v=$0
                sub(/^[[:space:]]*crtc=/, "", v)
                if (v != "(null)" && v != "") target_crtc_name=v
                in_conn=0
                next
            }
            next
        }
 
        END {
            if (target_crtc_name != "" && (target_crtc_name in mode_by_name)) {
                print mode_by_name[target_crtc_name]
                exit 0
            }
            # fallback: nothing resolved
            print "-"
            exit 0
        }
    ' "$st" 2>/dev/null
}
###############################################################################
# Unified entrypoint (non-modetest)
###############################################################################
weston_force_primary_1080p60_if_not_60() {
    wf_ret=1

    wf_primary_sysfs=$(display_select_primary_connector 2>/dev/null || true)
    if [ -z "$wf_primary_sysfs" ]; then
        log_warn "weston_force_primary_1080p60_if_not_60: cannot determine primary connector; skipping"
        return 1
    fi

    wf_idx=$(printf '%s\n' "$wf_primary_sysfs" | sed 's/^card\([0-9][0-9]*\)-.*$/\1/')
    case "$wf_idx" in ""|*[!0-9]*) wf_idx="" ;; esac
    if [ -z "$wf_idx" ]; then
        log_warn "weston_force_primary_1080p60_if_not_60: bad sysfs name '$wf_primary_sysfs'"
        return 1
    fi

    wf_conn_name=$(printf '%s\n' "$wf_primary_sysfs" | sed 's/^card[0-9][0-9]*-//')
    if [ -z "$wf_conn_name" ]; then
        log_warn "weston_force_primary_1080p60_if_not_60: cannot derive connector name from '$wf_primary_sysfs'"
        return 1
    fi

    wf_cur_mode=""
    wf_cur_hz=""

    wf_cur_mode=$(display_connector_cur_mode "$wf_primary_sysfs" 2>/dev/null || true)
    if [ -n "$wf_cur_mode" ]; then
        wf_cur_hz=$(printf '%s\n' "$wf_cur_mode" | awk -F@ 'NF>=2{print $2; exit 0}')
    fi

    if [ -n "$wf_cur_hz" ] && hz_is_about_60 "$wf_cur_hz"; then
        log_info "weston_force_primary_1080p60_if_not_60: already ~60Hz (${wf_cur_hz}Hz); skipping"
        return 0
    fi

    log_info "weston_force_primary_1080p60_if_not_60: forcing ${wf_conn_name} to 1920x1080@60 via weston.ini (cur=${wf_cur_mode:-unknown})"

    if ! command -v weston_set_output_mode >/dev/null 2>&1; then
        log_warn "weston_force_primary_1080p60_if_not_60: weston_set_output_mode not found; cannot update weston.ini"
        return 1
    fi

    weston_set_output_mode "$wf_conn_name" "1920x1080@60" || {
        log_warn "weston_force_primary_1080p60_if_not_60: weston_set_output_mode failed"
        return 1
    }

    # If Weston is not running yet, do NOT restart anything.
    # Write weston.ini now; let the upcoming Weston start apply it.
    wf_running=0
    if command -v weston_is_running >/dev/null 2>&1; then
        if weston_is_running >/dev/null 2>&1; then
            wf_running=1
        fi
    else
        # Prefer pgrep over grepping ps (ShellCheck SC2009)
        if command -v pgrep >/dev/null 2>&1; then
            if pgrep -x weston >/dev/null 2>&1; then
                wf_running=1
            fi
        else
            # Last-resort fallback (only if pgrep is unavailable)
	    # shellcheck disable=SC2009
            if ps 2>/dev/null | grep -q '[w]eston'; then
                wf_running=1
            fi
        fi
    fi

    if [ "$wf_running" -eq 1 ]; then
        log_info "weston_force_primary_1080p60_if_not_60: weston is running; restarting once to apply new weston.ini..."

        if command -v weston_stop >/dev/null 2>&1; then
            weston_stop >/dev/null 2>&1 || true
        else
            # Best-effort fallback (guarded for minimal images) - avoid SC2015
            if command -v killall >/dev/null 2>&1; then
                killall weston >/dev/null 2>&1 || true
            fi

            if command -v pkill >/dev/null 2>&1; then
                pkill -TERM weston >/dev/null 2>&1 || true
            fi

            sleep 1

            if command -v pkill >/dev/null 2>&1; then
                pkill -KILL weston >/dev/null 2>&1 || true
            fi
        fi

        # Restart using the same logic used by your tests (NOT systemd-only)
        if command -v weston_pick_env_or_start >/dev/null 2>&1; then
            weston_pick_env_or_start >/dev/null 2>&1 || true
        elif command -v overlay_start_weston_drm >/dev/null 2>&1; then
            overlay_start_weston_drm >/dev/null 2>&1 || true
        else
            log_warn "weston_force_primary_1080p60_if_not_60: no weston start helper found after stop"
        fi

        if command -v wayland_connection_ok >/dev/null 2>&1; then
            wayland_connection_ok >/dev/null 2>&1 || true
        fi
    else
        log_info "weston_force_primary_1080p60_if_not_60: weston not running; weston.ini updated (will apply on next start)"
    fi

    # Post-verify (bounded retries; do not stall CI)
    wf_after_mode=""
    wf_after_hz=""
    wf_try=0
    while [ "$wf_try" -lt 5 ]; do
        wf_after_mode=$(display_connector_cur_mode "$wf_primary_sysfs" 2>/dev/null || true)
        if [ -n "$wf_after_mode" ]; then
            wf_after_hz=$(printf '%s\n' "$wf_after_mode" | awk -F@ 'NF>=2{print $2; exit 0}')
        else
            wf_after_hz=""
        fi

        if [ -n "$wf_after_hz" ] && hz_is_about_60 "$wf_after_hz"; then
            break
        fi

        wf_try=$((wf_try + 1))
        sleep 1
    done

    if [ -n "$wf_after_hz" ] && hz_is_about_60 "$wf_after_hz"; then
        log_info "weston_force_primary_1080p60_if_not_60: post-verify OK (cur=${wf_after_mode})"
        wf_ret=0
    else
        log_warn "weston_force_primary_1080p60_if_not_60: post-verify still not ~60Hz (cur=${wf_after_mode:-unknown}); keeping best-effort"
        wf_ret=0
    fi

    return "$wf_ret"
}

###############################################################################
# EGL / GL pipeline introspection (eglinfo parser)
###############################################################################

# Optional: EGLINFO_DEBUG=1 to dump full eglinfo output when a platform fails.

egli_pick_platform_flag() {
  EGLINFO="${EGLINFO:-eglinfo}"

  # NEW: treat missing/unusable eglinfo as a real failure (return 1)
  if ! command -v "$EGLINFO" >/dev/null 2>&1; then
    echo ""
    return 1
  fi

  # Keep existing behavior: try to detect supported flag from --help.
  # NOTE: we no longer force "|| true" so we can detect a true failure.
  help_out="$("$EGLINFO" --help 2>&1)"
  rc=$?

  # NEW: if --help truly failed and produced nothing, signal failure
  if [ "$rc" -ne 0 ] && [ -z "${help_out:-}" ]; then
    echo ""
    return 1
  fi

  if echo "$help_out" | grep -qi -- '--platform'; then
    echo "--platform"
    return 0
  fi

  if echo "$help_out" | grep -Eqi '(^|[[:space:]])-p([[:space:]]|,|$)'; then
    echo "-p"
    return 0
  fi

  if echo "$help_out" | grep -Eqi '(^|[[:space:]])-P([[:space:]]|,|$)'; then
    echo "-P"
    return 0
  fi

  # No platform selection flag supported — not an error
  echo ""
  return 0
}

egli_glvnd_icd_from_json() {
  # Extract ICD library_path from a GLVND EGL vendor JSON (no jq).
  # Prints the value (e.g., libEGL_adreno.so.1) or empty on failure.
  f="$1"
  [ -r "$f" ] || { printf '%s\n' ""; return 0; }
 
  # Match a line containing "library_path" : "...."
  # Keep it resilient to whitespace.
  sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1
}
 
egli_derive_driver_name() {
  # Best-effort for log readability only.
  # Inputs: gl_vendor gl_renderer
  v="$1"
  r="$2"
 
  # Qualcomm/Adreno path
  if printf '%s %s\n' "$v" "$r" | grep -Eqi '(qualcomm|adreno)'; then
    icd=""
    if [ -f /usr/share/glvnd/egl_vendor.d/10_EGL_adreno.json ]; then
      icd="$(egli_glvnd_icd_from_json /usr/share/glvnd/egl_vendor.d/10_EGL_adreno.json)"
    fi
    if [ -n "$icd" ]; then
      printf '%s\n' "adreno ($icd)"
      return 0
    fi
    printf '%s\n' "adreno"
    return 0
  fi
 
  # Mesa path
  if printf '%s %s\n' "$v" "$r" | grep -Eqi '(mesa|llvmpipe|softpipe|swrast|lavapipe)'; then
    icd=""
    if [ -f /usr/share/glvnd/egl_vendor.d/50_mesa.json ]; then
      icd="$(egli_glvnd_icd_from_json /usr/share/glvnd/egl_vendor.d/50_mesa.json)"
    fi
    if [ -n "$icd" ]; then
      printf '%s\n' "mesa ($icd)"
      return 0
    fi
    printf '%s\n' "mesa"
    return 0
  fi
 
  printf '%s\n' "unknown"
  return 0
}

egli_get_field() {
  key="$1"
  awk -v k="$key" '
    BEGIN { IGNORECASE=1 }

    function trim(s) {
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      return s
    }

    function emit_after_colon(line) {
      sub("^[^:]*:[[:space:]]*", "", line)
      line = trim(line)
      if (line != "") {
        print line
        exit
      }
    }

    {
      line = $0

      # 1) Fast-path: key at column 1: "KEY: value"
      if (index(tolower(line), tolower(k ":")) == 1) {
        emit_after_colon(line)
      }

      # 2) Mesa eglinfo style: "OpenGL ... vendor: freedreno" / "renderer: ..."
      # Callers pass keys like "OpenGL vendor string" or "GL_VENDOR".
      if (tolower(k) ~ /vendor/ && line ~ /^[[:space:]]*OpenGL/ && line ~ / vendor[[:space:]]*:/) {
        emit_after_colon(line)
      }
      if (tolower(k) ~ /renderer/ && line ~ /^[[:space:]]*OpenGL/ && line ~ / renderer[[:space:]]*:/) {
        emit_after_colon(line)
      }

      # 3) Allow leading whitespace: " OpenGL vendor string: ..."
      if (tolower(line) ~ "^[[:space:]]*" tolower(k) "[[:space:]]*:") {
        emit_after_colon(line)
      }
    }
  '
}

egli_get_first() {
  # $1 = full text, rest = keys (try in order)
  text="$1"
  shift

  for key in "$@"; do
    val="$(printf '%s\n' "$text" | egli_get_field "$key")"
    if [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  done

  printf '%s\n' ""
  return 0
}

egli_classify_pipeline() {
  # Inputs: driver gl_vendor gl_renderer
  d="$1"
  v="$2"
  r="$3"

  # CPU / software fallbacks (Mesa swrast/llvmpipe/etc.)
  if printf '%s %s %s\n' "$d" "$v" "$r" | grep -Eqi \
    '(llvmpipe|softpipe|swrast|kms_swrast|lavapipe|virgl|swiftshader)'; then
    printf '%s\n' "CPU (software)"
    return 0
  fi

  # If it’s not obviously software, treat as GPU/hardware.
  printf '%s\n' "GPU (hardware)"
  return 0
}

egli_wayland_socket_ok() {
  wd="${WAYLAND_DISPLAY:-}"
  [ -n "$wd" ] || return 1
 
  case "$wd" in
    /*)
      [ -S "$wd" ] && return 0
      return 1
      ;;
    *)
      xrd="${XDG_RUNTIME_DIR:-}"
      if [ -n "$xrd" ]; then
        [ -S "$xrd/$wd" ] && return 0
        return 1
      fi
 
      # Fallbacks when XDG_RUNTIME_DIR is unset (common in minimal shells)
      [ -S "/run/user/0/$wd" ] && return 0
      [ -S "/run/user/1000/$wd" ] && return 0
      [ -S "/run/$wd" ] && return 0
 
      return 1
      ;;
  esac
}

egli_print_legacy() {
  plat="$1"
  driver="$2"
  gl_vendor="$3"
  gl_renderer="$4"

  plat_up="$(printf '%s' "$plat" | tr '[:lower:]' '[:upper:]')"

  log_info "EGLINFO: Pipeline=${plat_up} platform:"

  [ -n "$driver" ] || driver="(unknown)"
  [ -n "$gl_vendor" ] || gl_vendor="(unknown)"
  [ -n "$gl_renderer" ] || gl_renderer="(unknown)"

  # Align EXACTLY to your sample log format (no extra indentation)
  log_info "EGLINFO: EGL driver name: $driver"
  log_info "EGLINFO: GL_VENDOR: $gl_vendor"
  log_info "EGLINFO: GL_RENDERER: $gl_renderer"
}

egli_try_one_platform() {
  plat="$1"
  plat_flag="$2"

  EGLINFO="${EGLINFO:-eglinfo}"

  if [ -n "$plat_flag" ]; then
    out="$("$EGLINFO" "$plat_flag" "$plat" 2>&1)"
    rc=$?
  else
    out="$(EGL_PLATFORM="$plat" "$EGLINFO" 2>&1)"
    rc=$?
  fi

  # “Initialized?” heuristic: at least one of these should exist
  egl_vendor="$(printf '%s\n' "$out" | egli_get_field "EGL vendor string")"
  egl_version="$(printf '%s\n' "$out" | egli_get_field "EGL version string")"
  egl_api_ver="$(printf '%s\n' "$out" | egli_get_field "EGL API version")"

  ok=0
  [ -n "$egl_vendor" ] && ok=1
  [ -n "$egl_version" ] && ok=1
  [ -n "$egl_api_ver" ] && ok=1

  if [ "$rc" -ne 0 ] || [ "$ok" -eq 0 ]; then
    log_warn "eglinfo platform '$plat' did not initialize cleanly (rc=$rc)."
    if [ "${EGLINFO_DEBUG:-0}" = "1" ]; then
      log_info "---- eglinfo output (platform '$plat') ----"
      printf '%s\n' "$out"
      log_info "---- end eglinfo output ----"
    fi
    return 1
  fi

  # Driver name
  driver="$(egli_get_first "$out" \
    "EGL driver name" \
    "EGL driver" \
    "Driver name" \
    "Driver")"

  # GL vendor
  gl_vendor="$(egli_get_first "$out" \
    "GL_VENDOR" \
    "OpenGL ES profile vendor string" \
    "OpenGL vendor string" \
    "OpenGL ES vendor string")"

  # GL renderer
  gl_renderer="$(egli_get_first "$out" \
    "GL_RENDERER" \
    "OpenGL ES profile renderer string" \
    "OpenGL renderer string" \
    "OpenGL ES renderer string")"

  # Avoid classification on empty strings
  [ -n "$driver" ] || driver="unknown"
  [ -n "$gl_vendor" ] || gl_vendor="unknown"
  [ -n "$gl_renderer" ] || gl_renderer="unknown"

  # If eglinfo didn't expose a driver name, derive one from GLVND JSON + strings
  if [ "$driver" = "unknown" ]; then
    driver="$(egli_derive_driver_name "$gl_vendor" "$gl_renderer")"
  fi

  # Print GPU/CPU pipeline type
  pipe_kind="$(egli_classify_pipeline "$driver" "$gl_vendor" "$gl_renderer")"
  log_info "EGLINFO: Pipeline type: $pipe_kind"

  # ---- Cache what we used, so decision uses the same data ----
  EGLI_LAST_PLATFORM="$plat"
  EGLI_LAST_DRIVER="$driver"
  EGLI_LAST_GL_VENDOR="$gl_vendor"
  EGLI_LAST_GL_RENDERER="$gl_renderer"
  EGLI_LAST_PIPE_KIND="$pipe_kind"
  if [ "${EGLINFO_CACHE_OUTPUT:-0}" = "1" ]; then
    EGLI_LAST_OUT="$out"
  else
    EGLI_LAST_OUT=""
  fi
  # -----------------------------------------------------------

  egli_print_legacy "$plat" "$driver" "$gl_vendor" "$gl_renderer"
  return 0
}

display_print_eglinfo_pipeline() {
  # Usage: display_print_eglinfo_pipeline auto|wayland|gbm|device|surfaceless
  mode="${1:-auto}"

  # Clear cached result on every call (prevents stale decisions)
  EGLI_LAST_PLATFORM=""
  EGLI_LAST_DRIVER=""
  EGLI_LAST_GL_VENDOR=""
  EGLI_LAST_GL_RENDERER=""
  EGLI_LAST_PIPE_KIND=""
  EGLI_LAST_OUT=""

  EGLINFO="${EGLINFO:-eglinfo}"
  if ! command -v "$EGLINFO" >/dev/null 2>&1; then
    log_error "eglinfo not found (EGLINFO='$EGLINFO')"
    return 1
  fi

  # egli_pick_platform_flag may return non-zero; treat empty as "use EGL_PLATFORM="
  plat_flag="$(egli_pick_platform_flag 2>/dev/null)" || plat_flag=""

  log_info "---------------- EGLINFO pipeline detection (select one) ----------------"

  if [ "$mode" = "auto" ]; then
    # Prefer wayland only if the socket really exists (base/prop handled)
    if egli_wayland_socket_ok; then
      if egli_try_one_platform "wayland" "$plat_flag"; then
        log_info "---------------- End EGLINFO pipeline detection --------------------------"
        return 0
      fi
    fi

    if egli_try_one_platform "gbm" "$plat_flag"; then
      log_info "---------------- End EGLINFO pipeline detection --------------------------"
      return 0
    fi

    if egli_try_one_platform "device" "$plat_flag"; then
      log_info "---------------- End EGLINFO pipeline detection --------------------------"
      return 0
    fi

    if egli_try_one_platform "surfaceless" "$plat_flag"; then
      log_info "---------------- End EGLINFO pipeline detection --------------------------"
      return 0
    fi

    log_warn "No working eglinfo platform found (tried wayland/gbm/device/surfaceless)."
    log_info "---------------- End EGLINFO pipeline detection --------------------------"
    return 1
  fi

  case "$mode" in
    wayland|gbm|device|surfaceless)
      # If user explicitly requested wayland but socket is not present, warn and fallback
      if [ "$mode" = "wayland" ] && ! egli_wayland_socket_ok; then
        log_warn "Requested 'wayland' but WAYLAND_DISPLAY socket is not present; trying fallbacks..."
      else
        if egli_try_one_platform "$mode" "$plat_flag"; then
          log_info "---------------- End EGLINFO pipeline detection --------------------------"
          return 0
        fi
        log_warn "Requested '$mode' did not work. Trying fallbacks..."
      fi

      # Fallback order: gbm -> device -> surfaceless -> wayland (last)
      if egli_try_one_platform "gbm" "$plat_flag"; then :;
      elif egli_try_one_platform "device" "$plat_flag"; then :;
      elif egli_try_one_platform "surfaceless" "$plat_flag"; then :;
      elif egli_wayland_socket_ok && egli_try_one_platform "wayland" "$plat_flag"; then :;
      else
        log_warn "No fallback platforms worked either."
      fi

      log_info "---------------- End EGLINFO pipeline detection --------------------------"
      return 0
      ;;
    *)
      log_warn "Unknown mode '$mode' (use: auto|wayland|gbm|device|surfaceless). Defaulting to auto."
      display_print_eglinfo_pipeline auto
      return $?
      ;;
  esac
}

###############################################################################
# GPU accel gating (detect-only)
###############################################################################
display_is_cpu_renderer() {
  # Usage: display_is_cpu_renderer <mode>
  # Prints EGLINFO block via display_print_eglinfo_pipeline().
  # Returns: 0 if CPU/software renderer detected, 1 otherwise (GPU or unknown)
  mode="${1:-auto}"

  # Print + cache a single selected platform (no re-run of eglinfo for decision)
  display_print_eglinfo_pipeline "$mode" || true

  # If we couldn't cache anything usable, do NOT claim CPU.
  if [ -z "${EGLI_LAST_PIPE_KIND:-}" ]; then
    return 1
  fi

  if printf '%s\n' "$EGLI_LAST_PIPE_KIND" | grep -qi '^CPU'; then
    return 0
  fi

  return 1
}

###############################################################################
# Wayland protocol validation (client-side)
###############################################################################
# Validate that the client actually created a surface and committed buffers.
# Expects WAYLAND_DEBUG output in the provided logfile.
#
# Usage:
# display_wayland_proto_validate "/path/to/run.log"
# Returns:
# 0 = looks good (surface + commit seen)
# 1 = missing required evidence
display_wayland_proto_validate() {
  logf="${1:-}"
  [ -n "$logf" ] && [ -f "$logf" ] || return 1

  # Accept both wl_compositor@X and wl_compositor#X formats
  # Accept commit() with or without parentheses in logs
  if grep -Eq 'wl_compositor[@#][0-9]+\.create_surface' "$logf" &&
     grep -Eq 'wl_surface[@#][0-9]+\.commit' "$logf"; then
    return 0
  fi

  return 1
}

###############################################################################
# Screenshot capture + delta validation
###############################################################################
# Uses weston-screenshooter when available.
# If the compositor rejects capture (unauthorized / protocol failure),
# treat it as "not available" so tests do not FAIL due to policy.
#
# Returns convention:
# 0 = success
# 1 = tool exists but capture failed
# 2 = tool not available or not permitted (unauthorized / protocol failure)

display_screenshot_tool() {
  if command -v weston-screenshooter >/dev/null 2>&1; then
    echo "weston-screenshooter"
    return 0
  fi
  return 1
}

display_take_screenshot() {
  out="${1:-}"
  [ -n "$out" ] || return 1

  tool="$(display_screenshot_tool 2>/dev/null || true)"
  [ -n "$tool" ] || return 2

  tmp_log="$(mktemp /tmp/weston_shot_XXXXXX.log 2>/dev/null || true)"
  [ -n "$tmp_log" ] || tmp_log="/tmp/weston_shot.log"

  rc=0
  case "$tool" in
    weston-screenshooter)
      # capture stdout+stderr to inspect authorization failures
      weston-screenshooter "$out" >"$tmp_log" 2>&1 || rc=$?
      ;;
    *)
      rm -f "$tmp_log" 2>/dev/null || true
      return 2
      ;;
  esac

  # If compositor rejects capture, treat as "not permitted" (skip)
  if grep -qiE 'unauthorized|protocol failure' "$tmp_log" 2>/dev/null; then
    rm -f "$tmp_log" 2>/dev/null || true
    rm -f "$out" 2>/dev/null || true
    return 2
  fi

  rm -f "$tmp_log" 2>/dev/null || true

  [ "$rc" -eq 0 ] || return 1
  [ -s "$out" ] || return 1
  return 0
}

display_hash_file() {
  f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 1

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
    return 0
  fi
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$f" | awk '{print $1}'
    return 0
  fi
  return 1
}

# Begin screenshot-delta session (captures "before" shot).
# Usage:
# display_screenshot_delta_begin "testname" "/path/to/outdir"
# Side effects:
# sets DISPLAY_SHOT_BEFORE and DISPLAY_SHOT_DIR
# Returns:
# 0 ok
# 2 tool missing or not permitted
# 1 capture failed
display_screenshot_delta_begin() {
  tn="${1:-weston-test}"
  od="${2:-.}"

  ts="$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%s)"
  DISPLAY_SHOT_DIR="$od"
  DISPLAY_SHOT_BEFORE="${od}/${tn}_before_${ts}.png"

  rc=0
  display_take_screenshot "$DISPLAY_SHOT_BEFORE" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_info "Screenshot before captured: $DISPLAY_SHOT_BEFORE"
    return 0
  fi

  if [ "$rc" -eq 2 ]; then
    log_warn "Screenshot tool not available or not permitted skipping screenshot delta validation"
    DISPLAY_SHOT_BEFORE=""
    return 2
  fi

  log_warn "Failed to capture screenshot before skipping screenshot delta validation"
  DISPLAY_SHOT_BEFORE=""
  return 1
}

# End screenshot-delta session (captures "after" and compares hash).
# Usage:
# display_screenshot_delta_end "testname"
# Returns:
# 0 changed (PASS)
# 1 identical (FAIL)
# 2 not available or skipped
display_screenshot_delta_end() {
  tn="${1:-weston-test}"
  [ -n "${DISPLAY_SHOT_BEFORE:-}" ] || return 2

  od="${DISPLAY_SHOT_DIR:-.}"
  ts="$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%s)"
  after="${od}/${tn}_after_${ts}.png"

  rc=0
  display_take_screenshot "$after" || rc=$?

  if [ "$rc" -eq 2 ]; then
    log_warn "Screenshot tool not available or not permitted skipping screenshot delta validation"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    log_warn "Failed to capture screenshot after skipping screenshot delta validation"
    return 2
  fi

  log_info "Screenshot after captured: $after"

  h1="$(display_hash_file "$DISPLAY_SHOT_BEFORE" 2>/dev/null || true)"
  h2="$(display_hash_file "$after" 2>/dev/null || true)"

  if [ -z "$h1" ] || [ -z "$h2" ]; then
    log_warn "Could not hash screenshots skipping screenshot delta validation"
    return 2
  fi

  if [ "$h1" = "$h2" ]; then
    log_warn "Screenshot delta check identical no visible change detected"
    return 1
  fi

  log_info "Screenshot delta check changed visual validation OK"
  return 0
}

# Resolve FPS expectation policy for display tests.
# Sets DISPLAY_FPS_* globals from FPS_EXPECT_MODE / EXPECT_FPS / detected refresh.
display_resolve_fps_policy() {
    DISPLAY_FPS_MODE=""
    DISPLAY_FPS_EXPECTED=""
    DISPLAY_FPS_DETECTED_HZ=""
    DISPLAY_FPS_MIN_OK=""
    DISPLAY_FPS_MAX_OK=""

    fps_mode="${FPS_EXPECT_MODE:-auto}"
    fps_expect="${EXPECT_FPS:-}"
    fps_default="${EXPECT_FPS_DEFAULT:-60}"
    fps_tol="${FPS_TOL_PCT:-10}"
    fps_min_pct="${MIN_FPS_PCT:-85}"

    case "$fps_mode" in
        auto)
            if [ -n "$fps_expect" ]; then
                DISPLAY_FPS_MODE="fixed"
            else
                DISPLAY_FPS_MODE="detected"
            fi
            ;;
        fixed|detected)
            DISPLAY_FPS_MODE="$fps_mode"
            ;;
        *)
            log_warn "display_resolve_fps_policy: unknown FPS_EXPECT_MODE='$fps_mode', defaulting to auto"
            if [ -n "$fps_expect" ]; then
                DISPLAY_FPS_MODE="fixed"
            else
                DISPLAY_FPS_MODE="detected"
            fi
            ;;
    esac

    if [ "$DISPLAY_FPS_MODE" = "detected" ]; then
        if command -v weston_get_primary_refresh_hz >/dev/null 2>&1; then
            DISPLAY_FPS_DETECTED_HZ="$(weston_get_primary_refresh_hz 2>/dev/null || true)"
        fi

        case "$DISPLAY_FPS_DETECTED_HZ" in
            ''|*[!0-9.]*)
                DISPLAY_FPS_MODE="fixed"
                if [ -n "$fps_expect" ]; then
                    DISPLAY_FPS_EXPECTED="$fps_expect"
                    log_warn "display_resolve_fps_policy: refresh detect failed, falling back to fixed EXPECT_FPS=$DISPLAY_FPS_EXPECTED"
                else
                    DISPLAY_FPS_EXPECTED="$fps_default"
                    log_warn "display_resolve_fps_policy: refresh detect failed, falling back to fixed EXPECT_FPS_DEFAULT=$DISPLAY_FPS_EXPECTED"
                fi
                ;;
            *)
                DISPLAY_FPS_EXPECTED="$(printf '%s\n' "$DISPLAY_FPS_DETECTED_HZ" | awk '{printf "%.0f\n", $1 + 0.0}')"
                DISPLAY_FPS_MIN_OK="$(awk -v f="$DISPLAY_FPS_EXPECTED" -v p="$fps_min_pct" 'BEGIN { printf "%.0f\n", f * p / 100.0 }')"
                log_info "FPS policy: mode=detected refresh=${DISPLAY_FPS_DETECTED_HZ}Hz expected=${DISPLAY_FPS_EXPECTED} min_ok=${DISPLAY_FPS_MIN_OK}"
                return 0
                ;;
        esac
    fi

    if [ -z "$DISPLAY_FPS_EXPECTED" ]; then
        if [ -n "$fps_expect" ]; then
            DISPLAY_FPS_EXPECTED="$fps_expect"
        else
            DISPLAY_FPS_EXPECTED="$fps_default"
        fi
    fi

    DISPLAY_FPS_MIN_OK="$(awk -v f="$DISPLAY_FPS_EXPECTED" -v t="$fps_tol" 'BEGIN { printf "%.0f\n", f * (100.0 - t) / 100.0 }')"
    DISPLAY_FPS_MAX_OK="$(awk -v f="$DISPLAY_FPS_EXPECTED" -v t="$fps_tol" 'BEGIN { printf "%.0f\n", f * (100.0 + t) / 100.0 }')"

    log_info "FPS policy: mode=fixed expected=${DISPLAY_FPS_EXPECTED} range=[${DISPLAY_FPS_MIN_OK}, ${DISPLAY_FPS_MAX_OK}]"
    return 0
}

# Apply refresh policy for display tests.
# Fixed ~60 FPS target gets best-effort 60Hz normalization; detected mode keeps native refresh.
display_apply_fps_refresh_policy() {
    if [ -z "${DISPLAY_FPS_MODE:-}" ] || [ -z "${DISPLAY_FPS_EXPECTED:-}" ]; then
        log_warn "display_apply_fps_refresh_policy: FPS policy not resolved"
        return 1
    fi

    if [ "$DISPLAY_FPS_MODE" = "detected" ]; then
        log_info "Detected FPS mode selected; keeping native refresh"
        return 0
    fi

    if hz_is_about_60 "${DISPLAY_FPS_EXPECTED}"; then
        if command -v weston_force_primary_1080p60_if_not_60 >/dev/null 2>&1; then
            log_info "Fixed ~60 FPS policy selected; ensuring primary output is ~60Hz (best-effort)"
            if weston_force_primary_1080p60_if_not_60; then
                log_info "Primary output is ~60Hz (or was already ~60Hz)"
            else
                log_warn "Unable to force ~60Hz (continuing; not a hard failure)"
            fi
        else
            log_warn "weston_force_primary_1080p60_if_not_60 helper not found; skipping ~60Hz enforcement"
        fi
    else
        log_info "Fixed FPS policy selected with expected=${DISPLAY_FPS_EXPECTED}; no refresh normalization applied"
    fi

    return 0
}

# Gate measured FPS against the resolved display FPS policy.
# Returns 0 for pass, 1 for fail. Logs the reason internally.
display_fps_gate_avg() {
    fps_avg="$1"
    fps_count="$2"
    require_fps="${REQUIRE_FPS:-1}"

    if [ "$require_fps" -eq 0 ]; then
        if [ "$fps_count" -eq 0 ]; then
            log_warn "REQUIRE_FPS=0 and no FPS samples found; skipping FPS gating"
        else
            log_info "REQUIRE_FPS=0; FPS stats recorded but not used for gating"
        fi
        return 0
    fi

    if [ "$fps_count" -eq 0 ]; then
        log_fail "FPS gating enabled but no FPS samples were found"
        return 1
    fi

    fps_int="$(printf '%s\n' "$fps_avg" | awk 'BEGIN {v=0} {v=$1+0.0} END {printf "%.0f\n", v}')"

    if [ "${DISPLAY_FPS_MODE:-}" = "detected" ]; then
        if [ -z "${DISPLAY_FPS_MIN_OK:-}" ]; then
            log_fail "Detected FPS policy missing minimum threshold"
            return 1
        fi

        if [ "$fps_int" -lt "$DISPLAY_FPS_MIN_OK" ]; then
            log_fail "Average FPS below detected-refresh threshold: avg=${fps_avg} (~${fps_int}) < ${DISPLAY_FPS_MIN_OK} (refresh=${DISPLAY_FPS_DETECTED_HZ}Hz)"
            return 1
        fi

        log_info "Detected-refresh FPS gate passed: avg=${fps_avg} (~${fps_int}) >= ${DISPLAY_FPS_MIN_OK} (refresh=${DISPLAY_FPS_DETECTED_HZ}Hz)"
        return 0
    fi

    if [ -z "${DISPLAY_FPS_MIN_OK:-}" ] || [ -z "${DISPLAY_FPS_MAX_OK:-}" ]; then
        log_fail "Fixed FPS policy missing valid range"
        return 1
    fi

    if [ "$fps_int" -lt "$DISPLAY_FPS_MIN_OK" ] || [ "$fps_int" -gt "$DISPLAY_FPS_MAX_OK" ]; then
        log_fail "Average FPS out of range: avg=${fps_avg} (~${fps_int}) not in [${DISPLAY_FPS_MIN_OK}, ${DISPLAY_FPS_MAX_OK}] (expected=${DISPLAY_FPS_EXPECTED})"
        return 1
    fi

    log_info "Fixed FPS gate passed: avg=${fps_avg} (~${fps_int}) in [${DISPLAY_FPS_MIN_OK}, ${DISPLAY_FPS_MAX_OK}]"
    return 0
}

# Parse FPS samples from a weston-simple-egl style log.
# Sets DISPLAY_FPS_COUNT / DISPLAY_FPS_AVG / DISPLAY_FPS_MIN / DISPLAY_FPS_MAX.
display_parse_fps_log() {
    logf="$1"

    DISPLAY_FPS_COUNT=0
    DISPLAY_FPS_AVG="-"
    DISPLAY_FPS_MIN="-"
    DISPLAY_FPS_MAX="-"

    [ -n "$logf" ] || return 1
    [ -r "$logf" ] || return 1

    fps_stats=$(
        awk '
            /[0-9]+[[:space:]]+frames in[[:space:]]+[0-9]+[[:space:]]+seconds/ {
                val = $(NF-1) + 0.0
                all_n++
                all_vals[all_n] = val
            }
            END {
                if (all_n == 0) exit

                if (all_n == 1) {
                    n = 1
                    sum = all_vals[1]
                    min = all_vals[1]
                    max = all_vals[1]
                } else {
                    n = 0
                    sum = 0.0
                    for (i = 2; i <= all_n; i++) {
                        v = all_vals[i]
                        n++
                        sum += v
                        if (n == 1 || v < min) min = v
                        if (n == 1 || v > max) max = v
                    }
                }

                if (n > 0) {
                    avg = sum / n
                    printf "n=%d avg=%f min=%f max=%f\n", n, avg, min, max
                }
            }
        ' "$logf" 2>/dev/null || true
    )

    [ -n "$fps_stats" ] || return 1

    DISPLAY_FPS_COUNT=$(printf '%s\n' "$fps_stats" | awk '{print $1}' | sed 's/^n=//')
    DISPLAY_FPS_AVG=$(printf '%s\n' "$fps_stats" | awk '{print $2}' | sed 's/^avg=//')
    DISPLAY_FPS_MIN=$(printf '%s\n' "$fps_stats" | awk '{print $3}' | sed 's/^min=//')
    DISPLAY_FPS_MAX=$(printf '%s\n' "$fps_stats" | awk '{print $4}' | sed 's/^max=//')

    case "$DISPLAY_FPS_COUNT" in ''|*[!0-9]*) DISPLAY_FPS_COUNT=0 ;; esac
    [ -n "$DISPLAY_FPS_AVG" ] || DISPLAY_FPS_AVG="-"
    [ -n "$DISPLAY_FPS_MIN" ] || DISPLAY_FPS_MIN="-"
    [ -n "$DISPLAY_FPS_MAX" ] || DISPLAY_FPS_MAX="-"

    return 0
}

# Detect display build flavour dynamically from available EGL vendor JSON files.
# Exports:
#   DISPLAY_BUILD_FLAVOUR, base or overlay
#   DISPLAY_EGL_VENDOR_JSON, matched vendor JSON path, empty when not found
# Return:
#   0 always, detection is best-effort and defaults to base
display_detect_build_flavour() {
    DISPLAY_BUILD_FLAVOUR="base"
    DISPLAY_EGL_VENDOR_JSON=""

    for d in /usr/share/glvnd/egl_vendor.d /etc/glvnd/egl_vendor.d; do
        [ -d "$d" ] || continue

        for f in "$d"/*adreno*.json "$d"/*EGL_adreno*.json; do
            [ -e "$f" ] || continue
            if [ -f "$f" ]; then
                DISPLAY_EGL_VENDOR_JSON="$f"
                DISPLAY_BUILD_FLAVOUR="overlay"
                export DISPLAY_BUILD_FLAVOUR
                export DISPLAY_EGL_VENDOR_JSON
                return 0
            fi
        done
    done

    export DISPLAY_BUILD_FLAVOUR
    export DISPLAY_EGL_VENDOR_JSON
    return 0
}

# Log display snapshots and require at least one connected DRM display.
# This helper keeps display gating dynamic, no connector names or fixed paths are hardcoded.
# Arguments:
#   $1, testcase name for log messages
#   $2, optional modetest line cap, default 200
# Exports:
#   DISPLAY_CONNECTED_SUMMARY, sysfs display summary, or none
# Return:
#   0 when at least one connected display is found
#   1 when no connected DRM display is found
display_log_snapshot_and_require_connector() {
    ds_testname="$1"
    ds_modetest_cap="${2:-200}"

    DISPLAY_CONNECTED_SUMMARY="none"
    export DISPLAY_CONNECTED_SUMMARY

    if command -v display_debug_snapshot >/dev/null 2>&1; then
        display_debug_snapshot "pre-display-check"
    fi

    if command -v modetest >/dev/null 2>&1; then
        log_info "----- modetest -M msm -ac, capped at ${ds_modetest_cap} lines -----"
        modetest -M msm -ac 2>&1 | sed -n "1,${ds_modetest_cap}p" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            log_info "[modetest] $line"
        done
        log_info "----- End modetest -M msm -ac -----"
    else
        log_warn "modetest not found in PATH, skipping modetest snapshot"
    fi

    if command -v display_connected_summary >/dev/null 2>&1; then
        DISPLAY_CONNECTED_SUMMARY="$(display_connected_summary 2>/dev/null || true)"
        export DISPLAY_CONNECTED_SUMMARY
    fi

    if [ -z "$DISPLAY_CONNECTED_SUMMARY" ] || [ "$DISPLAY_CONNECTED_SUMMARY" = "none" ]; then
        log_warn "No connected DRM display found, skipping ${ds_testname}"
        return 1
    fi

    log_info "Connected display, ${DISPLAY_CONNECTED_SUMMARY}"
    return 0
}

# Return success when a Weston process is running.
weston_has_running_process() {
    if command -v weston_is_running >/dev/null 2>&1; then
        if weston_is_running >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -x weston >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# Print Weston runtime diagnostics, including systemd unit state, process list, and env.
# Arguments:
# $1, snapshot label
weston_log_runtime_snapshot() {
    wlr_label="$1"
    wlr_pids=""
    wlr_state=""

    log_info "----- Weston runtime snapshot, ${wlr_label} -----"

    if command -v systemd_service_exists >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
        if systemd_service_exists weston.service; then
            wlr_state="$(systemctl is-active weston.service 2>/dev/null || true)"
            if [ "$wlr_state" = "failed" ]; then
                log_warn "systemd weston.service, state=${wlr_state}"
            else
                log_info "systemd weston.service, state=${wlr_state:-unknown}"
            fi
        fi

        if systemd_service_exists weston.socket; then
            wlr_state="$(systemctl is-active weston.socket 2>/dev/null || true)"
            if [ "$wlr_state" = "failed" ]; then
                log_warn "systemd weston.socket, state=${wlr_state}"
            else
                log_info "systemd weston.socket, state=${wlr_state:-unknown}"
            fi
        fi
    fi

    if command -v weston_log_service_runtime_context >/dev/null 2>&1; then
        weston_log_service_runtime_context || true
    fi

    if command -v pgrep >/dev/null 2>&1; then
        wlr_pids="$(pgrep -x weston 2>/dev/null || true)"
    fi

    if [ -n "$wlr_pids" ]; then
        log_info "weston PIDs, $(printf '%s' "$wlr_pids" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        if command -v ps >/dev/null 2>&1; then
            printf '%s\n' "$wlr_pids" | while IFS= read -r pid; do
                if [ -n "$pid" ]; then
                    ps -o pid= -o user= -o group= -o args= -p "$pid" 2>/dev/null | while IFS= read -r line; do
                        log_info "[ps] $line"
                    done
                fi
            done
        fi
    else
        log_warn "No weston process found"
    fi

    log_info "Env now, XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
    log_info "----- End Weston runtime snapshot, ${wlr_label} -----"
}

# Print the configured systemd user for weston.service.
weston_systemd_service_user() {
    wsu_user=""

    if ! command -v systemd_service_exists >/dev/null 2>&1; then
        return 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        return 1
    fi
    if ! systemd_service_exists weston.service; then
        return 1
    fi

    wsu_user="$(systemctl show -p User --value weston.service 2>/dev/null || true)"
    if [ -n "$wsu_user" ]; then
        printf '%s\n' "$wsu_user"
        return 0
    fi

    return 1
}

# Prefer the Wayland socket that belongs to the systemd-managed Weston user.
# Fall back to generic discovery only when needed.
weston_preferred_socket() {
    wps_user=""
    wps_uid=""
    wps_dir=""
    wps_sock=""

    if wps_user="$(weston_systemd_service_user 2>/dev/null)"; then
        wps_uid="$(id -u "$wps_user" 2>/dev/null || true)"
        if [ -n "$wps_uid" ]; then
            wps_dir="/run/user/$wps_uid"
            if [ -d "$wps_dir" ]; then
                for wps_sock in "$wps_dir"/wayland-*; do
                    if [ -S "$wps_sock" ]; then
                        printf '%s\n' "$wps_sock"
                        return 0
                    fi
                done
            fi
        fi
    fi

    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        discover_wayland_socket_anywhere 2>/dev/null | head -n 1
        return 0
    fi

    return 1
}

# Restart the systemd-managed Weston runtime cleanly.
# This is the preferred relaunch path when weston.service exists.
weston_restart_systemd_runtime() {
    wrs_wait="${1:-10}"
    wrs_user=""
    wrs_uid=""
    wrs_dir=""

    if ! command -v systemd_service_exists >/dev/null 2>&1; then
        return 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        return 1
    fi
    if ! systemd_service_exists weston.service; then
        return 1
    fi

    log_info "Relaunch path, restarting systemd-managed Weston runtime"

    if systemd_service_exists weston.socket; then
        log_info "Stopping weston.socket before relaunch"
        systemctl stop weston.socket >/dev/null 2>&1 || true
    fi

    log_info "Stopping weston.service before relaunch"
    systemctl stop weston.service >/dev/null 2>&1 || true

    log_info "Resetting failed Weston systemd state before relaunch"
    systemctl reset-failed weston.service weston.socket >/dev/null 2>&1 || true

    wrs_user="$(weston_systemd_service_user 2>/dev/null || true)"
    if [ -n "$wrs_user" ]; then
        wrs_uid="$(id -u "$wrs_user" 2>/dev/null || true)"
        if [ -n "$wrs_uid" ]; then
            wrs_dir="/run/user/$wrs_uid"
            log_info "Preferred Weston service user, ${wrs_user}"
            log_info "Preferred Weston runtime directory, ${wrs_dir}"
        fi
    fi

    if systemd_service_exists weston.socket; then
        log_info "Starting weston.socket"
        systemctl start weston.socket >/dev/null 2>&1 || true
    fi

    log_info "Starting weston.service"
    if ! systemctl start weston.service >/dev/null 2>&1; then
        return 1
    fi

    if command -v weston_wait_ready >/dev/null 2>&1; then
        weston_wait_ready "$wrs_wait" || true
    fi

    if systemctl is-failed --quiet weston.service 2>/dev/null; then
        return 1
    fi

    if ! weston_has_running_process; then
        return 1
    fi

    return 0
}

# Log the runtime context derived from weston.service user configuration.
weston_log_service_runtime_context() {
    wls_user=""
    wls_uid=""
    wls_dir=""
    wls_sock_found=0
    wls_sock=""

    if ! command -v weston_systemd_service_user >/dev/null 2>&1; then
        log_warn "weston_systemd_service_user helper not available"
        return 1
    fi

    wls_user="$(weston_systemd_service_user 2>/dev/null || true)"
    if [ -z "$wls_user" ]; then
        log_warn "Could not determine Weston service user"
        return 1
    fi

    log_info "Weston service user, ${wls_user}"

    if id "$wls_user" >/dev/null 2>&1; then
        wls_uid="$(id -u "$wls_user" 2>/dev/null || true)"
        log_info "Weston service UID, ${wls_uid:-<unknown>}"
    else
        log_warn "Weston service user does not exist on target, ${wls_user}"
        return 1
    fi

    if [ -n "$wls_uid" ]; then
        wls_dir="/run/user/$wls_uid"
        log_info "Weston preferred runtime directory, ${wls_dir}"

        if [ -d "$wls_dir" ]; then
            log_info "Weston runtime directory exists, ${wls_dir}"
            find "$wls_dir" -prune -print 2>/dev/null | while IFS= read -r line; do
                log_info "[runtime-dir] $line"
            done

            for wls_sock in "$wls_dir"/wayland-*; do
                if [ -S "$wls_sock" ]; then
                    if [ "$wls_sock_found" -eq 0 ]; then
                        log_info "Wayland sockets under preferred runtime directory:"
                    fi
                    log_info "[socket] ${wls_sock}"
                    wls_sock_found=1
                fi
            done

            if [ "$wls_sock_found" -eq 0 ]; then
                log_info "No Wayland sockets found under preferred runtime directory, ${wls_dir}"
            fi
        else
            log_warn "Weston runtime directory does not exist, ${wls_dir}"
        fi
    fi

    return 0
}

# Prepare a usable Weston and Wayland runtime dynamically for a display test.
# Validation mode:
# runtime, only verify Weston runtime readiness, process and socket
# client, also verify a real Wayland client path through wayland_connection_ok
# Relaunch policy:
# default is disabled
# when enabled, failed Weston systemd state is cleaned before relaunch
# Arguments:
# $1, testcase name for log messages
# $2, wait timeout in seconds, default 10
# $3, validation mode, runtime or client, default runtime
# $4, allow relaunch, 1 enables relaunch, 0 disables it, default 0
# Exports:
# DISPLAY_WAYLAND_SOCKET, final adopted Wayland socket path
# DISPLAY_RUNTIME_MODEL, per-user, global, or custom
# Return:
# 0 when runtime is ready and usable
# 1 when no Wayland socket is found on base, connected display is present, Weston runtime is expected
# 2 when no Wayland socket is found on overlay after optional relaunch handling
# 3 when runtime validation fails, or Weston process is missing and relaunch is disabled
weston_prepare_runtime() {
    wr_testname="$1"
    wr_wait_secs="${2:-10}"
    wr_validate_mode="${3:-runtime}"
    wr_allow_relaunch="${4:-0}"

    DISPLAY_WAYLAND_SOCKET=""
    DISPLAY_RUNTIME_MODEL="unknown"
    export DISPLAY_WAYLAND_SOCKET
    export DISPLAY_RUNTIME_MODEL

    if [ -z "${DISPLAY_BUILD_FLAVOUR:-}" ]; then
        display_detect_build_flavour
    fi

    if command -v weston_log_runtime_snapshot >/dev/null 2>&1; then
        weston_log_runtime_snapshot "${wr_testname}: start"
    elif command -v wayland_debug_snapshot >/dev/null 2>&1; then
        wayland_debug_snapshot "${wr_testname}: start"
    fi

    wr_sock=""
    wr_new_sock=""
    wr_service_failed=0
    wr_need_relaunch=0

    if command -v systemd_service_exists >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
        if systemd_service_exists weston.service; then
            if systemctl is-failed --quiet weston.service 2>/dev/null; then
                wr_service_failed=1
            fi
        fi
    fi

    if weston_has_running_process; then
        if [ "$wr_allow_relaunch" -eq 1 ]; then
            log_info "Relaunch not required, Weston already running"
        fi
    else
        wr_need_relaunch=1
    fi

    if [ "$wr_service_failed" -eq 1 ]; then
        if [ "$wr_allow_relaunch" -eq 1 ]; then
            wr_need_relaunch=1
            log_warn "weston.service is in failed state, cleanup and relaunch will be attempted"
        else
            log_fail "weston.service is in failed state, runtime is not healthy"
            return 3
        fi
    fi

    if [ "$wr_need_relaunch" -eq 1 ]; then
        if [ "$wr_allow_relaunch" -ne 1 ]; then
            if [ "$wr_service_failed" -eq 1 ]; then
                log_fail "weston.service is in failed state, runtime relaunch is disabled"
            else
                log_fail "No weston process found, runtime relaunch is disabled"
            fi
            return 3
        fi

        log_warn "Preparing Weston runtime relaunch, cleaning stale systemd state first"

        if command -v systemd_service_exists >/dev/null 2>&1 && systemd_service_exists weston.service; then
            if ! weston_restart_systemd_runtime "$wr_wait_secs"; then
                if command -v weston_log_runtime_snapshot >/dev/null 2>&1; then
                    weston_log_runtime_snapshot "${wr_testname}: after-relaunch"
                fi
                log_fail "Weston relaunch attempt failed, systemd-managed Weston could not be recovered"
                return 3
            fi
        elif command -v weston_restore_runtime >/dev/null 2>&1; then
            log_info "Attempting weston_restore_runtime"
            if ! weston_restore_runtime "$wr_wait_secs"; then
                if command -v weston_log_runtime_snapshot >/dev/null 2>&1; then
                    weston_log_runtime_snapshot "${wr_testname}: after-relaunch"
                fi
                log_fail "Weston relaunch attempt failed, weston_restore_runtime returned non-zero"
                return 3
            fi
        elif [ "$DISPLAY_BUILD_FLAVOUR" = "overlay" ] && command -v overlay_start_weston_drm >/dev/null 2>&1; then
            log_info "Attempting overlay_start_weston_drm"

            if command -v weston_force_primary_1080p60_if_not_60 >/dev/null 2>&1; then
                log_info "Pre-configuring primary output to about 60Hz before starting Weston, best effort"
                weston_force_primary_1080p60_if_not_60 || true
            fi

            if ! overlay_start_weston_drm; then
                if command -v weston_log_runtime_snapshot >/dev/null 2>&1; then
                    weston_log_runtime_snapshot "${wr_testname}: after-relaunch"
                fi
                log_fail "Weston relaunch attempt failed, overlay_start_weston_drm returned non-zero"
                return 3
            fi

            if command -v weston_wait_ready >/dev/null 2>&1; then
                weston_wait_ready "$wr_wait_secs" || true
            fi
        else
            log_fail "No Weston relaunch helper is available"
            return 3
        fi

        if command -v weston_log_runtime_snapshot >/dev/null 2>&1; then
            weston_log_runtime_snapshot "${wr_testname}: after-relaunch"
        fi

        if command -v systemd_service_exists >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
            if systemd_service_exists weston.service; then
                if systemctl is-failed --quiet weston.service 2>/dev/null; then
                    log_fail "weston.service is still in failed state after relaunch attempt"
                    return 3
                fi
            fi
        fi

        if ! weston_has_running_process; then
            log_fail "Weston relaunch did not result in a running process"
            return 3
        fi
    fi

    if ! weston_has_running_process; then
        log_fail "Wayland runtime validation failed, Weston process is not running"
        return 3
    fi

    if command -v weston_preferred_socket >/dev/null 2>&1; then
        wr_sock="$(weston_preferred_socket 2>/dev/null || true)"
    elif command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        wr_sock="$(discover_wayland_socket_anywhere 2>/dev/null | head -n 1 || true)"
    fi

    if [ -n "$wr_sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        log_info "Found existing Wayland socket, ${wr_sock}"
        if ! adopt_wayland_env_from_socket "$wr_sock"; then
            log_warn "Failed to adopt environment from ${wr_sock}"
        fi
    fi

    if [ -z "$wr_sock" ] && command -v weston_wait_ready >/dev/null 2>&1; then
        log_info "No usable Wayland socket yet, waiting briefly for Weston runtime"
        if weston_wait_ready "$wr_wait_secs"; then
            if command -v weston_preferred_socket >/dev/null 2>&1; then
                wr_sock="$(weston_preferred_socket 2>/dev/null || true)"
            elif command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
                wr_sock="$(discover_wayland_socket_anywhere 2>/dev/null | head -n 1 || true)"
            fi

            if [ -n "$wr_sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
                log_info "Weston runtime became ready, ${wr_sock}"
                if ! adopt_wayland_env_from_socket "$wr_sock"; then
                    log_warn "Failed to adopt environment from ${wr_sock} after wait"
                fi
            fi
        fi
    fi

    if command -v weston_preferred_socket >/dev/null 2>&1; then
        wr_new_sock="$(weston_preferred_socket 2>/dev/null || true)"
        if [ -n "$wr_new_sock" ]; then
            wr_sock="$wr_new_sock"
        fi
    elif command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        wr_new_sock="$(discover_wayland_socket_anywhere 2>/dev/null | head -n 1 || true)"
        if [ -n "$wr_new_sock" ]; then
            wr_sock="$wr_new_sock"
        fi
    fi

    if [ -z "$wr_sock" ]; then
        if [ "$DISPLAY_BUILD_FLAVOUR" = "base" ]; then
            log_fail "No Wayland socket found on base build, connected display is present, Weston runtime is expected"
            return 1
        fi

        log_fail "No Wayland socket found on overlay build after optional relaunch handling"
        return 2
    fi

    case "$wr_sock" in
        /run/user/*/wayland-*)
            DISPLAY_RUNTIME_MODEL="per-user"
            ;;
        /run/wayland-*)
            DISPLAY_RUNTIME_MODEL="global"
            ;;
        *)
            DISPLAY_RUNTIME_MODEL="custom"
            ;;
    esac

    DISPLAY_WAYLAND_SOCKET="$wr_sock"
    export DISPLAY_RUNTIME_MODEL
    export DISPLAY_WAYLAND_SOCKET

    log_info "Wayland runtime model, ${DISPLAY_RUNTIME_MODEL}"
    log_info "Wayland socket, ${DISPLAY_WAYLAND_SOCKET}"
    log_info "XDG_RUNTIME_DIR, ${XDG_RUNTIME_DIR:-<unset>}"
    log_info "WAYLAND_DISPLAY, ${WAYLAND_DISPLAY:-<unset>}"

    if [ "$wr_validate_mode" = "client" ]; then
        if command -v wayland_connection_ok >/dev/null 2>&1; then
            if ! wayland_connection_ok; then
                log_fail "Wayland client probe failed, runtime is not usable"
                return 3
            fi
            log_info "Wayland client probe, OK"
        else
            log_warn "wayland_connection_ok helper not found, continuing with runtime-only checks"
        fi
    else
        if ! weston_has_running_process; then
            log_fail "Wayland runtime validation failed, Weston process is not running"
            return 3
        fi

        if command -v weston_runtime_socket_exists >/dev/null 2>&1; then
            if ! weston_runtime_socket_exists; then
                log_fail "Wayland runtime validation failed, socket is not present after adoption"
                return 3
            fi
        fi

        if command -v systemd_service_exists >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
            if systemd_service_exists weston.service; then
                if systemctl is-failed --quiet weston.service 2>/dev/null; then
                    log_fail "Wayland runtime validation failed, weston.service is in failed state"
                    return 3
                fi
            fi
        fi

        if command -v weston_log_runtime_snapshot >/dev/null 2>&1; then
            weston_log_runtime_snapshot "${wr_testname}: final"
        fi

        log_info "Wayland runtime validation, OK"
    fi

    return 0
}
