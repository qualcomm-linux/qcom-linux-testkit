#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
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

# Only source once (idempotent)
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
ARCH=""
BIN_DIR="" # directory that CONTAINS fastrpc_test
ASSETS_DIR="" # kept for compatibility/logging (not used by new layout)
VERBOSE=0
USER_PD_FLAG=0 # default: -U 0 (system/signed PD)
CLI_DOMAIN=""
CLI_DOMAIN_NAME=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --arch <name> Architecture (only if explicitly provided)
  --bin-dir <path> Directory containing 'fastrpc_test' (default: /usr/local/bin)
  --assets-dir <path> (compat) previously used when assets lived under 'linux/'
  --domain <0|1|2|3> DSP domain: 0=ADSP, 1=MDSP, 2=SDSP, 3=CDSP
  --domain-name <name> DSP domain by name: adsp|mdsp|sdsp|cdsp
  --user-pd Use '-U 1' (user/unsigned PD). Default is '-U 0'
  --repeat <N> Number of repetitions (default: 1)
  --timeout <sec> Timeout for each run (no timeout if omitted)
  --verbose Extra logging for CI debugging
  --help Show this help

Env:
  FASTRPC_DOMAIN=0|1|2|3 Sets domain; CLI --domain/--domain-name wins.
  FASTRPC_DOMAIN_NAME=adsp|... Named domain; CLI wins.
  FASTRPC_USER_PD=0|1 Sets PD (-U value). CLI --user-pd overrides to 1.
  FASTRPC_EXTRA_FLAGS Extra flags appended (space-separated).
  ALLOW_BIN_FASTRPC=1 Permit using /bin/fastrpc_test when --bin-dir=/bin.

Notes:
- Script *cd*s into the binary directory and launches ./fastrpc_test.
- Libraries are resolved via:
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/fastrpc_test[:\$LD_LIBRARY_PATH]
- DSP skeletons are resolved via (if present):
    ADSP_LIBRARY_PATH=/usr/local/share/fastrpc_test/v75[:v68]
    CDSP_LIBRARY_PATH=/usr/local/share/fastrpc_test/v75[:v68]
    SDSP_LIBRARY_PATH=/usr/local/share/fastrpc_test/v75[:v68]
- If domain not provided, auto-pick: CDSP if present; else ADSP; else SDSP; else 3.
EOF
}

# --------------------- Parse arguments -------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --bin-dir) BIN_DIR="$2"; shift 2 ;;
        --assets-dir) ASSETS_DIR="$2"; shift 2 ;;
        --domain) CLI_DOMAIN="$2"; shift 2 ;;
        --domain-name) CLI_DOMAIN_NAME="$2"; shift 2 ;;
        --user-pd) USER_PD_FLAG=1; shift ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --help) usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument: $1" >&2; usage; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1 ;;
    esac
done

# ---- Back-compat: accept --assets-dir but ignore in the new /usr/local layout.
# Export so external tooling (or legacy wrappers) can still read it.
if [ -n "${ASSETS_DIR:-}" ]; then
    export ASSETS_DIR
    log_info "(compat) --assets-dir provided: $ASSETS_DIR (ignored with /usr/local layout)"
fi

# ---------- Validation ----------
case "$REPEAT" in *[!0-9]*|"") log_error "Invalid --repeat: $REPEAT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1 ;; esac
if [ -n "$TIMEOUT" ]; then
    case "$TIMEOUT" in *[!0-9]*|"") log_error "Invalid --timeout: $TIMEOUT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1 ;; esac
fi

# Ensure we're in the testcase directory (repo convention)
test_path="$(find_test_case_by_name "$TESTNAME")" || {
    log_error "Cannot locate test path for $TESTNAME"
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
    exit 1
}
cd "$test_path" || {
    log_error "cd to test path failed: $test_path"
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
    exit 1
}

# -------------------- Helpers --------------------
log_debug() { [ "$VERBOSE" -eq 1 ] && log_info "[debug] $*"; }

cmd_to_string() {
    out=""
    for a in "$@"; do
        case "$a" in
            *[!A-Za-z0-9._:/-]*|"")
                q=$(printf "%s" "$a" | sed "s/'/'\\\\''/g")
                out="$out '$q'"
                ;;
            *)
                out="$out $a"
                ;;
        esac
    done
    printf "%s" "$out"
}

