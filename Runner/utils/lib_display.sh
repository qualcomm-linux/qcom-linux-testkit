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
        # stderr: callers capture stdout as the summary.
        log_warn "display_connected_summary: $ds_base not found" >&2
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

# Select the DRM card device that owns the preferred connected display.
# Prints /dev/dri/cardN when a real connected connector is available.
display_select_primary_drm_device() {
    connector=""
    card_idx=""
    card_dev=""

    if connector="$(display_select_primary_connector)"; then
        if [ -z "$connector" ]; then
            log_warn "display_select_primary_drm_device: display_select_primary_connector returned empty output" >&2
            return 1
        fi
    else
        log_warn "display_select_primary_drm_device: display_select_primary_connector failed" >&2
        return 1
    fi

    if card_idx="$(display__drm_idx_from_sysfs_connector "$connector")"; then
        :
    else
        log_warn "display_select_primary_drm_device: failed to extract DRM card index from connector '$connector'" >&2
        return 1
    fi

    case "$card_idx" in
        ""|*[!0-9]*)
            log_warn "display_select_primary_drm_device: invalid DRM card index '$card_idx' from connector '$connector'" >&2
            return 1
            ;;
    esac

    card_dev="/dev/dri/card$card_idx"
    if [ ! -e "$card_dev" ]; then
        log_warn "display_select_primary_drm_device: selected DRM device '$card_dev' does not exist for connector '$connector'" >&2
        return 1
    fi

    printf '%s\n' "$card_dev"
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

# Adopt the live GNOME Wayland session without changing the desktop compositor.
# The selected socket must be owned by a running gnome-shell user so later
# clients can be executed with the same uid and runtime directory.
display_adopt_gnome_wayland_session() {
    dagws_pid=""
    dagws_user=""
    dagws_uid=""
    dagws_runtime_dir=""
    dagws_socket=""
    dagws_socket_uid=""
    dagws_home=""

    DISPLAY_WAYLAND_SESSION_USER=""
    DISPLAY_WAYLAND_SESSION_HOME=""
    DISPLAY_WAYLAND_SESSION_RUNTIME_DIR=""
    DISPLAY_WAYLAND_SOCKET=""
    DISPLAY_RUNTIME_MODEL="unknown"
    export DISPLAY_WAYLAND_SESSION_USER
    export DISPLAY_WAYLAND_SESSION_HOME
    export DISPLAY_WAYLAND_SESSION_RUNTIME_DIR
    export DISPLAY_WAYLAND_SOCKET
    export DISPLAY_RUNTIME_MODEL

    command -v pgrep >/dev/null 2>&1 || return 1
    command -v ps >/dev/null 2>&1 || return 1
    command -v id >/dev/null 2>&1 || return 1

    for dagws_pid in $(pgrep -x gnome-shell 2>/dev/null); do
        dagws_user="$(ps -o user= -p "$dagws_pid" 2>/dev/null | awk 'NR == 1 { print $1 }')"
        [ -n "$dagws_user" ] || continue

        dagws_uid="$(id -u "$dagws_user" 2>/dev/null || true)"
        [ -n "$dagws_uid" ] || continue

        dagws_runtime_dir="/run/user/$dagws_uid"
        [ -d "$dagws_runtime_dir" ] || continue

        for dagws_socket in "$dagws_runtime_dir"/wayland-*; do
            [ -S "$dagws_socket" ] || continue

            dagws_socket_uid="$(stat -c '%u' "$dagws_socket" 2>/dev/null || true)"
            [ "$dagws_socket_uid" = "$dagws_uid" ] || continue

            dagws_home="$(getent passwd "$dagws_user" 2>/dev/null | awk -F: 'NR == 1 { print $6 }')"
            [ -n "$dagws_home" ] || dagws_home="/"

            DISPLAY_WAYLAND_SESSION_USER="$dagws_user"
            DISPLAY_WAYLAND_SESSION_HOME="$dagws_home"
            DISPLAY_WAYLAND_SESSION_RUNTIME_DIR="$dagws_runtime_dir"
            DISPLAY_WAYLAND_SOCKET="$dagws_socket"
            DISPLAY_RUNTIME_MODEL="desktop-gnome-session"
            export DISPLAY_WAYLAND_SESSION_USER
            export DISPLAY_WAYLAND_SESSION_HOME
            export DISPLAY_WAYLAND_SESSION_RUNTIME_DIR
            export DISPLAY_WAYLAND_SOCKET
            export DISPLAY_RUNTIME_MODEL

            log_info "Adopted GNOME Wayland session, user=$dagws_user socket=$dagws_socket"
            return 0
        done
    done

    return 1
}

