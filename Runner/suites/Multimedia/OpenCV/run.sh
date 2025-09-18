#!/bin/sh
# OpenCV test/perf suite runner (auto-discovery; per-binary skip; summary; proper exit codes)
# SPDX-License-Identifier: BSD-3-Clause-Clear

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
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$LOG_DIR" >/dev/null 2>&1 || true
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
SUMMARY_FILE="$SCRIPT_DIR/$TESTNAME.summary"
RESLIST_FILE="$SCRIPT_DIR/${TESTNAME}.reslist"
: > "$RESLIST_FILE"
: > "$SUMMARY_FILE"

# ---------- defaults / cli ----------
# We compute the final filter AFTER parsing CLI to honor precedence:
# CLI --filter > env GTEST_FILTER > env GTEST_FILTER_STRING > DEFAULT_FILTER
DEFAULT_FILTER="-tracking_GOTURN.GOTURN/*"
CLI_FILTER=""

BIN_PATH="" # --bin <path|name>
BUILD_DIR="." # --build-dir
CWD="." # --cwd
TESTDATA_PATH="" # --testdata
EXTRA_ARGS="" # --args "..."
TIMEOUT_SECS="" # --timeout N
SUITE="all" # --suite accuracy|performance|all
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
  --build-dir <path> Root to search for binaries (default: .)
  --suite <name> accuracy | performance | all (default: all)
  --filter <pattern> gtest filter for all runs (default from env or "-tracking_GOTURN.GOTURN/*")
  --repeat <N> gtest repeat count
  --shuffle Enable gtest shuffle
  --seed <N> gtest random seed
  --cwd <path> Working directory for test execution (default: .)
  --testdata <path> Export OPENCV_TEST_DATA_PATH to this dir
  --args "<args>" Extra args added to all test binaries
  --timeout <sec> Kill a run if it exceeds <sec> (needs \`timeout\`)
  --perf-args "<args>" Extra args appended to all opencv_perf_* runs
  --perf-to-tests Also append --perf-args to opencv_test_* runs
  --list List tests (per-binary) and exit (treated as PASS)
  -h|--help Show this help

Env honored:
  OPENCV_TEST_DATA_PATH, GTEST_FILTER, GTEST_FILTER_STRING
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bin) BIN_PATH="$2"; shift 2 ;;
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --suite) SUITE="$2"; shift 2 ;;
        --filter) CLI_FILTER="$2"; shift 2 ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        --shuffle) SHUFFLE=1; shift 1 ;;
        --seed) SEED="$2"; shift 2 ;;
        --cwd) CWD="$2"; shift 2 ;;
        --testdata) TESTDATA_PATH="$2"; shift 2 ;;
        --args) EXTRA_ARGS="$2"; shift 2 ;;
        --timeout) TIMEOUT_SECS="$2"; shift 2 ;;
        --perf-args) PERF_ARGS="$2"; shift 2 ;;
        --perf-to-tests) PERF_TO_TESTS=1; shift 1 ;;
        --list) LIST_ONLY=1; shift 1 ;;
        -h|--help) print_usage; exit 0 ;;
        *) log_warn "Unknown arg: $1"; shift 1 ;;
    esac
done

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

# ----- timeout handling via run_with_timeout (from functestlib.sh) -----
if [ -n "$TIMEOUT_SECS" ]; then
    if ! command -v run_with_timeout >/dev/null 2>&1; then
        log_warn "run_with_timeout() not available; ignoring --timeout"
        TIMEOUT_SECS=""
    fi
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
    grep -Eq '^\[==========\] Running 0 tests from 0 test (suites|cases)\.' "$logp" \
      || grep -qi 'No tests to run' "$logp"
}

run_one() {
    bin_short="$1"
    bin_extra="$2"

    bin_path="$(resolve_bin "$bin_short")" || {
        log_skip "$bin_short : not found — SKIP"
        echo "$bin_short SKIP" >> "$RESLIST_FILE"
        append_summary "$bin_short" "SKIP" "-"
        return 2
    }

    # Build argument list
    ts="$(date +%Y%m%d-%H%M%S)"
    gargs="--gtest_color=yes --gtest_filter=$GTEST_FILTER"
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
    if [ -n "$TIMEOUT_SECS" ]; then
        log_info "Cmd : $cmd (via run_with_timeout $TIMEOUT_SECS)"
    else
        log_info "Cmd : $cmd"
    fi
    log_info "Log : $run_log"

    (
        cd "$CWD" || exit 2
        if [ -n "$TIMEOUT_SECS" ]; then
            run_with_timeout "$TIMEOUT_SECS" sh -c "$cmd"
        else
            # shellcheck disable=SC2086
            sh -c "$cmd"
        fi
    ) >"$run_log" 2>&1
    rc=$?
    [ "$rc" -eq 124 ] && rc=1 # timeout => fail

    if [ "$rc" -eq 0 ] && parse_zero_tests_as_skip "$run_log"; then
        log_skip "$bin_short : No tests executed — SKIP"
        echo "$bin_short SKIP" >> "$RESLIST_FILE"
        append_summary "$bin_short" "SKIP" "$run_log"
        log_info "----- END $bin_short (rc=0, SKIP) @ $(date '+%Y-%m-%d %H:%M:%S') -----"
        return 2
    fi

    if [ "$rc" -eq 0 ]; then
        log_pass "$bin_short : PASS"
        echo "$bin_short PASS" >> "$RESLIST_FILE"
        append_summary "$bin_short" "PASS" "$run_log"
        log_info "----- END $bin_short (rc=0, PASS) @ $(date '+%Y-%m-%d %H:%M:%S') -----"
        return 0
    else
        log_fail "$bin_short : FAIL (exit=$rc). See: $run_log"
        echo "$bin_short FAIL" >> "$RESLIST_FILE"
        append_summary "$bin_short" "FAIL" "$run_log"
        log_info "----- END $bin_short (rc=$rc, FAIL) @ $(date '+%Y-%m-%d %H:%M:%S') -----"
        return 1
    fi
}

discover_bins() {
    # Emit newline-separated base names for opencv_test_* and opencv_perf_* discovered
    tmp_all="$(mktemp "/tmp/${TESTNAME}_bins.XXXXXX")"
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
    rb="$(resolve_bin "$(basename "$BIN_PATH")" 2>/dev/null || true)"
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
    run_one "$BIN_SHORT" ""
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

# ----- build suite selection -----
want_acc=0; want_per=0
case "$SUITE" in
    accuracy) want_acc=1 ;;
    performance) want_per=1 ;;
    all) want_acc=1; want_per=1 ;;
    *) log_warn "Unknown suite '$SUITE', defaulting to 'all'"; want_acc=1; want_per=1 ;;
esac

# ----- discover first (we will also use this list for dependency check) -----
DISC_TMP="$(mktemp "/tmp/${TESTNAME}_discover.XXXXXX")"
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
if [ "$PASS" -gt 0 ] || [ "$SKIP" -gt 0 ]; then
    # Treat "some ran (pass/skip) and no failures" as PASS overall
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
fi
echo "$TESTNAME SKIP" > "$RES_FILE"
exit 2
