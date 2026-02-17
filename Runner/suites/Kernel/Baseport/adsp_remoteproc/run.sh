#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="adsp_remoteproc"
RES_FILE="./$TESTNAME.res"
FW="adsp"

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"
log_info "=== Test Initialization ==="

# --- Tunables (override via env) ----------------------------------------------
STOP_TO="${STOP_TO:-10}" # remoteproc stop timeout (s)
START_TO="${START_TO:-10}" # remoteproc start timeout (s)
POLL_I="${POLL_I:-1}" # state poll interval (s)
PRE_STOP_DELAY="${PRE_STOP_DELAY:-30}" # FIXED delay before stopping ADSP (seconds)
FATAL_ON_UNSUSPENDED="${FATAL_ON_UNSUSPENDED:-0}" # 1 = abort if audio not suspended/unsupported after delay

# --- CLI ----------------------------------------------------------------------
# Default: do NOT do SSR (stop/start). Enable explicitly with --ssr
DO_SSR=0

usage() {
    echo "Usage: $0 [--ssr] [--pre-stop-delay SEC] [--fatal-on-unsuspended] [--stop-to SEC] [--start-to SEC] [--poll-i SEC]" >&2
    echo " --ssr Perform ADSP stop/start (SSR). Default: OFF" >&2
    echo " --pre-stop-delay SEC Delay before stop when --ssr is used (default: $PRE_STOP_DELAY)" >&2
    echo " --fatal-on-unsuspended Abort if audio not suspended/unsupported after delay (only meaningful with --ssr)" >&2
    echo " --stop-to SEC Stop timeout (default: $STOP_TO)" >&2
    echo " --start-to SEC Start timeout (default: $START_TO)" >&2
    echo " --poll-i SEC Poll interval (default: $POLL_I)" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ssr)
            DO_SSR=1
            shift
            ;;
        --pre-stop-delay)
            if [ $# -lt 2 ]; then
                log_fail "Missing value for --pre-stop-delay"
                usage
                exit 2
            fi
            PRE_STOP_DELAY="$2"
            shift 2
            ;;
        --fatal-on-unsuspended)
            FATAL_ON_UNSUSPENDED=1
            shift
            ;;
        --stop-to)
            if [ $# -lt 2 ]; then
                log_fail "Missing value for --stop-to"
                usage
                exit 2
            fi
            STOP_TO="$2"
            shift 2
            ;;
        --start-to)
            if [ $# -lt 2 ]; then
                log_fail "Missing value for --start-to"
                usage
                exit 2
            fi
            START_TO="$2"
            shift 2
            ;;
        --poll-i)
            if [ $# -lt 2 ]; then
                log_fail "Missing value for --poll-i"
                usage
                exit 2
            fi
            POLL_I="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
done

log_info "Tunables: STOP_TO=$STOP_TO START_TO=$START_TO POLL_I=$POLL_I PRE_STOP_DELAY=$PRE_STOP_DELAY FATAL_ON_UNSUSPENDED=$FATAL_ON_UNSUSPENDED"
log_info "SSR control: DO_SSR=$DO_SSR (0=no stop/start, 1=do stop/start)"

# --- Audio readiness snapshot (no hardcoding, no long wait) -------------------
# Discovers a bound snd*/snd-soc* driver, logs module once, collects nodes to check.
# Sets globals:
# CHECK_NODES="list of .../power/runtime_status files"
# AUDIO_PM_SNAPSHOT_OK=1/0 (current sample)
discover_audio_stack_and_snapshot() {
    DRIVERS_BASE="/sys/bus/platform/drivers"
    log_info "Validating audio stack readiness before ADSP test..."
    log_info "Scanning for platform audio driver (module -> bound -> suspend snapshot)..."

    platform_drv=""
    platform_mod=""
    for drvdir in "$DRIVERS_BASE"/snd-* "$DRIVERS_BASE"/snd-soc-*; do
        [ -d "$drvdir" ] || continue
        [ -L "$drvdir/sound" ] || continue
        platform_drv="$(basename "$drvdir")"
        if [ -L "$drvdir/module" ]; then
            platform_mod="$(basename "$(readlink -f "$drvdir/module")")"
        else
            platform_mod=""
        fi
        break
    done

    CHECK_NODES=""
    if [ -z "$platform_drv" ]; then
        log_warn "No suitable platform audio driver found (module+bound); skipping suspend snapshot"
        AUDIO_PM_SNAPSHOT_OK=1
        return 0
    fi

    if [ -n "$platform_mod" ]; then
        if check_driver_loaded "$platform_mod" >/dev/null 2>&1; then
            log_pass "Driver/module '$platform_mod' is loaded"
        elif [ -d "/sys/module/$platform_mod" ]; then
            log_info "Module '$platform_mod' appears built-in"
        else
            log_warn "Module '$platform_mod' not present; proceeding (driver bound)"
        fi
    else
        log_info "No 'module' symlink for $platform_drv; assuming built-in/platform driver"
    fi

    log_info "Using bound audio driver: $platform_drv${platform_mod:+ (module: $platform_mod)}"
    TARGET_PATH="$DRIVERS_BASE/$platform_drv/sound"

    # 1) Platform sound root + immediate children (collect runtime_status files)
    if [ -d "$TARGET_PATH" ]; then
        _rt_nodes_list="$(mktemp)"
        find "$TARGET_PATH" -maxdepth 2 -type f -path "*/power/runtime_status" \
            -exec printf '%s\n' {} \; 2>/dev/null >"$_rt_nodes_list"
        while IFS= read -r f; do
            [ -n "$f" ] && CHECK_NODES="$CHECK_NODES $f"
        done <"$_rt_nodes_list"
        rm -f "$_rt_nodes_list"
    fi

    # 2) ALSA cards
    for f in /sys/class/sound/card*/device/power/runtime_status; do
        [ -f "$f" ] && CHECK_NODES="$CHECK_NODES $f"
    done

    # 3) SoundWire slaves
    for f in /sys/bus/soundwire/devices/*/power/runtime_status; do
        [ -f "$f" ] && CHECK_NODES="$CHECK_NODES $f"
    done

    if [ -z "$CHECK_NODES" ]; then
        log_warn "No runtime_status nodes found for audio stack; treating snapshot as OK"
        AUDIO_PM_SNAPSHOT_OK=1
        return 0
    fi

    # Single snapshot: OK if all nodes are 'suspended' or 'unsupported'
    AUDIO_PM_SNAPSHOT_OK=1
    for n in $CHECK_NODES; do
        st="$(cat "$n" 2>/dev/null || echo "unknown")"
        case "$st" in
            suspended|unsupported) : ;;
            *) AUDIO_PM_SNAPSHOT_OK=0 ;;
        esac
        [ "$AUDIO_PM_SNAPSHOT_OK" -eq 0 ] && break
    done

    if [ "$AUDIO_PM_SNAPSHOT_OK" -eq 1 ]; then
        log_info "Audio PM snapshot: OK (suspended/unsupported)"
    else
        log_warn "Audio PM snapshot: not fully suspended; proceeding to fixed pre-stop delay"
    fi
}

# Re-check after fixed delay (if gating is enabled)
audio_pm_snapshot_ok() {
    # Re-sample the same CHECK_NODES set; if empty, treat as OK.
    if [ -z "$CHECK_NODES" ]; then
        echo "1"
        return
    fi
    for n in $CHECK_NODES; do
        st="$(cat "$n" 2>/dev/null || echo "unknown")"
        case "$st" in suspended|unsupported) : ;; *) echo "0"; return ;; esac
    done
    echo "1"
}

discover_audio_stack_and_snapshot

# --- Check DT presence for ADSP -----------------------------------------------
if ! dt_has_remoteproc_fw "$FW"; then
    log_skip "$TESTNAME SKIP – $FW not described in DT"
    log_info "Writing to file $RES_FILE"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi
log_info "DT indicates $FW is present"

# --- Enumerate ADSP remoteproc entries ----------------------------------------
entries="$(get_remoteproc_by_firmware "$FW" "" all 2>/dev/null)" || entries=""
if [ -z "$entries" ]; then
    log_fail "$FW present in DT but no /sys/class/remoteproc entry found"
    log_info "Writing to file $RES_FILE"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

count_instances="$(printf '%s\n' "$entries" | wc -l)"
log_info "Found $count_instances $FW instance(s)"

inst_fail=0
RESULT_LINES=""

# --- Iterate each instance via here-doc ---------------------------------------
while IFS='|' read -r rpath rstate rfirm rname; do
    [ -n "$rpath" ] || continue
    inst_id="$(basename "$rpath")"
    log_info "---- $inst_id: path=$rpath state=$rstate firmware=$rfirm name=$rname ----"

    boot_res="PASS"
    stop_res="NA"
    start_res="NA"
    ping_res="SKIPPED"

    if [ "$rstate" = "running" ]; then
        log_pass "$inst_id: boot check PASS"
    else
        log_fail "$inst_id: boot check FAIL (state=$rstate)"
        boot_res="FAIL"
        inst_fail=$((inst_fail + 1))
        RESULT_LINES="$RESULT_LINES $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
        continue
    fi

    if [ "$DO_SSR" -eq 1 ]; then
        # ---- Fixed pre-stop delay (always wait PRE_STOP_DELAY seconds) -----------
        log_info "$inst_id: waiting ${PRE_STOP_DELAY}s before remoteproc stop (fixed delay)"
        [ "$PRE_STOP_DELAY" -gt 0 ] && sleep "$PRE_STOP_DELAY"

        # Optional gating: after the fixed delay, ensure PM is OK before stopping
        if [ "$FATAL_ON_UNSUSPENDED" -eq 1 ]; then
            if [ "$(audio_pm_snapshot_ok)" -ne 1 ]; then
                log_fail "Audio not in suspended/unsupported state after ${PRE_STOP_DELAY}s (FATAL_ON_UNSUSPENDED=1); aborting before stop"
                log_info "Writing to file $RES_FILE"
                echo "$TESTNAME FAIL" >"$RES_FILE"
                exit 1
            fi
        fi

        # Helpful dmesg snapshots
        dmesg | tail -n 100 >"$test_path/dmesg_before_stop.log"
        dump_rproc_logs "$rpath" before-stop

        # ---- Stop ADSP -----------------------------------------------------------
        t0="$(date +%s)"
        log_info "$inst_id: stopping"
        if stop_remoteproc "$rpath" && wait_remoteproc_state "$rpath" offline "$STOP_TO" "$POLL_I"; then
            t1="$(date +%s)"
            log_pass "$inst_id: stop PASS ($((t1 - t0))s)"
            stop_res="PASS"
        else
            dump_rproc_logs "$rpath" after-stop-fail
            log_fail "$inst_id: stop FAIL"
            stop_res="FAIL"
            inst_fail=$((inst_fail + 1))
            RESULT_LINES="$RESULT_LINES $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
            continue
        fi

        dump_rproc_logs "$rpath" after-stop
        dump_rproc_logs "$rpath" before-start

        # ---- Start ADSP ----------------------------------------------------------
        t2="$(date +%s)"
        log_info "$inst_id: starting"
        if start_remoteproc "$rpath" && wait_remoteproc_state "$rpath" running "$START_TO" "$POLL_I"; then
            t3="$(date +%s)"
            log_pass "$inst_id: start PASS ($((t3 - t2))s)"
            start_res="PASS"
        else
            dump_rproc_logs "$rpath" after-start-fail
            log_fail "$inst_id: start FAIL"
            start_res="FAIL"
            inst_fail=$((inst_fail + 1))
            RESULT_LINES="$RESULT_LINES $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
            continue
        fi

        dump_rproc_logs "$rpath" after-start
        dmesg | tail -n 100 >"$test_path/dmesg_after_restart.log"
    else
        log_info "$inst_id: SSR disabled (--ssr not set). Skipping stop/start."
        stop_res="SKIPPED"
        start_res="SKIPPED"
    fi

    # ---- Optional RPMsg sanity ping -----------------------------------------
    if CTRL_DEV="$(find_rpmsg_ctrl_for "$FW")"; then
        log_info "$inst_id: RPMsg ctrl dev: $CTRL_DEV"
        if rpmsg_ping_generic "$CTRL_DEV"; then
            log_pass "$inst_id: rpmsg ping PASS"
            ping_res="PASS"
        else
            log_warn "$inst_id: rpmsg ping FAIL"
            ping_res="FAIL"
            inst_fail=$((inst_fail + 1))
        fi
    else
        log_info "$inst_id: no RPMsg channel, skipping ping"
    fi

    RESULT_LINES="$RESULT_LINES $inst_id: boot=$boot_res, stop=$stop_res, start=$start_res, ping=$ping_res"
done <<__RPROC_LIST__
$entries
__RPROC_LIST__

# --- Summary ------------------------------------------------------------------
log_info "Instance results:$RESULT_LINES"

if [ "$inst_fail" -gt 0 ]; then
    log_fail "One or more $FW instance(s) failed ($inst_fail/$count_instances)"
    log_info "Writing to file $RES_FILE"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

log_pass "All $count_instances $FW instance(s) passed"
log_info "Writing to file $RES_FILE"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