log_dsp_remoteproc_status() {
    fw_list="adsp cdsp cdsp0 cdsp1 sdsp gdsp0 gdsp1"
    any=0
    for fw in $fw_list; do
        if dt_has_remoteproc_fw "$fw"; then
            entries="$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null)" || entries=""
            if [ -n "$entries" ]; then
                any=1
                while IFS='|' read -r rpath rstate rfirm rname; do
                    [ -n "$rpath" ] || continue
                    inst="$(basename "$rpath")"
                    log_info "rproc.$fw: $inst path=$rpath state=$rstate fw=$rfirm name=$rname"
                done <<__RPROC__
$entries
__RPROC__
            fi
        fi
    done
    [ $any -eq 0 ] && log_info "rproc: no *dsp remoteproc entries detected via DT"
}

name_to_domain() {
    case "$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')" in
        adsp) echo 0 ;;
        mdsp) echo 1 ;;
        sdsp) echo 2 ;;
        cdsp) echo 3 ;;
        *) echo "" ;;
    esac
}

pick_default_domain() {
    # Prefer CDSP if present; else ADSP; else SDSP; else 3
    if dt_has_remoteproc_fw "cdsp" || dt_has_remoteproc_fw "cdsp0" || dt_has_remoteproc_fw "cdsp1"; then
        echo 3; return
    fi
    if dt_has_remoteproc_fw "adsp"; then
        echo 0; return
    fi
    if dt_has_remoteproc_fw "sdsp"; then
        echo 2; return
    fi
    echo 3
}

# -------------------- Banner --------------------
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "Kernel: $(uname -a 2>/dev/null || echo N/A)"
log_info "Date(UTC): $(date -u 2>/dev/null || echo N/A)"
log_soc_info

# -------------------- Binary directory resolution -----------------
if [ -n "$BIN_DIR" ]; then
    :
else
    BIN_DIR="/usr/bin"
fi

case "$BIN_DIR" in
    /bin)
        if [ "${ALLOW_BIN_FASTRPC:-0}" -ne 1 ]; then
	    log_skip "$TESTNAME SKIP - unsupported layout: /bin. Set ALLOW_BIN_FASTRPC=1 or pass --bin-dir."
            echo "$TESTNAME : SKIP" >"$RESULT_FILE"
            exit 1
        fi
    ;;
esac

RUN_DIR="$BIN_DIR"
RUN_BIN="$RUN_DIR/fastrpc_test"

if [ ! -x "$RUN_BIN" ]; then
    log_skip "$TESTNAME SKIP - fastrpc_test not installed (expected at: $RUN_BIN)"
    echo "$TESTNAME : SKIP" >"$RESULT_FILE"
    exit 1
fi

# New layout checks (replace legacy 'linux/' checks)
LIB_SYS_DIR="/usr/local/lib"
LIB_TEST_DIR="/usr/local/lib/fastrpc_test"
SKEL_BASE="/usr/local/share/fastrpc_test"

SKEL_PATH=""
[ -d "$SKEL_BASE/v75" ] && SKEL_PATH="${SKEL_PATH:+$SKEL_PATH:}$SKEL_BASE/v75"
[ -d "$SKEL_BASE/v68" ] && SKEL_PATH="${SKEL_PATH:+$SKEL_PATH:}$SKEL_BASE/v68"

[ -d "$LIB_SYS_DIR" ] || log_warn "Missing system libs dir: $LIB_SYS_DIR (lib{adsp,cdsp,sdsp}rpc*.so expected)"
[ -d "$LIB_TEST_DIR" ] || log_warn "Missing test libs dir: $LIB_TEST_DIR (libcalculator.so, etc.)"
[ -n "$SKEL_PATH" ] || log_warn "No DSP skeleton dirs found under: $SKEL_BASE (expected v75/ v68/)"

log_info "Using binary: $RUN_BIN"
log_info "Run dir: $RUN_DIR (launching ./fastrpc_test)"
log_info "Binary details:"
log_info " ls -l: $(ls -l "$RUN_BIN" 2>/dev/null || echo 'N/A')"
log_info " file : $(file "$RUN_BIN" 2>/dev/null || echo 'N/A')"

