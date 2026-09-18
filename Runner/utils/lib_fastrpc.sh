#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# FastRPC runtime layout helpers.
#
# Supports both Yocto/current and Debian package layouts.
#
# Yocto/current:
# libs : /usr/local/lib
# test libs : /usr/local/lib/fastrpc_test
# skeletons : dynamically discovered below /usr/local/share/fastrpc_test
#
# Debian:
# libs : /usr/lib/<multiarch>
# test libs : /usr/lib/<multiarch>/fastrpc_test
# skeletons : dynamically discovered below /usr/share/fastrpc_test
#
# Optional environment overrides:
# FASTRPC_LIB_SYS_DIR
# FASTRPC_LIB_TEST_DIR
# FASTRPC_SKEL_BASE

# fastrpc_append_word_unique CURRENT NEW
# Append NEW to the space-separated CURRENT list when it is non-empty and absent.
# Inputs: two strings. Output: the resulting list on stdout.
# Returns: 0. Side effects: none.
fastrpc_append_word_unique() {
    current="$1"
    new="$2"

    [ -n "$new" ] || {
        printf '%s' "$current"
        return 0
    }

    for word in $current; do
        if [ "$word" = "$new" ]; then
            printf '%s' "$current"
            return 0
        fi
    done

    if [ -n "$current" ]; then
        printf '%s %s' "$current" "$new"
    else
        printf '%s' "$new"
    fi
}

# fastrpc_append_colon_dir CURRENT_PATH NEW_DIR
# Append an existing NEW_DIR to a colon-separated path without duplicates.
# Inputs: a path list and directory. Output: the resulting path on stdout.
# Returns: 0. Side effects: probes NEW_DIR with test -d only.
fastrpc_append_colon_dir() {
    current_path="$1"
    new_dir="$2"

    [ -n "$new_dir" ] || {
        printf '%s' "$current_path"
        return 0
    }

    [ -d "$new_dir" ] || {
        printf '%s' "$current_path"
        return 0
    }

    case ":$current_path:" in
        *":$new_dir:"*)
            printf '%s' "$current_path"
            ;;
        *)
            if [ -n "$current_path" ]; then
                printf '%s:%s' "$current_path" "$new_dir"
            else
                printf '%s' "$new_dir"
            fi
            ;;
    esac
}

# fastrpc_first_dir_with_file CANDIDATE_DIRS FILE_PATTERN
# Find the first space-separated candidate directory containing a matching file.
# Inputs: directory list and find-compatible basename pattern. Output: directory on stdout.
# Returns: 0 when found, 1 otherwise. Side effects: none.
fastrpc_first_dir_with_file() {
    candidate_dirs="$1"
    file_pattern="$2"

    for candidate_dir in $candidate_dirs; do
        [ -n "$candidate_dir" ] || continue

        if [ -d "$candidate_dir" ] &&
           find "$candidate_dir" -maxdepth 1 \( -type f -o -type l \) \
               -name "$file_pattern" -print -quit 2>/dev/null |
               grep -q .; then
            printf '%s\n' "$candidate_dir"
            return 0
        fi
    done

    return 1
}

# fastrpc_find_file_in_dirs CANDIDATE_DIRS FILE_PATTERN
# Find the first matching regular file or symlink directly below candidate directories.
# Inputs: space-separated directories and basename pattern. Output: file path on stdout.
# Returns: 0 when found, 1 otherwise. Side effects: none.
fastrpc_find_file_in_dirs() {
    candidate_dirs="$1"
    file_pattern="$2"

    for candidate_dir in $candidate_dirs; do
        [ -d "$candidate_dir" ] || continue

        candidate_file="$(
            find "$candidate_dir" -maxdepth 1 \( -type f -o -type l \) \
                -name "$file_pattern" -print -quit 2>/dev/null
        )"
        if [ -n "$candidate_file" ]; then
            printf '%s\n' "$candidate_file"
            return 0
        fi
    done

    return 1
}

# fastrpc_find_file_in_trees CANDIDATE_DIRS FILE_PATTERN
# Recursively find the first matching regular file or symlink in candidate trees.
# Inputs: space-separated tree roots and basename pattern. Output: file path on stdout.
# Returns: 0 when found, 1 otherwise. Side effects: none.
fastrpc_find_file_in_trees() {
    candidate_dirs="$1"
    file_pattern="$2"

    for candidate_dir in $candidate_dirs; do
        [ -d "$candidate_dir" ] || continue

        candidate_file="$(
            find "$candidate_dir" \( -type f -o -type l \) \
                -name "$file_pattern" -print -quit 2>/dev/null
        )"
        if [ -n "$candidate_file" ]; then
            printf '%s\n' "$candidate_file"
            return 0
        fi
    done

    return 1
}

# fastrpc_find_skeleton_dirs SKELETON_BASES
# Discover unique directories containing any required FastRPC DSP skeleton.
# Input: space-separated tree roots. Output: colon-separated directories on stdout.
# Returns: 0. Side effects: none.
fastrpc_find_skeleton_dirs() {
    skeleton_bases="$1"
    skeleton_dirs=""

    for skeleton_base in $skeleton_bases; do
        [ -d "$skeleton_base" ] || continue

        while IFS= read -r skeleton_dir; do
            [ -n "$skeleton_dir" ] || continue
            skeleton_dirs="$(fastrpc_append_colon_dir "$skeleton_dirs" "$skeleton_dir")"
        done <<EOF
$(find "$skeleton_base" \( -type f -o -type l \) \
    \( -name 'libcalculator_skel.so*' -o -name 'libhap_example_skel.so*' -o -name 'libmultithreading_skel.so*' \) \
    -exec dirname {} \; 2>/dev/null | sort -u)
EOF
    done

    printf '%s\n' "$skeleton_dirs"
}

