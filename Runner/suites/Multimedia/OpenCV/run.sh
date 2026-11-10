#!/bin/sh
# OpenCV test/perf suite runner (auto-discovery; per-binary skip; summary; proper exit codes)
# SPDX-License-Identifier: BSD-3-Clause
# ----- locate and source init_env -----
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
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="OpenCV"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
LOG_DIR="${LOG_DIR:-$PWD/logs}"
mkdir -p "$LOG_DIR" || test_result_finish FAIL "Cannot create OpenCV logs at $LOG_DIR"
LOG_DIR=$(CDPATH='' cd "$LOG_DIR" && pwd -P) || test_result_finish FAIL "Cannot resolve OpenCV log directory"
SUMMARY_FILE="$LOG_DIR/$TESTNAME.summary"
RESLIST_FILE="$LOG_DIR/${TESTNAME}.reslist"
: > "$RESLIST_FILE"
: > "$SUMMARY_FILE"

# ---------- defaults / cli ----------
# We compute the final filter AFTER parsing CLI to honor precedence:
# CLI --filter > env GTEST_FILTER > env GTEST_FILTER_STRING > DEFAULT_FILTER
DEFAULT_FILTER="-tracking_GOTURN.GOTURN/*"
CLI_FILTER=""

BIN_PATH="" # --bin <path|name>
BIN_LIST="" # --bin-list "bin1 bin2 ..."
BUILD_DIR="." # --build-dir
CWD="." # --cwd
TESTDATA_PATH="" # --testdata
EXTRA_ARGS="" # --args "..."
TIMEOUT_SECS="" # --timeout N
SUITE_TIMEOUT_SECS="" # --suite-timeout N
SUITE="all" # --suite accuracy|performance|all|smoke
LIST_ONLY=0 # --list
REPEAT="" # --repeat N
SHUFFLE=0 # --shuffle
SEED="" # --seed N
PERF_ARGS="" # --perf-args "<common perf args>"
PERF_TO_TESTS=0 # --perf-to-tests (apply PERF_ARGS to opencv_test_* too)

print_usage() {
    cat <<EOF
Usage: $0 [options]
  --bin <path|name> Run a single OpenCV gtest/perf binary (overrides --suite)
  --bin-list "<bin1 bin2 ...>" Run selected OpenCV binaries and aggregate result
  --build-dir <path> Root to search for binaries (default: .)
  --suite <name> accuracy | performance | all | smoke (default: all)
                 smoke runs in-memory core matrix tests without external data
  --filter <pattern> gtest filter for all runs (default from env or "-tracking_GOTURN.GOTURN/*")
  --repeat <N> gtest repeat count
  --shuffle [0|1] Enable shuffle, or explicitly disable it with 0
  --seed <N> gtest random seed
  --cwd <path> Working directory for test execution (default: .)
  --testdata <path> Export OPENCV_TEST_DATA_PATH to this dir
  --args "<args>" Extra args added to all test binaries
  --timeout <sec> Bound one run using the shared managed timeout helper
  --perf-args "<args>" Extra args appended to all opencv_perf_* runs
  --perf-to-tests Also append --perf-args to opencv_test_* runs
  --list [0|1] List tests without execution (SKIP), or disable listing with 0
  --suite-timeout <sec> Bound all selected binaries together (default: no total bound)
  -h|--help Show this help

Env honored:
  OPENCV_TEST_DATA_PATH, GTEST_FILTER, GTEST_FILTER_STRING
EOF
}

