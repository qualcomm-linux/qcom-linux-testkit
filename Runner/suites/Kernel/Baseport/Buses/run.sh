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
# shellcheck disable=SC1091
. "$TOOLS/lib_pkg_provider.sh"

TESTNAME="Buses"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME"

I2C_LEGACY_TEST_ENABLE="${I2C_LEGACY_TEST_ENABLE:-auto}"
I2C_TEST_ADAPTER="${I2C_TEST_ADAPTER:-auto}"
I2C_TEST_TIMEOUT="${I2C_TEST_TIMEOUT:-15}"
I2C_DMESG_STRICT="${I2C_DMESG_STRICT:-0}"
I2C_SCAN_ENABLE="${I2C_SCAN_ENABLE:-0}"
I2C_SCAN_MODE="${I2C_SCAN_MODE:-quick}"
I2C_READ_ADDRESS="${I2C_READ_ADDRESS:-}"
I2C_READ_REGISTER="${I2C_READ_REGISTER:-}"
I2C_READ_MODE="${I2C_READ_MODE:-b}"
I2C_READ_EXPECTED="${I2C_READ_EXPECTED:-}"
I2C_READ_MASK="${I2C_READ_MASK:-}"
I2C_WRITE_ADDRESS="${I2C_WRITE_ADDRESS:-}"
I2C_WRITE_REGISTER="${I2C_WRITE_REGISTER:-}"
I2C_WRITE_VALUE="${I2C_WRITE_VALUE:-}"
I2C_WRITE_MODE="${I2C_WRITE_MODE:-b}"
I2C_ALLOW_WRITE="${I2C_ALLOW_WRITE:-0}"
I2C_TOOLS_TIMEOUT="${I2C_TOOLS_TIMEOUT:-10}"

usage() {
    cat <<'EOF'
Usage: ./run.sh [options]

Options:
  --legacy-test          Run image-provided i2c-msm-test after inventory.
  --adapter BUS          Use /dev/i2c-BUS or an explicit /dev/i2c-* path.
  --timeout SECONDS      Legacy command timeout, default: 15.
  --tools-timeout SEC    i2c-tools command timeout, default: 10.
  --scan                 Scan addresses on the explicitly selected adapter.
  --scan-mode MODE       quick or read, default: quick.
  --read ADDRESS REG     Read one explicitly selected register.
  --read-mode MODE       b or w, default: b.
  --expected VALUE       Expected read value.
  --mask VALUE           Mask applied to expected read comparison.
  --write ADDRESS REG VALUE
                         Transactionally write, read back, and restore a register.
  --write-mode MODE      b or w, default: b.
  --allow-write          Confirm the selected register is safe to modify.
  -h, --help             Show this help.

Environment:
  I2C_LEGACY_TEST_ENABLE=auto|0|1
  I2C_TEST_ADAPTER=auto|BUS|/dev/i2c-BUS
  I2C_TEST_TIMEOUT=SECONDS
  I2C_DMESG_STRICT=0|1
  I2C_SCAN_ENABLE=0|1
  I2C_SCAN_MODE=quick|read
  I2C_READ_ADDRESS, I2C_READ_REGISTER, I2C_READ_MODE, I2C_READ_EXPECTED,
  I2C_READ_MASK, I2C_WRITE_ADDRESS, I2C_WRITE_REGISTER, I2C_WRITE_VALUE,
  I2C_WRITE_MODE, I2C_ALLOW_WRITE=0|1, I2C_TOOLS_TIMEOUT=SECONDS

Scanning and register operations auto-select a unique character adapter when
possible. Use --adapter when multiple adapters exist. Writes also require
--allow-write and always attempt to restore the original value.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --legacy-test)
                I2C_LEGACY_TEST_ENABLE=1
                shift
                ;;
            --adapter)
                [ "$#" -ge 2 ] || return 1
                I2C_TEST_ADAPTER="$2"
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 1
                I2C_TEST_TIMEOUT="$2"
                shift 2
                ;;
            --tools-timeout)
                [ "$#" -ge 2 ] || return 1
                I2C_TOOLS_TIMEOUT="$2"
                shift 2
                ;;
            --scan)
                I2C_SCAN_ENABLE=1
                shift
                ;;
            --scan-mode)
                [ "$#" -ge 2 ] || return 1
                I2C_SCAN_MODE="$2"
                shift 2
                ;;
            --read)
                [ "$#" -ge 3 ] || return 1
                I2C_READ_ADDRESS="$2"
                I2C_READ_REGISTER="$3"
                shift 3
                ;;
            --read-mode)
                [ "$#" -ge 2 ] || return 1
                I2C_READ_MODE="$2"
                shift 2
                ;;
            --expected)
                [ "$#" -ge 2 ] || return 1
                I2C_READ_EXPECTED="$2"
                shift 2
                ;;
            --mask)
                [ "$#" -ge 2 ] || return 1
                I2C_READ_MASK="$2"
                shift 2
                ;;
            --write)
                [ "$#" -ge 4 ] || return 1
                I2C_WRITE_ADDRESS="$2"
                I2C_WRITE_REGISTER="$3"
                I2C_WRITE_VALUE="$4"
                shift 4
                ;;
            --write-mode)
                [ "$#" -ge 2 ] || return 1
                I2C_WRITE_MODE="$2"
                shift 2
                ;;
            --allow-write)
                I2C_ALLOW_WRITE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                return 1
                ;;
        esac
    done
}

