#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# tflite_benchmark_defaults <cpu|gpu|qnn-htp>
# Initializes the selected fixed benchmark profile and public override policy.
tflite_benchmark_defaults() {
    TFLITE_BENCH_PROFILE="$1"
    TFLITE_BENCH_OS_ID=$(pkg_detect_os_id)
    TFLITE_BENCH_TIMEOUT="${TFLITE_TIMEOUT:-120}"
    TFLITE_BENCH_TIMEOUT_SOURCE="default"
    if [ -n "${TFLITE_TIMEOUT:-}" ]; then
        TFLITE_BENCH_TIMEOUT_SOURCE="environment"
    fi
    TFLITE_BENCH_TIMEOUT_MAX=600

    TFLITE_BENCH_BINARY_OVERRIDE="${TFLITE_BENCHMARK_BINARY:-}"
    TFLITE_BENCH_BINARY_SOURCE="dynamic"
    if [ -n "$TFLITE_BENCH_BINARY_OVERRIDE" ]; then
        TFLITE_BENCH_BINARY_SOURCE="environment"
    fi

    TFLITE_BENCH_MODEL_OVERRIDE="${TFLITE_MODEL:-}"
    TFLITE_BENCH_MODEL_SOURCE="unset"
    if [ -n "$TFLITE_BENCH_MODEL_OVERRIDE" ]; then
        TFLITE_BENCH_MODEL_SOURCE="environment"
    fi

    TFLITE_BENCH_FETCH_MODEL="${TFLITE_FETCH_MODEL:-0}"
    TFLITE_BENCH_FETCH_MODEL_SOURCE="default"
    if [ -n "${TFLITE_FETCH_MODEL:-}" ]; then
        TFLITE_BENCH_FETCH_MODEL_SOURCE="environment"
    fi
    TFLITE_BENCH_AI_HUB_VERSION="${TFLITE_AI_HUB_VERSION:-0.63.0}"
    TFLITE_BENCH_AI_HUB_VERSION_SOURCE="default-latest-reviewed"
    if [ -n "${TFLITE_AI_HUB_VERSION:-}" ]; then
        TFLITE_BENCH_AI_HUB_VERSION_SOURCE="environment"
    fi
    TFLITE_BENCH_FETCH_TIMEOUT="${TFLITE_MODEL_FETCH_TIMEOUT:-300}"
    TFLITE_BENCH_FETCH_TIMEOUT_SOURCE="default"
    if [ -n "${TFLITE_MODEL_FETCH_TIMEOUT:-}" ]; then
        TFLITE_BENCH_FETCH_TIMEOUT_SOURCE="environment"
    fi

    TFLITE_BENCH_CONFIGURATION_REQUEST="${TFLITE_CONFIGURATION:-auto}"
    TFLITE_BENCH_CONFIGURATION_SOURCE="default"
    if [ -n "${TFLITE_CONFIGURATION:-}" ]; then
        TFLITE_BENCH_CONFIGURATION_SOURCE="environment"
    fi

    TFLITE_BENCH_DELEGATE_OVERRIDE="${TFLITE_DELEGATE_LIBRARY:-}"
    TFLITE_BENCH_DELEGATE_SOURCE="dynamic"
    if [ -n "$TFLITE_BENCH_DELEGATE_OVERRIDE" ]; then
        TFLITE_BENCH_DELEGATE_SOURCE="environment"
    fi

    TFLITE_BENCH_DELEGATE_OPTIONS="${TFLITE_DELEGATE_OPTIONS:-}"
    TFLITE_BENCH_DELEGATE_OPTIONS_SOURCE="profile-default"
    if [ -n "$TFLITE_BENCH_DELEGATE_OPTIONS" ]; then
        TFLITE_BENCH_DELEGATE_OPTIONS_SOURCE="environment"
    fi

    TFLITE_BENCH_THREADS=1
    TFLITE_BENCH_BACKEND="cpu"
    TFLITE_BENCH_SUPPORTED_CONFIGURATIONS="config1,config2"
    TFLITE_BENCH_AI_HUB_MODEL_ID="inception_v3"
    TFLITE_BENCH_AI_HUB_PRECISION="w8a8"
    case "$TFLITE_BENCH_PROFILE" in
        cpu)
            TFLITE_BENCH_THREADS=3
            ;;
        gpu)
            TFLITE_BENCH_BACKEND="gpu"
            TFLITE_BENCH_SUPPORTED_CONFIGURATIONS="config2"
            ;;
        qnn-htp)
            TFLITE_BENCH_BACKEND="qnn-htp"
            TFLITE_BENCH_SUPPORTED_CONFIGURATIONS="config2"
            TFLITE_BENCH_AI_HUB_MODEL_ID=""
            TFLITE_BENCH_AI_HUB_PRECISION=""
            if [ -z "$TFLITE_BENCH_DELEGATE_OPTIONS" ]; then
                TFLITE_BENCH_DELEGATE_OPTIONS="backend_type:htp;"
            fi
            ;;
        *)
            return 2
            ;;
    esac
}

# tflite_benchmark_usage
# Prints the common CLI contract for the already selected fixed profile.
tflite_benchmark_usage() {
    if [ -n "$TFLITE_BENCH_AI_HUB_MODEL_ID" ]; then
        tflite_model_guidance="Use --model for a provisioned graph. Desktop distributions may explicitly use --fetch-model."
    else
        tflite_model_guidance="This profile requires a provisioned graph supplied with --model or TFLITE_MODEL."
    fi
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --benchmark PATH_OR_NAME" \
        "  --model PATH" \
        "  --fetch-model                 Desktop only, fetch an official AI Hub model" \
        "  --no-fetch-model              Disable an environment-requested fetch" \
        "  --ai-hub-version VERSION      Default: 0.63.0" \
        "  --fetch-timeout SECONDS       Default: 300" \
        "  --configuration MODE         auto, config1/base, or config2/overlay" \
        "  --config1, --base             Require Config 1/base policy" \
        "  --config2, --overlay          Require Config 2/overlay policy" \
        "  --auto                        Detect from the installed QNN runtime" \
        "  --delegate PATH_OR_NAME       QNN HTP profile only" \
        "  --delegate-options OPTIONS    QNN HTP profile only" \
        "  --timeout SECONDS" \
        "  -h, --help" \
        "Fixed profile: $TFLITE_BENCH_PROFILE" \
        "$tflite_model_guidance"
}