# >>>>>>>>>>>>>>>>>>>>>> ENV for your initramfs layout <<<<<<<<<<<<<<<<<<<<<<
# Libraries: system + test payloads
export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib/fastrpc_test${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Skeletons: export if present (don’t clobber if user already set)
[ -n "$SKEL_PATH" ] && {
    : "${ADSP_LIBRARY_PATH:=$SKEL_PATH}"; export ADSP_LIBRARY_PATH
    : "${CDSP_LIBRARY_PATH:=$SKEL_PATH}"; export CDSP_LIBRARY_PATH
    : "${SDSP_LIBRARY_PATH:=$SKEL_PATH}"; export SDSP_LIBRARY_PATH
}
log_info "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
[ -n "$ADSP_LIBRARY_PATH" ] && log_info "ADSP_LIBRARY_PATH=${ADSP_LIBRARY_PATH}"
[ -n "$CDSP_LIBRARY_PATH" ] && log_info "CDSP_LIBRARY_PATH=${CDSP_LIBRARY_PATH}"
[ -n "$SDSP_LIBRARY_PATH" ] && log_info "SDSP_LIBRARY_PATH=${SDSP_LIBRARY_PATH}"
# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
# Ensure /usr/lib/dsp has the expected DSP artifacts (generic, idempotent)
ensure_usr_lib_dsp_symlinks
# Log *dsp remoteproc statuses via existing helpers
log_dsp_remoteproc_status

# -------------------- PD selection -------------------
PD_VAL="${FASTRPC_USER_PD:-0}"
[ "$USER_PD_FLAG" -eq 1 ] && PD_VAL=1
log_info "PD setting: -U $PD_VAL (use --user-pd or FASTRPC_USER_PD=1 to change)"

# -------------------- Domain selection -------------------
DOMAIN=""
# Precedence: CLI name -> CLI number -> env name -> env number -> auto-pick
if [ -n "$CLI_DOMAIN_NAME" ]; then
    DOMAIN="$(name_to_domain "$CLI_DOMAIN_NAME")"
elif [ -n "$CLI_DOMAIN" ]; then
    DOMAIN="$CLI_DOMAIN"
elif [ -n "${FASTRPC_DOMAIN_NAME:-}" ]; then
    DOMAIN="$(name_to_domain "$FASTRPC_DOMAIN_NAME")"
elif [ -n "${FASTRPC_DOMAIN:-}" ]; then
    DOMAIN="$FASTRPC_DOMAIN"
fi

# Validate / auto-pick
case "$DOMAIN" in
    0|1|2|3) : ;;
    "" )
        DOMAIN="$(pick_default_domain)"
        log_info "Domain auto-picked: -d $DOMAIN (CDSP=3, ADSP=0, SDSP=2)"
        ;;
    * )
        log_warn "Invalid domain '$DOMAIN' auto-picking"
        DOMAIN="$(pick_default_domain)"
        ;;
esac

case "$DOMAIN" in
    0) dom_name="ADSP" ;;
    1) dom_name="MDSP" ;;
    2) dom_name="SDSP" ;;
    3) dom_name="CDSP" ;;
esac
log_info "Domain: -d $DOMAIN ($dom_name)"

# -------------------- Buffering tool availability ---------------
HAVE_STDBUF=0; command -v stdbuf >/dev/null 2>&1 && HAVE_STDBUF=1
HAVE_SCRIPT=0; command -v script >/dev/null 2>&1 && HAVE_SCRIPT=1
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

buf_label="none"
if [ $HAVE_STDBUF -eq 1 ]; then
    buf_label="stdbuf -oL -eL"
elif [ $HAVE_SCRIPT -eq 1 ]; then
    buf_label="script -q"
fi

# -------------------- Build argv safely -------------------------
set -- -d "$DOMAIN" -t linux

if [ -n "$ARCH" ]; then
    set -- "$@" -a "$ARCH"
    log_info "Arch option: -a $ARCH"
else
    log_info "No --arch provided; running without -a"
fi

set -- "$@" -U "$PD_VAL"

if [ -n "$FASTRPC_EXTRA_FLAGS" ]; then
    # shellcheck disable=SC2086
    set -- "$@" $FASTRPC_EXTRA_FLAGS
    log_info "Extra flags: $FASTRPC_EXTRA_FLAGS"
fi

