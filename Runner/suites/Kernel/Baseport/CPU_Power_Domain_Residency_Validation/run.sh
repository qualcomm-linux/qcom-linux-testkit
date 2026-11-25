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
TESTNAME="CPU_Power_Domain_Residency_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

OBSERVE_SECONDS="10"
DOMAIN_ROOT=""
MIN_PERCENT=""

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Measure idle residency of runtime-discovered CPU power domains and their parents.
  --seconds <value>  Read-only observation interval in seconds
  --domain-root <value>  Optional pm_genpd directory, otherwise the mounted debugfs
  --min-percent <value>  Optional required aggregate idle-residency percentage per domain
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
            --domain-root)
                DOMAIN_ROOT="$2"
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
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies sleep cmp cp; then
    test_result_finish SKIP "Power-domain observation requires image-provided sleep, cmp and cp"
fi
if [ -z "$DOMAIN_ROOT" ]; then
    debug_mount=$(awk '$3 == "debugfs" {print $2; exit}' /proc/mounts)
    if [ -n "$debug_mount" ]; then
        DOMAIN_ROOT="$debug_mount/pm_genpd"
    fi
fi
if [ -z "$DOMAIN_ROOT" ] || [ ! -d "$DOMAIN_ROOT" ]; then
    test_result_finish SKIP "No readable pm_genpd debugfs, provision mounted kernel power-domain diagnostics"
fi
DOMAIN_ROOT=$(cd "$DOMAIN_ROOT" && pwd -P) || test_result_finish FAIL "Cannot resolve the selected domain root"
: >"$OUT_DIR/domains.list"
for domain in "$DOMAIN_ROOT"/*; do
    [ -d "$domain" ] || continue
    if [ -r "$domain/devices" ] && grep -Eq '(^|[/:])cpu[0-9]+$' "$domain/devices"; then
        printf '%s\n' "${domain##*/}" >>"$OUT_DIR/domains.list"
    fi
done
if [ ! -s "$OUT_DIR/domains.list" ]; then
    test_result_finish SKIP "No CPU-associated generic power domains, platform-coordinated idle may not expose this interface"
fi
# Follow actual child-domain links, never infer cluster names from SoC names.
added=1
while [ "$added" -eq 1 ]; do
    added=0
    for domain in "$DOMAIN_ROOT"/*; do
        [ -r "$domain/sub_domains" ] || continue
        if grep -Fxq "${domain##*/}" "$OUT_DIR/domains.list"; then
            continue
        fi
        while IFS= read -r child; do
            if grep -Fxq "$child" "$OUT_DIR/domains.list"; then
                printf '%s\n' "${domain##*/}" >>"$OUT_DIR/domains.list"
                added=1
                break
            fi
        done <"$domain/sub_domains"
    done
