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
# skeletons : /usr/local/share/fastrpc_test/v75, v68
#
# Debian:
# libs : /usr/lib/<multiarch>
# test libs : /usr/lib/<multiarch>/fastrpc_test
# skeletons : /usr/share/fastrpc_test/v75, v68
#
# Optional environment overrides:
# FASTRPC_LIB_SYS_DIR
# FASTRPC_LIB_TEST_DIR
# FASTRPC_SKEL_BASE

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

fastrpc_first_existing_word_dir() {
    candidate_dirs="$1"

    for candidate_dir in $candidate_dirs; do
        [ -n "$candidate_dir" ] || continue

        if [ -d "$candidate_dir" ]; then
            printf '%s\n' "$candidate_dir"
            return 0
        fi
    done

    return 1
}

# Returns the first directory in the space-separated candidate_dirs list that
# contains ALL three FastRPC system libraries (libadsprpc, libcdsprpc, and
# libsdsprpc).  Requiring the complete set ensures every domain's runtime
# library is present before any domain is scheduled.  Generic directories
# like /usr/lib that exist without FastRPC installed are skipped.
fastrpc_first_dir_with_fastrpc_syslib() {
    candidate_dirs="$1"
    for candidate_dir in $candidate_dirs; do
        [ -d "$candidate_dir" ] || continue
        _missing=""
        for lib in libadsprpc libcdsprpc libsdsprpc; do
            if ! find "$candidate_dir" -maxdepth 1 -name "${lib}.so*" 2>/dev/null \
               | grep -qm1 .; then
                _missing="${_missing:+$_missing }${lib}"
            fi
        done
        if [ -z "$_missing" ]; then
            printf '%s\n' "$candidate_dir"
            return 0
        fi
        log_debug "fastrpc_syslib: $candidate_dir missing: $_missing"
    done
    return 1
}

# Returns the first directory in the space-separated candidate_dirs list that
# contains ALL three FastRPC test libraries (libcalculator, libhap_example,
# and libmultithreading).  Requiring the complete set prevents partial installs
# from producing runtime failures instead of clean SKIPs.  Matches both
# unversioned (.so) and versioned (.so.N) forms.
fastrpc_first_dir_with_testlib() {
    candidate_dirs="$1"
    for candidate_dir in $candidate_dirs; do
        [ -d "$candidate_dir" ] || continue
        _missing=""
        for lib in libcalculator libhap_example libmultithreading; do
            if ! find "$candidate_dir" -maxdepth 1 -name "${lib}.so*" 2>/dev/null \
               | grep -qm1 .; then
                _missing="${_missing:+$_missing }${lib}"
            fi
        done
        if [ -z "$_missing" ]; then
            printf '%s\n' "$candidate_dir"
            return 0
        fi
        log_debug "fastrpc_testlib: $candidate_dir missing: $_missing"
    done
    return 1
}

# Returns 0 if the given skeleton version directory contains at least one
# loadable DSP shared object (.so or .so.N).  An empty version directory
# (e.g. v75/ with no files) is not treated as a valid artifact set.
fastrpc_skel_dir_has_artifacts() {
    skel_dir="$1"
    [ -d "$skel_dir" ] || return 1
    find "$skel_dir" -maxdepth 1 -name "*.so*" 2>/dev/null | grep -qm1 .
}

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
    FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/local/lib/fastrpc_test")"
    FASTRPC_SKEL_BASES_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_SKEL_BASES_CHECKED" "/usr/local/share/fastrpc_test")"

    # Debian/multiarch layout.
    if [ -n "$FASTRPC_MULTIARCH_TRIPLET" ]; then
        FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/lib/$FASTRPC_MULTIARCH_TRIPLET")"
        FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/lib/$FASTRPC_MULTIARCH_TRIPLET/fastrpc_test")"
    fi

    # Generic fallbacks.
    FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/lib")"
    FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/lib/fastrpc_test")"
    FASTRPC_SKEL_BASES_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_SKEL_BASES_CHECKED" "/usr/share/fastrpc_test")"

    FASTRPC_RESOLVED_LIB_SYS_DIR="$(fastrpc_first_dir_with_fastrpc_syslib "$FASTRPC_LIB_SYS_DIRS_CHECKED" || true)"
    FASTRPC_RESOLVED_LIB_TEST_DIR="$(fastrpc_first_dir_with_testlib "$FASTRPC_LIB_TEST_DIRS_CHECKED" || true)"
    FASTRPC_RESOLVED_SKEL_BASE="$(fastrpc_first_existing_word_dir "$FASTRPC_SKEL_BASES_CHECKED" || true)"

    FASTRPC_RESOLVED_SKEL_PATH=""
    if [ -n "$FASTRPC_RESOLVED_SKEL_BASE" ]; then
        # Only add a version directory if it contains actual skeleton artifacts.
        # An empty v75/ or v68/ directory is not a valid artifact set.
        for _skel_ver in v75 v68; do
            _skel_dir="$FASTRPC_RESOLVED_SKEL_BASE/$_skel_ver"
            if fastrpc_skel_dir_has_artifacts "$_skel_dir"; then
                FASTRPC_RESOLVED_SKEL_PATH="$(fastrpc_append_colon_dir "$FASTRPC_RESOLVED_SKEL_PATH" "$_skel_dir")"
            else
                log_debug "fastrpc_skel: $_skel_dir exists but contains no .so artifacts; skipping"
            fi
        done
        unset _skel_ver _skel_dir
    fi
}

