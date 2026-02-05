#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# IRIS Video V4L2 runner with stack selection via utils/lib_video.sh

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"

while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_video.sh"

TESTNAME="Video_V4L2_Runner"
RES_FILE="./${TESTNAME}.res"

if [ -z "${TAR_URL:-}" ]; then
    TAR_URL="https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz"
fi

# --- Defaults / knobs ---
if [ -z "${TIMEOUT:-}" ]; then TIMEOUT="60"; fi
if [ -z "${STRICT:-}" ]; then STRICT="0"; fi
if [ -z "${DMESG_SCAN:-}" ]; then DMESG_SCAN="1"; fi
PATTERN=""
if [ -z "${MAX:-}" ]; then MAX="0"; fi
if [ -z "${STOP_ON_FAIL:-}" ]; then STOP_ON_FAIL="0"; fi
DRY="0"
if [ -z "${EXTRACT_INPUT_CLIPS:-}" ]; then EXTRACT_INPUT_CLIPS="true"; fi
if [ -z "${SUCCESS_RE:-}" ]; then SUCCESS_RE="SUCCESS"; fi
if [ -z "${LOGLEVEL:-}" ]; then LOGLEVEL="15"; fi
if [ -z "${REPEAT:-}" ]; then REPEAT="1"; fi
if [ -z "${REPEAT_DELAY:-}" ]; then REPEAT_DELAY="0"; fi
if [ -z "${REPEAT_POLICY:-}" ]; then REPEAT_POLICY="all"; fi
JUNIT_OUT=""
VERBOSE="0"

# --- Stabilizers (opt-in) ---
RETRY_ON_FAIL="0" # extra attempts after a FAIL
POST_TEST_SLEEP="0" # settle time after each case

# --- Custom module source (opt-in; default is untouched) ---
KO_DIRS="" # colon-separated list of dirs that contain .ko files
KO_TREE="" # alt root that has lib/modules/$KVER
KO_TARBALL="" # optional tarball that we unpack once
KO_PREFER_CUSTOM="0" # 1 = try custom first; default 0 = system first

# --- Opt-in: custom media bundle tar (always honored even with --dir/--config) ---
CLIPS_TAR="" # /path/to/clips.tar[.gz|.xz|.zst|.bz2|.tgz|.tbz2|.zip]
CLIPS_DEST="" # optional extraction destination; defaults to cfg/dir root or testcase dir

if [ -z "${VIDEO_STACK:-}" ]; then VIDEO_STACK="auto"; fi
if [ -z "${VIDEO_PLATFORM:-}" ]; then VIDEO_PLATFORM=""; fi
if [ -z "${VIDEO_FW_DS:-}" ]; then VIDEO_FW_DS=""; fi
if [ -z "${VIDEO_FW_BACKUP_DIR:-}" ]; then VIDEO_FW_BACKUP_DIR=""; fi
if [ -z "${VIDEO_NO_REBOOT:-}" ]; then VIDEO_NO_REBOOT="0"; fi
if [ -z "${VIDEO_FORCE:-}" ]; then VIDEO_FORCE="0"; fi
if [ -z "${VIDEO_APP:-}" ]; then VIDEO_APP="/usr/bin/iris_v4l2_test"; fi

# <<< CHANGE #1: Initialize the V4L2 compliance run variable >>>
V4L2_COMPLIANCE_RUN="0"

# --- Net/DL tunables (no-op if helpers ignore them) ---
if [ -z "${NET_STABILIZE_SLEEP:-}" ]; then NET_STABILIZE_SLEEP="5"; fi
if [ -z "${WGET_TIMEOUT_SECS:-}" ]; then WGET_TIMEOUT_SECS="120"; fi
if [ -z "${WGET_TRIES:-}" ]; then WGET_TRIES="2"; fi

# --- Stability sleeps ---
if [ -z "${APP_LAUNCH_SLEEP:-}" ]; then APP_LAUNCH_SLEEP="1"; fi
if [ -z "${INTER_TEST_SLEEP:-}" ]; then INTER_TEST_SLEEP="2"; fi

# --- New: log flavor for --stack both sub-runs ---
LOG_FLAVOR=""

usage() {
    cat <<EOF
Usage: $0 [--config path.json|/path/dir] [--dir DIR] [--pattern GLOB]
          [--timeout S] [--strict] [--no-dmesg] [--max N] [--stop-on-fail]
          [--loglevel N] [--extract-input-clips true|false]
          [--repeat N] [--repeat-delay S] [--repeat-policy all|any]
          [--junit FILE] [--dry-run] [--verbose]
          [--stack auto|upstream|downstream|base|overlay|up|down|both]
          [--platform lemans|monaco|kodiak]
          [--downstream-fw PATH] [--force]
          [--app /path/to/iris_v4l2_test]
          [--v4l2-compliance] # <<< This flag is now recognized
          [--ssid SSID] [--password PASS]
          [--ko-dir DIR[:DIR2:...]] # opt-in: search these dirs for .ko on failure
          [--ko-tree ROOT] # opt-in: modprobe -d ROOT (expects lib/modules/\$(uname -r))
          [--ko-tar FILE.tar[.gz|.xz]] # opt-in: unpack once under /run/iris_mods/\$KVER, set --ko-tree/--ko-dir accordingly
          [--ko-prefer-custom] # opt-in: try custom sources before system
          [--app-launch-sleep S] [--inter-test-sleep S]
          [--log-flavor NAME] # internal: e.g. upstream or downstream (used by --stack both)
          # --- Stabilizers ---
          [--retry-on-fail N] # retry up to N times if a case ends FAIL
          [--post-test-sleep S] # sleep S seconds after each case
          # --- Media bundle (opt-in, local tar) ---
          [--clips-tar /path/to/clips.tar.gz] # extract locally even if --dir/--config is used
          [--clips-dest DIR] # extraction destination (defaults to cfg/dir root or testcase dir)
EOF
}

CFG=""
DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config)
            shift
            CFG="$1"
            ;;
        --dir)
            shift
            DIR="$1"
            ;;
        --pattern)
            shift
            PATTERN="$1"
            ;;
        --timeout)
            shift
            TIMEOUT="$1"
            ;;
        --strict)
            STRICT=1
            ;;
        --no-dmesg)
            DMESG_SCAN=0
            ;;
        --max)
            shift
            MAX="$1"
            ;;
        --stop-on-fail)
            STOP_ON_FAIL=1
            ;;
        --loglevel)
            shift
            LOGLEVEL="$1"
            ;;
        --repeat)
            shift
            REPEAT="$1"
            ;;
        --repeat-delay)
            shift
            REPEAT_DELAY="$1"
            ;;
        --repeat-policy)
            shift
            REPEAT_POLICY="$1"
            ;;
        --junit)
            shift
            JUNIT_OUT="$1"
            ;;
        --dry-run)
            DRY=1
            ;;
        --extract-input-clips)
            shift
            EXTRACT_INPUT_CLIPS="$1"
            ;;
        --verbose)
            VERBOSE=1
            ;;
        --stack)
            shift
            VIDEO_STACK="$1"
            ;;
        --platform)
            shift
            VIDEO_PLATFORM="$1"
            ;;
        --downstream-fw)
            shift
            VIDEO_FW_DS="$1"
            ;;
        --force)
            VIDEO_FORCE=1
            ;;
        --app)
            shift
            VIDEO_APP="$1"
            ;;
        # <<< CHANGE #2: Handle the --v4l2-compliance argument >>>
        --v4l2-compliance)
            V4L2_COMPLIANCE_RUN="1"
            ;;
        --ssid)
            shift
            SSID="$1"
            ;;
        --password)
            shift
            PASSWORD="$1"
            ;;
        --ko-dir)
            shift
            KO_DIRS="$1"
            ;;
        --ko-tree)
            shift
            KO_TREE="$1"
            ;;
        --ko-tar)
            shift
            KO_TARBALL="$1"
            ;;
        --ko-prefer-custom)
            KO_PREFER_CUSTOM="1"
            ;;

        --app-launch-sleep)
            shift
            APP_LAUNCH_SLEEP="$1"
            ;;
        --inter-test-sleep)
            shift
            INTER_TEST_SLEEP="$1"
            ;;
        --log-flavor)
            shift
            LOG_FLAVOR="$1"
            ;;
        # --- Stabilizers ---
        --retry-on-fail)
            shift
            RETRY_ON_FAIL="$1"
            ;;
        --post-test-sleep)
            shift
            POST_TEST_SLEEP="$1"
            ;;
        # --- Media bundle (opt-in, local tar) ---
        --clips-tar)
            shift
            CLIPS_TAR="$1"
            ;;
        --clips-dest)
            shift
            CLIPS_DEST="$1"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_warn "Unknown arg: $1"
            ;;
    esac
    shift