# tflite_benchmark_parse_args <suite-arguments...>
# Applies CLI overrides to benchmark globals and returns 2 on invalid syntax.
tflite_benchmark_parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --benchmark)
                [ "$#" -ge 2 ] || return 2
                TFLITE_BENCH_BINARY_OVERRIDE="$2"
                if [ -n "$TFLITE_BENCH_BINARY_OVERRIDE" ]; then
                    TFLITE_BENCH_BINARY_SOURCE="cli"
                else
                    TFLITE_BENCH_BINARY_SOURCE="dynamic"
                fi
                shift 2
                ;;
            --model)
                [ "$#" -ge 2 ] || return 2
                TFLITE_BENCH_MODEL_OVERRIDE="$2"
                if [ -n "$TFLITE_BENCH_MODEL_OVERRIDE" ]; then
                    TFLITE_BENCH_MODEL_SOURCE="cli"
                else
                    TFLITE_BENCH_MODEL_SOURCE="unset"
                fi
                shift 2
                ;;
            --fetch-model)
                TFLITE_BENCH_FETCH_MODEL=1
                TFLITE_BENCH_FETCH_MODEL_SOURCE="cli"
                shift
                ;;
            --no-fetch-model)
                TFLITE_BENCH_FETCH_MODEL=0
                TFLITE_BENCH_FETCH_MODEL_SOURCE="cli"
                shift
                ;;
            --ai-hub-version)
                [ "$#" -ge 2 ] || return 2
                TFLITE_BENCH_AI_HUB_VERSION="${2#v}"
                TFLITE_BENCH_AI_HUB_VERSION_SOURCE="cli"
                shift 2
                ;;
            --fetch-timeout)
                [ "$#" -ge 2 ] || return 2
                TFLITE_BENCH_FETCH_TIMEOUT="$2"
                TFLITE_BENCH_FETCH_TIMEOUT_SOURCE="cli"
                shift 2
                ;;
            --configuration)
                [ "$#" -ge 2 ] || return 2
                TFLITE_BENCH_CONFIGURATION_REQUEST="$2"
                TFLITE_BENCH_CONFIGURATION_SOURCE="cli"
                shift 2
                ;;
            --config1|--base)
                TFLITE_BENCH_CONFIGURATION_REQUEST="config1"
                TFLITE_BENCH_CONFIGURATION_SOURCE="cli"
                shift
                ;;
            --config2|--overlay)
                TFLITE_BENCH_CONFIGURATION_REQUEST="config2"
                TFLITE_BENCH_CONFIGURATION_SOURCE="cli"
                shift
                ;;
            --auto)
                TFLITE_BENCH_CONFIGURATION_REQUEST="auto"
                TFLITE_BENCH_CONFIGURATION_SOURCE="cli"
                shift
                ;;
            --delegate)
                [ "$#" -ge 2 ] || return 2
                TFLITE_BENCH_DELEGATE_OVERRIDE="$2"
                if [ -n "$TFLITE_BENCH_DELEGATE_OVERRIDE" ]; then
                    TFLITE_BENCH_DELEGATE_SOURCE="cli"
                else
                    TFLITE_BENCH_DELEGATE_SOURCE="dynamic"
                fi
                shift 2
                ;;
            --delegate-options)
                [ "$#" -ge 2 ] || return 2
                TFLITE_BENCH_DELEGATE_OPTIONS="$2"
                if [ -n "$TFLITE_BENCH_DELEGATE_OPTIONS" ]; then
                    TFLITE_BENCH_DELEGATE_OPTIONS_SOURCE="cli"
                else
                    TFLITE_BENCH_DELEGATE_OPTIONS_SOURCE="profile-default"
                fi
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                TFLITE_BENCH_TIMEOUT="$2"
                TFLITE_BENCH_TIMEOUT_SOURCE="cli"
                shift 2
                ;;
            -h|--help)
                tflite_benchmark_usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                return 2
                ;;
        esac
    done
}

# tflite_benchmark_normalize_configuration
# Normalizes the public configuration selection into auto, config1, or config2.
tflite_benchmark_normalize_configuration() {
    case "$TFLITE_BENCH_CONFIGURATION_REQUEST" in
        auto)
            ;;
        config1|base)
            TFLITE_BENCH_CONFIGURATION_REQUEST="config1"
            ;;
        config2|overlay)
            TFLITE_BENCH_CONFIGURATION_REQUEST="config2"
            ;;
        *)
            return 1
            ;;
    esac
}

