#!/bin/sh
# Generic Video V4L2 runner (encode/decode) for iris_v4l2_test JSON configs.
# Minimal deps: POSIX sh + grep/sed/awk/find/sort
# Uses in-tree run_with_timeout() from functestlib.sh when present.
# SPDX-License-Identifier: BSD-3-Clause-Clear

###############################################################################
# Locate and source init_env + functestlib.sh
###############################################################################
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

TESTNAME="Video_V4L2_Runner"
RES_FILE="./${TESTNAME}.res"

# Media assets bundle with sample clips
TAR_URL="${TAR_URL:-https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz}"

###############################################################################
# Knobs (override by env or CLI)
###############################################################################
TIMEOUT="${TIMEOUT:-60}" # per-test timeout (s)
STRICT="${STRICT:-0}" # 1=fail suite if dmesg shows critical errors
DMESG_SCAN="${DMESG_SCAN:-1}" # 1=scan dmesg after each test
PATTERN="" # glob to filter configs
MAX="${MAX:-0}" # run at most N tests (0=all)
STOP_ON_FAIL="${STOP_ON_FAIL:-0}" # bail on first fail
DRY=0 # 1=dry-run
EXTRACT_INPUT_CLIPS="${EXTRACT_INPUT_CLIPS:-true}" # true/false, prefetch media bundle
SUCCESS_RE="${SUCCESS_RE:-SUCCESS}" # success marker regex in tool log
LOGLEVEL="${LOGLEVEL:-15}" # iris_v4l2_test --loglevel
REPEAT="${REPEAT:-1}" # repeats per config
REPEAT_DELAY="${REPEAT_DELAY:-0}" # seconds between repeats
REPEAT_POLICY="${REPEAT_POLICY:-all}" # all|any
JUNIT_OUT="" # optional path to write JUnit XML
VERBOSE=0

usage() {
    cat <<EOF
Usage: $0 [--config path.json] [--dir DIR] [--pattern GLOB]
          [--timeout S] [--strict] [--no-dmesg] [--max N] [--stop-on-fail]
          [--loglevel N] [--extract-input-clips true|false]
          [--repeat N] [--repeat-delay S] [--repeat-policy all|any]
          [--junit FILE] [--dry-run] [--verbose]
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
        --help|-h) usage; exit 0 ;;
        *) log_warn "Unknown arg: $1" ;;
    esac
    shift
done

# Resolve testcase path and run from there (so .res/logs are next to run.sh)
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
cd "$test_path" || { log_error "cd failed: $test_path"; echo "$TESTNAME FAIL" >"$RES_FILE"; exit 1; }


LOG_DIR="./logs_${TESTNAME}"
mkdir -p "$LOG_DIR"

log_info "----------------------------------------------------------------------"
log_info "------------------ Starting $TESTNAME (generic runner) ----------------"
log_info "=== Initialization ==="
log_info "TIMEOUT=${TIMEOUT}s STRICT=$STRICT DMESG_SCAN=$DMESG_SCAN SUCCESS_RE=$SUCCESS_RE"
log_info "LOGLEVEL=$LOGLEVEL EXTRACT_INPUT_CLIPS=$EXTRACT_INPUT_CLIPS"
log_info "REPEAT=$REPEAT REPEAT_DELAY=${REPEAT_DELAY}s REPEAT_POLICY=$REPEAT_POLICY"
[ "$VERBOSE" -eq 1 ] && log_info "CWD=$(pwd) | SCRIPT_DIR=$SCRIPT_DIR | test_path=$test_path"

# Required binaries (no external 'timeout' needed)
check_dependencies iris_v4l2_test grep sed awk find sort || {
    log_skip "$TESTNAME SKIP - required tools missing"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
}

###############################################################################
# Sanity checks
###############################################################################
case "$LOGLEVEL" in ''|*[!0-9]* ) log_warn "Non-numeric --loglevel '$LOGLEVEL'; using 15"; LOGLEVEL=15 ;; esac

###############################################################################
# Helpers (jq-free JSON scraping; POSIX only)
###############################################################################
# Decide decode/encode:
# 1) filename contains "dec"/"enc"
# 2) else JSON "Domain": "Decoder"/"Encoder"
# 3) else default decode
is_decode_cfg() {
    cfg="$1"
    b="$(basename "$cfg" | tr '[:upper:]' '[:lower:]')"
    case "$b" in
        *dec*.json) return 0 ;; # decode
        *enc*.json) return 1 ;; # encode
    esac
    dom="$(sed -n 's/.*"Domain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -n1)"
    dom_l="$(printf '%s' "$dom" | tr '[:upper:]' '[:lower:]')"
    case "$dom_l" in
        decoder|decode) return 0 ;;
        encoder|encode) return 1 ;;
    esac
    return 0
}

