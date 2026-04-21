#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# --------- Robustly source init_env and functestlib.sh ----------

TESTNAME="fastrpc_test"
RESULT_FILE="$TESTNAME.res"
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
    echo "$TESTNAME : FAIL" >"$RESULT_FILE" 2>/dev/null || true
    exit 0
fi

# Only source once (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# ---------------------------------------------------------------

# Defaults
REPEAT=1
TIMEOUT=""
ARCH=""
BIN_DIR="" # directory that CONTAINS fastrpc_test
ASSETS_DIR="" # kept for compatibility/logging (not used by new layout)
VERBOSE=0
UNSIGNED_PD_FLAG=0 # default: -U 0 (system/signed PD)
CLI_DOMAIN=""
CLI_DOMAIN_NAME=""
DOMAIN_MODE="all-supported" # Default: test all supported domains
PD_MODE="both" # Default: test both PDs where supported

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

**Enhanced Test Coverage**:
  This test now validates FastRPC across all supported DSP domains and PD modes.
  - Tests all detected domains: ADSP, MDSP, SDSP, CDSP, CDSP1, GPDSP0, GPDSP1
  - Tests both signed and unsigned Protection Domains where hardware supports them
  - For legacy single-domain testing: use --domain-mode single --domain <N>

Options:
  --arch <name> Architecture (only if explicitly provided)
  --bin-dir <path> Directory containing 'fastrpc_test' (default: /usr/bin)
  --assets-dir <path> (compat) previously used when assets lived under 'linux/'
  --domain <0|1|2|3|4|5|6> DSP domain: 0=ADSP, 1=MDSP, 2=SDSP, 3=CDSP, 4=CDSP1, 5=GPDSP0, 6=GPDSP1
  --domain-name <name> DSP domain by name: adsp|mdsp|sdsp|cdsp|cdsp1|gpdsp0|gpdsp1
  --domain-mode <all-supported|single> Discover all supported domains or run only one (default: all-supported)
  --pd-mode <both|signed-only|unsigned-only> Select PD mode(s) to run (default: both)
  --unsigned-pd Use '-U 1' (user/unsigned PD). Overrides --pd-mode for compatibility
  --repeat <N> Number of repetitions (default: 1)
  --timeout <sec> Timeout for each run (no timeout if omitted)
  --verbose Extra logging for CI debugging
  --help Show this help

Domain Selection Priority:
  1. --domain-name (highest priority, forces single domain)
  2. --domain (forces single domain)
  3. --domain-mode single + FASTRPC_DOMAIN_NAME env
  4. --domain-mode single + FASTRPC_DOMAIN env
  5. --domain-mode all-supported (default, discovers all)

Env:
  FASTRPC_DOMAIN=0|1|2|3|4|5|6 Sets domain; CLI --domain/--domain-name wins.
  FASTRPC_DOMAIN_NAME=adsp|... Named domain; CLI wins.
  FASTRPC_UNSIGNED_PD=0|1 Sets PD (-U value). CLI --unsigned-pd overrides to 1.
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
- Domain mapping: ADSP=0 MDSP=1 SDSP=2 CDSP=3 CDSP1=4 GPDSP0=5 GPDSP1=6
- PD support: ADSP/MDSP/SDSP support signed only; CDSP/CDSP1/GPDSP support both.
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
        --domain-mode) DOMAIN_MODE="$2"; shift 2 ;;
        --pd-mode) PD_MODE="$2"; shift 2 ;;
        --unsigned-pd) UNSIGNED_PD_FLAG=1; shift ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --help) usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument: $1" >&2; usage; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 0 ;;
    esac
done

# ---- Back-compat: accept --assets-dir but ignore in the new /usr/local layout.
# Export so external tooling (or legacy wrappers) can still read it.
if [ -n "${ASSETS_DIR:-}" ]; then
    export ASSETS_DIR
    log_info "(compat) --assets-dir provided: $ASSETS_DIR (ignored with /usr/local layout)"
fi

# ---------- Validation ----------
case "$REPEAT" in *[!0-9]*|"") log_error "Invalid --repeat: $REPEAT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 0 ;; esac
if [ -n "$TIMEOUT" ]; then
    case "$TIMEOUT" in *[!0-9]*|"") log_error "Invalid --timeout: $TIMEOUT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 0 ;; esac
fi
# Validate enhanced options
case "$DOMAIN_MODE" in all-supported|single) : ;; *) log_error "Invalid --domain-mode: $DOMAIN_MODE"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 0 ;; esac
case "$PD_MODE" in both|signed-only|unsigned-only) : ;; *) log_error "Invalid --pd-mode: $PD_MODE"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 0 ;; esac

