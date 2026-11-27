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

TESTNAME="SoC_Infra_CPU_Available_Freq_Validation"
RES_FILE="./$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

CPUFREQ_ROOT="/sys/devices/system/cpu/cpufreq"
REPORT_FILE="./cpu_available_freqs.log"
# Frequencies are in kHz. Twelve digits is far above any real value and keeps the
# numeric comparisons below inside the shell's integer range.
MAX_DIGITS=12

# cpuavail_check_policy <policy-dir>
# Checks the scaling_available_frequencies list of one cpufreq policy and prints
# one report line: "<policy> <khz> <khz> ..." for a valid list, or
# "<policy> READ_ERROR|EMPTY|INVALID_VALUE(<token>)|OUT_OF_RANGE(<token> not in <min>..<max>)".
# Runs in a subshell, so it changes no shell state.
# Returns: 0 the list is valid, 1 the list is invalid, 2 the policy does not
# expose scaling_available_frequencies.
cpuavail_check_policy() (
    cacp_dir="$1"
    cacp_name="${cacp_dir##*/}"
    cacp_file="$cacp_dir/scaling_available_frequencies"

    [ -e "$cacp_file" ] || exit 2

    if ! cacp_list=$(cat "$cacp_file" 2>/dev/null); then
        printf '%s READ_ERROR\n' "$cacp_name"
        exit 1
    fi

    # The hardware limits are optional context: without usable limits, only the
    # format of each value is checked.
    cacp_min=""
    cacp_max=""
    if cacp_min=$(cat "$cacp_dir/cpuinfo_min_freq" 2>/dev/null) &&
       cacp_max=$(cat "$cacp_dir/cpuinfo_max_freq" 2>/dev/null) &&
       is_unsigned_number "$cacp_min" && is_unsigned_number "$cacp_max" &&
       [ "${#cacp_min}" -le "$MAX_DIGITS" ] && [ "${#cacp_max}" -le "$MAX_DIGITS" ]; then
        :
    else
        cacp_min=""
        cacp_max=""
    fi

    # Split on whitespace without letting the shell expand any token as a glob.
    set -f
    # shellcheck disable=SC2086
    set -- $cacp_list
    set +f

    if [ "$#" -eq 0 ]; then
        printf '%s EMPTY\n' "$cacp_name"
        exit 1
    fi

    for cacp_freq in "$@"; do
        if ! is_unsigned_number "$cacp_freq" ||
           [ "${#cacp_freq}" -gt "$MAX_DIGITS" ] ||
           [ "$cacp_freq" -le 0 ]; then
            cacp_shown=$(printf '%s' "$cacp_freq" | tr -c '[:print:]' '?')
            printf '%s INVALID_VALUE(%s)\n' "$cacp_name" "$cacp_shown"
            exit 1
        fi
        if [ -n "$cacp_min" ] &&
           { [ "$cacp_freq" -lt "$cacp_min" ] || [ "$cacp_freq" -gt "$cacp_max" ]; }; then
            printf '%s OUT_OF_RANGE(%s not in %s..%s)\n' "$cacp_name" "$cacp_freq" "$cacp_min" "$cacp_max"
            exit 1
        fi
    done

    printf '%s %s\n' "$cacp_name" "$*"
    exit 0
)

# cpuavail_active_policies
# Prints the policy directory of every online CPU, one per line, repeats allowed.
# A policy whose CPUs are all offline can stay in sysfs, but every attribute of it
# then fails to read, so only the policies printed here may be checked.
cpuavail_active_policies() (
    get_online_cpus | while IFS= read -r caap_cpu; do
        is_unsigned_number "$caap_cpu" || continue
        caap_link="/sys/devices/system/cpu/cpu$caap_cpu/cpufreq"
        [ -e "$caap_link" ] || continue
        readlink -f "$caap_link" 2>/dev/null
    done
)

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"

# Never install packages on the target; skip when a base utility is missing.
if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies cat tr grep readlink; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

# cpufreq is optional: it needs a driver bound to the CPUs, so no policy means
# there is nothing to check, not a failure. A policy with no online CPU is not
# checked either: its attributes cannot be read while every CPU of it is offline.
policy_total=0
inactive=0
checked=0
invalid=0
absent=0
active_policies=$(cpuavail_active_policies)

if ! printf '' >"$REPORT_FILE"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create the report file $REPORT_FILE in $(pwd)"
fi

for policy_dir in "$CPUFREQ_ROOT"/policy*; do
    [ -d "$policy_dir" ] || continue
    policy_total=$((policy_total + 1))

    policy_real=$(readlink -f "$policy_dir" 2>/dev/null)
    if [ -z "$policy_real" ] || ! printf '%s\n' "$active_policies" | grep -qxF "$policy_real"; then
        inactive=$((inactive + 1))
        log_info "${policy_dir##*/}: no online CPU, not checked"
        continue
    fi

    report_line=$(cpuavail_check_policy "$policy_dir")
    policy_rc=$?
    case "$policy_rc" in
        0)
            checked=$((checked + 1))
            printf '%s\n' "$report_line" >>"$REPORT_FILE"
            ;;
        1)
            checked=$((checked + 1))
            invalid=$((invalid + 1))
            printf '%s\n' "$report_line" >>"$REPORT_FILE"
            ;;
        *)
            absent=$((absent + 1))
            log_info "${policy_dir##*/}: scaling_available_frequencies is not exposed, not checked"
            ;;
    esac
done

log_info "cpufreq policies: found=$policy_total offline=$inactive checked=$checked invalid=$invalid not_exposed=$absent (details: $REPORT_FILE)"
# Replay the report so the job log shows every policy and its advertised
# frequencies in kHz. The report file is kept as a result artifact.
log_file_with_label "CPU-AVAILABLE-FREQ-KHZ" "$REPORT_FILE"

if [ "$policy_total" -eq 0 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no cpufreq policy under $CPUFREQ_ROOT, cpufreq is not enabled or no driver is bound"
fi
if [ "$checked" -eq 0 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no online cpufreq policy exposes scaling_available_frequencies (found=$policy_total offline=$inactive not_exposed=$absent)"
fi

if [ "$invalid" -gt 0 ]; then
    grep -E 'READ_ERROR|EMPTY|INVALID_VALUE|OUT_OF_RANGE' "$REPORT_FILE" | while IFS= read -r bad_line; do
        log_fail "Invalid frequency list: $bad_line"
    done
    test_result_record "FAIL" "$invalid of $checked cpufreq policies advertise an invalid frequency list"
else
    test_result_record "PASS" "All $checked cpufreq policies advertise a valid frequency list"
fi

test_result_finish