done
trap 'test_result_finish FAIL "Power-domain residency observation interrupted"' HUP INT TERM
for phase in before after; do
    phase_dir="$OUT_DIR/$phase"
    mkdir -p "$phase_dir" || test_result_finish FAIL "Cannot retain domain observation"
    cat /sys/devices/system/cpu/online >"$phase_dir/online.list" || test_result_finish FAIL "Cannot capture CPU online mask"
    index=0
    : >"$phase_dir/totals.tsv"
    while IFS= read -r name; do
        index=$((index + 1))
        domain="$DOMAIN_ROOT/$name"
        if [ ! -r "$domain/total_idle_time" ] || [ ! -r "$domain/idle_states" ]; then
            if [ "$phase" = before ]; then
                test_result_finish SKIP "Domain=$name lacks readable idle accounting, enable genpd debugfs accounting"
            fi
            test_result_finish FAIL "Previously readable domain=$name lost its idle accounting"
        fi
        for attribute in total_idle_time idle_states devices sub_domains; do
            if ! cp "$domain/$attribute" "$phase_dir/$index-$attribute.log"; then
                test_result_finish FAIL "Cannot retain $attribute for domain=$name"
            fi
        done
        idle=$(awk 'NF==2 && $1 ~ /^[0-9]+$/ && $2=="ms" {count++; value=$1} END {if (NR!=1 || count!=1) exit 1; print value}' "$phase_dir/$index-total_idle_time.log") ||
            test_result_finish FAIL "Domain=$name exposes malformed total_idle_time"
        if ! awk '
            NR==1 {if ($1!="State" || $2!="Time(ms)" || $3!="Usage" || $4!="Rejected") bad=1; next}
            {if ($1 !~ /^S[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || seen[$1]++) bad=1}
            END {exit (bad || NR<2)}
        ' "$phase_dir/$index-idle_states.log"; then
            test_result_finish FAIL "Domain=$name exposes malformed idle-state counters"
        fi
        printf '%s %s\n' "$index" "$idle" >>"$phase_dir/totals.tsv"
    done <"$OUT_DIR/domains.list"
    cat /proc/uptime >"$phase_dir/uptime.log" || test_result_finish FAIL "Cannot capture monotonic observation timing"
    scan_dmesg_errors "$phase_dir/kernel" 'genpd|psci|cpuidle' '' || true
    if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
        if [ "$phase" = before ]; then
            test_result_finish SKIP "Power-domain validation requires readable kernel health evidence"
        fi
        test_result_finish FAIL "Kernel health evidence became unavailable after observation"
    fi
    if [ -s "$phase_dir/kernel/dmesg_errors.log" ]; then
        test_result_finish FAIL "Power-domain faults are present, inspect $phase_dir/kernel"
    fi
    if [ "$phase" = before ]; then
        sleep "$OBSERVE_SECONDS" || test_result_finish FAIL "Domain observation interval was interrupted"
    fi
done
if ! cmp -s "$OUT_DIR/before/online.list" "$OUT_DIR/after/online.list"; then
    test_result_finish SKIP "CPU online topology changed during power-domain observation, rerun without competing hotplug"
fi
elapsed=$(awk 'FILENAME==ARGV[1] {start=$1; next} {print $1-start}' "$OUT_DIR/before/uptime.log" "$OUT_DIR/after/uptime.log")
if ! awk -v value="$elapsed" 'BEGIN {exit !(value > 0)}'; then
    test_result_finish FAIL "Power-domain observation timing did not advance"
fi
index=0
while IFS= read -r name; do
    index=$((index + 1))
    attachments_stable=1
    for attribute in devices sub_domains; do
        if ! cmp -s "$OUT_DIR/before/$index-$attribute.log" "$OUT_DIR/after/$index-$attribute.log"; then
            attachments_stable=0
        fi
    done
    if [ "$attachments_stable" != 1 ]; then
        test_result_record SKIP "Domain=$name attachments changed, rerun on a stable topology"
        continue
    fi
    if ! awk '
        FNR==1 {next}
        FILENAME==ARGV[1] {usage[$1]=$3; rejected[$1]=$4; next}
        {if (!($1 in usage) || $3<usage[$1] || $4<rejected[$1]) bad=1; seen[$1]=1}
        END {for (state in usage) if (!(state in seen)) bad=1; exit bad}
    ' "$OUT_DIR/before/$index-idle_states.log" "$OUT_DIR/after/$index-idle_states.log"; then
        test_result_record FAIL "Domain=$name idle counters regressed or its state inventory changed"
        continue
    fi
    verdict=$(awk -v id="$index" -v elapsed="$elapsed" -v minimum="$MIN_PERCENT" '
        $1!=id {next}
        FILENAME==ARGV[1] {start=$2; next}
        {
            delta=$2-start; percent=100*delta/(elapsed*1000)
            if (delta<0 || (minimum!="" && percent<minimum)) state="FAIL"
            else if (delta>0) state="PASS"
            else state="SKIP"
            printf "%s %.3f",state,percent
        }
    ' "$OUT_DIR/before/totals.tsv" "$OUT_DIR/after/totals.tsv")
    test_result_record "${verdict%% *}" "Domain=$name measured_idle_percent=${verdict#* }, no arbitrary deepest-state requirement"
done <"$OUT_DIR/domains.list"

test_result_finish