# Ensure we're in the testcase directory (repo convention)
test_path="$(find_test_case_by_name "$TESTNAME")" || {
    log_error "Cannot locate test path for $TESTNAME"
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
    exit 0
}
cd "$test_path" || {
    log_error "cd to test path failed: $test_path"
    echo "$TESTNAME : FAIL" >"$RESULT_FILE"
    exit 0
}

# -------------------- Helpers --------------------
# shellcheck disable=SC2317 # Helper kept for optional debug use.
log_debug() {
    if [ "$VERBOSE" -eq 1 ]; then
        log_info "[debug] $*" >&2
    fi
}

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

extract_test_summary_counts() {
    log_file="$1"

    total="$(sed -n 's/^[[:space:]]*Total tests run:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"
    passed="$(sed -n 's/^[[:space:]]*Passed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"
    failed="$(sed -n 's/^[[:space:]]*Failed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"
    skipped="$(sed -n 's/^[[:space:]]*Skipped:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"

    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    case "$passed" in ''|*[!0-9]*) passed=0 ;; esac
    case "$failed" in ''|*[!0-9]*) failed=0 ;; esac
    case "$skipped" in ''|*[!0-9]*) skipped=0 ;; esac

    printf '%s:%s:%s:%s\n' "$total" "$passed" "$failed" "$skipped"
}

log_dsp_remoteproc_status() {
    fw_list="adsp mdsp sdsp cdsp cdsp0 cdsp1 gdsp0 gdsp1 gpdsp0 gpdsp1"
    any=0
    for fw in $fw_list; do
        if dt_has_remoteproc_fw "$fw" || [ -n "$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null || true)" ]; then
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
        cdsp1) echo 4 ;;
        gpdsp0|gdsp0) echo 5 ;;
        gpdsp1|gdsp1) echo 6 ;;
        *) echo "" ;;
    esac
}

# Helper to get domain name from id
domain_to_name() {
    case "$1" in
        0) echo "ADSP" ;;
        1) echo "MDSP" ;;
        2) echo "SDSP" ;;
        3) echo "CDSP" ;;
        4) echo "CDSP1" ;;
        5) echo "GPDSP0" ;;
        6) echo "GPDSP1" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# Helper to append unique word
append_unique() {
    current="$1"
    new="$2"
    for word in $current; do
        [ "$word" = "$new" ] && { printf "%s" "$current"; return; }
    done
    [ -n "$current" ] && printf "%s %s" "$current" "$new" || printf "%s" "$new"
}

# Helper to normalize remoteproc/firmware names
canonicalize_domain_name() {
    norm="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$norm" in
        cdsp0) echo "cdsp" ;;
        gdsp0) echo "gpdsp0" ;;
        gdsp1) echo "gpdsp1" ;;
        *) printf "%s" "$norm" ;;
    esac
}

# Discover all supported domains
discover_supported_domains() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - discover_supported_domains: helper-backed discovery active" >&2

    for fw in adsp mdsp sdsp cdsp cdsp0 cdsp1 gpdsp0 gpdsp1 gdsp0 gdsp1; do
        entries="$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null || true)"

        if [ -n "$entries" ]; then
            while IFS='|' read -r rpath rstate rfirm rname; do
                nameguess=""

                if [ -n "$rname" ]; then
                    nameguess="$rname"
                elif [ -n "$rfirm" ]; then
                    nameguess=$(basename "$rfirm" 2>/dev/null | sed 's/\.[^.]*$//')
                fi

                [ -n "$nameguess" ] || continue

                canon="$(canonicalize_domain_name "$nameguess")"
                d="$(name_to_domain "$canon")"

                if [ -n "$d" ]; then
                    printf '%s\n' "$d"
                    log_debug "discover: fw=$fw rname=$rname rfirm=$rfirm canon=$canon domain=$d state=$rstate"
                else
                    log_debug "discover: fw=$fw rname=$rname rfirm=$rfirm canon=$canon domain=<none>"
                fi
            done <<EOF
$entries
EOF
        elif dt_has_remoteproc_fw "$fw"; then
            canon="$(canonicalize_domain_name "$fw")"
            d="$(name_to_domain "$canon")"

            if [ -n "$d" ]; then
                printf '%s\n' "$d"
                log_debug "discover: fw=$fw dt-only canon=$canon domain=$d"
            fi
        else
            log_debug "discover: fw=$fw not present"
        fi
    done
}