# Run a command in the user context that owns an adopted GNOME Wayland socket.
# When no GNOME session was adopted, preserve the caller's existing execution.
display_run_in_wayland_session() {
    drws_user="${DISPLAY_WAYLAND_SESSION_USER:-}"
    drws_home="${DISPLAY_WAYLAND_SESSION_HOME:-/}"
    drws_runtime_dir="${DISPLAY_WAYLAND_SESSION_RUNTIME_DIR:-}"
    drws_socket="${DISPLAY_WAYLAND_SOCKET:-}"

    if [ -z "$drws_user" ] ||
       [ -z "$drws_runtime_dir" ] ||
       [ -z "$drws_socket" ]; then
        "$@"
        return $?
    fi

    if [ "$(id -un 2>/dev/null || true)" = "$drws_user" ]; then
        env \
            HOME="$drws_home" \
            XDG_RUNTIME_DIR="$drws_runtime_dir" \
            WAYLAND_DISPLAY="$(basename "$drws_socket")" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$drws_runtime_dir/bus" \
            "$@"
        return $?
    fi

    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        log_error "Cannot access the adopted GNOME Wayland session as user=$drws_user without root"
        return 1
    fi

    if ! command -v runuser >/dev/null 2>&1; then
        log_error "runuser is unavailable, cannot access the adopted GNOME Wayland session"
        return 1
    fi

    runuser -u "$drws_user" -- env \
        HOME="$drws_home" \
        XDG_RUNTIME_DIR="$drws_runtime_dir" \
        WAYLAND_DISPLAY="$(basename "$drws_socket")" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$drws_runtime_dir/bus" \
        "$@"
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

# Return success when the currently exported Wayland environment is usable.
#
# The probe must validate only Wayland connectivity. It must not depend on
# EGL, GLES, GLVND vendor selection, or GPU acceleration.
#
# Inputs:
#   XDG_RUNTIME_DIR
#   WAYLAND_DISPLAY
#
# Arguments:
#   None
#
# Return:
#   0 - the Wayland client probe succeeded
#   1 - the Wayland client probe failed
wayland_connection_ok() {
    wco_socket=""
    wco_rc=1
    wco_pid=""
    wco_probe_log="${TMPDIR:-/tmp}/wayland_connection_ok.$$"
 
    if [ -n "${XDG_RUNTIME_DIR:-}" ] &&
       [ -n "${WAYLAND_DISPLAY:-}" ]; then
        case "$WAYLAND_DISPLAY" in
            /*)
                wco_socket="$WAYLAND_DISPLAY"
                ;;
            *)
                wco_socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
                ;;
        esac
    fi
 
    if [ -z "$wco_socket" ]; then
        log_warn "wayland_connection_ok: Wayland environment is incomplete"
        return 1
    fi
 
    log_info "wayland_connection_ok: using socket $wco_socket"
 
    if [ ! -S "$wco_socket" ]; then
        log_warn "wayland_connection_ok: Wayland socket is unavailable: $wco_socket"
        return 1
    fi
 
    rm -f "$wco_probe_log"
 
    if command -v wayland-info >/dev/null 2>&1; then
        log_info "Probing Wayland connection with wayland-info"
 
        if command -v run_with_timeout >/dev/null 2>&1; then
            run_with_timeout \
                "3s" \
                wayland-info \
                >"$wco_probe_log" 2>&1
            wco_rc=$?
        else
            wayland-info >"$wco_probe_log" 2>&1
            wco_rc=$?
        fi
 
        if [ "$wco_rc" -eq 0 ]; then
            rm -f "$wco_probe_log"
            log_pass "Wayland connection probe passed"
            return 0
        fi
 
        log_warn "wayland_connection_ok: wayland-info returned $wco_rc"
        sed -n '1,40p' "$wco_probe_log" 2>/dev/null || true
        rm -f "$wco_probe_log"
        return 1
    fi
 
    if ! command -v weston-simple-shm >/dev/null 2>&1; then
        log_warn "wayland_connection_ok: no Wayland probe client is available"
        log_warn "Expected wayland-info or weston-simple-shm"
        return 1
    fi
 
    log_info "Probing Wayland connection with weston-simple-shm"
 
    if command -v run_with_timeout >/dev/null 2>&1; then
        run_with_timeout \
            "3s" \
            weston-simple-shm \
            >"$wco_probe_log" 2>&1
        wco_rc=$?
 
        case "$wco_rc" in
            0|124|137|143)
                rm -f "$wco_probe_log"
                log_pass "Wayland connection probe passed"
                return 0
                ;;
            *)
                log_warn "wayland_connection_ok: weston-simple-shm returned $wco_rc"
                sed -n '1,40p' "$wco_probe_log" 2>/dev/null || true
                rm -f "$wco_probe_log"
                return 1
                ;;
        esac
    fi
 
    weston-simple-shm >"$wco_probe_log" 2>&1 &
    wco_pid=$!
 
    sleep 1
 
    if ! kill -0 "$wco_pid" 2>/dev/null; then
        wait "$wco_pid" 2>/dev/null
        wco_rc=$?
 
        log_warn "wayland_connection_ok: weston-simple-shm exited early, rc=$wco_rc"
        sed -n '1,40p' "$wco_probe_log" 2>/dev/null || true
        rm -f "$wco_probe_log"
        return 1
    fi
 
    kill "$wco_pid" 2>/dev/null || true
    wait "$wco_pid" 2>/dev/null || true
    rm -f "$wco_probe_log"
 
    log_pass "Wayland connection probe passed"
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

# Adopt an existing Wayland socket and validate that a client can connect.
# This supports socket-activated Weston setups where weston.service may not
# already be running, but weston.socket or /run/wayland-* can activate it.
weston_adopt_existing_runtime_and_probe() {
    tag="$1"
    sock=""

    if command -v weston_preferred_socket >/dev/null 2>&1; then
        sock="$(weston_preferred_socket 2>/dev/null || true)"
    fi

    if [ -z "$sock" ] && command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        sock="$(discover_wayland_socket_anywhere 2>/dev/null | head -n 1 || true)"
    fi

    if [ -z "$sock" ]; then
        log_warn "No Wayland socket found for ${tag}"
        return 1
    fi

    if ! command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        log_warn "adopt_wayland_env_from_socket helper not found for ${tag}"
        return 1
    fi

    if ! command -v wayland_connection_ok >/dev/null 2>&1; then
        log_warn "wayland_connection_ok helper not found for ${tag}"
        return 1
    fi

    log_info "Found existing Wayland socket, ${sock}"

    if ! adopt_wayland_env_from_socket "$sock"; then
        log_warn "Failed to adopt Wayland environment from ${sock}"
        return 1
    fi

    if ! wayland_connection_ok; then
        log_warn "Wayland socket probe failed for ${sock}"
        return 1
    fi

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

# Extract one platform section from multi-platform Mesa eglinfo output.
#
# Args:
#   $1 - platform name: x11, wayland, gbm, device, or surfaceless
#
# Input:
#   eglinfo output on stdin
#
# Output:
#   Only the requested platform section
egli_extract_platform_section() {
    eps_platform="$1"

    awk \
        -v wanted="$eps_platform" '
        function platform_name(line) {
            if (line ~ /^GBM platform:[[:space:]]*$/) {
                return "gbm"
            }

            if (line ~ /^Wayland platform:[[:space:]]*$/) {
                return "wayland"
            }

            if (line ~ /^X11 platform:[[:space:]]*$/) {
                return "x11"
            }

            if (line ~ /^Surfaceless platform:[[:space:]]*$/) {
                return "surfaceless"
            }

            if (line ~ /^Device platform:[[:space:]]*$/) {
                return "device"
            }

            return ""
        }

        {
            detected = platform_name($0)

            if (detected != "") {
                if (selected && detected != wanted) {
                    exit
                }

                selected = detected == wanted
            }

            if (selected) {
                print
            }
        }
        '
}

egli_try_one_platform() {
    plat="$1"
    plat_flag="$2"
 
    EGLINFO="${EGLINFO:-eglinfo}"
 
    out=""
    parse_out=""
    platform_out=""
    rc=0
 
    if [ -n "$plat_flag" ]; then
        out="$(
            "$EGLINFO" \
                "$plat_flag" \
                "$plat" \
                2>&1
        )"
 
        rc=$?
    else
        out="$(
            EGL_PLATFORM="$plat" \
                "$EGLINFO" \
                2>&1
        )"
 
        rc=$?
    fi
 
    platform_out="$(
        printf '%s\n' "$out" |
            egli_extract_platform_section \
                "$plat"
    )"
 
    if [ -n "$platform_out" ]; then
        parse_out="$platform_out"
    else
        parse_out="$out"
    fi
 
    egl_vendor="$(
        printf '%s\n' "$parse_out" |
            egli_get_field \
                "EGL vendor string"
    )"
 
    egl_version="$(
        printf '%s\n' "$parse_out" |
            egli_get_field \
                "EGL version string"
    )"
 
    egl_api_ver="$(
        printf '%s\n' "$parse_out" |
            egli_get_field \
                "EGL API version"
    )"
 
    ok=0
 
    [ -n "$egl_vendor" ] && ok=1
    [ -n "$egl_version" ] && ok=1
    [ -n "$egl_api_ver" ] && ok=1
 
    if [ "$ok" -eq 0 ] ||
       printf '%s\n' "$parse_out" |
           grep -q \
               '^eglinfo: eglInitialize failed'; then
        log_warn "eglinfo platform '$plat' did not initialize cleanly, rc=$rc"
 
        if [ "${EGLINFO_DEBUG:-0}" = "1" ]; then
            log_info "---- eglinfo output, platform '$plat' ----"
 
            printf '%s\n' "$parse_out"
 
            log_info "---- end eglinfo output ----"
        fi
 
        return 1
    fi
 
    if [ "$rc" -ne 0 ] &&
       [ -n "$platform_out" ]; then
        log_warn "eglinfo returned rc=$rc because another platform probe failed; selected platform '$plat' initialized successfully"
    fi
 
    driver="$(
        egli_get_first \
            "$parse_out" \
            "EGL driver name" \
            "EGL driver" \
            "Driver name" \
            "Driver"
    )"
 
    gl_vendor="$(
        egli_get_first \
            "$parse_out" \
            "GL_VENDOR" \
            "OpenGL ES profile vendor" \
            "OpenGL core profile vendor" \
            "OpenGL compatibility profile vendor" \
            "OpenGL ES profile vendor string" \
            "OpenGL vendor string" \
            "OpenGL ES vendor string"
    )"
 
    gl_renderer="$(
        egli_get_first \
            "$parse_out" \
            "GL_RENDERER" \
            "OpenGL ES profile renderer" \
            "OpenGL core profile renderer" \
            "OpenGL compatibility profile renderer" \
            "OpenGL ES profile renderer string" \
            "OpenGL renderer string" \
            "OpenGL ES renderer string"
    )"
 
    [ -n "$egl_vendor" ] || egl_vendor="unknown"
    [ -n "$egl_version" ] || egl_version="unknown"
    [ -n "$egl_api_ver" ] || egl_api_ver="unknown"
    [ -n "$driver" ] || driver="unknown"
    [ -n "$gl_vendor" ] || gl_vendor="unknown"
    [ -n "$gl_renderer" ] || gl_renderer="unknown"
 
    if [ "$driver" = "unknown" ]; then
        driver="$(
            egli_derive_driver_name \
                "$gl_vendor" \
                "$gl_renderer"
        )"
    fi
 
    pipe_kind="$(
        egli_classify_pipeline \
            "$driver" \
            "$gl_vendor" \
            "$gl_renderer"
    )"
 
    log_info "EGLINFO: Pipeline type: $pipe_kind"
 
    EGLI_LAST_PLATFORM="$plat"
    EGLI_LAST_EGL_VENDOR="$egl_vendor"
    EGLI_LAST_EGL_VERSION="$egl_version"
    EGLI_LAST_EGL_API_VERSION="$egl_api_ver"
    EGLI_LAST_DRIVER="$driver"
    EGLI_LAST_GL_VENDOR="$gl_vendor"
    EGLI_LAST_GL_RENDERER="$gl_renderer"
    EGLI_LAST_PIPE_KIND="$pipe_kind"
 
    if [ "${EGLINFO_CACHE_OUTPUT:-0}" = "1" ]; then
        EGLI_LAST_OUT="$parse_out"
    else
        EGLI_LAST_OUT=""
    fi
 
    egli_print_legacy \
        "$plat" \
        "$driver" \
        "$gl_vendor" \
        "$gl_renderer"
 
    return 0
}

display_print_eglinfo_pipeline() {
    # Usage:
    #   display_print_eglinfo_pipeline \
    #       auto|x11|wayland|gbm|device|surfaceless
    #
    # Cache populated by egli_try_one_platform():
    #   EGLI_LAST_PLATFORM
    #   EGLI_LAST_EGL_VENDOR
    #   EGLI_LAST_EGL_VERSION
    #   EGLI_LAST_EGL_API_VERSION
    #   EGLI_LAST_DRIVER
    #   EGLI_LAST_GL_VENDOR
    #   EGLI_LAST_GL_RENDERER
    #   EGLI_LAST_PIPE_KIND
    #   EGLI_LAST_OUT
 
    mode="${1:-auto}"
 
    # Clear every cached field before probing so callers never consume stale
    # data from an earlier platform attempt.
    EGLI_LAST_PLATFORM=""
    EGLI_LAST_EGL_VENDOR=""
    EGLI_LAST_EGL_VERSION=""
    EGLI_LAST_EGL_API_VERSION=""
    EGLI_LAST_DRIVER=""
    EGLI_LAST_GL_VENDOR=""
    EGLI_LAST_GL_RENDERER=""
    EGLI_LAST_PIPE_KIND=""
    EGLI_LAST_OUT=""
 
    EGLINFO="${EGLINFO:-eglinfo}"
 
    if ! command -v "$EGLINFO" >/dev/null 2>&1; then
        log_error "eglinfo not found, EGLINFO=$EGLINFO"
        return 1
    fi
 
    plat_flag="$(
        egli_pick_platform_flag \
            2>/dev/null
    )" || plat_flag=""
 
    log_info "---------------- EGLINFO pipeline detection (select one) ----------------"
 
    case "$mode" in
        auto)
            # Preserve the existing compositor/direct-rendering selection
            # order. X11 tests must request x11 explicitly so auto mode cannot
            # accidentally validate a different display stack.
            if egli_wayland_socket_ok &&
               egli_try_one_platform \
                   wayland \
                   "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            fi
 
            if egli_try_one_platform \
                gbm \
                "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            fi
 
            if egli_try_one_platform \
                device \
                "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            fi
 
            if egli_try_one_platform \
                surfaceless \
                "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            fi
 
            log_warn "No working eglinfo platform found, tried wayland/gbm/device/surfaceless"
            log_info "---------------- End EGLINFO pipeline detection --------------------------"
            return 1
            ;;
 
        x11)
            # X11 is intentionally strict. Do not fall back to GBM, device,
            # surfaceless, or Wayland because that would make an X11 testcase
            # pass without validating X11 EGL.
            if egli_try_one_platform \
                x11 \
                "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            fi
 
            log_warn "Requested X11 EGL platform did not initialize"
            log_info "---------------- End EGLINFO pipeline detection --------------------------"
            return 1
            ;;
 
        wayland|gbm|device|surfaceless)
            if [ "$mode" = "wayland" ] &&
               ! egli_wayland_socket_ok; then
                log_warn "Requested wayland platform, but the WAYLAND_DISPLAY socket is unavailable; trying fallbacks"
            elif egli_try_one_platform \
                "$mode" \
                "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            else
                log_warn "Requested $mode platform did not initialize; trying fallbacks"
            fi
 
            # Preserve the existing fallback policy for non-X11 callers.
            if [ "$mode" != "gbm" ] &&
               egli_try_one_platform \
                   gbm \
                   "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            fi
 
            if [ "$mode" != "device" ] &&
               egli_try_one_platform \
                   device \
                   "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            fi
 
            if [ "$mode" != "surfaceless" ] &&
               egli_try_one_platform \
                   surfaceless \
                   "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            fi
 
            if [ "$mode" != "wayland" ] &&
               egli_wayland_socket_ok &&
               egli_try_one_platform \
                   wayland \
                   "$plat_flag"; then
                log_info "---------------- End EGLINFO pipeline detection --------------------------"
                return 0
            fi
 
            log_warn "No working eglinfo platform found for requested mode $mode or its fallbacks"
            log_info "---------------- End EGLINFO pipeline detection --------------------------"
            return 1
            ;;
 
        *)
            log_warn "Unknown mode '$mode', use auto|x11|wayland|gbm|device|surfaceless; defaulting to auto"
 
            display_print_eglinfo_pipeline \
                auto
 
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
    fps_backend="${DISPLAY_FPS_BACKEND:-auto}"

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
        if command -v display_get_primary_refresh_hz >/dev/null 2>&1; then
            DISPLAY_FPS_DETECTED_HZ="$(display_get_primary_refresh_hz "$fps_backend" 2>/dev/null || true)"
        elif command -v weston_get_primary_refresh_hz >/dev/null 2>&1; then
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
                log_info "FPS policy: mode=detected backend=$fps_backend refresh=${DISPLAY_FPS_DETECTED_HZ}Hz expected=${DISPLAY_FPS_EXPECTED} min_ok=${DISPLAY_FPS_MIN_OK}"
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

    if [ "${DISPLAY_FPS_BACKEND:-auto}" = "x11" ]; then
        log_info "X11 FPS backend selected; keeping the active XRandR mode unchanged"
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

# Parse FPS samples from a weston-simple-egl log.
#
# Supported formats:
#   Weston 14:
#     601 frames in 5 seconds: 120.199997 fps
#
#   Older Weston:
#     601 frames in 5 seconds = 120.199997
#
# The first sample is discarded as warm-up when two or more samples exist.
#
# Exports through shell globals:
#   DISPLAY_FPS_COUNT
#   DISPLAY_FPS_AVG
#   DISPLAY_FPS_MIN
#   DISPLAY_FPS_MAX
#   DISPLAY_FPS_SINGLE_FRAME - single-frame samples. A clock step turns every
#       reporting window into one, so a high count next to a healthy
#       DISPLAY_FPS_MAX means untrustworthy samples, not slow rendering.
#
# Return:
#   0 - one or more usable FPS samples remain after warm-up handling
#   1 - log is missing, unreadable, or contains no usable FPS samples
display_parse_fps_log() {
    dpfl_log_file="$1"
    dpfl_stats=""
 
    DISPLAY_FPS_COUNT=0
    DISPLAY_FPS_AVG="-"
    DISPLAY_FPS_MIN="-"
    DISPLAY_FPS_MAX="-"
    DISPLAY_FPS_SINGLE_FRAME=0
 
    [ -n "$dpfl_log_file" ] || return 1
    [ -r "$dpfl_log_file" ] || return 1
 
    dpfl_stats="$(
        awk '
            {
                value = ""
 
                for (i = 1; i <= NF; i++) {
                    if ($i == "frames" &&
                        i > 1 &&
                        $(i + 1) == "in") {
                        frames = $(i - 1)
                        for (j = i + 2; j <= NF; j++) {
                            # Weston 14:
                            # 601 frames in 5 seconds: 120.199997 fps
                            if ($j ~ /^seconds:$/) {
                                value = $(j + 1)
                                break
                            }
 
                            # Older Weston:
                            # 601 frames in 5 seconds = 120.199997
                            if ($j == "seconds" &&
                                $(j + 1) == "=") {
                                value = $(j + 2)
                                break
                            }
                        }
 
                        break
                    }
                }
 
                if (value ~ /^[0-9]+([.][0-9]+)?$/) {
                    all_n++
                    all_values[all_n] = value + 0.0
                    all_frames[all_n] = (frames ~ /^[0-9]+$/) ? frames + 0 : -1
                }
            }
 
            END {
                if (all_n == 0) {
                    exit 1
                }
 
                # Preserve the existing behavior: discard the first warm-up
                # sample when two or more samples were collected.
                first = (all_n > 1) ? 2 : 1
                count = 0
                sum = 0.0
                single = 0
 
                for (i = first; i <= all_n; i++) {
                    value = all_values[i]
                    count++
                    sum += value

                    if (all_frames[i] >= 0 && all_frames[i] <= 1) {
                        single++
                    }
 
                    if (count == 1 || value < min) {
                        min = value
                    }
 
                    if (count == 1 || value > max) {
                        max = value
                    }
                }
 
                if (count > 0) {
                    printf "n=%d avg=%.6f min=%.6f max=%.6f single=%d\n",
                        count,
                        sum / count,
                        min,
                        max,
                        single
                }
            }
        ' "$dpfl_log_file" 2>/dev/null
    )" || true
 
    [ -n "$dpfl_stats" ] || return 1
 
    DISPLAY_FPS_COUNT="$(
        printf '%s\n' "$dpfl_stats" |
            awk '{ print $1 }' |
            sed 's/^n=//'
    )"
 
    DISPLAY_FPS_AVG="$(
        printf '%s\n' "$dpfl_stats" |
            awk '{ print $2 }' |
            sed 's/^avg=//'
    )"
 
    DISPLAY_FPS_MIN="$(
        printf '%s\n' "$dpfl_stats" |
            awk '{ print $3 }' |
            sed 's/^min=//'
    )"
 
    DISPLAY_FPS_MAX="$(
        printf '%s\n' "$dpfl_stats" |
            awk '{ print $4 }' |
            sed 's/^max=//'
    )"

    DISPLAY_FPS_SINGLE_FRAME="$(
        printf '%s\n' "$dpfl_stats" |
            awk '{ print $5 }' |
            sed 's/^single=//'
    )"

    case "$DISPLAY_FPS_SINGLE_FRAME" in
        ''|*[!0-9]*)
            DISPLAY_FPS_SINGLE_FRAME=0
            ;;
    esac
 
    case "$DISPLAY_FPS_COUNT" in
        ''|*[!0-9]*)
            DISPLAY_FPS_COUNT=0
            DISPLAY_FPS_AVG="-"
            DISPLAY_FPS_MIN="-"
            DISPLAY_FPS_MAX="-"
            DISPLAY_FPS_SINGLE_FRAME=0
            return 1
            ;;
    esac
 
    [ "$DISPLAY_FPS_COUNT" -gt 0 ] 2>/dev/null || return 1
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

# Wait for at least one connected DRM connector to appear.
#
# Hot-plug detection is asynchronous, so a single sysfs read right after boot
# can report "none" on a board that does have a display. Poll instead.
#
# Tunables:
#   DISPLAY_CONNECTOR_WAIT, seconds to wait, default 20
#   DISPLAY_CONNECTOR_POLL, poll interval in seconds, default 2
# Exports:
#   DISPLAY_CONNECTED_SUMMARY, sysfs display summary, or none
#   DISPLAY_CONNECTOR_WAIT_USED, the sanitized wait bound that was applied
# Return:
#   0 when at least one connected display is found
#   1 when the wait expired with no connected display
display_wait_for_connector() {
    dwc_wait="${DISPLAY_CONNECTOR_WAIT:-20}"
    dwc_poll="${DISPLAY_CONNECTOR_POLL:-2}"

    is_unsigned_number "$dwc_wait" || dwc_wait=20
    is_unsigned_number "$dwc_poll" || dwc_poll=2
    [ "$dwc_poll" -gt 0 ] 2>/dev/null || dwc_poll=1

    DISPLAY_CONNECTOR_WAIT_USED="$dwc_wait"
    export DISPLAY_CONNECTOR_WAIT_USED

    DISPLAY_CONNECTED_SUMMARY="none"
    export DISPLAY_CONNECTED_SUMMARY

    command -v display_connected_summary >/dev/null 2>&1 || return 1

    # Connector nodes are created at driver bind, not by hot-plug: with none
    # present there is nothing to wait for, skip immediately.
    set -- /sys/class/drm/card*-*
    if [ ! -e "$1" ]; then
        DISPLAY_CONNECTOR_WAIT_USED=0
        return 1
    fi

    dwc_start="$(get_monotonic_seconds)"
    dwc_waited=0

    while :; do
        DISPLAY_CONNECTED_SUMMARY="$(display_connected_summary 2>/dev/null || true)"
        export DISPLAY_CONNECTED_SUMMARY

        if [ -n "$DISPLAY_CONNECTED_SUMMARY" ] &&
           [ "$DISPLAY_CONNECTED_SUMMARY" != "none" ]; then
            if [ "$dwc_waited" -gt 0 ]; then
                log_info "Connector appeared after ${dwc_waited}s"
            fi
            return 0
        fi

        dwc_waited=$(($(get_monotonic_seconds) - dwc_start))
        [ "$dwc_waited" -lt 0 ] && dwc_waited=0
        [ "$dwc_waited" -ge "$dwc_wait" ] && break

        sleep "$dwc_poll"
    done

    return 1
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

    # Settle first so the snapshots below describe the state the gate acts on;
    # the verdict lands in DISPLAY_CONNECTED_SUMMARY.
    display_wait_for_connector

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

    if [ -z "$DISPLAY_CONNECTED_SUMMARY" ] || [ "$DISPLAY_CONNECTED_SUMMARY" = "none" ]; then
        log_warn "No connected DRM display found after ${DISPLAY_CONNECTOR_WAIT_USED:-20}s, skipping ${ds_testname}"
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

# Prefer the Wayland socket that belongs to the active Weston runtime.
#
# Discovery order:
# 1. Socket owned by the configured systemd weston.service user.
# 2. Socket derived from a live Weston process:
#    - XDG_RUNTIME_DIR from /proc/<pid>/environ
#    - --socket from /proc/<pid>/cmdline
# 3. Existing generic Wayland socket discovery.
#
# This allows a Weston runtime started by one testcase shell to be reused by
# later testcase shells without hardcoding its runtime directory or socket name.
weston_preferred_socket() {
    wps_user=""
    wps_uid=""
    wps_dir=""
    wps_sock=""
    wps_pids=""
    wps_pid=""
    wps_runtime_dir=""
    wps_socket_name=""
    wps_candidate=""

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

    if command -v pgrep >/dev/null 2>&1; then
        wps_pids="$(pgrep -x weston 2>/dev/null || true)"
    else
        wps_pids="$(
            ps -eo pid=,comm= 2>/dev/null |
                awk '$2 == "weston" { print $1 }'
        )"
    fi

    for wps_pid in $wps_pids; do
        [ -r "/proc/$wps_pid/cmdline" ] || continue

        wps_socket_name="$(
            tr '\000' '\n' <"/proc/$wps_pid/cmdline" 2>/dev/null |
                awk '
                    take_socket {
                        print
                        exit
                    }

                    $0 == "--socket" {
                        take_socket = 1
                        next
                    }

                    /^--socket=/ {
                        sub(/^--socket=/, "")
                        print
                        exit
                    }
                '
        )"

        wps_runtime_dir=""

        if [ -r "/proc/$wps_pid/environ" ]; then
            wps_runtime_dir="$(
                tr '\000' '\n' <"/proc/$wps_pid/environ" 2>/dev/null |
                    sed -n 's/^XDG_RUNTIME_DIR=//p' |
                    head -n 1
            )"
        fi

        if [ -n "$wps_socket_name" ]; then
            case "$wps_socket_name" in
                /*)
                    wps_candidate="$wps_socket_name"
                    ;;
                *)
                    if [ -n "$wps_runtime_dir" ]; then
                        wps_candidate="$wps_runtime_dir/$wps_socket_name"
                    else
                        wps_candidate=""
                    fi
                    ;;
            esac

            if [ -n "$wps_candidate" ] &&
               [ -S "$wps_candidate" ]; then
                printf '%s\n' "$wps_candidate"
                return 0
            fi
        fi

        if [ -n "$wps_runtime_dir" ] &&
           [ -d "$wps_runtime_dir" ]; then
            for wps_sock in "$wps_runtime_dir"/wayland-*; do
                if [ -S "$wps_sock" ]; then
                    printf '%s\n' "$wps_sock"
                    return 0
                fi
            done
        fi
    done

    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        discover_wayland_socket_anywhere 2>/dev/null |
            head -n 1
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
    wr_passive_recovered=0

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

    # Passive recovery path:
    #
    # Some base images expose an active weston.socket or /run/wayland-* socket
    # even when weston.service is currently failed and no Weston process is
    # running. A short Wayland client probe can trigger socket activation and
    # recover Weston without requiring ALLOW_RELAUNCH=1.
    #
    # This avoids false failures like:
    # weston.service is in failed state
    # weston.socket is active
    # no weston process found
    #
    # while still failing later if the socket/client probe cannot recover the
    # runtime.
    if [ "$wr_service_failed" -eq 1 ] || ! weston_has_running_process; then
        log_warn "Weston runtime is not fully healthy, attempting passive Wayland socket recovery"

        if command -v weston_adopt_existing_runtime_and_probe >/dev/null 2>&1; then
            if weston_adopt_existing_runtime_and_probe "${wr_testname}: passive-recovery"; then
                log_info "Passive Wayland socket probe succeeded"

                if command -v weston_wait_ready >/dev/null 2>&1; then
                    if ! weston_wait_ready "$wr_wait_secs"; then
                        log_warn "Weston did not report fully ready after passive recovery wait"
                    fi
                fi

                if weston_has_running_process; then
                    wr_need_relaunch=0
                    wr_passive_recovered=1
                fi

                if command -v systemd_service_exists >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
                    if systemd_service_exists weston.service; then
                        if systemctl is-failed --quiet weston.service 2>/dev/null; then
                            wr_service_failed=1
                        else
                            wr_service_failed=0
                        fi
                    fi
                fi
            else
                log_warn "Passive Wayland socket recovery did not recover Weston runtime"
            fi
        else
            log_warn "weston_adopt_existing_runtime_and_probe helper not found, skipping passive recovery"
        fi
    fi

    if [ "$wr_passive_recovered" -eq 1 ]; then
        if command -v weston_log_runtime_snapshot >/dev/null 2>&1; then
            weston_log_runtime_snapshot "${wr_testname}: after-passive-recovery"
        elif command -v wayland_debug_snapshot >/dev/null 2>&1; then
            wayland_debug_snapshot "${wr_testname}: after-passive-recovery"
        fi
    fi

    if [ "$wr_service_failed" -eq 1 ]; then
        if [ "$wr_allow_relaunch" -eq 1 ]; then
            wr_need_relaunch=1
            log_warn "weston.service is in failed state, cleanup and relaunch will be attempted"
        else
            log_warn "weston.service is in failed state, runtime relaunch is disabled"

            if weston_has_running_process && weston_runtime_socket_exists; then
                log_warn "Continuing because Weston process and Wayland socket are usable despite failed systemd state"
                wr_service_failed=0
                wr_need_relaunch=0
            else
                log_fail "weston.service is in failed state and passive runtime recovery did not make Weston usable"
                return 3
            fi
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
                if ! weston_force_primary_1080p60_if_not_60; then
                    log_warn "Primary output pre-configuration failed, continuing with Weston start"
                fi
            fi

            if ! overlay_start_weston_drm; then
                if command -v weston_log_runtime_snapshot >/dev/null 2>&1; then
                    weston_log_runtime_snapshot "${wr_testname}: after-relaunch"
                fi
                log_fail "Weston relaunch attempt failed, overlay_start_weston_drm returned non-zero"
                return 3
            fi

            if command -v weston_wait_ready >/dev/null 2>&1; then
                if ! weston_wait_ready "$wr_wait_secs"; then
                    log_warn "weston_wait_ready did not confirm readiness after overlay_start_weston_drm"
                fi
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

# Ensure Qualcomm graphics package set is available when package recovery is supported.
#
# This helper is intentionally display/graphics specific only for choosing the
# package-set name and temporary Debusine source. Generic package-manager details
# such as apt/rpm/opkg behavior, DKMS header checks, package-set upgrade, and
# source installation are handled by lib_pkg_provider.sh.
#
# Args:
#   $1 - package-set name, default: graphics
#   $2 - Debusine source, default: qli-staging
#   $3 - Debusine suite, default: auto
#
# Return:
#   0 - package-set ready, skipped cleanly, or no mapping for this provider
#   1 - package-set recovery failed
display_ensure_graphics_package_set() {
    graphics_set_name="${1:-graphics}"
    graphics_source="${2:-qli-staging}"
    graphics_suite="${3:-auto}"

    if [ -z "${TOOLS:-}" ] || [ ! -f "$TOOLS/lib_pkg_provider.sh" ]; then
        log_warn "Package provider helper not found; continuing without graphics package recovery"
        return 0
    fi

    # shellcheck disable=SC1091
    . "$TOOLS/lib_pkg_provider.sh"

    # Load provider config first. Otherwise pkg_provider.conf can overwrite
    # caller-provided/default values such as apt_debusine_source.
    pkg_provider_init || true

    old_graphics_source="${PKG_APT_DEBUSINE_SOURCE:-none}"
    old_graphics_suite="${PKG_APT_DEBUSINE_SUITE:-auto}"

    case "$old_graphics_source" in
        ""|none|disabled)
            PKG_APT_DEBUSINE_SOURCE="$graphics_source"
            ;;
    esac

    case "$old_graphics_suite" in
        "")
            PKG_APT_DEBUSINE_SUITE="$graphics_suite"
            ;;
    esac

    # If this helper changed the apt source/suite after a previous package op,
    # force apt update again so the new source becomes visible.
    if [ "${PKG_APT_DEBUSINE_SOURCE:-none}" != "$old_graphics_source" ] ||
       [ "${PKG_APT_DEBUSINE_SUITE:-auto}" != "$old_graphics_suite" ]; then
        rm -f "${PKG_APT_UPDATED_MARK:-/tmp/qcom_testkit_apt_updated}" 2>/dev/null || true
    fi

    pkg_log_info "Graphics package recovery source, source=${PKG_APT_DEBUSINE_SOURCE:-none} suite=${PKG_APT_DEBUSINE_SUITE:-auto} set=${graphics_set_name}"

    pkg_ensure_package_set "$graphics_set_name"
}

###############################################################################
# GLVND EGL vendor selection
###############################################################################

# Select a single GLVND EGL vendor for the current process and its children.
#
# Usage:
#   display_select_egl_vendor mesa
#   display_select_egl_vendor adreno
#   display_select_egl_vendor native
display_select_egl_vendor() {
    dsev_mode="${1:-native}"
    dsev_json=""
    dsev_mesa_json="${DISPLAY_MESA_EGL_VENDOR_JSON:-/usr/share/glvnd/egl_vendor.d/50_mesa.json}"
    dsev_adreno_json="${DISPLAY_ADRENO_EGL_VENDOR_JSON:-/usr/share/glvnd/egl_vendor.d/10_adreno.json}"

    case "$dsev_mode" in
        native)
            unset __EGL_VENDOR_LIBRARY_FILENAMES
            log_info "Using native GLVND EGL vendor discovery"
            return 0
            ;;
        mesa)
            dsev_json="$dsev_mesa_json"
            ;;
        adreno)
            dsev_json="$dsev_adreno_json"
            ;;
        *)
            log_error "Unsupported EGL vendor mode: $dsev_mode"
            return 1
            ;;
    esac

    if [ ! -f "$dsev_json" ] || [ ! -r "$dsev_json" ]; then
        log_error "EGL vendor JSON is unavailable: $dsev_json"
        return 1
    fi

    if ! grep -q '"library_path"[[:space:]]*:' "$dsev_json" 2>/dev/null; then
        log_error "Invalid EGL vendor JSON, library_path missing: $dsev_json"
        return 1
    fi

    __EGL_VENDOR_LIBRARY_FILENAMES="$dsev_json"
    export __EGL_VENDOR_LIBRARY_FILENAMES

    log_info "Selected EGL vendor mode: $dsev_mode"
    log_info "Selected EGL vendor JSON: $__EGL_VENDOR_LIBRARY_FILENAMES"
    return 0
}

###############################################################################
# Display-manager DRM ownership helpers
###############################################################################

# Stop an active display service and record enough state to restore it.
#
# Usage:
#   display_stop_service_for_drm SERVICE DRM_DEVICE STATE_FILE
#
# The state file is created only when this helper actually stops the service.
display_stop_service_for_drm() {
    dssfd_service="${1:-display-manager.service}"
    dssfd_drm_device="${2:-}"
    dssfd_state_file="$3"
    dssfd_wait=0

    [ -n "$dssfd_state_file" ] || return 1
    rm -f "$dssfd_state_file"

    if ! command -v systemctl >/dev/null 2>&1; then
        log_info "Display-manager handling skipped because systemctl is unavailable"
        return 0
    fi

    if ! systemctl is-active --quiet "$dssfd_service"; then
        log_info "No active display manager requires stopping"
        return 0
    fi

    log_info "Stopping display manager to release DRM master: $dssfd_service"

    if [ -n "$dssfd_drm_device" ] &&
       command -v fuser >/dev/null 2>&1; then
        fuser -v "$dssfd_drm_device" 2>&1 |
            while IFS= read -r dssfd_line; do
                [ -n "$dssfd_line" ] || continue
                log_info "[DRM-OWNER] $dssfd_line"
            done
    fi

    printf '%s\n' "$dssfd_service" >"$dssfd_state_file"

    if ! systemctl stop "$dssfd_service"; then
        if systemctl is-active --quiet "$dssfd_service"; then
            rm -f "$dssfd_state_file"
        fi

        log_error "Failed to stop display manager: $dssfd_service"
        return 1
    fi

    while [ "$dssfd_wait" -lt 10 ]; do
        if ! systemctl is-active --quiet "$dssfd_service"; then
            break
        fi

        sleep 1
        dssfd_wait=$((dssfd_wait + 1))
    done

    if systemctl is-active --quiet "$dssfd_service"; then
        rm -f "$dssfd_state_file"
        log_error "Display manager is still active after stop: $dssfd_service"
        return 1
    fi

    if [ -n "$dssfd_drm_device" ] &&
       command -v fuser >/dev/null 2>&1; then
        dssfd_wait=0

        while [ "$dssfd_wait" -lt 5 ]; do
            if ! fuser "$dssfd_drm_device" >/dev/null 2>&1; then
                break
            fi

            sleep 1
            dssfd_wait=$((dssfd_wait + 1))
        done

        if fuser "$dssfd_drm_device" >/dev/null 2>&1; then
            log_warn "DRM device still has open users after stopping display manager: $dssfd_drm_device"

            fuser -v "$dssfd_drm_device" 2>&1 |
                while IFS= read -r dssfd_line; do
                    [ -n "$dssfd_line" ] || continue
                    log_info "[DRM-OWNER] $dssfd_line"
                done
        fi
    fi

    log_pass "Display manager stopped; DRM master is available for validation"
    return 0
}

# Restore a display service previously stopped by display_stop_service_for_drm.
display_restore_service_from_state() {
    drsfs_state_file="$1"
    drsfs_service=""

    [ -n "$drsfs_state_file" ] || return 0
    [ -s "$drsfs_state_file" ] || return 0

    drsfs_service="$(sed -n '1p' "$drsfs_state_file" 2>/dev/null || true)"
    [ -n "$drsfs_service" ] || return 0

    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "Cannot restore display manager because systemctl is unavailable"
        return 1
    fi

    if systemctl is-active --quiet "$drsfs_service"; then
        rm -f "$drsfs_state_file"
        log_info "Display manager is already active: $drsfs_service"
        return 0
    fi

    log_info "Restoring display manager: $drsfs_service"

    if ! systemctl start "$drsfs_service" >/dev/null 2>&1; then
        log_error "Failed to restore display manager: $drsfs_service"
        return 1
    fi

    rm -f "$drsfs_state_file"
    log_pass "Display manager restored: $drsfs_service"
    return 0
}

###############################################################################
# X11 runtime, output, GLX, and XVideo helpers
###############################################################################
# These helpers extend lib_display.sh. They discover the currently usable X11
# runtime from live server processes and sockets instead of assuming :0, a
# LightDM path, a user ID, a connector name, a mode, or a refresh rate.

DISPLAY_X11_DISPLAY=""
DISPLAY_X11_XAUTHORITY=""
DISPLAY_X11_SERVER_PID=""
DISPLAY_X11_SERVER_COMMAND=""
DISPLAY_X11_SESSION_KIND="unknown"
DISPLAY_X11_OUTPUT=""
DISPLAY_X11_MODE=""
DISPLAY_X11_REFRESH_HZ=""
DISPLAY_X11_ROOT_WIDTH=""
DISPLAY_X11_ROOT_HEIGHT=""
DISPLAY_X11_ROOT_DEPTH=""
DISPLAY_X11_ROOT_MAP_STATE=""

DISPLAY_GLX_DIRECT=""
DISPLAY_GLX_ACCELERATED=""
DISPLAY_GLX_VENDOR=""
DISPLAY_GLX_RENDERER=""
DISPLAY_GLX_VERSION=""
DISPLAY_GLX_PIPE_KIND=""
DISPLAY_GLX_OUT=""

# display_x11_connection_ok [display] [xauthority]
# Verify that xdpyinfo can connect to the supplied or currently exported X11
# display. When an authority file is supplied, it must be readable and is used
# only for this probe.
# Returns: 0 when the connection succeeds; 1 otherwise.
display_x11_connection_ok() {
    dxco_display="${1:-${DISPLAY:-}}"
    dxco_authority="${2:-${XAUTHORITY:-}}"

    [ -n "$dxco_display" ] || return 1
    command -v xdpyinfo >/dev/null 2>&1 || return 1

    if [ -n "$dxco_authority" ]; then
        [ -r "$dxco_authority" ] || return 1
        DISPLAY="$dxco_display" \
        XAUTHORITY="$dxco_authority" \
        LC_ALL=C \
            xdpyinfo -display "$dxco_display" >/dev/null 2>&1
        return $?
    fi

    (
        unset XAUTHORITY
        DISPLAY="$dxco_display" \
        LC_ALL=C \
            xdpyinfo -display "$dxco_display" >/dev/null 2>&1
    )
}

# display_x11_server_pids
# Print unique PIDs for live Xorg, X, and Xwayland server processes. pgrep is
# used when available and ps provides a portable fallback.
# Returns: 0 after emitting zero or more PIDs.
display_x11_server_pids() {
    {
        if command -v pgrep >/dev/null 2>&1; then
            for dxsp_name in Xorg X Xwayland; do
                pgrep -x "$dxsp_name" 2>/dev/null || true
            done
        fi

        ps -eo pid=,comm= 2>/dev/null |
            awk '$2 == "Xorg" || $2 == "X" || $2 == "Xwayland" { print $1 }'
    } | awk 'NF && !seen[$1]++ { print $1 }'

    return 0
}

# display_x11_process_display <pid>
# Extract the first command-line argument that looks like an X11 display name
# such as :0 or :0.0 from one server process.
# Returns: 0 when a display is printed; 1 when it cannot be determined.
display_x11_process_display() {
    dxpd_pid="${1:-}"

    [ -n "$dxpd_pid" ] || return 1
    [ -r "/proc/$dxpd_pid/cmdline" ] || return 1

    tr '\000' '\n' <"/proc/$dxpd_pid/cmdline" 2>/dev/null |
        awk '/^:[0-9]+([.][0-9]+)?$/ { print; exit }'
}

# display_x11_process_env_value <pid> <name>
# Read one environment variable from /proc/<pid>/environ and print its first
# value without modifying the caller's environment.
# Returns: 0 when a value is printed; 1 when the process environment is not
# readable or the variable is absent.
display_x11_process_env_value() {
    dxpev_pid="${1:-}"
    dxpev_name="${2:-}"

    [ -n "$dxpev_pid" ] || return 1
    [ -n "$dxpev_name" ] || return 1
    [ -r "/proc/$dxpev_pid/environ" ] || return 1

    tr '\000' '\n' <"/proc/$dxpev_pid/environ" 2>/dev/null |
        sed -n "s/^${dxpev_name}=//p" |
        head -n 1
}

# display_x11_process_authority <pid>
# Discover an Xauthority path from an X server's -auth command-line argument,
# falling back to the process XAUTHORITY environment variable.
# Returns: 0 and prints a non-empty path when found; 1 otherwise.
display_x11_process_authority() {
    dxpa_pid="${1:-}"

    [ -n "$dxpa_pid" ] || return 1

    dxpa_authority=""

    if [ -r "/proc/$dxpa_pid/cmdline" ]; then
        dxpa_authority="$(
            tr '\000' '\n' <"/proc/$dxpa_pid/cmdline" 2>/dev/null |
                awk '
                    take_next { print; exit }
                    $0 == "-auth" { take_next=1 }
                '
        )"
    fi

    if [ -z "$dxpa_authority" ]; then
        dxpa_authority="$(
            display_x11_process_env_value "$dxpa_pid" XAUTHORITY 2>/dev/null || true
        )"
    fi

    [ -n "$dxpa_authority" ] || return 1
    printf '%s\n' "$dxpa_authority"
}

# display_x11_find_authority_for_display <display>
# Search readable process environments for a process using the requested
# DISPLAY and print the first readable XAUTHORITY path associated with it.
# Returns: 0 when a readable authority file is printed; 1 otherwise.
display_x11_find_authority_for_display() {
    dxfafd_display="${1:-}"

    [ -n "$dxfafd_display" ] || return 1

    for dxfafd_env in /proc/[0-9]*/environ; do
        [ -r "$dxfafd_env" ] || continue

        dxfafd_pid=${dxfafd_env#/proc/}
        dxfafd_pid=${dxfafd_pid%/environ}
        dxfafd_proc_display="$(
            display_x11_process_env_value "$dxfafd_pid" DISPLAY 2>/dev/null || true
        )"

        [ "$dxfafd_proc_display" = "$dxfafd_display" ] || continue

        dxfafd_authority="$(
            display_x11_process_env_value "$dxfafd_pid" XAUTHORITY 2>/dev/null || true
        )"

        if [ -n "$dxfafd_authority" ] && [ -r "$dxfafd_authority" ]; then
            printf '%s\n' "$dxfafd_authority"
            return 0
        fi
    done

    return 1
}

