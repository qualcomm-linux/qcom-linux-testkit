#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause


# kselftest_log_status <log> <exit-status>
# Print PASS/FAIL/SKIP. Honor failures even when a harness exits zero.
# Examine TAP/KTAP at every depth, ignore expected TODO/SKIP failures.
kselftest_log_status() {
    awk -v rc="$2" '
    {
        line=$0
        top=(line !~ /^[[:space:]#]/)
        sub(/^[[:space:]]+/, "", line)
        # Inspect nested failures, but validate the outer plan only. Nested
        # subtests can restart numbering without their own TAP header.
        while (line ~ /^#[[:space:]]/) sub(/^#[[:space:]]*/, "", line)
        if (top && line ~ /^(TAP|KTAP) version/) {
            if (header && (!has_plan || top_count != planned)) bad=1
            has_plan=0
            top_count=0
            header=1
        }
        if (top && line ~ /^1\.\.[0-9]+([[:space:]]|$)/) {
            value=line
            sub(/^1\.\./, "", value)
            sub(/[[:space:]].*$/, "", value)
            planned=value+0
            has_plan=1
        }
        if (line ~ /^Bail out!/) bad=1
        if (line ~ /^(not ok|ok)([[:space:]]|$)/) {
            seen++
            if (top) top_count++
            directive=tolower(line)
            if (directive ~ /#[[:space:]]*(skip|todo)([[:space:]]|$)/) skipped++
            else if (line ~ /^not ok/) bad=1
            else passed++
        }
        if (line ~ /^1\.\.0([[:space:]]|$)/) zero=1
        if (line ~ /^(TAP|KTAP) version/) tap=1
    }
    END {
        if (has_plan && top_count != planned) bad=1
        if (header && !has_plan) bad=1
        if (bad || (rc != 0 && rc != 4)) print "FAIL"
        else if (rc == 4 || (seen && !passed) || (!seen && zero)) print "SKIP"
        else if (tap && !seen) print "FAIL"
        else print "PASS"
    }' "$1"
}

# kselftest_select <root> <allowlist> <output>
# Build unique collection:test selections. Keep manifest order and do not run
# both a collection harness and its children. Return 1 on malformed selections.
kselftest_select() (
    ks_root=$1
    ks_allow=$2
    ks_out=$3
    : >"$ks_out" || exit 1
    while IFS= read -r ks_entry || [ -n "$ks_entry" ]; do
        ks_entry=$(printf '%s\n' "$ks_entry" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$ks_entry" ] || continue
        case "$ks_entry" in
            *..*|/*|*[!a-zA-Z0-9_./:+-]*)
                echo "Invalid selftest selection: $ks_entry" >&2
                exit 1
                ;;
            *:*)
                printf '%s\n' "$ks_entry" >>"$ks_out"
                ;;
            */*)
                printf '%s:%s\n' "${ks_entry%%/*}" "${ks_entry#*/}" >>"$ks_out"
                ;;
            *)
                if [ -r "$ks_root/kselftest-list.txt" ]; then
                    awk -F: -v collection="$ks_entry" '$1 == collection {print}' "$ks_root/kselftest-list.txt" >>"$ks_out"
                elif [ -x "$ks_root/$ks_entry/run_test.sh" ]; then
                    printf '%s:run_test.sh\n' "$ks_entry" >>"$ks_out"
                else
                    # Legacy installations without a manifest retain *test discovery.
                    find "$ks_root/$ks_entry" -type f -name '*test' 2>/dev/null |
                    while IFS= read -r ks_file; do
                        [ -x "$ks_file" ] || continue
                        printf '%s:%s\n' "$ks_entry" "${ks_file#"$ks_root/$ks_entry/"}" >>"$ks_out"
                    done
                fi
                ;;
        esac
    done <"$ks_allow"
    awk -F: '
        NR == FNR {
            if ($2 == "run_test.sh") harness[$1]=1
            next
        }
        !seen[$0]++ && (!harness[$1] || $2 == "run_test.sh") {print}
    ' "$ks_out" "$ks_out" >"$ks_out.unique" || exit 1
    mv "$ks_out.unique" "$ks_out"
)

# kselftest_run_one <root> <collection:test> <outdir> <timeout>
# Use installed runner/manifest when available, otherwise run from test directory.
# Record result with exit status, elapsed seconds and fresh retained output.
kselftest_run_one() {
    local ks_root ks_entry ks_out ks_timeout ks_collection ks_binary ks_log ks_start ks_end ks_rc ks_status
    ks_root=$1
    ks_entry=$2
    ks_out=$3
    ks_timeout=$4
    ks_collection=${ks_entry%%:*}
    ks_binary=${ks_entry#*:}
    case "$ks_collection/$ks_binary" in
        *..*|/*|*[!a-zA-Z0-9_./+-]*)
            test_result_record FAIL "Unsafe selftest path: $ks_entry"
            return
            ;;
    esac
    ks_log="$ks_out/$ks_collection/$ks_binary.log"
    mkdir -p "$(dirname "$ks_log")" || return 1
    if [ ! -x "$ks_root/$ks_collection/$ks_binary" ]; then
        test_result_record SKIP "$ks_entry is not supplied as an executable in $ks_root"
        return
    fi
    ks_start=$(date +%s)
    (
        # Tests require their installed fixtures beside the executable.
        cd "$ks_root/$ks_collection" || exit 1
        TMPDIR="$ks_out"
        export TMPDIR
        # shellcheck disable=SC2034 # Consumed by functestlib timeout helper.
        MANAGED_TIMEOUT_USE_SESSION=1
        ks_cleanup_status=0
        trap 'ks_cleanup_status=$?
            trap - 0
            managed_timeout_cancel_bounded 2 || ks_cleanup_status=1
            exit "$ks_cleanup_status"' 0
        trap 'exit 1' HUP INT TERM
        if [ -x "$ks_root/run_kselftest.sh" ] && [ -r "$ks_root/kselftest-list.txt" ] &&
           grep -Fxq "$ks_entry" "$ks_root/kselftest-list.txt"; then
            run_with_managed_timeout "$ks_timeout" "$ks_out" kselftest "$ks_root/run_kselftest.sh" -t "$ks_entry"
        else
            run_with_managed_timeout "$ks_timeout" "$ks_out" kselftest "./$ks_binary"
        fi
    ) >"$ks_log" 2>&1
    ks_rc=$?
    ks_end=$(date +%s)
    ks_status=$(kselftest_log_status "$ks_log" "$ks_rc")
    test_result_record "$ks_status" "$ks_entry exit=$ks_rc elapsed=$((ks_end - ks_start))s log=$ks_log"
    printf '%s %s exit=%s elapsed=%ss\n' "$ks_status" "$ks_entry" "$ks_rc" "$((ks_end - ks_start))" >>"$ks_out/Kernel_Selftests.tests"
    if [ "$ks_status" != PASS ]; then
        cat "$ks_log"
    fi
}
