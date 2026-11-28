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

TESTNAME="RTC_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

RTC_DEVICE="${RTC_DEVICE:-auto}"
RTC_READ_DELAY="${RTC_READ_DELAY:-2}"
RTC_ALARM_ENABLE="${RTC_ALARM_ENABLE:-0}"
RTC_ALARM_DELAY="${RTC_ALARM_DELAY:-5}"
RTC_ALARM_TIMEOUT="${RTC_ALARM_TIMEOUT:-3}"
RTC_TIME_SET_ENABLE="${RTC_TIME_SET_ENABLE:-0}"
RTC_TIME_SET_OFFSET="${RTC_TIME_SET_OFFSET:-3}"
RTC_ALLOW_WRITE="${RTC_ALLOW_WRITE:-0}"

RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
RTC_RUNNER="$TOOLS/rtc_validation_runner.py"
SELECTED_RTC=""
SELECTED_RTC_SOURCE=""
RTC_CORE_STATUS="PASS"

# usage
# Prints the public command-line interface and examples. Produces no target
# state changes and returns success.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --device PATH             RTC character device, default: auto" \
        "  --read-delay SECONDS      Delay between RTC reads, default: 2" \
        "  --alarm-test              Opt in to bounded wake-alarm validation" \
        "  --alarm-delay SECONDS     Future alarm offset, default: 5" \
        "  --alarm-timeout SECONDS   Allowed expiration margin, default: 3" \
        "  --time-set-test           Opt in to RTC_SET_TIME validation" \
        "  --time-set-offset SECONDS Temporary RTC offset, default: 3" \
        "  --allow-write             Authorize RTC_SET_TIME and restoration" \
        "  -h, --help                Show this help" \
        "" \
        "Examples:" \
        "  ./run.sh" \
        "  ./run.sh --device /dev/rtc0 --alarm-test" \
        "  ./run.sh --time-set-test --allow-write"
}

# parse_args <suite-arguments...>
# Applies CLI overrides without probing or mutating the target. Returns 0 on
# success and 2 for missing values or unknown arguments.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --device)
                [ "$#" -ge 2 ] || return 2
                RTC_DEVICE="$2"
                shift 2
                ;;
            --read-delay)
                [ "$#" -ge 2 ] || return 2
                RTC_READ_DELAY="$2"
                shift 2
                ;;
            --alarm-test)
                RTC_ALARM_ENABLE=1
                shift
                ;;
            --alarm-delay)
                [ "$#" -ge 2 ] || return 2
                RTC_ALARM_DELAY="$2"
                shift 2
                ;;
            --alarm-timeout)
                [ "$#" -ge 2 ] || return 2
                RTC_ALARM_TIMEOUT="$2"
                shift 2
                ;;
            --time-set-test)
                RTC_TIME_SET_ENABLE=1
                shift
                ;;
            --time-set-offset)
                [ "$#" -ge 2 ] || return 2
                RTC_TIME_SET_OFFSET="$2"
                shift 2
                ;;
            --allow-write)
                RTC_ALLOW_WRITE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                return 2
                ;;
        esac
    done
}

# rtc_read_value <path> [fallback]
# Prints one whitespace-trimmed sysfs value. Diagnostics are intentionally not
# written to stdout because callers use command substitution.
rtc_read_value() {
    rtc_value_path="$1"
    rtc_value_fallback="${2:-unavailable}"

    if [ -r "$rtc_value_path" ]; then
        tr -d '\r\n' <"$rtc_value_path" 2>/dev/null || \
            printf '%s\n' "$rtc_value_fallback"
    else
        printf '%s\n' "$rtc_value_fallback"
    fi
}