# tflite_benchmark_resolve_binary
# Resolves the benchmark override or a known executable into TFLITE_BENCH_BINARY.
tflite_benchmark_resolve_binary() {
    TFLITE_BENCH_BINARY=""

    if [ -n "$TFLITE_BENCH_BINARY_OVERRIDE" ]; then
        case "$TFLITE_BENCH_BINARY_OVERRIDE" in
            */*)
                if [ -x "$TFLITE_BENCH_BINARY_OVERRIDE" ]; then
                    TFLITE_BENCH_BINARY="$TFLITE_BENCH_BINARY_OVERRIDE"
                    return 0
                fi
                return 1
                ;;
        esac
        if command -v "$TFLITE_BENCH_BINARY_OVERRIDE" >/dev/null 2>&1; then
            TFLITE_BENCH_BINARY=$(command -v "$TFLITE_BENCH_BINARY_OVERRIDE")
            return 0
        fi
        return 1
    fi

    for tflite_binary_name in \
        benchmark_model \
        benchmark_model_plus_flex \
        tensorflow-lite-benchmark \
        tflite_benchmark; do
        if command -v "$tflite_binary_name" >/dev/null 2>&1; then
            TFLITE_BENCH_BINARY=$(command -v "$tflite_binary_name")
            return 0
        fi
    done
    return 1
}

# tflite_benchmark_desktop_model_fetch_supported
# Returns success only for desktop distributions approved for AI Hub fetching.
tflite_benchmark_desktop_model_fetch_supported() {
    case "$TFLITE_BENCH_OS_ID" in
        debian|ubuntu|centos|rhel|fedora|rocky|almalinux)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# tflite_benchmark_select_fetched_model <asset-directory>
# Selects exactly one extracted TFLite graph without printing diagnostic text.
tflite_benchmark_select_fetched_model() {
    tflite_asset_dir="$1"
    tflite_unsorted_models="$TFLITE_BENCH_RESULT_DIR/ai-hub-models.unsorted"
    tflite_sorted_models="$TFLITE_BENCH_RESULT_DIR/ai-hub-models.list"

    if ! find "$tflite_asset_dir" \
        -type f \
        -name '*.tflite' \
        -print >"$tflite_unsorted_models" 2>/dev/null; then
        return 1
    fi
    if ! LC_ALL=C sort "$tflite_unsorted_models" >"$tflite_sorted_models"; then
        return 1
    fi
    tflite_model_count=$(wc -l <"$tflite_sorted_models" | tr -d '[:space:]')
    [ "$tflite_model_count" = "1" ] || return 1

    TFLITE_BENCH_MODEL=$(sed -n '1p' "$tflite_sorted_models")
    [ -r "$TFLITE_BENCH_MODEL" ] && [ -f "$TFLITE_BENCH_MODEL" ]
}

# tflite_benchmark_fetch_model
# Fetches an official tagged Inception TFLite asset on supported desktop OSes.
# Returns 3 for unsupported OS/profile, 4 for missing download tools, 5 for a
# failed fetch, and 6 for missing or ambiguous extracted model contents.
tflite_benchmark_fetch_model() {
    if ! tflite_benchmark_desktop_model_fetch_supported; then
        return 3
    fi
    [ -n "$TFLITE_BENCH_AI_HUB_MODEL_ID" ] || return 3

    tflite_fetch_dir="$TFLITE_BENCH_RESULT_DIR/ai-hub-model"
    TFLITE_BENCH_FETCH_LOG="$TFLITE_BENCH_RESULT_DIR/ai-hub-fetch.log"
    TFLITE_BENCH_FETCH_ARCHIVE="$tflite_fetch_dir/$TFLITE_BENCH_AI_HUB_MODEL_ID-tflite-$TFLITE_BENCH_AI_HUB_PRECISION.zip"
    if ! mkdir -p "$tflite_fetch_dir"; then
        return 5
    fi

    tflite_fetch_rc=127
    if command -v qai-hub-models >/dev/null 2>&1; then
        run_with_timeout_log \
            "$TFLITE_BENCH_FETCH_TIMEOUT" \
            "$TFLITE_BENCH_FETCH_LOG" \
            "$(command -v qai-hub-models)" fetch \
                "$TFLITE_BENCH_AI_HUB_MODEL_ID" \
                --runtime tflite \
                --precision "$TFLITE_BENCH_AI_HUB_PRECISION" \
                --version "$TFLITE_BENCH_AI_HUB_VERSION" \
                --output-dir "$tflite_fetch_dir" \
                --extract \
                --quiet
        tflite_fetch_rc=$?
    elif command -v unzip >/dev/null 2>&1 &&
         command -v curl >/dev/null 2>&1; then
        TFLITE_BENCH_FETCH_URL="https://qaihub-public-assets.s3.us-west-2.amazonaws.com/qai-hub-models/models/$TFLITE_BENCH_AI_HUB_MODEL_ID/releases/v$TFLITE_BENCH_AI_HUB_VERSION/$TFLITE_BENCH_AI_HUB_MODEL_ID-tflite-$TFLITE_BENCH_AI_HUB_PRECISION.zip"
        run_with_timeout_log \
            "$TFLITE_BENCH_FETCH_TIMEOUT" \
            "$TFLITE_BENCH_FETCH_LOG" \
            "$(command -v curl)" \
                --fail \
                --location \
                --silent \
                --show-error \
                --output "$TFLITE_BENCH_FETCH_ARCHIVE" \
                "$TFLITE_BENCH_FETCH_URL"
        tflite_fetch_rc=$?
        if [ "$tflite_fetch_rc" -eq 0 ]; then
            run_with_timeout_log \
                "$TFLITE_BENCH_FETCH_TIMEOUT" \
                "$TFLITE_BENCH_RESULT_DIR/ai-hub-extract.log" \
                "$(command -v unzip)" \
                    -q \
                    -o \
                    "$TFLITE_BENCH_FETCH_ARCHIVE" \
                    -d "$tflite_fetch_dir"
            tflite_fetch_rc=$?
        fi
    elif command -v unzip >/dev/null 2>&1 &&
         command -v wget >/dev/null 2>&1; then
        TFLITE_BENCH_FETCH_URL="https://qaihub-public-assets.s3.us-west-2.amazonaws.com/qai-hub-models/models/$TFLITE_BENCH_AI_HUB_MODEL_ID/releases/v$TFLITE_BENCH_AI_HUB_VERSION/$TFLITE_BENCH_AI_HUB_MODEL_ID-tflite-$TFLITE_BENCH_AI_HUB_PRECISION.zip"
        run_with_timeout_log \
            "$TFLITE_BENCH_FETCH_TIMEOUT" \
            "$TFLITE_BENCH_FETCH_LOG" \
            "$(command -v wget)" \
                -O "$TFLITE_BENCH_FETCH_ARCHIVE" \
                "$TFLITE_BENCH_FETCH_URL"
        tflite_fetch_rc=$?
        if [ "$tflite_fetch_rc" -eq 0 ]; then
            run_with_timeout_log \
                "$TFLITE_BENCH_FETCH_TIMEOUT" \
                "$TFLITE_BENCH_RESULT_DIR/ai-hub-extract.log" \
                "$(command -v unzip)" \
                    -q \
                    -o \
                    "$TFLITE_BENCH_FETCH_ARCHIVE" \
                    -d "$tflite_fetch_dir"
            tflite_fetch_rc=$?
        fi
    else
        return 4
    fi

    log_file_with_label "AI-HUB-FETCH" "$TFLITE_BENCH_FETCH_LOG" 40
    [ "$tflite_fetch_rc" -eq 0 ] || return 5
    if ! tflite_benchmark_select_fetched_model "$tflite_fetch_dir"; then
        return 6
    fi
    TFLITE_BENCH_MODEL_SOURCE="ai-hub-models-v$TFLITE_BENCH_AI_HUB_VERSION"
    return 0
}

# tflite_benchmark_resolve_model
# Validates a provisioned path or performs an explicitly requested model fetch.
tflite_benchmark_resolve_model() {
    TFLITE_BENCH_MODEL=""

    if [ -n "$TFLITE_BENCH_MODEL_OVERRIDE" ]; then
        if [ -r "$TFLITE_BENCH_MODEL_OVERRIDE" ] &&
           [ -f "$TFLITE_BENCH_MODEL_OVERRIDE" ]; then
            TFLITE_BENCH_MODEL="$TFLITE_BENCH_MODEL_OVERRIDE"
            return 0
        fi
        return 1
    fi
    [ "$TFLITE_BENCH_FETCH_MODEL" = "1" ] || return 2
    tflite_benchmark_fetch_model
}

# tflite_benchmark_resolve_library <override> <soname>
# Resolves one image library into TFLITE_BENCH_LIBRARY and returns 0 or 1.
tflite_benchmark_resolve_library() {
    tflite_library_override="$1"
    tflite_library_name="$2"
    TFLITE_BENCH_LIBRARY=""

    if [ -n "$tflite_library_override" ]; then
        case "$tflite_library_override" in
            */*)
                if [ -r "$tflite_library_override" ] &&
                   [ -f "$tflite_library_override" ]; then
                    TFLITE_BENCH_LIBRARY="$tflite_library_override"
                    return 0
                fi
                return 1
                ;;
        esac
        tflite_library_name="$tflite_library_override"
    fi

    if command -v ldconfig >/dev/null 2>&1; then
        TFLITE_BENCH_LIBRARY=$(
            ldconfig -p 2>/dev/null |
                awk -v wanted="$tflite_library_name" \
                    '$1 == wanted { print $NF; exit }'
        )
        if [ -r "$TFLITE_BENCH_LIBRARY" ] &&
           [ -f "$TFLITE_BENCH_LIBRARY" ]; then
            return 0
        fi
        TFLITE_BENCH_LIBRARY=""
    fi

    tflite_machine=$(uname -m 2>/dev/null || printf '%s' unknown)
    case "$tflite_machine" in
        aarch64|arm64)
            tflite_multiarch_dir=/usr/lib/aarch64-linux-gnu
            ;;
        x86_64|amd64)
            tflite_multiarch_dir=/usr/lib/x86_64-linux-gnu
            ;;
        *)
            tflite_multiarch_dir=""
            ;;
    esac

    for tflite_library_root in \
        /usr/lib \
        /usr/lib64 \
        /usr/local/lib \
        /usr/local/lib64 \
        /lib \
        /lib64 \
        /opt/qcom/lib \
        "$tflite_multiarch_dir"; do
        [ -n "$tflite_library_root" ] || continue
        if [ -r "$tflite_library_root/$tflite_library_name" ] &&
           [ -f "$tflite_library_root/$tflite_library_name" ]; then
            TFLITE_BENCH_LIBRARY="$tflite_library_root/$tflite_library_name"
            return 0
        fi
    done
    return 1
}

