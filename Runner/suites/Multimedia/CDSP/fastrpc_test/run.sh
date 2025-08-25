#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# --------- Robustly source init_env and functestlib.sh ----------
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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# ---------------------------------------------------------------

TESTNAME="fastrpc_test"
RESULT_FILE="$TESTNAME.res"

# Defaults
REPEAT=1
TIMEOUT=""
BIN_DIR="" # optional: where fastrpc_test lives
ASSETS_DIR="" # optional: parent containing linux/ etc
VERBOSE=0

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --bin-dir <path> Directory containing 'fastrpc_test' binary
  --assets-dir <path> Directory that CONTAINS 'linux/' (run from here if present)
  --repeat <N> Number of test repetitions (default: 1)
  --timeout <sec> Timeout for each run (no timeout if omitted)
  --verbose Extra logging for CI debugging
  --help Show this help

Notes:
- If --bin-dir is omitted, 'fastrpc_test' must be on PATH.
- If --assets-dir is omitted or lacks 'linux/', we run from the binary's dir.
- Uses stdbuf/script if available for unbuffered output; otherwise runs plain.
EOF
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --bin-dir) BIN_DIR="$2"; shift 2 ;;
        --assets-dir) ASSETS_DIR="$2"; shift 2 ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;; # actively used below
        --help) usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# ---------- Validation ----------
case "$REPEAT" in *[!0-9]*|"") log_error "Invalid --repeat: $REPEAT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1 ;; esac
if [ -n "$TIMEOUT" ]; then
    case "$TIMEOUT" in *[!0-9]*|"") log_error "Invalid --timeout: $TIMEOUT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1 ;; esac
fi

test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Small debug helper
log_debug() { [ "$VERBOSE" -eq 1 ] && log_info "[debug] $*"; }

# ---------- Locate binary ----------
if [ -n "$BIN_DIR" ]; then
    FASTBIN="$BIN_DIR/fastrpc_test"
    if [ ! -x "$FASTBIN" ]; then
        log_fail "fastrpc_test not executable at: $FASTBIN"
        echo "$TESTNAME : FAIL" > "$RESULT_FILE"
        exit 1
    fi
else
    if ! FASTBIN="$(command -v fastrpc_test 2>/dev/null)"; then
        log_fail "'fastrpc_test' binary not found on PATH (or use --bin-dir)."
        echo "$TESTNAME : FAIL" > "$RESULT_FILE"
        exit 1
    fi
fi
BINDIR="$(dirname "$FASTBIN")"
log_info "Binary: $FASTBIN"

# ---------- Buffering tool availability ----------
HAVE_STDBUF=0; command -v stdbuf >/dev/null 2>&1 && HAVE_STDBUF=1
HAVE_SCRIPT=0; command -v script >/dev/null 2>&1 && HAVE_SCRIPT=1
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

buf_label="none"
if [ $HAVE_STDBUF -eq 1 ]; then
    buf_label="stdbuf -oL -eL"
elif [ $HAVE_SCRIPT -eq 1 ]; then
    buf_label="script -q"
fi

# ---------- Assets directory resolution ----------
RESOLVED_RUN_DIR=""
if [ -n "$ASSETS_DIR" ]; then
    # Use user-provided assets dir if it exists; prefer it if it has linux/
    if [ -d "$ASSETS_DIR" ]; then
        RESOLVED_RUN_DIR="$ASSETS_DIR"
        if [ ! -d "$ASSETS_DIR/linux" ]; then
            log_debug "--assets-dir provided but no 'linux/' inside: $ASSETS_DIR (continuing anyway)"
        else
            log_info "Using --assets-dir: $ASSETS_DIR (expects: $ASSETS_DIR/linux)"
        fi
    else
        log_warn "--assets-dir not found: $ASSETS_DIR (falling back to binary dir)"
    fi
fi

if [ -z "$RESOLVED_RUN_DIR" ]; then
    if [ -d "$BINDIR/linux" ]; then
        RESOLVED_RUN_DIR="$BINDIR"
    elif [ -d "$SCRIPT_DIR/linux" ]; then
        RESOLVED_RUN_DIR="$SCRIPT_DIR"
    else
        # Last resort: run from the binary directory
        RESOLVED_RUN_DIR="$BINDIR"
    fi
fi

# Quiet note if linux/ missing (don’t spam CI output)
[ -d "$RESOLVED_RUN_DIR/linux" ] || log_debug "No 'linux/' under run dir: $RESOLVED_RUN_DIR (binary may still work)"