# rtc_capture_inventory <artifact>
# Records every Linux RTC class device and its runtime relationships. Sets
# selection counters used by rtc_select_device and returns success.
rtc_capture_inventory() {
    rtc_inventory_file="$1"
    RTC_USABLE_COUNT=0
    RTC_HCTOSYS_COUNT=0
    RTC_ONLY_USABLE=""
    RTC_ONLY_HCTOSYS=""

    printf 'rtc\tdevnode\tcharacter\treadable\thctosys\tname\tdriver\twakeup\tirq\tsince_epoch\n' \
        >"$rtc_inventory_file"

    for rtc_class_dir in /sys/class/rtc/rtc*; do
        [ -d "$rtc_class_dir" ] || continue
        rtc_class_name=$(basename "$rtc_class_dir")
        rtc_devnode="/dev/$rtc_class_name"
        rtc_character=0
        rtc_readable=0
        rtc_hctosys=$(rtc_read_value "$rtc_class_dir/hctosys" 0)
        rtc_name=$(rtc_read_value "$rtc_class_dir/name")
        rtc_since_epoch=$(rtc_read_value "$rtc_class_dir/since_epoch")
        rtc_device_dir=$(readlink -f "$rtc_class_dir/device" 2>/dev/null || true)
        rtc_driver="unbound"
        rtc_wakeup="unavailable"
        rtc_irq="unavailable"

        [ -c "$rtc_devnode" ] && rtc_character=1
        [ -r "$rtc_devnode" ] && rtc_readable=1

        if [ -n "$rtc_device_dir" ]; then
            rtc_driver_path=$(readlink -f "$rtc_device_dir/driver" 2>/dev/null || true)
            if [ -n "$rtc_driver_path" ]; then
                rtc_driver=$(basename "$rtc_driver_path")
            fi
            rtc_wakeup=$(rtc_read_value "$rtc_device_dir/power/wakeup")
            rtc_irq=$(rtc_read_value "$rtc_device_dir/irq")
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$rtc_class_name" \
            "$rtc_devnode" \
            "$rtc_character" \
            "$rtc_readable" \
            "$rtc_hctosys" \
            "$rtc_name" \
            "$rtc_driver" \
            "$rtc_wakeup" \
            "$rtc_irq" \
            "$rtc_since_epoch" \
            >>"$rtc_inventory_file"

        log_info "[RTC-DEVICE] rtc=$rtc_class_name devnode=$rtc_devnode character=$rtc_character readable=$rtc_readable hctosys=$rtc_hctosys name=$rtc_name driver=$rtc_driver wakeup=$rtc_wakeup irq=$rtc_irq since_epoch=$rtc_since_epoch"

        if [ "$rtc_character" -eq 1 ] && [ "$rtc_readable" -eq 1 ]; then
            RTC_USABLE_COUNT=$((RTC_USABLE_COUNT + 1))
            RTC_ONLY_USABLE="$rtc_devnode"
            if [ "$rtc_hctosys" = "1" ]; then
                RTC_HCTOSYS_COUNT=$((RTC_HCTOSYS_COUNT + 1))
                RTC_ONLY_HCTOSYS="$rtc_devnode"
            fi
        fi
    done
}

# rtc_select_device
# Selects an explicit RTC, the unique hctosys RTC, or the sole usable RTC.
# Returns 0 on selection, 1 for an invalid explicit path, and 2 when automatic
# selection is not applicable or is ambiguous.
rtc_select_device() {
    if [ "$RTC_DEVICE" != "auto" ]; then
        rtc_explicit_real=$(readlink -f "$RTC_DEVICE" 2>/dev/null || true)
        case "$rtc_explicit_real" in
            /dev/rtc*)
                ;;
            *)
                return 1
                ;;
        esac
        if [ ! -c "$rtc_explicit_real" ] || [ ! -r "$rtc_explicit_real" ]; then
            return 2
        fi
        SELECTED_RTC="$rtc_explicit_real"
        SELECTED_RTC_SOURCE="explicit"
        return 0
    fi

    if [ "$RTC_HCTOSYS_COUNT" -eq 1 ]; then
        SELECTED_RTC="$RTC_ONLY_HCTOSYS"
        SELECTED_RTC_SOURCE="unique-hctosys"
        return 0
    fi

    if [ "$RTC_USABLE_COUNT" -eq 1 ]; then
        SELECTED_RTC="$RTC_ONLY_USABLE"
        SELECTED_RTC_SOURCE="sole-usable-device"
        return 0
    fi

    return 2
}

# rtc_report_value <report> <key>
# Prints the first value for a report key and no diagnostics.
rtc_report_value() {
    rtc_report_file="$1"
    rtc_report_key="$2"
    awk -F '\t' -v wanted="$rtc_report_key" \
        '$1 == wanted { print substr($0, index($0, "\t") + 1); exit }' \
        "$rtc_report_file" 2>/dev/null
}

