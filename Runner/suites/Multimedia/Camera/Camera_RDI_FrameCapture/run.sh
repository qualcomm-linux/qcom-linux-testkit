#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

TESTNAME="Camera_RDI_FrameCapture"
RES_FILE="./$TESTNAME.res"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

print_usage() {
    cat <<EOF
Usage: $0 [--format <v4l2_fmt>] [--frames <count>] [--help]

Options:
  --format <v4l2_fmt> Override capture format (e.g., UYVY, NV12)
  --frames <count> Number of frames to capture per pipeline (default: 10)
  --help Show this help message
EOF
}


log_info "----------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------"
log_info "=== Test Initialization ==="

# --------- Argument Parsing ---------
USER_FORMAT=""
FRAMES=10
while [ $# -gt 0 ]; do
    case "$1" in
        --format)
            shift
            USER_FORMAT="$1"
            ;;
        --frames)
            shift
            FRAMES="$1"
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            print_usage
            exit 1
            ;;
    esac
    shift
done

# --------- Prechecks ---------
if ! dt_confirm_node_or_compatible "isp" "cam" "camss"; then
    log_skip "$TESTNAME SKIP – No ISP/camera node/compatible found in DT"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

DRIVER_MOD="qcom_camss"
DMESG_MODULES='qcom_camss|camss|isp'
DMESG_EXCLUDE='dummy regulator|supply [^ ]+ not found|using dummy regulator|Failed to create device link|reboot-mode.*-EEXIST|can.t register reboot mode'

if ! is_module_loaded "$DRIVER_MOD"; then
    log_skip "$TESTNAME SKIP – Driver module $DRIVER_MOD not loaded"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if scan_dmesg_errors "$SCRIPT_DIR" "$DMESG_MODULES" "$DMESG_EXCLUDE"; then
    log_skip "$TESTNAME SKIP – $DRIVER_MOD probe errors detected in dmesg"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --------- Dependency Checks ---------
check_dependencies media-ctl yavta python3 v4l2-ctl || {
    log_skip "$TESTNAME SKIP – Required tools missing"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
}

# --------- Media Node Detection ---------
MEDIA_NODE=$(detect_media_node)
if [ -z "$MEDIA_NODE" ]; then
    log_skip "$TESTNAME SKIP – Media node not found"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi
log_info "Detected media node: $MEDIA_NODE"

# --------- Pipeline Detection ---------
TOPO_FILE=$(mktemp "/tmp/${TESTNAME}_topo.XXXXXX")
TMP_PIPELINES_FILE=$(mktemp "/tmp/${TESTNAME}_blocks.XXXXXX")
trap 'rm -f "$TOPO_FILE" "$TMP_PIPELINES_FILE"' EXIT

media-ctl -p -d "$MEDIA_NODE" >"$TOPO_FILE" 2>/dev/null
PYTHON_PIPELINES=$(run_camera_pipeline_parser "$TOPO_FILE")
if [ -z "$PYTHON_PIPELINES" ]; then
    log_skip "$TESTNAME SKIP – No valid pipelines found"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

printf "%s\n" "$PYTHON_PIPELINES" > "$TMP_PIPELINES_FILE"

log_info "User format override: ${USER_FORMAT:-<none>}"
log_info "Frame count per pipeline: $FRAMES"

# --------- Pipeline Processing ---------
PASS=0; FAIL=0; SKIP=0; COUNT=0
block=""

while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "--" ]; then
        COUNT=$((COUNT+1))
        TMP="/tmp/cam_block.$$.$COUNT"
        printf "%s\n" "$block" > "$TMP"

        # Parses block and sets SENSOR, VIDEO, YAVTA_DEV, FMT, etc
        parse_pipeline_block "$TMP"
        rm -f "$TMP"

        TARGET_FORMAT="${USER_FORMAT:-$YAVTA_FMT}"

        log_info "----- Pipeline $COUNT: ${SENSOR:-unknown} $VIDEO $TARGET_FORMAT -----"

        if [ -z "$VIDEO" ] || [ "$VIDEO" = "None" ] || [ -z "$YAVTA_DEV" ]; then
            log_skip "$SENSOR: Invalid pipeline – skipping"
            SKIP=$((SKIP+1))
            block=""
            continue
        fi

        configure_pipeline_block "$MEDIA_NODE" "$USER_FORMAT"
        execute_capture_block "$FRAMES" "$TARGET_FORMAT"
        RET=$?

        case "$RET" in
            0)
                log_pass "$SENSOR $VIDEO $TARGET_FORMAT PASS"
                PASS=$((PASS+1))
                ;;
            1)
                log_fail "$SENSOR $VIDEO $TARGET_FORMAT FAIL (capture failed)"
                FAIL=$((FAIL+1))
                ;;
            2)
                log_skip "$SENSOR $VIDEO $TARGET_FORMAT SKIP (unsupported format)"
                SKIP=$((SKIP+1))
                ;;
            3)
                log_skip "$SENSOR $VIDEO missing data – skipping"
                SKIP=$((SKIP+1))
                ;;
        esac
        block=""
    else
        if [ -z "$block" ]; then
            block="$line"
        else
            block="$block
$line"
        fi
    fi
done < "$TMP_PIPELINES_FILE"

log_info "Test Summary: Passed: $PASS, Failed: $FAIL, Skipped: $SKIP"
if [ "$PASS" -gt 0 ]; then
    echo "$TESTNAME PASS" >"$RES_FILE"
elif [ "$FAIL" -gt 0 ]; then
    echo "$TESTNAME FAIL" >"$RES_FILE"
else
    echo "$TESTNAME SKIP" >"$RES_FILE"
fi

exit 0