# parse_args <arguments>
# Preserve flag-only forms and accept explicit boolean values from CI plans.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --list|--shuffle)
                cv_flag="$1"
                cv_enabled=1
                shift
                case "${1:-}" in
                    0|1)
                        cv_enabled="$1"
                        shift
                        ;;
                esac
                if [ "$cv_flag" = "--list" ]; then
                    LIST_ONLY="$cv_enabled"
                else
                    SHUFFLE="$cv_enabled"
                fi
                ;;
            --bin|--bin-list|--build-dir|--suite|--filter|--repeat|--seed|--cwd|--testdata|--args|--timeout|--suite-timeout|--perf-args)
                [ "$#" -ge 2 ] || test_result_finish FAIL "Missing value for $1"
                case "$1" in
                    --bin)
                        BIN_PATH="$2"
                        ;;
                    --bin-list)
                        BIN_LIST="$2"
                        ;;
                    --build-dir)
                        BUILD_DIR="$2"
                        ;;
                    --suite)
                        SUITE="$2"
                        ;;
                    --filter)
                        CLI_FILTER="$2"
                        ;;
                    --repeat)
                        REPEAT="$2"
                        ;;
                    --seed)
                        SEED="$2"
                        ;;
                    --cwd)
                        CWD="$2"
                        ;;
                    --testdata)
                        TESTDATA_PATH="$2"
                        ;;
                    --args)
                        EXTRA_ARGS="$2"
                        ;;
                    --timeout)
                        TIMEOUT_SECS="$2"
                        ;;
                    --suite-timeout)
                        SUITE_TIMEOUT_SECS="$2"
                        ;;
                    --perf-args)
                        PERF_ARGS="$2"
                        ;;
                esac
                shift 2
                ;;
            --perf-to-tests)
                PERF_TO_TESTS=1
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                test_result_finish FAIL "Unknown option: $1"
                ;;
        esac
    done
}
parse_args "$@"
case "$SUITE" in
    all|accuracy|performance|smoke)
        ;;
    *)
        test_result_finish FAIL "Unknown OpenCV suite: $SUITE"
        ;;
esac
if [ "$SUITE" = smoke ]; then
    # These upstream gtest suites construct their own matrices. The installed
    # binary selects its available cases, no board or release mapping is used.
    DEFAULT_FILTER="Core_Mat.*:Core_MatExpr.*:Core_IOArray.*"
    if [ -z "$BIN_PATH" ] && [ -z "$BIN_LIST" ]; then
        BIN_LIST="opencv_test_core"
    fi
    TIMEOUT_SECS=${TIMEOUT_SECS:-120}
    SUITE_TIMEOUT_SECS=${SUITE_TIMEOUT_SECS:-180}
fi
for cv_bound in "$TIMEOUT_SECS" "$SUITE_TIMEOUT_SECS"; do
    [ -n "$cv_bound" ] || continue
    if ! is_unsigned_number "$cv_bound" || [ "$cv_bound" -eq 0 ]; then
        test_result_finish FAIL "OpenCV timeout must be a positive integer, received '$cv_bound'"
    fi
done
SUITE_STARTED=$(get_monotonic_seconds)

# ----- PATH enrichment so check_dependencies can see build dir binaries -----
case ":$PATH:" in
  *":$BUILD_DIR/bin:"*) ;;
  *) [ -d "$BUILD_DIR/bin" ] && PATH="$BUILD_DIR/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$BUILD_DIR:"*) ;;
  *) [ -d "$BUILD_DIR" ] && PATH="$BUILD_DIR:$PATH" ;;
esac
export PATH

# ----- OPENCV_TEST_DATA_PATH (explicit or auto) -----
if [ -n "$TESTDATA_PATH" ]; then
    if [ -d "$TESTDATA_PATH" ]; then
        export OPENCV_TEST_DATA_PATH="$TESTDATA_PATH"
    else
        log_warn "--testdata provided but not found: $TESTDATA_PATH (continuing)"
    fi
elif [ -z "${OPENCV_TEST_DATA_PATH:-}" ]; then
    for cand in \
        /var/testdata \
        /usr/share/opencv4/testdata \
        /usr/share/opencv/testdata \
        /opt/opencv_extra/testdata \
        "$SCRIPT_DIR/../../testdata"
    do
        if [ -d "$cand" ]; then export OPENCV_TEST_DATA_PATH="$cand"; break; fi
    done
fi

# ----- resolve final gtest filter with precedence -----
FINAL_FILTER="$DEFAULT_FILTER"
[ -n "${GTEST_FILTER_STRING:-}" ] && FINAL_FILTER="$GTEST_FILTER_STRING"
[ -n "${GTEST_FILTER:-}" ] && FINAL_FILTER="$GTEST_FILTER"
[ -n "$CLI_FILTER" ] && FINAL_FILTER="$CLI_FILTER"

# Export for children and also use internally
export GTEST_FILTER_STRING="$FINAL_FILTER"
GTEST_FILTER="$FINAL_FILTER"

# ----- set default PERF_ARGS early so logs always show it -----
if [ -z "$PERF_ARGS" ]; then
    PERF_ARGS="--perf_impl=plain --perf_min_samples=10 --perf_force_samples=10 --perf_verify_sanity --skip_unstable=1"
fi