# display_x11_process_on_display <process-name> <display>
# Return success when an exact process name has at least one process whose
# DISPLAY environment matches the requested X11 display.
# Returns: 0 on a match; 1 when no matching process is found.
display_x11_process_on_display() {
    dxpod_name="${1:-}"
    dxpod_display="${2:-}"

    [ -n "$dxpod_name" ] || return 1
    [ -n "$dxpod_display" ] || return 1
    command -v pgrep >/dev/null 2>&1 || return 1

    for dxpod_pid in $(pgrep -x "$dxpod_name" 2>/dev/null || true); do
        dxpod_process_display="$(
            display_x11_process_env_value "$dxpod_pid" DISPLAY 2>/dev/null || true
        )"

        if [ "$dxpod_process_display" = "$dxpod_display" ]; then
            return 0
        fi
    done

    return 1
}

# display_x11_detect_session_kind
# Classify the adopted X11 session as generic x11, xfce, or lightdm-greeter by
# inspecting the active window manager and session processes.
# Sets and exports DISPLAY_X11_SESSION_KIND and prints the detected value.
# Returns: 0 after classification.
display_x11_detect_session_kind() {
    DISPLAY_X11_SESSION_KIND="x11"

    if command -v xprop >/dev/null 2>&1; then
        dxsk_wm_id="$({
            LC_ALL=C xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null || true
        } |
            sed -n 's/.*#[[:space:]]*\(0x[0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' |
            head -n 1)"

        if [ -n "$dxsk_wm_id" ]; then
            dxsk_wm_name="$({
                LC_ALL=C xprop -id "$dxsk_wm_id" _NET_WM_NAME WM_NAME 2>/dev/null || true
            } |
                sed -n 's/.*=[[:space:]]*"\(.*\)".*/\1/p' |
                head -n 1)"

            case "$(printf '%s\n' "$dxsk_wm_name" | tr '[:upper:]' '[:lower:]')" in
                *xfwm*) DISPLAY_X11_SESSION_KIND="xfce" ;;
            esac
        fi
    fi

    if [ "$DISPLAY_X11_SESSION_KIND" != "xfce" ]; then
        dxsk_display="${DISPLAY:-${DISPLAY_X11_DISPLAY:-}}"

        if display_x11_process_on_display xfce4-session "$dxsk_display" ||
           display_x11_process_on_display xfwm4 "$dxsk_display"; then
            DISPLAY_X11_SESSION_KIND="xfce"
        elif display_x11_process_on_display lightdm-gtk-greeter "$dxsk_display"; then
            DISPLAY_X11_SESSION_KIND="lightdm-greeter"
        fi
    fi

    export DISPLAY_X11_SESSION_KIND
    printf '%s\n' "$DISPLAY_X11_SESSION_KIND"
    return 0
}