# cleanup
# Restores a register value when an interrupted write left restoration pending.
cleanup() {
    if ! i2c_tools_restore_pending_write; then
        log_fail "I2C emergency register restoration failed"
        return 1
    fi
}

# handle_signal
# Restores pending state before terminating after a signal.
handle_signal() {
    cleanup || true
    exit 1
}

parse_args "$@" || {
    usage >&2
    exit 2
}

case "$I2C_LEGACY_TEST_ENABLE" in
    auto|0|1)
        ;;
    *)
        log_warn "Invalid I2C_LEGACY_TEST_ENABLE='$I2C_LEGACY_TEST_ENABLE', using auto"
        I2C_LEGACY_TEST_ENABLE=auto
        ;;
esac

case "$I2C_DMESG_STRICT" in
    0|1)
        ;;
    *)
        log_warn "Invalid I2C_DMESG_STRICT='$I2C_DMESG_STRICT', using 0"
        I2C_DMESG_STRICT=0
        ;;
esac

case "$I2C_TEST_TIMEOUT" in
    ''|*[!0-9]*|0)
        log_warn "Invalid I2C_TEST_TIMEOUT='$I2C_TEST_TIMEOUT', using 15"
        I2C_TEST_TIMEOUT=15
        ;;
esac

case "$I2C_TOOLS_TIMEOUT" in
    ''|*[!0-9]*|0)
        log_error "I2C_TOOLS_TIMEOUT must be a positive integer"
        exit 2
        ;;
esac

case "$I2C_SCAN_ENABLE:$I2C_ALLOW_WRITE" in
    0:0|0:1|1:0|1:1)
        ;;
    *)
        log_error "I2C_SCAN_ENABLE and I2C_ALLOW_WRITE must be 0 or 1"
        exit 2
        ;;
esac

case "$I2C_SCAN_MODE" in
    quick|read)
        ;;
    *)
        log_error "I2C_SCAN_MODE must be quick or read"
        exit 2
        ;;
esac

case "$I2C_READ_MODE:$I2C_WRITE_MODE" in
    b:b|b:w|w:b|w:w)
        ;;
    *)
        log_error "I2C read and write modes must be b or w"
        exit 2
        ;;
esac

if [ -n "$I2C_READ_ADDRESS$I2C_READ_REGISTER" ] &&
   { [ -z "$I2C_READ_ADDRESS" ] || [ -z "$I2C_READ_REGISTER" ]; }; then
    log_error "Both I2C_READ_ADDRESS and I2C_READ_REGISTER are required"
    exit 2
fi

if [ -z "$I2C_READ_ADDRESS" ] &&
   { [ -n "$I2C_READ_EXPECTED" ] || [ -n "$I2C_READ_MASK" ]; }; then
    log_error "I2C expected value and mask require an explicit register read"
    exit 2
fi