done

# Export envs used by lib
export VIDEO_APP
export VIDEO_FW_DS
export VIDEO_FW_BACKUP_DIR
export VIDEO_NO_REBOOT
export VIDEO_FORCE
export LOG_DIR
export TAR_URL
export SSID
export PASSWORD

export NET_STABILIZE_SLEEP
export WGET_TIMEOUT_SECS
export WGET_TRIES

export APP_LAUNCH_SLEEP
export INTER_TEST_SLEEP

# --- EARLY dependency check (bail out fast) ---

# Ensure the app is executable if a path was provided but lacks +x
if [ -n "$VIDEO_APP" ] && [ -f "$VIDEO_APP" ] && [ ! -x "$VIDEO_APP" ]; then
    chmod +x "$VIDEO_APP" 2>/dev/null || true
    if [ ! -x "$VIDEO_APP" ]; then
        log_warn "App $VIDEO_APP is not executable and chmod failed; attempting to run anyway."
    fi
fi

# --- Optional: unpack a custom module tarball **once** (no env exports) ---
KVER="$(uname -r 2>/dev/null || printf '%s' unknown)"
if [ -n "$KO_TARBALL" ] && [ -f "$KO_TARBALL" ]; then
    DEST="/run/iris_mods/$KVER"
    if [ ! -d "$DEST" ]; then
        mkdir -p "$DEST" 2>/dev/null || true
        case "$KO_TARBALL" in
            *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.zst)
                if command -v tar >/dev/null 2>&1; then
                    # best-effort; keep extraction bounded to DEST
                    tar -xf "$KO_TARBALL" -C "$DEST" 2>/dev/null || true
                fi
                ;;
            *)
                :
                ;;
        esac
    fi
    if [ -d "$DEST/lib/modules/$KVER" ]; then
        KO_TREE="$DEST"
    else
        first_ko_dir="$(find "$DEST" -type f -name '*.ko*' -maxdepth 3 2>/dev/null | head -n1 | xargs -r dirname)"
        if [ -n "$first_ko_dir" ]; then
            if [ -n "$KO_DIRS" ]; then
                KO_DIRS="$first_ko_dir:$KO_DIRS"
            else
                KO_DIRS="$first_ko_dir"
            fi
        fi
    fi
    log_info "Custom module source prepared (tree='${KO_TREE:-none}', dirs='${KO_DIRS:-none}', prefer_custom=$KO_PREFER_CUSTOM)"
fi

if [ -n "$VIDEO_APP" ] && [ -f "$VIDEO_APP" ] && [ ! -x "$VIDEO_APP" ]; then
    chmod +x "$VIDEO_APP" 2>/dev/null || true
    if [ ! -x "$VIDEO_APP" ]; then
        log_warn "App $VIDEO_APP is not executable and chmod failed; attempting to run anyway."
    fi
fi

# ---- Default firmware path for Kodiak downstream if CLI not given ----
if [ -z "${VIDEO_FW_DS:-}" ]; then
    default_fw="/data/vendor/iris_test_app/firmware/vpu20_1v.mbn"
    if [ -f "$default_fw" ]; then
        VIDEO_FW_DS="$default_fw"
        export VIDEO_FW_DS
        log_info "Using default downstream firmware path: $VIDEO_FW_DS"
    fi
fi

# Decide final app path: if --app given, require it; otherwise search PATH, /usr/bin, /data/vendor/iris_test_app
final_app=""

if [ -n "$VIDEO_APP" ] && [ -x "$VIDEO_APP" ]; then
    final_app="$VIDEO_APP"
else
    if command -v iris_v4l2_test >/dev/null 2>&1; then
        final_app="$(command -v iris_v4l2_test)"
    else
        if [ -x "/usr/bin/iris_v4l2_test" ]; then
            final_app="/usr/bin/iris_v4l2_test"
        else
            if [ -x "/data/vendor/iris_test_app/iris_v4l2_test" ]; then
                final_app="/data/vendor/iris_test_app/iris_v4l2_test"
            fi
        fi
    fi
fi

if [ -z "$final_app" ]; then
    log_skip "$TESTNAME SKIP - iris_v4l2_test not available (VIDEO_APP=$VIDEO_APP). Provide --app or install the binary."
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

VIDEO_APP="$final_app"
export VIDEO_APP

# --- Resolve testcase path and cd so outputs land here ---
if ! check_dependencies grep sed awk find sort; then
    log_skip "$TESTNAME SKIP - required tools missing"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"

if ! cd "$test_path"; then
    log_error "cd failed: $test_path"
    printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

# --- New: split logs by flavor, share bundle cache at root ---
LOG_ROOT="./logs_${TESTNAME}"
LOG_DIR="$LOG_ROOT"

if [ -n "$LOG_FLAVOR" ]; then
    LOG_DIR="$LOG_ROOT/$LOG_FLAVOR"
fi

mkdir -p "$LOG_DIR"
export LOG_DIR
export LOG_ROOT

# --- Detect top-level vs sub-run (when --stack both re-execs itself) ---
TOP_LEVEL_RUN="1"
if [ -n "$LOG_FLAVOR" ]; then
    TOP_LEVEL_RUN="0"
fi

# --- Opt-in local media bundle extraction (honored regardless of --config/--dir) ---
if [ -n "$CLIPS_TAR" ]; then
    # destination resolution: explicit --clips-dest > cfg dir > --dir > testcase dir
    clips_dest_resolved="$CLIPS_DEST"
    if [ -z "$clips_dest_resolved" ]; then
        if [ -n "$CFG" ] && [ -f "$CFG" ]; then
            clips_dest_resolved="$(cd "$(dirname "$CFG")" 2>/dev/null && pwd)"
        elif [ -n "$DIR" ] && [ -d "$DIR" ]; then
            clips_dest_resolved="$DIR"
        else
            clips_dest_resolved="$test_path"
        fi
    fi
    mkdir -p "$clips_dest_resolved" 2>/dev/null || true
    video_step "" "Extract custom clips tar → $clips_dest_resolved"
    case "$CLIPS_TAR" in
        *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.zst|*.tar.bz2|*.tbz2)
            if command -v tar >/dev/null 2>&1; then
                tar -xf "$CLIPS_TAR" -C "$clips_dest_resolved" 2>/dev/null || true
            else
                log_warn "tar not available; cannot extract --clips-tar"
            fi
            ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -o "$CLIPS_TAR" -d "$clips_dest_resolved" >/dev/null 2>&1 || true
            else
                log_warn "unzip not available; cannot extract --clips-tar"
            fi
            ;;
        *)
            log_warn "Unrecognized archive type for --clips-tar: $CLIPS_TAR"
            ;;
    esac
fi

# Ensure rootfs meets minimum size (2GiB) BEFORE any downloads — only once
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
    ensure_rootfs_min_size 2
else
    log_info "Sub-run: skipping rootfs size check (already performed)."
fi

# If we're going to fetch, ensure network is online first — only once
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
    if [ "$EXTRACT_INPUT_CLIPS" = "true" ] && [ -z "$CFG" ] && [ -z "$DIR" ] && [ -z "$CLIPS_TAR" ]; then
        net_rc=1

        if command -v check_network_status_rc >/dev/null 2>&1; then
            check_network_status_rc
            net_rc=$?
        elif command -v check_network_status >/dev/null 2>&1; then
            check_network_status >/dev/null 2>&1
            net_rc=$?
        fi

        if [ "$net_rc" -ne 0 ]; then
            video_step "" "Bring network online (Wi-Fi credentials if provided)"
            ensure_network_online || true
            sleep "${NET_STABILIZE_SLEEP:-5}"
        else
            sleep "${NET_STABILIZE_SLEEP:-5}"
        fi
    fi
else
    log_info "Sub-run: skipping initial network bring-up."
fi

