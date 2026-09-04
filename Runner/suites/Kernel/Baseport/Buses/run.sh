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

TESTNAME="Buses"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME"

I2C_LEGACY_TEST_ENABLE="${I2C_LEGACY_TEST_ENABLE:-auto}"
I2C_TEST_ADAPTER="${I2C_TEST_ADAPTER:-auto}"
I2C_TEST_TIMEOUT="${I2C_TEST_TIMEOUT:-15}"
I2C_DMESG_STRICT="${I2C_DMESG_STRICT:-0}"

usage() {
    cat <<'EOF'
Usage: ./run.sh [options]

Options:
  --legacy-test          Run image-provided i2c-msm-test after inventory.
  --adapter BUS          Use /dev/i2c-BUS or an explicit /dev/i2c-* path.
  --timeout SECONDS      Legacy command timeout, default: 15.
  -h, --help             Show this help.

Environment:
  I2C_LEGACY_TEST_ENABLE=auto|0|1
  I2C_TEST_ADAPTER=auto|BUS|/dev/i2c-BUS
  I2C_TEST_TIMEOUT=SECONDS
  I2C_DMESG_STRICT=0|1
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

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create result directory $RESULT_DIR"
fi

TMPDIR="$SCRIPT_DIR"

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME I2C Testcase"
log_info "Configuration: legacy_test=$I2C_LEGACY_TEST_ENABLE adapter=$I2C_TEST_ADAPTER timeout=${I2C_TEST_TIMEOUT}s dmesg_strict=$I2C_DMESG_STRICT"

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

if command -v i2cdetect >/dev/null 2>&1; then
    log_info "I2C userspace validation: listing adapters with the image-provided i2cdetect tool"
    if i2cdetect -l >"$RESULT_DIR/i2cdetect_list.log" 2>&1; then
        log_file_with_label "I2C-TOOLS" "$RESULT_DIR/i2cdetect_list.log"
        test_result_record "PASS" "i2cdetect listed the runtime I2C adapters"
    else
        log_file_with_label "I2C-TOOLS" "$RESULT_DIR/i2cdetect_list.log"
        test_result_record "FAIL" "i2cdetect is installed but failed to list adapters"
    fi
else
    test_result_record "SKIP" "Optional i2cdetect utility is not provided by the image"
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