if [ -n "$I2C_READ_MASK" ] && [ -z "$I2C_READ_EXPECTED" ]; then
    log_error "I2C_READ_MASK requires I2C_READ_EXPECTED"
    exit 2
fi

if [ -n "$I2C_WRITE_ADDRESS$I2C_WRITE_REGISTER$I2C_WRITE_VALUE" ] &&
   { [ -z "$I2C_WRITE_ADDRESS" ] || [ -z "$I2C_WRITE_REGISTER" ] || [ -z "$I2C_WRITE_VALUE" ]; }; then
    log_error "I2C write address, register, and value are all required"
    exit 2
fi

if [ -n "$I2C_WRITE_ADDRESS" ] && [ "$I2C_ALLOW_WRITE" -ne 1 ]; then
    log_error "Register writes require --allow-write or I2C_ALLOW_WRITE=1"
    exit 2
fi

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
trap cleanup EXIT
trap handle_signal HUP INT TERM

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create result directory $RESULT_DIR"
fi

TMPDIR="$SCRIPT_DIR"

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME I2C Testcase"
log_info "Configuration: legacy_test=$I2C_LEGACY_TEST_ENABLE adapter=$I2C_TEST_ADAPTER timeout=${I2C_TEST_TIMEOUT}s tools_timeout=${I2C_TOOLS_TIMEOUT}s scan=$I2C_SCAN_ENABLE scan_mode=$I2C_SCAN_MODE read=${I2C_READ_ADDRESS:-disabled}:${I2C_READ_REGISTER:-disabled}:$I2C_READ_MODE write=${I2C_WRITE_ADDRESS:-disabled}:${I2C_WRITE_REGISTER:-disabled}:$I2C_WRITE_MODE allow_write=$I2C_ALLOW_WRITE dmesg_strict=$I2C_DMESG_STRICT"

if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies \
    awk \
    basename \
    cat \
    dirname \
    find \
    grep \
    mkdir \
    mktemp \
    readlink \
    rm \
    sed \
    sort \
    tr \
    wc; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

i2c_collect_runtime_inventory "$RESULT_DIR"
i2c_inventory_status=$?

case "$i2c_inventory_status" in
    0)
        test_result_record \
            "PASS" \
            "I2C runtime is healthy: controllers=$I2C_RUNTIME_CONTROLLER_COUNT adapters=$I2C_RUNTIME_ADAPTER_COUNT clients=$I2C_RUNTIME_CLIENT_COUNT bound_clients=$I2C_RUNTIME_BOUND_CLIENT_COUNT"
        ;;
    1)
        test_result_record \
            "FAIL" \
            "I2C runtime validation failed: ${I2C_RUNTIME_FAILURE_REASON:-inconsistent controller, adapter, or client state}"
        ;;
    2)
        test_result_finish "SKIP" "$TESTNAME SKIP: I2C is not exposed by the runtime device tree or kernel"
        ;;
    *)
        test_result_finish "FAIL" "$TESTNAME FAIL: I2C runtime inventory could not complete"
        ;;
esac

i2c_devnode_count=0
for i2c_devnode in /dev/i2c-*; do
    [ -c "$i2c_devnode" ] || continue
    i2c_devnode_count=$((i2c_devnode_count + 1))
    log_info "[I2C-DEVNODE] path=$i2c_devnode"
done

if [ "$i2c_devnode_count" -gt 0 ]; then
    test_result_record "PASS" "I2C character devices are exposed: count=$i2c_devnode_count"
else
    test_result_record "SKIP" "I2C adapters are present but CONFIG_I2C_CHARDEV runtime nodes are not exposed"
fi

i2c_tools_explicit=0
if [ "$I2C_SCAN_ENABLE" -eq 1 ] ||
   [ -n "$I2C_READ_ADDRESS" ] ||
   [ -n "$I2C_WRITE_ADDRESS" ]; then
    i2c_tools_explicit=1
fi