# display_x11_adopt_candidate <display> [xauthority] [server-pid]
# Validate one DISPLAY/XAUTHORITY candidate, export it for subsequent helpers,
# capture optional server metadata, and classify the session.
# Returns: 0 when the candidate is usable and adopted; 1 otherwise.
display_x11_adopt_candidate() {
    dxac_display="${1:-}"
    dxac_authority="${2:-}"
    dxac_pid="${3:-}"

    [ -n "$dxac_display" ] || return 1

    if [ -n "$dxac_authority" ] &&
       display_x11_connection_ok "$dxac_display" "$dxac_authority"; then
        DISPLAY="$dxac_display"
        XAUTHORITY="$dxac_authority"
        export DISPLAY XAUTHORITY
    elif display_x11_connection_ok "$dxac_display" ""; then
        DISPLAY="$dxac_display"
        export DISPLAY
        unset XAUTHORITY
        dxac_authority=""
    else
        return 1
    fi

    DISPLAY_X11_DISPLAY="$dxac_display"
    DISPLAY_X11_XAUTHORITY="$dxac_authority"
    DISPLAY_X11_SERVER_PID="$dxac_pid"
    DISPLAY_X11_SERVER_COMMAND=""

    if [ -n "$dxac_pid" ] && [ -r "/proc/$dxac_pid/cmdline" ]; then
        DISPLAY_X11_SERVER_COMMAND="$(
            tr '\000' ' ' <"/proc/$dxac_pid/cmdline" 2>/dev/null
        )"
    fi

    export DISPLAY_X11_DISPLAY
    export DISPLAY_X11_XAUTHORITY
    export DISPLAY_X11_SERVER_PID
    export DISPLAY_X11_SERVER_COMMAND

    display_x11_detect_session_kind >/dev/null 2>&1 || true

    log_info "Adopted X11 runtime: DISPLAY=$DISPLAY XAUTHORITY=${XAUTHORITY:-<unset>} server_pid=${DISPLAY_X11_SERVER_PID:-unknown} session=${DISPLAY_X11_SESSION_KIND:-unknown}"
    return 0
}

# display_x11_resolve_env [display-override] [xauthority-override]
# Resolve and adopt a usable X11 runtime in this order: explicit override,
# current environment, discovered X server processes, then live X11 sockets.
# Returns: 0 after exporting a usable runtime; 1 when none can be discovered.
display_x11_resolve_env() {
    dxre_display_override="${1:-}"
    dxre_authority_override="${2:-}"

    if [ -n "$dxre_display_override" ]; then
        if display_x11_adopt_candidate \
            "$dxre_display_override" \
            "$dxre_authority_override" \
            ""; then
            return 0
        fi

        if [ -n "${XAUTHORITY:-}" ] &&
           [ "$dxre_authority_override" != "$XAUTHORITY" ] &&
           display_x11_adopt_candidate \
               "$dxre_display_override" \
               "$XAUTHORITY" \
               ""; then
            return 0
        fi
    fi

    if [ -n "${DISPLAY:-}" ]; then
        if display_x11_adopt_candidate \
            "$DISPLAY" \
            "${XAUTHORITY:-}" \
            ""; then
            return 0
        fi
    fi

    dxre_pids="$(display_x11_server_pids 2>/dev/null)"

    for dxre_pid in $dxre_pids; do
        dxre_display="$(display_x11_process_display "$dxre_pid" 2>/dev/null || true)"
        dxre_authority="$(display_x11_process_authority "$dxre_pid" 2>/dev/null || true)"

        [ -n "$dxre_display" ] || continue

        if [ -z "$dxre_authority" ]; then
            dxre_authority="$(
                display_x11_find_authority_for_display "$dxre_display" 2>/dev/null || true
            )"
        fi

        if [ -n "$dxre_display_override" ] &&
           [ "$dxre_display" != "$dxre_display_override" ]; then
            continue
        fi

        if [ -n "$dxre_authority_override" ]; then
            dxre_authority="$dxre_authority_override"
        fi

        if display_x11_adopt_candidate \
            "$dxre_display" \
            "$dxre_authority" \
            "$dxre_pid"; then
            return 0
        fi
    done

    for dxre_socket in /tmp/.X11-unix/X*; do
        [ -S "$dxre_socket" ] || continue

        dxre_index=${dxre_socket##*/X}
        case "$dxre_index" in
            ''|*[!0-9]*) continue ;;
        esac

        dxre_display=":$dxre_index"

        if [ -n "$dxre_display_override" ] &&
           [ "$dxre_display" != "$dxre_display_override" ]; then
            continue
        fi

        dxre_socket_authority="$dxre_authority_override"
        if [ -z "$dxre_socket_authority" ]; then
            dxre_socket_authority="$(
                display_x11_find_authority_for_display "$dxre_display" 2>/dev/null || true
            )"
        fi

        if display_x11_adopt_candidate \
            "$dxre_display" \
            "$dxre_socket_authority" \
            ""; then
            return 0
        fi
    done

    log_warn "No usable X11 display and Xauthority pair was discovered"
    return 1
}

# display_x11_get_active_output
# Discover the active XRandR output, current mode, and refresh rate. A primary
# output is preferred; otherwise the first connected output with an active mode
# is selected.
# Sets and exports DISPLAY_X11_OUTPUT, DISPLAY_X11_MODE, and
# DISPLAY_X11_REFRESH_HZ.
# Returns: 0 when a valid active output is found; 1 otherwise.
display_x11_get_active_output() {
    command -v xrandr >/dev/null 2>&1 || return 1
    display_x11_connection_ok || return 1

    dxao_record="$(LC_ALL=C xrandr --current 2>/dev/null |
        awk '
            function clean_hz(value) {
                gsub(/[+*i]/, "", value)
                return value
            }

            $2 == "connected" {
                in_output=1
                output_name=$1
                output_primary=0

                for (i=3; i<=NF; i++) {
                    if ($i == "primary") {
                        output_primary=1
                    }
                }
                next
            }

            $2 == "disconnected" {
                in_output=0
                next
            }

            in_output && $1 ~ /^[0-9]+x[0-9]+$/ {
                for (i=2; i<=NF; i++) {
                    if (index($i, "*") > 0) {
                        hz=clean_hz($i)
                        record=output_name "|" $1 "|" hz

                        if (output_primary) {
                            print record
                            emitted=1
                            exit
                        }

                        if (first_record == "") {
                            first_record=record
                        }
                    }
                }
            }

            END {
                if (!emitted && first_record != "") {
                    print first_record
                }
            }
        ' | head -n 1)"

    [ -n "$dxao_record" ] || return 1

    DISPLAY_X11_OUTPUT="$(printf '%s\n' "$dxao_record" | awk -F'|' '{print $1}')"
    DISPLAY_X11_MODE="$(printf '%s\n' "$dxao_record" | awk -F'|' '{print $2}')"
    DISPLAY_X11_REFRESH_HZ="$(printf '%s\n' "$dxao_record" | awk -F'|' '{print $3}')"

    case "$DISPLAY_X11_MODE" in
        *x*) ;;
        *) return 1 ;;
    esac

    case "$DISPLAY_X11_REFRESH_HZ" in
        ''|*[!0-9.]*) return 1 ;;
    esac

    export DISPLAY_X11_OUTPUT
    export DISPLAY_X11_MODE
    export DISPLAY_X11_REFRESH_HZ
    return 0
}

# display_x11_get_primary_refresh_hz
# Print the refresh rate selected by display_x11_get_active_output.
# Returns: 0 when a refresh rate is printed; 1 when no active output is found.
display_x11_get_primary_refresh_hz() {
    if ! display_x11_get_active_output; then
        return 1
    fi

    printf '%s\n' "$DISPLAY_X11_REFRESH_HZ"
}

# display_x11_get_root_geometry
# Query the X11 root window and capture its width, height, depth, and map state.
# Sets and exports DISPLAY_X11_ROOT_WIDTH, DISPLAY_X11_ROOT_HEIGHT,
# DISPLAY_X11_ROOT_DEPTH, and DISPLAY_X11_ROOT_MAP_STATE.
# Returns: 0 when numeric root geometry is available; 1 otherwise.
display_x11_get_root_geometry() {
    command -v xwininfo >/dev/null 2>&1 || return 1
    display_x11_connection_ok || return 1

    dxrg_out="$(LC_ALL=C xwininfo -root 2>/dev/null)" || return 1

    DISPLAY_X11_ROOT_WIDTH="$(printf '%s\n' "$dxrg_out" |
        sed -n 's/^[[:space:]]*Width:[[:space:]]*//p' |
        head -n 1)"
    DISPLAY_X11_ROOT_HEIGHT="$(printf '%s\n' "$dxrg_out" |
        sed -n 's/^[[:space:]]*Height:[[:space:]]*//p' |
        head -n 1)"
    DISPLAY_X11_ROOT_DEPTH="$(printf '%s\n' "$dxrg_out" |
        sed -n 's/^[[:space:]]*Depth:[[:space:]]*//p' |
        head -n 1)"
    DISPLAY_X11_ROOT_MAP_STATE="$(printf '%s\n' "$dxrg_out" |
        sed -n 's/^[[:space:]]*Map State:[[:space:]]*//p' |
        head -n 1)"

    case "$DISPLAY_X11_ROOT_WIDTH:$DISPLAY_X11_ROOT_HEIGHT" in
        *[!0-9:]*|:*|*:) return 1 ;;
    esac

    export DISPLAY_X11_ROOT_WIDTH
    export DISPLAY_X11_ROOT_HEIGHT
    export DISPLAY_X11_ROOT_DEPTH
    export DISPLAY_X11_ROOT_MAP_STATE
    return 0
}

# display_x11_print_glx_pipeline
# Run glxinfo -B, parse the direct-rendering and renderer details, classify the
# pipeline as hardware or software, export the parsed fields, and print the raw
# glxinfo output.
# Returns: 0 when a renderer is reported; 1 when glxinfo or the X11 connection
# is unavailable or glxinfo fails.
display_x11_print_glx_pipeline() {
    DISPLAY_GLX_DIRECT=""
    DISPLAY_GLX_ACCELERATED=""
    DISPLAY_GLX_VENDOR=""
    DISPLAY_GLX_RENDERER=""
    DISPLAY_GLX_VERSION=""
    DISPLAY_GLX_PIPE_KIND=""
    DISPLAY_GLX_OUT=""

    command -v glxinfo >/dev/null 2>&1 || return 1
    display_x11_connection_ok || return 1

    dxpg_out="$(LC_ALL=C glxinfo -B 2>&1)"
    dxpg_rc=$?

    if [ "$dxpg_rc" -ne 0 ]; then
        printf '%s\n' "$dxpg_out"
        return 1
    fi

    DISPLAY_GLX_DIRECT="$(printf '%s\n' "$dxpg_out" |
        sed -n 's/^direct rendering:[[:space:]]*//p' |
        head -n 1)"
    DISPLAY_GLX_ACCELERATED="$(printf '%s\n' "$dxpg_out" |
        sed -n 's/^[[:space:]]*Accelerated:[[:space:]]*//p' |
        head -n 1)"
    DISPLAY_GLX_VENDOR="$(printf '%s\n' "$dxpg_out" |
        sed -n 's/^OpenGL vendor string:[[:space:]]*//p' |
        head -n 1)"
    DISPLAY_GLX_RENDERER="$(printf '%s\n' "$dxpg_out" |
        sed -n 's/^OpenGL renderer string:[[:space:]]*//p' |
        head -n 1)"
    DISPLAY_GLX_VERSION="$(printf '%s\n' "$dxpg_out" |
        sed -n \
            -e 's/^OpenGL core profile version string:[[:space:]]*//p' \
            -e 's/^OpenGL version string:[[:space:]]*//p' |
        head -n 1)"

    [ -n "$DISPLAY_GLX_VENDOR" ] || DISPLAY_GLX_VENDOR="unknown"
    [ -n "$DISPLAY_GLX_RENDERER" ] || DISPLAY_GLX_RENDERER="unknown"
    [ -n "$DISPLAY_GLX_VERSION" ] || DISPLAY_GLX_VERSION="unknown"

    if command -v egli_classify_pipeline >/dev/null 2>&1; then
        DISPLAY_GLX_PIPE_KIND="$(egli_classify_pipeline \
            "" \
            "$DISPLAY_GLX_VENDOR" \
            "$DISPLAY_GLX_RENDERER")"
    else
        case "$(printf '%s\n' "$DISPLAY_GLX_RENDERER" | tr '[:upper:]' '[:lower:]')" in
            *llvmpipe*|*softpipe*|*swrast*|*software*)
                DISPLAY_GLX_PIPE_KIND="CPU (software)"
                ;;
            unknown|"")
                DISPLAY_GLX_PIPE_KIND="unknown"
                ;;
            *)
                DISPLAY_GLX_PIPE_KIND="GPU (hardware)"
                ;;
        esac
    fi

    [ -n "$DISPLAY_GLX_PIPE_KIND" ] || DISPLAY_GLX_PIPE_KIND="unknown"
    DISPLAY_GLX_OUT="$dxpg_out"

    export DISPLAY_GLX_DIRECT
    export DISPLAY_GLX_ACCELERATED
    export DISPLAY_GLX_VENDOR
    export DISPLAY_GLX_RENDERER
    export DISPLAY_GLX_VERSION
    export DISPLAY_GLX_PIPE_KIND
    export DISPLAY_GLX_OUT

    printf '%s\n' "$dxpg_out"
    log_info "GLXINFO: direct=${DISPLAY_GLX_DIRECT:-unknown} accelerated=${DISPLAY_GLX_ACCELERATED:-unknown}"
    log_info "GLXINFO: vendor=$DISPLAY_GLX_VENDOR"
    log_info "GLXINFO: renderer=$DISPLAY_GLX_RENDERER"
    log_info "GLXINFO: version=$DISPLAY_GLX_VERSION"
    log_info "GLXINFO: pipeline type=$DISPLAY_GLX_PIPE_KIND"

    [ "$DISPLAY_GLX_RENDERER" != "unknown" ]
}

###############################################################################
# X11 fullscreen helpers
###############################################################################
# These helpers are shared by X11 clients that do not provide a reliable native
# fullscreen option. Window discovery compares exact before/after snapshots so
# an existing root, greeter, panel, or desktop window is not selected.

