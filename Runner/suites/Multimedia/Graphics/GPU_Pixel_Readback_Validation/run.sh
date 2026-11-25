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
TESTNAME="GPU_Pixel_Readback_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

BINARY=""
EXPECTED_NODE=""
TIMEOUT="120"

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate hardware GPU rendering through expected-pixel readback without a display.
  --binary <value>  Image-provided egl-readback executable, otherwise PATH discovery
  --expected-node <value>  Optional exact render-node expectation for the helper-selected device
  --timeout <value>  Maximum render-helper runtime in seconds
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
            --binary)
                BINARY="$2"
                ;;
            --expected-node)
                EXPECTED_NODE="$2"
                ;;
            --timeout)
                TIMEOUT="$2"
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


if ! printf '%s\n' "$TIMEOUT" | grep -Eq '^[1-9][0-9]{0,8}$'; then
    test_result_finish FAIL "--timeout must be a positive decimal integer of at most nine digits"
fi
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies readlink; then
    test_result_finish SKIP "Render-node identity requires image-provided readlink"
fi
if [ -n "$EXPECTED_NODE" ]; then
    case "$EXPECTED_NODE" in
        /dev/dri/renderD*)
            suffix=${EXPECTED_NODE#/dev/dri/renderD}
            case "$suffix" in
                ''|*[!0-9]*)
                    test_result_finish FAIL "--expected-node must name one /dev/dri/renderD<number> device"
                    ;;
            esac
            ;;
        *)
            test_result_finish FAIL "--expected-node must name one /dev/dri/renderD<number> device"
            ;;
    esac
fi
: >"$OUT_DIR/render-nodes.tsv"
for node in /sys/class/drm/renderD*; do
    [ -e "$node/device/driver" ] || continue
    name=${node##*/}
    [ -c "/dev/dri/$name" ] || continue
    printf '/dev/dri/%s %s\n' "$name" "$(readlink -f "$node/device/driver")" >>"$OUT_DIR/render-nodes.tsv"
done
if [ ! -s "$OUT_DIR/render-nodes.tsv" ]; then
    test_result_finish SKIP "No driver-bound DRM render device, provide a DRM GPU-enabled image"
fi
if [ -n "$EXPECTED_NODE" ] && ! awk -v expected="$EXPECTED_NODE" '$1 == expected {found=1} END {exit !found}' "$OUT_DIR/render-nodes.tsv"; then
    test_result_finish SKIP "Expected render device=$EXPECTED_NODE is unavailable, inspect $OUT_DIR/render-nodes.tsv"
fi
if [ -z "$BINARY" ]; then
    BINARY=$(command -v egl-readback 2>/dev/null || true)
else
    BINARY=$(command -v "$BINARY" 2>/dev/null || true)
fi
if [ -z "$BINARY" ] || [ ! -x "$BINARY" ]; then
    test_result_finish SKIP "Provision egl-readback with GBM/EGL/GLES support in the image, or select --binary"
fi
scan_dmesg_errors "$OUT_DIR/before" 'msm|drm|gpu|gmu|adreno' '' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_finish SKIP "GPU health validation needs readable kernel logs before rendering"
fi
if [ -s "$OUT_DIR/before/dmesg_errors.log" ]; then
    test_result_finish FAIL "GPU kernel faults exist before rendering, inspect $OUT_DIR/before"
fi
# The reference binary selects its own MSM device. It has no device CLI, so
# validate the node it actually reports instead of claiming a discovered node
# was used. An expected-node value is an assertion, not a routing parameter.
# shellcheck disable=SC2034 # Shared finish invokes the owned-child cleanup.
TEST_RESULT_CLEANUP=bounded_timeout_cancel
trap 'test_result_finish FAIL "GPU readback validation interrupted"' HUP INT TERM
run_with_bounded_timeout "$TIMEOUT" "$BINARY" >"$OUT_DIR/readback.log" 2>&1
helper_status=$?
scan_dmesg_errors "$OUT_DIR/after" 'msm|drm|gpu|gmu|adreno' '' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ]; then
    test_result_record FAIL "GPU kernel evidence became unavailable after rendering"
elif [ -s "$OUT_DIR/after/dmesg_errors.log" ]; then
    test_result_record FAIL "GPU rendering produced kernel faults, inspect $OUT_DIR/after"
fi
if [ "$helper_status" -ne 0 ]; then
    test_result_finish FAIL "GPU readback helper exited status=$helper_status, inspect $OUT_DIR/readback.log"
fi
selected=$(awk '$1 ~ /^\/dev\/dri\/renderD[0-9]+:$/ && $2 == "msm" {sub(/:$/, "", $1); print $1}' "$OUT_DIR/readback.log")
if [ -z "$selected" ] || ! awk -v selected="$selected" '$1 == selected {found=1} END {exit !found}' "$OUT_DIR/render-nodes.tsv"; then
    test_result_finish FAIL "Helper did not identify one discovered MSM render node, inspect $OUT_DIR/readback.log"
fi
if [ -n "$EXPECTED_NODE" ] && [ "$selected" != "$EXPECTED_NODE" ]; then
    test_result_finish FAIL "Helper rendered on node=$selected instead of expected=$EXPECTED_NODE"
fi
if ! awk '
    /^GL_RENDERER / {
        renderer++
        value=tolower($0)
        if (NF < 2 || value ~ /llvmpipe|softpipe|swrast|swiftshader|lavapipe|software rasterizer/) bad=1
    }
    /^pixel \([0-9]+,[0-9]+\) = [0-9]+ [0-9]+ [0-9]+ [0-9]+$/ {pixels[$2]=1}
    /^[1-9][0-9]* frames in [0-9.]+ s .*last pixel [0-9]+ [0-9]+ [0-9]+$/ {frames++}
    /^egl-readback: PASS$/ {complete++}
    /egl-readback: FAIL/ {bad=1}
    END {
        for (coordinate in pixels) count++
        exit (bad || renderer != 1 || count < 2 || frames != 1 || complete != 1)
    }
' "$OUT_DIR/readback.log"; then
    test_result_finish FAIL "Hardware renderer, distinct pixel checks or completed frame-loop evidence is missing or failed, inspect $OUT_DIR/readback.log"
fi
test_result_record PASS "GPU expected-pixel readback and frame loop completed on node=$selected"

test_result_finish