# ----- helpers -----
resolve_bin() {
    bn="$1"
    if [ -x "$bn" ]; then printf "%s" "$bn"; return 0; fi
    if [ -x "$BUILD_DIR/bin/$bn" ]; then printf "%s" "$BUILD_DIR/bin/$bn"; return 0; fi
    if [ -x "$BUILD_DIR/$bn" ]; then printf "%s" "$BUILD_DIR/$bn"; return 0; fi
    if command -v "$bn" >/dev/null 2>&1; then command -v "$bn"; return 0; fi
    fnd="$(find "$BUILD_DIR" -maxdepth 3 -type f -name "$bn" -perm -111 2>/dev/null | head -n 1)"
    [ -n "$fnd" ] && { printf "%s" "$fnd"; return 0; }
    return 1
}

append_summary() {
    # args: name status logpath
    printf "%-32s %-4s %s\n" "$1" "$2" "$3" >> "$SUMMARY_FILE"
}

parse_zero_tests_as_skip() {
    # Return 0 (true) if log shows "Running 0 tests ..." (suites or cases wording) or "No tests to run"
    logp="$1"
    grep -Eq 'Running 0 tests from 0 test (suites|cases)\.' "$logp" \
      || grep -qi 'No tests to run' "$logp"
}

run_one() {
    bin_short="$1"
    bin_extra="$2"

    # An explicit --bin has already been resolved. Retain that exact executable
    # even when the build directory contains another binary with the same name.
    bin_path="${3:-}"
    if [ -z "$bin_path" ]; then
        bin_path="$(resolve_bin "$bin_short")"
    fi
    if [ -z "$bin_path" ]; then
        log_skip "$bin_short : not found — SKIP"
        echo "$bin_short SKIP" >> "$RESLIST_FILE"
        append_summary "$bin_short" "SKIP" "-"
        return 2
    fi

    effective_timeout="$TIMEOUT_SECS"
    if [ -n "$SUITE_TIMEOUT_SECS" ]; then
        remaining=$((SUITE_TIMEOUT_SECS - $(get_monotonic_seconds) + SUITE_STARTED))
        if [ "$remaining" -le 0 ]; then
            log_fail "$bin_short : suite execution budget exhausted, no new workload was started"
            printf '%s FAIL\n' "$bin_short" >>"$RESLIST_FILE"
            append_summary "$bin_short" "FAIL" "not-started-budget-exhausted"
            return 1
        fi
        if [ -z "$effective_timeout" ] || [ "$remaining" -lt "$effective_timeout" ]; then
            effective_timeout="$remaining"
        fi
    fi

    # Build argument list
    ts="$(date +%Y%m%d-%H%M%S)"
    cv_color=yes
    if [ "$SUITE" = smoke ]; then
        cv_color=no
    fi
    gargs="--gtest_color=$cv_color --gtest_filter=$GTEST_FILTER"
    [ -n "$REPEAT" ] && gargs="$gargs --gtest_repeat=$REPEAT"
    [ "$SHUFFLE" -eq 1 ] && gargs="$gargs --gtest_shuffle"
    [ -n "$SEED" ] && gargs="$gargs --gtest_random_seed=$SEED"
    [ "$LIST_ONLY" -eq 1 ] && gargs="$gargs --gtest_list_tests"
    [ -n "$EXTRA_ARGS" ] && gargs="$gargs $EXTRA_ARGS"
    [ -n "$bin_extra" ] && gargs="$gargs $bin_extra"

    perf_applied="no"
    case "$bin_short" in
        opencv_perf_*)
            # If suite didn't pass PERF_ARGS as bin_extra (single-binary mode), apply them here.
            if [ -z "$bin_extra" ] && [ -n "$PERF_ARGS" ]; then
                gargs="$gargs $PERF_ARGS"
            fi
            perf_applied="yes"
            ;;
        opencv_test_*)
            if [ "$PERF_TO_TESTS" -eq 1 ] && [ -n "$PERF_ARGS" ]; then
                # If not already provided via bin_extra, add now.
                case " $gargs " in
                    *" $PERF_ARGS "*) : ;; # already included
                    *) gargs="$gargs $PERF_ARGS" ;;
                esac
                perf_applied="yes"
            fi
            ;;
    esac

    run_log="$LOG_DIR/${bin_short}_${ts}.log"

    now="$(date '+%Y-%m-%d %H:%M:%S')"
    log_info "----- START $bin_short @ $now -----"
    log_info "Running $bin_short"
    log_info "Binary : $bin_path"
    [ -n "${OPENCV_TEST_DATA_PATH:-}" ] && log_info "OPENCV_TEST_DATA_PATH=$OPENCV_TEST_DATA_PATH"
    log_info "GTEST_FILTER_STRING: '$GTEST_FILTER_STRING'"
    log_info "Args : $gargs"
    if [ "$perf_applied" = "yes" ]; then
        log_info "PerfArgs (applied): ${PERF_ARGS:-<none>}"
    else
        log_info "PerfArgs (available, not applied): ${PERF_ARGS:-<none>}"
    fi

    cmd="$bin_path $gargs"
    if [ -n "$effective_timeout" ]; then
        log_info "Cmd : $cmd (via managed timeout $effective_timeout)"
    else
        log_info "Cmd : $cmd"
    fi
    log_info "Log : $run_log"

    (
        cd "$CWD" || exit 2
        if [ -n "$effective_timeout" ]; then
            cv_use_session=0
            if command -v setsid >/dev/null 2>&1; then
                cv_use_session=1
            fi
            MANAGED_TIMEOUT_USE_SESSION="$cv_use_session" \
                run_with_managed_timeout "$effective_timeout" "$LOG_DIR" OpenCV \
                    sh -c "exec \"\$1\" $gargs" sh "$bin_path"
        else
            sh -c "exec \"\$1\" $gargs" sh "$bin_path"
        fi
    ) >"$run_log" 2>&1
    rc=$?
    timed_out=0

    case "$rc" in
        124|137|143)
            if [ -n "$effective_timeout" ]; then
                timed_out=1
            fi
            ;;
    esac

    if [ "$rc" -eq 0 ] && grep -Eq '\[[[:space:]]*FAILED[[:space:]]*\]' "$run_log"; then
        log_fail "$bin_short : output reports failed tests despite exit zero"
        rc=1
    fi

    if [ "$rc" -eq 0 ]; then
        case " $gargs " in
            *" --gtest_list_tests "*|*" --gtest_list_tests=1 "*|*" --gtest_list_tests=true "*)
                log_skip "$bin_short : listing only, no functional tests executed"
                printf '%s SKIP\n' "$bin_short" >>"$RESLIST_FILE"
                append_summary "$bin_short" "SKIP" "$run_log"
                return 2
                ;;
        esac
    fi

    if [ "$rc" -eq 0 ] && parse_zero_tests_as_skip "$run_log"; then
        log_skip "$bin_short : No tests executed — SKIP"
        echo "$bin_short SKIP" >> "$RESLIST_FILE"
        append_summary "$bin_short" "SKIP" "$run_log"
        log_info "----- END $bin_short (rc=0, SKIP) @ $(date '+%Y-%m-%d %H:%M:%S') -----"
        return 2
    fi

    if [ "$rc" -eq 0 ]; then
        cv_summary=$(sed -n "s/$(printf '\033')\[[0-9;]*m//g; /\[[[:space:]]*PASSED[[:space:]]*\]/p; /\[[[:space:]]*SKIPPED[[:space:]]*\]/p; /\[[[:space:]]*FAILED[[:space:]]*\]/p" "$run_log")
        if printf '%s\n' "$cv_summary" | grep -Eq '\[[[:space:]]*FAILED[[:space:]]*\]'; then
            log_fail "$bin_short : output reports failed tests despite exit zero"
            rc=1
        elif printf '%s\n' "$cv_summary" |
           grep -Eq '\[[[:space:]]*PASSED[[:space:]]*\][[:space:]]+[1-9][0-9]* test'; then
            :
        elif printf '%s\n' "$cv_summary" |
             grep -Eq '\[[[:space:]]*SKIPPED[[:space:]]*\][[:space:]]+[1-9][0-9]* test'; then
            log_skip "$bin_short : selected gtests skipped, no successful workload"
            printf '%s SKIP\n' "$bin_short" >>"$RESLIST_FILE"
            append_summary "$bin_short" "SKIP" "$run_log"
            return 2
        else
            log_fail "$bin_short : no positive gtest execution summary, validation is incomplete"
            rc=1
        fi
    fi

    if [ "$rc" -eq 0 ]; then
        log_pass "$bin_short : PASS"
        echo "$bin_short PASS" >> "$RESLIST_FILE"
        append_summary "$bin_short" "PASS" "$run_log"
        log_info "----- END $bin_short (rc=0, PASS) @ $(date '+%Y-%m-%d %H:%M:%S') -----"
        return 0
    fi

    if [ "$timed_out" -eq 1 ]; then
        log_fail "$bin_short : FAIL/TIMEOUT after ${effective_timeout}s (exit=$rc). See: $run_log"
    else
        log_fail "$bin_short : FAIL (exit=$rc). See: $run_log"
    fi
    # Retain the complete log and replay its ending, where gtest reports the
    # failing cases and asset errors. Do not replace a crash with an asset SKIP.
    if command -v tail >/dev/null 2>&1; then
        if tail -n 80 "$run_log" >"$run_log.failure-tail"; then
            log_file_with_label OPENCV-FAILURE "$run_log.failure-tail" 80
        fi
    else
        log_file_with_label OPENCV-FAILURE "$run_log" 80
    fi

    echo "$bin_short FAIL" >> "$RESLIST_FILE"
    append_summary "$bin_short" "FAIL" "$run_log"
    log_info "----- END $bin_short (rc=$rc, FAIL) @ $(date '+%Y-%m-%d %H:%M:%S') -----"
    return 1 
}