# Resolve which domains to test
resolve_domains_to_test() {
    resolved=""
    if [ -n "$CLI_DOMAIN_NAME" ]; then
        resolved="$(name_to_domain "$CLI_DOMAIN_NAME")"
    elif [ -n "$CLI_DOMAIN" ]; then
        resolved="$CLI_DOMAIN"
    elif [ "$DOMAIN_MODE" = "single" ]; then
        if [ -n "${FASTRPC_DOMAIN_NAME:-}" ]; then
            resolved="$(name_to_domain "$FASTRPC_DOMAIN_NAME")"
        elif [ -n "${FASTRPC_DOMAIN:-}" ]; then
            resolved="$FASTRPC_DOMAIN"
        fi
    else
        resolved="$(discover_supported_domains)"
    fi

    log_debug "resolve: raw domains='$resolved'"

    valid=""
    for d in $resolved; do
        case "$d" in
            0|1|2|3|4|5|6)
                case " $valid " in
                    *" $d "*) : ;;
                    *)
                        if [ -n "$valid" ]; then
                            valid="${valid} ${d}"
                        else
                            valid="$d"
                        fi
                        ;;
                esac
                ;;
            *)
                log_warn "Ignoring invalid domain '$d'"
                ;;
        esac
    done
    printf '%s' "$valid"
}

# Get supported PD values for a domain
domain_supported_pds() {
    case "$1" in
        0|1|2) printf "%s" "0" ;; # ADSP/MDSP/SDSP: signed only
        3|4|5|6) printf "%s" "0 1" ;; # CDSP/CDSP1/GPDSP: both
        *) printf "%s" "" ;;
    esac
}

# Get requested PD values
requested_pds() {
    [ "$UNSIGNED_PD_FLAG" -eq 1 ] && { printf "%s" "1"; return; }
    case "$PD_MODE" in
        signed-only) printf "%s" "0" ;;
        unsigned-only) printf "%s" "1" ;;
        both) printf "%s" "0 1" ;;
    esac
}