# fastrpc_detect_multiarch_triplet
# Detect the target multiarch triplet from image tools or the running architecture.
# Inputs: none. Output: triplet or an empty line on stdout.
# Returns: 0. Side effects: executes read-only compiler, package, and uname probes.
fastrpc_detect_multiarch_triplet() {
    triplet=""

    if command -v gcc >/dev/null 2>&1; then
        triplet="$(gcc -dumpmachine 2>/dev/null || true)"
    fi

    if [ -z "$triplet" ] && command -v dpkg-architecture >/dev/null 2>&1; then
        triplet="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
    fi

    if [ -z "$triplet" ]; then
        case "$(uname -m 2>/dev/null || true)" in
            aarch64|arm64)
                triplet="aarch64-linux-gnu"
                ;;
            armv7l|armv8l)
                triplet="arm-linux-gnueabihf"
                ;;
            x86_64)
                triplet="x86_64-linux-gnu"
                ;;
        esac
    fi

    printf '%s\n' "$triplet"
}

# fastrpc_discover_runtime_layout
# Discover FastRPC system, test, and DSP skeleton library locations.
# Inputs: optional FASTRPC_* path overrides and healthcheck DSP path globals.
# Outputs: FASTRPC_*_CHECKED and FASTRPC_RESOLVED_* shell globals, no stdout contract.
# Returns: 0. Side effects: read-only filesystem traversal.
fastrpc_discover_runtime_layout() {
    FASTRPC_MULTIARCH_TRIPLET="$(fastrpc_detect_multiarch_triplet)"

    FASTRPC_LIB_SYS_DIRS_CHECKED=""
    FASTRPC_LIB_TEST_DIRS_CHECKED=""
    FASTRPC_SKEL_BASES_CHECKED=""

    # Explicit overrides first.
    [ -n "${FASTRPC_LIB_SYS_DIR:-}" ] &&
        FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "$FASTRPC_LIB_SYS_DIR")"

    [ -n "${FASTRPC_LIB_TEST_DIR:-}" ] &&
        FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "$FASTRPC_LIB_TEST_DIR")"

    [ -n "${FASTRPC_SKEL_BASE:-}" ] &&
        FASTRPC_SKEL_BASES_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_SKEL_BASES_CHECKED" "$FASTRPC_SKEL_BASE")"

    # Yocto/current layout.
    FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/local/lib")"
    FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/local/lib64")"
    FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/local/lib/fastrpc_test")"
    FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/local/lib64/fastrpc_test")"
    FASTRPC_SKEL_BASES_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_SKEL_BASES_CHECKED" "/usr/local/share/fastrpc_test")"

    # Debian/multiarch layout.
    if [ -n "$FASTRPC_MULTIARCH_TRIPLET" ]; then
        FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/lib/$FASTRPC_MULTIARCH_TRIPLET")"
        FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/lib/$FASTRPC_MULTIARCH_TRIPLET/fastrpc_test")"
    fi

    # Generic fallbacks.
    FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/lib")"
    FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/lib64")"
    FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/lib/fastrpc_test")"
    FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/lib64/fastrpc_test")"
    FASTRPC_SKEL_BASES_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_SKEL_BASES_CHECKED" "/usr/share/fastrpc_test")"

    FASTRPC_RESOLVED_LIB_SYS_DIR="$(
        fastrpc_first_dir_with_file "$FASTRPC_LIB_SYS_DIRS_CHECKED" 'lib*dsprpc.so*' || true
    )"
    FASTRPC_RESOLVED_LIB_SYS_PATH=""
    for library_dir in $FASTRPC_LIB_SYS_DIRS_CHECKED; do
        if find "$library_dir" -maxdepth 1 \( -type f -o -type l \) \
            -name 'lib*dsprpc.so*' -print -quit 2>/dev/null |
           grep -q .; then
            FASTRPC_RESOLVED_LIB_SYS_PATH="$(
                fastrpc_append_colon_dir "$FASTRPC_RESOLVED_LIB_SYS_PATH" "$library_dir"
            )"
        fi
    done

    FASTRPC_RESOLVED_LIB_TEST_PATH=""
    for test_library_dir in $FASTRPC_LIB_TEST_DIRS_CHECKED; do
        if find "$test_library_dir" -maxdepth 1 \( -type f -o -type l \) \
            \( -name 'libcalculator.so*' -o -name 'libhap_example.so*' -o -name 'libmultithreading.so*' \) \
            -print -quit 2>/dev/null | grep -q .; then
            FASTRPC_RESOLVED_LIB_TEST_PATH="$(
                fastrpc_append_colon_dir "$FASTRPC_RESOLVED_LIB_TEST_PATH" "$test_library_dir"
            )"
        fi
    done
    if [ -n "${FASTRPC_HEALTHCHECK_DSP_LIB_DIR:-}" ]; then
        FASTRPC_SKEL_BASES_CHECKED="$(
            fastrpc_append_word_unique \
                "$FASTRPC_SKEL_BASES_CHECKED" \
                "$FASTRPC_HEALTHCHECK_DSP_LIB_DIR"
        )"
    fi

    FASTRPC_RESOLVED_SKEL_PATH="$(fastrpc_find_skeleton_dirs "$FASTRPC_SKEL_BASES_CHECKED")"
}