discover_bins() {
    # Emit newline-separated base names for opencv_test_* and opencv_perf_* discovered
    tmp_all="$(mktemp "$LOG_DIR/${TESTNAME}_bins.XXXXXX")"
    : > "$tmp_all"

    # Search BUILD_DIR and BUILD_DIR/bin first
    for root in "$BUILD_DIR" "$BUILD_DIR/bin"; do
        [ -d "$root" ] || continue
        find "$root" -maxdepth 1 -type f \( -name 'opencv_test_*' -o -name 'opencv_perf_*' \) -print 2>/dev/null \
        | while IFS= read -r p; do
            [ -x "$p" ] && basename "$p"
        done >> "$tmp_all"
    done

    # Search PATH dirs
    OLD_IFS="$IFS"; IFS=":"
    for d in $PATH; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -type f \( -name 'opencv_test_*' -o -name 'opencv_perf_*' \) -print 2>/dev/null \
        | while IFS= read -r p; do
            [ -x "$p" ] && basename "$p"
        done >> "$tmp_all"
    done
    IFS="$OLD_IFS"

    # Unique + classify
    sort -u "$tmp_all" | while IFS= read -r b; do
        case "$b" in
            opencv_test_*) printf "ACC %s\n" "$b" ;;
            opencv_perf_*) printf "PER %s\n" "$b" ;;
        esac
    done
    rm -f "$tmp_all"
}