# tflite_benchmark_detect_configuration
# Selects Config 1/base or Config 2/overlay without modifying target state.
# Auto mode identifies Config 2 from the installed QNN TFLite delegate and HTP
# backend runtime. Explicit modes allow CI and operators to assert image policy.
tflite_benchmark_detect_configuration() {
    TFLITE_BENCH_DETECTED_CONFIGURATION="config1"
    TFLITE_BENCH_DETECTED_CONFIGURATION_SOURCE="qnn-runtime-absent"
    TFLITE_BENCH_CONFIG_QNN_DELEGATE="not-found"
    TFLITE_BENCH_CONFIG_QNN_BACKEND="not-found"

    if tflite_benchmark_resolve_library "" libQnnTFLiteDelegate.so; then
        TFLITE_BENCH_CONFIG_QNN_DELEGATE="$TFLITE_BENCH_LIBRARY"
    fi
    if tflite_benchmark_resolve_library "" libQnnHtp.so; then
        TFLITE_BENCH_CONFIG_QNN_BACKEND="$TFLITE_BENCH_LIBRARY"
    fi
    if [ "$TFLITE_BENCH_CONFIG_QNN_DELEGATE" != "not-found" ] &&
       [ "$TFLITE_BENCH_CONFIG_QNN_BACKEND" != "not-found" ]; then
        TFLITE_BENCH_DETECTED_CONFIGURATION="config2"
        TFLITE_BENCH_DETECTED_CONFIGURATION_SOURCE="qnn-delegate-and-htp-runtime"
    fi

    case "$TFLITE_BENCH_CONFIGURATION_REQUEST" in
        config1|config2)
            TFLITE_BENCH_ACTIVE_CONFIGURATION="$TFLITE_BENCH_CONFIGURATION_REQUEST"
            TFLITE_BENCH_ACTIVE_CONFIGURATION_SOURCE="$TFLITE_BENCH_CONFIGURATION_SOURCE"
            ;;
        auto)
            TFLITE_BENCH_ACTIVE_CONFIGURATION="$TFLITE_BENCH_DETECTED_CONFIGURATION"
            TFLITE_BENCH_ACTIVE_CONFIGURATION_SOURCE="$TFLITE_BENCH_DETECTED_CONFIGURATION_SOURCE"
            ;;
    esac
}

# tflite_benchmark_configuration_supported
# Returns success when the current fixed profile supports the active config.
tflite_benchmark_configuration_supported() {
    if [ "$TFLITE_BENCH_PROFILE" = "cpu" ]; then
        return 0
    fi
    [ "$TFLITE_BENCH_ACTIVE_CONFIGURATION" = "config2" ]
}

# tflite_benchmark_log_package <package-name>
# Logs an installed DEB or RPM version without modifying package state.
tflite_benchmark_log_package() {
    tflite_package_name="$1"

    if command -v dpkg-query >/dev/null 2>&1; then
        tflite_package_version=$(
            dpkg-query -W -f='${Status} ${Version}\n' \
                "$tflite_package_name" 2>/dev/null |
                awk '$1 == "install" && $3 == "installed" { print $4; exit }'
        )
        if [ -n "$tflite_package_version" ]; then
            log_info "[TFLITE-PACKAGE] name=$tflite_package_name provider=dpkg status=installed version=$tflite_package_version"
            return 0
        fi
    fi

    if command -v rpm >/dev/null 2>&1; then
        tflite_package_version=$(
            rpm -q --qf '%{VERSION}-%{RELEASE}\n' \
                "$tflite_package_name" 2>/dev/null |
                head -n 1
        )
        if [ -n "$tflite_package_version" ]; then
            log_info "[TFLITE-PACKAGE] name=$tflite_package_name provider=rpm status=installed version=$tflite_package_version"
            return 0
        fi
    fi

    log_info "[TFLITE-PACKAGE] name=$tflite_package_name status=not-detected"
    return 1
}

# tflite_benchmark_log_inventory
# Logs mapped installed package versions without modifying package state.
tflite_benchmark_log_inventory() {
    tflite_package_set="ai-ml-tflite"
    if [ "$TFLITE_BENCH_PROFILE" = "qnn-htp" ]; then
        tflite_package_set="ai-ml-qnn"
    fi

    tflite_mapped_packages=$(pkg_lookup_package_set "$tflite_package_set" || true)
    if [ -z "$tflite_mapped_packages" ]; then
        log_info "[TFLITE-PACKAGE] os=$TFLITE_BENCH_OS_ID set=$tflite_package_set mapping=not-defined package_install=disabled"
        return 0
    fi

    log_info "[TFLITE-PACKAGE] os=$TFLITE_BENCH_OS_ID set=$tflite_package_set mapped_packages=$tflite_mapped_packages package_install=disabled"
    for tflite_mapped_package in $tflite_mapped_packages; do
        tflite_benchmark_log_package "$tflite_mapped_package" || true
    done
}

