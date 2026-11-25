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
TESTNAME="CPU_Idle_Residency_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

OBSERVE_SECONDS="10"
MIN_PERCENT=""

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Measure actual idle residency across online CPUs without changing idle policy.
  --seconds <value>  Read-only observation interval in seconds
  --min-percent <value>  Optional required aggregate idle-residency percentage per CPU
EOF
}

# parse_args <arguments>...
# Parse explicit values before accessing runtime evidence.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_finish FAIL "Missing value for $1"
        fi
        case "$2" in
            --*)
                test_result_finish FAIL "Missing value for $1 before option=$2"
                ;;
        esac
        case "$1" in
            --seconds)
                OBSERVE_SECONDS="$2"
                ;;
            --min-percent)
                MIN_PERCENT="$2"
                ;;
            *)
                test_result_finish FAIL "Unknown option=$1"
                ;;
        esac
        shift 2
    done
}

parse_args "$@"

# shellcheck disable=SC2034 # Read by the shared dependency helper.
CHECK_DEPS_RECOVER=0
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat awk grep sed tr uname mkdir mktemp date; then
    test_result_finish SKIP "Required shell tools are absent, provision them in the image"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create retained evidence under CWD=$PWD"


if ! printf '%s\n' "$OBSERVE_SECONDS" | grep -Eq '^[1-9][0-9]{0,3}$'; then
    test_result_finish FAIL "--seconds must be a positive decimal integer of at most four digits"
fi
if [ -n "$MIN_PERCENT" ] && ! awk -v value="$MIN_PERCENT" 'BEGIN {exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0 && value <= 100)}'; then
    test_result_finish FAIL "--min-percent must be greater than zero and at most 100"
fi
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies sleep cmp; then
    test_result_finish SKIP "Residency sampling requires image-provided sleep and cmp"
fi
trap 'test_result_finish FAIL "CPU idle residency observation interrupted"' HUP INT TERM
for phase in before after; do
    cat /sys/devices/system/cpu/online >"$OUT_DIR/$phase-online.list" ||
        test_result_finish SKIP "CPU online mask is unavailable, provide sysfs CPU topology"
    kernel_cpuidle_snapshot "$OUT_DIR/$phase-states.tsv"
    snapshot_status=$?
    if [ "$snapshot_status" -eq 2 ]; then
        if [ "$phase" = after ]; then
            test_result_finish FAIL "Previously exposed CPU idle states disappeared during observation"
        fi
        test_result_finish SKIP "No cpuidle state counters on online CPUs, enable a supported idle driver"
    elif [ "$snapshot_status" -ne 0 ]; then
        test_result_finish FAIL "CPU idle counters are unreadable or malformed, inspect $OUT_DIR/$phase-states.tsv"
    fi
    cat /proc/uptime >"$OUT_DIR/$phase-uptime.log" || test_result_finish FAIL "Cannot retain monotonic observation timing"
    if [ "$phase" = before ]; then
        scan_dmesg_errors "$OUT_DIR/kernel-before" 'cpuidle|psci|CPU[0-9]+' '' || true
        if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
            test_result_finish SKIP "Residency validation requires readable kernel health evidence"
        fi
        if [ -s "$OUT_DIR/kernel-before/dmesg_errors.log" ]; then
            test_result_finish FAIL "CPU idle faults exist before observation, inspect $OUT_DIR/kernel-before"
        fi
        sleep "$OBSERVE_SECONDS" || test_result_finish FAIL "Idle observation interval was interrupted"
    fi
done
scan_dmesg_errors "$OUT_DIR/kernel-after" 'cpuidle|psci|CPU[0-9]+' '' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ] || [ -s "$OUT_DIR/kernel-after/dmesg_errors.log" ]; then
    test_result_finish FAIL "CPU idle health evidence is failed or unavailable after observation"
fi
if ! cmp -s "$OUT_DIR/before-online.list" "$OUT_DIR/after-online.list"; then
    test_result_finish SKIP "Online CPUs changed during observation, rerun without a competing hotplug workload"
fi
elapsed=$(awk 'FILENAME==ARGV[1] {start=$1; next} {printf "%.6f", $1-start}' "$OUT_DIR/before-uptime.log" "$OUT_DIR/after-uptime.log")
if ! awk -v value="$elapsed" 'BEGIN {exit !(value > 0)}'; then
    test_result_finish FAIL "Observation timing did not advance"
fi
if ! awk -v elapsed="$elapsed" -v minimum="$MIN_PERCENT" -v metrics="$OUT_DIR/residency.tsv" '
    FILENAME==ARGV[1] {key=$1 "/" $2; before[key]=$0; count++; next}
    {
        key=$1 "/" $2
        if (!(key in before) || seen[key]++) {bad=1; next}
        split(before[key], initial, " ")
        if ($3 != initial[3]) changed=1
        if ($4 < initial[4] || $5 < initial[5] || ($6 != "-" && initial[6] != "-" && $6 < initial[6])) bad=1
        if (($6 == "-") != (initial[6] == "-")) changed=1
        usage=$4-initial[4]; time=$5-initial[5]
        rejected=($6 == "-" ? "unavailable" : $6-initial[6])
        print $1, $2, "entries=" usage, "time_us=" time, "rejected=" rejected, "disabled=" $3 >metrics
        cpu[$1]=1
        if ($3 == 0) {enabled[$1]++; residency[$1]+=time}
    }
    END {
        for (key in before) if (!(key in seen)) changed=1
        if (bad) {print "FAIL counter-regression-or-duplicate-state"; exit 1}
        if (changed) {print "SKIP state-policy-or-inventory-changed"; exit 0}
        for (id in cpu) {
            percent=100*residency[id]/(elapsed*1000000)
            if (!enabled[id]) state="SKIP"
            else if (minimum != "" && percent < minimum) state="FAIL"
            else if (residency[id] > 0) state="PASS"
            else state="SKIP"
            printf "%s CPU%s measured_idle_percent=%.3f enabled_states=%d\n", state,id,percent,enabled[id]
        }
    }
' "$OUT_DIR/before-states.tsv" "$OUT_DIR/after-states.tsv" >"$OUT_DIR/verdicts.log"; then
    test_result_record FAIL "CPU idle counters regressed or became inconsistent, inspect $OUT_DIR/residency.tsv"
fi
while read -r verdict detail; do
    test_result_record "$verdict" "$detail, no observed residency requires a quieter target or an explicit expected threshold"
done <"$OUT_DIR/verdicts.log"

test_result_finish