fastrpc_export_runtime_env() {
    new_ld_library_path=""

    new_ld_library_path="$(fastrpc_append_colon_dir "$new_ld_library_path" "$FASTRPC_RESOLVED_LIB_SYS_DIR")"
    new_ld_library_path="$(fastrpc_append_colon_dir "$new_ld_library_path" "$FASTRPC_RESOLVED_LIB_TEST_DIR")"

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

fastrpc_log_runtime_layout() {
    log_info "FastRPC multiarch triplet: ${FASTRPC_MULTIARCH_TRIPLET:-<not detected>}"

    if [ -n "$FASTRPC_RESOLVED_LIB_SYS_DIR" ]; then
        log_info "FastRPC system library dir: $FASTRPC_RESOLVED_LIB_SYS_DIR"
    else
        log_warn "No FastRPC system library dir found. Checked: $FASTRPC_LIB_SYS_DIRS_CHECKED"
    fi

    if [ -n "$FASTRPC_RESOLVED_LIB_TEST_DIR" ]; then
        log_info "FastRPC test library dir: $FASTRPC_RESOLVED_LIB_TEST_DIR"
    else
        log_warn "No FastRPC test library dir found. Checked: $FASTRPC_LIB_TEST_DIRS_CHECKED"
    fi

    if [ -n "$FASTRPC_RESOLVED_SKEL_PATH" ]; then
        log_info "FastRPC skeleton path: $FASTRPC_RESOLVED_SKEL_PATH"
    else
        log_warn "No DSP skeleton dirs found. Checked bases: $FASTRPC_SKEL_BASES_CHECKED"
    fi
}

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

# shellcheck disable=SC2317
log_debug() {
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        log_info "[debug] $*" >&2
    fi
}

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

log_dsp_remoteproc_status() {
    fw_list="adsp mdsp sdsp cdsp cdsp0 cdsp1 gdsp0 gdsp1 gpdsp0 gpdsp1"
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

# ---------------------------------------------------------------------------
# Domain capability table — single source of truth.
# To add a new DSP domain, add one case block here; all other functions derive
# from this table automatically.
#
# Fields:
#   name           Display name (uppercase).
#   endpoint_label DT binding label → /dev/fastrpc-<label>[{-secure}].
#   fw_aliases     Space-separated firmware/DT strings for remoteproc discovery
#                  and accepted user-input aliases (besides lowercase name).
#   supported_pds  Space-separated PD values: 0=signed, 1=unsigned.
# ---------------------------------------------------------------------------
FASTRPC_ALL_DOMAIN_IDS="0 1 2 3 4 5 6"

fastrpc_domain_info() {
    _dtbl_id="$1" _dtbl_field="$2"
    case "$_dtbl_id" in
        0) case "$_dtbl_field" in
               name)           printf '%s\n' "ADSP"  ;;
               endpoint_label) printf '%s\n' "adsp"  ;;
               fw_aliases)     printf '%s\n' "adsp"  ;;
               supported_pds)  printf '%s\n' "0"     ;;
           esac ;;
        1) case "$_dtbl_field" in
               name)           printf '%s\n' "MDSP"  ;;
               endpoint_label) printf '%s\n' "mdsp"  ;;
               fw_aliases)     printf '%s\n' "mdsp"  ;;
               supported_pds)  printf '%s\n' "0"     ;;
           esac ;;
        2) case "$_dtbl_field" in
               name)           printf '%s\n' "SDSP"  ;;
               endpoint_label) printf '%s\n' "sdsp"  ;;
               fw_aliases)     printf '%s\n' "sdsp"  ;;
               supported_pds)  printf '%s\n' "0"     ;;
           esac ;;
        3) case "$_dtbl_field" in
               name)           printf '%s\n' "CDSP"         ;;
               endpoint_label) printf '%s\n' "cdsp"         ;;
               fw_aliases)     printf '%s\n' "cdsp cdsp0"   ;;
               supported_pds)  printf '%s\n' "0 1"          ;;
           esac ;;
        4) case "$_dtbl_field" in
               name)           printf '%s\n' "CDSP1"  ;;
               endpoint_label) printf '%s\n' "cdsp1"  ;;
               fw_aliases)     printf '%s\n' "cdsp1"  ;;
               supported_pds)  printf '%s\n' "0 1"    ;;
           esac ;;
        5) case "$_dtbl_field" in
               name)           printf '%s\n' "GPDSP0"         ;;
               endpoint_label) printf '%s\n' "gdsp0"          ;;
               fw_aliases)     printf '%s\n' "gpdsp0 gdsp0"   ;;
               supported_pds)  printf '%s\n' "0 1"            ;;
           esac ;;
        6) case "$_dtbl_field" in
               name)           printf '%s\n' "GPDSP1"         ;;
               endpoint_label) printf '%s\n' "gdsp1"          ;;
               fw_aliases)     printf '%s\n' "gpdsp1 gdsp1"   ;;
               supported_pds)  printf '%s\n' "0 1"            ;;
           esac ;;
    esac
}