DISPLAY_X11_FULLSCREEN_WATCH_PID=""
DISPLAY_X11_FULLSCREEN_STATUS_FILE=""
DISPLAY_X11_FULLSCREEN_STOP_FILE=""
DISPLAY_X11_FULLSCREEN_RESULT=""
DISPLAY_X11_FULLSCREEN_WINDOW_ID=""
DISPLAY_X11_FULLSCREEN_DETAIL=""
DISPLAY_X11_FULLSCREEN_AVAILABLE=0
DISPLAY_X11_FULLSCREEN_HAVE_WMCTRL=0

# display_x11__snapshot_visible_windows <output-file>
# Save the unique IDs of all currently visible X11 windows to the supplied file.
# Returns: 0 when the snapshot file is created; 1 when it cannot be created.
display_x11__snapshot_visible_windows() {
    dxsvw_file="${1:-}"

    [ -n "$dxsvw_file" ] || return 1
    : >"$dxsvw_file" || return 1

    xdotool search \
        --onlyvisible \
        --name '.*' \
        2>/dev/null |
        awk '/^[0-9]+$/ && !seen[$1]++ { print $1 }' \
        >"$dxsvw_file" ||
        true

    return 0
}

# display_x11__snapshot_command_pids <command> <output-file>
# Save the PIDs whose process comm exactly matches the requested command. A path
# is normalized to its basename before matching.
# Returns: 0 when the snapshot file is created; 1 when it cannot be created.
display_x11__snapshot_command_pids() {
    dxscp_command="${1:-}"
    dxscp_file="${2:-}"

    [ -n "$dxscp_file" ] || return 1
    : >"$dxscp_file" || return 1

    [ -n "$dxscp_command" ] || return 0
    dxscp_command=${dxscp_command##*/}

    ps -eo pid=,comm= 2>/dev/null |
        awk -v command="$dxscp_command" '
            $2 == command {
                print $1
            }
        ' >"$dxscp_file" ||
        true

    return 0
}

# display_x11__window_is_viewable <window-id>
# Return success when xwininfo reports that the requested X11 window is mapped
# and viewable.
# Returns: 0 for a viewable window; 1 otherwise.
display_x11__window_is_viewable() {
    dxwiv_id="${1:-}"

    [ -n "$dxwiv_id" ] || return 1

    LC_ALL=C xwininfo \
        -id "$dxwiv_id" \
        2>/dev/null |
        grep -q 'Map State:[[:space:]]*IsViewable'
}

# display_x11__find_new_window <command> <before-windows> <before-pids>
#                              <after-windows> <after-pids>
# Find a newly created viewable window. New PIDs matching the client command are
# preferred; a before/after visible-window comparison is used as fallback.
# Sets and exports DISPLAY_X11_FULLSCREEN_WINDOW_ID.
# Returns: 0 when a new viewable window is found; 1 otherwise.
display_x11__find_new_window() {
    dxfnw_command="${1:-}"
    dxfnw_before_windows="${2:-}"
    dxfnw_before_pids="${3:-}"
    dxfnw_after_windows="${4:-}"
    dxfnw_after_pids="${5:-}"

    DISPLAY_X11_FULLSCREEN_WINDOW_ID=""

    display_x11__snapshot_command_pids \
        "$dxfnw_command" \
        "$dxfnw_after_pids"

    if [ -n "$dxfnw_command" ]; then
        while IFS= read -r dxfnw_pid; do
            [ -n "$dxfnw_pid" ] || continue

            if grep -Fqx \
                "$dxfnw_pid" \
                "$dxfnw_before_pids" \
                2>/dev/null; then
                continue
            fi

            dxfnw_id="$({
                xdotool search \
                    --onlyvisible \
                    --pid "$dxfnw_pid" \
                    2>/dev/null ||
                    true
            } | head -n 1)"

            if display_x11__window_is_viewable "$dxfnw_id"; then
                DISPLAY_X11_FULLSCREEN_WINDOW_ID="$dxfnw_id"
                export DISPLAY_X11_FULLSCREEN_WINDOW_ID
                return 0
            fi
        done <"$dxfnw_after_pids"
    fi

    display_x11__snapshot_visible_windows "$dxfnw_after_windows"

    while IFS= read -r dxfnw_id; do
        [ -n "$dxfnw_id" ] || continue

        if grep -Fqx \
            "$dxfnw_id" \
            "$dxfnw_before_windows" \
            2>/dev/null; then
            continue
        fi

        if display_x11__window_is_viewable "$dxfnw_id"; then
            DISPLAY_X11_FULLSCREEN_WINDOW_ID="$dxfnw_id"
            export DISPLAY_X11_FULLSCREEN_WINDOW_ID
            return 0
        fi
    done <"$dxfnw_after_windows"

    return 1
}

# display_x11__recover_command <command>
# Recover one missing X11 command through the common command-to-package map.
# The package-provider library is sourced lazily when needed, and the configured
# dependency-recovery policy is respected.
# Returns: 0 when the command is available before or after recovery; 1 otherwise.
display_x11__recover_command() {
    dxrc_command="${1:-}"

    [ -n "$dxrc_command" ] || return 1

    if command -v "$dxrc_command" >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v pkg_ensure_command >/dev/null 2>&1; then
        if [ -n "${TOOLS:-}" ] && [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
            # shellcheck disable=SC1091
            . "$TOOLS/lib_pkg_provider.sh"
        fi
    fi

    if ! command -v pkg_ensure_command >/dev/null 2>&1; then
        return 1
    fi

    if command -v pkg_check_dependencies_recover_enabled >/dev/null 2>&1 &&
       ! pkg_check_dependencies_recover_enabled; then
        return 1
    fi

    if ! pkg_ensure_command "$dxrc_command"; then
        return 1
    fi

    hash -r 2>/dev/null || true
    command -v "$dxrc_command" >/dev/null 2>&1
}

# display_x11_prepare_fullscreen_support
# Prepare the optional shared fullscreen watcher when X11_FULLSCREEN=1.
# xdotool and xwininfo are required and are recovered individually through the
# command map. wmctrl is recovered best-effort and enables an EWMH fullscreen
# request in addition to the geometry fallback.
# Sets and exports DISPLAY_X11_FULLSCREEN_AVAILABLE and
# DISPLAY_X11_FULLSCREEN_HAVE_WMCTRL.
# Returns: 0 when fullscreen is disabled or support is ready; 1 when enabled but
# required commands remain unavailable.
display_x11_prepare_fullscreen_support() {
    DISPLAY_X11_FULLSCREEN_AVAILABLE=0
    DISPLAY_X11_FULLSCREEN_HAVE_WMCTRL=0

    export DISPLAY_X11_FULLSCREEN_AVAILABLE
    export DISPLAY_X11_FULLSCREEN_HAVE_WMCTRL

    [ "${X11_FULLSCREEN:-0}" = "1" ] || return 0

    display_x11__recover_command xdotool || true
    display_x11__recover_command xwininfo || true

    # Optional EWMH support. Failure does not disable geometry-based fullscreen.
    display_x11__recover_command wmctrl || true

    if command -v wmctrl >/dev/null 2>&1; then
        DISPLAY_X11_FULLSCREEN_HAVE_WMCTRL=1
    fi

    if command -v xdotool >/dev/null 2>&1 &&
       command -v xwininfo >/dev/null 2>&1; then
        DISPLAY_X11_FULLSCREEN_AVAILABLE=1
        export DISPLAY_X11_FULLSCREEN_AVAILABLE
        export DISPLAY_X11_FULLSCREEN_HAVE_WMCTRL

        log_info "X11 fullscreen support ready: xdotool=$(command -v xdotool) xwininfo=$(command -v xwininfo) wmctrl=${DISPLAY_X11_FULLSCREEN_HAVE_WMCTRL}"
        return 0
    fi

    if ! command -v xdotool >/dev/null 2>&1; then
        log_warn "X11 fullscreen support unavailable: xdotool not installed"
    fi

    if ! command -v xwininfo >/dev/null 2>&1; then
        log_warn "X11 fullscreen support unavailable: xwininfo not installed"
    fi

    export DISPLAY_X11_FULLSCREEN_AVAILABLE
    export DISPLAY_X11_FULLSCREEN_HAVE_WMCTRL
    return 1
}

# display_x11__apply_fullscreen_window <window-id> <width> <height>
# Map the selected window, request EWMH fullscreen when wmctrl is available,
# force it to root-window geometry with xdotool, and verify the resulting size.
# Sets and exports DISPLAY_X11_FULLSCREEN_DETAIL.
# Returns: 0 when the measured size matches; 1 otherwise.
display_x11__apply_fullscreen_window() {
    dxafw_id="${1:-}"
    dxafw_width="${2:-}"
    dxafw_height="${3:-}"

    [ -n "$dxafw_id" ] || return 1
    [ -n "$dxafw_width" ] || return 1
    [ -n "$dxafw_height" ] || return 1

    xdotool windowmap \
        "$dxafw_id" \
        >/dev/null 2>&1 ||
        true

    if [ "${DISPLAY_X11_FULLSCREEN_HAVE_WMCTRL:-0}" = "1" ] &&
       command -v wmctrl >/dev/null 2>&1; then
        dxafw_hex="$({
            printf '0x%x\n' "$dxafw_id" 2>/dev/null ||
            true
        } | head -n 1)"

        if [ -n "$dxafw_hex" ]; then
            wmctrl \
                -i \
                -r "$dxafw_hex" \
                -b add,fullscreen \
                >/dev/null 2>&1 ||
                true
        fi
    fi

    xdotool windowmove \
        "$dxafw_id" \
        0 \
        0 \
        >/dev/null 2>&1 ||
        true

    xdotool windowsize \
        "$dxafw_id" \
        "$dxafw_width" \
        "$dxafw_height" \
        >/dev/null 2>&1 ||
        true

    xdotool windowraise \
        "$dxafw_id" \
        >/dev/null 2>&1 ||
        true

    dxafw_actual_width="$({
        LC_ALL=C xwininfo \
            -id "$dxafw_id" \
            2>/dev/null ||
            true
    } | awk '
        /^[[:space:]]*Width:/ {
            print $2
            exit
        }
    ')"

    dxafw_actual_height="$({
        LC_ALL=C xwininfo \
            -id "$dxafw_id" \
            2>/dev/null ||
            true
    } | awk '
        /^[[:space:]]*Height:/ {
            print $2
            exit
        }
    ')"

    DISPLAY_X11_FULLSCREEN_DETAIL="actual=${dxafw_actual_width:-unknown}x${dxafw_actual_height:-unknown}"
    export DISPLAY_X11_FULLSCREEN_DETAIL

    [ "$dxafw_actual_width" = "$dxafw_width" ] &&
    [ "$dxafw_actual_height" = "$dxafw_height" ]
}

# display_x11_fullscreen_watch_start [wait-seconds] [command] [status-file]
# Start a background watcher before launching an X11 client. It snapshots the
# current windows/processes, waits for the new client window, and repeatedly
# applies fullscreen geometry until the client exits or the watcher is stopped.
# Sets and exports watcher PID/status/stop-file globals.
# Returns: 0 when the watcher starts; 1 when fullscreen is disabled, preparation
# fails, the timeout is invalid, or root geometry cannot be resolved.
display_x11_fullscreen_watch_start() {
    dxfw_wait_seconds="${1:-10}"
    dxfw_command="${2:-}"
    dxfw_status_file="${3:-/tmp/display-x11-fullscreen-$$.status}"
    dxfw_stop_file="${dxfw_status_file}.stop"
    dxfw_before_windows="${dxfw_status_file}.before-windows"
    dxfw_before_pids="${dxfw_status_file}.before-pids"
    dxfw_after_windows="${dxfw_status_file}.after-windows"
    dxfw_after_pids="${dxfw_status_file}.after-pids"

    DISPLAY_X11_FULLSCREEN_WATCH_PID=""
    DISPLAY_X11_FULLSCREEN_STATUS_FILE="$dxfw_status_file"
    DISPLAY_X11_FULLSCREEN_STOP_FILE="$dxfw_stop_file"

    export DISPLAY_X11_FULLSCREEN_WATCH_PID
    export DISPLAY_X11_FULLSCREEN_STATUS_FILE
    export DISPLAY_X11_FULLSCREEN_STOP_FILE

    case "$dxfw_wait_seconds" in
        ''|*[!0-9]*|0)
            printf '%s\n' \
                "SKIP|invalid-timeout|$dxfw_wait_seconds" \
                >"$dxfw_status_file"
            return 1
            ;;
    esac

    if [ "${X11_FULLSCREEN:-0}" != "1" ]; then
        printf '%s\n' \
            "SKIP|fullscreen-disabled|" \
            >"$dxfw_status_file"
        return 1
    fi

    if ! display_x11_prepare_fullscreen_support; then
        if ! command -v xdotool >/dev/null 2>&1; then
            dxfw_prepare_reason="xdotool-unavailable"
        elif ! command -v xwininfo >/dev/null 2>&1; then
            dxfw_prepare_reason="xwininfo-unavailable"
        else
            dxfw_prepare_reason="fullscreen-support-unavailable"
        fi

        printf '%s\n' \
            "SKIP|$dxfw_prepare_reason|" \
            >"$dxfw_status_file"
        return 1
    fi

    if ! display_x11_get_root_geometry; then
        printf '%s\n' \
            "SKIP|root-geometry-unavailable|" \
            >"$dxfw_status_file"
        return 1
    fi

    dxfw_root_width="$DISPLAY_X11_ROOT_WIDTH"
    dxfw_root_height="$DISPLAY_X11_ROOT_HEIGHT"

    case "$dxfw_root_width:$dxfw_root_height" in
        *[!0-9:]*|:*|*:)
            printf '%s\n' \
                "SKIP|invalid-root-geometry|${dxfw_root_width}x${dxfw_root_height}" \
                >"$dxfw_status_file"
            return 1
            ;;
    esac

    rm -f \
        "$dxfw_status_file" \
        "$dxfw_stop_file" \
        "$dxfw_before_windows" \
        "$dxfw_before_pids" \
        "$dxfw_after_windows" \
        "$dxfw_after_pids"

    if ! display_x11__snapshot_visible_windows "$dxfw_before_windows"; then
        printf '%s\n' \
            "SKIP|window-snapshot-failed|" \
            >"$dxfw_status_file"
        return 1
    fi

    if ! display_x11__snapshot_command_pids \
        "$dxfw_command" \
        "$dxfw_before_pids"; then
        printf '%s\n' \
            "SKIP|process-snapshot-failed|command=$dxfw_command" \
            >"$dxfw_status_file"
        return 1
    fi

    (
        dxfw_elapsed=0
        dxfw_window_id=""
        dxfw_first_apply_elapsed=""
        dxfw_verified=0

        while [ "$dxfw_elapsed" -lt "$dxfw_wait_seconds" ] &&
              [ ! -e "$dxfw_stop_file" ]; do
            if display_x11__find_new_window \
                "$dxfw_command" \
                "$dxfw_before_windows" \
                "$dxfw_before_pids" \
                "$dxfw_after_windows" \
                "$dxfw_after_pids"; then
                dxfw_window_id="$DISPLAY_X11_FULLSCREEN_WINDOW_ID"
                break
            fi

            sleep 1
            dxfw_elapsed=$((dxfw_elapsed + 1))
        done

        if [ -z "$dxfw_window_id" ]; then
            printf '%s\n' \
                "SKIP|window-not-found|command=$dxfw_command" \
                >"$dxfw_status_file"
            exit 0
        fi

        while [ ! -e "$dxfw_stop_file" ]; do
            if ! display_x11__window_is_viewable "$dxfw_window_id"; then
                break
            fi

            if display_x11__apply_fullscreen_window \
                "$dxfw_window_id" \
                "$dxfw_root_width" \
                "$dxfw_root_height"; then
                dxfw_verified=1

                if [ -z "$dxfw_first_apply_elapsed" ]; then
                    dxfw_first_apply_elapsed="$dxfw_elapsed"
                    printf '%s\n' \
                        "PASS|$dxfw_window_id|geometry=${dxfw_root_width}x${dxfw_root_height};detected_after=${dxfw_first_apply_elapsed}s" \
                        >"$dxfw_status_file"
                fi
            fi

            sleep 1
        done

        if [ "$dxfw_verified" -eq 0 ]; then
            printf '%s\n' \
                "WARN|$dxfw_window_id|${DISPLAY_X11_FULLSCREEN_DETAIL:-geometry-not-verified}" \
                >"$dxfw_status_file"
        fi
    ) &

    DISPLAY_X11_FULLSCREEN_WATCH_PID=$!

    export DISPLAY_X11_FULLSCREEN_WATCH_PID
    export DISPLAY_X11_FULLSCREEN_STATUS_FILE
    export DISPLAY_X11_FULLSCREEN_STOP_FILE

    return 0
}