# fastrpc_missing_test_libraries
# Identify required host test libraries absent from the discovered search directories.
# Inputs: FASTRPC_LIB_TEST_DIRS_CHECKED. Output: space-separated names on stdout.
# Returns: 0. Side effects: read-only filesystem traversal.
fastrpc_missing_test_libraries() {
    missing_libraries=""

    for test_library in libcalculator.so libhap_example.so libmultithreading.so; do
        found_library=0

        for test_dir in $FASTRPC_LIB_TEST_DIRS_CHECKED; do
            if find "$test_dir" -maxdepth 1 \( -type f -o -type l \) \
                -name "${test_library}*" -print -quit 2>/dev/null |
               grep -q .; then
                found_library=1
                break
            fi
        done

        if [ "$found_library" -eq 0 ]; then
            missing_libraries="$(fastrpc_append_word_unique "$missing_libraries" "$test_library")"
        fi
    done

    printf '%s\n' "$missing_libraries"
}

# fastrpc_missing_skeleton_libraries
# Identify required DSP skeleton libraries absent from the discovered search trees.
# Inputs: FASTRPC_SKEL_BASES_CHECKED. Output: space-separated names on stdout.
# Returns: 0. Side effects: read-only filesystem traversal.
fastrpc_missing_skeleton_libraries() {
    missing_skeletons=""

    for skeleton_library in \
        libcalculator_skel.so \
        libhap_example_skel.so \
        libmultithreading_skel.so; do
        found_skeleton=0

        for skeleton_base in $FASTRPC_SKEL_BASES_CHECKED; do
            if find "$skeleton_base" \( -type f -o -type l \) \
                -name "${skeleton_library}*" -print -quit 2>/dev/null |
               grep -q .; then
                found_skeleton=1
                break
            fi
        done

        if [ "$found_skeleton" -eq 0 ]; then
            missing_skeletons="$(
                fastrpc_append_word_unique "$missing_skeletons" "$skeleton_library"
            )"
        fi
    done

    printf '%s\n' "$missing_skeletons"
}

# fastrpc_validate_runtime_artifacts
# Validate the FastRPC binary's host dependencies and all required test artifacts.
# Inputs: RUN_BIN and discovered FASTRPC_* globals. Output: no stdout contract.
# Returns: 0 when usable, 1 otherwise, and sets FASTRPC_ARTIFACT_ERROR.
# Side effects: runs read-only find and optional ldd probes.
fastrpc_validate_runtime_artifacts() {
    FASTRPC_ARTIFACT_ERROR=""
    missing_test_libraries="$(fastrpc_missing_test_libraries)"
    missing_skeleton_libraries="$(fastrpc_missing_skeleton_libraries)"

    if [ -z "$FASTRPC_RESOLVED_LIB_SYS_DIR" ]; then
        FASTRPC_ARTIFACT_ERROR="no FastRPC system library was found"
    elif [ -n "$missing_test_libraries" ]; then
        FASTRPC_ARTIFACT_ERROR="missing test libraries: $missing_test_libraries"
    elif [ -n "$missing_skeleton_libraries" ]; then
        FASTRPC_ARTIFACT_ERROR="missing DSP skeleton libraries: $missing_skeleton_libraries"
    elif [ -z "$FASTRPC_RESOLVED_SKEL_PATH" ]; then
        FASTRPC_ARTIFACT_ERROR="no directory containing required DSP skeleton libraries was found"
    elif command -v ldd >/dev/null 2>&1 &&
         ldd "$RUN_BIN" 2>/dev/null | grep -q 'not found'; then
        FASTRPC_ARTIFACT_ERROR="fastrpc_test has unresolved host library dependencies"
    fi

    if [ -z "$FASTRPC_ARTIFACT_ERROR" ] && command -v ldd >/dev/null 2>&1; then
        for test_library in libcalculator.so libhap_example.so libmultithreading.so; do
            test_library_path="$(
                fastrpc_find_file_in_dirs \
                    "$FASTRPC_LIB_TEST_DIRS_CHECKED" \
                    "${test_library}*" || true
            )"

            if [ -n "$test_library_path" ] &&
               ldd "$test_library_path" 2>/dev/null | grep -q 'not found'; then
                FASTRPC_ARTIFACT_ERROR="$test_library has unresolved host library dependencies"
                break
            fi
        done
    fi

    [ -z "$FASTRPC_ARTIFACT_ERROR" ]
}

# fastrpc_export_runtime_env
# Build and export host and DSP library search paths from discovered directories.
# Inputs: FASTRPC_RESOLVED_* globals and existing library-path environment values.
# Outputs: exported LD_LIBRARY_PATH and DSP-specific *_LIBRARY_PATH variables.
# Returns: 0. Side effects: mutates the current shell environment.
fastrpc_export_runtime_env() {
    new_ld_library_path=""

    for resolved_dir in $(printf '%s' "$FASTRPC_RESOLVED_LIB_SYS_PATH" | tr ':' ' '); do
        new_ld_library_path="$(fastrpc_append_colon_dir "$new_ld_library_path" "$resolved_dir")"
    done

    for resolved_dir in $(printf '%s' "$FASTRPC_RESOLVED_LIB_TEST_PATH" | tr ':' ' '); do
        new_ld_library_path="$(fastrpc_append_colon_dir "$new_ld_library_path" "$resolved_dir")"
    done

    if [ -n "${LD_LIBRARY_PATH:-}" ]; then
        if [ -n "$new_ld_library_path" ]; then
            new_ld_library_path="${new_ld_library_path}:${LD_LIBRARY_PATH}"
        else
            new_ld_library_path="$LD_LIBRARY_PATH"
        fi
    fi

    if [ -n "$new_ld_library_path" ]; then
        export LD_LIBRARY_PATH="$new_ld_library_path"
    fi

    if [ -n "$FASTRPC_RESOLVED_SKEL_PATH" ]; then
        : "${ADSP_LIBRARY_PATH:=$FASTRPC_RESOLVED_SKEL_PATH}"
        : "${CDSP_LIBRARY_PATH:=$FASTRPC_RESOLVED_SKEL_PATH}"
        : "${SDSP_LIBRARY_PATH:=$FASTRPC_RESOLVED_SKEL_PATH}"

        export ADSP_LIBRARY_PATH
        export CDSP_LIBRARY_PATH
        export SDSP_LIBRARY_PATH
    fi
}