extract_scalar_key_values() { # "Key": "value"
    key="$1"; cfg="$2"
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"\r\n]*\\)\".*/\\1/p" "$cfg"
}
extract_array_key_values() { # "Key": ["a","b"]
    key="$1"; cfg="$2"
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\\[\\(.*\\)\\].*/\\1/p" "$cfg" \
    | tr ',' '\n' | sed -n 's/.*"\([^"]*\)".*/\1/p'
}
extract_input_clips() {
    cfg="$1"
    {
        # common variants
        extract_scalar_key_values "InputPath" "$cfg"
        extract_scalar_key_values "input" "$cfg"
        extract_scalar_key_values "InputFile" "$cfg"
        extract_scalar_key_values "Source" "$cfg"
        extract_scalar_key_values "Clip" "$cfg"
        extract_array_key_values "Inputs" "$cfg"
        extract_array_key_values "Clips" "$cfg"
        extract_array_key_values "Files" "$cfg"
    } 2>/dev/null | sed '/^$/d' | sort -u
}

# Guess codec from config (by key → content → filename) and normalize name.
guess_codec_from_cfg() {
    cfg="$1"
    for k in Codec codec CodecName codecName VideoCodec videoCodec DecoderName EncoderName Name name; do
        v="$(extract_scalar_key_values "$k" "$cfg" | head -n 1)"
        if [ -n "$v" ]; then
            printf '%s\n' "$v"
            return
        fi
    done
    for tok in hevc h265 h264 av1 vp9 vp8 mpeg4 mpeg2 h263 avc; do
        if grep -qiE "(^|[^A-Za-z0-9])${tok}([^A-Za-z0-9]|$)" "$cfg" 2>/dev/null; then
            printf '%s\n' "$tok"
            return
        fi
    done
    b="$(basename "$cfg" | tr '[:upper:]' '[:lower:]')"
    for tok in hevc h265 h264 av1 vp9 vp8 mpeg4 mpeg2 h263 avc; do
        case "$b" in *"$tok"*) printf '%s\n' "$tok"; return ;; esac
    done
    printf '%s\n' "unknown"
}

canon_codec() {
    c="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$c" in
        h265|hevc) echo "hevc" ;;
        h264|avc) echo "h264" ;;
        vp9) echo "vp9" ;;
        vp8) echo "vp8" ;;
        av1) echo "av1" ;;
        mpeg4) echo "mpeg4";;
        mpeg2) echo "mpeg2";;
        h263) echo "h263" ;;
        *) echo "$c" ;;
    esac
}

# /dev/video* presence without ls(1)
devices_present() {
    set -- /dev/video* 2>/dev/null
    [ -e "$1" ]
}