# ---------------------------------------------------------------------------
# Accessor wrappers — all derived from fastrpc_domain_info().
# ---------------------------------------------------------------------------

name_to_domain() {
    _ntd_input="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    for _ntd_id in $FASTRPC_ALL_DOMAIN_IDS; do
        _ntd_name="$(fastrpc_domain_info "$_ntd_id" name | tr '[:upper:]' '[:lower:]')"
        [ "$_ntd_input" = "$_ntd_name" ] && { printf '%s\n' "$_ntd_id"; return 0; }
        for _ntd_alias in $(fastrpc_domain_info "$_ntd_id" fw_aliases); do
            [ "$_ntd_input" = "$_ntd_alias" ] && { printf '%s\n' "$_ntd_id"; return 0; }
        done
    done
    printf '%s\n' ""
}

domain_to_name() {
    _dtn_name="$(fastrpc_domain_info "$1" name)"
    printf '%s\n' "${_dtn_name:-UNKNOWN}"
}

domain_to_endpoint_label() {
    fastrpc_domain_info "$1" endpoint_label
}

# Returns 0 if a usable FastRPC character device exists for the given domain.
# Checks both /dev/fastrpc-<label> and /dev/fastrpc-<label>-secure.
fastrpc_domain_endpoint_available() {
    _fdea_label="$(domain_to_endpoint_label "$1")"
    [ -n "$_fdea_label" ] || return 1
    [ -c "/dev/fastrpc-${_fdea_label}" ] || [ -c "/dev/fastrpc-${_fdea_label}-secure" ]
}

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

discover_supported_domains() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - discover_supported_domains: table-driven discovery active" >&2

    for _dsd_id in $FASTRPC_ALL_DOMAIN_IDS; do
        for _dsd_fw in $(fastrpc_domain_info "$_dsd_id" fw_aliases); do
            _dsd_entries="$(get_remoteproc_by_firmware "$_dsd_fw" "" all 2>/dev/null || true)"
            if [ -n "$_dsd_entries" ]; then
                log_debug "discover: domain=$_dsd_id fw_alias=$_dsd_fw (via remoteproc)"
                printf '%s\n' "$_dsd_id"
                break
            elif dt_has_remoteproc_fw "$_dsd_fw"; then
                log_debug "discover: domain=$_dsd_id fw_alias=$_dsd_fw (dt-only)"
                printf '%s\n' "$_dsd_id"
                break
            else
                log_debug "discover: domain=$_dsd_id fw_alias=$_dsd_fw not present"
            fi
        done
    done
    unset _dsd_id _dsd_fw _dsd_entries
}

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
        _rdt_valid=0
        for _rdt_known in $FASTRPC_ALL_DOMAIN_IDS; do
            [ "$d" = "$_rdt_known" ] && { _rdt_valid=1; break; }
        done
        if [ "$_rdt_valid" -eq 1 ]; then
            case " $valid " in
                *" $d "*) : ;;
                *) valid="${valid:+$valid }$d" ;;
            esac
        else
            log_warn "Ignoring invalid domain '$d'"
        fi
    done
    unset d _rdt_valid _rdt_known

    printf '%s' "$valid"
}

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

domain_supported_pds() {
    fastrpc_domain_info "$1" supported_pds
}

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