# rtc_record_helper_result <mode> <return-code> <report>
# Replays helper evidence and records the mode-specific PASS, FAIL, or SKIP.
rtc_record_helper_result() {
    rtc_result_mode="$1"
    rtc_result_rc="$2"
    rtc_result_report="$3"
    rtc_result_reason=$(rtc_report_value "$rtc_result_report" reason)
    rtc_result_reason="${rtc_result_reason:-helper-did-not-produce-a-reason}"
    rtc_result_message=$(rtc_report_value "$rtc_result_report" message)

    log_file_with_label "RTC-REPORT" "$rtc_result_report" 40
    case "$rtc_result_rc" in
        0)
            test_result_record "PASS" "RTC $rtc_result_mode validation passed, reason=$rtc_result_reason report=$rtc_result_report"
            ;;
        2)
            if [ -n "$rtc_result_message" ]; then
                test_result_record "SKIP" "$rtc_result_message, reason=$rtc_result_reason report=$rtc_result_report"
            else
                test_result_record "SKIP" "RTC $rtc_result_mode validation is unavailable, reason=$rtc_result_reason report=$rtc_result_report"
            fi
            ;;
        *)
            test_result_record "FAIL" "RTC $rtc_result_mode validation failed, rc=$rtc_result_rc reason=$rtc_result_reason report=$rtc_result_report"
            ;;
    esac
}

parse_args "$@" || {
    usage >&2
    exit 2
}

for rtc_numeric_value in \
    "$RTC_READ_DELAY" \
    "$RTC_ALARM_DELAY" \
    "$RTC_ALARM_TIMEOUT" \
    "$RTC_TIME_SET_OFFSET"; do
    case "$rtc_numeric_value" in
        ''|*[!0-9]*|0)
            log_error "RTC delay, timeout, and offset values must be positive integers"
            exit 2
            ;;
    esac
done

for rtc_boolean_value in \
    "$RTC_ALARM_ENABLE" \
    "$RTC_TIME_SET_ENABLE" \
    "$RTC_ALLOW_WRITE"; do
    case "$rtc_boolean_value" in
        0|1)
            ;;
        *)
            log_error "RTC enable and write policy values must be 0 or 1"
            exit 2
            ;;
    esac
done

if [ "$RTC_TIME_SET_ENABLE" = "1" ] && [ "$RTC_ALLOW_WRITE" != "1" ]; then
    log_error "RTC time-set validation requires --allow-write or RTC_ALLOW_WRITE=1"
    exit 2
fi

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "RTC validation: dynamically selecting a Linux RTC and validating direct ioctl behavior"
log_info "Configuration: device=$RTC_DEVICE read_delay=${RTC_READ_DELAY}s alarm_enable=$RTC_ALARM_ENABLE alarm_delay=${RTC_ALARM_DELAY}s alarm_timeout=${RTC_ALARM_TIMEOUT}s time_set_enable=$RTC_TIME_SET_ENABLE time_set_offset=${RTC_TIME_SET_OFFSET}s allow_write=$RTC_ALLOW_WRITE"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies awk basename date mkdir python3 readlink tr; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required image-provided base utilities are unavailable"
fi

if [ ! -r "$RTC_RUNNER" ]; then
    test_result_finish "FAIL" "$TESTNAME FAIL: in-repository RTC helper is missing: $RTC_RUNNER"
fi

if [ ! -d /sys/class/rtc ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: Linux RTC class is not exposed"
fi

rtc_capture_inventory "$RESULT_DIR/rtc_devices.tsv"
log_info "[RTC-DISCOVERY] usable=$RTC_USABLE_COUNT hctosys=$RTC_HCTOSYS_COUNT artifact=$RESULT_DIR/rtc_devices.tsv"

rtc_select_device
rtc_select_rc=$?
case "$rtc_select_rc" in
    0)
        log_info "[RTC-SELECTION] device=$SELECTED_RTC source=$SELECTED_RTC_SOURCE"
        ;;
    1)
        test_result_finish "FAIL" "$TESTNAME FAIL: explicit RTC path must resolve to a /dev/rtc* character device"
        ;;
    *)
        if [ "$RTC_DEVICE" != "auto" ]; then
            test_result_finish "SKIP" "$TESTNAME SKIP: requested RTC device is unavailable or unreadable: $RTC_DEVICE"
        elif [ "$RTC_USABLE_COUNT" -eq 0 ]; then
            test_result_finish "SKIP" "$TESTNAME SKIP: no readable RTC character device was discovered"
        else
            test_result_finish "SKIP" "$TESTNAME SKIP: RTC selection is ambiguous, choose one of $RTC_USABLE_COUNT devices with --device"
        fi
        ;;
esac