if [ "$i2c_tools_explicit" -eq 1 ] && [ "$I2C_TEST_ADAPTER" = "auto" ]; then
    I2C_TEST_ADAPTER=$(i2c_tools_select_adapter)
    i2c_adapter_selection_status=$?
    case "$i2c_adapter_selection_status" in
        0)
            log_info "I2C functional adapter auto-selected: i2c-$I2C_TEST_ADAPTER"
            ;;
        1)
            test_result_finish "FAIL" "$TESTNAME FAIL: multiple I2C character adapters are available, select one with --adapter or I2C_TEST_ADAPTER"
            ;;
        *)
            test_result_finish "FAIL" "$TESTNAME FAIL: no I2C character adapter is available for the explicitly requested operation"
            ;;
    esac
fi

pkg_ensure_host_distro_package_set_present i2c-tools
i2c_tools_package_status=$?

case "$i2c_tools_package_status" in
    0)
        log_info "I2C userspace package set is ready"
        ;;
    1)
        if [ "$i2c_tools_explicit" -eq 1 ]; then
            log_warn "i2c-tools package recovery failed on $(pkg_detect_os_id), explicit operations will verify the required commands directly"
        else
            test_result_record "SKIP" "I2C userspace diagnostics are unavailable because i2c-tools package recovery failed on $(pkg_detect_os_id)"
        fi
        ;;
    2)
        log_info "I2C package recovery is not applicable, using image-provided tools"
        ;;
    *)
        test_result_record "FAIL" "I2C package preparation returned unexpected status $i2c_tools_package_status"
        ;;
esac

if [ "$i2c_tools_package_status" -ne 1 ]; then
    log_info "I2C userspace validation: listing adapters and querying adapter functionality without transferring device data"
    i2c_tools_validate_adapters "$RESULT_DIR" "$I2C_TOOLS_TIMEOUT"
    i2c_tools_status=$?
    case "$i2c_tools_status" in
        0)
            test_result_record "PASS" "i2c-tools validated $I2C_TOOLS_CAPABILITY_COUNT adapter functionality report(s)"
            ;;
        1)
            test_result_record "FAIL" "i2c-tools adapter listing or functionality query failed, see $RESULT_DIR/i2cdetect_*.log"
            ;;
        2)
            test_result_record "SKIP" "i2cdetect or an I2C character adapter is unavailable"
            ;;
        *)
            test_result_record "FAIL" "I2C adapter functionality helper returned unexpected status $i2c_tools_status"
            ;;
    esac
fi

if [ "$I2C_SCAN_ENABLE" -eq 1 ]; then
    log_warn "I2C address scan was explicitly requested for adapter=$I2C_TEST_ADAPTER mode=$I2C_SCAN_MODE"
    i2c_tools_scan_adapter \
        "$I2C_TEST_ADAPTER" \
        "$I2C_SCAN_MODE" \
        "$I2C_TOOLS_TIMEOUT" \
        "$RESULT_DIR"
    i2c_scan_status=$?
    case "$i2c_scan_status" in
        0)
            test_result_record "PASS" "Explicit I2C $I2C_SCAN_MODE address scan completed on adapter $I2C_TEST_ADAPTER"
            ;;
        1)
            test_result_record "FAIL" "Explicit I2C address scan failed on adapter $I2C_TEST_ADAPTER"
            ;;
        2)
            test_result_record "FAIL" "Explicit I2C address scan requires i2cdetect and an accessible adapter"
            ;;
        *)
            test_result_record "FAIL" "Explicit I2C address scan configuration is invalid"
            ;;
    esac
fi

if [ -n "$I2C_READ_ADDRESS" ]; then
    log_warn "I2C register read was explicitly requested for adapter=$I2C_TEST_ADAPTER address=$I2C_READ_ADDRESS register=$I2C_READ_REGISTER mode=$I2C_READ_MODE"
    i2c_tools_read_register \
        "$I2C_TEST_ADAPTER" \
        "$I2C_READ_ADDRESS" \
        "$I2C_READ_REGISTER" \
        "$I2C_READ_MODE" \
        "$I2C_TOOLS_TIMEOUT" \
        "$RESULT_DIR" \
        "$I2C_READ_EXPECTED" \
        "$I2C_READ_MASK"
    i2c_read_status=$?
    case "$i2c_read_status" in
        0)
            test_result_record "PASS" "Explicit I2C register read completed: adapter=$I2C_TEST_ADAPTER address=$I2C_READ_ADDRESS register=$I2C_READ_REGISTER value=$I2C_TOOLS_LAST_READ"
            ;;
        1)
            test_result_record "FAIL" "Explicit I2C register read or expected-value comparison failed"
            ;;
        2)
            test_result_record "FAIL" "Explicit I2C register read requires i2cget and an accessible adapter"
            ;;
        *)
            test_result_record "FAIL" "Explicit I2C register read configuration is invalid"
            ;;
    esac
