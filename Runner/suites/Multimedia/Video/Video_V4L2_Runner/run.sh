#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# POSIX-only Video V4L2 runner with stack selection via utils/lib_video.sh

# --- Load init_env, functestlib, lib_video ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then INIT_ENV="$SEARCH/init_env"; break; fi
    SEARCH=$(dirname "$SEARCH")
done
if [ -z "$INIT_ENV" ]; then
    printf '%s\n' "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_video.sh"

TESTNAME="Video_V4L2_Runner"
RES_FILE="./${TESTNAME}.res"

: "${TAR_URL:=https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz}"

# --- Defaults / knobs ---
TIMEOUT="${TIMEOUT:-60}"
STRICT="${STRICT:-0}"
DMESG_SCAN="${DMESG_SCAN:-1}"
PATTERN=""
MAX="${MAX:-0}"
STOP_ON_FAIL="${STOP_ON_FAIL:-0}"
DRY=0
EXTRACT_INPUT_CLIPS="${EXTRACT_INPUT_CLIPS:-true}"
SUCCESS_RE="${SUCCESS_RE:-SUCCESS}"
LOGLEVEL="${LOGLEVEL:-15}"
REPEAT="${REPEAT:-1}"
REPEAT_DELAY="${REPEAT_DELAY:-0}"
REPEAT_POLICY="${REPEAT_POLICY:-all}"
JUNIT_OUT=""
VERBOSE=0

VIDEO_STACK="${VIDEO_STACK:-auto}" # accepts base/overlay/up/down
VIDEO_PLATFORM="${VIDEO_PLATFORM:-}" # lemans|monaco|kodiak|"" (auto)
VIDEO_FW_DS="${VIDEO_FW_DS:-}" # Kodiak DS firmware path
VIDEO_FW_BACKUP_DIR="${VIDEO_FW_BACKUP_DIR:-}" # override, default /opt (in lib)
VIDEO_NO_REBOOT="${VIDEO_NO_REBOOT:-0}"
VIDEO_FORCE="${VIDEO_FORCE:-0}"
VIDEO_APP="${VIDEO_APP:-/usr/bin/iris_v4l2_test}"

usage() {
    cat <<EOF
Usage: $0 [--config path.json] [--dir DIR] [--pattern GLOB]
          [--timeout S] [--strict] [--no-dmesg] [--max N] [--stop-on-fail]
          [--loglevel N] [--extract-input-clips true|false]
          [--repeat N] [--repeat-delay S] [--repeat-policy all|any]
          [--junit FILE] [--dry-run] [--verbose]
          [--stack auto|upstream|downstream|base|overlay|up|down]
          [--platform lemans|monaco|kodiak]
          [--downstream-fw PATH] [--force]
          [--app /path/to/iris_v4l2_test]
EOF
}

CFG=""; DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config) shift; CFG="$1" ;;
        --dir) shift; DIR="$1" ;;
        --pattern) shift; PATTERN="$1" ;;
        --timeout) shift; TIMEOUT="$1" ;;
        --strict) STRICT=1 ;;
        --no-dmesg) DMESG_SCAN=0 ;;
        --max) shift; MAX="$1" ;;
        --stop-on-fail) STOP_ON_FAIL=1 ;;
        --loglevel) shift; LOGLEVEL="$1" ;;
        --repeat) shift; REPEAT="$1" ;;
        --repeat-delay) shift; REPEAT_DELAY="$1" ;;
        --repeat-policy) shift; REPEAT_POLICY="$1" ;;
        --junit) shift; JUNIT_OUT="$1" ;;
        --dry-run) DRY=1 ;;
        --extract-input-clips) shift; EXTRACT_INPUT_CLIPS="$1" ;;
        --verbose) VERBOSE=1 ;;
        --stack) shift; VIDEO_STACK="$1" ;;
        --platform) shift; VIDEO_PLATFORM="$1" ;;
        --downstream-fw) shift; VIDEO_FW_DS="$1" ;;
        --force) VIDEO_FORCE=1 ;;
        --app) shift; VIDEO_APP="$1" ;;
        --help|-h) usage; exit 0 ;;
        *) log_warn "Unknown arg: $1" ;;
    esac
    shift
done

# Export app path for lib
export VIDEO_APP