# fastrpc_log_runtime_layout
# Log discovered FastRPC paths and the resolved location of every required artifact.
# Inputs: discovered FASTRPC_* globals. Output: no machine-readable stdout contract.
# Returns: 0. Side effects: emits informational and warning log records.
fastrpc_log_runtime_layout() {
    log_info "FastRPC multiarch triplet: ${FASTRPC_MULTIARCH_TRIPLET:-<not detected>}"

    if [ -n "$FASTRPC_RESOLVED_LIB_SYS_PATH" ]; then
        log_info "FastRPC system library path: $FASTRPC_RESOLVED_LIB_SYS_PATH"
    else
        log_warn "No FastRPC system library dir found. Checked: $FASTRPC_LIB_SYS_DIRS_CHECKED"
    fi

    if [ -n "$FASTRPC_RESOLVED_LIB_TEST_PATH" ]; then
        log_info "FastRPC test library path: $FASTRPC_RESOLVED_LIB_TEST_PATH"
    else
        log_warn "No FastRPC test library dir found. Checked: $FASTRPC_LIB_TEST_DIRS_CHECKED"
    fi

    if [ -n "$FASTRPC_RESOLVED_SKEL_PATH" ]; then
        log_info "FastRPC skeleton path: $FASTRPC_RESOLVED_SKEL_PATH"
    else
        log_warn "No DSP skeleton dirs found. Checked bases: $FASTRPC_SKEL_BASES_CHECKED"
    fi

    for runtime_library in libadsprpc.so libcdsprpc.so libsdsprpc.so; do
        runtime_library_path="$(
            fastrpc_find_file_in_dirs \
                "$FASTRPC_LIB_SYS_DIRS_CHECKED" \
                "${runtime_library}*" || true
        )"
        log_info "[FASTRPC-ARTIFACT] type=runtime-library name=$runtime_library path=${runtime_library_path:-missing}"
    done

    for test_library in libcalculator.so libhap_example.so libmultithreading.so; do
        test_library_path="$(
            fastrpc_find_file_in_dirs \
                "$FASTRPC_LIB_TEST_DIRS_CHECKED" \
                "${test_library}*" || true
        )"
        log_info "[FASTRPC-ARTIFACT] type=test-library name=$test_library path=${test_library_path:-missing}"
    done

    for skeleton_library in \
        libcalculator_skel.so \
        libhap_example_skel.so \
        libmultithreading_skel.so; do
        skeleton_library_path="$(
            fastrpc_find_file_in_trees \
                "$FASTRPC_SKEL_BASES_CHECKED" \
                "${skeleton_library}*" || true
        )"
        log_info "[FASTRPC-ARTIFACT] type=dsp-skeleton name=$skeleton_library path=${skeleton_library_path:-missing}"
    done
}

# fastrpc_setup_runtime_layout
# Discover, report, and export the complete FastRPC runtime library layout.
# Inputs: optional FASTRPC_* path overrides. Output: discovered/exported globals.
# Returns: 0. Side effects: logs discovery and mutates library-path environment values.
fastrpc_setup_runtime_layout() {
    fastrpc_discover_runtime_layout
    fastrpc_log_runtime_layout
    fastrpc_export_runtime_env

    log_info "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
    [ -n "${ADSP_LIBRARY_PATH:-}" ] && log_info "ADSP_LIBRARY_PATH=${ADSP_LIBRARY_PATH}"
    [ -n "${CDSP_LIBRARY_PATH:-}" ] && log_info "CDSP_LIBRARY_PATH=${CDSP_LIBRARY_PATH}"
    [ -n "${SDSP_LIBRARY_PATH:-}" ] && log_info "SDSP_LIBRARY_PATH=${SDSP_LIBRARY_PATH}"
}

# -------------------- FastRPC test orchestration helpers --------------------

# log_debug MESSAGE...
# Emit a diagnostic message only when VERBOSE is set to 1.
# Inputs: message arguments and VERBOSE. Output: no stdout contract.
# Returns: 0. Side effects: logs to stderr when enabled.
# shellcheck disable=SC2317
log_debug() {
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        log_info "[debug] $*" >&2
    fi
}

# cmd_to_string ARG...
# Render command arguments as a readable shell-like string for diagnostic logging.
# Inputs: arbitrary command arguments. Output: one escaped string on stdout.
# Returns: 0. Side effects: none. The output is descriptive and must not be evaluated.
cmd_to_string() {
    out=""
    for a in "$@"; do
        case "$a" in
            *[!A-Za-z0-9._:/-]*|"")
                q=$(printf "%s" "$a" | sed "s/'/'\\\\''/g")
                out="$out '$q'"
                ;;
            *)
                out="$out $a"
                ;;
        esac
    done
    printf "%s" "$out"
}