# display_x11_fullscreen_watch_finish
# Stop and join the active watcher, parse its status file into exported globals,
# remove transient snapshot files, and log the final fullscreen result.
# Returns: 0 for PASS, 1 for WARN, and 2 for SKIP/not applied.
display_x11_fullscreen_watch_finish() {
    dxfwf_status_file="${DISPLAY_X11_FULLSCREEN_STATUS_FILE:-}"
    dxfwf_stop_file="${DISPLAY_X11_FULLSCREEN_STOP_FILE:-}"

    DISPLAY_X11_FULLSCREEN_RESULT="SKIP"
    DISPLAY_X11_FULLSCREEN_WINDOW_ID=""
    DISPLAY_X11_FULLSCREEN_DETAIL="watcher-not-started"

    if [ -n "$dxfwf_stop_file" ]; then
        : >"$dxfwf_stop_file" 2>/dev/null ||
            true
    fi

    if [ -n "${DISPLAY_X11_FULLSCREEN_WATCH_PID:-}" ]; then
        wait \
            "$DISPLAY_X11_FULLSCREEN_WATCH_PID" \
            2>/dev/null ||
            true
    fi

    if [ -n "$dxfwf_status_file" ] && [ -r "$dxfwf_status_file" ]; then
        IFS='|' read -r \
            DISPLAY_X11_FULLSCREEN_RESULT \
            DISPLAY_X11_FULLSCREEN_WINDOW_ID \
            DISPLAY_X11_FULLSCREEN_DETAIL \
            <"$dxfwf_status_file"
    fi

    if [ -n "$dxfwf_status_file" ]; then
        rm -f \
            "$dxfwf_stop_file" \
            "${dxfwf_status_file}.before-windows" \
            "${dxfwf_status_file}.before-pids" \
            "${dxfwf_status_file}.after-windows" \
            "${dxfwf_status_file}.after-pids" \
            2>/dev/null ||
            true
    elif [ -n "$dxfwf_stop_file" ]; then
        rm -f "$dxfwf_stop_file" 2>/dev/null || true
    fi

    DISPLAY_X11_FULLSCREEN_WATCH_PID=""
    DISPLAY_X11_FULLSCREEN_STOP_FILE=""

    export DISPLAY_X11_FULLSCREEN_RESULT
    export DISPLAY_X11_FULLSCREEN_WINDOW_ID
    export DISPLAY_X11_FULLSCREEN_DETAIL
    export DISPLAY_X11_FULLSCREEN_WATCH_PID
    export DISPLAY_X11_FULLSCREEN_STOP_FILE

    case "$DISPLAY_X11_FULLSCREEN_RESULT" in
        PASS)
            log_info "X11 fullscreen applied: window=$DISPLAY_X11_FULLSCREEN_WINDOW_ID $DISPLAY_X11_FULLSCREEN_DETAIL"
            return 0
            ;;
        WARN)
            log_warn "X11 fullscreen could not be fully verified: window=$DISPLAY_X11_FULLSCREEN_WINDOW_ID detail=$DISPLAY_X11_FULLSCREEN_DETAIL"
            return 1
            ;;
        *)
            log_warn "X11 fullscreen was not applied: reason=$DISPLAY_X11_FULLSCREEN_WINDOW_ID detail=$DISPLAY_X11_FULLSCREEN_DETAIL"
            return 2
            ;;
    esac
}

# display_x11_xvideo_available
# Probe xvinfo on the adopted X11 display and return success only when at least
# one XVideo adaptor is reported.
# Returns: 0 when XVideo is usable; 1 otherwise.
display_x11_xvideo_available() {
    command -v xvinfo >/dev/null 2>&1 || return 1
    display_x11_connection_ok || return 1

    dxxv_out="$(LC_ALL=C xvinfo 2>&1)"
    dxxv_rc=$?

    [ "$dxxv_rc" -eq 0 ] || return 1

    if printf '%s\n' "$dxxv_out" |
       grep -Eq 'number of adaptors:[[:space:]]*[1-9][0-9]*|Adaptor #[0-9]+'; then
        return 0
    fi

    return 1
}

# display_get_primary_refresh_hz [auto|x11|wayland|weston]
# Print the primary display refresh rate using the requested backend. Auto mode
# prefers a usable Wayland/Weston runtime, then X11, and finally a direct Weston
# fallback when the helper exists.
# Returns: 0 when a refresh rate is printed; 1 when no backend can provide one.
display_get_primary_refresh_hz() {
    dgpr_backend="${1:-auto}"

    case "$dgpr_backend" in
        x11)
            display_x11_get_primary_refresh_hz
            return $?
            ;;
        wayland|weston)
            if command -v weston_get_primary_refresh_hz >/dev/null 2>&1; then
                weston_get_primary_refresh_hz
                return $?
            fi
            return 1
            ;;
        auto)
            if command -v egli_wayland_socket_ok >/dev/null 2>&1 &&
               egli_wayland_socket_ok >/dev/null 2>&1 &&
               command -v weston_get_primary_refresh_hz >/dev/null 2>&1; then
                if weston_get_primary_refresh_hz; then
                    return 0
                fi
            fi

            if display_x11_connection_ok >/dev/null 2>&1 &&
               command -v xrandr >/dev/null 2>&1; then
                if display_x11_get_primary_refresh_hz; then
                    return 0
                fi
            fi

            if command -v weston_get_primary_refresh_hz >/dev/null 2>&1; then
                weston_get_primary_refresh_hz
                return $?
            fi
            ;;
        *)
            log_warn "Unsupported display refresh backend: $dgpr_backend"
            ;;
    esac

    return 1
}


###############################################################################
# Weston testcase integration helpers
#
# This block is intentionally limited to:
# - minimal Weston package/client recovery on apt systems
# - the already validated base/overlay graphics-stack transitions
# - the existing image-managed Yocto Weston lifecycle
# - testcase FPS policy
#
# It does not create users, TTY sessions, PAM configuration, udev rules,
# systemd units, seatd instances, or standalone Weston processes.
###############################################################################

display_ensure_weston_test_dependencies() {
    dewtd_client="${1:-weston-simple-egl}"
    dewtd_os_id="unknown"
    dewtd_provider="check"
    dewtd_dependencies=""
    dewtd_rc=0
    dewtd_old_check_deps_no_exit="${CHECK_DEPS_NO_EXIT-__unset__}"

    if command -v pkg_detect_os_id >/dev/null 2>&1; then
        dewtd_os_id="$(pkg_detect_os_id 2>/dev/null || true)"
    elif [ -r /etc/os-release ]; then
        dewtd_os_id="$(
            sed -n 's/^ID=//p' /etc/os-release |
                head -n 1 |
                tr -d '"' |
                tr '[:upper:]' '[:lower:]'
        )"
    fi

    [ -n "$dewtd_os_id" ] || dewtd_os_id="unknown"

    if command -v pkg_active_provider >/dev/null 2>&1; then
        dewtd_provider="$(pkg_active_provider 2>/dev/null || true)"
    fi

    [ -n "$dewtd_provider" ] || dewtd_provider="check"

    case "$dewtd_os_id" in
        debian|ubuntu)
            if [ "$dewtd_provider" = "apt" ] &&
               command -v pkg_ensure_required_package_set_present >/dev/null 2>&1; then
                if ! pkg_ensure_required_package_set_present weston-runtime; then
                    log_fail "Failed to ensure the minimal Weston runtime package set"
                    return 1
                fi
            fi

            dewtd_dependencies="$dewtd_client weston"
            ;;

        centos|rhel|fedora)
            # RPM package names vary by release and repository. Keep this path
            # check-only until explicit validated mappings are added.
            dewtd_dependencies="$dewtd_client weston"
            ;;

        *)
            # Preserve Yocto and other image-provided package behavior.
            dewtd_dependencies="$dewtd_client"
            ;;
    esac

    CHECK_DEPS_NO_EXIT=1
    export CHECK_DEPS_NO_EXIT

    if ! check_dependencies "$dewtd_dependencies"; then
        dewtd_rc=1
    fi

    case "$dewtd_old_check_deps_no_exit" in
        __unset__)
            unset CHECK_DEPS_NO_EXIT
            ;;
        *)
            CHECK_DEPS_NO_EXIT="$dewtd_old_check_deps_no_exit"
            export CHECK_DEPS_NO_EXIT
            ;;
    esac

    if [ "$dewtd_rc" -ne 0 ]; then
        log_fail "Required Weston commands are unavailable, os=$dewtd_os_id commands=$dewtd_dependencies"
        return 1
    fi

    log_pass "Weston testcase dependencies are ready, client=$dewtd_client"
    return 0
}


# Return success when the named systemd unit currently exists.
display_desktop_weston_unit_exists() {
    ddwue_unit="${1:-qcom-testkit-weston.service}"
    ddwue_load_state=""

    command -v systemctl >/dev/null 2>&1 || return 1

    ddwue_load_state="$(
        systemctl show "$ddwue_unit" \
            -p LoadState \
            --value 2>/dev/null ||
        true
    )"

    [ -n "$ddwue_load_state" ] &&
        [ "$ddwue_load_state" != "not-found" ]
}

# Return success when the Weston log contains a fatal DRM/KMS startup error.
display_desktop_weston_log_has_fatal_errors() {
    ddwlhfe_log="${1:-}"

    [ -n "$ddwlhfe_log" ] || return 1
    [ -r "$ddwlhfe_log" ] || return 1

    grep -Eiq \
        "atomic: couldn.t commit new state: Permission denied|repaint-flush failed: Permission denied|failed to acquire DRM master|failed to initialize DRM backend|failed to create renderer|failed to open.*DRM" \
        "$ddwlhfe_log"
}

# Adopt and validate one desktop Weston socket.
display_adopt_desktop_weston_socket() {
    dadws_socket="${1:-}"
    dadws_log="${2:-}"

    [ -n "$dadws_socket" ] || return 1
    [ -S "$dadws_socket" ] || return 1

    if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        if ! adopt_wayland_env_from_socket "$dadws_socket"; then
            return 1
        fi
    else
        XDG_RUNTIME_DIR="$(dirname "$dadws_socket")"
        WAYLAND_DISPLAY="$(basename "$dadws_socket")"
        export XDG_RUNTIME_DIR
        export WAYLAND_DISPLAY
    fi

    if command -v wayland_connection_ok >/dev/null 2>&1; then
        if ! wayland_connection_ok; then
            return 1
        fi
    fi

    if [ -n "$dadws_log" ] &&
       display_desktop_weston_log_has_fatal_errors "$dadws_log"; then
        log_error "Weston reports fatal DRM/KMS errors: $dadws_log"
        return 1
    fi

    DISPLAY_WAYLAND_SOCKET="$dadws_socket"
    DISPLAY_RUNTIME_MODEL="desktop-systemd-transient"
    export DISPLAY_WAYLAND_SOCKET
    export DISPLAY_RUNTIME_MODEL

    log_info "Wayland runtime model, $DISPLAY_RUNTIME_MODEL"
    log_info "Wayland socket, $DISPLAY_WAYLAND_SOCKET"
    log_info "XDG_RUNTIME_DIR, ${XDG_RUNTIME_DIR:-<unset>}"
    log_info "WAYLAND_DISPLAY, ${WAYLAND_DISPLAY:-<unset>}"

    return 0
}

# Stop the qcom-testkit transient Weston runtime.
#
# Arguments:
#   $1 - restore display manager: 1=yes, 0=no, default=1
#
# This helper never removes packages or persistent system configuration.
display_stop_transient_weston_runtime() {
    dstwr_restore_dm="${1:-1}"
    dstwr_unit="qcom-testkit-weston.service"
    dstwr_runtime_dir="/run/qcom-testkit-weston"
    dstwr_socket_name="wayland-qcom-testkit"
    dstwr_state_file="$dstwr_runtime_dir/display-manager.state"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$dstwr_unit" >/dev/null 2>&1 || true
        systemctl reset-failed "$dstwr_unit" >/dev/null 2>&1 || true
    fi

    rm -f \
        "$dstwr_runtime_dir/$dstwr_socket_name" \
        "$dstwr_runtime_dir/$dstwr_socket_name.lock" \
        2>/dev/null || true

    if [ "$dstwr_restore_dm" -eq 1 ] 2>/dev/null &&
       command -v display_restore_service_from_state >/dev/null 2>&1; then
        display_restore_service_from_state "$dstwr_state_file" || return 1
    fi

    if [ "$dstwr_restore_dm" -eq 1 ] 2>/dev/null; then
        rm -rf "$dstwr_runtime_dir" 2>/dev/null || true
    fi

    if [ "${DISPLAY_WAYLAND_SOCKET:-}" = "$dstwr_runtime_dir/$dstwr_socket_name" ]; then
        unset DISPLAY_WAYLAND_SOCKET
        unset DISPLAY_RUNTIME_MODEL
        unset WAYLAND_DISPLAY
        unset XDG_RUNTIME_DIR
    fi

    return 0
}

# Start the proven desktop Weston runtime through systemd-run.
#
# The command path intentionally matches the target-validated manual sequence:
# - stop display-manager.service and record whether it was active
# - create a root-owned XDG runtime directory
# - start Weston as a transient system service
# - use Weston/libseat default backend selection
# - do not set LIBSEAT_BACKEND, SEATD_VTBOUND, or a custom seat
#
# Arguments:
#   $1 - testcase/log tag
#   $2 - socket startup timeout in seconds
#
# Return:
#   0 - runtime is ready
#   1 - runtime startup or validation failed
display_start_transient_weston_runtime() {
    dstwr_testname="${1:-display-test}"
    dstwr_wait_secs="${2:-10}"
    dstwr_unit="qcom-testkit-weston.service"
    dstwr_runtime_dir="/run/qcom-testkit-weston"
    dstwr_socket_name="wayland-qcom-testkit"
    dstwr_socket="$dstwr_runtime_dir/$dstwr_socket_name"
    dstwr_log="/tmp/qcom-testkit-weston.log"
    dstwr_state_file="$dstwr_runtime_dir/display-manager.state"
    dstwr_drm_device=""
    dstwr_drm_card=""
    dstwr_egl_json="${__EGL_VENDOR_LIBRARY_FILENAMES:-}"
    dstwr_weston_bin=""
    dstwr_wait=0
    dstwr_started=0

    case "$dstwr_wait_secs" in
        ''|*[!0-9]*)
            dstwr_wait_secs=10
            ;;
    esac

    [ "$dstwr_wait_secs" -gt 0 ] 2>/dev/null || dstwr_wait_secs=10

    for dstwr_command in systemctl systemd-run weston; do
        if ! command -v "$dstwr_command" >/dev/null 2>&1; then
            log_error "Cannot start desktop Weston, required command is unavailable: $dstwr_command"
            return 1
        fi
    done

    dstwr_weston_bin="$(command -v weston 2>/dev/null || true)"

    if [ -z "$dstwr_weston_bin" ]; then
        log_error "Cannot start desktop Weston, weston binary could not be resolved"
        return 1
    fi

    if ! command -v display_select_primary_drm_device >/dev/null 2>&1; then
        log_error "Cannot start desktop Weston, DRM selection helper is unavailable"
        return 1
    fi

    if ! command -v display_stop_service_for_drm >/dev/null 2>&1; then
        log_error "Cannot start desktop Weston, display-manager ownership helper is unavailable"
        return 1
    fi

    dstwr_drm_device="$(
        display_select_primary_drm_device 2>/dev/null ||
        true
    )"

    if [ -z "$dstwr_drm_device" ] || [ ! -c "$dstwr_drm_device" ]; then
        log_error "Cannot start desktop Weston, no usable primary DRM device was selected"
        return 1
    fi

    dstwr_drm_card="${dstwr_drm_device##*/}"

    if ! install -d -m 0700 -o root -g root "$dstwr_runtime_dir"; then
        log_error "Failed to create Weston runtime directory: $dstwr_runtime_dir"
        return 1
    fi

    # Preserve the original display-manager state across an explicit Weston
    # relaunch. The stop helper intentionally recreates its state file, so do
    # not call it again when the manager is already inactive and a valid state
    # file from the initial startup exists.
    if [ -s "$dstwr_state_file" ] &&
       ! systemctl is-active --quiet display-manager.service; then
        log_info "Display manager is already inactive, preserving recorded restore state"
    elif ! display_stop_service_for_drm \
        display-manager.service \
        "$dstwr_drm_device" \
        "$dstwr_state_file"; then
        log_error "Failed to release display-manager DRM ownership"
        return 1
    fi

    if command -v fuser >/dev/null 2>&1 &&
       fuser "$dstwr_drm_device" >/dev/null 2>&1; then
        log_error "DRM device is still in use after stopping the display manager: $dstwr_drm_device"
        fuser -v "$dstwr_drm_device" 2>&1 |
            while IFS= read -r dstwr_owner_line; do
                [ -n "$dstwr_owner_line" ] || continue
                log_info "[DRM-OWNER] $dstwr_owner_line"
            done
        display_restore_service_from_state "$dstwr_state_file" || true
        return 1
    fi

    rm -f \
        "$dstwr_socket" \
        "$dstwr_socket.lock" \
        "$dstwr_log"

    log_info "Starting transient desktop Weston through systemd-run"
    log_info "Weston unit, $dstwr_unit"
    log_info "Weston DRM device, $dstwr_drm_device"
    log_info "Weston runtime directory, $dstwr_runtime_dir"
    log_info "Weston socket, $dstwr_socket"
    log_info "Weston log, $dstwr_log"

    if [ -n "$dstwr_egl_json" ]; then
        log_info "Weston EGL vendor JSON, $dstwr_egl_json"
    else
        log_info "Weston EGL vendor JSON, native GLVND discovery"
    fi

    if display_desktop_weston_unit_exists "$dstwr_unit"; then
        log_info "Reusing the existing transient unit definition"
        systemctl reset-failed "$dstwr_unit" >/dev/null 2>&1 || true

        if systemctl start "$dstwr_unit"; then
            dstwr_started=1
        fi
    else
        if [ -n "$dstwr_egl_json" ]; then
            if systemd-run \
                --unit="$dstwr_unit" \
                --description="QCOM testkit Weston DRM runtime" \
                --property=Type=simple \
                --property=Restart=no \
                --setenv="XDG_RUNTIME_DIR=$dstwr_runtime_dir" \
                --setenv="__EGL_VENDOR_LIBRARY_FILENAMES=$dstwr_egl_json" \
                "$dstwr_weston_bin" \
                    -Bdrm \
                    --renderer=gl \
                    --drm-device="$dstwr_drm_card" \
                    --current-mode \
                    --continue-without-input \
                    --idle-time=0 \
                    --no-config \
                    --socket="$dstwr_socket_name" \
                    --log="$dstwr_log"; then
                dstwr_started=1
            fi
        else
            if systemd-run \
                --unit="$dstwr_unit" \
                --description="QCOM testkit Weston DRM runtime" \
                --property=Type=simple \
                --property=Restart=no \
                --setenv="XDG_RUNTIME_DIR=$dstwr_runtime_dir" \
                "$dstwr_weston_bin" \
                    -Bdrm \
                    --renderer=gl \
                    --drm-device="$dstwr_drm_card" \
                    --current-mode \
                    --continue-without-input \
                    --idle-time=0 \
                    --no-config \
                    --socket="$dstwr_socket_name" \
                    --log="$dstwr_log"; then
                dstwr_started=1
            fi
        fi
    fi

    if [ "$dstwr_started" -ne 1 ]; then
        log_error "systemd could not start the transient Weston unit"
        display_stop_transient_weston_runtime 1 || true
        return 1
    fi

    while [ "$dstwr_wait" -lt "$dstwr_wait_secs" ]; do
        if [ -S "$dstwr_socket" ]; then
            break
        fi

        if ! systemctl is-active --quiet "$dstwr_unit"; then
            break
        fi

        sleep 1
        dstwr_wait=$((dstwr_wait + 1))
    done

    if [ ! -S "$dstwr_socket" ]; then
        log_error "Transient Weston did not create its Wayland socket"
        systemctl status "$dstwr_unit" --no-pager --full 2>&1 || true
        journalctl -u "$dstwr_unit" -n 80 --no-pager 2>&1 || true
        tail -n 80 "$dstwr_log" 2>/dev/null || true
        display_stop_transient_weston_runtime 1 || true
        return 1
    fi

    sleep 1

    if ! display_adopt_desktop_weston_socket \
        "$dstwr_socket" \
        "$dstwr_log"; then
        log_error "Transient Weston runtime validation failed"
        tail -n 80 "$dstwr_log" 2>/dev/null || true
        display_stop_transient_weston_runtime 1 || true
        return 1
    fi

    DISPLAY_RUNTIME_OWNER="qcom-testkit-transient"
    DISPLAY_TRANSIENT_WESTON_UNIT="$dstwr_unit"
    DISPLAY_TRANSIENT_WESTON_LOG="$dstwr_log"
    DISPLAY_TRANSIENT_WESTON_DRM_DEVICE="$dstwr_drm_device"
    export DISPLAY_RUNTIME_OWNER
    export DISPLAY_TRANSIENT_WESTON_UNIT
    export DISPLAY_TRANSIENT_WESTON_LOG
    export DISPLAY_TRANSIENT_WESTON_DRM_DEVICE

    log_pass "Transient desktop Weston runtime is ready"
    return 0
}