# tflite_benchmark_supports <flag-name>
# Returns success when retained benchmark help documents the requested flag.
tflite_benchmark_supports() {
    grep -q -- "--$1" "$TFLITE_BENCH_HELP_LOG" 2>/dev/null
}

# tflite_benchmark_parse_summary_count <benchmark-log>
# Prints the measured-run count associated with the inference summary.
tflite_benchmark_parse_summary_count() {
    awk '
        /count=[0-9]+/ && /avg=[0-9]/ && $0 !~ /Timings \(microseconds\)/ {
            for (field = 1; field <= NF; field++) {
                if ($field ~ /^count=[0-9]+$/) {
                    count = $field
                    sub(/^count=/, "", count)
                }
            }
        }
        /Inference timings in us:/ && count != "" {
            print count
        }
    ' "$1" 2>/dev/null | tail -n 1
}

# tflite_benchmark_parse_summary_average <benchmark-log>
# Prints the benchmark's end-to-end Inference (avg) value in microseconds.
tflite_benchmark_parse_summary_average() {
    awk '
        /Inference timings in us:/ {
            for (field = 1; field < NF; field++) {
                if ($field == "Inference" && $(field + 1) == "(avg):") {
                    average = $(field + 2)
                    gsub(/,/, "", average)
                    print average
                }
            }
        }
    ' "$1" 2>/dev/null | tail -n 1
}

# tflite_benchmark_parse_legacy_timing <count|average> <benchmark-log>
# Supports benchmark builds that emit only a Timings (microseconds) summary.
tflite_benchmark_parse_legacy_timing() {
    tflite_legacy_field="$1"
    tflite_legacy_log="$2"

    grep 'Timings (microseconds): count=' "$tflite_legacy_log" 2>/dev/null |
        awk -v wanted="$tflite_legacy_field" '
            {
                for (field = 1; field <= NF; field++) {
                    if ($field ~ ("^" wanted "=[0-9]+([.][0-9]+)?$")) {
                        sub("^" wanted "=", "", $field)
                        value = $field
                    }
                }
            }
            END {
                if (value != "") {
                    print value
                }
            }
        '
}

# tflite_benchmark_validate_accelerator
# Confirms that GPU or HTP execution did not fall back to the CPU.
tflite_benchmark_validate_accelerator() {
    TFLITE_BENCH_DELEGATION="cpu"
    TFLITE_BENCH_ACCELERATOR_OPERATIONS="not-applicable"
    TFLITE_BENCH_CPU_FALLBACK_OPERATIONS="0"

    case "$TFLITE_BENCH_PROFILE" in
        cpu)
            return 0
            ;;
        gpu)
            if ! grep -q 'GPU delegate created' "$TFLITE_BENCH_RUN_LOG" 2>/dev/null; then
                return 10
            fi

            tflite_gpu_partition_line=$(
                grep 'operations will run on the GPU, and the remaining .* operations will run on the CPU' \
                    "$TFLITE_BENCH_RUN_LOG" 2>/dev/null |
                    tail -n 1
            )
            if [ -n "$tflite_gpu_partition_line" ]; then
                TFLITE_BENCH_ACCELERATOR_OPERATIONS=$(
                    printf '%s\n' "$tflite_gpu_partition_line" |
                        awk '
                            {
                                for (field = 1; field < NF; field++) {
                                    if ($(field + 1) == "operations" &&
                                       $(field + 2) == "will" &&
                                       $(field + 3) == "run" &&
                                       $(field + 4) == "on" &&
                                       $(field + 5) == "the" &&
                                       $(field + 6) == "GPU,") {
                                        print $field
                                        exit
                                    }
                                }
                            }
                        '
                )
                TFLITE_BENCH_CPU_FALLBACK_OPERATIONS=$(
                    printf '%s\n' "$tflite_gpu_partition_line" |
                        awk '
                            {
                                for (field = 1; field < NF; field++) {
                                    if ($field == "remaining" &&
                                       $(field + 1) ~ /^[0-9]+$/) {
                                        print $(field + 1)
                                        exit
                                    }
                                }
                            }
                        '
                )
            fi

            case "$TFLITE_BENCH_CPU_FALLBACK_OPERATIONS" in
                ''|*[!0-9]*)
                    return 11
                    ;;
            esac
            if [ "$TFLITE_BENCH_CPU_FALLBACK_OPERATIONS" -ne 0 ]; then
                return 12
            fi
            if ! grep -q 'model graph will be completely executed by the delegate' \
                "$TFLITE_BENCH_RUN_LOG" 2>/dev/null; then
                return 11
            fi
            TFLITE_BENCH_DELEGATION="gpu-complete"
            return 0
            ;;
        qnn-htp)
            if ! grep -q 'EXTERNAL delegate created' \
                "$TFLITE_BENCH_RUN_LOG" 2>/dev/null; then
                return 20
            fi
            if ! grep -q 'model graph will be completely executed by the delegate' \
                "$TFLITE_BENCH_RUN_LOG" 2>/dev/null; then
                return 21
            fi
            if ! grep -q 'TfLiteQnnDelegate' \
                "$TFLITE_BENCH_RUN_LOG" 2>/dev/null; then
                return 22
            fi
            TFLITE_BENCH_DELEGATION="qnn-htp-complete"
            return 0
            ;;
    esac

    return 30
}

# tflite_benchmark_run_command
# Executes the fixed profile command with 100 runs and operator profiling.
tflite_benchmark_run_command() {
    case "$TFLITE_BENCH_PROFILE" in
        cpu)
            run_with_timeout_log \
                "$TFLITE_BENCH_TIMEOUT" \
                "$TFLITE_BENCH_RUN_LOG" \
                "$TFLITE_BENCH_BINARY" \
                    "--graph=$TFLITE_BENCH_MODEL" \
                    --enable_op_profiling=true \
                    --num_runs=100 \
                    --num_threads=3
            ;;
        gpu)
            run_with_timeout_log \
                "$TFLITE_BENCH_TIMEOUT" \
                "$TFLITE_BENCH_RUN_LOG" \
                "$TFLITE_BENCH_BINARY" \
                    "--graph=$TFLITE_BENCH_MODEL" \
                    --use_gpu=true \
                    --enable_op_profiling=true \
                    --num_runs=100 \
                    --num_threads=1
            ;;
        qnn-htp)
            run_with_timeout_log \
                "$TFLITE_BENCH_TIMEOUT" \
                "$TFLITE_BENCH_RUN_LOG" \
                "$TFLITE_BENCH_BINARY" \
                    "--graph=$TFLITE_BENCH_MODEL" \
                    "--external_delegate_path=$TFLITE_BENCH_DELEGATE_LIBRARY" \
                    "--external_delegate_options=$TFLITE_BENCH_DELEGATE_OPTIONS" \
                    --enable_op_profiling=true \
                    --num_runs=100 \
                    --num_threads=1
            ;;
    esac
}