# extract_test_summary_counts LOG_FILE
# Parse the final FastRPC test totals from a retained command log.
# Input: readable log path. Output: total:passed:failed:skipped on stdout.
# Returns: 0 and substitutes zero for missing or malformed fields. Side effects: none.
extract_test_summary_counts() {
    log_file="$1"

    total="$(sed -n 's/^[[:space:]]*Total tests run:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"
    passed="$(sed -n 's/^[[:space:]]*Passed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"
    failed="$(sed -n 's/^[[:space:]]*Failed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"
    skipped="$(sed -n 's/^[[:space:]]*Skipped:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"

    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    case "$passed" in ''|*[!0-9]*) passed=0 ;; esac
    case "$failed" in ''|*[!0-9]*) failed=0 ;; esac
    case "$skipped" in ''|*[!0-9]*) skipped=0 ;; esac

    printf '%s:%s:%s:%s\n' "$total" "$passed" "$failed" "$skipped"
}

# log_dsp_remoteproc_status
# Log runtime remoteproc state for every FastRPC firmware alias in the domain table.
# Inputs: runtime DT and remoteproc sysfs through shared helpers. Output: no stdout contract.
# Returns: 0. Side effects: emits informational logs only.
log_dsp_remoteproc_status() {
    fw_list="$(fastrpc_domain_table | awk -F '|' '{print $5}')"
    any=0

    for fw in $fw_list; do
        if dt_has_remoteproc_fw "$fw" || [ -n "$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null || true)" ]; then
            entries="$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null)" || entries=""

            if [ -n "$entries" ]; then
                any=1

                while IFS='|' read -r rpath rstate rfirm rname; do
                    [ -n "$rpath" ] || continue
                    inst="$(basename "$rpath")"
                    log_info "rproc.$fw: $inst path=$rpath state=$rstate fw=$rfirm name=$rname"
                done <<__RPROC__
$entries
__RPROC__
            fi
        fi
    done

    [ "$any" -eq 0 ] && log_info "rproc: no *dsp remoteproc entries detected via DT"
}

# fastrpc_domain_table
# Emit the protocol-defined FastRPC domain metadata used by discovery and policy.
# Inputs: none. Output: pipe-separated domain rows on stdout.
# Returns: 0. Side effects: none.
fastrpc_domain_table() {
    cat <<'EOF'
0|ADSP|adsp|adsp|adsp|0
1|MDSP|mdsp|mdsp|mdsp|0
2|SDSP|sdsp|sdsp|sdsp|0
3|CDSP|cdsp|cdsp|cdsp cdsp0|0 1
4|CDSP1|cdsp1|cdsp1|cdsp1|0 1
5|GDSP0|gdsp0|gdsp0|gdsp0 gpdsp0|0 1
6|GDSP1|gdsp1|gdsp1|gdsp1 gpdsp1|0 1
EOF
}

# fastrpc_domain_field DOMAIN_ID FIELD_NUMBER
# Read one field from the FastRPC domain table for a numeric domain identifier.
# Inputs: domain ID and one-based field number. Output: matching field on stdout.
# Returns: awk status, normally 0 even when no row matches. Side effects: none.
fastrpc_domain_field() {
    requested_domain="$1"
    requested_field="$2"

    fastrpc_domain_table | awk -F '|' -v domain="$requested_domain" -v field="$requested_field" '
        $1 == domain {
            print $field
            exit
        }
    '
}

# name_to_domain DOMAIN_NAME
# Map a case-insensitive public domain name or supported alias to its numeric ID.
# Input: one domain name. Output: numeric domain ID on stdout when recognized.
# Returns: awk status, normally 0 even when unmapped. Side effects: none.
name_to_domain() {
    requested_name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    fastrpc_domain_table | awk -F '|' -v requested="$requested_name" '
        {
            alias_count = split($5, aliases, " ")
            for (alias_number = 1; alias_number <= alias_count; alias_number++) {
                if (requested == aliases[alias_number]) {
                    print $1
                    exit
                }
            }
        }
    '
}

# domain_to_name DOMAIN_ID
# Map a numeric FastRPC domain identifier to its public display name.
# Input: numeric domain ID. Output: domain name or UNKNOWN on stdout.
# Returns: 0. Side effects: none.
domain_to_name() {
    domain_name="$(fastrpc_domain_field "$1" 2)"
    printf '%s\n' "${domain_name:-UNKNOWN}"
}

# domain_to_endpoint_label DOMAIN_ID
# Return the device-node label associated with a FastRPC domain.
# Input: numeric domain ID. Output: endpoint label or an empty line on stdout.
# Returns: the domain-table lookup status. Side effects: none.
domain_to_endpoint_label() {
    fastrpc_domain_field "$1" 3
}

# append_unique CURRENT NEW
# Append NEW to a space-separated list when it is not already present.
# Inputs: current list and new word. Output: resulting list on stdout.
# Returns: 0. Side effects: none.
append_unique() {
    current="$1"
    new="$2"

    for word in $current; do
        [ "$word" = "$new" ] && {
            printf "%s" "$current"
            return
        }
    done

    [ -n "$current" ] && printf "%s %s" "$current" "$new" || printf "%s" "$new"
}