ensure_clips_present_or_fetch() {
    cfg="$1"; missing=0
    clips="$(extract_input_clips "$cfg")"
    [ -z "$clips" ] && return 0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
            /*) abs="$p" ;;
            *) abs="$(cd "$(dirname "$cfg")" && pwd)/$p" ;;
        esac
        if [ ! -f "$abs" ]; then
            log_warn "Missing input clip: $abs"
            if [ "$EXTRACT_INPUT_CLIPS" = "true" ] && [ -n "$TAR_URL" ]; then
                log_info "Attempting fetch via TAR_URL=$TAR_URL"
				extract_tar_from_url "$TAR_URL" || true
            else
                log_warn "Skipping extraction of input clips as EXTRACT_INPUT_CLIPS is not true."
            fi
            [ ! -f "$abs" ] && missing=1
        fi
    done <<EOF
$(printf "%s\n" "$clips")
EOF
    [ $missing -eq 0 ]
}

# Pretty, human-readable case name; returns "pretty|safe"
pretty_name_from_cfg() {
    cfg="$1"
    base="$(basename "$cfg" .json)"
    name="$(extract_scalar_key_values "name" "$cfg")"
    [ -n "$name" ] || name="$(extract_scalar_key_values "Name" "$cfg")"
    codec="$(extract_scalar_key_values "codec" "$cfg")"
    [ -n "$codec" ] || codec="$(extract_scalar_key_values "Codec" "$cfg")"
    op=""
    if is_decode_cfg "$cfg"; then op="Decode"; else op="Encode"; fi

    if [ -n "$name" ]; then
        nice="$name"
    elif [ -n "$codec" ]; then
        nice="$op:$codec ($base)"
    else
        nice="$op:$base"
    fi

    safe="$(printf '%s' "$nice" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')"
    printf '%s|%s\n' "$nice" "$safe"
}

###############################################################################
# Dmesg scan helper
# Return codes: 2 = disabled, 0 = errors found, 1 = clean
###############################################################################
scan_dmesg_if_enabled() {
    [ "$DMESG_SCAN" -eq 1 ] || return 2
    MODS='oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error'
    EXCL='using dummy regulator|not found|EEXIST|probe deferred'
    if scan_dmesg_errors "$LOG_DIR" "$MODS" "$EXCL"; then
        return 0
    fi
    return 1
}

###############################################################################
# JUnit helpers
###############################################################################
JUNIT_TMP="$LOG_DIR/.junit_cases.xml"
: > "$JUNIT_TMP"
append_junit_case() {
    # $1=id $2=pretty $3=mode $4=elapsed $5=status $6=logf
    id="$1"; pretty="$2"; mode="$3"; elapsed="$4"; status="$5"; logf="$6"
    [ -n "$JUNIT_OUT" ] || return 0
    safe_msg="$(tail -n 50 "$logf" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')"
    {
        printf ' <testcase classname="%s" name="%s" time="%s">\n' "Video.${mode}" "$pretty" "$elapsed"
        case "$status" in
            PASS) : ;;
            SKIP) printf ' <skipped/>\n' ;;
            FAIL) printf ' <failure message="%s">\n' "failed"; printf '%s\n' "$safe_msg"; printf ' </failure>\n' ;;
        esac
        printf ' </testcase>\n'
    } >> "$JUNIT_TMP"
}

###############################################################################
# Per-config execution (with repeats) — uses run_with_timeout if available
###############################################################################
have_rwt=0
if command -v run_with_timeout >/dev/null 2>&1; then
    have_rwt=1
else
    log_warn "run_with_timeout() not found; running without enforced timeout"
fi

run_once() {
    cfg="$1"; logf="$2"
    : > "$logf"
    [ "$VERBOSE" -eq 1 ] && log_info "[cmd] iris_v4l2_test --config \"$cfg\" --loglevel $LOGLEVEL"
    if [ "$have_rwt" -eq 1 ]; then
        if run_with_timeout "$TIMEOUT" iris_v4l2_test --config "$cfg" --loglevel "$LOGLEVEL" >>"$logf" 2>&1; then
            :
        else
            rc=$?
            if [ "$rc" -eq 124 ]; then
                log_fail "[run] timeout after ${TIMEOUT}s"
            else
                log_fail "[run] iris_v4l2_test exited rc=$rc"
            fi
            return 1
        fi
    else
        if iris_v4l2_test --config "$cfg" --loglevel "$LOGLEVEL" >>"$logf" 2>&1; then
            :
        else
            rc=$?
            log_fail "[run] iris_v4l2_test exited rc=$rc (no timeout enforced)"
            return 1
        fi
    fi

    if grep -Eq "$SUCCESS_RE" "$logf"; then
        return 0
    fi
    return 1
}

run_repeated() {
    # $1=cfg $2=pretty $3=mode $4=id
    cfg="$1"; pretty="$2"; mode="$3"; id="$4"
    logf="$LOG_DIR/${id}.log"
    pass_runs=0; fail_runs=0; rep=1
    start_case=$(date +%s 2>/dev/null || echo 0)

    while [ "$rep" -le "$REPEAT" ]; do
        [ "$REPEAT" -gt 1 ] && log_info "[$id] repeat $rep/$REPEAT — $pretty"
        if run_once "$cfg" "$logf"; then
            pass_runs=$((pass_runs+1))
        else
            fail_runs=$((fail_runs+1))
        fi
        [ "$rep" -lt "$REPEAT" ] && [ "$REPEAT_DELAY" -gt 0 ] && sleep "$REPEAT_DELAY"
        rep=$((rep+1))
    done

    end_case=$(date +%s 2>/dev/null || echo 0)
    elapsed=$(( end_case - start_case )); [ "$elapsed" -lt 0 ] && elapsed=0

    final="FAIL"
    case "$REPEAT_POLICY" in
        any) [ "$pass_runs" -ge 1 ] && final="PASS" ;;
        all|*) [ "$fail_runs" -eq 0 ] && final="PASS" ;;
    esac

    # Optional dmesg triage: only gate with STRICT=1 and when errors are found
    scan_dmesg_if_enabled
    dmesg_rc=$?
    if [ "$dmesg_rc" -eq 0 ]; then
        log_warn "[$id] dmesg reported errors (STRICT=$STRICT)"
        [ "$STRICT" -eq 1 ] && final="FAIL"
    fi

    append_junit_case "$id" "$pretty" "$mode" "$elapsed" "$final" "$logf"

    case "$final" in
        PASS) log_pass "[$id] PASS ($pass_runs/$REPEAT ok) — $pretty";;
        FAIL) log_fail "[$id] FAIL (pass=$pass_runs fail=$fail_runs) — $pretty";;
        SKIP) log_skip "[$id] SKIP — $pretty";;
    esac
    echo "$id $final $pretty" >> "$LOG_DIR/summary.txt"
    echo "$mode,$id,$final,$pretty,$elapsed,$pass_runs,$fail_runs" >> "$LOG_DIR/results.csv"

    [ "$final" = "PASS" ] && return 0 || return 1
}

###############################################################################
# Discover config list
###############################################################################
CFG_LIST="$LOG_DIR/.cfgs"
: > "$CFG_LIST"

if [ -z "$CFG" ]; then
    log_info "No --config passed, searching for JSON files under testcase dir: $test_path"
    find "$test_path" -type f -name "*.json" 2>/dev/null | sort > "$CFG_LIST"
else
    printf "%s\n" "$CFG" > "$CFG_LIST"
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
        echo "$TESTNAME SKIP" > "$RES_FILE"
        exit 0
    fi
fi

cfg_count=$(wc -l < "$CFG_LIST" 2>/dev/null | tr -d ' ')
log_info "Discovered $cfg_count JSON config(s) to run"

###############################################################################
# Run suite
###############################################################################
: > "$LOG_DIR/summary.txt"
echo "mode,id,result,name,elapsed,pass_runs,fail_runs" > "$LOG_DIR/results.csv"

total=0; pass=0; fail=0; skip=0; suite_rc=0

# Read list without a pipeline (avoid subshell)
while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue
    total=$((total+1))

    # Determine mode
    if is_decode_cfg "$cfg"; then
        mode="decode"
    else
        mode="encode"
    fi

    # Human-friendly name & unique, codec-based ID
    name_and_id="$(pretty_name_from_cfg "$cfg")"
    pretty="$(printf '%s' "$name_and_id" | cut -d'|' -f1)"
    raw_codec="$(guess_codec_from_cfg "$cfg")"
    codec="$(canon_codec "$raw_codec")"
    safe_codec="$(printf '%s' "$codec" | tr ' /' '__')"
    base_noext="$(basename "$cfg" .json)"
    id="${mode}-${safe_codec}-${base_noext}"

    log_info "[$id] START — mode=$mode codec=$codec name=\"$pretty\" cfg=\"$cfg\""

    if ! devices_present; then
        log_skip "[$id] SKIP - no /dev/video* nodes"
        echo "$id SKIP $pretty" >> "$LOG_DIR/summary.txt"
        echo "$mode,$id,SKIP,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        skip=$((skip+1))
        continue
    fi

    if ! ensure_clips_present_or_fetch "$cfg"; then
        log_fail "[$id] Required input clip(s) not present — $pretty"
        echo "$id FAIL $pretty" >> "$LOG_DIR/summary.txt"
        echo "$mode,$id,FAIL,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        fail=$((fail+1)); suite_rc=1
        [ "$STOP_ON_FAIL" -eq 1 ] && break
        continue
    fi
    [ "$VERBOSE" -eq 1 ] && log_info "[$id] input clips: OK"

    if [ "$DRY" -eq 1 ]; then
        log_info "[dry] [$id] iris_v4l2_test --config \"$cfg\" --loglevel $LOGLEVEL — $pretty"
        echo "$id DRY-RUN $pretty" >> "$LOG_DIR/summary.txt"
        echo "$mode,$id,DRY-RUN,$pretty,0,0,0" >> "$LOG_DIR/results.csv"
        continue
    fi

    if run_repeated "$cfg" "$pretty" "$mode" "$id"; then
        pass=$((pass+1))
        log_pass "[$id] DONE — PASS"
    else
        fail=$((fail+1)); suite_rc=1
        log_fail "[$id] DONE — FAIL"
        [ "$STOP_ON_FAIL" -eq 1 ] && break
    fi

    if [ "$MAX" -gt 0 ] && [ "$total" -ge "$MAX" ]; then
        log_info "Reached MAX=$MAX tests; stopping"
        break
    fi
done < "$CFG_LIST"

log_info "Summary: total=$total pass=$pass fail=$fail skip=$skip"

# JUnit finalize
if [ -n "$JUNIT_OUT" ]; then
    tests=$((pass+fail+skip))
    failures="$fail"
    skipped="$skip"
    {
        printf '<testsuite name="%s" tests="%s" failures="%s" skipped="%s">\n' "$TESTNAME" "$tests" "$failures" "$skipped"
        cat "$JUNIT_TMP"
        printf '</testsuite>\n'
    } > "$JUNIT_OUT"
    log_info "Wrote JUnit: $JUNIT_OUT"
fi

if [ $suite_rc -eq 0 ]; then
    log_pass "$TESTNAME: PASS"; echo "$TESTNAME PASS" > "$RES_FILE"
else
    log_fail "$TESTNAME: FAIL"; echo "$TESTNAME FAIL" > "$RES_FILE"
fi
exit $suite_rc