# tflite_benchmark_execute <test-name> <result-file> <suite-directory>
# Resolves image tools and a user-provisioned model, runs the selected
# benchmark, validates timing and profiling evidence, records the final result,
# and exits through shared result orchestration.
tflite_benchmark_execute() {
    tflite_test_name="$1"
    tflite_result_file="$2"
    tflite_suite_dir="$3"
    TFLITE_BENCH_RESULT_DIR="$tflite_suite_dir/results/$tflite_test_name/run-$(date '+%Y%m%d-%H%M%S')-$$"
    TFLITE_BENCH_RUN_LOG="$TFLITE_BENCH_RESULT_DIR/benchmark.log"
    TFLITE_BENCH_HELP_LOG="$TFLITE_BENCH_RESULT_DIR/benchmark-help.log"

    test_result_init "$tflite_test_name" "$tflite_result_file" || exit 1
    if ! mkdir -p "$TFLITE_BENCH_RESULT_DIR"; then
        test_result_finish \
            "FAIL" \
            "$tflite_test_name FAIL: cannot create evidence directory $TFLITE_BENCH_RESULT_DIR"
    fi

    log_info "--------------------------------------------------------------------------"
    log_info "Starting $tflite_test_name"
    log_info "Evidence directory: $TFLITE_BENCH_RESULT_DIR"
    log_info "[TFLITE-POLICY] os=$TFLITE_BENCH_OS_ID requested_configuration=$TFLITE_BENCH_CONFIGURATION_REQUEST configuration_source=$TFLITE_BENCH_CONFIGURATION_SOURCE supported_configurations=$TFLITE_BENCH_SUPPORTED_CONFIGURATIONS profile=$TFLITE_BENCH_PROFILE backend=$TFLITE_BENCH_BACKEND threads=$TFLITE_BENCH_THREADS runs=100 op_profiling=enabled timeout=${TFLITE_BENCH_TIMEOUT}s timeout_source=$TFLITE_BENCH_TIMEOUT_SOURCE benchmark=${TFLITE_BENCH_BINARY_OVERRIDE:-auto} benchmark_source=$TFLITE_BENCH_BINARY_SOURCE model=${TFLITE_BENCH_MODEL_OVERRIDE:-unset} model_source=$TFLITE_BENCH_MODEL_SOURCE fetch_model=$TFLITE_BENCH_FETCH_MODEL fetch_source=$TFLITE_BENCH_FETCH_MODEL_SOURCE ai_hub_version=$TFLITE_BENCH_AI_HUB_VERSION ai_hub_version_source=$TFLITE_BENCH_AI_HUB_VERSION_SOURCE fetch_timeout=${TFLITE_BENCH_FETCH_TIMEOUT}s fetch_timeout_source=$TFLITE_BENCH_FETCH_TIMEOUT_SOURCE package_install=disabled"

    case "$TFLITE_BENCH_TIMEOUT" in
        ''|*[!0-9]*|0)
            test_result_record "FAIL" "TFLite benchmark timeout must be a positive integer"
            test_result_finish
            ;;
    esac
    if [ "$TFLITE_BENCH_TIMEOUT" -gt "$TFLITE_BENCH_TIMEOUT_MAX" ]; then
        test_result_record "FAIL" "TFLite benchmark timeout must not exceed ${TFLITE_BENCH_TIMEOUT_MAX}s"
        test_result_finish
    fi
    case "$TFLITE_BENCH_FETCH_MODEL" in
        0|1)
            ;;
        *)
            test_result_record "FAIL" "TFLITE_FETCH_MODEL must be 0 or 1"
            test_result_finish
            ;;
    esac
    case "$TFLITE_BENCH_FETCH_TIMEOUT" in
        ''|*[!0-9]*|0)
            test_result_record "FAIL" "AI Hub model fetch timeout must be a positive integer"
            test_result_finish
            ;;
    esac
    if [ "$TFLITE_BENCH_FETCH_TIMEOUT" -gt 900 ]; then
        test_result_record "FAIL" "AI Hub model fetch timeout must not exceed 900s"
        test_result_finish
    fi
    if [ -z "$TFLITE_BENCH_AI_HUB_VERSION" ]; then
        test_result_record "FAIL" "AI Hub Models version must not be empty"
        test_result_finish
    fi
    if ! tflite_benchmark_normalize_configuration; then
        test_result_record "FAIL" "Unsupported TFLite configuration selection, value=$TFLITE_BENCH_CONFIGURATION_REQUEST expected=auto,config1,config2"
        test_result_finish
    fi

    tflite_benchmark_log_inventory
    tflite_benchmark_detect_configuration
    log_info "[TFLITE-CONFIGURATION] requested=$TFLITE_BENCH_CONFIGURATION_REQUEST active=$TFLITE_BENCH_ACTIVE_CONFIGURATION active_source=$TFLITE_BENCH_ACTIVE_CONFIGURATION_SOURCE detected=$TFLITE_BENCH_DETECTED_CONFIGURATION detected_source=$TFLITE_BENCH_DETECTED_CONFIGURATION_SOURCE qnn_delegate=$TFLITE_BENCH_CONFIG_QNN_DELEGATE qnn_backend=$TFLITE_BENCH_CONFIG_QNN_BACKEND"
    if [ "$TFLITE_BENCH_CONFIGURATION_REQUEST" != "auto" ] &&
       [ "$TFLITE_BENCH_CONFIGURATION_REQUEST" != "$TFLITE_BENCH_DETECTED_CONFIGURATION" ]; then
        test_result_record "SKIP" "Requested TFLite configuration is unavailable on this image, requested=$TFLITE_BENCH_CONFIGURATION_REQUEST detected=$TFLITE_BENCH_DETECTED_CONFIGURATION detected_source=$TFLITE_BENCH_DETECTED_CONFIGURATION_SOURCE"
        test_result_finish
    fi
    if ! tflite_benchmark_configuration_supported; then
        test_result_record "SKIP" "TFLite profile is unsupported on the active configuration, profile=$TFLITE_BENCH_PROFILE active_configuration=$TFLITE_BENCH_ACTIVE_CONFIGURATION supported_configurations=$TFLITE_BENCH_SUPPORTED_CONFIGURATIONS"
        test_result_finish
    fi

    tflite_benchmark_resolve_model
    tflite_model_rc=$?
    case "$tflite_model_rc" in
        0)
            ;;
        1)
            test_result_record "FAIL" "Provisioned TFLite model is unavailable, path=$TFLITE_BENCH_MODEL_OVERRIDE source=$TFLITE_BENCH_MODEL_SOURCE"
            test_result_finish
            ;;
        2)
            if [ -n "$TFLITE_BENCH_AI_HUB_MODEL_ID" ]; then
                test_result_record "SKIP" "TFLite model path was not supplied, provision the model and use --model or TFLITE_MODEL, or explicitly request desktop retrieval with --fetch-model"
            else
                test_result_record "SKIP" "TFLite model path was not supplied, provision the model and use --model or TFLITE_MODEL"
            fi
            test_result_finish
            ;;
        3)
            if [ "$TFLITE_BENCH_PROFILE" = "qnn-htp" ]; then
                test_result_record "FAIL" "AI Hub Models does not publish a fetchable YOLOv8 asset because of upstream licensing, side-load the graph and use --model"
            else
                test_result_record "FAIL" "AI Hub model fetching is supported only on Debian, Ubuntu, CentOS, RHEL, Fedora, Rocky Linux, and AlmaLinux, os=$TFLITE_BENCH_OS_ID"
            fi
            test_result_finish
            ;;
        4)
            test_result_record "FAIL" "AI Hub model fetch was requested but neither qai-hub-models nor curl or wget with unzip is available"
            test_result_finish
            ;;
        5)
            test_result_record "FAIL" "AI Hub model fetch failed or timed out, version=$TFLITE_BENCH_AI_HUB_VERSION artifact=$TFLITE_BENCH_FETCH_LOG"
            test_result_finish
            ;;
        *)
            test_result_record "FAIL" "AI Hub model archive did not contain exactly one readable TFLite graph, artifact=$TFLITE_BENCH_RESULT_DIR/ai-hub-models.list"
            test_result_finish
            ;;
    esac

    if ! tflite_benchmark_resolve_binary; then
        if [ -n "$TFLITE_BENCH_BINARY_OVERRIDE" ]; then
            test_result_record "FAIL" "Explicit TFLite benchmark executable is unavailable, value=$TFLITE_BENCH_BINARY_OVERRIDE source=$TFLITE_BENCH_BINARY_SOURCE"
        else
            test_result_record "SKIP" "Image-provided TFLite benchmark executable was not found, expected package=tensorflow-lite-qcom-apps"
        fi
        test_result_finish
    fi

    TFLITE_BENCH_DELEGATE_LIBRARY="none"
    TFLITE_BENCH_BACKEND_LIBRARY="none"
    if [ "$TFLITE_BENCH_PROFILE" = "qnn-htp" ]; then
        if ! tflite_benchmark_resolve_library \
            "$TFLITE_BENCH_DELEGATE_OVERRIDE" \
            libQnnTFLiteDelegate.so; then
            if [ -n "$TFLITE_BENCH_DELEGATE_OVERRIDE" ]; then
                test_result_record "FAIL" "Explicit QNN TFLite delegate library is unavailable, value=$TFLITE_BENCH_DELEGATE_OVERRIDE source=$TFLITE_BENCH_DELEGATE_SOURCE"
            else
                test_result_record "SKIP" "QNN TFLite delegate is not installed, required=libQnnTFLiteDelegate.so"
            fi
            test_result_finish
        fi
        TFLITE_BENCH_DELEGATE_LIBRARY="$TFLITE_BENCH_LIBRARY"

        if ! tflite_benchmark_resolve_library "" libQnnHtp.so; then
            test_result_record "FAIL" "QNN TFLite delegate is installed but the HTP backend library is missing, required=libQnnHtp.so"
            test_result_finish
        fi
        TFLITE_BENCH_BACKEND_LIBRARY="$TFLITE_BENCH_LIBRARY"
    fi

    "$TFLITE_BENCH_BINARY" --help >"$TFLITE_BENCH_HELP_LOG" 2>&1 || true
    case "$TFLITE_BENCH_PROFILE" in
        gpu)
            if ! tflite_benchmark_supports use_gpu; then
                test_result_record "SKIP" "Installed TFLite benchmark does not expose --use_gpu, executable=$TFLITE_BENCH_BINARY artifact=$TFLITE_BENCH_HELP_LOG"
                test_result_finish
            fi
            ;;
        qnn-htp)
            if ! tflite_benchmark_supports external_delegate_path ||
               ! tflite_benchmark_supports external_delegate_options; then
                test_result_record "SKIP" "Installed TFLite benchmark does not expose the external delegate interface, executable=$TFLITE_BENCH_BINARY artifact=$TFLITE_BENCH_HELP_LOG"
                test_result_finish
            fi
            ;;
    esac

    log_info "[TFLITE-DISCOVERY] benchmark=$TFLITE_BENCH_BINARY model=$TFLITE_BENCH_MODEL delegate=$TFLITE_BENCH_DELEGATE_LIBRARY backend_library=$TFLITE_BENCH_BACKEND_LIBRARY"
    if [ "$TFLITE_BENCH_PROFILE" = "qnn-htp" ]; then
        log_info "[TFLITE-QNN] backend=htp options_source=$TFLITE_BENCH_DELEGATE_OPTIONS_SOURCE adsp_library_path=${ADSP_LIBRARY_PATH:-unset}"
    fi
    log_info "Running benchmark_model with operator profiling and 100 runs"

    tflite_benchmark_run_command
    tflite_benchmark_rc=$?
    log_file_with_label "TFLITE-BENCHMARK" "$TFLITE_BENCH_RUN_LOG" 120

    if [ "$tflite_benchmark_rc" -ne 0 ]; then
        test_result_record "FAIL" "TFLite benchmark failed or timed out, profile=$TFLITE_BENCH_PROFILE rc=$tflite_benchmark_rc artifact=$TFLITE_BENCH_RUN_LOG"
        test_result_finish
    fi

    tflite_timing_count=$(tflite_benchmark_parse_summary_count "$TFLITE_BENCH_RUN_LOG")
    tflite_average_us=$(tflite_benchmark_parse_summary_average "$TFLITE_BENCH_RUN_LOG")
    TFLITE_BENCH_TIMING_SOURCE="inference-summary"
    if [ -z "$tflite_timing_count" ] || [ -z "$tflite_average_us" ]; then
        tflite_timing_count=$(
            tflite_benchmark_parse_legacy_timing count "$TFLITE_BENCH_RUN_LOG"
        )
        tflite_average_us=$(
            tflite_benchmark_parse_legacy_timing avg "$TFLITE_BENCH_RUN_LOG"
        )
        TFLITE_BENCH_TIMING_SOURCE="legacy-timings-summary"
    fi
    tflite_nodes_observed=$(
        sed -n 's/^\([0-9][0-9]*\) nodes observed.*/\1/p' \
            "$TFLITE_BENCH_RUN_LOG" |
            tail -n 1
    )

    case "$tflite_timing_count" in
        ''|*[!0-9]*)
            test_result_record "FAIL" "TFLite benchmark exited successfully without parseable timing count, artifact=$TFLITE_BENCH_RUN_LOG"
            test_result_finish
            ;;
    esac
    if [ "$tflite_timing_count" -lt 100 ]; then
        test_result_record "FAIL" "TFLite benchmark completed fewer than 100 measured runs, count=$tflite_timing_count artifact=$TFLITE_BENCH_RUN_LOG"
        test_result_finish
    fi
    if ! awk -v average_us="$tflite_average_us" '
        BEGIN {
            valid = average_us ~ /^[0-9]+([.][0-9]+)?$/ && average_us + 0 > 0
            exit !valid
        }
    '; then
        test_result_record "FAIL" "TFLite benchmark exited successfully without a positive average inference time, artifact=$TFLITE_BENCH_RUN_LOG"
        test_result_finish
    fi
    tflite_benchmark_validate_accelerator
    tflite_accelerator_rc=$?
    case "$tflite_accelerator_rc" in
        0)
            ;;
        10)
            test_result_record "FAIL" "TFLite GPU delegate was not created, artifact=$TFLITE_BENCH_RUN_LOG"
            test_result_finish
            ;;
        11)
            test_result_record "FAIL" "TFLite GPU benchmark did not confirm complete GPU delegation, artifact=$TFLITE_BENCH_RUN_LOG"
            test_result_finish
            ;;
        12)
            test_result_record "FAIL" "TFLite GPU benchmark used CPU fallback, gpu_operations=$TFLITE_BENCH_ACCELERATOR_OPERATIONS cpu_fallback_operations=$TFLITE_BENCH_CPU_FALLBACK_OPERATIONS artifact=$TFLITE_BENCH_RUN_LOG"
            test_result_finish
            ;;
        20)
            test_result_record "FAIL" "QNN external delegate was not created, artifact=$TFLITE_BENCH_RUN_LOG"
            test_result_finish
            ;;
        21)
            test_result_record "FAIL" "QNN HTP benchmark did not confirm complete delegate execution, artifact=$TFLITE_BENCH_RUN_LOG"
            test_result_finish
            ;;
        22)
            test_result_record "FAIL" "QNN HTP profiling did not report TfLiteQnnDelegate execution, artifact=$TFLITE_BENCH_RUN_LOG"
            test_result_finish
            ;;
        *)
            test_result_record "FAIL" "Unsupported TFLite accelerator validation state, profile=$TFLITE_BENCH_PROFILE"
            test_result_finish
            ;;
    esac
    case "$tflite_nodes_observed" in
        ''|*[!0-9]*|0)
            test_result_record "FAIL" "Operator profiling did not report executed nodes, artifact=$TFLITE_BENCH_RUN_LOG"
            test_result_finish
            ;;
    esac
    tflite_average_ms=$(
        awk -v average_us="$tflite_average_us" \
            'BEGIN { printf "%.6f", average_us / 1000 }'
    )
    TFLITE_BENCH_PERFORMANCE_REPORT="$TFLITE_BENCH_RESULT_DIR/performance.tsv"
    if ! {
        printf 'key\tvalue\n'
        printf 'backend\t%s\n' "$TFLITE_BENCH_BACKEND"
        printf 'profile\t%s\n' "$TFLITE_BENCH_PROFILE"
        printf 'requested_configuration\t%s\n' "$TFLITE_BENCH_CONFIGURATION_REQUEST"
        printf 'active_configuration\t%s\n' "$TFLITE_BENCH_ACTIVE_CONFIGURATION"
        printf 'active_configuration_source\t%s\n' "$TFLITE_BENCH_ACTIVE_CONFIGURATION_SOURCE"
        printf 'detected_configuration\t%s\n' "$TFLITE_BENCH_DETECTED_CONFIGURATION"
        printf 'detected_configuration_source\t%s\n' "$TFLITE_BENCH_DETECTED_CONFIGURATION_SOURCE"
        printf 'supported_configurations\t%s\n' "$TFLITE_BENCH_SUPPORTED_CONFIGURATIONS"
        printf 'model\t%s\n' "$TFLITE_BENCH_MODEL"
        printf 'model_source\t%s\n' "$TFLITE_BENCH_MODEL_SOURCE"
        printf 'timing_source\t%s\n' "$TFLITE_BENCH_TIMING_SOURCE"
        printf 'delegation\t%s\n' "$TFLITE_BENCH_DELEGATION"
        printf 'accelerator_operations\t%s\n' "$TFLITE_BENCH_ACCELERATOR_OPERATIONS"
        printf 'cpu_fallback_operations\t%s\n' "$TFLITE_BENCH_CPU_FALLBACK_OPERATIONS"
        printf 'measured_runs\t%s\n' "$tflite_timing_count"
        printf 'profiled_nodes\t%s\n' "$tflite_nodes_observed"
        printf 'average_inference_us\t%s\n' "$tflite_average_us"
        printf 'average_inference_ms\t%s\n' "$tflite_average_ms"
    } >"$TFLITE_BENCH_PERFORMANCE_REPORT"; then
        test_result_record "FAIL" "Could not write the TFLite performance report, artifact=$TFLITE_BENCH_PERFORMANCE_REPORT"
        test_result_finish
    fi

    log_info "[TFLITE-PERFORMANCE] backend=$TFLITE_BENCH_BACKEND delegation=$TFLITE_BENCH_DELEGATION model=$TFLITE_BENCH_MODEL model_source=$TFLITE_BENCH_MODEL_SOURCE timing_source=$TFLITE_BENCH_TIMING_SOURCE average_inference_us=$tflite_average_us average_inference_ms=$tflite_average_ms measured_runs=$tflite_timing_count profiled_nodes=$tflite_nodes_observed accelerator_operations=$TFLITE_BENCH_ACCELERATOR_OPERATIONS cpu_fallback_operations=$TFLITE_BENCH_CPU_FALLBACK_OPERATIONS"
    test_result_record "PASS" "TFLite benchmark completed, backend=$TFLITE_BENCH_BACKEND delegation=$TFLITE_BENCH_DELEGATION runs=$tflite_timing_count nodes=$tflite_nodes_observed average_inference_us=$tflite_average_us average_inference_ms=$tflite_average_ms report=$TFLITE_BENCH_PERFORMANCE_REPORT artifact=$TFLITE_BENCH_RUN_LOG"
    test_result_finish
}