# -------------------- Logging root -----------------------------
TS="$(date +%Y%m%d-%H%M%S)"
LOG_ROOT="./logs_${TESTNAME}_${TS}"
mkdir -p "$LOG_ROOT" || { log_error "Cannot create $LOG_ROOT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 1; }

tmo_label="none"; [ -n "$TIMEOUT" ] && tmo_label="${TIMEOUT}s"
log_info "Repeats: $REPEAT | Timeout: $tmo_label | Buffering: $buf_label"

# -------------------- Run loop ---------------------------------
PASS_COUNT=0
i=1
while [ "$i" -le "$REPEAT" ]; do
    iter_tag="iter$i"
    iter_log="$LOG_ROOT/${iter_tag}.out"
    iter_rc="$LOG_ROOT/${iter_tag}.rc"
    iter_cmd="$LOG_ROOT/${iter_tag}.cmd"
    iter_env="$LOG_ROOT/${iter_tag}.env"
    iter_dmesg="$LOG_ROOT/${iter_tag}.dmesg"
    iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    {
        echo "DATE_UTC=$iso_now"
        echo "RUN_DIR=$RUN_DIR"
        echo "RUN_BIN=$RUN_BIN"
        echo "PATH=$PATH"
        echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
        echo "ADSP_LIBRARY_PATH=${ADSP_LIBRARY_PATH:-}"
        echo "CDSP_LIBRARY_PATH=${CDSP_LIBRARY_PATH:-}"
        echo "SDSP_LIBRARY_PATH=${SDSP_LIBRARY_PATH:-}"
        echo "ARCH=${ARCH:-}"
        echo "PD_VAL=$PD_VAL"
        echo "DOMAIN=$DOMAIN ($dom_name)"
        echo "REPEAT=$REPEAT TIMEOUT=${TIMEOUT:-none}"
        echo "EXTRA=$FASTRPC_EXTRA_FLAGS"
    } > "$iter_env"

    log_info "Running $iter_tag/$REPEAT | start: $iso_now | dir: $RUN_DIR"
    log_info "Executing: ./fastrpc_test$(cmd_to_string "$@")"
    printf "./fastrpc_test%s\n" "$(cmd_to_string "$@")" > "$iter_cmd"

    (
        cd "$RUN_DIR" || exit 127
        if [ $HAVE_STDBUF -eq 1 ]; then
             runWithTimeoutIfSet stdbuf -oL -eL ./fastrpc_test "$@"
        elif [ $HAVE_SCRIPT -eq 1 ]; then
            cmd_str="./fastrpc_test$(cmd_to_string "$@")"
            if [ -n "$TIMEOUT" ] && [ $HAVE_TIMEOUT -eq 1 ]; then
                script -q -c "timeout $TIMEOUT $cmd_str" /dev/null
            else
                script -q -c "$cmd_str" /dev/null
            fi
        else
            runWithTimeoutIfSet ./fastrpc_test "$@"
        fi
    ) >"$iter_log" 2>&1
    rc=$?

    printf '%s\n' "$rc" >"$iter_rc"

    if [ -s "$iter_log" ]; then
        echo "----- $iter_tag output begin -----"
        cat "$iter_log"
        echo "----- $iter_tag output end -----"
    fi

    if [ "$rc" -ne 0 ]; then
        log_fail "$iter_tag: fastrpc_test exited $rc (see $iter_log)"
        dmesg | tail -n 300 > "$iter_dmesg" 2>/dev/null
        log_dsp_remoteproc_status
    fi

	if [ -r "$iter_log" ] && grep -F -q -e "All tests completed successfully" -e "All applicable tests PASSED" "$iter_log"; then
        PASS_COUNT=$((PASS_COUNT+1))
        log_pass "$iter_tag: success"
    else
        log_warn "$iter_tag: success pattern not found"
    fi

    i=$((i+1))
done

# -------------------- Finalize --------------------------------
if [ "$PASS_COUNT" -eq "$REPEAT" ]; then
    log_pass "$TESTNAME : Test Passed ($PASS_COUNT/$REPEAT)"
    echo "$TESTNAME : PASS" > "$RESULT_FILE"
else
    log_fail "$TESTNAME : Test Failed ($PASS_COUNT/$REPEAT)"
    echo "$TESTNAME : FAIL" > "$RESULT_FILE"
fi

[ -f "$RESULT_FILE" ] || {
    log_error "Missing result file ($RESULT_FILE) — creating FAIL"
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
}

exit 0