# --- Resolve testcase path and cd so outputs land here ---
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
cd "$test_path" || { log_error "cd failed: $test_path"; printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"; exit 1; }

# --- Optional early fetch of bundle (best-effort) ---
if [ "$EXTRACT_INPUT_CLIPS" = "true" ]; then
    video_step "" "Early bundle fetch (best-effort)"
    extract_tar_from_url "$TAR_URL" || true
fi

LOG_DIR="./logs_${TESTNAME}"
mkdir -p "$LOG_DIR"

log_info "----------------------------------------------------------------------"
log_info "---------------------- Starting $TESTNAME (modular) -------------------"
log_info "STACK=$VIDEO_STACK PLATFORM=${VIDEO_PLATFORM:-auto} STRICT=$STRICT DMESG_SCAN=$DMESG_SCAN"
log_info "TIMEOUT=${TIMEOUT}s LOGLEVEL=$LOGLEVEL REPEAT=$REPEAT REPEAT_POLICY=$REPEAT_POLICY"
log_info "APP=$VIDEO_APP"
[ -n "$VIDEO_FW_DS" ] && log_info "Downstream FW override: $VIDEO_FW_DS"
[ -n "$VIDEO_FW_BACKUP_DIR" ] && log_info "FW backup override: $VIDEO_FW_BACKUP_DIR"
[ "$VERBOSE" -eq 1 ] && log_info "CWD=$(pwd) | SCRIPT_DIR=$SCRIPT_DIR | test_path=$test_path"

# --- Required tools ---
check_dependencies iris_v4l2_test grep sed awk find sort || {
    log_skip "$TESTNAME SKIP - required tools missing"
    printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
}
# App presence (not necessarily executable if set to custom path on target)
if [ ! -x "$VIDEO_APP" ]; then
    log_warn "App not executable at VIDEO_APP=$VIDEO_APP (will still try to run)"
fi

# Warn if not root (module/blacklist ops may fail)
video_warn_if_not_root

# --- Ensure desired video stack (hot switch best-effort) ---
plat="$VIDEO_PLATFORM"
[ -n "$plat" ] || plat=$(video_detect_platform)
log_info "Detected platform: $plat"

# Export envs used by lib
export VIDEO_FW_DS VIDEO_FW_BACKUP_DIR VIDEO_NO_REBOOT VIDEO_FORCE LOG_DIR TAR_URL

# Normalize stack to accept base/overlay/up/down
VIDEO_STACK=$(video_normalize_stack "$VIDEO_STACK")

pre_stack=$(video_stack_status "$plat")
log_info "Current video stack (pre): $pre_stack"

video_step "" "Apply desired stack = $VIDEO_STACK"
post_stack=$(video_ensure_stack "$VIDEO_STACK" "$plat" || true)
if [ -z "$post_stack" ] || [ "$post_stack" = "unknown" ]; then
    log_warn "Could not fully switch to requested stack=$VIDEO_STACK (platform=$plat). Blacklist updated; reboot may be required."
    post_stack=$(video_stack_status "$plat")
fi
log_info "Video stack (post): $post_stack"

# Per-platform module validation
case "$plat" in
    lemans|monaco)
        if [ "$post_stack" = "upstream" ]; then
            if video_has_module_loaded qcom_iris && video_has_module_loaded iris_vpu; then
                log_pass "Upstream validated: qcom_iris + iris_vpu present"
            else
                log_warn "Upstream expected but modules mismatch (need qcom_iris and iris_vpu)"
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
            else
                log_warn "Upstream expected but venus modules mismatch"
            fi
        elif [ "$post_stack" = "downstream" ]; then
            if video_has_module_loaded iris_vpu; then
                log_pass "Downstream validated: iris_vpu present (Kodiak)"
            else
                log_warn "Downstream expected but iris_vpu not present (Kodiak)"
            fi
        fi
        ;;
    *) log_warn "Unknown platform; skipping strict module validation" ;;
esac

# Validate numeric loglevel
case "$LOGLEVEL" in ''|*[!0-9]* ) log_warn "Non-numeric --loglevel '$LOGLEVEL'; using 15"; LOGLEVEL=15 ;; esac

# --- Discover config list ---
CFG_LIST="$LOG_DIR/.cfgs"; : > "$CFG_LIST"
if [ -z "$CFG" ]; then
    log_info "No --config passed, searching for JSON under testcase dir: $test_path"
    find "$test_path" -type f -name "*.json" 2>/dev/null | sort > "$CFG_LIST"
