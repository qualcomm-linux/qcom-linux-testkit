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

TESTNAME="DMAEngine_Data_Integrity_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

DMA_CHANNEL="${DMATEST_CHANNEL:-auto}"
DMA_ITERATIONS="${DMATEST_ITERATIONS:-20}"
DMA_TIMEOUT_MS="${DMATEST_TIMEOUT_MS:-3000}"
RUN_TIMEOUT_SECONDS="${DMATEST_RUN_TIMEOUT_SECONDS:-90}"

DMATEST_DIR="/sys/module/dmatest/parameters"
LOADED_BY_TEST=0
PARAMETERS_CHANGED=0

# usage
# Prints supported command-line options and returns success.
usage() {
    printf '%s\n' "Usage: $0 [--channel NAME|auto] [--iterations N] [--timeout-ms N] [--run-timeout N]"
}

# parse_args <arguments...>
# Parses command-line overrides and exits for help or invalid input.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --channel)
                [ "$#" -ge 2 ] || {
                    usage >&2
                    exit 2
                }
                DMA_CHANNEL="$2"
                shift 2
                ;;
            --iterations)
                [ "$#" -ge 2 ] || {
                    usage >&2
                    exit 2
                }
                DMA_ITERATIONS="$2"
                shift 2
                ;;
            --timeout-ms)
                [ "$#" -ge 2 ] || {
                    usage >&2
                    exit 2
                }
                DMA_TIMEOUT_MS="$2"
                shift 2
                ;;
            --run-timeout)
                [ "$#" -ge 2 ] || {
                    usage >&2
                    exit 2
                }
                RUN_TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_fail "Unknown argument: $1"
                usage >&2
                exit 2
                ;;
        esac
    done
}

# snapshot_parameters <output-file>
# Saves the dmatest parameters changed by this suite as "name|value" records. Returns 0
# when the parameters directory exists, otherwise 1.
snapshot_parameters() {
    output_file="$1"
    [ -d "$DMATEST_DIR" ] || return 1
    : >"$output_file"

    for parameter_name in timeout iterations threads_per_chan noverify verbose channel; do
        parameter_path="$DMATEST_DIR/$parameter_name"
        [ -r "$parameter_path" ] || continue
        parameter_value=$(tr -d '\r\n' <"$parameter_path")
        printf '%s|%s\n' "$parameter_name" "$parameter_value" >>"$output_file"
    done

    return 0
}

# restore_parameters <snapshot-file>
# Restores previously saved dmatest scalar parameters. Returns success even if
# individual read-only parameters cannot be restored, after logging warnings.
# shellcheck disable=SC2317
restore_parameters() {
    snapshot_file="$1"
    [ -r "$snapshot_file" ] || return 0
    [ -d "$DMATEST_DIR" ] || return 0

    while IFS='|' read -r parameter_name parameter_value; do
        [ -n "$parameter_name" ] || continue
        parameter_path="$DMATEST_DIR/$parameter_name"
        [ -w "$parameter_path" ] || continue
        if ! printf '%s\n' "$parameter_value" >"$parameter_path" 2>/dev/null; then
            log_warn "Could not restore dmatest parameter $parameter_name"
        fi
    done <"$snapshot_file"
}

# cleanup
# Stops a test started by this suite, restores pre-existing parameter values,
# and unloads dmatest only when this suite loaded it. Returns success.
# shellcheck disable=SC2317
cleanup() {
    if [ "$PARAMETERS_CHANGED" -eq 1 ] && [ -w "$DMATEST_DIR/run" ]; then
        printf '%s\n' 0 >"$DMATEST_DIR/run" 2>/dev/null || true
    fi

    if [ "$LOADED_BY_TEST" -eq 1 ]; then
        unload_kernel_module dmatest false || log_warn "Could not unload dmatest loaded by this suite"
    else
        restore_parameters "$SCRIPT_DIR/dmatest_parameters_before.log"
    fi
}

# configure_channel <channel-name>
# Requests one DMA channel from dmatest and verifies the accepted channel
# through the channel parameter. Returns 0 when accepted, otherwise 1.
configure_channel() {
    channel_name="$1"
    [ -n "$channel_name" ] || return 1

    if ! printf '%s\n' "$channel_name" >"$DMATEST_DIR/channel" 2>/dev/null; then
        return 1
    fi

    configured_channel=$(tr -d '\r\n' <"$DMATEST_DIR/channel" 2>/dev/null || true)
    if [ "$configured_channel" = "$channel_name" ]; then
        return 0
    fi

    return 1
}