# Get effective PD values for a domain
effective_pds_for_domain() {
    domain="$1"
    requested="$(requested_pds)"
    supported="$(domain_supported_pds "$domain")"
    effective=""
    for req in $requested; do
        for sup in $supported; do
            [ "$req" = "$sup" ] && effective="$(append_unique "$effective" "$req")"
        done
    done
    printf "%s" "$effective"
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
            exit 0
        fi
    ;;
esac

RUN_DIR="$BIN_DIR"
RUN_BIN="$RUN_DIR/fastrpc_test"

if [ ! -x "$RUN_BIN" ]; then
    log_skip "$TESTNAME SKIP - fastrpc_test not installed (expected at: $RUN_BIN)"
    echo "$TESTNAME : SKIP" >"$RESULT_FILE"
    exit 0
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
# Skeletons: export if present (don't clobber if user already set)
[ -n "$SKEL_PATH" ] && {
    : "${ADSP_LIBRARY_PATH:=$SKEL_PATH}"; export ADSP_LIBRARY_PATH
    : "${CDSP_LIBRARY_PATH:=$SKEL_PATH}"; export CDSP_LIBRARY_PATH
    : "${SDSP_LIBRARY_PATH:=$SKEL_PATH}"; export SDSP_LIBRARY_PATH
}
log_info "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
[ -n "${ADSP_LIBRARY_PATH:-}" ] && log_info "ADSP_LIBRARY_PATH=${ADSP_LIBRARY_PATH}"
[ -n "${CDSP_LIBRARY_PATH:-}" ] && log_info "CDSP_LIBRARY_PATH=${CDSP_LIBRARY_PATH}"
[ -n "${SDSP_LIBRARY_PATH:-}" ] && log_info "SDSP_LIBRARY_PATH=${SDSP_LIBRARY_PATH}"
# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
# Ensure /usr/lib/dsp has the expected DSP artifacts (generic, idempotent)
ensure_usr_lib_dsp_symlinks
# Log *dsp remoteproc statuses via existing helpers
log_dsp_remoteproc_status

# -------------------- Domain and PD selection -------------------
# Resolve domains and PDs to test
DOMAINS_TO_TEST="$(resolve_domains_to_test)"

if [ -z "$DOMAINS_TO_TEST" ]; then
    log_skip "$TESTNAME SKIP - no mapped/supported domains detected"
    echo "$TESTNAME : SKIP" >"$RESULT_FILE"
    exit 0
fi

log_info "Domain mode: $DOMAIN_MODE"
log_info "Domains to test: $DOMAINS_TO_TEST"

# Build human-readable domain names
domain_names=""
for d in $DOMAINS_TO_TEST; do
    n="$(domain_to_name "$d")"
    if [ -n "$domain_names" ]; then
        domain_names="${domain_names},${n}"
    else
        domain_names="$n"
    fi
done
[ -n "$domain_names" ] && log_info "Resolved domain names: $domain_names"

log_info "PD mode: $PD_MODE"

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

# -------------------- Logging root -----------------------------
TS="$(date +%Y%m%d-%H%M%S)"
LOG_ROOT="./logs_${TESTNAME}_${TS}"
mkdir -p "$LOG_ROOT" || { log_error "Cannot create $LOG_ROOT"; echo "$TESTNAME : FAIL" >"$RESULT_FILE"; exit 0; }

tmo_label="none"; [ -n "$TIMEOUT" ] && tmo_label="${TIMEOUT}s"
log_info "Repeats: $REPEAT | Timeout: $tmo_label | Buffering: $buf_label"

# -------------------- Run loop ---------------------------------
# Nested loop over domains and PDs
PASS_COUNT=0
TOTAL_COUNT=0

# Track per-domain/per-PD results during execution
# Format: "DOMAIN:PD:pass_count:fail_count"
RESULTS_TRACKER=""

for DOMAIN in $DOMAINS_TO_TEST; do
    dom_name="$(domain_to_name "$DOMAIN")"
    PD_VALUES="$(effective_pds_for_domain "$DOMAIN")"

    if [ -z "$PD_VALUES" ]; then
        log_warn "Skipping $dom_name: requested PD mode unsupported for this domain"
        continue
    fi

    for PD_VAL in $PD_VALUES; do
        case "$PD_VAL" in
            0) pd_name="signed" ;;
            1) pd_name="unsigned" ;;
            *) pd_name="unknown" ;;
        esac

        # Initialize counters for this domain/PD combo
        combo_pass=0
        combo_fail=0

        i=1
        while [ "$i" -le "$REPEAT" ]; do
            TOTAL_COUNT=$((TOTAL_COUNT+1))

            iter_tag="${dom_name}_${pd_name}_iter${i}"
            iter_log="$LOG_ROOT/${iter_tag}.out"
            iter_rc="$LOG_ROOT/${iter_tag}.rc"
            iter_cmd="$LOG_ROOT/${iter_tag}.cmd"
            iter_env="$LOG_ROOT/${iter_tag}.env"
            iter_dmesg="$LOG_ROOT/${iter_tag}.dmesg"
            iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

            set -- -d "$DOMAIN" -t linux
            [ -n "$ARCH" ] && set -- "$@" -a "$ARCH"
            set -- "$@" -U "$PD_VAL"
            # shellcheck disable=SC2086
            [ -n "${FASTRPC_EXTRA_FLAGS:-}" ] && set -- "$@" ${FASTRPC_EXTRA_FLAGS}

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
                echo "PD_VAL=$PD_VAL ($pd_name)"
                echo "DOMAIN=$DOMAIN ($dom_name)"
                echo "REPEAT=$REPEAT TIMEOUT=${TIMEOUT:-none}"
                echo "EXTRA=${FASTRPC_EXTRA_FLAGS:-}"
            } > "$iter_env"

            log_info "Running $iter_tag | domain=$dom_name | pd=$pd_name"
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
                log_fail "$iter_tag: fastrpc_test exited $rc"
                dmesg | tail -n 300 > "$iter_dmesg" 2>/dev/null
                log_dsp_remoteproc_status
            fi

            # Track result immediately
            if [ "$rc" -eq 0 ] && [ -r "$iter_log" ] && grep -F -q -e "All tests completed successfully" -e "All applicable tests PASSED" "$iter_log"; then
                PASS_COUNT=$((PASS_COUNT+1))
                combo_pass=$((combo_pass+1))
                log_pass "$iter_tag: success"
            else
                combo_fail=$((combo_fail+1))
                log_warn "$iter_tag: success pattern not found"
            fi

            i=$((i+1))
        done

        # Store results for this domain/PD combo
        RESULTS_TRACKER="${RESULTS_TRACKER}${DOMAIN}:${PD_VAL}:${combo_pass}:${combo_fail}
"
    done
done

# -------------------- Finalize --------------------------------
# Build detailed summary table from tracked results
log_info "=========================================================================="
log_info " FastRPC Test Summary"
log_info "=========================================================================="