# --- Early guard: bail out BEFORE any download if Kodiak-downstream lacks --downstream-fw ---
early_plat="$VIDEO_PLATFORM"
if [ -z "$early_plat" ]; then
    early_plat="$(video_detect_platform)"
fi

early_stack="$(video_normalize_stack "$VIDEO_STACK")"

if [ "$early_plat" = "kodiak" ] && [ "$early_stack" = "downstream" ] && [ -z "${VIDEO_FW_DS:-}" ]; then
    log_skip "On Kodiak, downstream/overlay requires --downstream-fw <file>; skipping run."
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --- Optional early fetch of bundle (best-effort, ALWAYS in LOG_ROOT) — only once
if [ "$TOP_LEVEL_RUN" -eq 1 ]; then
    if [ "$EXTRACT_INPUT_CLIPS" = "true" ] && [ -z "$CFG" ] && [ -z "$DIR" ]; then
        if [ -n "$CLIPS_TAR" ]; then
            log_info "Custom --clips-tar provided; skipping online early fetch."
        else
            video_step "" "Early bundle fetch (best-effort)"

            saved_log_dir="$LOG_DIR"
            LOG_DIR="$LOG_ROOT"
            export LOG_DIR

            if command -v check_network_status_rc >/dev/null 2>&1; then
                if ! check_network_status_rc; then
                    log_info "Network unreachable; skipping early media bundle fetch."
                else
                    extract_tar_from_url "$TAR_URL" || true
                fi
            else
                extract_tar_from_url "$TAR_URL" || true
            fi

            LOG_DIR="$saved_log_dir"
            export LOG_DIR
        fi
    else
        log_info "Skipping early bundle fetch (explicit --config/--dir provided or EXTRACT_INPUT_CLIPS=false)."
    fi
else
    log_info "Sub-run: skipping early bundle fetch."
fi

# --- If user asked for both stacks, re-invoke ourselves for base and overlay ---
if [ "${VIDEO_STACK}" = "both" ]; then
    build_reexec_args() {
        args=""

        if [ -n "${CFG:-}" ]; then
            esc_cfg="$(printf %s "$CFG" | sed "s/'/'\\\\''/g")"
            args="$args --config '$esc_cfg'"
        fi

        if [ -n "${DIR:-}" ]; then
            esc_dir="$(printf %s "$DIR" | sed "s/'/'\\\\''/g")"
            args="$args --dir '$esc_dir'"
        fi

        if [ -n "${PATTERN:-}" ]; then
            esc_pat="$(printf %s "$PATTERN" | sed "s/'/'\\\\''/g")"
            args="$args --pattern '$esc_pat'"
        fi

        if [ -n "${TIMEOUT:-}" ]; then
            args="$args --timeout $(printf %s "$TIMEOUT")"
        fi

        if [ "${STRICT:-0}" -eq 1 ]; then
            args="$args --strict"
        fi

        if [ "${DMESG_SCAN:-1}" -eq 0 ]; then
            args="$args --no-dmesg"
        fi

        if [ -n "${MAX:-}" ] && [ "$MAX" -gt 0 ] 2>/dev/null; then
            args="$args --max $MAX"
        fi

        if [ "${STOP_ON_FAIL:-0}" -eq 1 ]; then
            args="$args --stop-on-fail"
        fi

        if [ -n "${LOGLEVEL:-}" ]; then
            args="$args --loglevel $(printf %s "$LOGLEVEL")"
        fi

        if [ -n "${REPEAT:-}" ]; then
            args="$args --repeat $(printf %s "$REPEAT")"
        fi

        if [ -n "${REPEAT_DELAY:-}" ]; then
            args="$args --repeat-delay $(printf %s "$REPEAT_DELAY")"
        fi

        if [ -n "${REPEAT_POLICY:-}" ]; then
            esc_pol="$(printf %s "$REPEAT_POLICY" | sed "s/'/'\\\\''/g")"
            args="$args --repeat-policy '$esc_pol'"
        fi

        if [ -n "${JUNIT_OUT:-}" ]; then
            esc_junit="$(printf %s "$JUNIT_OUT" | sed "s/'/'\\\\''/g")"
            args="$args --junit '$esc_junit'"
        fi

        if [ "${DRY:-0}" -eq 1 ]; then
            args="$args --dry-run"
        fi

        if [ -n "${EXTRACT_INPUT_CLIPS:-}" ] && [ "$EXTRACT_INPUT_CLIPS" != "true" ]; then
            args="$args --extract-input-clips $(printf %s "$EXTRACT_INPUT_CLIPS")"
        fi

        if [ "${VERBOSE:-0}" -eq 1 ]; then
            args="$args --verbose"
        fi

        if [ -n "${VIDEO_PLATFORM:-}" ]; then
            esc_plat="$(printf %s "$VIDEO_PLATFORM" | sed "s/'/'\\\\''/g")"
            args="$args --platform '$esc_plat'"
        fi

        if [ -n "${VIDEO_FW_DS:-}" ]; then
            esc_fw="$(printf %s "$VIDEO_FW_DS" | sed "s/'/'\\\\''/g")"
            args="$args --downstream-fw '$esc_fw'"
        fi

        if [ "${VIDEO_FORCE:-0}" -eq 1 ]; then
            args="$args --force"
        fi

        if [ -n "${VIDEO_APP:-}" ]; then
            esc_app="$(printf %s "$VIDEO_APP" | sed "s/'/'\\\\''/g")"
            args="$args --app '$esc_app'"
        fi
        
        if [ "$V4L2_COMPLIANCE_RUN" -eq 1 ]; then
            args="$args --v4l2-compliance"
        fi

        if [ -n "${SSID:-}" ]; then
            esc_ssid="$(printf %s "$SSID" | sed "s/'/'\\\\''/g")"
            args="$args --ssid '$esc_ssid'"
        fi

        if [ -n "${PASSWORD:-}" ]; then
            esc_pwd="$(printf %s "$PASSWORD" | sed "s/'/'\\\\''/g")"
            args="$args --password '$esc_pwd'"
        fi

        if [ -n "${APP_LAUNCH_SLEEP:-}" ]; then
            args="$args --app-launch-sleep $(printf %s "$APP_LAUNCH_SLEEP")"
        fi

        if [ -n "${INTER_TEST_SLEEP:-}" ]; then
            args="$args --inter-test-sleep $(printf %s "$INTER_TEST_SLEEP")"
        fi

        # --- Stabilizers passthrough ---
        if [ -n "${RETRY_ON_FAIL:-}" ]; then
            args="$args --retry-on-fail $(printf %s "$RETRY_ON_FAIL")"
        fi
        if [ -n "${POST_TEST_SLEEP:-}" ]; then
            args="$args --post-test-sleep $(printf %s "$POST_TEST_SLEEP")"
        fi

        # --- Media bundle passthrough ---
        if [ -n "${CLIPS_TAR:-}" ]; then
            esc_tar="$(printf %s "$CLIPS_TAR" | sed "s/'/'\\\\''/g")"
            args="$args --clips-tar '$esc_tar'"
        fi
        if [ -n "${CLIPS_DEST:-}" ]; then
            esc_dst="$(printf %s "$CLIPS_DEST" | sed "s/'/'\\\\''/g")"
            args="$args --clips-dest '$esc_dst'"
        fi

        printf "%s" "$args"
    }

    reexec_args="$(build_reexec_args)"

    log_info "[both] starting BASE (upstream) pass"
    # shellcheck disable=SC2086
    sh -c "'$0' --stack base --log-flavor upstream $reexec_args"
    rc_base=$?

    base_res_line=""
    if [ -f "$RES_FILE" ]; then
        base_res_line="$(cat "$RES_FILE" 2>/dev/null || true)"
    fi

    log_info "[both] starting OVERLAY (downstream) pass"
    # shellcheck disable=SC2086
    sh -c "'$0' --stack overlay --log-flavor downstream $reexec_args"
    rc_overlay=$?

    overlay_res_line=""
    if [ -f "$RES_FILE" ]; then
        overlay_res_line="$(cat "$RES_FILE" 2>/dev/null || true)"
    fi

    base_status="$(printf '%s\n' "$base_res_line" | awk '{print $2}')"
    overlay_status="$(printf '%s\n' "$overlay_res_line" | awk '{print $2}')"

    overlay_reason=""
    plat_for_reason="$VIDEO_PLATFORM"
    if [ -z "$plat_for_reason" ]; then
        plat_for_reason="$(video_detect_platform)"
    fi
    if [ "$overlay_status" = "SKIP" ] && [ "$plat_for_reason" = "kodiak" ] && [ -z "${VIDEO_FW_DS:-}" ]; then
        overlay_reason="missing --downstream-fw"
    fi

    if [ "$rc_base" -eq 0 ] && [ "$rc_overlay" -eq 0 ] ; then
        if [ "$base_status" = "PASS" ] && [ "$overlay_status" = "SKIP" ]; then
            if [ -n "$overlay_reason" ]; then
                log_info "[both] upstream/base executed and PASS; downstream/overlay SKIP ($overlay_reason). Overall PASS."
            else
                log_info "[both] upstream/base executed and PASS; downstream/overlay SKIP. Overall PASS."
            fi
        elif [ "$base_status" = "SKIP" ] && [ "$overlay_status" = "PASS" ]; then
            log_info "[both] downstream/overlay executed and PASS; upstream/base SKIP. Overall PASS."
        else
            log_pass "[both] both passes succeeded"
        fi

        printf '%s\n' "$TESTNAME PASS" > "$RES_FILE"
        exit 0
    else
        log_fail "[both] one or more passes failed (base rc=$rc_base, overlay rc=$rc_overlay; base=$base_status overlay=$overlay_status)"
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
fi

