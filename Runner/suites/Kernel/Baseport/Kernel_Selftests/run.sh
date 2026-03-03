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
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

# --- Helper: Run command with timeout, POSIX fallback ---
run_with_timeout() {
    secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi
    "$@" &
    pid=$!
    (
        sleep "$secs"
        kill -9 "$pid" 2>/dev/null
    ) > /dev/null 2>&1 &
    killer=$!
    wait "$pid" 2>/dev/null
    status=$?
    kill -9 "$killer" 2>/dev/null
    return $status
}

ensure_log_dir() {
    log_path="$1"
    dir_path=$(dirname "$log_path")
    [ -d "$dir_path" ] || mkdir -p "$dir_path"
}

format_time() {
    secs="$1"
    if [ "$secs" -ge 60 ]; then
        mins=$((secs / 60))
        rem=$((secs % 60))
        printf "%dm %02ds" "$mins" "$rem"
    else
        printf "%ds" "$secs"
    fi
}

TESTNAME="Kernel_Selftests"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

res_file="./$TESTNAME.res"
per_test_file="./$TESTNAME.tests"
whitelist="./enabled_tests.list"
selftest_dir="/kselftest"
arch="$(uname -m)"
skip_arch="x86 powerpc mips sparc"

pass=0
fail=0
skip=0

rm -f "$res_file" "$per_test_file" ./*.log

log_info "--------------------------------------------------------"
log_info "Starting $TESTNAME..."

check_dependencies find

if [ ! -d "$selftest_dir" ]; then
    log_skip "$TESTNAME: $selftest_dir not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

if [ ! -f "$whitelist" ]; then
    log_skip "$TESTNAME: whitelist $whitelist not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

run_suite_tests() {
    suite="$1"
    dir="$selftest_dir/$suite"
    ran_any_local=0

    if [ -x "$dir/run_test.sh" ]; then
        log_info "Running $suite/run_test.sh"
        logfile="$suite/run_test.sh.log"
        ensure_log_dir "$logfile"
        start=$(date +%s)
        run_with_timeout 300 "$dir/run_test.sh" > "$logfile" 2>&1
        status=$?
        end=$(date +%s)
        elapsed=$((end - start))
        duration_text=$(format_time "$elapsed")
        if [ "$status" -eq 0 ]; then
            log_pass "PASS $suite/run_test.sh ($duration_text)"
            echo "PASS $suite/run_test.sh $duration_text" >> "$per_test_file"
            pass=$((pass + 1))
        else
            log_fail "FAIL $suite/run_test.sh ($duration_text)"
            echo "FAIL $suite/run_test.sh $duration_text" >> "$per_test_file"
            fail=$((fail + 1))
        fi
        ran_any_local=1
    fi

    test_bins=$(find "$dir" -type f -name '*test' -executable 2>/dev/null)
    for bin in $test_bins; do
        binname="${bin#"$selftest_dir"/}"
        case "$binname" in */run_test.sh) continue ;; esac

        log_info "Running $binname"
        logfile="${binname}.log"
        ensure_log_dir "$logfile"
        start=$(date +%s)
        run_with_timeout 300 "$bin" > "$logfile" 2>&1
        status=$?
        end=$((end - start))
        elapsed=$((end - start))
        duration_text=$(format_time "$elapsed")
        if [ "$status" -eq 0 ]; then
            log_pass "PASS $binname ($duration_text)"
            echo "PASS $binname $duration_text" >> "$per_test_file"
            pass=$((pass + 1))
        else
            log_fail "FAIL $binname ($duration_text)"
            echo "FAIL $binname $duration_text" >> "$per_test_file"
            fail=$((fail + 1))
        fi
        ran_any_local=1
    done

    if [ "$ran_any_local" -eq 0 ]; then
        log_skip "$suite: no test binaries"
        echo "SKIP $suite (no test binaries)" >> "$per_test_file"
        skip=$((skip + 1))
    fi
}

while IFS= read -r test || [ -n "$test" ]; do
    case "$test" in
        ''|\#*) continue ;;
    esac

    for a in $skip_arch; do
        if [ "$test" = "$a" ]; then
            log_skip "$test skipped on $arch"
            echo "SKIP $test (unsupported arch)" >> "$per_test_file"
            skip=$((skip + 1))
            continue 2
        fi
    done

    if echo "$test" | grep -q ':'; then
        suite=$(echo "$test" | cut -d: -f1)
        testbin=$(echo "$test" | cut -d: -f2)
        bin_path="$selftest_dir/$suite/$testbin"
    elif echo "$test" | grep -q '/'; then
        suite=$(echo "$test" | cut -d/ -f1)
        testbin=$(echo "$test" | cut -d/ -f2-)
        bin_path="$selftest_dir/$suite/$testbin"
    else
        suite="$test"
        testbin=""
        bin_path=""
    fi

    if [ -n "$testbin" ]; then
        if [ ! -d "$selftest_dir/$suite" ]; then
            log_skip "$suite not found"
            echo "SKIP $suite (directory not found)" >> "$per_test_file"
            skip=$((skip + 1))
            continue
        fi
        if [ -x "$bin_path" ]; then
            log_info "Running $suite/$testbin"
            logfile="$suite/$testbin.log"
            ensure_log_dir "$logfile"
            start=$(date +%s)
            run_with_timeout 300 "$bin_path" > "$logfile" 2>&1
            status=$?
            end=$(date +%s)
            elapsed=$((end - start))
            duration_text=$(format_time "$elapsed")
            if [ "$status" -eq 0 ]; then
                log_pass "PASS $suite/$testbin ($duration_text)"
                echo "PASS $suite/$testbin $duration_text" >> "$per_test_file"
                pass=$((pass + 1))
            else
                log_fail "FAIL $suite/$testbin ($duration_text)"
                echo "FAIL $suite/$testbin $duration_text" >> "$per_test_file"
                fail=$((fail + 1))
            fi
        else
            log_skip "SKIP $suite/$testbin (not found or not executable)"
            echo "SKIP $suite/$testbin (not found or not executable)" >> "$per_test_file"
            skip=$((skip + 1))
        fi
        continue
    fi

    if [ -d "$selftest_dir/$suite" ]; then
        run_suite_tests "$suite"
    else
        log_skip "$suite not found"
        echo "SKIP $suite (not found)" >> "$per_test_file"
        skip=$((skip + 1))
    fi

done < "$whitelist"

if [ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]; then
    echo "$TESTNAME PASS" > "$res_file"
    log_pass "$TESTNAME: all tests passed"
    exit 0
else
    echo "$TESTNAME FAIL" > "$res_file"
    log_fail "$TESTNAME: one or more tests failed"
    exit 1
fi

log_info "Per-test results written to $per_test_file"
log_info "------------------- Completed $TESTNAME Testcase -----------"