SUMMARY_FILE="$LOG_ROOT/summary.txt"
true > "$SUMMARY_FILE"

# Display table header
SUMMARY_FMT="%-10s | %-10s | %6s | %6s | %6s | %6s | %-6s"
SUMMARY_SEP="--------------------------------------------------------------------------------"

log_info "$SUMMARY_SEP"
header_line="$(printf "$SUMMARY_FMT" "Domain" "PD Mode" "Total" "Pass" "Fail" "Skip" "Status")"
log_info "$header_line"
log_info "$SUMMARY_SEP"

overall_subtests_total=0
overall_subtests_pass=0
overall_subtests_fail=0
overall_subtests_skip=0

# Parse tracked results and build table
while IFS=: read -r domain pd_val pass_cnt fail_cnt; do
    [ -z "$domain" ] && continue

    dom_name="$(domain_to_name "$domain")"
    case "$pd_val" in
        0) pd_name="Signed" ;;
        1) pd_name="Unsigned" ;;
        *) pd_name="Unknown" ;;
    esac

    combo_total_tests=0
    combo_pass_tests=0
    combo_fail_tests=0
    combo_skip_tests=0

    case "$pd_val" in
        0) pd_tag="signed" ;;
        1) pd_tag="unsigned" ;;
        *) pd_tag="unknown" ;;
    esac

    pattern="$LOG_ROOT/${dom_name}_${pd_tag}_iter"*.out
    for iter_file in $pattern; do
        [ -f "$iter_file" ] || continue

        counts="$(extract_test_summary_counts "$iter_file")"
        t="$(printf '%s' "$counts" | awk -F: '{print $1}')"
        p="$(printf '%s' "$counts" | awk -F: '{print $2}')"
        f="$(printf '%s' "$counts" | awk -F: '{print $3}')"
        s="$(printf '%s' "$counts" | awk -F: '{print $4}')"

        combo_total_tests=$((combo_total_tests + t))
        combo_pass_tests=$((combo_pass_tests + p))
        combo_fail_tests=$((combo_fail_tests + f))
        combo_skip_tests=$((combo_skip_tests + s))
    done

    overall_subtests_total=$((overall_subtests_total + combo_total_tests))
    overall_subtests_pass=$((overall_subtests_pass + combo_pass_tests))
    overall_subtests_fail=$((overall_subtests_fail + combo_fail_tests))
    overall_subtests_skip=$((overall_subtests_skip + combo_skip_tests))

    if [ "$combo_total_tests" -eq 0 ]; then
        status="SKIP"
    elif [ "$combo_fail_tests" -eq 0 ]; then
        status="PASS"
    else
        status="FAIL"
    fi

    line="$(printf "$SUMMARY_FMT" "$dom_name" "$pd_name" "$combo_total_tests" "$combo_pass_tests" "$combo_fail_tests" "$combo_skip_tests" "$status")"
    echo "$line" >> "$SUMMARY_FILE"
    log_info "$line"
done <<EOF
$RESULTS_TRACKER
EOF

log_info "$SUMMARY_SEP"
overall_inv_line="$(printf '%-20s Total:%6d | Passed:%6d | Failed:%6d' \
    'Overall invocations:' "$TOTAL_COUNT" "$PASS_COUNT" "$((TOTAL_COUNT - PASS_COUNT))")"
log_info "$overall_inv_line"

overall_sub_line="$(printf '%-20s Total:%6d | Passed:%6d | Failed:%6d | Skipped:%6d' \
    'Overall subtests:' "$overall_subtests_total" "$overall_subtests_pass" "$overall_subtests_fail" "$overall_subtests_skip")"
log_info "$overall_sub_line"

# Final result determination
if [ "$TOTAL_COUNT" -eq 0 ]; then
    log_skip "$TESTNAME SKIP - no runnable domain/PD combinations"
    echo "$TESTNAME : SKIP" > "$RESULT_FILE"
    exit 0
elif [ "$PASS_COUNT" -eq "$TOTAL_COUNT" ]; then
    log_pass "$TESTNAME : Test Passed ($PASS_COUNT/$TOTAL_COUNT)"
    echo "$TESTNAME : PASS" > "$RESULT_FILE"
    exit 0
else
    log_fail "$TESTNAME : Test Failed ($PASS_COUNT/$TOTAL_COUNT)"
    echo "$TESTNAME : FAIL" > "$RESULT_FILE"
    exit 0
fi