# ---------- Timeout wrapper (portable fallback) ----------
run_with_timeout() {
    # Usage: run_with_timeout <timeout_sec_or_empty> -- <cmd> [args...]
    tmo="$1"; shift
    [ "$1" = "--" ] && shift
    if [ -n "$tmo" ] && [ $HAVE_TIMEOUT -eq 1 ]; then
        timeout "$tmo" "$@"
        return $?
    fi

    if [ -z "$tmo" ]; then
        "$@"
        return $?
    fi

    # Fallback: crude timeout using a watcher
    (
        setsid "$@" &
        child=$!
        (
            sleep "$tmo"
            if kill -0 "$child" 2>/dev/null; then
                # shellcheck disable=SC2046
                kill -TERM -$(ps -o pgid= "$child" | tr -d ' ') 2>/dev/null
            fi
        ) &
        watcher=$!
        wait "$child"; rc=$?
        kill "$watcher" 2>/dev/null
        exit $rc
    )
    return $?
}

# ---------- Logging root ----------
TS="$(date +%Y%m%d-%H%M%S)"
LOG_ROOT="./logs_${TESTNAME}_${TS}"
mkdir -p "$LOG_ROOT" || { log_error "Cannot create $LOG_ROOT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1; }

tmo_label="none"; [ -n "$TIMEOUT" ] && tmo_label="${TIMEOUT}s"
log_info "Repeats: $REPEAT | Timeout: $tmo_label | Buffering: $buf_label"
log_debug "Run dir: $RESOLVED_RUN_DIR | PATH=$PATH"

# ---------- Run loop ----------
PASS_COUNT=0
i=1
while [ "$i" -le "$REPEAT" ]; do
    iter_tag="iter$i"
    iter_log="$LOG_ROOT/${iter_tag}.out"
    iter_rc="$LOG_ROOT/${iter_tag}.rc"
    iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    log_info "Running $iter_tag/$REPEAT | start: $iso_now | dir: $RESOLVED_RUN_DIR"

    # Execute from the chosen directory so binary can discover local deps
    if [ $HAVE_STDBUF -eq 1 ]; then
        (
            cd "$RESOLVED_RUN_DIR" || exit 127
            run_with_timeout "$TIMEOUT" -- stdbuf -oL -eL "$FASTBIN" -d 3 -U 1 -t linux 
        ) >"$iter_log" 2>&1
        rc=$?
    elif [ $HAVE_SCRIPT -eq 1 ]; then
        (
            cd "$RESOLVED_RUN_DIR" || exit 127
            if [ -n "$TIMEOUT" ] && [ $HAVE_TIMEOUT -eq 1 ]; then
                script -q -c "timeout $TIMEOUT \"$FASTBIN\" -d 3 -U 1 -t linux " /dev/null
            else
                script -q -c "\"$FASTBIN\" -d 3 -U 1 -t linux " /dev/null
            fi
        ) >"$iter_log" 2>&1
        rc=$?
    else
        (
            cd "$RESOLVED_RUN_DIR" || exit 127
            run_with_timeout "$TIMEOUT" -- "$FASTBIN" -d 3 -U 1 -t linux 
        ) >"$iter_log" 2>&1
        rc=$?
    fi

    printf '%s\n' "$rc" >"$iter_rc"

    # Stream the iteration output to console (compact)
    if [ -s "$iter_log" ]; then
        echo "----- $iter_tag output begin -----"
        cat "$iter_log"
        echo "----- $iter_tag output end -----"
    fi

    if [ "$rc" -ne 0 ]; then
        log_fail "$iter_tag: fastrpc_test exited $rc (see $iter_log)"
    fi

    if grep -q "All tests completed successfully" "$iter_log"; then
        PASS_COUNT=$((PASS_COUNT+1))
        log_pass "$iter_tag: success"
    else
        log_warn "$iter_tag: success pattern not found"
    fi

    i=$((i+1))
done

# ---------- Finalize ----------
if [ "$PASS_COUNT" -eq "$REPEAT" ]; then
    log_pass "$TESTNAME : Test Passed ($PASS_COUNT/$REPEAT)"
    echo "$TESTNAME : PASS" > "$RESULT_FILE"
    exit 0
else
    log_fail "$TESTNAME : Test Failed ($PASS_COUNT/$REPEAT)"
    echo "$TESTNAME : FAIL" > "$RESULT_FILE"
    exit 1
fi