###############################################################################
# Desktop Weston runtime, manual command promoted to shared helper
#
# This helper uses the exact direct DRM command validated manually on Debian:
# - no seatd-launch
# - no LIBSEAT_BACKEND override
# - no PAM, TTY, udev, user, or systemd-unit creation
# - no package operations
#
# It first adopts an existing Weston socket. When no Weston process exists, it
# stops only the active display manager through the existing shared helper and
# starts Weston on the dynamically selected DRM card.
###############################################################################
display_prepare_desktop_weston_runtime() {
    dpdwr_testname="${1:-display-test}"
    dpdwr_wait_secs="${2:-10}"
    dpdwr_runtime_dir="${DISPLAY_DESKTOP_WESTON_RUNTIME_DIR:-/run/qcom-weston-manual}"
    dpdwr_socket_name="${DISPLAY_DESKTOP_WESTON_SOCKET:-wayland-manual-test}"
    dpdwr_socket_path="$dpdwr_runtime_dir/$dpdwr_socket_name"
    dpdwr_weston_log="${DISPLAY_DESKTOP_WESTON_LOG:-/tmp/weston-manual.log}"
    dpdwr_launch_log="${DISPLAY_DESKTOP_WESTON_LAUNCH_LOG:-/tmp/weston-manual-launch.log}"
    dpdwr_state_file="$dpdwr_runtime_dir/display-manager.state"
    dpdwr_drm_device=""
    dpdwr_drm_card=""
    dpdwr_candidate=""
    dpdwr_runtime=""
    dpdwr_socket=""
    dpdwr_pid=""
    dpdwr_wait=0
    dpdwr_started=0
    dpdwr_display_manager_stopped=0
    dpdwr_old_xdg="${XDG_RUNTIME_DIR-__unset__}"
    dpdwr_old_wayland="${WAYLAND_DISPLAY-__unset__}"

    case "$dpdwr_wait_secs" in
        ''|*[!0-9]*)
            dpdwr_wait_secs=10
            ;;
    esac

    [ "$dpdwr_wait_secs" -gt 0 ] 2>/dev/null || dpdwr_wait_secs=10

    # First honor a working environment already exported by the caller.
    if [ -n "${XDG_RUNTIME_DIR:-}" ] &&
       [ -n "${WAYLAND_DISPLAY:-}" ]; then
        dpdwr_candidate="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"

        if [ -S "$dpdwr_candidate" ] &&
           command -v wayland_connection_ok >/dev/null 2>&1 &&
           wayland_connection_ok; then
            DISPLAY_WAYLAND_SOCKET="$dpdwr_candidate"
            export DISPLAY_WAYLAND_SOCKET
            log_pass "Existing desktop Weston runtime is usable, socket=$dpdwr_candidate"
            return 0
        fi
    fi

    # Derive the socket from a live Weston process environment and command line.
    if command -v pgrep >/dev/null 2>&1; then
        for dpdwr_pid in $(pgrep -x weston 2>/dev/null || true); do
            [ -r "/proc/$dpdwr_pid/environ" ] || continue
            [ -r "/proc/$dpdwr_pid/cmdline" ] || continue

            dpdwr_runtime="$(
                tr '\000' '\n' <"/proc/$dpdwr_pid/environ" 2>/dev/null |
                    sed -n 's/^XDG_RUNTIME_DIR=//p' |
                    head -n 1
            )"

            dpdwr_socket="$(
                tr '\000' '\n' <"/proc/$dpdwr_pid/cmdline" 2>/dev/null |
                    awk '
                        previous == "--socket" {
                            print
                            exit
                        }

                        /^--socket=/ {
                            sub(/^--socket=/, "")
                            print
                            exit
                        }

                        {
                            previous = $0
                        }
                    '
            )"

            [ -n "$dpdwr_runtime" ] || continue
            [ -n "$dpdwr_socket" ] || continue

            dpdwr_candidate="$dpdwr_runtime/$dpdwr_socket"
            [ -S "$dpdwr_candidate" ] || continue

            if command -v adopt_wayland_env_from_socket >/dev/null 2>&1 &&
               adopt_wayland_env_from_socket "$dpdwr_candidate"; then
                if ! command -v wayland_connection_ok >/dev/null 2>&1 ||
                   wayland_connection_ok; then
                    DISPLAY_WAYLAND_SOCKET="$dpdwr_candidate"
                    export DISPLAY_WAYLAND_SOCKET
                    log_pass "Adopted existing desktop Weston runtime, socket=$dpdwr_candidate pid=$dpdwr_pid"
                    return 0
                fi
            fi
        done
    fi

    # Keep compatibility with existing generic discovery.
    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        dpdwr_candidate="$(
            discover_wayland_socket_anywhere 2>/dev/null |
                head -n 1 ||
                true
        )"

        if [ -n "$dpdwr_candidate" ] &&
           [ -S "$dpdwr_candidate" ] &&
           command -v adopt_wayland_env_from_socket >/dev/null 2>&1 &&
           adopt_wayland_env_from_socket "$dpdwr_candidate"; then
            if ! command -v wayland_connection_ok >/dev/null 2>&1 ||
               wayland_connection_ok; then
                DISPLAY_WAYLAND_SOCKET="$dpdwr_candidate"
                export DISPLAY_WAYLAND_SOCKET
                log_pass "Adopted discovered desktop Weston runtime, socket=$dpdwr_candidate"
                return 0
            fi
        fi
    fi

    # Explicitly check the path used by the manually validated command.
    if [ -S "$dpdwr_socket_path" ] &&
       command -v adopt_wayland_env_from_socket >/dev/null 2>&1 &&
       adopt_wayland_env_from_socket "$dpdwr_socket_path"; then
        if ! command -v wayland_connection_ok >/dev/null 2>&1 ||
           wayland_connection_ok; then
            DISPLAY_WAYLAND_SOCKET="$dpdwr_socket_path"
            export DISPLAY_WAYLAND_SOCKET
            log_pass "Adopted validated desktop Weston runtime, socket=$dpdwr_socket_path"
            return 0
        fi
    fi

    # Never launch a second compositor over an unknown Weston process.
    if command -v pgrep >/dev/null 2>&1 &&
       pgrep -x weston >/dev/null 2>&1; then
        log_error "A Weston process exists but no usable Wayland socket could be adopted"
        return 1
    fi

    if ! command -v weston >/dev/null 2>&1; then
        log_error "Cannot start desktop Weston, weston command is unavailable"
        return 1
    fi

    if ! command -v display_select_primary_drm_device >/dev/null 2>&1; then
        log_error "Cannot start desktop Weston, DRM selection helper is unavailable"
        return 1
    fi

    dpdwr_drm_device="$(
        display_select_primary_drm_device 2>/dev/null ||
        true
    )"

    if [ -z "$dpdwr_drm_device" ] ||
       [ ! -c "$dpdwr_drm_device" ]; then
        log_error "Cannot start desktop Weston, no usable DRM card was selected"
        return 1
    fi

    dpdwr_drm_card=${dpdwr_drm_device##*/}

    if ! mkdir -p "$dpdwr_runtime_dir"; then
        log_error "Could not create desktop Weston runtime directory, $dpdwr_runtime_dir"
        return 1
    fi

    if ! chmod 0700 "$dpdwr_runtime_dir"; then
        log_error "Could not set desktop Weston runtime directory permissions, $dpdwr_runtime_dir"
        return 1
    fi

    rm -f \
        "$dpdwr_socket_path" \
        "$dpdwr_socket_path.lock" \
        "$dpdwr_weston_log" \
        "$dpdwr_launch_log"

    # Reuse the existing display-manager ownership helper. The manager remains
    # stopped while Weston owns DRM, matching the manually validated state.
    if command -v display_stop_service_for_drm >/dev/null 2>&1; then
        if ! display_stop_service_for_drm \
            display-manager.service \
            "$dpdwr_drm_device" \
            "$dpdwr_state_file"; then
            log_error "Could not release display-manager DRM ownership"
            return 1
        fi

        if [ -s "$dpdwr_state_file" ]; then
            dpdwr_display_manager_stopped=1
        fi
    elif command -v systemctl >/dev/null 2>&1 &&
         systemctl is-active --quiet display-manager.service 2>/dev/null; then
        log_error "Display manager is active and the shared DRM ownership helper is unavailable"
        return 1
    fi

    log_info "Starting desktop Weston with the manually validated DRM command"
    log_info "Desktop Weston DRM device, $dpdwr_drm_device"
    log_info "Desktop Weston runtime directory, $dpdwr_runtime_dir"
    log_info "Desktop Weston socket, $dpdwr_socket_path"
    log_info "Desktop Weston log, $dpdwr_weston_log"

    XDG_RUNTIME_DIR="$dpdwr_runtime_dir" \
        nohup env \
            -u LIBSEAT_BACKEND \
            -u SEATD_SOCK \
            -u SEATD_VTBOUND \
            weston \
                -Bdrm \
                --renderer=gl \
                --drm-device="$dpdwr_drm_card" \
                --current-mode \
                --continue-without-input \
                --idle-time=0 \
                --no-config \
                --socket="$dpdwr_socket_name" \
                --log="$dpdwr_weston_log" \
            >"$dpdwr_launch_log" 2>&1 &

    dpdwr_pid=$!
    dpdwr_started=1

    while [ "$dpdwr_wait" -lt "$dpdwr_wait_secs" ]; do
        if [ -S "$dpdwr_socket_path" ]; then
            break
        fi

        if ! kill -0 "$dpdwr_pid" 2>/dev/null; then
            break
        fi

        sleep 1
        dpdwr_wait=$((dpdwr_wait + 1))
    done

    if [ ! -S "$dpdwr_socket_path" ]; then
        log_error "Desktop Weston did not create its Wayland socket"
        tail -n 80 "$dpdwr_weston_log" 2>/dev/null || true
        tail -n 40 "$dpdwr_launch_log" 2>/dev/null || true

        if [ "$dpdwr_started" -eq 1 ]; then
            kill -TERM "$dpdwr_pid" 2>/dev/null || true
            wait "$dpdwr_pid" 2>/dev/null || true
        fi

        if [ "$dpdwr_display_manager_stopped" -eq 1 ] &&
           command -v display_restore_service_from_state >/dev/null 2>&1; then
            display_restore_service_from_state "$dpdwr_state_file" || true
        fi

        return 1
    fi

    if ! command -v adopt_wayland_env_from_socket >/dev/null 2>&1 ||
       ! adopt_wayland_env_from_socket "$dpdwr_socket_path"; then
        log_error "Could not adopt the desktop Weston Wayland socket"
        kill -TERM "$dpdwr_pid" 2>/dev/null || true
        wait "$dpdwr_pid" 2>/dev/null || true

        if [ "$dpdwr_display_manager_stopped" -eq 1 ] &&
           command -v display_restore_service_from_state >/dev/null 2>&1; then
            display_restore_service_from_state "$dpdwr_state_file" || true
        fi

        return 1
    fi

    if command -v wayland_connection_ok >/dev/null 2>&1 &&
       ! wayland_connection_ok; then
        log_error "Desktop Weston socket exists but the Wayland client probe failed"
        kill -TERM "$dpdwr_pid" 2>/dev/null || true
        wait "$dpdwr_pid" 2>/dev/null || true

        if [ "$dpdwr_display_manager_stopped" -eq 1 ] &&
           command -v display_restore_service_from_state >/dev/null 2>&1; then
            display_restore_service_from_state "$dpdwr_state_file" || true
        fi

        return 1
    fi

    if [ -r "$dpdwr_weston_log" ] &&
       tail -n 200 "$dpdwr_weston_log" 2>/dev/null |
           grep -Eiq \
               "atomic: couldn.t commit new state: Permission denied|repaint-flush failed: Permission denied|failed to acquire DRM master|failed to initialize DRM backend|failed to create renderer"; then
        log_error "Desktop Weston reports fatal DRM/KMS errors"
        tail -n 80 "$dpdwr_weston_log" 2>/dev/null || true
        kill -TERM "$dpdwr_pid" 2>/dev/null || true
        wait "$dpdwr_pid" 2>/dev/null || true

        if [ "$dpdwr_display_manager_stopped" -eq 1 ] &&
           command -v display_restore_service_from_state >/dev/null 2>&1; then
            display_restore_service_from_state "$dpdwr_state_file" || true
        fi

        return 1
    fi

    DISPLAY_WAYLAND_SOCKET="$dpdwr_socket_path"
    DISPLAY_DESKTOP_WESTON_PID="$dpdwr_pid"
    DISPLAY_DESKTOP_WESTON_LOG="$dpdwr_weston_log"
    DISPLAY_DESKTOP_WESTON_DRM_DEVICE="$dpdwr_drm_device"

    export DISPLAY_WAYLAND_SOCKET
    export DISPLAY_DESKTOP_WESTON_PID
    export DISPLAY_DESKTOP_WESTON_LOG
    export DISPLAY_DESKTOP_WESTON_DRM_DEVICE

    log_pass "Desktop Weston runtime is ready, socket=$dpdwr_socket_path pid=$dpdwr_pid"
    return 0
}