# fastrpc_capture_healthcheck LOG_FILE TIMEOUT_SECONDS
# Run the image-provided FastRPC healthcheck under the shared bounded runner.
# Inputs: retained log path, positive timeout, and optional FASTRPC_HEALTHCHECK_BIN.
# Output: no stdout contract. Returns: 0 on success, 1 on execution failure, 2 if absent.
# Side effects: truncates LOG_FILE and emits healthcheck diagnostic logs.
fastrpc_capture_healthcheck() {
    healthcheck_log="$1"
    healthcheck_timeout="$2"
    healthcheck_bin="${FASTRPC_HEALTHCHECK_BIN:-}"

    if [ -z "$healthcheck_bin" ]; then
        healthcheck_bin="$(command -v fastrpc-healthcheck 2>/dev/null || true)"
    fi

    if [ -z "$healthcheck_bin" ] && [ -x "${BIN_DIR:-/usr/bin}/fastrpc-healthcheck" ]; then
        healthcheck_bin="${BIN_DIR:-/usr/bin}/fastrpc-healthcheck"
    fi

    [ -n "$healthcheck_bin" ] || return 2

    : >"$healthcheck_log"
    log_info "[FASTRPC-HEALTHCHECK] command=$healthcheck_bin timeout=${healthcheck_timeout}s artifact=$healthcheck_log"

    diag_run_with_timeout "$healthcheck_timeout" "$healthcheck_bin" >"$healthcheck_log" 2>&1
    healthcheck_rc=$?

    if [ "$healthcheck_rc" -eq 0 ]; then
        return 0
    fi

    log_warn "[FASTRPC-HEALTHCHECK] command failed rc=$healthcheck_rc artifact=$healthcheck_log"
    return 1
}

# fastrpc_parse_healthcheck LOG_FILE TSV_FILE
# Parse the healthcheck DSP capability table and advertised DSP library path.
# Inputs: raw healthcheck log and destination TSV path. Output: no stdout contract.
# Returns: 0 when at least one DSP row is parsed, 1 otherwise.
# Side effects: replaces TSV_FILE and sets FASTRPC_HEALTHCHECK_DSP_LIB_DIR.
fastrpc_parse_healthcheck() {
    healthcheck_log="$1"
    healthcheck_tsv="$2"

    FASTRPC_HEALTHCHECK_DSP_LIB_DIR="$(
        sed -n 's/^[[:space:]]*DSP dynamic libs path[[:space:]]*:[[:space:]]*//p' \
            "$healthcheck_log" | tail -n 1
    )"

    awk '
        BEGIN {
            OFS = "\t"
            in_table = 0
        }
        $1 == "DSP" && $2 == "State" && $3 == "SignedPD" {
            in_table = 1
            next
        }
        in_table && $1 ~ /^-+$/ {
            next
        }
        in_table && NF >= 5 {
            name = toupper($1)
            if (name ~ /^(ADSP|MDSP|SDSP|CDSP|CDSP1|GDSP0|GDSP1|GPDSP0|GPDSP1)$/) {
                support = tolower($5)
                for (column = 6; column <= NF; column++) {
                    support = support " " tolower($column)
                }
                print name, tolower($2), tolower($3), tolower($4), support
            }
        }
    ' "$healthcheck_log" >"$healthcheck_tsv"

    [ -s "$healthcheck_tsv" ]
}

# fastrpc_healthcheck_record DOMAIN_ID
# Select the parsed healthcheck row for a domain, accepting public GDSP aliases.
# Input: numeric domain ID and FASTRPC_HEALTHCHECK_TSV. Output: one TSV row on stdout.
# Returns: awk status, normally 0 even when no row matches. Side effects: none.
fastrpc_healthcheck_record() {
    domain_id="$1"
    healthcheck_name="$(fastrpc_domain_field "$domain_id" 2)"

    case "$healthcheck_name" in
        GDSP0) healthcheck_pattern='GDSP0|GPDSP0' ;;
        GDSP1) healthcheck_pattern='GDSP1|GPDSP1' ;;
        *) healthcheck_pattern="$healthcheck_name" ;;
    esac

    awk -F '\t' -v names="$healthcheck_pattern" '
        BEGIN {
            count = split(names, accepted, "|")
        }
        {
            for (item = 1; item <= count; item++) {
                if ($1 == accepted[item]) {
                    print
                    exit
                }
            }
        }
    ' "${FASTRPC_HEALTHCHECK_TSV:-/dev/null}"
}

# fastrpc_log_healthcheck_records
# Log every parsed FastRPC domain capability record for live CI evidence.
# Input: FASTRPC_HEALTHCHECK_TSV. Output: no machine-readable stdout contract.
# Returns: 0. Side effects: emits informational logs.
fastrpc_log_healthcheck_records() {
    while IFS="$(printf '\t')" read -r hc_name hc_state hc_signed hc_unsigned hc_support; do
        [ -n "$hc_name" ] || continue
        log_info "[FASTRPC-CAPABILITY] domain=$hc_name state=$hc_state signed_pd=$hc_signed unsigned_pd=$hc_unsigned support=$hc_support source=fastrpc-healthcheck"
    done <"$FASTRPC_HEALTHCHECK_TSV"
}

# fastrpc_healthcheck_supported_domains
# Select online, FastRPC-supported domain IDs from the parsed healthcheck table.
# Input: FASTRPC_HEALTHCHECK_TSV. Output: one numeric domain ID per stdout line.
# Returns: 0. Side effects: logs exclusion and mapping diagnostics to stderr.
fastrpc_healthcheck_supported_domains() {
    while IFS="$(printf '\t')" read -r \
        hc_name hc_state hc_signed hc_unsigned hc_support; do
        if [ "$hc_state" != "online" ]; then
            log_info "[FASTRPC-DISCOVERY] domain=$hc_name eligible=no reason=healthcheck-state-$hc_state" >&2
            continue
        fi

        if [ "$hc_support" != "yes" ]; then
            log_info "[FASTRPC-DISCOVERY] domain=$hc_name eligible=no reason=healthcheck-support-$hc_support" >&2
            continue
        fi

        hc_domain="$(name_to_domain "$hc_name")"
        if [ -n "$hc_domain" ]; then
            printf '%s\n' "$hc_domain"
        else
            log_warn "[FASTRPC-DISCOVERY] domain=$hc_name eligible=no reason=unmapped-healthcheck-domain" >&2
        fi
    done <"$FASTRPC_HEALTHCHECK_TSV"
}

