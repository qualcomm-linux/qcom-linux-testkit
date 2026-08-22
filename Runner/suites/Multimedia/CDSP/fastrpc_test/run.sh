#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# --------- Robustly source init_env and functestlib.sh ----------

TESTNAME="fastrpc_test"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
RESULT_FILE="$RES_FILE"
 
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
    echo "$TESTNAME FAIL" >"$RES_FILE" 2>/dev/null || true
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
 
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_fastrpc.sh"
 
# Optional generic package-set recovery.
# This must be a clean no-op when no package-set mapping exists for the active OS/provider.
if [ -f "$TOOLS/lib_pkg_provider.sh" ]; then
    # shellcheck disable=SC1091
    . "$TOOLS/lib_pkg_provider.sh"
 
    if ! pkg_ensure_package_set fastrpc; then
        log_skip "$TESTNAME SKIP - required package set is not available: fastrpc"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
fi

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
- Libraries and DSP skeletons are auto-discovered using lib_fastrpc.sh.
- Supported layouts include:
    Yocto/current:
      /usr/local/lib
      /usr/local/lib/fastrpc_test
      /usr/local/share/fastrpc_test
    Debian:
      /usr/lib/<multiarch>
      /usr/lib/<multiarch>/fastrpc_test
      /usr/share/fastrpc_test
- Optional overrides:
    FASTRPC_LIB_SYS_DIR
    FASTRPC_LIB_TEST_DIR
    FASTRPC_SKEL_BASE
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

# ---- Back-compat: accept --assets-dir but ignore in the new auto-discovered layout.
# Export so external tooling (or legacy wrappers) can still read it.
if [ -n "${ASSETS_DIR:-}" ]; then
    export ASSETS_DIR
    log_info "(compat) --assets-dir provided: $ASSETS_DIR (ignored with auto-discovered FastRPC runtime layout)"
fi

# Variables consumed by sourced FastRPC helper functions in lib_fastrpc.sh.
# Export them so ShellCheck treats this as an explicit run.sh -> lib_fastrpc.sh
# interface instead of reporting SC2034.
export CLI_DOMAIN
export CLI_DOMAIN_NAME
export UNSIGNED_PD_FLAG
export VERBOSE

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

# FastRPC helper functions are provided by Runner/utils/lib_fastrpc.sh.

# -------------------- Banner --------------------
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "Kernel: $(uname -a 2>/dev/null || echo N/A)"
log_info "Date(UTC): $(date -u 2>/dev/null || echo N/A)"
log_soc_info
SOC_MACHINE="$(tr -s ' ' < /sys/devices/soc0/machine 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

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

# -------------------- Runtime layout discovery --------------------
fastrpc_setup_runtime_layout

log_info "Using binary: $RUN_BIN"
log_info "Run dir: $RUN_DIR (launching ./fastrpc_test)"
log_info "Binary details:"
log_info " ls -l: $(ls -l "$RUN_BIN" 2>/dev/null || echo 'N/A')"
log_info " file : $(file "$RUN_BIN" 2>/dev/null || echo 'N/A')"

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

# -------------------- SoC-specific domain blacklist --------------------
# QCS9075, QCS8275, QCS8300, QCS9100: GPDSP0 (domain 5) and GPDSP1 (domain 6) not supported currently
soc_skip_all=0
soc_skip_gpdsp=0

case "$SOC_MACHINE" in
    *QCS9075*|*QCS8275*|*QCS8300*|*QCS9100*)
        soc_skip_gpdsp=1
        ;;
esac

if [ "$soc_skip_all" -eq 1 ]; then
    log_skip "$TESTNAME SKIP - SoC $SOC_MACHINE does not support FastRPC"
    echo "$TESTNAME : SKIP" >"$RESULT_FILE"
    exit 0
fi

if [ "$soc_skip_gpdsp" -eq 1 ]; then
    filtered=""
    for d in $DOMAINS_TO_TEST; do
        case "$d" in
            5|6) log_info "SoC $SOC_MACHINE: skipping $(domain_to_name "$d") (not supported)" ;;
            *) filtered="${filtered:+$filtered }$d" ;;
        esac
    done
    DOMAINS_TO_TEST="$filtered"
fi

if [ -z "$DOMAINS_TO_TEST" ]; then
    log_skip "$TESTNAME SKIP - no supported domains remain after SoC filter ($SOC_MACHINE)"
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
# Format: "DOMAIN:PD:pass_count:fail_count:subtests_total:subtests_pass:subtests_fail:subtests_skip"
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
        combo_subtests_total=0
        combo_subtests_pass=0
        combo_subtests_fail=0
        combo_subtests_skip=0

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

            # Extract and accumulate subtest counts from this iteration's log
            if [ -r "$iter_log" ]; then
                iter_counts="$(extract_test_summary_counts "$iter_log")"
                iter_t="$(printf '%s' "$iter_counts" | awk -F: '{print $1}')"
                iter_p="$(printf '%s' "$iter_counts" | awk -F: '{print $2}')"
                iter_f="$(printf '%s' "$iter_counts" | awk -F: '{print $3}')"
                iter_s="$(printf '%s' "$iter_counts" | awk -F: '{print $4}')"
                combo_subtests_total=$((combo_subtests_total + iter_t))
                combo_subtests_pass=$((combo_subtests_pass + iter_p))
                combo_subtests_fail=$((combo_subtests_fail + iter_f))
                combo_subtests_skip=$((combo_subtests_skip + iter_s))
            fi

            # Track invocation result immediately
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

        # Store results for this domain/PD combo (including subtest counts)
        RESULTS_TRACKER="${RESULTS_TRACKER}${DOMAIN}:${PD_VAL}:${combo_pass}:${combo_fail}:${combo_subtests_total}:${combo_subtests_pass}:${combo_subtests_fail}:${combo_subtests_skip}
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
SUMMARY_SEP="--------------------------------------------------------------------------------"

log_info "$SUMMARY_SEP"
header_line="$(printf '%-10s | %-10s | %6s | %6s | %6s | %6s | %-6s' "Domain" "PD Mode" "Total" "Pass" "Fail" "Skip" "Status")"
log_info "$header_line"
log_info "$SUMMARY_SEP"

overall_subtests_total=0
overall_subtests_pass=0
overall_subtests_fail=0
overall_subtests_skip=0

# shellcheck disable=SC2034 # _pass_cnt/_fail_cnt consumed from tracker but not used in display
while IFS=: read -r domain pd_val _pass_cnt _fail_cnt combo_total_tests combo_pass_tests combo_fail_tests combo_skip_tests; do
    [ -z "$domain" ] && continue

    dom_name="$(domain_to_name "$domain")"
    case "$pd_val" in
        0) pd_name="Signed" ;;
        1) pd_name="Unsigned" ;;
        *) pd_name="Unknown" ;;
    esac

    # Sanitize counts read from tracker
    case "$combo_total_tests" in ''|*[!0-9]*) combo_total_tests=0 ;; esac
    case "$combo_pass_tests" in ''|*[!0-9]*) combo_pass_tests=0 ;; esac
    case "$combo_fail_tests" in ''|*[!0-9]*) combo_fail_tests=0 ;; esac
    case "$combo_skip_tests" in ''|*[!0-9]*) combo_skip_tests=0 ;; esac

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

    line="$(printf '%-10s | %-10s | %6s | %6s | %6s | %6s | %-6s' "$dom_name" "$pd_name" "$combo_total_tests" "$combo_pass_tests" "$combo_fail_tests" "$combo_skip_tests" "$status")"
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
