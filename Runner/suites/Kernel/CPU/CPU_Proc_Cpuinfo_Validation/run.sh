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

TESTNAME="CPU_Proc_Cpuinfo_Validation"
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

deps_list="cat grep sed awk tr mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ ! -r /proc/cpuinfo ]; then
    test_result_record "FAIL" "/proc/cpuinfo is not readable"
    test_result_finish "FAIL"
fi

cpuinfo_ids() {
    awk '
        /^processor[[:space:]]*:/ { print $NF }
    ' /proc/cpuinfo | sort -n
}

cpuinfo_arm_ok() {
    awk '
        function flush() {
            if (proc == "") return
            if (imp == 0 || part == 0 || feat == 0) bad = 1
        }
        BEGIN { bad = 0; proc = "" }
        /^$/ { flush(); proc = ""; imp = 0; part = 0; feat = 0; next }
        /^processor[[:space:]]*:/ { proc = $NF }
        /^CPU implementer[[:space:]]*:/ { imp = 1 }
        /^CPU part[[:space:]]*:/ { part = 1 }
        /^Features[[:space:]]*:/ { feat = 1 }
        END { flush(); exit bad }
    ' /proc/cpuinfo
}

online_ids="$(get_online_cpus | sort -n | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
proc_ids="$(cpuinfo_ids | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
log_info "online_cpus=$online_ids cpuinfo_processors=$proc_ids"

if [ -z "$proc_ids" ]; then
    test_result_record "FAIL" "/proc/cpuinfo has no processor entries"
else
    test_result_record "PASS" "/proc/cpuinfo lists processors $proc_ids"
    if [ "$proc_ids" != "$online_ids" ]; then
        online_before="$online_ids"
        sleep 1
        online_ids="$(get_online_cpus | sort -n | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
        proc_ids="$(cpuinfo_ids | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
    fi
    if [ "$proc_ids" = "$online_ids" ]; then
        test_result_record "PASS" "cpuinfo processor ids match online CPUs ($online_ids)"
    elif [ "$online_ids" != "${online_before:-$online_ids}" ]; then
        test_result_record "SKIP" "online CPU set changed while reading cpuinfo"
    else
        test_result_record "FAIL" "cpuinfo processors ($proc_ids) do not match online CPUs ($online_ids)"
    fi
fi

arch="$(uname -m 2>/dev/null || true)"
case "$arch" in
    aarch64|arm64)
        if cpuinfo_arm_ok; then
            test_result_record "PASS" "each aarch64 processor has implementer, part, and Features"
        else
            test_result_record "FAIL" "an aarch64 processor record is missing implementer, part, or Features"
        fi
        ;;
    *)
        test_result_record "SKIP" "arch-specific cpuinfo field check not applied for $arch"
        ;;
esac

test_result_finish