# fastrpc_healthcheck_domain_ready DOMAIN_ID
# Enforce that an explicitly selected domain is listed, online, and supported.
# Input: numeric domain ID and FASTRPC_HEALTHCHECK_TSV. Output: no stdout contract.
# Returns: 0 when ready, 1 when unhealthy, 2 when unlisted.
# Side effects: emits failure diagnostics.
fastrpc_healthcheck_domain_ready() {
    healthcheck_record="$(fastrpc_healthcheck_record "$1")"
    if [ -z "$healthcheck_record" ]; then
        log_fail "[FASTRPC-CAPABILITY] domain=$(domain_to_name "$1") expected=healthcheck-record observed=not-listed artifact=$FASTRPC_HEALTHCHECK_TSV"
        return 2
    fi

    IFS="$(printf '\t')" read -r hc_name hc_state hc_signed hc_unsigned hc_support <<EOF
$healthcheck_record
EOF

    if [ "$hc_state" != "online" ] || [ "$hc_support" != "yes" ]; then
        log_fail "[FASTRPC-CAPABILITY] domain=$hc_name expected=online-and-supported observed_state=$hc_state observed_support=$hc_support"
        return 1
    fi

    return 0
}

# fastrpc_remoteproc_domain_state DOMAIN_ID
# Resolve the first runtime remoteproc record matching a domain's firmware aliases.
# Input: numeric domain ID. Output: state|path|firmware|name on stdout.
# Returns: 0 when found, 2 otherwise. Side effects: read-only shared-helper probes.
fastrpc_remoteproc_domain_state() {
    domain_id="$1"
    domain_aliases="$(fastrpc_domain_field "$domain_id" 5)"

    for domain_alias in $domain_aliases; do
        remoteproc_entries="$(
            get_remoteproc_by_firmware "$domain_alias" "" all 2>/dev/null || true
        )"
        [ -n "$remoteproc_entries" ] || continue

        while IFS='|' read -r remoteproc_path remoteproc_state remoteproc_firmware remoteproc_name; do
            [ -n "$remoteproc_path" ] || continue
            printf '%s|%s|%s|%s\n' \
                "$remoteproc_state" \
                "$remoteproc_path" \
                "$remoteproc_firmware" \
                "$remoteproc_name"
            return 0
        done <<EOF
$remoteproc_entries
EOF
    done

    return 2
}

# fastrpc_domain_ready DOMAIN_ID
# Validate domain readiness from parsed healthcheck data or remoteproc fallback evidence.
# Input: numeric domain ID and optional FASTRPC_HEALTHCHECK_TSV. Output: no stdout contract.
# Returns: 0 when ready, 1 when unhealthy, 2 when runtime evidence is absent.
# Side effects: emits failure diagnostics.
fastrpc_domain_ready() {
    domain_id="$1"

    if [ -s "${FASTRPC_HEALTHCHECK_TSV:-}" ]; then
        fastrpc_healthcheck_domain_ready "$domain_id"
        return $?
    fi

    remoteproc_record="$(fastrpc_remoteproc_domain_state "$domain_id")"
    if [ -z "$remoteproc_record" ]; then
        log_fail "[FASTRPC-CAPABILITY] domain=$(domain_to_name "$domain_id") expected=runtime-remoteproc observed=not-found"
        return 2
    fi

    IFS='|' read -r remoteproc_state remoteproc_path remoteproc_firmware remoteproc_name <<EOF
$remoteproc_record
EOF

    if [ "$remoteproc_state" != "running" ]; then
        log_fail "[FASTRPC-CAPABILITY] domain=$(domain_to_name "$domain_id") expected=remoteproc-running observed=$remoteproc_state path=$remoteproc_path firmware=$remoteproc_firmware name=$remoteproc_name"
        return 1
    fi

    return 0
}

# discover_supported_domains
# Dynamically select runnable FastRPC domains from healthcheck or runtime fallback data.
# Inputs: healthcheck globals, DT, remoteproc, and FastRPC endpoint devices.
# Output: one numeric domain ID per stdout line. Returns: 0.
# Side effects: emits discovery and exclusion diagnostics to stderr.
discover_supported_domains() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - discover_supported_domains: helper-backed discovery active" >&2

    if [ -s "${FASTRPC_HEALTHCHECK_TSV:-}" ]; then
        fastrpc_healthcheck_supported_domains
        return
    fi

    for fw in $(fastrpc_domain_table | awk -F '|' '{print $5}'); do
        entries="$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null || true)"

        if [ -n "$entries" ]; then
            while IFS='|' read -r rpath rstate rfirm rname; do
                nameguess=""

                if [ -n "$rname" ]; then
                    nameguess="$rname"
                elif [ -n "$rfirm" ]; then
                    nameguess=$(basename "$rfirm" 2>/dev/null | sed 's/\.[^.]*$//')
                fi

                [ -n "$nameguess" ] || continue

                d="$(name_to_domain "$nameguess")"

                if [ -n "$d" ]; then
                    if [ "$rstate" != "running" ]; then
                        log_info "[FASTRPC-DISCOVERY] domain=$(domain_to_name "$d") eligible=no reason=remoteproc-state-$rstate" >&2
                    else
                        if fastrpc_domain_endpoint_available "$d"; then
                            printf '%s\n' "$d"
                            log_debug "discover: fw=$fw rname=$rname rfirm=$rfirm domain=$d state=$rstate"
                        else
                            label="$(domain_to_endpoint_label "$d")"
                            log_info "[FASTRPC-DISCOVERY] domain=$(domain_to_name "$d") eligible=no reason=endpoint-absent expected=/dev/fastrpc-${label}[-secure]" >&2
                        fi
                    fi
                else
                    log_debug "discover: fw=$fw rname=$rname rfirm=$rfirm domain=<none>"
                fi
            done <<EOF