log_info "========= Starting OpenCV Suite at $(date '+%Y-%m-%d %H:%M:%S') ========="
log_info "Suite settings: FILTER='$GTEST_FILTER_STRING' | PERF_TO_TESTS=$PERF_TO_TESTS | PERF_ARGS='${PERF_ARGS:-<none>}''"

# ----- single-binary mode: dependency check + run -----
if [ -n "$BIN_PATH" ]; then
    # Resolve; if not found => SKIP the suite
    rb="$(resolve_bin "$BIN_PATH" 2>/dev/null || true)"
    if [ -z "$rb" ]; then
        log_skip "$(basename "$BIN_PATH") : not found — SKIP"
        echo "$TESTNAME SKIP" > "$RES_FILE"
        exit 2
    fi
    # Ensure check_dependencies sees it (by basename in PATH)
    bname="$(basename "$rb")"
    bdir="$(dirname "$rb")"
    case ":$PATH:" in *":$bdir:"*) ;; *) PATH="$bdir:$PATH"; export PATH;; esac
    check_dependencies "$bname" || log_warn "Dependency check failed for $bname — proceeding"

    BIN_SHORT="$bname"
    run_one "$BIN_SHORT" "" "$rb"
    rc=$?
    echo ""
    echo "========= OpenCV Suite Summary ========="
    printf "%-32s %-4s %s\n" "TEST" "RES" "LOG"
    cat "$SUMMARY_FILE"
    echo "========================================"
    case "$rc" in
        0) echo "$TESTNAME PASS" > "$RES_FILE"; exit 0 ;;
        2) echo "$TESTNAME SKIP" > "$RES_FILE"; exit 2 ;;
        *) echo "$TESTNAME FAIL" > "$RES_FILE"; exit 1 ;;
    esac
fi