log_info "----------------------------------------------------------------------"
log_info "---------------------- Starting $TESTNAME (modular) -------------------"
log_info "STACK=$VIDEO_STACK PLATFORM=${VIDEO_PLATFORM:-auto} STRICT=$STRICT DMESG_SCAN=$DMESG_SCAN"
log_info "TIMEOUT=${TIMEOUT}s LOGLEVEL=$LOGLEVEL REPEAT=$REPEAT REPEAT_POLICY=$REPEAT_POLICY"
log_info "APP=$VIDEO_APP"
if [ -n "$VIDEO_FW_DS" ]; then
    log_info "Downstream FW override: $VIDEO_FW_DS"
fi
if [ -n "$KO_TREE$KO_DIRS$KO_TARBALL" ]; then
    if [ -n "$KO_TREE" ]; then
        log_info "Custom module tree (modprobe -d): $KO_TREE"
    fi
    if [ -n "$KO_DIRS" ]; then
        log_info "Custom ko dir(s): $KO_DIRS (prefer_custom=$KO_PREFER_CUSTOM)"
    fi
fi
if [ -n "$VIDEO_FW_BACKUP_DIR" ]; then
    log_info "FW backup override: $VIDEO_FW_BACKUP_DIR"
fi
if [ "$VERBOSE" -eq 1 ]; then
    log_info "CWD=$(pwd) | SCRIPT_DIR=$SCRIPT_DIR | test_path=$test_path"
fi
log_info "SLEEPS: app-launch=${APP_LAUNCH_SLEEP}s, inter-test=${INTER_TEST_SLEEP}s"

# Warn if not root (module/blacklist ops may fail)
video_warn_if_not_root

# --- Ensure desired video stack (hot switch best-effort) ---
plat="$VIDEO_PLATFORM"
if [ -z "$plat" ]; then
    plat=$(video_detect_platform)
fi
log_info "Detected platform: $plat"

VIDEO_STACK="$(video_normalize_stack "$VIDEO_STACK")"
pre_stack="$(video_stack_status "$plat")"
log_info "Current video stack (pre): $pre_stack"

# Kodiak + upstream → install backup firmware to /lib/firmware before switching
if [ "$plat" = "kodiak" ]; then
    case "$VIDEO_STACK" in
        upstream|up|base)
            video_step "" "Kodiak upstream firmware install"
            video_kodiak_install_firmware || true
            ;;
    esac
fi

# ---- Enforce --downstream-fw on Kodiak when requesting downstream/overlay (SKIP if unmet) ----
if [ "$plat" = "kodiak" ]; then
    case "$VIDEO_STACK" in
        downstream|overlay|down)
            if [ -z "$VIDEO_FW_DS" ] || [ ! -f "$VIDEO_FW_DS" ]; then
                log_skip "On Kodiak, downstream/overlay requires --downstream-fw <file>; skipping run."
                printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi
            ;;
    esac
fi

# --- Optional cleanup: robust capture + normalization of post-stack value ---
video_dump_stack_state "pre"

# --- Custom .ko staging (only if user provided --ko-dir) ---
if [ -n "${KO_DIRS:-}" ]; then
    case "$(video_normalize_stack "$VIDEO_STACK")" in
        downstream|overlay|down)
            KVER="$(uname -r 2>/dev/null || printf '%s' unknown)"

            if command -v video_find_module_file >/dev/null 2>&1; then
                modpath="$(video_find_module_file iris_vpu "$KO_DIRS" 2>/dev/null | tail -n1 | tr -d '\r')"
            else
                modpath=""
            fi

            if [ -n "$modpath" ] && [ -f "$modpath" ]; then
                log_info "Using custom iris_vpu candidate: $modpath"
                if command -v video_ensure_moddir_install >/dev/null 2>&1; then
                    video_ensure_moddir_install "$modpath" "$KVER" >/dev/null 2>&1 || true
                fi
                if command -v depmod >/dev/null 2>&1; then
                    depmod -a "$KVER" >/dev/null 2>&1 || true
                fi
            else
                log_warn "KO_DIRS set, but iris_vpu.ko not found under: $KO_DIRS"
            fi
            ;;
    esac
fi

video_step "" "Apply desired stack = $VIDEO_STACK"

stack_tmp="$LOG_DIR/.ensure_stack.$$.out"
: > "$stack_tmp"

video_ensure_stack "$VIDEO_STACK" "$plat" >"$stack_tmp" 2>&1 || true

if [ -s "$stack_tmp" ]; then
    total_lines="$(wc -l < "$stack_tmp" 2>/dev/null | tr -d ' ')"
    if [ -n "$total_lines" ] && [ "$total_lines" -gt 1 ] 2>/dev/null; then
        head -n $((total_lines - 1)) "$stack_tmp"
    fi
    post_stack="$(tail -n 1 "$stack_tmp" | tr -d '\r')"
else
    post_stack=""
fi

rm -f "$stack_tmp" 2>/dev/null || true

if [ -z "$post_stack" ] || [ "$post_stack" = "unknown" ]; then
    log_warn "Could not fully switch to requested stack=$VIDEO_STACK (platform=$plat). Blacklist updated; reboot may be required."
    post_stack="$(video_stack_status "$plat")"
fi

log_info "Video stack (post): $post_stack"

video_dump_stack_state "post"

# --- Custom .ko load assist (only if user provided --ko-dir) ---
if [ -n "${KO_DIRS:-}" ]; then
    case "$(video_normalize_stack "$VIDEO_STACK")" in
        downstream|overlay|down)
            if ! video_has_module_loaded iris_vpu 2>/dev/null; then
                if command -v video_find_module_file >/dev/null 2>&1; then
                    modpath2="$(video_find_module_file iris_vpu "$KO_DIRS" 2>/dev/null | tail -n1 | tr -d '\r')"
                else
                    modpath2=""
                fi

                if [ "$KO_PREFER_CUSTOM" = "1" ] && [ -n "$modpath2" ] && [ -f "$modpath2" ]; then
                    if command -v video_insmod_with_deps >/dev/null 2>&1; then
                        log_info "Prefer custom: insmod with deps: $modpath2"
                        video_insmod_with_deps "$modpath2" >/dev/null 2>&1 || true
                    fi
                fi
            fi
            ;;
    esac
fi

# Always refresh/prune device nodes (even if no switch occurred)
video_step "" "Refresh V4L device nodes (udev trigger + prune stale)"
video_clean_and_refresh_v4l || true