$entries
EOF
        elif dt_has_remoteproc_fw "$fw"; then
            d="$(name_to_domain "$fw")"

            if [ -n "$d" ]; then
                if ! fastrpc_domain_endpoint_available "$d"; then
                    label="$(domain_to_endpoint_label "$d")"
                    log_warn "$(domain_to_name "$d"): skipped (/dev/fastrpc-${label}[-secure] absent)" >&2
                else
                    printf '%s\n' "$d"
                    log_debug "discover: fw=$fw dt-only domain=$d"
                fi
            fi
        else
            log_debug "discover: fw=$fw not present"
        fi
    done
}

# resolve_domains_to_test
# Apply CLI, environment, and dynamic-discovery precedence to the domain selection.
# Inputs: CLI_DOMAIN*, DOMAIN_MODE, FASTRPC_DOMAIN*, and runtime discovery.
# Output: unique space-separated valid domain IDs on stdout. Returns: 0.
# Side effects: logs invalid entries and verbose diagnostics.
resolve_domains_to_test() {
    resolved=""

    if [ -n "$CLI_DOMAIN_NAME" ]; then
        resolved="$(name_to_domain "$CLI_DOMAIN_NAME")"
    elif [ -n "$CLI_DOMAIN" ]; then
        resolved="$CLI_DOMAIN"
    elif [ "$DOMAIN_MODE" = "single" ]; then
        if [ -n "${FASTRPC_DOMAIN_NAME:-}" ]; then
            resolved="$(name_to_domain "$FASTRPC_DOMAIN_NAME")"
        elif [ -n "${FASTRPC_DOMAIN:-}" ]; then
            resolved="$FASTRPC_DOMAIN"
        fi
    else
        resolved="$(discover_supported_domains)"
    fi

    log_debug "resolve: raw domains='$resolved'"

    valid=""
    for d in $resolved; do
        if [ -n "$(fastrpc_domain_field "$d" 2)" ]; then
            case " $valid " in
                *" $d "*)
                    :
                    ;;
                *)
                    if [ -n "$valid" ]; then
                        valid="${valid} ${d}"
                    else
                        valid="$d"
                    fi
                    ;;
            esac
        else
            log_warn "Ignoring invalid domain '$d'"
        fi
    done

    printf '%s' "$valid"
}

# domain_supported_pds DOMAIN_ID
# Return signed and unsigned protection-domain modes supported by one DSP domain.
# Input: numeric domain ID and optional healthcheck table. Output: space-separated 0/1 values.
# Returns: 0. Side effects: none.
domain_supported_pds() {
    domain_id="$1"

    if [ -s "${FASTRPC_HEALTHCHECK_TSV:-}" ]; then
        healthcheck_record="$(fastrpc_healthcheck_record "$domain_id")"

        if [ -n "$healthcheck_record" ]; then
            IFS="$(printf '\t')" read -r \
                hc_name hc_state hc_signed hc_unsigned hc_support <<EOF
$healthcheck_record
EOF
            supported_pds=""
            [ "$hc_signed" = "yes" ] && supported_pds="0"
            if [ "$hc_unsigned" = "yes" ]; then
                supported_pds="$(fastrpc_append_word_unique "$supported_pds" 1)"
            fi
            printf '%s' "$supported_pds"
            return
        fi
    fi

    fastrpc_domain_field "$domain_id" 6
}

# requested_pds
# Resolve requested protection-domain modes from compatibility and policy settings.
# Inputs: UNSIGNED_PD_FLAG, FASTRPC_UNSIGNED_PD, and PD_MODE.
# Output: space-separated 0/1 values on stdout. Returns: 0. Side effects: none.
requested_pds() {
    [ "$UNSIGNED_PD_FLAG" -eq 1 ] && {
        printf "%s" "1"
        return
    }

    [ "${FASTRPC_UNSIGNED_PD:-0}" -eq 1 ] && {
        printf "%s" "1"
        return
    }

    case "$PD_MODE" in
        signed-only) printf "%s" "0" ;;
        unsigned-only) printf "%s" "1" ;;
        both) printf "%s" "0 1" ;;
    esac
}

# effective_pds_for_domain DOMAIN_ID
# Intersect requested protection-domain modes with those supported by the domain.
# Input: numeric domain ID and current PD policy globals. Output: 0/1 values on stdout.
# Returns: 0. Side effects: none.
effective_pds_for_domain() {
    domain="$1"
    requested="$(requested_pds)"
    supported="$(domain_supported_pds "$domain")"
    effective=""

    for req in $requested; do
        for sup in $supported; do
            [ "$req" = "$sup" ] && effective="$(append_unique "$effective" "$req")"
        done
    done

    printf "%s" "$effective"
}

# fastrpc_domain_endpoint_available DOMAIN_ID
# Check whether a normal or secure character device exists for a FastRPC domain.
# Input: numeric domain ID. Output: none.
# Returns: 0 when an endpoint exists, 1 otherwise. Side effects: none.
fastrpc_domain_endpoint_available() {
    label="$(domain_to_endpoint_label "$1")"
    [ -n "$label" ] || return 1
    [ -c "/dev/fastrpc-${label}" ] || [ -c "/dev/fastrpc-${label}-secure" ]
}