display_prepare_desktop_graphics_stack() {
    dpdgs_testname="${1:-display-test}"
    dpdgs_mode="${2:-auto}"
    dpdgs_gpu_module="${3:-msm_kgsl}"
    dpdgs_gpu_device="${4:-/dev/kgsl-3d0}"
    dpdgs_gbm_package="${5:-}"
    dpdgs_rc=0
    dpdgs_package_changed=0
    dpdgs_boot_changed=0

    if [ -z "$dpdgs_gbm_package" ]; then
        if command -v pkg_detect_os_id >/dev/null 2>&1 &&
           [ "$(pkg_detect_os_id 2>/dev/null || true)" = "ubuntu" ]; then
            dpdgs_gbm_package="libgbm-msm"
        else
            dpdgs_gbm_package="libgbm-msm1"
        fi
    fi

    case "$dpdgs_mode" in
        auto)
            log_info "Desktop graphics mode is auto, preserving the currently installed and booted stack"
            return 0
            ;;

        overlay)
            for dpdgs_helper in \
                pkg_package_set_contains \
                pkg_ensure_optional_package_set_present \
                pkg_package_has_file_matching \
                mrv_qcom_gpu_validate_boot_mode \
                display_select_egl_vendor; do
                if ! command -v "$dpdgs_helper" >/dev/null 2>&1; then
                    log_fail "$dpdgs_testname FAIL - required desktop overlay helper is unavailable: $dpdgs_helper"
                    return 1
                fi
            done

            if ! pkg_package_set_contains graphics "$dpdgs_gbm_package"; then
                log_fail "$dpdgs_testname FAIL - graphics package set is incomplete, missing $dpdgs_gbm_package"
                return 1
            fi

            if ! pkg_ensure_optional_package_set_present \
                graphics \
                qli-staging \
                auto \
                --overlay; then
                log_fail "$dpdgs_testname FAIL - failed to ensure Qualcomm graphics overlay package set"
                return 1
            fi

            if ! pkg_package_has_file_matching \
                "$dpdgs_gbm_package" \
                '/gbm/msm_gbm[.]so$'; then
                log_fail "$dpdgs_testname FAIL - Qualcomm GBM backend is unavailable from $dpdgs_gbm_package"
                return 1
            fi

            mrv_qcom_gpu_validate_boot_mode \
                kgsl \
                "$dpdgs_gpu_module" \
                "$dpdgs_gpu_device" \
                msm
            dpdgs_rc=$?

            case "$dpdgs_rc" in
                0)
                    ;;
                2)
                    log_skip "$dpdgs_testname SKIP - Qualcomm overlay packages are ready, reboot required to activate KGSL"
                    return 2
                    ;;
                *)
                    log_skip "$dpdgs_testname SKIP - unable to confirm a valid KGSL boot runtime"
                    return 2
                    ;;
            esac

            if command -v ldconfig >/dev/null 2>&1 && ! ldconfig; then
                log_fail "$dpdgs_testname FAIL - ldconfig failed after overlay package validation"
                return 1
            fi

            if ! display_select_egl_vendor adreno; then
                log_fail "$dpdgs_testname FAIL - failed to select Qualcomm Adreno EGL vendor"
                return 1
            fi

            log_pass "Qualcomm overlay packages, GBM backend, and KGSL boot runtime are ready"
            return 0
            ;;

        base)
            for dpdgs_helper in \
                pkg_restore_package_set \
                pkg_ensure_required_package_set_present \
                mrv_qcom_gpu_cleanup_kgsl_boot_artifacts \
                mrv_qcom_gpu_validate_boot_mode \
                display_select_egl_vendor; do
                if ! command -v "$dpdgs_helper" >/dev/null 2>&1; then
                    log_fail "$dpdgs_testname FAIL - required desktop base helper is unavailable: $dpdgs_helper"
                    return 1
                fi
            done

            dpdgs_package_changed=0
            dpdgs_boot_changed=0

            pkg_restore_package_set graphics
            dpdgs_rc=$?

            case "$dpdgs_rc" in
                0)
                    dpdgs_package_changed=0
                    ;;
                2)
                    dpdgs_package_changed=1
                    ;;
                *)
                    log_fail "$dpdgs_testname FAIL - failed to remove Qualcomm graphics overlay package set"
                    return 1
                    ;;
            esac

            mrv_qcom_gpu_cleanup_kgsl_boot_artifacts
            dpdgs_rc=$?

            case "$dpdgs_rc" in
                0)
                    dpdgs_boot_changed=1
                    ;;
                1)
                    dpdgs_boot_changed=0
                    ;;
                2)
                    log_fail "$dpdgs_testname FAIL - failed to clean stale KGSL boot artifacts"
                    return 1
                    ;;
                *)
                    log_fail "$dpdgs_testname FAIL - unexpected KGSL boot-artifact cleanup result, rc=$dpdgs_rc"
                    return 1
                    ;;
            esac

            if ! pkg_ensure_required_package_set_present graphics-base; then
                log_fail "$dpdgs_testname FAIL - failed to ensure upstream Mesa graphics package set"
                return 1
            fi

            if [ "$dpdgs_package_changed" -eq 1 ] ||
               [ "$dpdgs_boot_changed" -eq 1 ]; then
                    log_skip "$dpdgs_testname SKIP - Qualcomm graphics packages or KGSL boot artifacts changed, reboot required to activate upstream MSM/freedreno"
                return 2
            fi

            mrv_qcom_gpu_validate_boot_mode \
                msm \
                "$dpdgs_gpu_module" \
                "$dpdgs_gpu_device" \
                msm
            dpdgs_rc=$?

            case "$dpdgs_rc" in
                0)
                    ;;
                2)
                    log_skip "$dpdgs_testname SKIP - current boot still uses KGSL, reboot required to restore upstream MSM/freedreno ownership"
                    return 2
                    ;;
                *)
                    log_skip "$dpdgs_testname SKIP - unable to confirm upstream MSM/freedreno ownership"
                    return 2
                    ;;
            esac

            if ! display_select_egl_vendor mesa; then
                log_skip "$dpdgs_testname SKIP - Mesa EGL vendor is unavailable"
                return 2
            fi

            log_pass "Upstream MSM/freedreno packages and boot runtime are ready"
            return 0
            ;;

        *)
            log_fail "$dpdgs_testname FAIL - unsupported desktop graphics mode: $dpdgs_mode"
            return 1
            ;;
    esac
}

display_prepare_image_weston_runtime() {
    dpiwr_testname="${1:-display-test}"
    dpiwr_wait_secs="${2:-10}"
    dpiwr_flavour="${3:-base}"
    dpiwr_sock=""
    dpiwr_new_sock=""

    log_info "Preserving image-provided Weston runtime behavior"

    if command -v wayland_debug_snapshot >/dev/null 2>&1; then
        wayland_debug_snapshot "${dpiwr_testname}: start"
    fi

    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        dpiwr_sock="$(
            discover_wayland_socket_anywhere 2>/dev/null |
                head -n 1 ||
                true
        )"
    fi

    if [ -n "$dpiwr_sock" ] &&
       command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        log_info "Found existing Wayland socket, $dpiwr_sock"

        if ! adopt_wayland_env_from_socket "$dpiwr_sock"; then
            log_warn "Failed to adopt Wayland environment from $dpiwr_sock"
        fi
    fi

    if [ -z "$dpiwr_sock" ] &&
       [ "$dpiwr_flavour" = "base" ] &&
       command -v weston_wait_ready >/dev/null 2>&1; then
        log_info "No usable Wayland socket yet on base build, waiting briefly for the image-provided Weston runtime"

        if weston_wait_ready "$dpiwr_wait_secs"; then
            if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
                dpiwr_sock="$(
                    discover_wayland_socket_anywhere 2>/dev/null |
                        head -n 1 ||
                        true
                )"
            fi

            if [ -n "$dpiwr_sock" ] &&
               command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
                log_info "Base Weston runtime became ready, $dpiwr_sock"
                adopt_wayland_env_from_socket "$dpiwr_sock" || true
            fi
        fi
    fi

    if [ -z "$dpiwr_sock" ]; then
        if [ "$dpiwr_flavour" = "overlay" ] &&
           command -v overlay_start_weston_drm >/dev/null 2>&1; then
            log_info "No usable Wayland socket, starting overlay Weston through overlay_start_weston_drm"

            if command -v \
                weston_force_primary_1080p60_if_not_60 \
                >/dev/null 2>&1; then
                log_info "Pre-configuring the primary output to about 60Hz before starting Weston, best effort"
                weston_force_primary_1080p60_if_not_60 || true
            fi

            if ! overlay_start_weston_drm; then
                log_warn "overlay_start_weston_drm returned non-zero"
                return 1
            fi

            if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
                dpiwr_sock="$(
                    discover_wayland_socket_anywhere 2>/dev/null |
                        head -n 1 ||
                        true
                )"
            fi

            if [ -n "$dpiwr_sock" ] &&
               command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
                log_info "Overlay Weston created Wayland socket, $dpiwr_sock"
                adopt_wayland_env_from_socket "$dpiwr_sock" || true
            else
                log_warn "overlay_start_weston_drm reported success but no Wayland socket was found"
            fi
        else
            log_fail "$dpiwr_testname FAIL - no image-provided Wayland socket is available"
            return 1
        fi
    fi

    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        dpiwr_new_sock="$(
            discover_wayland_socket_anywhere 2>/dev/null |
                head -n 1 ||
                true
        )"

        if [ -n "$dpiwr_new_sock" ]; then
            dpiwr_sock="$dpiwr_new_sock"
        fi
    fi

    if [ -z "$dpiwr_sock" ]; then
        log_fail "$dpiwr_testname FAIL - no Wayland socket was found after runtime preparation"
        return 1
    fi

    if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        if ! adopt_wayland_env_from_socket "$dpiwr_sock"; then
            log_fail "$dpiwr_testname FAIL - failed to adopt the final Wayland socket"
            return 1
        fi
    else
        XDG_RUNTIME_DIR="$(dirname "$dpiwr_sock")"
        WAYLAND_DISPLAY="$(basename "$dpiwr_sock")"
        export XDG_RUNTIME_DIR
        export WAYLAND_DISPLAY
    fi

    if command -v wayland_connection_ok >/dev/null 2>&1; then
        if ! wayland_connection_ok; then
            if [ "$dpiwr_flavour" = "base" ] &&
               command -v weston_wait_ready >/dev/null 2>&1; then
                log_warn "Initial Wayland connection test failed, waiting briefly and retrying"

                if weston_wait_ready 5; then
                    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
                        dpiwr_sock="$(
                            discover_wayland_socket_anywhere 2>/dev/null |
                                head -n 1 ||
                                true
                        )"
                    fi

                    if [ -n "$dpiwr_sock" ] &&
                       command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
                        adopt_wayland_env_from_socket "$dpiwr_sock" || true
                    fi
                fi
            fi

            if ! wayland_connection_ok; then
                log_fail "$dpiwr_testname FAIL - Wayland connection test failed"
                return 1
            fi
        fi

        log_info "Wayland connection test, OK"
    else
        log_warn "wayland_connection_ok helper is unavailable, continuing with socket validation only"
    fi

    DISPLAY_WAYLAND_SOCKET="$dpiwr_sock"

    case "$dpiwr_sock" in
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

    export DISPLAY_WAYLAND_SOCKET
    export DISPLAY_RUNTIME_MODEL

    log_info "Wayland runtime model, $DISPLAY_RUNTIME_MODEL"
    log_info "Wayland socket, $DISPLAY_WAYLAND_SOCKET"
    log_info "XDG_RUNTIME_DIR, ${XDG_RUNTIME_DIR:-<unset>}"
    log_info "WAYLAND_DISPLAY, ${WAYLAND_DISPLAY:-<unset>}"

    return 0
}

display_resolve_test_fps_gate_policy() {
    drtfgp_os_id="${1:-unknown}"
    drtfgp_mode="${2:-auto}"
    drtfgp_explicit="${3:-}"
    drtfgp_cap="${4:-60}"
    drtfgp_min_pct="${5:-85}"

    DISPLAY_TEST_FPS_POLICY="shared"
    DISPLAY_TEST_FPS_REFRESH="${DISPLAY_FPS_DETECTED_HZ:-}"
    DISPLAY_TEST_FPS_EXPECTED="${DISPLAY_FPS_EXPECTED:-}"
    DISPLAY_TEST_FPS_MIN_OK="${DISPLAY_FPS_MIN_OK:-}"

    case "$drtfgp_os_id" in
        debian|ubuntu|centos|rhel|fedora)
            if [ "$drtfgp_mode" = "auto" ] &&
               [ -z "$drtfgp_explicit" ]; then
                DISPLAY_TEST_FPS_POLICY="desktop-functional-cap"
                DISPLAY_TEST_FPS_EXPECTED="$drtfgp_cap"

                case "$DISPLAY_TEST_FPS_REFRESH" in
                    ''|*[!0-9]*)
                        ;;
                    *)
                        if [ "$DISPLAY_TEST_FPS_REFRESH" -gt 0 ] &&
                           [ "$DISPLAY_TEST_FPS_REFRESH" -lt "$DISPLAY_TEST_FPS_EXPECTED" ]; then
                            DISPLAY_TEST_FPS_EXPECTED="$DISPLAY_TEST_FPS_REFRESH"
                        fi
                        ;;
                esac

                DISPLAY_TEST_FPS_MIN_OK=$((
                    DISPLAY_TEST_FPS_EXPECTED * drtfgp_min_pct / 100
                ))

                if [ "$DISPLAY_TEST_FPS_MIN_OK" -le 0 ]; then
                    DISPLAY_TEST_FPS_MIN_OK=1
                fi
            fi
            ;;
    esac

    export DISPLAY_TEST_FPS_POLICY
    export DISPLAY_TEST_FPS_REFRESH
    export DISPLAY_TEST_FPS_EXPECTED
    export DISPLAY_TEST_FPS_MIN_OK

    return 0
}

display_apply_test_fps_gate_policy() {
    datfgp_avg="${1:--}"
    datfgp_count="${2:-0}"
    datfgp_require="${3:-1}"

    case "$datfgp_count" in
        ''|*[!0-9]*)
            datfgp_count=0
            ;;
    esac

    if [ "${DISPLAY_TEST_FPS_POLICY:-shared}" = "desktop-session-connectivity" ]; then
        if [ "$datfgp_count" -eq 0 ]; then
            log_warn "No FPS samples were produced by the desktop session, compositor connectivity was validated"
        else
            log_info "Recording desktop-session FPS samples without performance gating, samples=$datfgp_count avg=$datfgp_avg"
        fi

        return 0
    fi

    if [ "${DISPLAY_TEST_FPS_POLICY:-shared}" != "desktop-functional-cap" ]; then
        if command -v display_fps_gate_avg >/dev/null 2>&1; then
            display_fps_gate_avg "$datfgp_avg" "$datfgp_count"
            return $?
        fi

        if [ "$datfgp_require" -ne 0 ]; then
            log_fail "FPS gating is required but display_fps_gate_avg is unavailable"
            return 1
        fi

        log_warn "display_fps_gate_avg is unavailable, FPS gating was not requested"
        return 0
    fi

    if [ "$datfgp_count" -eq 0 ]; then
        if [ "$datfgp_require" -ne 0 ]; then
            log_fail "Desktop functional FPS gate enabled but no FPS samples were found"
            return 1
        fi

        log_warn "No FPS samples were found, FPS gating was not requested"
        return 0
    fi

    if ! printf '%s\n' "$datfgp_avg" |
        awk -v min="${DISPLAY_TEST_FPS_MIN_OK:-1}" '
            $1 ~ /^[0-9]+([.][0-9]+)?$/ && ($1 + 0.0) >= (min + 0.0) {
                exit 0
            }
            { exit 1 }
        '; then
        datfgp_rounded="$(
            awk -v value="$datfgp_avg" 'BEGIN { printf "%.0f", value + 0.0 }'
        )"

        log_fail "Average FPS below desktop functional threshold, avg=$datfgp_avg (~$datfgp_rounded) < ${DISPLAY_TEST_FPS_MIN_OK:-1} (target=${DISPLAY_TEST_FPS_EXPECTED:-unknown}, output=${DISPLAY_TEST_FPS_REFRESH:-unknown}Hz)"
        return 1
    fi

    datfgp_rounded="$(
        awk -v value="$datfgp_avg" 'BEGIN { printf "%.0f", value + 0.0 }'
    )"

    log_info "Desktop functional FPS gate passed, avg=$datfgp_avg (~$datfgp_rounded) >= ${DISPLAY_TEST_FPS_MIN_OK:-1} (target=${DISPLAY_TEST_FPS_EXPECTED:-unknown}, output=${DISPLAY_TEST_FPS_REFRESH:-unknown}Hz)"
    return 0
}