rtc_read_report="$RESULT_DIR/rtc_read.tsv"
rtc_read_log="$RESULT_DIR/rtc_read.log"
rtc_read_timeout=$((RTC_READ_DELAY + 10))
if run_with_timeout_log \
    "$rtc_read_timeout" \
    "$rtc_read_log" \
    python3 \
    "$RTC_RUNNER" \
    --mode read \
    --device "$SELECTED_RTC" \
    --read-delay "$RTC_READ_DELAY" \
    --report "$rtc_read_report"; then
    rtc_read_rc=0
else
    rtc_read_rc=$?
fi
log_file_with_label "RTC-READ" "$rtc_read_log" 20
rtc_record_helper_result "time-read and progression" "$rtc_read_rc" "$rtc_read_report"
case "$rtc_read_rc" in
    0)
        RTC_CORE_STATUS="PASS"
        ;;
    2)
        RTC_CORE_STATUS="SKIP"
        ;;
    *)
        RTC_CORE_STATUS="FAIL"
        ;;
esac

if [ "$RTC_ALARM_ENABLE" = "1" ]; then
    rtc_alarm_report="$RESULT_DIR/rtc_alarm.tsv"
    rtc_alarm_log="$RESULT_DIR/rtc_alarm.log"
    rtc_alarm_run_timeout=$((RTC_ALARM_DELAY + RTC_ALARM_TIMEOUT + 10))
    if run_with_timeout_log \
        "$rtc_alarm_run_timeout" \
        "$rtc_alarm_log" \
        python3 \
        "$RTC_RUNNER" \
        --mode alarm \
        --device "$SELECTED_RTC" \
        --alarm-delay "$RTC_ALARM_DELAY" \
        --alarm-timeout "$RTC_ALARM_TIMEOUT" \
        --report "$rtc_alarm_report"; then
        rtc_alarm_rc=0
    else
        rtc_alarm_rc=$?
    fi
    log_file_with_label "RTC-ALARM" "$rtc_alarm_log" 20
    rtc_record_helper_result "wake-alarm" "$rtc_alarm_rc" "$rtc_alarm_report"
else
    test_result_record "SKIP" "RTC wake-alarm validation is disabled by default, use --alarm-test to opt in"
fi

if [ "$RTC_TIME_SET_ENABLE" = "1" ]; then
    rtc_time_set_report="$RESULT_DIR/rtc_time_set.tsv"
    rtc_time_set_log="$RESULT_DIR/rtc_time_set.log"
    rtc_time_set_timeout=$((RTC_READ_DELAY + 10))
    if run_with_timeout_log \
        "$rtc_time_set_timeout" \
        "$rtc_time_set_log" \
        python3 \
        "$RTC_RUNNER" \
        --mode set-time \
        --device "$SELECTED_RTC" \
        --read-delay "$RTC_READ_DELAY" \
        --time-set-offset "$RTC_TIME_SET_OFFSET" \
        --report "$rtc_time_set_report"; then
        rtc_time_set_rc=0
    else
        rtc_time_set_rc=$?
    fi
    log_file_with_label "RTC-TIME-SET" "$rtc_time_set_log" 20
    rtc_record_helper_result "time-set and restoration" "$rtc_time_set_rc" "$rtc_time_set_report"
else
    test_result_record "SKIP" "RTC time-set validation is disabled by default, use --time-set-test --allow-write to opt in"
fi

export KERNEL_LOG_JOURNAL_FALLBACK=1
# Match RTC identifier segments such as pm8xxx_rtc_* and qcom_pmic_rtc_glink.
# Bound fault symbols without changing the existing ordinary-error selection.
rtc_fault_regex='([[:alnum:]_]+[-_])*rtc([-_][[:alnum:]_-]+|[0-9]*)'
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'rtc[-_0-9 ]|qpnp_rtc|pmic.*rtc|qcom.*rtc' \
    'registered as rtc[0-9]+|setting system clock|system clock set' \
    "(^|[^[:alnum:]_])($rtc_fault_regex)([^[:alnum:]_]|$)"
rtc_dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for RTC health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$rtc_dmesg_rc" -eq 0 ]; then
    log_file_with_label "RTC-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 25
    test_result_record "FAIL" "RTC-related kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No non-benign RTC-related kernel errors were found"
fi

if [ "$RTC_CORE_STATUS" = "SKIP" ] && [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: direct RTC time validation was unavailable"
fi

test_result_finish