# --- Hard gate: if requested stack not in effect, abort immediately (platform-aware)
case "$VIDEO_STACK" in
  upstream|up|base)
    if ! video_validate_upstream_loaded "$plat"; then
        case "$plat" in
            lemans|monaco)
                msg="qcom_iris not both present"
                ;;
            kodiak)
                msg="venus_core/dec/enc not all present"
                ;;
            *)
                msg="required upstream modules not present for platform $plat"
                ;;
        esac
        log_fail "[STACK] Upstream requested but $msg; aborting."
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
    ;;
  downstream|overlay|down)
    if ! video_validate_downstream_loaded "$plat"; then
        case "$plat" in
            lemans|monaco)
                msg="iris_vpu missing or qcom_iris still loaded"
                ;;
            kodiak)
                msg="iris_vpu missing or venus_core still loaded"
                ;;
            *)
                msg="required downstream modules not present for platform $plat"
                ;;
        esac
        log_fail "[STACK] Downstream requested but $msg; aborting."
        printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
    ;;
esac

# Per-platform module validation (informational)
case "$plat" in
    lemans|monaco)
        if [ "$post_stack" = "upstream" ]; then
            if video_has_module_loaded qcom_iris && video_has_module_loaded iris_vpu; then
                log_pass "Upstream validated: qcom_iris + iris_vpu present"
            elif video_has_module_loaded qcom_iris && ! video_has_module_loaded iris_vpu; then
                log_pass "Upstream validated: qcom_iris present (pure upstream build)"
            else
                log_warn "Upstream expected but qcom_iris not present"
            fi
        elif [ "$post_stack" = "downstream" ]; then
            if video_has_module_loaded iris_vpu && ! video_has_module_loaded qcom_iris; then
                log_pass "Downstream validated: only iris_vpu present"
            else
                log_warn "Downstream expected but qcom_iris still loaded or iris_vpu missing"
            fi
        fi
        ;;
    kodiak)
        if [ "$post_stack" = "upstream" ]; then
            if video_has_module_loaded venus_core && video_has_module_loaded venus_dec && video_has_module_loaded venus_enc; then
                log_pass "Upstream validated: venus_core/dec/enc present"
            elif video_has_module_loaded qcom_iris && ! video_has_module_loaded iris_vpu; then
                log_pass "Upstream validated: qcom_iris present (pure upstream build on Kodiak)"
            else
                log_warn "Upstream expected but neither Venus trio nor pure qcom_iris path validated"
            fi
        elif [ "$post_stack" = "downstream" ]; then
            if video_has_module_loaded iris_vpu; then
                log_pass "Downstream validated: iris_vpu present (Kodiak)"
            else
                log_warn "Downstream expected but iris_vpu not present (Kodiak)"
            fi
        fi
        ;;
    *)
        log_warn "Unknown platform; skipping strict module validation"
        ;;
esac

# Validate numeric loglevel
case "$LOGLEVEL" in
    ''|*[!0-9]* )
        log_warn "Non-numeric --loglevel '$LOGLEVEL'; using 15"
        LOGLEVEL=15
        ;;
esac

# --- Discover config list ---
CFG_LIST="$LOG_DIR/.cfgs"
: > "$CFG_LIST"

if [ -n "$CFG" ] && [ -d "$CFG" ]; then
    DIR="$CFG"
    CFG=""
fi

if [ -z "$CFG" ]; then
    if [ -n "$DIR" ]; then
        base_dir="$DIR"
        if [ -n "$PATTERN" ]; then
            find "$base_dir" -type f -name "$PATTERN" 2>/dev/null | sort > "$CFG_LIST"
        else
            find "$base_dir" -type f -name "*.json" 2>/dev/null | sort > "$CFG_LIST"
        fi
        log_info "Using custom config directory: $base_dir"
    else
        log_info "No --config passed, searching for JSON under testcase dir: $test_path"
        find "$test_path" -type f -name "*.json" 2>/dev/null | sort > "$CFG_LIST"
    fi
else
    printf '%s\n' "$CFG" > "$CFG_LIST"
fi

if [ ! -s "$CFG_LIST" ]; then
    log_skip "$TESTNAME SKIP - no JSON configs found"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

cfg_count="$(wc -l < "$CFG_LIST" 2>/dev/null | tr -d ' ')"
log_info "Discovered $cfg_count JSON config(s) to run"

# --- JUnit prep / results files ---
JUNIT_TMP="$LOG_DIR/.junit_cases.xml"
: > "$JUNIT_TMP"

printf '%s\n' "mode,id,result,name,elapsed,pass_runs,fail_runs" > "$LOG_DIR/results.csv"
: > "$LOG_DIR/summary.txt"

# --- Suite loop ---
total="0"
pass="0"
fail="0"
skip="0"
suite_rc="0"
first_case="1"