fi

if [ -n "$I2C_WRITE_ADDRESS" ]; then
    log_warn "I2C transactional register write was explicitly authorized for adapter=$I2C_TEST_ADAPTER address=$I2C_WRITE_ADDRESS register=$I2C_WRITE_REGISTER mode=$I2C_WRITE_MODE"
    i2c_tools_write_restore_register \
        "$I2C_TEST_ADAPTER" \
        "$I2C_WRITE_ADDRESS" \
        "$I2C_WRITE_REGISTER" \
        "$I2C_WRITE_VALUE" \
        "$I2C_WRITE_MODE" \
        "$I2C_TOOLS_TIMEOUT" \
        "$RESULT_DIR"
    i2c_write_status=$?
    case "$i2c_write_status" in
        0)
            test_result_record "PASS" "Explicit I2C register write was read back and the original value was restored"
            ;;
        1)
            test_result_record "FAIL" "Explicit I2C register write, read-back, or restoration failed"
            ;;
        2)
            test_result_record "FAIL" "Explicit I2C register write requires i2cget, i2cset, and an accessible adapter"
            ;;
        *)
            test_result_record "FAIL" "Explicit I2C register write configuration is invalid"
            ;;
    esac
fi

if [ "$I2C_LEGACY_TEST_ENABLE" != 0 ]; then
    log_info "I2C functional validation: running the optional image-provided i2c-msm-test path"
    i2c_run_legacy_test "$RESULT_DIR" "$I2C_TEST_ADAPTER" "$I2C_TEST_TIMEOUT"
    i2c_legacy_status=$?
    case "$i2c_legacy_status" in
        0)
            test_result_record "PASS" "Legacy I2C functional validation completed on $I2C_LEGACY_SELECTED_ADAPTER"
            ;;
        1)
            test_result_record "FAIL" "i2c-msm-test failed, timed out, or omitted its required transfer markers"
            ;;
        2)
            test_result_record "SKIP" "Legacy I2C validation is unavailable because i2c-msm-test is not provided by the image"
            ;;
        4)
            if [ "$I2C_LEGACY_TEST_ENABLE" = "1" ]; then
                test_result_record "FAIL" "Legacy I2C functional test has no usable adapter: requested=$I2C_TEST_ADAPTER"
            else
                test_result_record "SKIP" "Automatic legacy I2C validation found no usable character-device adapter"
            fi
            ;;
        *)
            test_result_record "FAIL" "Legacy I2C functional validation received invalid configuration"
            ;;
    esac
else
    test_result_record "SKIP" "Legacy i2c-msm-test was disabled by configuration"
fi

log_info "I2C kernel-health validation: capturing controller errors without changing bus state"
scan_dmesg_errors \
    "$RESULT_DIR" \
    'geni_i2c.*|i2c_qcom_geni.*|i2c.*' \
    'deferred probe|EPROBE_DEFER|using dummy regulator|supply [^ ]+ not found'
i2c_dmesg_status=$?

if [ ! -s "$RESULT_DIR/dmesg_snapshot.log" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for I2C health validation"
elif [ "$i2c_dmesg_status" -eq 0 ] && [ "$I2C_DMESG_STRICT" -eq 1 ]; then
    test_result_record "FAIL" "I2C-related kernel errors were found in $RESULT_DIR/dmesg_errors.log"
elif [ "$i2c_dmesg_status" -eq 0 ]; then
    test_result_record "SKIP" "I2C kernel errors were retained as advisory evidence, set I2C_DMESG_STRICT=1 to gate them"
else
    test_result_record "PASS" "No non-benign I2C controller errors were found in the captured kernel log"
fi

test_result_finish