# ----- selected binary list mode: bounded CI smoke set -----
if [ -n "$BIN_LIST" ]; then
    PASS=0
    FAIL=0
    SKIP=0

    for BIN_SHORT in $BIN_LIST; do
        [ -n "$BIN_SHORT" ] || continue

        run_one "$BIN_SHORT" ""
        rc=$?

        if [ "$rc" -eq 0 ]; then
            PASS=$((PASS + 1))
        elif [ "$rc" -eq 2 ]; then
            SKIP=$((SKIP + 1))
        else
            FAIL=$((FAIL + 1))
        fi
    done

    echo ""
    echo "========= OpenCV Suite Summary ========="
    printf "%-32s %-4s %s\n" "TEST" "RES" "LOG"
    cat "$SUMMARY_FILE"
    echo "----------------------------------------"
    echo "Totals: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

    if [ "$FAIL" -gt 0 ]; then
        echo "$TESTNAME FAIL" > "$RES_FILE"
        exit 1
    fi

    if [ "$PASS" -gt 0 ]; then
        echo "$TESTNAME PASS" > "$RES_FILE"
        exit 0
    fi

    if [ "$SKIP" -gt 0 ]; then
        echo "$TESTNAME SKIP" > "$RES_FILE"
        exit 2
    fi

    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 2
fi

# ----- build suite selection -----
want_acc=0; want_per=0
case "$SUITE" in
    accuracy) want_acc=1 ;;
    performance) want_per=1 ;;
    all) want_acc=1; want_per=1 ;;
    *) log_warn "Unknown suite '$SUITE', defaulting to 'all'"; want_acc=1; want_per=1 ;;
esac

# ----- discover first (we will also use this list for dependency check) -----
DISC_TMP="$(mktemp "$LOG_DIR/${TESTNAME}_discover.XXXXXX")"
discover_bins > "$DISC_TMP"

if [ ! -s "$DISC_TMP" ]; then
    log_skip "No OpenCV test/perf binaries discovered — SKIP"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    rm -f "$DISC_TMP"
    exit 2
fi

# ----- dependency check for opencv_test_core + discovered binaries (non-fatal) -----
DEPS="opencv_test_core"
while IFS= read -r line; do
    name="$(printf '%s' "$line" | awk '{print $2}')"
    [ -n "$name" ] && DEPS="$DEPS $name"
done < "$DISC_TMP"

# Non-fatal: just report availability; we still run and SKIP missing ones in run_one
# shellcheck disable=SC2086
check_dependencies $DEPS || log_warn "Some OpenCV binaries not found in PATH; they may still be resolved via --build-dir"

PASS=0
FAIL=0
SKIP=0

# ----- run accuracy -----
if [ "$want_acc" -eq 1 ]; then
    acc_list="$(awk '/^ACC /{print $2}' "$DISC_TMP" | tr '\n' ' ')"
    for b in $acc_list; do
        [ -z "$b" ] && continue
        run_one "$b" ""
        r=$?
        if [ "$r" -eq 0 ]; then PASS=$((PASS+1))
        elif [ "$r" -eq 2 ]; then SKIP=$((SKIP+1))
        else FAIL=$((FAIL+1))
        fi
    done
fi

# ----- run performance -----
if [ "$want_per" -eq 1 ]; then
    per_list="$(awk '/^PER /{print $2}' "$DISC_TMP" | tr '\n' ' ')"
    for b in $per_list; do
        [ -z "$b" ] && continue
        # We no longer need to pass PERF_ARGS here explicitly, run_one() will apply defaults for perf bins.
        run_one "$b" ""
        r=$?
        if [ "$r" -eq 0 ]; then PASS=$((PASS+1))
        elif [ "$r" -eq 2 ]; then SKIP=$((SKIP+1))
        else FAIL=$((FAIL+1))
        fi
    done
fi

rm -f "$DISC_TMP"

# ----- print + persist final summary -----
echo "" >> "$SUMMARY_FILE"
echo "========= OpenCV Suite Summary ========="
printf "%-32s %-4s %s\n" "TEST" "RES" "LOG"
cat "$SUMMARY_FILE"
echo "----------------------------------------"
echo "Totals: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

# ----- decide overall result -----
if [ "$FAIL" -gt 0 ]; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi
if [ "$PASS" -gt 0 ]; then
    # A functional PASS requires at least one executed, successful binary.
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
fi
echo "$TESTNAME SKIP" > "$RES_FILE"
exit 2
