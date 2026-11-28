#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# ---------- Repo env + helpers ----------
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
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="CPU_Accounting_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
# shellcheck disable=SC2034
CHECK_DEPS_RECOVER=0

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

# usage
# Print the supported options without changing hardware.
usage() {
    printf '%s\n' "Usage: $0 [--help]"
}

# parse_args <arguments...>
# Reject unsupported arguments before test setup.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *)
                test_result_finish FAIL "Unsupported option: $1"
                ;;
        esac
    done
}
parse_args "$@"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

deps_list="cat grep sed awk tr sleep mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ ! -r /proc/stat ]; then
    test_result_record "FAIL" "/proc/stat is not readable"
    test_result_finish "FAIL"
fi

if ! awk '
    /^cpu[0-9]* / {
        rows++
        if (NF < 8) bad = 1
        for (i = 2; i <= NF; i++) if ($i !~ /^[0-9]+$/) bad = 1
    }
    END { if (rows < 1 || bad) exit 1 }
' /proc/stat; then
    test_result_record "FAIL" "/proc/stat cpu rows contain a missing or non-numeric counter"
    test_result_finish "FAIL"
fi

s1="$(awk '/^cpu / { sum = 0; for (i = 2; i <= NF; i++) sum += $i; print sum }' /proc/stat)"
sleep 1
s2="$(awk '/^cpu / { sum = 0; for (i = 2; i <= NF; i++) sum += $i; print sum }' /proc/stat)"
if is_unsigned_number "$s1" && is_unsigned_number "$s2" && [ "$s2" -ge "$s1" ]; then
    test_result_record "PASS" "/proc/stat cpu aggregate is monotonic ($s1 -> $s2)"
else
    test_result_record "FAIL" "/proc/stat cpu aggregate is not monotonic ($s1 -> $s2)"
fi

online_ids="$(get_online_cpus | sort -n | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
stat_ids="$(awk '/^cpu[0-9]+ / { sub(/^cpu/, "", $1); print $1 }' /proc/stat | sort -n | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
if [ "$stat_ids" != "$online_ids" ]; then
    sleep 1
    online_ids="$(get_online_cpus | sort -n | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
    stat_ids="$(awk '/^cpu[0-9]+ / { sub(/^cpu/, "", $1); print $1 }' /proc/stat | sort -n | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
fi
if [ -n "$stat_ids" ] && [ "$stat_ids" = "$online_ids" ]; then
    test_result_record "PASS" "/proc/stat per-CPU rows match online CPUs $online_ids"
elif [ -n "$stat_ids" ]; then
    test_result_record "FAIL" "/proc/stat CPUs ($stat_ids) do not match online CPUs ($online_ids)"
else
    test_result_record "FAIL" "/proc/stat has no per-CPU rows"
fi

if [ -r /proc/loadavg ]; then
    la="$(kernel_attribute_value /proc/loadavg)" || la=""
    if printf '%s\n' "$la" | awk 'NF >= 5 && $1 ~ /^[0-9]+([.][0-9]+)?$/ && $2 ~ /^[0-9]+([.][0-9]+)?$/ && $3 ~ /^[0-9]+([.][0-9]+)?$/ && $4 ~ /^[0-9]+\/[0-9]+$/ && $5 ~ /^[0-9]+$/ { ok = 1 } END { exit !ok }'; then
        test_result_record "PASS" "/proc/loadavg has numeric load, entity, and pid fields ($la)"
    else
        test_result_record "FAIL" "/proc/loadavg is not in load/entity/pid form ('${la:-unreadable}')"
    fi
else
    test_result_record "FAIL" "/proc/loadavg is not readable"
fi

if [ -r /proc/pressure/cpu ]; then
    kernel_record_attribute "PSI cpu" "/proc/pressure/cpu"
else
    test_result_record "SKIP" "PSI /proc/pressure/cpu not present"
fi

if [ -r /proc/schedstat ]; then
    if grep -q '^version' /proc/schedstat; then
        test_result_record "PASS" "/proc/schedstat has a version header"
    else
        test_result_record "FAIL" "/proc/schedstat missing version header"
    fi
else
    test_result_record "SKIP" "/proc/schedstat not present"
fi

test_result_finish