while IFS= read -r cfg; do
    if [ -z "$cfg" ]; then
        continue
    fi

    # Inter-test pause (skip before the very first case)
    if [ "$first_case" -eq 0 ] 2>/dev/null; then
        case "$INTER_TEST_SLEEP" in
            ''|*[!0-9]* )
                :
                ;;
            0)
                :
                ;;
            *)
                log_info "Inter-test sleep ${INTER_TEST_SLEEP}s"
                sleep "$INTER_TEST_SLEEP"
                ;;
        esac
    fi
    first_case="0"

    total=$((total + 1))

    if video_is_decode_cfg "$cfg"; then
        mode="decode"
    else
        mode="encode"
    fi

    name_and_id="$(video_pretty_name_from_cfg "$cfg")"
    pretty="$(printf '%s' "$name_and_id" | cut -d'|' -f1)"
    raw_codec="$(video_guess_codec_from_cfg "$cfg")"
    codec="$(video_canon_codec "$raw_codec")"
    safe_codec="$(printf '%s' "$codec" | tr ' /' '__')"
    base_noext="$(basename "$cfg" .json)"
    id="${mode}-${safe_codec}-${base_noext}"

    log_info "----------------------------------------------------------------------"
    log_info "[$id] START — mode=$mode codec=$codec name=\"$pretty\" cfg=\"$cfg\""

    video_step "$id" "Check /dev/video* presence"
    if ! video_devices_present; then
        log_skip "[$id] SKIP - no /dev/video* nodes"
        printf '%s\n' "$id SKIP $pretty" >> "$LOG_DIR/summary.txt"
        printf '%s\n' "$mode,$id,SKIP,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        skip=$((skip + 1))
        continue
    fi

    # Fetch only when not explicitly provided a config/dir and feature enabled
    if [ "$EXTRACT_INPUT_CLIPS" = "true" ] && [ -z "$CFG" ] && [ -z "$DIR" ]; then
        if [ -n "$CLIPS_TAR" ]; then
            log_info "[$id] Custom --clips-tar provided; skipping online per-test fetch."
            ce=0
        else
            video_step "$id" "Ensure clips present or fetch"

            saved_log_dir_case="$LOG_DIR"
            LOG_DIR="$LOG_ROOT"
            export LOG_DIR

            video_ensure_clips_present_or_fetch "$cfg" "$TAR_URL"
            ce=$?

            LOG_DIR="$saved_log_dir_case"
            export LOG_DIR

            # Map generic download errors to "offline" if link just flapped
            if [ "$ce" -eq 1 ] 2>/dev/null; then
                sleep "${NET_STABILIZE_SLEEP:-5}"

                if command -v check_network_status_rc >/dev/null 2>&1; then
                    if ! check_network_status_rc; then
                        ce=2
                    fi
                elif command -v check_network_status >/dev/null 2>&1; then
                    if ! check_network_status >/dev/null 2>&1; then
                        ce=2
                    fi
                fi
            fi

            if [ "$ce" -eq 2 ] 2>/dev/null; then
                if [ "$mode" = "decode" ]; then
                    log_skip "[$id] SKIP - offline and clips missing (decode case)"
                    printf '%s\n' "$id SKIP $pretty" >> "$LOG_DIR/summary.txt"
                    printf '%s\n' "$mode,$id,SKIP,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
                    skip=$((skip + 1))
                    continue
                fi
            elif [ "$ce" -eq 1 ] 2>/dev/null; then
                log_fail "[$id] FAIL - fetch/extract failed while online"
                printf '%s\n' "$id FAIL $pretty" >> "$LOG_DIR/summary.txt"
                printf '%s\n' "$mode,$id,FAIL,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
                fail=$((fail + 1))
                suite_rc=1

                if [ "$STOP_ON_FAIL" -eq 1 ]; then
                    break
                fi

                continue
            fi
        fi
    else
        log_info "[$id] Fetch disabled (explicit --config/--dir)."
    fi

    # Strict clip existence check after optional fetch
    video_step "$id" "Verify required clips exist"
    missing_case="0"
    clips_file="$LOG_DIR/.clips.$$"

    video_extract_input_clips "$cfg" > "$clips_file"

    if [ -s "$clips_file" ]; then
        while IFS= read -r pth; do
            if [ -z "$pth" ]; then
                continue
            fi

            case "$pth" in
                /*)
                    abs="$pth"
                    ;;
                *)
                    abs="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)/$pth"
                    ;;
            esac

            if [ ! -f "$abs" ]; then
                missing_case=1
            fi
        done < "$clips_file"
    fi

    rm -f "$clips_file" 2>/dev/null || true

    if [ "$missing_case" -eq 1 ] 2>/dev/null; then
        log_fail "[$id] Required input clip(s) not present — $pretty"
        printf '%s\n' "$id FAIL $pretty" >> "$LOG_DIR/summary.txt"
        printf '%s\n' "$mode,$id,FAIL,$pretty,$elapsed,0,0" >> "$LOG_DIR/results.csv"
        fail=$((fail + 1))
        suite_rc=1

        if [ "$STOP_ON_FAIL" -eq 1 ]; then
            break
        fi

        continue
    fi

    if [ "$DRY" -eq 1 ]; then
        video_step "$id" "DRY RUN - print command"
        log_info "[dry] [$id] $VIDEO_APP --config \"$cfg\" --loglevel $LOGLEVEL — $pretty"
        printf '%s\n' "$id DRY-RUN $pretty" >> "$LOG_DIR/summary.txt"
        printf '%s\n' "$mode,$id,DRY-RUN,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        continue
    fi

    pass_runs="0"
    fail_runs="0"
    rep="1"
    start_case="$(date +%s 2>/dev/null || printf '%s' 0)"
    logf="$LOG_DIR/${id}.log"

    while [ "$rep" -le "$REPEAT" ]; do
        if [ "$REPEAT" -gt 1 ]; then
            log_info "[$id] repeat $rep/$REPEAT — $pretty"
        fi

        video_step "$id" "Execute app"
        log_info "[$id] CMD: $VIDEO_APP --config \"$cfg\" --loglevel $LOGLEVEL"

        case "$APP_LAUNCH_SLEEP" in
            ''|*[!0-9]* )
                :
                ;;
            0)
                :
                ;;
            *)
                log_info "[$id] pre-launch sleep ${APP_LAUNCH_SLEEP}s"
                sleep "$APP_LAUNCH_SLEEP"
                ;;
        esac

        if video_run_once "$cfg" "$logf" "$TIMEOUT" "$SUCCESS_RE" "$LOGLEVEL"; then
            pass_runs=$((pass_runs + 1))
        else
            rc_val="$(awk -F'=' '/^END-RUN rc=/{print $2}' "$logf" 2>/dev/null | tail -n1 | tr -d ' ')"
            if [ -n "$rc_val" ] 2>/dev/null; then
                case "$rc_val" in
                    139) log_warn "[$id] App exited rc=139 (SIGSEGV)." ;;
                    134) log_warn "[$id] App exited rc=134 (SIGABRT)." ;;
                    137) log_warn "[$id] App exited rc=137 (SIGKILL/OOM?)." ;;
                    *) : ;;
                esac
            fi
            fail_runs=$((fail_runs + 1))
        fi

        if [ "$rep" -lt "$REPEAT" ] && [ "$REPEAT_DELAY" -gt 0 ]; then
            sleep "$REPEAT_DELAY"
        fi

        rep=$((rep + 1))
    done

    end_case="$(date +%s 2>/dev/null || printf '%s' 0)"
    elapsed=$((end_case - start_case))
    if [ "$elapsed" -lt 0 ] 2>/dev/null; then
        elapsed=0
    fi

    final="FAIL"
    case "$REPEAT_POLICY" in
        any)
            if [ "$pass_runs" -ge 1 ]; then
                final="PASS"
            fi
            ;;
        all|*)
            if [ "$fail_runs" -eq 0 ]; then
                final="PASS"
            fi
            ;;
    esac

    video_step "$id" "DMESG triage"
    video_scan_dmesg_if_enabled "$DMESG_SCAN" "$LOG_DIR"
    dmesg_rc=$?

    if [ "$dmesg_rc" -eq 0 ]; then
        log_warn "[$id] dmesg reported errors (STRICT=$STRICT)"
        if [ "$STRICT" -eq 1 ]; then
            final="FAIL"
        fi
    fi

    # (2) Retry on final failure (extra attempts outside REPEAT loop, before recording results)
    if [ "$final" = "FAIL" ] && [ "$RETRY_ON_FAIL" -gt 0 ] 2>/dev/null; then
        r=1
        log_info "[$id] RETRY_ON_FAIL: up to $RETRY_ON_FAIL additional attempt(s)"
        while [ "$r" -le "$RETRY_ON_FAIL" ]; do
            if [ "$REPEAT_DELAY" -gt 0 ] 2>/dev/null; then
                sleep "$REPEAT_DELAY"
            fi

            log_info "[$id] retry attempt $r/$RETRY_ON_FAIL"
            if video_run_once "$cfg" "$logf" "$TIMEOUT" "$SUCCESS_RE" "$LOGLEVEL"; then
                pass_runs=$((pass_runs + 1))
                final="PASS"
                log_pass "[$id] RETRY succeeded — marking PASS"
                break
            else
                rc_val="$(awk -F'=' '/^END-RUN rc=/{print $2}' "$logf" 2>/dev/null | tail -n1 | tr -d ' ')"
                if [ -n "$rc_val" ]; then
                    case "$rc_val" in
                        139) log_warn "[$id] Retry exited rc=139 (SIGSEGV)." ;;
                        134) log_warn "[$id] Retry exited rc=134 (SIGABORT)." ;;
                        137) log_warn "[$id] Retry exited rc=137 (SIGKILL/OOM?)." ;;
                        *) : ;;
                    esac
                fi
            fi
            r=$((r + 1))
        done
    fi

    {
        printf 'RESULT id=%s mode=%s pretty="%s" final=%s pass_runs=%s fail_runs=%s elapsed=%s\n' \
            "$id" "$mode" "$pretty" "$final" "$pass_runs" "$fail_runs" "$elapsed"
    } >> "$logf" 2>&1

    video_junit_append_case "$JUNIT_TMP" "Video.$mode" "$pretty" "$elapsed" "$final" "$logf"

    case "$final" in
        PASS)
            log_pass "[$id] PASS ($pass_runs/$REPEAT ok) — $pretty"
            ;;
        FAIL)
            log_fail "[$id] FAIL (pass=$pass_runs fail=$fail_runs) — $pretty"
            ;;
        SKIP)
            log_skip "[$id] SKIP — $pretty"
            ;;
    esac

    printf '%s\n' "$id $final $pretty" >> "$LOG_DIR/summary.txt"
    printf '%s\n' "$mode,$id,$final,$pretty,$elapsed,$pass_runs,$fail_runs" >> "$LOG_DIR/results.csv"

    if [ "$final" = "PASS" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        suite_rc=1

        if [ "$STOP_ON_FAIL" -eq 1 ]; then
            break
        fi
    fi

    case "$POST_TEST_SLEEP" in
        ''|*[!0-9]* )
            :
            ;;
        0) : ;;
        *) log_info "Post-test sleep ${POST_TEST_SLEEP}s"; sleep "$POST_TEST_SLEEP" ;;
    esac

    if [ "$MAX" -gt 0 ] && [ "$total" -ge "$MAX" ]; then
        log_info "Reached MAX=$MAX tests; stopping"
        break
    fi
done < "$CFG_LIST"

# ======================================================================
# --- V4L2 Compliance (Decoder & Encoder) ---
# ======================================================================
if [ "$V4L2_COMPLIANCE_RUN" -eq 1 ]; then
    log_info "----------------------------------------------------------------------"
    log_info "Starting V4L2 Compliance Tests (Streaming Enabled)"

    V4L2_BIN="$(command -v v4l2-compliance || echo "/usr/bin/v4l2-compliance")"

    if [ ! -x "$V4L2_BIN" ]; then
        log_warn "v4l2-compliance binary not found at $V4L2_BIN; skipping compliance tests."
    else
        # --- 1. Find an H.264 media file from the test suite ---
        h264_media_file=""
        h264_cfg_file=""

        # Find a decode config for H.264 that was processed
        if [ -s "$CFG_LIST" ]; then
            while IFS= read -r cfg_path; do
                raw_codec="$(video_guess_codec_from_cfg "$cfg_path")"
                canon_codec="$(video_canon_codec "$raw_codec")"
                is_decode=$(video_is_decode_cfg "$cfg_path" && echo "yes" || echo "no")

                if [ "$is_decode" = "yes" ] && [ "$canon_codec" = "h264" ]; then
                    h264_cfg_file="$cfg_path"
                    break
                fi
            done < "$CFG_LIST"
        fi

        if [ -n "$h264_cfg_file" ]; then
            log_info "Found H.264 config file: $h264_cfg_file"
            relative_clip_path=$(video_extract_input_clips "$h264_cfg_file" | head -n 1)

            if [ -n "$relative_clip_path" ]; then
                cfg_dir="$(cd "$(dirname "$h264_cfg_file")" 2>/dev/null && pwd)"
                abs_clip_path="$cfg_dir/$relative_clip_path"

                if [ -f "$abs_clip_path" ]; then
                    h264_media_file="$abs_clip_path"
                    log_info "Found H.264 media for compliance test: $h264_media_file"
                else
                    log_warn "Media file '$abs_clip_path' from JSON does not exist."
                fi
            fi
        else
            log_warn "Could not find a processed H.264 decode config in the suite, will search manually."
        fi
        
        # Fallback search
        if [ -z "$h264_media_file" ]; then
            log_info "Falling back to searching for any .264 media file."
            search_dirs="${CLIPS_DEST:-} ${test_path:-} ${DIR:-} ."
            for d in $search_dirs; do
                if [ -n "$d" ] && [ -d "$d" ]; then
                    found=$(find "$d" -name "*.264" 2>/dev/null | head -n 1)
                    if [ -n "$found" ]; then
                        h264_media_file="$found"
                        break
                    fi
                fi
            done
        fi

        # --- 2. Run Decoder Compliance ---
        total=$((total + 1))
        if [ -n "$h264_media_file" ]; then
            log_info "Compliance Media: $h264_media_file"
            log_info "Running Decoder Compliance on /dev/video0 (Stream)"
            comp_dec_log="$LOG_DIR/compliance_decoder.log"
            
            # --- EXECUTE TEST & CAPTURE LOGS ---
            "$V4L2_BIN" -d /dev/video0 -s5 --stream-from="$h264_media_file" > "$comp_dec_log" 2>&1
            rc_dec=$?
            
            # --- PRINT DETAILED LOGS TO CONSOLE ---
            log_info ">>> DETAILED DECODER COMPLIANCE LOGS START >>>"
            cat "$comp_dec_log"
            log_info "<<< DETAILED DECODER COMPLIANCE LOGS END <<<"

            if [ "$rc_dec" -eq 0 ]; then
                log_pass "V4L2 Decoder Compliance (video0) PASS"
                pass=$((pass + 1))
                printf '%s\n' "compliance-dec PASS" >> "$LOG_DIR/summary.txt"
            else
                log_fail "V4L2 Decoder Compliance (video0) FAIL"
                fail=$((fail + 1))
                suite_rc=1
                printf '%s\n' "compliance-dec FAIL" >> "$LOG_DIR/summary.txt"
            fi
        else
            log_warn "No .264 media file found; skipping Decoder Compliance streaming test."
            skip=$((skip + 1))
            printf '%s\n' "compliance-dec SKIP" >> "$LOG_DIR/summary.txt"
        fi

        # --- 3. Run Encoder Compliance ---
        total=$((total + 1))
        log_info "Running Encoder Compliance on /dev/video1 (Stream)"
        comp_enc_log="$LOG_DIR/compliance_encoder.log"
        
        # --- EXECUTE TEST & CAPTURE LOGS ---
        "$V4L2_BIN" -d /dev/video1 -s5 > "$comp_enc_log" 2>&1
        rc_enc=$?

        # --- PRINT DETAILED LOGS TO CONSOLE ---
        log_info ">>> DETAILED ENCODER COMPLIANCE LOGS START >>>"
        cat "$comp_enc_log"
        log_info "<<< DETAILED ENCODER COMPLIANCE LOGS END <<<"

        if [ "$rc_enc" -eq 0 ]; then
            log_pass "V4L2 Encoder Compliance (video1) PASS"
            pass=$((pass + 1))
            printf '%s\n' "compliance-enc PASS" >> "$LOG_DIR/summary.txt"
        else
            log_fail "V4L2 Encoder Compliance (video1) FAIL"
            fail=$((fail + 1))
            suite_rc=1
            printf '%s\n' "compliance-enc FAIL" >> "$LOG_DIR/summary.txt"
        fi
    fi

    # ======================================================================
    # --- Custom v4l2-ctl Tests (Decoder & Encoder) ---
    # ======================================================================
    log_info "----------------------------------------------------------------------"
    log_info "Starting Custom v4l2-ctl Tests"

    # Helper to find media files based on extension and optional string pattern
    find_media_for_test() {
        local ext="$1"
        local pattern="${2:-}"
        local search_dirs="${CLIPS_DEST:-} ${test_path:-} ${DIR:-} ."
        
        for d in $search_dirs; do
            if [ -n "$d" ] && [ -d "$d" ]; then
                if [ -n "$pattern" ]; then
                    found=$(find "$d" -name "*${pattern}*.${ext}" 2>/dev/null | head -n 1)
                else
                    found=$(find "$d" -name "*.${ext}" 2>/dev/null | head -n 1)
                fi
                if [ -n "$found" ]; then
                    echo "$found"
                    return 0
                fi
            fi
        done
        echo ""
    }

    # --- Decoder v4l2-ctl tests ---
    log_info "--- Decoder v4l2-ctl tests ---"

    # 1. Decoder H264
    dec_h264_clip=$(find_media_for_test "264" "")
    if [ -z "$dec_h264_clip" ]; then dec_h264_clip=$(find_media_for_test "h264" ""); fi
    
    if [ -n "$dec_h264_clip" ]; then
        log_info "Testing Decoder H264 with: $dec_h264_clip"
        v4l2-ctl --verbose --set-fmt-video-out=pixelformat=H264 --set-fmt-video=pixelformat=NV12 --stream-mmap --stream-out-mmap --stream-from "$dec_h264_clip" --stream-to=/tmp/v4l2_h264_to_nv12_decoder_output.yuv -d /dev/video0
    else
        log_warn "Skipping Decoder H264: No .264/.h264 clip found"
    fi

    # 2. Decoder HEVC
    dec_hevc_clip=$(find_media_for_test "265" "")
    if [ -z "$dec_hevc_clip" ]; then dec_hevc_clip=$(find_media_for_test "hevc" ""); fi
    
    if [ -n "$dec_hevc_clip" ]; then
        log_info "Testing Decoder HEVC with: $dec_hevc_clip"
        v4l2-ctl --verbose --set-fmt-video-out=pixelformat=HEVC --set-fmt-video=pixelformat=NV12 --stream-mmap --stream-out-mmap --stream-from="$dec_hevc_clip" --stream-to=/tmp/v4l2_hevc_to_nv12_decoder_output.yuv -d /dev/video0
    else
        log_warn "Skipping Decoder HEVC: No .265/.hevc clip found"
    fi

    # 3. Decoder VP9
    dec_vp9_clip=$(find_media_for_test "vp9" "")
    if [ -z "$dec_vp9_clip" ]; then dec_vp9_clip=$(find_media_for_test "ivf" ""); fi
    
    if [ -n "$dec_vp9_clip" ]; then
        log_info "Testing Decoder VP9 with: $dec_vp9_clip"
        v4l2-ctl --verbose --set-fmt-video-out=pixelformat=VP90 --set-fmt-video=pixelformat=NV12 --stream-mmap --stream-out-mmap --stream-from-hdr="$dec_vp9_clip" --stream-mmap --stream-to=/tmp/v4l2_vp9_to_nv12_decoder_output.yuv -d /dev/video0
    else
        log_warn "Skipping Decoder VP9: No .vp9/.ivf clip found"
    fi


    # --- Encoder v4l2-ctl tests ---
    log_info "--- Encoder v4l2-ctl tests ---"

    # Helper for Encoder: Find raw input (NV12/YUV) matching resolution or fallback
    # Note: v4l2-ctl encoding requires raw YUV/NV12 input. We search for .yuv or .nv12.
    find_raw_clip() {
        local w="$1"
        local h="$2"
        # Try to find a file with width/height in the name, e.g., "1920x1080" or "1080p"
        local match=$(find_media_for_test "yuv" "${w}x${h}")
        if [ -z "$match" ]; then match=$(find_media_for_test "nv12" "${w}x${h}"); fi
        if [ -z "$match" ]; then match=$(find_media_for_test "yuv" "${h}p"); fi
        
        # Fallback: Just return any YUV if not found (Command might fail on size mismatch, but we try)
        if [ -z "$match" ]; then 
            match=$(find_media_for_test "yuv" "")
            if [ -n "$match" ]; then log_warn "Exact resolution ${w}x${h} raw clip not found, using generic: $match"; fi
        fi
        echo "$match"
    }

    # H264 Encoder Tests
    # 1080p
    raw_1080=$(find_raw_clip "1920" "1080")
    if [ -n "$raw_1080" ]; then
        log_info "Enc H264 1080p using: $raw_1080"
        v4l2-ctl --verbose --set-fmt-video-out=width=1920,height=1080,pixelformat=NV12 --set-selection-output target=crop,top=0,left=0,width=1920,height=1080 --set-fmt-video=pixelformat=H264 --stream-mmap --stream-out-mmap --stream-from="$raw_1080" --stream-to=/tmp/Big_Buck_Bunny_1080_10s.h264 -d /dev/video1
    fi

    # 720p
    raw_720=$(find_raw_clip "1280" "720")
    if [ -n "$raw_720" ]; then
        log_info "Enc H264 720p using: $raw_720"
        v4l2-ctl --verbose --set-fmt-video-out=width=1280,height=720,pixelformat=NV12 --set-selection-output target=crop,top=0,left=0,width=1280,height=720 --set-fmt-video=pixelformat=H264 --stream-mmap --stream-out-mmap --stream-from="$raw_720" --stream-to=/tmp/cyclists_1280x720_92frames.h264 -d /dev/video1
    fi

    # 640x480
    raw_480=$(find_raw_clip "640" "480")
    if [ -n "$raw_480" ]; then
        log_info "Enc H264 480p using: $raw_480"
        v4l2-ctl --verbose --set-fmt-video-out=width=640,height=480,pixelformat=NV12 --set-selection-output target=crop,top=0,left=0,width=640,height=480 --set-fmt-video=pixelformat=H264 --stream-mmap --stream-out-mmap --stream-from="$raw_480" --stream-to=/tmp/jets_640x480_20frames.h264 -d /dev/video1
    fi

    # 352x288
    raw_288=$(find_raw_clip "352" "288")
    if [ -n "$raw_288" ]; then
        log_info "Enc H264 288p using: $raw_288"
        v4l2-ctl --verbose --set-fmt-video-out=width=352,height=288,pixelformat=NV12 --set-selection-output target=crop,top=0,left=0,width=352,height=288 --set-fmt-video=pixelformat=H264 --stream-mmap --stream-out-mmap --stream-from="$raw_288" --stream-to=/tmp/foreman_352x288_20frames.h264 -d /dev/video1
    fi

    # HEVC Encoder Tests
    # 1080p
    if [ -n "$raw_1080" ]; then
        log_info "Enc HEVC 1080p using: $raw_1080"
        v4l2-ctl --verbose --set-fmt-video-out=width=1920,height=1080,pixelformat=NV12 --set-selection-output target=crop,top=0,left=0,width=1920,height=1080 --set-fmt-video=pixelformat=HEVC --stream-mmap --stream-out-mmap --stream-from="$raw_1080" --stream-to=/tmp/Big_Buck_Bunny_1080_10s.hevc -d /dev/video1
    fi

    # 720p
    if [ -n "$raw_720" ]; then
        log_info "Enc HEVC 720p using: $raw_720"
        v4l2-ctl --verbose --set-fmt-video-out=width=1280,height=720,pixelformat=NV12 --set-selection-output target=crop,top=0,left=0,width=1280,height=720 --set-fmt-video=pixelformat=HEVC --stream-mmap --stream-out-mmap --stream-from="$raw_720" --stream-to=/tmp/cyclists_1280x720_92frames.hevc -d /dev/video1
    fi

    # 640x480
    if [ -n "$raw_480" ]; then
        log_info "Enc HEVC 480p using: $raw_480"
        v4l2-ctl --verbose --set-fmt-video-out=width=640,height=480,pixelformat=NV12 --set-selection-output target=crop,top=0,left=0,width=640,height=480 --set-fmt-video=pixelformat=HEVC --stream-mmap --stream-out-mmap --stream-from="$raw_480" --stream-to=/tmp/jets_640x480_20frames.hevc -d /dev/video1
    fi

    # 352x288
    if [ -n "$raw_288" ]; then
        log_info "Enc HEVC 288p using: $raw_288"
        v4l2-ctl --verbose --set-fmt-video-out=width=352,height=288,pixelformat=NV12 --set-selection-output target=crop,top=0,left=0,width=352,height=288 --set-fmt-video=pixelformat=HEVC --stream-mmap --stream-out-mmap --stream-from="$raw_288" --stream-to=/tmp/foreman_352x288_20frames.hevc -d /dev/video1
    fi

else
    log_info "Skipping V4L2 Compliance Tests (use --v4l2-compliance to enable)"
fi

log_info "Summary: total=$total pass=$pass fail=$fail skip=$skip"


# --- End-of-run detailed per-test results ---
if [ -s "$LOG_DIR/summary.txt" ]; then
    log_info "----------------------------------------------------------------------"
    log_info "Per-test results (id result):"
    while IFS= read -r line; do
        id_field=$(printf '%s\n' "$line" | awk '{print $1}')
        res_field=$(printf '%s\n' "$line" | awk '{print $2}')
        if [ -n "$id_field" ] && [ -n "$res_field" ]; then
            log_info "$id_field $res_field"
        fi
    done < "$LOG_DIR/summary.txt"
fi

# --- Aggregate breakdown by mode/codec ---
if [ -s "$LOG_DIR/results.csv" ]; then
    log_info "----------------------------------------------------------------------"
    log_info "Mode/codec breakdown (total/pass/fail/skip):"
    awk -F',' 'NR>1 {
        id=$2; res=$3;
        split(id,a,"-"); mode=a[1]; codec=a[2];
        key=mode "-" codec;
        total[key]++
        if (res=="PASS") pass[key]++
        else if (res=="FAIL") fail[key]++
        else if (res=="SKIP") skip[key]++
    }
    END {
        for (k in total) {
            printf " %s: total=%d pass=%d fail=%d skip=%d\n", k, total[k], pass[k]+0, fail[k]+0, skip[k]+0
        }
    }' "$LOG_DIR/results.csv" | while IFS= read -r ln; do
        if [ -n "$ln" ]; then
            log_info "$ln"
        fi
    done
fi

# --- JUnit finalize ---
if [ -n "$JUNIT_OUT" ]; then
    tests=$((pass + fail + skip))
    failures="$fail"
    skipped="$skip"

    {
        printf '<testsuite name="%s" tests="%s" failures="%s" skipped="%s">\n' "$TESTNAME" "$tests" "$failures" "$skipped"
        cat "$JUNIT_TMP"
        # Manually add compliance test results to JUnit if needed
    } > "$JUNIT_OUT"

    log_info "Wrote JUnit: $JUNIT_OUT"
fi

# Overall suite result (single-stack path):
# If ALL testcases were skipped (pass=0, fail=0, skip>0) => overall SKIP.
# Otherwise: suite_rc==0 -> PASS, else FAIL.
if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ] && [ "$skip" -gt 0 ]; then
    log_skip "$TESTNAME: SKIP (all $skip test(s) skipped)"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ "$suite_rc" -eq 0 ] 2>/dev/null; then
    log_pass "$TESTNAME: PASS"
    printf '%s\n' "$TESTNAME PASS" >"$RES_FILE"
    exit 0
else
    log_fail "$TESTNAME: FAIL"
    printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

exit "$suite_rc"