# select_dma_channel
# Prints and configures the requested channel, or the first idle channel that
# dmatest accepts when auto-selection is requested. Returns 0 on success.
select_dma_channel() {
    if [ "$DMA_CHANNEL" != "auto" ]; then
        [ -d "/sys/class/dma/$DMA_CHANNEL" ] || return 1
        if [ -r "/sys/class/dma/$DMA_CHANNEL/in_use" ] &&
           [ "$(tr -d '[:space:]' <"/sys/class/dma/$DMA_CHANNEL/in_use")" != "0" ]; then
            return 1
        fi
        configure_channel "$DMA_CHANNEL" || return 1
        printf '%s\n' "$DMA_CHANNEL"
        return 0
    fi

    for channel_dir in /sys/class/dma/*; do
        [ -d "$channel_dir" ] || continue
        channel_name=$(basename "$channel_dir")
        if [ -r "$channel_dir/in_use" ] &&
           [ "$(tr -d '[:space:]' <"$channel_dir/in_use")" != "0" ]; then
            continue
        fi
        if configure_channel "$channel_name"; then
            printf '%s\n' "$channel_name"
            return 0
        fi
    done

    return 1
}

parse_args "$@"

for numeric_value in "$DMA_ITERATIONS" "$DMA_TIMEOUT_MS" "$RUN_TIMEOUT_SECONDS"; do
    case "$numeric_value" in
        ''|*[!0-9]*|0)
            log_fail "Iterations, timeout, and run-timeout values must be positive integers"
            exit 2
            ;;
    esac
done

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
rm -f \
    "$SCRIPT_DIR/dmatest_parameters_before.log" \
    "$SCRIPT_DIR/dmatest_new.log"

trap cleanup 0
trap 'exit 130' 1 2 15

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Configuration: channel=$DMA_CHANNEL iterations=$DMA_ITERATIONS timeout_ms=$DMA_TIMEOUT_MS run_timeout_seconds=$RUN_TIMEOUT_SECONDS"

dmatest_config=$(kernel_config_value CONFIG_DMATEST 2>/dev/null || true)
if [ -n "$dmatest_config" ]; then
    log_info "[DMAENGINE-CONFIG] $dmatest_config"
else
    dmatest_config="unavailable"
    log_info "[DMAENGINE-CONFIG] CONFIG_DMATEST=unavailable, running-kernel configuration could not be read"
fi

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies awk grep sed wc tr basename sleep cp; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

if [ ! -d /sys/class/dma ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: the DMAEngine class is not available"
fi

scan_dmesg_errors \
    "$SCRIPT_DIR/dmesg_before" \
    "dmatest|dmaengine|dma" \
    "No errors|0 failures" || true
baseline_lines=$(wc -l <"$SCRIPT_DIR/dmesg_before/dmesg_snapshot.log" 2>/dev/null || printf '%s\n' 0)

if [ -d "$DMATEST_DIR" ]; then
    snapshot_parameters "$SCRIPT_DIR/dmatest_parameters_before.log" || true
    if [ -r "$DMATEST_DIR/run" ] &&
       grep -Eq '^(Y|1)$' "$DMATEST_DIR/run" 2>/dev/null; then
        test_result_finish "SKIP" "$TESTNAME SKIP: an existing dmatest run is active"
    fi
    configured_channel=$(tr -d '\r\n' <"$DMATEST_DIR/channel" 2>/dev/null || true)
    if [ -n "$configured_channel" ]; then
        test_result_finish "SKIP" "$TESTNAME SKIP: dmatest already has configured channels"
    fi
else
    case "$dmatest_config" in
        CONFIG_DMATEST=n)
            test_result_finish \
                "SKIP" \
                "$TESTNAME SKIP: CONFIG_DMATEST is disabled in the running kernel. Enable CONFIG_DMATEST=m and package the matching dmatest.ko, or enable CONFIG_DMATEST=y"
            ;;
        CONFIG_DMATEST=y)
            test_result_finish \
                "FAIL" \
                "$TESTNAME FAIL: CONFIG_DMATEST=y but $DMATEST_DIR is unavailable, the built-in dmatest runtime did not initialize"
            ;;
    esac

    module_path=$(find_kernel_module dmatest)
    if [ -n "$module_path" ]; then
        case "$module_path" in
            "/lib/modules/$(uname -r)/"*)
                ;;
            *)
                log_warn "Ignoring dmatest module from a non-running kernel tree: $module_path"
                module_path=""
                ;;
        esac
    fi
    if [ -z "$module_path" ]; then
        case "$dmatest_config" in
            CONFIG_DMATEST=m)
                test_result_finish \
                    "FAIL" \
                    "$TESTNAME FAIL: CONFIG_DMATEST=m but the matching dmatest.ko is missing from /lib/modules/$(uname -r). Package the module with the running kernel"
                ;;
            *)
                test_result_finish \
                    "SKIP" \
                    "$TESTNAME SKIP: CONFIG_DMATEST could not be determined and no matching dmatest module is available. Enable CONFIG_DMATEST=m and package dmatest.ko with the running kernel, or enable CONFIG_DMATEST=y"
                ;;
        esac
    fi
    if ! load_kernel_module "$module_path"; then
        test_result_finish "FAIL" "$TESTNAME FAIL: the image-provided dmatest module could not be loaded"
    fi
    LOADED_BY_TEST=1
fi

if [ ! -d "$DMATEST_DIR" ]; then
    test_result_finish "FAIL" "$TESTNAME FAIL: dmatest parameters are unavailable after driver activation"
fi

for required_parameter in run channel iterations timeout noverify; do
    if [ ! -w "$DMATEST_DIR/$required_parameter" ]; then
        test_result_finish "SKIP" "$TESTNAME SKIP: dmatest parameter is not writable: $required_parameter"
    fi
done

printf '%s\n' "$DMA_ITERATIONS" >"$DMATEST_DIR/iterations"
printf '%s\n' "$DMA_TIMEOUT_MS" >"$DMATEST_DIR/timeout"
printf '%s\n' N >"$DMATEST_DIR/noverify"
if [ -w "$DMATEST_DIR/threads_per_chan" ]; then
    printf '%s\n' 1 >"$DMATEST_DIR/threads_per_chan"
fi
if [ -w "$DMATEST_DIR/verbose" ]; then
    printf '%s\n' 1 >"$DMATEST_DIR/verbose"
fi
PARAMETERS_CHANGED=1

if ! selected_channel=$(select_dma_channel); then
    test_result_finish "SKIP" "$TESTNAME SKIP: no idle DMA memcpy channel was accepted by dmatest"
fi
log_pass "DMA channel selected for verified memcpy testing: $selected_channel"

printf '%s\n' 1 >"$DMATEST_DIR/run"

elapsed=0
while [ "$elapsed" -lt "$RUN_TIMEOUT_SECONDS" ]; do
    run_state=$(tr -d '[:space:]' <"$DMATEST_DIR/run" 2>/dev/null || true)
    case "$run_state" in
        N|0)
            break
            ;;
    esac
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ "$elapsed" -ge "$RUN_TIMEOUT_SECONDS" ]; then
    test_result_finish "FAIL" "$TESTNAME FAIL: dmatest did not complete within $RUN_TIMEOUT_SECONDS seconds"
fi

scan_dmesg_errors \
    "$SCRIPT_DIR/dmesg_after" \
    "dmatest|dmaengine|dma" \
    "No errors|0 failures" || true

after_snapshot="$SCRIPT_DIR/dmesg_after/dmesg_snapshot.log"
after_lines=$(wc -l <"$after_snapshot" 2>/dev/null || printf '%s\n' 0)
if [ "$after_lines" -ge "$baseline_lines" ]; then
    first_new_line=$((baseline_lines + 1))
    sed -n "${first_new_line},\$p" "$after_snapshot" >"$SCRIPT_DIR/dmatest_new.log"
else
    cp "$after_snapshot" "$SCRIPT_DIR/dmatest_new.log"
fi

summary_count=$(grep -c 'dmatest: .*summary' "$SCRIPT_DIR/dmatest_new.log" 2>/dev/null || true)
summary_count=${summary_count:-0}
if [ "$summary_count" -eq 0 ]; then
    test_result_finish "FAIL" "$TESTNAME FAIL: no new dmatest completion summary was captured"
fi

if grep -Eq "dmatest: .*summary .* [1-9][0-9]* failures|mismatch|timed out|timeout|corrupt" \
    "$SCRIPT_DIR/dmatest_new.log"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: DMA data-integrity errors were reported"
fi

if ! grep -Eq 'dmatest: .*summary .* 0 failures' "$SCRIPT_DIR/dmatest_new.log"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: dmatest summaries did not report zero failures"
fi

while IFS= read -r result_line; do
    log_info "[DMATEST] $result_line"
done <"$SCRIPT_DIR/dmatest_new.log"

test_result_finish "PASS" "$TESTNAME PASS: channel=$selected_channel summaries=$summary_count"