else
    printf '%s\n' "$CFG" > "$CFG_LIST"
fi
if [ ! -s "$CFG_LIST" ]; then
    [ -n "$DIR" ] || DIR="$test_path"
    if [ -n "$PATTERN" ]; then
        find "$DIR" -type f -name "$PATTERN" 2>/dev/null | sort > "$CFG_LIST"
    else
        find "$DIR" -type f -name "*.json" 2>/dev/null | sort > "$CFG_LIST"
    fi
    if [ ! -s "$CFG_LIST" ]; then
        log_skip "$TESTNAME SKIP - no JSON configs found"
        printf '%s\n' "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
fi

cfg_count=$(wc -l < "$CFG_LIST" 2>/dev/null | tr -d ' ')
log_info "Discovered $cfg_count JSON config(s) to run"

# --- JUnit prep / results files ---
JUNIT_TMP="$LOG_DIR/.junit_cases.xml"
: > "$JUNIT_TMP"
printf '%s\n' "mode,id,result,name,elapsed,pass_runs,fail_runs" > "$LOG_DIR/results.csv"
: > "$LOG_DIR/summary.txt"

# --- Suite loop ---
total=0; pass=0; fail=0; skip=0; suite_rc=0

while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue
    total=$((total + 1))

    if video_is_decode_cfg "$cfg"; then mode="decode"; else mode="encode"; fi

    name_and_id=$(video_pretty_name_from_cfg "$cfg")
    pretty=$(printf '%s' "$name_and_id" | cut -d'|' -f1)
    raw_codec=$(video_guess_codec_from_cfg "$cfg")
    codec=$(video_canon_codec "$raw_codec")
    safe_codec=$(printf '%s' "$codec" | tr ' /' '__')
    base_noext=$(basename "$cfg" .json)
    id="${mode}-${safe_codec}-${base_noext}"

    log_info "[$id] START — mode=$mode codec=$codec name=\"$pretty\" cfg=\"$cfg\""

    video_step "$id" "Check /dev/video* presence"
    if ! video_devices_present; then
        log_skip "[$id] SKIP - no /dev/video* nodes"
        printf '%s\n' "$id SKIP $pretty" >> "$LOG_DIR/summary.txt"
        printf '%s\n' "$mode,$id,SKIP,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        skip=$((skip + 1))
        continue
    fi

    if [ "$EXTRACT_INPUT_CLIPS" = "true" ]; then
        video_step "$id" "Ensure clips present or fetch"
        video_ensure_clips_present_or_fetch "$cfg" "$TAR_URL"
        ce=$?
        if [ "$ce" -eq 2 ] 2>/dev/null; then
            # offline → only SKIP decode cases (align with audio semantics)
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
            fail=$((fail + 1)); suite_rc=1
            [ "$STOP_ON_FAIL" -eq 1 ] && break
            continue
        fi
    fi

    # Strict clip existence check after optional fetch
    video_step "$id" "Verify required clips exist"
    missing_case=0
    clips_file="$LOG_DIR/.clips.$$"
    video_extract_input_clips "$cfg" > "$clips_file"
    if [ -s "$clips_file" ]; then
        while IFS= read -r pth; do
            [ -z "$pth" ] && continue
            case "$pth" in
                /*) abs="$pth" ;;
                *) abs=$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)/$pth ;;
            esac
            [ -f "$abs" ] || missing_case=1
        done < "$clips_file"
    fi
    rm -f "$clips_file" 2>/dev/null || true
    if [ "$missing_case" -eq 1 ] 2>/dev/null; then
        log_fail "[$id] Required input clip(s) not present — $pretty"
        printf '%s\n' "$id FAIL $pretty" >> "$LOG_DIR/summary.txt"
        printf '%s\n' "$mode,$id,FAIL,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        fail=$((fail + 1)); suite_rc=1
        [ "$STOP_ON_FAIL" -eq 1 ] && break
        continue
    fi

    if [ "$DRY" -eq 1 ]; then
        video_step "$id" "DRY RUN - print command"
        log_info "[dry] [$id] $VIDEO_APP --config \"$cfg\" --loglevel $LOGLEVEL — $pretty"
        printf '%s\n' "$id DRY-RUN $pretty" >> "$LOG_DIR/summary.txt"
        printf '%s\n' "$mode,$id,DRY-RUN,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        continue
    fi

    pass_runs=0; fail_runs=0; rep=1
    start_case=$(date +%s 2>/dev/null || printf '%s' 0)
    logf="$LOG_DIR/${id}.log"

    while [ "$rep" -le "$REPEAT" ]; do
        [ "$REPEAT" -gt 1 ] && log_info "[$id] repeat $rep/$REPEAT — $pretty"
        video_step "$id" "Execute app"
        if video_run_once "$cfg" "$logf" "$TIMEOUT" "$SUCCESS_RE" "$LOGLEVEL"; then
            pass_runs=$((pass_runs + 1))
        else
            fail_runs=$((fail_runs + 1))
        fi
        if [ "$rep" -lt "$REPEAT" ] && [ "$REPEAT_DELAY" -gt 0 ]; then sleep "$REPEAT_DELAY"; fi
        rep=$((rep + 1))
    done

    end_case=$(date +%s 2>/dev/null || printf '%s' 0)
    elapsed=$((end_case - start_case)); [ "$elapsed" -lt 0 ] 2>/dev/null && elapsed=0

    final="FAIL"
    case "$REPEAT_POLICY" in
        any) [ "$pass_runs" -ge 1 ] && final="PASS" ;;
        all|*) [ "$fail_runs" -eq 0 ] && final="PASS" ;;
    esac

    video_step "$id" "DMESG triage"
    video_scan_dmesg_if_enabled "$DMESG_SCAN" "$LOG_DIR"
    dmesg_rc=$?
    if [ "$dmesg_rc" -eq 0 ]; then
        log_warn "[$id] dmesg reported errors (STRICT=$STRICT)"
        [ "$STRICT" -eq 1 ] && final="FAIL"
    fi

    # Append explicit RESULT line into the case log for CI grepability
    {
        printf 'RESULT id=%s mode=%s pretty="%s" final=%s pass_runs=%s fail_runs=%s elapsed=%s\n' \
            "$id" "$mode" "$pretty" "$final" "$pass_runs" "$fail_runs" "$elapsed"
    } >> "$logf" 2>&1

    video_junit_append_case "$JUNIT_TMP" "Video.$mode" "$pretty" "$elapsed" "$final" "$logf"

    case "$final" in
        PASS) log_pass "[$id] PASS ($pass_runs/$REPEAT ok) — $pretty" ;;
        FAIL) log_fail "[$id] FAIL (pass=$pass_runs fail=$fail_runs) — $pretty" ;;
        SKIP) log_skip "[$id] SKIP — $pretty" ;;
    esac

    printf '%s\n' "$id $final $pretty" >> "$LOG_DIR/summary.txt"
    printf '%s\n' "$mode,$id,$final,$pretty,$elapsed,$pass_runs,$fail_runs" >> "$LOG_DIR/results.csv"

    if [ "$final" = "PASS" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); suite_rc=1
        [ "$STOP_ON_FAIL" -eq 1 ] && break
    fi

    if [ "$MAX" -gt 0 ] && [ "$total" -ge "$MAX" ]; then
        log_info "Reached MAX=$MAX tests; stopping"
        break
    fi
done < "$CFG_LIST"

log_info "Summary: total=$total pass=$pass fail=$fail skip=$skip"

# --- JUnit finalize ---
if [ -n "$JUNIT_OUT" ]; then
    tests=$((pass + fail + skip))
    failures="$fail"
    skipped="$skip"
    {
        printf '<testsuite name="%s" tests="%s" failures="%s" skipped="%s">\n' "$TESTNAME" "$tests" "$failures" "$skipped"
        cat "$JUNIT_TMP"
        printf '</testsuite>\n'
    } > "$JUNIT_OUT"
    log_info "Wrote JUnit: $JUNIT_OUT"
fi

if [ "$suite_rc" -eq 0 ] 2>/dev/null; then
    log_pass "$TESTNAME: PASS"; printf '%s\n' "$TESTNAME PASS" >"$RES_FILE"
else
    log_fail "$TESTNAME: FAIL"; printf '%s\n' "$TESTNAME FAIL" >"$RES_FILE"
fi
exit "$suite_rc"
